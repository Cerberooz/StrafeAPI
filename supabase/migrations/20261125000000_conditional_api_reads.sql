-- Additive transport optimization. Existing API/plugin contracts and RPCs remain unchanged.
-- Execute the original scoped operation BEFORE comparing digests: authorization,
-- revocation, bans, region checks, heartbeat leases and probe cleanup stay current.
create function strafe_api.api_read_if_changed(
  p_key_hash text, p_call text, p_parameters jsonb, p_digest text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_result jsonb;
  v_catalog jsonb;
  v_digest text;
  v_ids uuid[];
  v_live constant text[] := array['state','players','cpu','heap','schedulerDelayMs','readyBackends','instanceId','lastSeen'];
begin
  if p_call in ('get_points_snapshot','get_points_leaderboard_for_season','get_smp_leaderboard_seasons') then
    v_result := strafe_api.regional_points_call(p_key_hash, p_parameters->>'p_region', p_call, p_parameters);
  elsif p_call = 'get_tier_ban_statuses' then
    select array_agg(value::uuid order by ordinality) into v_ids
      from jsonb_array_elements_text(p_parameters->'p_player_ids') with ordinality;
    v_result := strafe_api.api_get_tier_ban_statuses(p_key_hash, v_ids);
  elsif p_call = 'proxy_balancer' and p_parameters->>'p_action' in ('heartbeat','catalog','probe-jobs') then
    v_result := strafe_api.proxy_balancer_call(p_key_hash, p_parameters->>'p_action', p_parameters->'p_body');
    if v_result->>'ok' = 'true' and jsonb_typeof(v_result->'proxies') = 'array' then
      select coalesce(jsonb_agg(node - v_live order by ordinal), '[]'::jsonb) into v_catalog
        from jsonb_array_elements(v_result->'proxies') with ordinality as nodes(node, ordinal);
      v_digest := encode(sha256(convert_to(v_catalog::text, 'UTF8')), 'hex');
      if p_digest = v_digest then
        -- Send every live field and any newly introduced field. Names, addresses,
        -- head textures and backend definitions come from the validated catalog.
        select coalesce(jsonb_agg((select jsonb_object_agg(key, value) from jsonb_each(node)
          where key = 'id' or key = any(v_live)) order by ordinal), '[]'::jsonb) into v_catalog
          from jsonb_array_elements(v_result->'proxies') with ordinality as nodes(node, ordinal);
        v_result := jsonb_set(v_result, '{proxies}', v_catalog);
      end if;
      return jsonb_build_object('mode','proxy-catalog','digest',v_digest,'notModified',coalesce(p_digest=v_digest,false),'value',v_result);
    end if;
  else
    raise exception 'Unsupported conditional read' using errcode = '22023';
  end if;
  v_digest := encode(sha256(convert_to(v_result::text, 'UTF8')), 'hex');
  if p_digest = v_digest then
    return jsonb_build_object('mode','value','digest',v_digest,'notModified',true);
  end if;
  return jsonb_build_object('mode','value','digest',v_digest,'notModified',false,'value',v_result);
end;
$$;

revoke all on function strafe_api.api_read_if_changed(text,text,jsonb,text)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
grant execute on function strafe_api.api_read_if_changed(text,text,jsonb,text) to service_role, strafe_points_runtime;
notify pgrst, 'reload schema';
