-- Proxy Balancer v2.0: tables are private; only credential-bound RPC is exposed.
create table strafe_api.proxy_nodes (
  id text primary key check(id ~ '^[a-z0-9][a-z0-9_-]{0,47}$'),
  pool text not null check(pool ~ '^[a-z0-9][a-z0-9_-]{0,47}$'),
  api_key_id uuid not null unique references public.api_keys(id),
  region text not null check(region in ('AS','EU','NA','SA','OC','AF')),
  name text not null check(length(name) between 1 and 64),
  host text not null check(length(host) between 1 and 253 and host !~ '[[:space:]/]'),
  port integer not null default 25565 check(port between 1 and 65535),
  priority integer not null default 100,
  capacity integer not null default 300 check(capacity between 1 and 100000),
  head_texture text not null default '' check(length(head_texture)<=2048),
  backends jsonb not null check(jsonb_typeof(backends)='object' and octet_length(backends::text)<=2048),
  enabled boolean not null default true,
  instance_id uuid, sequence bigint not null default -1,
  state text not null default 'UNHEALTHY' check(state in ('READY','DRAINING','UNHEALTHY')),
  players integer not null default 0,
  cpu double precision, heap double precision, scheduler_delay_ms double precision,
  ready_backends jsonb not null default '[]', last_seen timestamptz
);
create index proxy_nodes_pool on strafe_api.proxy_nodes(pool);
create table strafe_api.proxy_preferences (
  player_id uuid not null, pool text not null, proxy_id text not null references strafe_api.proxy_nodes(id),
  revision bigint not null default 1, updated_at timestamptz not null default now(), primary key(player_id,pool)
);
create table strafe_api.proxy_probe_jobs (
  id uuid primary key default gen_random_uuid(), source_proxy text not null references strafe_api.proxy_nodes(id),
  player_id uuid not null, pool text not null, ip inet,
  created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '4 seconds'
);
create index proxy_probe_pending on strafe_api.proxy_probe_jobs(pool,expires_at);
create index proxy_probe_owner on strafe_api.proxy_probe_jobs(source_proxy,player_id,created_at);
create table strafe_api.proxy_probe_results (
  job_id uuid not null references strafe_api.proxy_probe_jobs(id) on delete cascade,
  proxy_id text not null references strafe_api.proxy_nodes(id), ping_ms double precision,
  primary key(job_id,proxy_id)
);
create table strafe_api.proxy_handoffs (
  id uuid primary key default gen_random_uuid(), ticket_hash text not null unique,
  player_id uuid not null, pool text not null,
  source_proxy text not null references strafe_api.proxy_nodes(id), target_proxy text not null references strafe_api.proxy_nodes(id),
  source_instance uuid not null, target_instance uuid not null,
  source_session_hash text not null, destination_session_hash text, claim_session_hash text,
  backend text not null, reason text not null check(reason in ('initial','preferred','manual','drain','health')),
  preference_revision bigint not null, created_at timestamptz not null default now(),
  expires_at timestamptz not null default now()+interval '60 seconds',
  claimed_at timestamptz, completed_at timestamptz, preference_saved boolean
);
create index proxy_handoffs_player on strafe_api.proxy_handoffs(player_id,created_at);
create index proxy_handoffs_expiry on strafe_api.proxy_handoffs(expires_at);
create index proxy_handoffs_manual_cooldown on strafe_api.proxy_handoffs(player_id,pool,completed_at) where reason='manual';
create table strafe_api.proxy_retired_sessions (
  player_id uuid not null, token_hash text not null, retired_at timestamptz not null default now(),
  primary key(player_id,token_hash)
);
-- Retired session hashes intentionally remain: a delayed pre-transfer heartbeat must never revive them.
-- This retired-token table keeps no credentials, raw tickets, or player IPs.

-- Preserve ordinary session policy while fencing retired transfer source tokens.
-- Clone the previous implementation instead of renaming it: existing callers/prepared plans
-- must retain the original function OID and therefore always run the new fence.
do $$ declare definition text; begin
  definition:=pg_catalog.pg_get_functiondef('strafe_api.api_account_session_upsert(text,uuid,text,boolean,text,timestamptz,integer)'::regprocedure);
  execute replace(definition,'FUNCTION strafe_api.api_account_session_upsert(',
    'FUNCTION strafe_api.api_account_session_upsert_before_proxy_balancer(');
end; $$;
create or replace function strafe_api.api_account_session_upsert(
  p_key_hash text,p_player_id uuid,p_player_name text,p_premium boolean,p_session_token_hash text,
  p_session_started_at timestamptz,p_ttl_seconds integer
) returns jsonb language plpgsql security definer set search_path='' as $$
begin
  perform strafe_api.require_point_api_key(p_key_hash,'accounts:write');
  -- Match the existing tier-status wrapper lock order, avoiding heartbeat/handoff deadlocks.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('tier-ban:'||p_player_id::text));
  -- Serialize all sessions for this player against handoff completion.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('proxy-session:'||p_player_id::text,0));
  if exists(select 1 from strafe_api.proxy_retired_sessions where player_id=p_player_id and token_hash=p_session_token_hash) then
    return jsonb_build_object('ok',false,'code','stale_session');
  end if;
  return strafe_api.api_account_session_upsert_before_proxy_balancer(p_key_hash,p_player_id,p_player_name,p_premium,p_session_token_hash,p_session_started_at,p_ttl_seconds);
end;
$$;

create function strafe_api.proxy_node_json(n strafe_api.proxy_nodes) returns jsonb
language sql stable set search_path='' as $$
 select jsonb_build_object('id',n.id,'pool',n.pool,'region',n.region,'name',n.name,'host',n.host,'port',n.port,
 'priority',n.priority,'capacity',n.capacity,'headTexture',n.head_texture,'backends',n.backends,
 'state',case when not n.enabled or n.last_seen is null or n.last_seen<now()-interval '20 seconds' then 'UNHEALTHY' else n.state end,
 'players',n.players,'cpu',n.cpu,'heap',n.heap,'schedulerDelayMs',n.scheduler_delay_ms,
 'readyBackends',n.ready_backends,'instanceId',n.instance_id,'lastSeen',n.last_seen)
$$;

create function strafe_api.proxy_balancer_call(p_key_hash text,p_action text,p_body jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  key_id uuid; node strafe_api.proxy_nodes; target strafe_api.proxy_nodes;
  player uuid; job strafe_api.proxy_probe_jobs; handoff strafe_api.proxy_handoffs;
  pref strafe_api.proxy_preferences; sess public.minecraft_account_sessions;
  result jsonb; jobs jsonb; catalog jsonb; job_id uuid; ticket_id uuid;
  saved boolean:=false; affected integer; started timestamptz; account jsonb; current_instance uuid;
begin
  key_id:=strafe_api.require_point_api_key(p_key_hash,'accounts:write');
  select * into node from strafe_api.proxy_nodes where api_key_id=key_id and enabled;
  if not found then raise exception 'api_key_scope_denied' using errcode='42501'; end if;
  if (select count(*) from strafe_api.proxy_nodes where pool=node.pool and enabled)>9 then
    return jsonb_build_object('ok',false,'code','invalid_pool_configuration');
  end if;
  if p_action not in ('heartbeat','catalog','preference','preference-save','probe-create','probe-result','probe-read','probe-jobs','handoff-create','handoff-consume','handoff-complete','handoff-status','handoff-cancel')
    or p_body is null or jsonb_typeof(p_body)<>'object' or octet_length(p_body::text)>32768 then
    raise exception 'invalid proxy action' using errcode='22023';
  end if;
  -- Every request carries its immutable process generation. A late former process cannot act as its replacement.
  if p_action<>'heartbeat' and (node.instance_id is distinct from (p_body->>'instanceId')::uuid
    or node.last_seen is null or node.last_seen<now()-interval '20 seconds') then
    return jsonb_build_object('ok',false,'code','stale_proxy_instance');
  end if;
  -- Expiring work is bounded by the 32-job admission cap per source; index-backed cleanup.
  update strafe_api.proxy_probe_jobs set ip=null where id in (select id from strafe_api.proxy_probe_jobs where ip is not null and expires_at<=now() limit 128);
  delete from strafe_api.proxy_probe_jobs where id in (select id from strafe_api.proxy_probe_jobs where expires_at<now()-interval '30 seconds' limit 128);
  delete from strafe_api.proxy_handoffs where id in (select id from strafe_api.proxy_handoffs where expires_at<now()-interval '1 day' limit 128);
  if p_body ? 'playerId' then player:=(p_body->>'playerId')::uuid; end if;
  if p_action='heartbeat' then
    if p_body->>'state' not in ('READY','DRAINING') or jsonb_typeof(p_body->'backends')<>'array'
      or (p_body->>'players')::int not between 0 and 100000 then raise exception 'invalid heartbeat' using errcode='22023'; end if;
    -- An old instance may not take over while a replacement is alive.
    update strafe_api.proxy_nodes set instance_id=(p_body->>'instanceId')::uuid,sequence=(p_body->>'sequence')::bigint,
      state=p_body->>'state',players=(p_body->>'players')::int,cpu=(p_body->>'cpu')::double precision,
      heap=(p_body->>'heap')::double precision,scheduler_delay_ms=(p_body->>'schedulerDelayMs')::double precision,
      ready_backends=p_body->'backends',last_seen=clock_timestamp()
    where id=node.id and (instance_id=(p_body->>'instanceId')::uuid and sequence<(p_body->>'sequence')::bigint
      or instance_id is null or last_seen<now()-interval '20 seconds');
    if not found then return jsonb_build_object('ok',false,'code','stale_proxy_instance'); end if;
    select * into node from strafe_api.proxy_nodes where id=node.id;
  end if;
  if p_action in ('heartbeat','catalog','probe-jobs') then
    select coalesce(jsonb_agg(strafe_api.proxy_node_json(n) order by n.priority,n.id),'[]') into catalog
      from strafe_api.proxy_nodes n where n.pool=node.pool and n.enabled;
    select coalesce(jsonb_agg(jsonb_build_object('id',j.id,'ip',host(j.ip),'expiresAt',j.expires_at)),'[]') into jobs
      from (select j.* from strafe_api.proxy_probe_jobs j where j.pool=node.pool and j.expires_at>now()
        and not exists(select 1 from strafe_api.proxy_probe_results r where r.job_id=j.id and r.proxy_id=node.id)
        order by j.created_at limit 16) j;
    return jsonb_build_object('ok',true,'proxyId',node.id,'pool',node.pool,'proxies',catalog,'probeJobs',jobs,'serverTime',clock_timestamp());
  end if;
  if p_action='preference' then
    select * into pref from strafe_api.proxy_preferences where player_id=player and pool=node.pool;
    return jsonb_build_object('ok',true,'proxyId',pref.proxy_id,'revision',coalesce(pref.revision,0));
  end if;
  if p_action='preference-save' then
    if p_body->>'proxyId'<>node.id then return jsonb_build_object('ok',false,'code','wrong_proxy'); end if;
    if not exists(select 1 from public.minecraft_account_sessions where player_id=player and api_key_id=key_id
      and session_token_hash=p_body->>'sessionHash' and ended_at is null and expires_at>now()) then
      return jsonb_build_object('ok',false,'code','stale_session');
    end if;
    insert into strafe_api.proxy_preferences(player_id,pool,proxy_id)
      select player,node.pool,node.id where (p_body->>'expectedRevision')::bigint=0 on conflict do nothing;
    get diagnostics affected = row_count; saved:=affected>0;
    select * into pref from strafe_api.proxy_preferences where player_id=player and pool=node.pool;
    return jsonb_build_object('ok',true,'preferenceSaved',saved,'proxyId',pref.proxy_id,'revision',pref.revision);
  end if;
  if p_action='probe-create' then
    if not exists(select 1 from public.minecraft_account_sessions where player_id=player and api_key_id=key_id
      and session_token_hash=p_body->>'sessionHash' and ended_at is null and expires_at>now()) then
      return jsonb_build_object('ok',false,'code','stale_session');
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('proxy-probes:'||node.id,0));
    if exists(select 1 from strafe_api.proxy_probe_jobs where player_id=player and source_proxy=node.id and created_at>now()-interval '30 seconds')
      or (select count(*) from strafe_api.proxy_probe_jobs where source_proxy=node.id and expires_at>now())>=32 then
      return jsonb_build_object('ok',false,'code','probe_rate_limited');
    end if;
    insert into strafe_api.proxy_probe_jobs(source_proxy,player_id,pool,ip) values(node.id,player,node.pool,(p_body->>'ip')::inet) returning id into job_id;
    return jsonb_build_object('ok',true,'id',job_id);
  end if;
  if p_action in ('probe-result','probe-read') then
    select * into job from strafe_api.proxy_probe_jobs where id=(p_body->>'id')::uuid and pool=node.pool;
    if not found then return jsonb_build_object('ok',false,'code','probe_expired'); end if;
    if p_action='probe-result' then
      if job.expires_at<=now() then return jsonb_build_object('ok',false,'code','probe_expired'); end if;
      insert into strafe_api.proxy_probe_results values(job.id,node.id,(p_body->>'pingMs')::double precision) on conflict do nothing;
      return jsonb_build_object('ok',true);
    end if;
    if job.source_proxy<>node.id then raise exception 'api_key_scope_denied' using errcode='42501'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('proxyId',r.proxy_id,'pingMs',r.ping_ms)),'[]') into result
      from strafe_api.proxy_probe_results r where r.job_id=job.id;
    return jsonb_build_object('ok',true,'done',job.expires_at<=now(),'results',result,'expiresAt',job.expires_at);
  end if;
  if p_action='handoff-status' then
    select coalesce(jsonb_agg(jsonb_build_object('handoffId',h.id,'state',
      case when h.completed_at is not null then 'completed' when h.expires_at<=now() then 'expired'
        when h.claimed_at is not null then 'claimed' else 'pending' end)),'[]') into result
      from strafe_api.proxy_handoffs h where h.source_proxy=node.id
      and h.id in (select value::uuid from jsonb_array_elements_text(p_body->'handoffIds'));
    return jsonb_build_object('ok',true,'handoffs',result);
  end if;
  if p_action='handoff-create' then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('proxy-session:'||player::text,0));
    select * into sess from public.minecraft_account_sessions where player_id=player for update;
    if not found or sess.api_key_id<>key_id or sess.session_token_hash<>p_body->>'sourceSessionHash'
      or sess.ended_at is not null or sess.expires_at<=now() then return jsonb_build_object('ok',false,'code','stale_session'); end if;
    if exists(select 1 from strafe_api.proxy_handoffs where player_id=player and expires_at>now() and completed_at is null) then
      return jsonb_build_object('ok',false,'code','handoff_pending'); end if;
    if p_body->>'reason'='manual' and exists(select 1 from strafe_api.proxy_handoffs
      where player_id=player and pool=node.pool and reason='manual' and completed_at>now()-interval '30 seconds') then
      select max(completed_at)+interval '30 seconds' into started from strafe_api.proxy_handoffs
        where player_id=player and pool=node.pool and reason='manual' and completed_at>now()-interval '30 seconds';
      return jsonb_build_object('ok',false,'code','transfer_cooldown','waitSeconds',greatest(1,ceil(extract(epoch from started-clock_timestamp()))::int));
    end if;
    select * into target from strafe_api.proxy_nodes where id=p_body->>'targetProxyId' and pool=node.pool and enabled;
    if not found or target.id=node.id or target.state<>'READY' or target.last_seen is null or target.last_seen<now()-interval '20 seconds'
      or target.players>=target.capacity or not (target.ready_backends ? (p_body->>'backend'))
      or not (target.backends ? (p_body->>'backend')) or not (node.backends ? (p_body->>'backend'))
      or target.instance_id is null or node.instance_id is null then return jsonb_build_object('ok',false,'code','proxy_unavailable'); end if;
    insert into strafe_api.proxy_handoffs(ticket_hash,player_id,pool,source_proxy,target_proxy,source_instance,target_instance,source_session_hash,backend,reason,preference_revision)
      values(p_body->>'ticketHash',player,node.pool,node.id,target.id,node.instance_id,target.instance_id,p_body->>'sourceSessionHash',
      p_body->>'backend',p_body->>'reason',(p_body->>'preferenceRevision')::bigint) returning id,expires_at into ticket_id,started;
    return jsonb_build_object('ok',true,'handoffId',ticket_id,'expiresAt',started);
  end if;
  if p_action='handoff-cancel' then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('proxy-session:'||player::text,0));
    update strafe_api.proxy_handoffs h set expires_at=clock_timestamp()
      where h.id=(p_body->>'handoffId')::uuid and h.player_id=player and h.source_proxy=node.id
      and h.source_instance=node.instance_id and h.source_session_hash=p_body->>'sourceSessionHash'
      and h.claimed_at is null and h.completed_at is null and exists(select 1 from public.minecraft_account_sessions s
        where s.player_id=player and s.api_key_id=key_id and s.session_token_hash=h.source_session_hash
        and s.ended_at is null and s.expires_at>now());
    return jsonb_build_object('ok',true,'cancelled',found);
  end if;
  if p_action in ('handoff-consume','handoff-complete') then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('tier-ban:'||player::text));
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('proxy-session:'||player::text,0));
    select * into handoff from strafe_api.proxy_handoffs h where
      (p_action='handoff-consume' and h.ticket_hash=p_body->>'ticketHash'
      or p_action='handoff-complete' and h.id=(p_body->>'handoffId')::uuid) for update;
    if not found or handoff.player_id<>player or handoff.target_proxy<>node.id or handoff.pool<>node.pool
      or handoff.target_instance is distinct from node.instance_id or handoff.expires_at<=now() then
      return jsonb_build_object('ok',false,'code','invalid_handoff'); end if;
    if p_action='handoff-consume' then
      if handoff.completed_at is not null or (handoff.claimed_at is not null and handoff.claim_session_hash is distinct from p_body->>'claimSessionHash')
        or p_body->>'claimSessionHash' is null then return jsonb_build_object('ok',false,'code','invalid_handoff'); end if;
      update strafe_api.proxy_handoffs set claimed_at=coalesce(claimed_at,clock_timestamp()),claim_session_hash=p_body->>'claimSessionHash' where id=handoff.id;
      return jsonb_build_object('ok',true,'handoffId',handoff.id,'backend',handoff.backend,'sourceProxyId',handoff.source_proxy,
        'reason',handoff.reason,'preferenceRevision',handoff.preference_revision);
    end if;
    if handoff.claimed_at is null or handoff.claim_session_hash is distinct from p_body->>'sessionHash' or p_body->>'backend'<>handoff.backend then return jsonb_build_object('ok',false,'code','invalid_handoff'); end if;
    if handoff.completed_at is not null then
      if handoff.destination_session_hash<>p_body->>'sessionHash' then return jsonb_build_object('ok',false,'code','invalid_handoff'); end if;
      account:=strafe_api.api_account_session_upsert_with_tier_status(p_key_hash,player,p_body->>'playerName',(p_body->>'premium')::boolean,
        p_body->>'sessionHash',clock_timestamp(),180);
      return jsonb_build_object('ok',true,'preferenceSaved',handoff.preference_saved,'account',account);
    end if;
    select * into sess from public.minecraft_account_sessions where player_id=player for update;
    -- A normal newer login supersedes a pending transfer, even if it uses another proxy.
    if not found or sess.session_token_hash<>handoff.source_session_hash then return jsonb_build_object('ok',false,'code','stale_session'); end if;
    started:=greatest(clock_timestamp(),sess.session_started_at+interval '1 millisecond');
    insert into strafe_api.proxy_retired_sessions(player_id,token_hash) values(player,handoff.source_session_hash) on conflict do nothing;
    -- Change only ownership/nonce, then use the normal account API for its existing status/skin handling.
    update public.minecraft_account_sessions set api_key_id=key_id,session_token_hash=p_body->>'sessionHash',
      session_started_at=started,last_seen_at=clock_timestamp(),expires_at=clock_timestamp()+interval '180 seconds',ended_at=null where player_id=player;
    account:=strafe_api.api_account_session_upsert_with_tier_status(p_key_hash,player,p_body->>'playerName',(p_body->>'premium')::boolean,
      p_body->>'sessionHash',started,180);
    if account->>'ok' is distinct from 'true' then raise exception 'account handoff failed' using errcode='22023'; end if;
    if handoff.reason='manual' then
      update strafe_api.proxy_preferences set proxy_id=node.id,revision=revision+1,updated_at=clock_timestamp()
        where player_id=player and pool=node.pool and revision=handoff.preference_revision;
      get diagnostics affected = row_count; saved:=affected>0;
    end if;
    if handoff.reason in ('initial','manual') and handoff.preference_revision=0 then
      insert into strafe_api.proxy_preferences(player_id,pool,proxy_id) values(player,node.pool,node.id) on conflict do nothing;
      if found then saved:=true; end if;
    end if;
    update strafe_api.proxy_handoffs set completed_at=clock_timestamp(),destination_session_hash=p_body->>'sessionHash',preference_saved=saved where id=handoff.id;
    return jsonb_build_object('ok',true,'preferenceSaved',saved,'sessionStartedAt',floor(extract(epoch from started)*1000),'account',account);
  end if;
  raise exception 'invalid proxy action' using errcode='22023';
end;
$$;

-- No direct browser/service-role access to routing state, IP probe jobs or credentials.
revoke all on strafe_api.proxy_nodes,strafe_api.proxy_preferences,strafe_api.proxy_probe_jobs,strafe_api.proxy_probe_results,strafe_api.proxy_handoffs,strafe_api.proxy_retired_sessions from public,anon,authenticated,service_role,strafe_points_runtime,strafe_points_api;
revoke all on function strafe_api.proxy_node_json(strafe_api.proxy_nodes) from public,anon,authenticated,service_role,strafe_points_runtime,strafe_points_api;
revoke all on function strafe_api.api_account_session_upsert_before_proxy_balancer(text,uuid,text,boolean,text,timestamptz,integer) from public,anon,authenticated,service_role,strafe_points_runtime,strafe_points_api;
revoke all on function strafe_api.proxy_balancer_call(text,text,jsonb) from public,anon,authenticated;
grant execute on function strafe_api.proxy_balancer_call(text,text,jsonb) to service_role,strafe_points_runtime,strafe_points_api;
revoke all on function strafe_api.api_account_session_upsert(text,uuid,text,boolean,text,timestamptz,integer) from public,anon,authenticated;
grant execute on function strafe_api.api_account_session_upsert(text,uuid,text,boolean,text,timestamptz,integer) to service_role,strafe_points_runtime,strafe_points_api;
notify pgrst,'reload schema';
