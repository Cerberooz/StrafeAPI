-- Mirror authenticated SkinsRestorer apply events without the periodic mirror cooldown.
-- SkinsRestorer owns command cooldowns; existing session, scope, reservation and
-- premium checks remain in force. Periodic reconciliation retains its cooldown.
create or replace function strafe_api.api_prepare_account_skin(
  p_key_hash text, p_player_id uuid, p_session_token_hash text, p_request_id uuid, p_input text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_existing record;
  v_active record;
  v_last_attempt timestamptz;
  v_attempts timestamptz[];
  v_updated timestamptz;
  v_next_change timestamptz;
  v_retry integer;
  v_session record;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  if p_player_id is null or p_request_id is null or p_input is null or length(btrim(p_input)) not between 1 and 2048
      or p_session_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid skin prepare request' using errcode = '22023';
  end if;
  select player_id into v_session from public.minecraft_account_sessions s where s.player_id = p_player_id
      and s.api_key_id = v_key_id and s.session_token_hash = p_session_token_hash and s.expires_at > pg_catalog.now()
      and s.ended_at is null for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'session_unavailable');
  end if;
  if not exists (select 1 from public.minecraft_accounts a where a.player_id = p_player_id and not a.premium) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'premium_skin_managed_by_minecraft');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(p_player_id::text));
  delete from public.account_skin_requests where status <> 'reserved' and created_at < pg_catalog.now() - interval '90 days';
  select api_key_id, player_id, input, status, expires_at, result, commit_fingerprint
    into v_existing from public.account_skin_requests where request_id = p_request_id for update;
  if found then
    if v_existing.api_key_id <> v_key_id or v_existing.player_id <> p_player_id or v_existing.input <> btrim(p_input) then
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'idempotency_conflict');
    end if;
    if v_existing.status = 'reserved' and v_existing.expires_at <= pg_catalog.now() then
      update public.account_skin_requests set status = 'expired' where request_id = p_request_id;
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_reservation_expired');
    end if;
    if v_existing.status = 'committed' then return coalesce(v_existing.result, '{}'::jsonb) || pg_catalog.jsonb_build_object('duplicate', true); end if;
    if v_existing.status <> 'reserved' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_request_not_active'); end if;
    return pg_catalog.jsonb_build_object('ok', true, 'requestId', p_request_id, 'expiresAt', v_existing.expires_at,
      'nextSkinChangeAt', null, 'duplicate', true);
  end if;

  if btrim(p_input) = 'skinsrestorer-current' then
  insert into public.account_skin_throttles(player_id, last_attempt_at)
  values (p_player_id, pg_catalog.now())
  on conflict (player_id) do update set last_attempt_at = pg_catalog.now()
    where public.account_skin_throttles.last_attempt_at <= pg_catalog.now() - interval '10 seconds'
  returning last_attempt_at into v_last_attempt;
  if v_last_attempt is null then
    select last_attempt_at into v_last_attempt from public.account_skin_throttles where player_id = p_player_id;
    v_retry := greatest(1, ceil(extract(epoch from (v_last_attempt + interval '10 seconds' - pg_catalog.now())))::integer);
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_request_throttled', 'retryAfterSeconds', v_retry);
  end if;

  select updated_at into v_updated from public.account_skins where player_id = p_player_id;
  if found and v_updated + interval '30 minutes' > pg_catalog.now() then
    v_next_change := v_updated + interval '30 minutes';
    v_retry := greatest(1, ceil(extract(epoch from (v_next_change - pg_catalog.now())))::integer);
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_cooldown', 'nextSkinChangeAt', v_next_change,
      'retryAfterSeconds', v_retry);
  end if;
  end if;
  select request_id, expires_at into v_active from public.account_skin_requests
    where player_id = p_player_id and status = 'reserved' and expires_at > pg_catalog.now() for update;
  if found then
    v_retry := greatest(1, ceil(extract(epoch from (v_active.expires_at - pg_catalog.now())))::integer);
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_request_in_progress', 'retryAfterSeconds', v_retry);
  end if;
  update public.account_skin_requests set status = 'expired'
    where player_id = p_player_id and status = 'reserved' and expires_at <= pg_catalog.now();
  if btrim(p_input) not in ('skinsrestorer-current', 'skinsrestorer-event') then
    insert into public.account_skin_throttles(player_id, last_attempt_at)
      values (p_player_id, pg_catalog.now()) on conflict (player_id) do nothing;
    select coalesce(array_agg(attempt order by attempt), '{}'::timestamptz[])
      into v_attempts
      from public.account_skin_throttles t,
        lateral unnest(t.command_attempts) as recent(attempt)
      where t.player_id = p_player_id and attempt > pg_catalog.now() - interval '60 seconds';
    if cardinality(v_attempts) >= 3 then
      v_retry := greatest(1, ceil(extract(epoch from (v_attempts[1] + interval '60 seconds' - pg_catalog.now())))::integer);
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_command_rate_limited', 'retryAfterSeconds', v_retry);
    end if;
    update public.account_skin_throttles
      set command_attempts = array_append(v_attempts, pg_catalog.now()), last_attempt_at = pg_catalog.now()
      where player_id = p_player_id;
  end if;
  insert into public.account_skin_requests(request_id, player_id, api_key_id, input, status, expires_at)
    values (p_request_id, p_player_id, v_key_id, btrim(p_input), 'reserved', pg_catalog.now() + interval '5 minutes');
  return pg_catalog.jsonb_build_object('ok', true, 'requestId', p_request_id,
    'expiresAt', pg_catalog.now() + interval '5 minutes', 'nextSkinChangeAt', null, 'duplicate', false);
end;
$$;

notify pgrst, 'reload schema';
