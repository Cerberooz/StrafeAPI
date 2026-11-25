import { createHash } from 'node:crypto';

type Json = Record<string, unknown>;
type Entry = { digest: string; mode: string; value: Json; bytes: number; expires: number };
// These fields are sent fresh on every proxy poll. Only descriptive catalog fields are reused.
const liveProxyFields = ['state', 'players', 'cpu', 'heap', 'schedulerDelayMs', 'readyBackends', 'instanceId', 'lastSeen'];
const reads = new Set(['get_points_snapshot', 'get_points_leaderboard_for_season', 'get_smp_leaderboard_seasons', 'get_tier_ban_statuses']);

export function supportsConditionalRead(name: string, parameters: Json): boolean {
  return reads.has(name) || name === 'proxy_balancer' && ['heartbeat', 'catalog', 'probe-jobs'].includes(String(parameters.p_action));
}

/** Every hit is revalidated by a scoped database function; no stale data or cached authorization. */
export class ConditionalReads {
  private readonly entries = new Map<string, Entry>();
  private bytes = 0;
  private unavailableUntil = 0;
  constructor(private readonly maxBytes = 32 * 1024 * 1024, private readonly maxEntries = 512,
    private readonly now: () => number = Date.now, private readonly minBytes = 0) {}

  async read<T>(name: string, parameters: Json, validate: (digest: string | null) => Promise<unknown>,
    fallback: () => Promise<T>): Promise<T> {
    if (this.now() < this.unavailableUntil) return fallback();
    // Heartbeat sequence/metrics change every call, while its descriptive catalog does not.
    // The actual unmodified parameters still go to SQL for all fencing, mutations and checks.
    const identity = name === 'proxy_balancer'
      ? { key: parameters.p_key_hash, action: parameters.p_action, instance: (parameters.p_body as Json)?.instanceId }
      : parameters;
    const key = createHash('sha256').update(JSON.stringify([name, identity])).digest('hex');
    let previous = this.entries.get(key);
    if (previous && previous.expires <= this.now()) { this.remove(key); previous = undefined; }
    // A digest envelope can be larger than a tiny original result. Keep those reads
    // on their ordinary, freshly authorized RPC for the lifetime of this entry.
    if (previous?.mode === 'bypass') return fallback();
    let envelope: unknown;
    try { envelope = await validate(previous?.digest ?? null); }
    catch (error) {
      const code = error && typeof error === 'object'
        ? ('backendCode' in error ? error.backendCode : 'code' in error ? error.code : null) : null;
      if (code !== 'PGRST202' && code !== '42883') throw error;
      // Rolling deployment: old schema keeps working, and a missing RPC is not retried every poll.
      this.unavailableUntil = this.now() + 60_000;
      return fallback();
    }
    if (!isObject(envelope) || typeof envelope.digest !== 'string' || !/^[a-f0-9]{64}$/.test(envelope.digest)
      || typeof envelope.notModified !== 'boolean' || !['value', 'proxy-catalog'].includes(String(envelope.mode))) {
      throw new Error('Invalid conditional read response');
    }
    let value: Json;
    if (envelope.mode === 'proxy-catalog') {
      if (!isObject(envelope.value) || !Array.isArray(envelope.value.proxies)) throw new Error('Invalid proxy catalog response');
      value = envelope.value;
      if (envelope.notModified) {
        if (!previous || previous.digest !== envelope.digest || previous.mode !== envelope.mode || !Array.isArray(previous.value.proxies))
          throw new Error('Missing validated proxy catalog');
        const catalog = new Map(previous.value.proxies.filter(isObject).map(node => [node.id, node]));
        value = { ...value, proxies: (value.proxies as unknown[]).map((node: unknown) => {
          if (!isObject(node) || !catalog.has(node.id)) throw new Error('Proxy catalog identity mismatch');
          return { ...catalog.get(node.id), ...node };
        }) };
      }
      const stored = { ...value, proxies: (value.proxies as unknown[]).map(node => {
        if (!isObject(node)) throw new Error('Invalid proxy catalog node');
        const staticNode = { ...node };
        for (const field of liveProxyFields) delete staticNode[field];
        return staticNode;
      }) };
      const worthCaching = Buffer.byteLength(JSON.stringify(stored.proxies)) >= this.minBytes;
      this.remember(key, envelope.digest, worthCaching ? 'proxy-catalog' : 'bypass', worthCaching ? stored : {});
    } else {
      if (envelope.notModified) {
        if (!previous || previous.digest !== envelope.digest || previous.mode !== envelope.mode) throw new Error('Missing validated read');
        value = previous.value;
      } else {
        if (!isObject(envelope.value)) throw new Error('Invalid conditional read value');
        value = envelope.value;
      }
      const worthCaching = Buffer.byteLength(JSON.stringify(value)) >= this.minBytes;
      this.remember(key, envelope.digest, worthCaching ? 'value' : 'bypass', worthCaching ? value : {});
    }
    // Route handlers may normalize response fields; they must not mutate the validated copy.
    return structuredClone(value) as T;
  }

  private remember(key: string, digest: string, mode: string, value: Json): void {
    this.remove(key);
    const bytes = Buffer.byteLength(JSON.stringify(value));
    if (bytes > this.maxBytes || this.maxEntries < 1) return;
    while (this.entries.size >= this.maxEntries || this.bytes + bytes > this.maxBytes) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.remove(oldest);
    }
    this.entries.set(key, { digest, mode, value: structuredClone(value), bytes, expires: this.now() + 15 * 60_000 });
    this.bytes += bytes;
  }

  private remove(key: string): void {
    const old = this.entries.get(key);
    if (old) { this.bytes -= old.bytes; this.entries.delete(key); }
  }
}

function isObject(value: unknown): value is Json {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
