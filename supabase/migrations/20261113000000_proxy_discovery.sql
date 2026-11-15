-- Self-registration reuses each proxy's existing account key. Durable identities,
-- preferences and tickets stay in PostgreSQL; expiring health lives in Redis.
-- Preserve the original RPC OID so existing callers gain these checks too.
do $$ declare definition text; begin
  definition:=pg_catalog.pg_get_functiondef('strafe_api.proxy_balancer_call(text,text,jsonb)'::regprocedure);
  definition:=replace(definition,'FUNCTION strafe_api.proxy_balancer_call(',
    'FUNCTION strafe_api.proxy_balancer_call_before_discovery(');
  definition:=replace(definition,'where pool=node.pool and enabled)>9', 'where pool=node.pool and enabled)>54');
  definition:=replace(definition,'or target.instance_id is null or node.instance_id is null',
    'or target.instance_id is null or node.instance_id is null or (p_body ? ''targetInstanceId'' and target.instance_id is distinct from (p_body->>''targetInstanceId'')::uuid)');
  execute definition;
end; $$;

create or replace function strafe_api.proxy_balancer_call(p_key_hash text,p_action text,p_body jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  key_id uuid; registration jsonb; node strafe_api.proxy_nodes; existing strafe_api.proxy_nodes;
begin
  key_id:=strafe_api.require_point_api_key(p_key_hash,'accounts:write');
  if p_action='heartbeat' and p_body ? 'registration' then
    registration:=p_body->'registration';
    if jsonb_typeof(registration)<>'object' or octet_length(p_body::text)>32768
      or registration->>'id' !~ '^[a-z0-9][a-z0-9_-]{0,47}$'
      or registration->>'pool' !~ '^[a-z0-9][a-z0-9_-]{0,47}$'
      or jsonb_typeof(registration->'backends')<>'object' then
      raise exception 'invalid proxy registration' using errcode='22023';
    end if;
    -- Serialize pool admission and identity claims across API replicas.
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('proxy-registration',0));
    select * into existing from strafe_api.proxy_nodes where id=registration->>'id';
    select * into node from strafe_api.proxy_nodes where api_key_id=key_id for update;
    if node.id is not null and (node.id<>registration->>'id' or node.pool<>registration->>'pool' or not node.enabled)
      or existing.id is not null and existing.api_key_id<>key_id then
      return jsonb_build_object('ok',false,'code','proxy_identity_conflict');
    end if;
    if node.id is null then
      if (select count(*) from strafe_api.proxy_nodes where pool=registration->>'pool' and enabled)>=54 then
        return jsonb_build_object('ok',false,'code','invalid_pool_configuration');
      end if;
      insert into strafe_api.proxy_nodes(id,pool,api_key_id,region,name,host,port,priority,capacity,head_texture,backends)
      values(registration->>'id',registration->>'pool',key_id,registration->>'region',registration->>'name',
        registration->>'host',(registration->>'port')::int,(registration->>'priority')::int,
        (registration->>'capacity')::int,registration->>'headTexture',registration->'backends');
    else
      -- A late former process must not change the endpoint before the heartbeat fence runs.
      if node.instance_id is not null and node.last_seen>=now()-interval '20 seconds'
        and (node.instance_id is distinct from (p_body->>'instanceId')::uuid or node.sequence>=(p_body->>'sequence')::bigint) then
        return jsonb_build_object('ok',false,'code','stale_proxy_instance');
      end if;
      update strafe_api.proxy_nodes set region=registration->>'region',name=registration->>'name',host=registration->>'host',
        port=(registration->>'port')::int,priority=(registration->>'priority')::int,capacity=(registration->>'capacity')::int,
        head_texture=registration->>'headTexture',backends=registration->'backends' where id=node.id;
    end if;
  end if;
  return strafe_api.proxy_balancer_call_before_discovery(p_key_hash,p_action,p_body);
end;
$$;
revoke all on function strafe_api.proxy_balancer_call_before_discovery(text,text,jsonb) from public,anon,authenticated,service_role,strafe_points_runtime,strafe_points_api;
revoke all on function strafe_api.proxy_balancer_call(text,text,jsonb) from public,anon,authenticated;
grant execute on function strafe_api.proxy_balancer_call(text,text,jsonb) to service_role,strafe_points_runtime,strafe_points_api;
