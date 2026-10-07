-- Automatic cracked skin mirroring permits one update per rolling 30 minutes.

-- Explicit commands retain the independent three-per-minute limit.

-- Proxy configuration may choose a longer polling interval.

create or replace function strafe_api.api_account_session_upsert(
  p_key_hash text, p_player_id uuid, p_player_name text, p_premium boolean, p_session_token_hash text,
  p_session_started_at timestamptz, p_ttl_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_expires timestamptz;
  v_session_started timestamptz;
  v_account record;
  v_skin record;
  v_next_change timestamptz;
  v_skin_status text := 'none';
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  if p_player_id is null or p_player_name is null or p_player_name !~ '^[A-Za-z0-9_]{1,16}$'
      or p_premium is null or p_session_token_hash !~ '^[0-9a-f]{64}$' or p_session_started_at is null
      or p_session_started_at > pg_catalog.now() + interval '5 minutes'
      or p_ttl_seconds is null or p_ttl_seconds not between 90 and 600 then
    raise exception 'invalid account session' using errcode = '22023';
  end if;
  insert into public.minecraft_accounts(player_id, player_name, premium)
  values (p_player_id, p_player_name, p_premium)
  on conflict (player_id) do nothing;

  insert into public.minecraft_account_sessions(player_id, api_key_id, session_token_hash, session_started_at, last_seen_at, expires_at)
  values (p_player_id, v_key_id, p_session_token_hash, p_session_started_at, pg_catalog.now(), pg_catalog.now() + pg_catalog.make_interval(secs => p_ttl_seconds))
  on conflict (player_id) do update
    set api_key_id = excluded.api_key_id,
        session_token_hash = excluded.session_token_hash,
        session_started_at = case when public.minecraft_account_sessions.session_token_hash = excluded.session_token_hash
          then public.minecraft_account_sessions.session_started_at else excluded.session_started_at end,
        last_seen_at = pg_catalog.clock_timestamp(),
        expires_at = pg_catalog.clock_timestamp() + pg_catalog.make_interval(secs => p_ttl_seconds),
        ended_at = null
    where (public.minecraft_account_sessions.api_key_id = excluded.api_key_id and
      ((public.minecraft_account_sessions.session_token_hash = excluded.session_token_hash
          and public.minecraft_account_sessions.ended_at is null)
        or (public.minecraft_account_sessions.session_token_hash <> excluded.session_token_hash
          and (excluded.session_started_at > public.minecraft_account_sessions.session_started_at
            or (public.minecraft_account_sessions.ended_at is not null
              and excluded.session_started_at = public.minecraft_account_sessions.session_started_at)))))
      or (public.minecraft_account_sessions.api_key_id <> excluded.api_key_id
        and (public.minecraft_account_sessions.ended_at is not null
          or public.minecraft_account_sessions.expires_at <= pg_catalog.now())
        and excluded.session_started_at > public.minecraft_account_sessions.session_started_at)
  returning expires_at, session_started_at into v_expires, v_session_started;

  if v_expires is null then
    if exists (select 1 from public.minecraft_account_sessions s where s.player_id = p_player_id and s.api_key_id <> v_key_id) then
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'session_owned_by_other_key');
    end if;
    if exists (select 1 from public.minecraft_account_sessions s where s.player_id = p_player_id
        and s.session_started_at > p_session_started_at) then
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'stale_session');
    end if;
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'session_conflict');
  end if;
  update public.minecraft_accounts set player_name = p_player_name, premium = p_premium, updated_at = pg_catalog.now()
    where player_id = p_player_id;
  select player_id, player_name, premium, discord_id into v_account
    from public.minecraft_accounts where player_id = p_player_id;
  select texture_hash, model, texture_value, texture_signature, updated_at into v_skin
    from public.account_skins where player_id = p_player_id;
  if found then
    v_next_change := v_skin.updated_at + interval '30 minutes';
    v_skin_status := case when v_next_change > pg_catalog.now() then 'cooldown' else 'available' end;
  end if;
  return pg_catalog.jsonb_build_object(
    'ok', true,
    'playerId', v_account.player_id,
    'playerName', v_account.player_name,
    'premium', v_account.premium,
    'linked', v_account.discord_id is not null,
    'sessionAvailable', true,
    'sessionExpiresAt', v_expires,
    'nextSkinChangeAt', v_next_change,
    'skin', pg_catalog.jsonb_build_object(
      'status', v_skin_status, 'model', v_skin.model,
      'textureValue', v_skin.texture_value, 'textureSignature', v_skin.texture_signature,
      'textureUrl', case when v_skin.texture_hash is null then null else 'https://textures.minecraft.net/texture/' || v_skin.texture_hash end,
      'portraitUrl', case when v_skin.texture_hash is null then null else '/v1/accounts/portraits/' || v_skin.texture_hash || '/' || v_skin.model || '.png' end,
      'updatedAt', v_skin.updated_at
    )
  );
end;
$$;

create or replace function strafe_api.api_get_account(p_key_hash text, p_player_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_account record;
  v_skin record;
  v_next_change timestamptz;
  v_skin_status text := 'none';
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'accounts:read');
  select player_id, player_name, premium, discord_id
    into v_account from public.minecraft_accounts where player_id = p_player_id;
  if not found then
    return pg_catalog.jsonb_build_object(
      'playerId', p_player_id, 'playerName', null, 'premium', null, 'linked', false,
      'sessionAvailable', false, 'sessionExpiresAt', null, 'nextSkinChangeAt', null,
      'skin', pg_catalog.jsonb_build_object('status', 'none', 'model', null, 'textureValue', null,
        'textureSignature', null, 'textureUrl', null, 'portraitUrl', null, 'updatedAt', null)
    );
  end if;
  select expires_at into v_session from public.minecraft_account_sessions
   where player_id = p_player_id and expires_at > pg_catalog.now() and ended_at is null;
  select texture_hash, model, texture_value, texture_signature, updated_at
    into v_skin from public.account_skins where player_id = p_player_id;
  if found then
    v_next_change := v_skin.updated_at + interval '30 minutes';
    v_skin_status := case when v_next_change > pg_catalog.now() then 'cooldown' else 'available' end;
  end if;
  return pg_catalog.jsonb_build_object(
    'playerId', v_account.player_id,
    'playerName', v_account.player_name,
    'premium', v_account.premium,
    'linked', v_account.discord_id is not null,
    'sessionAvailable', v_session.expires_at is not null,
    'sessionExpiresAt', v_session.expires_at,
    'nextSkinChangeAt', v_next_change,
    'skin', pg_catalog.jsonb_build_object(
      'status', v_skin_status,
      'model', v_skin.model,
      'textureValue', v_skin.texture_value,
      'textureSignature', v_skin.texture_signature,
      'textureUrl', case when v_skin.texture_hash is null then null else 'https://textures.minecraft.net/texture/' || v_skin.texture_hash end,
      'portraitUrl', case when v_skin.texture_hash is null then null else '/v1/accounts/portraits/' || v_skin.texture_hash || '/' || v_skin.model || '.png' end,
      'updatedAt', v_skin.updated_at
    )
  );
end;
$$;

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
  if btrim(p_input) <> 'skinsrestorer-current' then
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
  select api_key_id, player_id, input, status, expires_at, commit_fingerprint, result
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
  if v_request.input = 'skinsrestorer-current' and exists (select 1 from public.account_skins where player_id = p_player_id and updated_at + interval '30 minutes' > pg_catalog.now()) then
    select updated_at + interval '30 minutes' into v_next_change from public.account_skins where player_id = p_player_id;
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_cooldown', 'nextSkinChangeAt', v_next_change,
      'retryAfterSeconds', greatest(1, ceil(extract(epoch from (v_next_change - pg_catalog.now())))::integer));
  end if;
  insert into public.account_skins(player_id, texture_hash, model, texture_value, texture_signature, updated_at)
    values (p_player_id, p_texture_hash, p_model, p_texture_value, p_texture_signature, pg_catalog.now())
  on conflict (player_id) do update set texture_hash = excluded.texture_hash, model = excluded.model,
    texture_value = excluded.texture_value, texture_signature = excluded.texture_signature, updated_at = pg_catalog.now();
  v_next_change := pg_catalog.now() + interval '30 minutes';
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
