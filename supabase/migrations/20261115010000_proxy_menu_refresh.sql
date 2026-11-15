-- Refresh estimates on every selector opening. Share a still-running probe instead
-- of blocking the player for 30 seconds; retain authenticated sessions and the
-- per-source cap. Alter the preserved implementation without changing its OID.
do $migration$
declare
  definition text;
  previous text := $old$    if exists(select 1 from strafe_api.proxy_probe_jobs where player_id=player and source_proxy=node.id and created_at>now()-interval '30 seconds')
      or (select count(*) from strafe_api.proxy_probe_jobs where source_proxy=node.id and expires_at>now())>=32 then$old$;
  replacement text := $new$    select * into job from strafe_api.proxy_probe_jobs
      where player_id=player and source_proxy=node.id and expires_at>now()
        and ip=(p_body->>'ip')::inet order by created_at desc limit 1;
    if found then
      return jsonb_build_object('ok',true,'id',job.id);
    end if;
    if (select count(*) from strafe_api.proxy_probe_jobs where source_proxy=node.id and expires_at>now())>=32 then$new$;
begin
  definition := replace(pg_catalog.pg_get_functiondef('strafe_api.proxy_balancer_call_before_discovery(text,text,jsonb)'::regprocedure), E'\r\n', E'\n');
  if position(previous in definition)=0 then
    raise exception 'Unexpected proxy probe admission implementation';
  end if;
  execute replace(definition,previous,replacement);
end;
$migration$;
