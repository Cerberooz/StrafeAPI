-- Skin selection runs on Velocity. Only authenticated cracked identities can write skins.
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
  if found and v_updated + interval '24 hours' > pg_catalog.now() then
    v_next_change := v_updated + interval '24 hours';
    v_retry := greatest(1, ceil(extract(epoch from (v_next_change - pg_catalog.now())))::integer);
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_cooldown', 'nextSkinChangeAt', v_next_change,
      'retryAfterSeconds', v_retry);
  end if;
  select request_id, expires_at into v_active from public.account_skin_requests
    where player_id = p_player_id and status = 'reserved' and expires_at > pg_catalog.now() for update;
  if found then
    v_retry := greatest(1, ceil(extract(epoch from (v_active.expires_at - pg_catalog.now())))::integer);
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_request_in_progress', 'retryAfterSeconds', v_retry);
  end if;
  update public.account_skin_requests set status = 'expired'
    where player_id = p_player_id and status = 'reserved' and expires_at <= pg_catalog.now();
  insert into public.account_skin_requests(request_id, player_id, api_key_id, input, status, expires_at)
    values (p_request_id, p_player_id, v_key_id, btrim(p_input), 'reserved', pg_catalog.now() + interval '5 minutes');
  return pg_catalog.jsonb_build_object('ok', true, 'requestId', p_request_id,
    'expiresAt', pg_catalog.now() + interval '5 minutes', 'nextSkinChangeAt', null, 'duplicate', false);
end;
$$;

create or replace function strafe_api.api_commit_account_skin(
  p_key_hash text, p_player_id uuid, p_session_token_hash text, p_request_id uuid,
  p_texture_hash text, p_model text, p_texture_value text, p_texture_signature text, p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_request record;
  v_result jsonb;
  v_next_change timestamptz;
  v_session record;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  if p_texture_hash !~ '^[0-9a-f]{40,64}$' or p_model not in ('classic', 'slim')
      or p_texture_value is null or length(p_texture_value) not between 1 and 8192
      or p_texture_signature is null or length(p_texture_signature) not between 1 and 8192
      or p_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid canonical skin' using errcode = '22023';
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
  select api_key_id, player_id, status, expires_at, commit_fingerprint, result
    into v_request from public.account_skin_requests where request_id = p_request_id for update;
  if not found or v_request.api_key_id <> v_key_id or v_request.player_id <> p_player_id then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_reservation_not_found');
  end if;
  if v_request.status = 'committed' then
    if v_request.commit_fingerprint <> p_fingerprint then
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'idempotency_conflict');
    end if;
    return v_request.result || pg_catalog.jsonb_build_object('duplicate', true);
  end if;
  if v_request.status <> 'reserved' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_reservation_not_active'); end if;
  if v_request.expires_at <= pg_catalog.now() then
    update public.account_skin_requests set status = 'expired' where request_id = p_request_id;
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_reservation_expired');
  end if;
  if exists (select 1 from public.account_skins where player_id = p_player_id and updated_at + interval '24 hours' > pg_catalog.now()) then
    select updated_at + interval '24 hours' into v_next_change from public.account_skins where player_id = p_player_id;
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_cooldown', 'nextSkinChangeAt', v_next_change,
      'retryAfterSeconds', greatest(1, ceil(extract(epoch from (v_next_change - pg_catalog.now())))::integer));
  end if;
  insert into public.account_skins(player_id, texture_hash, model, texture_value, texture_signature, updated_at)
    values (p_player_id, p_texture_hash, p_model, p_texture_value, p_texture_signature, pg_catalog.now())
  on conflict (player_id) do update set texture_hash = excluded.texture_hash, model = excluded.model,
    texture_value = excluded.texture_value, texture_signature = excluded.texture_signature, updated_at = pg_catalog.now();
  v_next_change := pg_catalog.now() + interval '24 hours';
  v_result := pg_catalog.jsonb_build_object('ok', true, 'status', 'completed', 'requestId', p_request_id,
    'textureHash', p_texture_hash, 'model', p_model,
    'textureUrl', 'https://textures.minecraft.net/texture/' || p_texture_hash,
    'portraitUrl', '/v1/accounts/portraits/' || p_texture_hash || '/' || p_model || '.png',
    'textureValue', p_texture_value, 'textureSignature', p_texture_signature,
    'nextSkinChangeAt', v_next_change, 'duplicate', false);
  update public.account_skin_requests set status = 'committed', commit_fingerprint = p_fingerprint, result = v_result
    where request_id = p_request_id;
  return v_result;
end;
$$;
notify pgrst, 'reload schema';
