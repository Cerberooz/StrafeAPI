create table strafe_api.proxy_admin_jobs (
  id uuid primary key default gen_random_uuid(),
  requester text not null references strafe_api.proxy_nodes(id),
  requester_instance uuid not null,
  actor uuid not null,
  actor_hash text not null,
  source text not null references strafe_api.proxy_nodes(id),
  source_instance uuid not null,
  command jsonb not null,
  result jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 seconds',
  claimed_at timestamptz
);
create index proxy_admin_pending on strafe_api.proxy_admin_jobs(source, source_instance, created_at) where claimed_at is null;
create index proxy_admin_expiry on strafe_api.proxy_admin_jobs(expires_at);
create index proxy_admin_requester on strafe_api.proxy_admin_jobs(requester, actor, expires_at);
alter table strafe_api.proxy_admin_jobs enable row level security;
revoke all on table strafe_api.proxy_admin_jobs from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

-- Trusted Velocity instances check the actor's game permission. SQL enforces
-- relaying only between registered instances in the same pool and binds each
-- request to the actor's active, credential-owned account session.
create function strafe_api.proxy_admin_call(p_key_hash text,p_action text,p_body jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  key_id uuid;
  node strafe_api.proxy_nodes;
  source_node strafe_api.proxy_nodes;
  job strafe_api.proxy_admin_jobs;
  actor_id uuid;
  request_actor_hash text;
  kind text;
  outcome text;
  payload jsonb;
begin
  key_id := strafe_api.require_point_api_key(p_key_hash,'accounts:write');
  select * into node from strafe_api.proxy_nodes n where n.api_key_id=key_id and n.enabled
    and n.instance_id=(p_body->>'instanceId')::uuid and n.last_seen>=now()-interval '20 seconds';
  if not found then return jsonb_build_object('ok',false,'code','stale_proxy_instance'); end if;
  if p_action in ('admin-submit','admin-status') then
    actor_id := (p_body->>'actorId')::uuid;
    request_actor_hash := p_body->>'actorHash';
    if not exists(select 1 from public.minecraft_account_sessions s where s.player_id=actor_id and s.api_key_id=key_id
      and s.session_token_hash=request_actor_hash and s.ended_at is null and s.expires_at>now()) then
      return jsonb_build_object('ok',false,'code','stale_session');
    end if;
  end if;
  if p_action='admin-submit' then
    -- Serialize admission for this actor and keep the short-lived queue bounded.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('proxy-admin:'||node.id,0));
    if (select count(*) from strafe_api.proxy_admin_jobs j where j.requester=node.id and j.expires_at>now())>=64
      or (select count(*) from strafe_api.proxy_admin_jobs j where j.requester=node.id and j.actor=actor_id
        and j.expires_at>now() and j.result is null)>=3 then
      return jsonb_build_object('ok',false,'code','admin_queue_busy');
    end if;
    select * into source_node from strafe_api.proxy_nodes n where n.id=p_body->>'source' and n.pool=node.pool and n.enabled
      and n.instance_id=(p_body->>'sourceInstance')::uuid and n.last_seen>=now()-interval '20 seconds';
    if not found then return jsonb_build_object('ok',false,'code','source_unavailable'); end if;
    kind := p_body->>'kind';
    if kind='roster' then
      payload := jsonb_build_object('kind',kind,'offset',(p_body->>'offset')::int);
    elsif kind in ('move','drain') then
      if not exists(select 1 from strafe_api.proxy_nodes n where n.id=p_body->>'destination' and n.id<>source_node.id
        and n.pool=node.pool and n.enabled and n.state='READY' and n.players<n.capacity
        and n.instance_id=(p_body->>'destinationInstance')::uuid and n.last_seen>=now()-interval '20 seconds') then
        return jsonb_build_object('ok',false,'code','destination_unavailable');
      end if;
      payload := jsonb_build_object('kind',kind,'destination',p_body->>'destination',
        'destinationInstance',(p_body->>'destinationInstance')::uuid);
      if kind='move' then
        payload := payload || jsonb_build_object('playerId',(p_body->>'playerId')::uuid,'connectionId',(p_body->>'connectionId')::uuid);
      end if;
    else
      return jsonb_build_object('ok',false,'code','invalid_admin_action');
    end if;
    insert into strafe_api.proxy_admin_jobs(requester,requester_instance,actor,actor_hash,source,source_instance,command)
      values(node.id,node.instance_id,actor_id,request_actor_hash,source_node.id,source_node.instance_id,payload) returning * into job;
    return jsonb_build_object('ok',true,'jobId',job.id);
  elsif p_action='admin-poll' then
    delete from strafe_api.proxy_admin_jobs where id in
      (select id from strafe_api.proxy_admin_jobs where expires_at<=now() order by expires_at limit 64 for update skip locked);
    with pending as (
      select j.id from strafe_api.proxy_admin_jobs j
      join strafe_api.proxy_nodes n on n.id=j.requester
      join public.minecraft_account_sessions s on s.player_id=j.actor and s.api_key_id=n.api_key_id and s.session_token_hash=j.actor_hash
      where j.source=node.id and j.source_instance=node.instance_id and j.claimed_at is null and j.expires_at>now()
        and n.enabled and n.pool=node.pool and n.instance_id=j.requester_instance and n.last_seen>=now()-interval '20 seconds'
        and s.ended_at is null and s.expires_at>now()
      order by j.created_at limit 1 for update of j skip locked
    )
    update strafe_api.proxy_admin_jobs j set claimed_at=now() from pending where j.id=pending.id returning j.* into job;
    return jsonb_build_object('ok',true,'job',case when job.id is not null then
      job.command || jsonb_build_object('jobId',job.id,'actorId',job.actor,
        'expiresAtMs',floor(extract(epoch from job.expires_at)*1000)::bigint) end);
  elsif p_action='admin-result' then
    outcome := p_body->>'outcome';
    update strafe_api.proxy_admin_jobs j set result=
      case when outcome='roster' then jsonb_build_object('outcome',outcome,'players',p_body->'players','total',p_body->'total')
           else jsonb_build_object('outcome',outcome) end
      where j.id=(p_body->>'jobId')::uuid and j.source=node.id and j.source_instance=node.instance_id
        and j.claimed_at is not null and j.result is null and j.expires_at>now()
        and (outcome in ('unavailable','player_left','move_failed','already_draining')
          or (outcome='roster' and j.command->>'kind'='roster')
          or (outcome='move_sent' and j.command->>'kind'='move')
          or (outcome='drain_started' and j.command->>'kind'='drain'));
    return jsonb_build_object('ok',found);
  elsif p_action='admin-status' then
    select * into job from strafe_api.proxy_admin_jobs j where j.id=(p_body->>'jobId')::uuid
      and j.requester=node.id and j.requester_instance=node.instance_id and j.actor=actor_id
      and j.actor_hash=request_actor_hash and j.expires_at>now();
    if not found then return jsonb_build_object('ok',false,'code','admin_request_expired'); end if;
    return jsonb_build_object('ok',true,'result',job.result);
  end if;
  return jsonb_build_object('ok',false,'code','invalid_admin_action');
end;
$$;
revoke all on function strafe_api.proxy_admin_call(text,text,jsonb) from public,anon,authenticated;
grant execute on function strafe_api.proxy_admin_call(text,text,jsonb) to service_role,strafe_points_runtime,strafe_points_api;
