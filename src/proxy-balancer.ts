import { createHash } from 'node:crypto';
import { isIP } from 'node:net';
export const proxyBalancerActions = new Set(['heartbeat','catalog','preference','preference-save','probe-create','probe-result','probe-read','probe-jobs','handoff-create','handoff-consume','handoff-complete','handoff-status','handoff-cancel']);
export const proxyAdminActions = new Set(['admin-submit','admin-poll','admin-result','admin-status']);
for (const action of proxyAdminActions) proxyBalancerActions.add(action);
type Body = Record<string, unknown>;
export class ProxyInputError extends Error {}
const id = (v:unknown) => typeof v === 'string' && /^[a-z0-9][a-z0-9_-]{0,47}$/.test(v);
const uuid = (v:unknown) => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const integer = (v:unknown,min:number,max:number) => Number.isSafeInteger(v) && (v as number)>=min && (v as number)<=max;
export function publicProbeIp(value: unknown): boolean {
  if (typeof value !== 'string') return false;
  if (isIP(value) === 4) {
    const a=value.split('.').map(Number); const x=a[0]!,y=a[1]!;
    return x!==0 && x!==10 && x!==127 && x<224 && !(x===169&&y===254) && !(x===172&&y>=16&&y<=31)
      && !(x===192&&(y===168||y===0)) && !(x===100&&y>=64&&y<=127) && !(x===198&&(y===18||y===19));
  }
  // Reject mapped IPv4, loopback, ULA, link-local and multicast. Permit global-unicast IPv6 only.
  return isIP(value)===6 && /^[23][0-9a-f]{3}:/i.test(value);
}
export function validateProxyBody(action:string, input:Body):Body {
  if (!proxyBalancerActions.has(action)) throw new ProxyInputError('Unknown proxy action.');
  const b:Body={...input};
  if (Buffer.byteLength(JSON.stringify(b))>32768) throw new ProxyInputError('Proxy request too large.');
  const need=(ok:boolean)=>{if(!ok)throw new ProxyInputError('Invalid proxy request.');};
  need(uuid(b.instanceId));
  const session=(field:string,out:string)=>{
    const v=b[field]; need(typeof v==='string' && /^[0-9a-f]{64}$/i.test(v));
    b[out]=createHash('sha256').update((v as string).toLowerCase()).digest('hex'); delete b[field];
  };
  if (action === 'admin-poll') return { instanceId: b.instanceId };
  if (action === 'admin-submit') {
    need(uuid(b.actorId) && id(b.source) && uuid(b.sourceInstance));
    session('actorToken','actorHash');
    const fields: Body = { instanceId: b.instanceId, actorId: b.actorId, actorHash: b.actorHash,
      source: b.source, sourceInstance: b.sourceInstance, kind: b.kind };
    if (b.kind === 'roster') {
      need(integer(b.offset,0,100000));
      return { ...fields, offset: b.offset };
    }
    need((b.kind === 'move' || b.kind === 'drain') && id(b.destination) && uuid(b.destinationInstance));
    const destination = { destination: b.destination, destinationInstance: b.destinationInstance };
    if (b.kind === 'drain') return { ...fields, ...destination };
    need(uuid(b.playerId) && uuid(b.connectionId));
    return { ...fields, ...destination, playerId: b.playerId, connectionId: b.connectionId };
  }
  if (action === 'admin-status') {
    need(uuid(b.jobId) && uuid(b.actorId));
    session('actorToken','actorHash');
    return { instanceId: b.instanceId, jobId: b.jobId, actorId: b.actorId, actorHash: b.actorHash };
  }
  if (action === 'admin-result') {
    need(uuid(b.jobId) && ['roster','move_sent','drain_started','unavailable','player_left','move_failed','already_draining'].includes(String(b.outcome)));
    const fields: Body = { instanceId: b.instanceId, jobId: b.jobId, outcome: b.outcome };
    if (b.outcome !== 'roster') return fields;
    need(integer(b.total,0,100000) && Array.isArray(b.players) && b.players.length <= 45);
    const players = (b.players as unknown[]).map(row => {
      need(!!row && typeof row === 'object' && !Array.isArray(row));
      const p = row as Body;
      need(uuid(p.playerId) && (p.connectionId === null || uuid(p.connectionId)) &&
        typeof p.name === 'string' && p.name.length >= 1 && p.name.length <= 64 && !/\p{Cc}/u.test(p.name));
      return { playerId: p.playerId, connectionId: p.connectionId, name: p.name };
    });
    return { ...fields, total: b.total, players };
  }
  if (['preference','preference-save','probe-create','handoff-create','handoff-consume','handoff-complete'].includes(action)) need(uuid(b.playerId));
  if(action==='handoff-status') need(Array.isArray(b.handoffIds)&&b.handoffIds.length<=50&&b.handoffIds.every(uuid));
  if (action==='heartbeat') {
    need(uuid(b.instanceId)&&integer(b.sequence,0,Number.MAX_SAFE_INTEGER)&&['READY','DRAINING'].includes(String(b.state))&&integer(b.players,0,100000));
    for(const field of ['cpu','heap']) need(b[field]===null || (typeof b[field]==='number'&&Number.isFinite(b[field])&&(b[field] as number)>=0&&(b[field] as number)<=1));
    need(b.schedulerDelayMs===null || (typeof b.schedulerDelayMs==='number'&&Number.isFinite(b.schedulerDelayMs)&&(b.schedulerDelayMs as number)>=0&&(b.schedulerDelayMs as number)<=3600000));
    need(Array.isArray(b.backends)&&b.backends.length<=32&&b.backends.every(id));
    if (b.registration !== undefined) {
      const n = b.registration as Body;
      need(n !== null && typeof n === 'object' && !Array.isArray(n));
      need(id(n.id) && id(n.pool) && ['AS','EU','NA','SA','OC','AF'].includes(String(n.region)));
      need(typeof n.name === 'string' && n.name.length >= 1 && n.name.length <= 64);
      need(typeof n.host === 'string' && n.host.length <= 253 &&
        (publicProbeIp(n.host) || /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(n.host)));
      need(integer(n.port,1,65535) && integer(n.capacity,1,100000) && integer(n.priority,-100000,100000));
      need(typeof n.headTexture === 'string' && n.headTexture.length <= 2048);
      need(n.backends !== null && typeof n.backends === 'object' && !Array.isArray(n.backends));
      const mappings = Object.entries(n.backends as Body);
      need(mappings.length >= 1 && mappings.length <= 32 && Buffer.byteLength(JSON.stringify(n.backends)) <= 2048 &&
        mappings.every(([role,name]) => id(role) && typeof name === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(name)));
      need((b.backends as string[]).every(role => Object.hasOwn(n.backends as Body,role)));
      b.registration = Object.fromEntries(['id','pool','region','name','host','port','capacity','priority','headTexture','backends'].map(k => [k,n[k]]));
    }
  }
  if(action==='preference-save') {need(id(b.proxyId)&&integer(b.expectedRevision,0,Number.MAX_SAFE_INTEGER));session('sessionToken','sessionHash');}
  if(action==='probe-create') {need(publicProbeIp(b.ip));session('sessionToken','sessionHash');}
  if(action==='probe-read'||action==='probe-result') need(uuid(b.id));
  if(action==='probe-result')need(b.pingMs===null||(typeof b.pingMs==='number'&&Number.isFinite(b.pingMs)&&(b.pingMs as number)>=0&&(b.pingMs as number)<=10000));
  if(action==='handoff-create') {need(id(b.targetProxyId)&&id(b.backend)&&['initial','preferred','manual','drain','health'].includes(String(b.reason))&&integer(b.preferenceRevision,0,Number.MAX_SAFE_INTEGER));if(b.targetInstanceId!==undefined)need(uuid(b.targetInstanceId));session('sourceSessionToken','sourceSessionHash');}
  if(action==='handoff-consume') {session('sessionToken','claimSessionHash');need(typeof b.ticket==='string'&&/^[0-9a-f]{64}$/.test(b.ticket));b.ticketHash=createHash('sha256').update(b.ticket as string).digest('hex');delete b.ticket;}
  if(action==='handoff-cancel') {need(uuid(b.handoffId)&&uuid(b.playerId));session('sourceSessionToken','sourceSessionHash');}
  if(action==='handoff-complete') {need(uuid(b.handoffId)&&id(b.backend)&&typeof b.playerName==='string'&&/^[A-Za-z0-9_]{1,16}$/.test(b.playerName)&&typeof b.premium==='boolean');session('sessionToken','sessionHash');}
  return b;
}
