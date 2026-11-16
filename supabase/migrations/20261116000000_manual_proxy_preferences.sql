alter table strafe_api.proxy_preferences
  add column selected_manually boolean not null default false;

-- The old automatic writes could only create revision 1. For revision 1,
-- a retained successful manual handoff proves that the player made the choice.
update strafe_api.proxy_preferences p
set selected_manually=true
where p.revision>1 or exists (
  select 1 from strafe_api.proxy_handoffs h
  where h.player_id=p.player_id and h.pool=p.pool and h.target_proxy=p.proxy_id
    and h.reason='manual' and h.preference_saved and h.completed_at is not null
    and h.preference_revision=0
);

do $migration$
declare
  definition text;
  previous text[] := array[
    $old$'proxyId',pref.proxy_id,'revision',coalesce(pref.revision,0)$old$,
    $old$  if p_action='preference-save' then
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
  end if;$old$,
    $old$  if p_action='handoff-create' then$old$,
    $old$      update strafe_api.proxy_preferences set proxy_id=node.id,revision=revision+1,updated_at=clock_timestamp()$old$,
    $old$    if handoff.reason in ('initial','manual') and handoff.preference_revision=0 then
      insert into strafe_api.proxy_preferences(player_id,pool,proxy_id) values(player,node.pool,node.id) on conflict do nothing;$old$
  ];
  replacement text[] := array[
    $new$'proxyId',case when pref.selected_manually then pref.proxy_id end,'revision',coalesce(pref.revision,0)$new$,
    $new$  if p_action='preference-save' then
    -- Old Velocity versions may ask to save an automatic default during rollout.
    return jsonb_build_object('ok',true,'preferenceSaved',false);
  end if;$new$,
    $new$  if p_action='handoff-create' then
    if p_body->>'reason'='initial' then
      return jsonb_build_object('ok',false,'code','initial_routing_disabled');
    end if;$new$,
    $new$      update strafe_api.proxy_preferences
      set proxy_id=node.id,revision=revision+1,updated_at=clock_timestamp(),selected_manually=true$new$,
    $new$    if handoff.reason='manual' and handoff.preference_revision=0 then
      insert into strafe_api.proxy_preferences(player_id,pool,proxy_id,selected_manually)
      values(player,node.pool,node.id,true) on conflict do nothing;$new$
  ];
begin
  definition := replace(pg_catalog.pg_get_functiondef('strafe_api.proxy_balancer_call_before_discovery(text,text,jsonb)'::regprocedure), E'\r\n', E'\n');
  for i in 1..array_length(previous,1) loop
    if position(previous[i] in definition)=0 then
      raise exception 'Unexpected proxy preference implementation at replacement %', i;
    end if;
    definition:=replace(definition,previous[i],replacement[i]);
  end loop;
  execute definition;
end;
$migration$;
