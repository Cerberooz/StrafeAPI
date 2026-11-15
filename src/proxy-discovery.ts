import { createClient } from 'redis';

type Node = Record<string, unknown>;
export const PROXY_LEASE_MS = 20_000;

// Only accepted database heartbeats are published. Redis time bounds the lease;
// delayed HTTP callbacks cannot overwrite a newer generation or extend stale health.
export const PUBLISH_PROXY = `
local now = redis.call('TIME')
local nowMs = tonumber(now[1]) * 1000 + math.floor(tonumber(now[2]) / 1000)
local incoming = cjson.decode(ARGV[1])
local expires = tonumber(ARGV[2])
if expires <= nowMs then return 0 end
local old = redis.call('GET', KEYS[1])
if old then
  local current = cjson.decode(old)
  if current.leaseVersion > incoming.leaseVersion then return 0 end
  if current.leaseVersion == incoming.leaseVersion and current.instanceId ~= incoming.instanceId then return 0 end
  if current.instanceId == incoming.instanceId and current.sequence >= incoming.sequence then return 0 end
end
redis.call('SET', KEYS[1], ARGV[1], 'PX', math.min(expires - nowMs, ${PROXY_LEASE_MS}))
return 1`;

export interface DiscoveryStore {
  publish(node: Node, sequence: number): Promise<void>;
  live(nodes: Node[]): Promise<Node[]>;
}

export class ProxyDiscovery implements DiscoveryStore {
  private readonly client;
  private readonly prefix: string;
  constructor(url: string, prefix = 'strafe:proxy:') {
    if (!/^rediss?:\/\//.test(url)) throw new Error('PROXY_REDIS_URL must use redis:// or rediss://.');
    if (!/^[a-zA-Z0-9:_-]{1,80}$/.test(prefix)) throw new Error('Invalid PROXY_REDIS_PREFIX.');
    this.prefix = prefix;
    this.client = createClient({ url, disableOfflineQueue: true, commandsQueueMaxLength: 256, commandOptions: { timeout: 2000 },
      socket: { connectTimeout: 1500, reconnectStrategy: retries => Math.min(1000 + retries * 200, 5000) } });
    // Errors are returned to callers without logging connection strings or credentials.
    this.client.on('error', () => {});
    void this.client.connect().catch(() => {});
  }
  private key(node: Node): string { return `${this.prefix}${node.pool}:${node.id}`; }
  async publish(node: Node, sequence: number): Promise<void> {
    if (!this.client.isReady) throw new Error('Proxy discovery unavailable.');
    const leaseVersion = Date.parse(String(node.lastSeen));
    if (!Number.isFinite(leaseVersion)) throw new Error('Invalid proxy heartbeat.');
    await this.client.eval(PUBLISH_PROXY, { keys: [this.key(node)],
      arguments: [JSON.stringify({ ...node, sequence, leaseVersion }), String(leaseVersion + PROXY_LEASE_MS)] });
  }
  async live(nodes: Node[]): Promise<Node[]> {
    if (!this.client.isReady) throw new Error('Proxy discovery unavailable.');
    if (!nodes.length) return [];
    const values = await this.client.mGet(nodes.map(n => this.key(n)));
    return nodes.flatMap((node,i) => {
      const value = values[i];
      if (!value) return [];
      try {
        const live = JSON.parse(value) as Node;
        const version = Number(live.leaseVersion);
        // SQL remains the credential/generation fence and durable transfer authority.
        if (!Number.isFinite(version) || live.id !== node.id || live.pool !== node.pool || live.instanceId !== node.instanceId || live.state !== node.state ||
            version < Date.parse(String(node.lastSeen)) || Date.now() - version >= PROXY_LEASE_MS) return [];
        // A peer can heartbeat between the SQL snapshot and MGET. A newer accepted
        // heartbeat of the same process is usable; an older Redis write is not.
        const { sequence: _sequence, leaseVersion: _version, ...advertised } = live;
        return [{ ...node, ...advertised }];
      } catch { return []; }
    });
  }
  close(): void { if (this.client.isOpen) this.client.destroy(); }
}

// Used by the HTTP boundary and by isolated verification; never exposes Redis to clients.
export async function discoveredCall(store: DiscoveryStore, action: string, body: Node,
    call: (action: string, body: Node) => Promise<Node>): Promise<Node> {
  if (action === 'handoff-create') {
    const snapshot = await call('catalog', { instanceId: body.instanceId });
    if (snapshot.ok !== true) return snapshot;
    const nodes = await store.live(snapshot.proxies as Node[]);
    const source = nodes.find(n => n.id === snapshot.proxyId);
    const target = nodes.find(n => n.id === body.targetProxyId);
    if (!source || !target || target.state !== 'READY' ||
        body.targetInstanceId !== undefined && target.instanceId !== body.targetInstanceId) return { ok: false, code: 'proxy_unavailable' };
  }
  const result = await call(action,body);
  if (result.ok !== true || !Array.isArray(result.proxies)) return result;
  if (action === 'heartbeat') {
    const self = (result.proxies as Node[]).find(n => n.id === result.proxyId);
    if (!self) throw new Error('Missing registered proxy.');
    await store.publish(self, Number(body.sequence));
  }
  const live = new Map((await store.live(result.proxies as Node[])).map(n => [n.id,n]));
  return { ...result, proxies: (result.proxies as Node[]).map(n => live.get(n.id) ?? { ...n, state: 'UNHEALTHY' }) };
}
