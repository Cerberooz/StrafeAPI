import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { fork } from 'node:child_process';
import { createServer } from 'node:net';
import { ConditionalReads, supportsConditionalRead } from '../dist/conditional-reads.js';

const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const full = value => ({ mode:'value', digest:hash(value), notModified:false, value });
const unchanged = value => ({ mode:'value', digest:hash(value), notModified:true });
const parameters = {p_key_hash:'test-key',p_subject_type:'player',p_region:'AS'};
const forbiddenFallback = () => { throw new Error('Unexpected fallback'); };

test('unchanged reads revalidate every time, preserve the public body and isolate mutations', async () => {
  const cache = new ConditionalReads();
  let value = {items:[{subjectId:'a',points:1000}], currentSeason:'season-2'}, calls = 0;
  const validate = async digest => { calls++; return digest === hash(value) ? unchanged(value) : full(value); };
  const first = await cache.read('get_points_snapshot',parameters,validate,forbiddenFallback);
  first.items[0].points = 999;
  assert.equal((await cache.read('get_points_snapshot',parameters,validate,forbiddenFallback)).items[0].points,1000);
  value.items[0].points = 1016;
  assert.equal((await cache.read('get_points_snapshot',parameters,validate,forbiddenFallback)).items[0].points,1016);
  value = {items:[], currentSeason:'season-3'};
  assert.deepEqual(await cache.read('get_points_snapshot',parameters,validate,forbiddenFallback),value);
  assert.equal(calls,4);
});

test('authorization failures and outages never serve a previous successful result', async () => {
  const cache = new ConditionalReads();
  await cache.read('get_tier_ban_statuses',parameters,async()=>full({bans:{a:false}}),forbiddenFallback);
  for (const error of [Object.assign(new Error('revoked'),{backendCode:'42501'}),new Error('network unavailable')]) {
    await assert.rejects(cache.read('get_tier_ban_statuses',parameters,async()=>{throw error;},forbiddenFallback),e=>e===error);
  }
  assert.deepEqual(await cache.read('get_tier_ban_statuses',parameters,async()=>full({bans:{a:true}}),forbiddenFallback),{bans:{a:true}});
});

test('cache partitions include keys, regions, seasons, subjects and page cursors', async () => {
  const cache = new ConditionalReads();
  for (const args of [parameters,{...parameters,p_key_hash:'another-key'},{...parameters,p_region:'EU'},
    {...parameters,p_subject_type:'team'},{...parameters,p_season:'season-1'},{...parameters,p_after:randomUUID()}]) {
    await cache.read('get_points_snapshot',args,async digest=>{ assert.equal(digest,null); return full({items:[]}); },forbiddenFallback);
  }
});

test('bounded memory, entry eviction and expiry force a fresh full result', async () => {
  let now = 0;
  const cache = new ConditionalReads(4096,1,()=>now);
  const read = key => cache.read('get_points_snapshot',{p_key_hash:key},async digest=>{assert.equal(digest,null);return full({items:[]});},forbiddenFallback);
  await read('a'); await read('b'); await read('a');
  now = 15*60_000+1; await read('a');
  const tiny = new ConditionalReads(1,1);
  for (let i=0;i<2;i++) await tiny.read('get_points_snapshot',parameters,async digest=>{assert.equal(digest,null);return full({items:[1]});},forbiddenFallback);
});

test('missing migration falls back with backoff and enables itself after installation', async () => {
  let now = 0, validations = 0, fallbacks = 0;
  const cache = new ConditionalReads(4096,10,()=>now);
  const validate = async()=>{validations++;throw Object.assign(new Error('missing'),{backendCode:'PGRST202'});};
  const fallback = async()=>{fallbacks++;return {old:true};};
  await cache.read('get_points_snapshot',parameters,validate,fallback);
  await cache.read('get_points_snapshot',parameters,validate,fallback);
  assert.equal(validations,1); assert.equal(fallbacks,2);
  now = 60_001;
  assert.deepEqual(await cache.read('get_points_snapshot',parameters,async()=>full({new:true}),forbiddenFallback),{new:true});
});

test('bad envelopes cannot invent missing cached values', async () => {
  for (const envelope of [null,{}, {...unchanged({a:1})}, {...full({a:1}),digest:'bad'}]) {
    await assert.rejects(new ConditionalReads().read('get_points_snapshot',parameters,async()=>envelope,forbiddenFallback));
  }
});

test('proxy catalogs reuse descriptive fields but update every live field on each poll', async () => {
  const cache = new ConditionalReads();
  const instance = randomUUID(), target = randomUUID();
  const staticNode = {id:'sg1',name:'Singapore',host:'sg.example.net',headTexture:'texture'.repeat(200),backends:{smp:'smp'}};
  const digest = hash([staticNode]);
  let reads = 0;
  const args = sequence=>({p_key_hash:'proxy-key',p_action:'heartbeat',p_body:{instanceId:instance,sequence,players:sequence}});
  const call = async oldDigest => {reads++;return {mode:'proxy-catalog',digest,notModified:oldDigest===digest,
    value:{ok:true,serverTime:String(reads),proxies:[{...(oldDigest===digest?{id:'sg1'}:staticNode),state:reads===1?'READY':'DRAINING',
      players:reads,cpu:reads/10,heap:reads/20,schedulerDelayMs:reads,readyBackends:[],instanceId:target,lastSeen:String(reads)}]}};};
  const first = await cache.read('proxy_balancer',args(1),call,forbiddenFallback);
  const second = await cache.read('proxy_balancer',args(2),call,forbiddenFallback);
  assert.equal(reads,2); assert.equal(second.proxies[0].headTexture,first.proxies[0].headTexture);
  for (const [key,value] of Object.entries({state:'DRAINING',players:2,cpu:.2,heap:.1,schedulerDelayMs:2,instanceId:target,lastSeen:'2'})) assert.equal(second.proxies[0][key],value);
  assert.equal(second.serverTime,'2');
  await cache.read('proxy_balancer',{...args(3),p_body:{instanceId:randomUUID()}},async old=>{assert.equal(old,null);return full({ok:false,code:'stale_proxy_instance'});},forbiddenFallback);
});

test('mutating and session operations never opt into the conditional transport', () => {
  for (const name of ['mutate_points','seed_point_snapshot','sync_point_profiles','proxy_admin_call','account_session_upsert_with_tier_status']) assert.equal(supportsConditionalRead(name,{}),false);
  for (const action of ['handoff-create','handoff-consume','handoff-complete','preference-save','drain']) assert.equal(supportsConditionalRead('proxy_balancer',{p_action:action}),false);
  for (const action of ['heartbeat','catalog','probe-jobs']) assert.equal(supportsConditionalRead('proxy_balancer',{p_action:action}),true);
});

test('small results use the original fresh RPC instead of larger digest envelopes', async () => {
  const cache = new ConditionalReads(4096,8,Date.now,256);
  let validations=0, regular=0;
  const validate=async()=>{validations++;return full({bans:{a:false}});};
  const fallback=async()=>{regular++;return {bans:{a:true}};};
  await cache.read('get_tier_ban_statuses',parameters,validate,fallback);
  assert.deepEqual(await cache.read('get_tier_ban_statuses',parameters,validate,fallback),{bans:{a:true}});
  assert.equal(validations,1);assert.equal(regular,1);
});

const engine = process.env.PROXY_SQL_ENGINE_PATH || fileURLToPath(new URL('../build/egress-test-engine-verified/node_modules/@electric-sql/pglite/dist/index.js',import.meta.url));
test('SQL wrapper preserves regional authorization, sees changes/deletes/seasons/bans and narrows grants', {skip:!existsSync(engine)}, async () => {
  const {PGlite} = await import(pathToFileURL(engine).href);
  const db = new PGlite();
  try {
    await db.exec(`create schema strafe_api; create schema strafe_points_eu;
      create role anon; create role authenticated; create role service_role; create role strafe_points_runtime; create role strafe_points_api;
      create table public.api_keys(id uuid primary key,key_hash text,point_region text,scopes text[],revoked boolean default false);
      insert into public.api_keys values(gen_random_uuid(),'as','AS',array['points:read','leaderboards:read','accounts:read'],false),
        (gen_random_uuid(),'eu','EU',array['points:read','leaderboards:read','accounts:read'],false);
      create function strafe_api.require_point_api_key(h text,s text) returns uuid language plpgsql as $$ declare k uuid; begin
        select id into k from public.api_keys where key_hash=h and not revoked and s=any(scopes);
        if not found then raise exception 'api_key_invalid'; end if; return k; end; $$;
      create table public.fixture_reads(region text primary key,payload jsonb);
      insert into public.fixture_reads values('AS','{"currentSeason":"season-2","items":[{"subjectId":"a","points":1000}]}'),('EU','{"currentSeason":"season-2","items":[]}');
      create function strafe_api.api_get_points_snapshot(h text,t text,l integer,a uuid) returns jsonb language sql as $$ select payload from public.fixture_reads where region='AS' $$;
      create function strafe_points_eu.api_get_points_snapshot(h text,t text,l integer,a uuid) returns jsonb language sql as $$ select payload from public.fixture_reads where region='EU' $$;
      create function strafe_api.api_get_points_leaderboard_for_season(h text,t text,l integer,o integer,m text,s text) returns jsonb language sql as $$ select payload from public.fixture_reads where region='AS' $$;
      create function strafe_api.api_get_smp_leaderboard_seasons(h text) returns jsonb language sql as $$ select payload from public.fixture_reads where region='AS' $$;
      create table public.tier_bans(player_id uuid primary key,banned boolean);
      create function strafe_api.api_is_tier_banned(p uuid) returns boolean language sql stable as $$ select coalesce((select banned from public.tier_bans where player_id=p),false) $$;`);
    const regional = await readFile(new URL('../supabase/migrations/20261024000000_isolated_region_records.sql',import.meta.url),'utf8');
    const start = regional.indexOf('create function strafe_api.regional_points_call(');
    await db.exec(regional.slice(start,regional.indexOf('$$;',start)+3));
    const moderation = await readFile(new URL('../supabase/migrations/20261006000000_tier_moderation.sql',import.meta.url),'utf8');
    const banStart = moderation.indexOf('create or replace function strafe_api.api_get_tier_ban_statuses(');
    await db.exec(moderation.slice(banStart,moderation.indexOf('$$;',banStart)+3));
    await db.exec(await readFile(new URL('../supabase/migrations/20261125000000_conditional_api_reads.sql',import.meta.url),'utf8'));
    const call = async(key,name,args,digest=null)=>(await db.query('select strafe_api.api_read_if_changed($1,$2,$3::jsonb,$4) as value',[key,name,JSON.stringify(args),digest])).rows[0].value;
    const args = {p_subject_type:'player',p_limit:500,p_after:null};
    const first = await call('as','get_points_snapshot',args);
    assert.equal(first.value.region,'AS');
    const second = await call('as','get_points_snapshot',args,first.digest);
    assert.equal(second.notModified,true); assert.equal(second.value,undefined);
    assert.ok(Buffer.byteLength(JSON.stringify(second))<Buffer.byteLength(JSON.stringify(first)));
    await assert.rejects(call('as','get_points_snapshot',{...args,p_region:'EU'},first.digest),/api_key_region_denied/);
    assert.equal((await call('eu','get_points_snapshot',args,first.digest)).value.region,'EU');
    await db.exec(`update public.fixture_reads set payload='{"currentSeason":"season-2","items":[{"subjectId":"a","points":1016}]}' where region='AS'`);
    const changed = await call('as','get_points_snapshot',args,first.digest);
    assert.equal(changed.notModified,false); assert.equal(changed.value.items[0].points,1016);
    await db.exec(`update public.fixture_reads set payload='{"currentSeason":"season-3","items":[]}' where region='AS'`);
    const reset = await call('as','get_points_snapshot',args,changed.digest);
    assert.equal(reset.value.currentSeason,'season-3'); assert.deepEqual(reset.value.items,[]);
    await db.exec(`update public.api_keys set revoked=true where key_hash='as'`);
    await assert.rejects(call('as','get_points_snapshot',args,reset.digest),/api_key_invalid/);
    await db.exec(`update public.api_keys set revoked=false where key_hash='as'`);
    const player = randomUUID(), banArgs = {p_player_ids:[player]};
    const before = await call('as','get_tier_ban_statuses',banArgs);
    await db.query('insert into public.tier_bans values($1,true)',[player]);
    const banned = await call('as','get_tier_ban_statuses',banArgs,before.digest);
    assert.equal(banned.value.bans[player],true); assert.equal(banned.notModified,false);
    await assert.rejects(call('as','get_tier_ban_statuses',{p_player_ids:[player,player]}),/unique/);
    await assert.rejects(call('as','mutate_points',{},null),/Unsupported/);
    const grant = await db.query(`select has_function_privilege('anon','strafe_api.api_read_if_changed(text,text,jsonb,text)','execute') as anon,
      has_function_privilege('service_role','strafe_api.api_read_if_changed(text,text,jsonb,text)','execute') as server`);
    assert.equal(grant.rows[0].anon,false); assert.equal(grant.rows[0].server,true);
    const page={currentSeason:'season-3',items:Array.from({length:500},(_,index)=>({subjectId:randomUUID(),displayName:'Player'+index,subjectType:'player',points:1000,wins:0,losses:0}))};
    await db.query("update public.fixture_reads set payload=$1::jsonb where region='AS'",[JSON.stringify(page)]);
    const large=await call('as','get_points_snapshot',args), small=await call('as','get_points_snapshot',args,large.digest);
    const fullBytes=Buffer.byteLength(JSON.stringify(large)),sameBytes=Buffer.byteLength(JSON.stringify(small));
    assert.ok(sameBytes<fullBytes*.01,'unchanged 500-row point snapshot reduces transport bytes by over 99%');
    console.log(`Snapshot fixture transport bytes: full=${fullBytes}, unchanged=${sameBytes}`);
  } finally { await db.close(); }
});


test('real HTTP server keeps old clients working, revalidates bans, revokes keys and supports an unmigrated schema', {timeout:20000}, async t => {
  const reservation=createServer();
  await new Promise(resolve=>reservation.listen(0,'127.0.0.1',resolve));
  const port=reservation.address().port;
  await new Promise(resolve=>reservation.close(resolve));
  const child=fork(fileURLToPath(new URL('../dist/server.js',import.meta.url)),[],{
    execArgv:['--import',new URL('./fixtures/conditional-api-fetch.mjs',import.meta.url).href],
    env:{...process.env,HOST:'127.0.0.1',PORT:String(port),SUPABASE_URL:'https://supabase.invalid',SUPABASE_SECRET_KEY:'sb_secret_test_only',
      API_CONDITIONAL_READS:'true',PROXY_REDIS_URL:'',PROXY_DISCOVERY_POOLS:'',DISCORD_CLIENT_ID:'',DISCORD_CLIENT_SECRET:'',ACCOUNT_PUBLIC_URL:''},
    stdio:['ignore','pipe','pipe','ipc']});
  t.after(()=>{child.kill();});
  let output='',errors=''; child.stderr.on('data',chunk=>{errors+=chunk;});
  await new Promise((resolve,reject)=>{
    child.stdout.on('data',chunk=>{output+=chunk;if(output.includes('listening on'))resolve();});
    child.once('exit',code=>reject(new Error('Fixture API exited '+code+': '+errors)));
  });
  const set=async fixture=>{
    const id=randomUUID();
    const ack=new Promise(resolve=>{const listener=message=>{if(message?.ack===id){child.off('message',listener);resolve();}};child.on('message',listener);});
    child.send({id,fixture}); await ack;
  };
  const headers={Authorization:'Bearer ssmp_live_'+'a'.repeat(64)};
  const get=async path=>fetch(`http://127.0.0.1:${port}${path}`,{headers});
  const snapshot='/v1/points/snapshot?subjectType=player&limit=500';
  const first=await (await get(snapshot)).json();
  assert.deepEqual(await (await get(snapshot)).json(),first);
  assert.equal('digest' in first,false);assert.equal('notModified' in first,false);
  const player='00000000-0000-4000-8000-000000000001';
  const statusPath='/v1/tiers/status?ids='+Array.from({length:10},(_,i)=>'00000000-0000-4000-8000-'+String(i+1).padStart(12,'0')).join(',');
  assert.equal((await (await get(statusPath)).json()).bans[player],false);
  await set({banned:true});
  assert.equal((await (await get(statusPath)).json()).bans[player],true);
  assert.equal((await (await get(snapshot)).json()).items[0].points,984);
  const instance=randomUUID();
  const poll=async()=>{
    const response=await fetch(`http://127.0.0.1:${port}/v1/proxy-balancer/probe-jobs`,{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({instanceId:instance})});
    assert.equal(response.status,200);return response.json();
  };
  const proxy1=await poll(),proxy2=await poll();
  assert.equal(proxy1.proxies[0].headTexture,proxy2.proxies[0].headTexture);
  assert.notEqual(proxy1.proxies[0].players,proxy2.proxies[0].players);
  assert.equal('mode' in proxy2,false);
  await set({revoked:true});assert.equal((await get(snapshot)).status,401);
  await set({revoked:false,unavailable:true});assert.equal((await get(snapshot)).status,503);
  await set({unavailable:false,migration:false});
  assert.equal((await get(snapshot)).status,200);
  assert.equal((await get(statusPath)).status,200);
});
