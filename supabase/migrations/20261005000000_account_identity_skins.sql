-- Minecraft account identity, trusted server presence, Discord linking and canonical skins.
-- The API runtime receives execute permission on fixed SECURITY DEFINER functions only.

create table if not exists public.minecraft_accounts (
  player_id uuid primary key,
  player_name text not null check (player_name ~ '^[A-Za-z0-9_]{1,16}$'),
  premium boolean not null,
  discord_id text unique check (discord_id is null or discord_id ~ '^[0-9]{17,20}$'),
  discord_display_name text check (discord_display_name is null or length(discord_display_name) between 1 and 100),
  linked_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  check ((discord_id is null and discord_display_name is null and linked_at is null)
      or (discord_id is not null and discord_display_name is not null and linked_at is not null))
);

create table if not exists public.minecraft_account_sessions (
  player_id uuid primary key references public.minecraft_accounts(player_id) on delete cascade,
  api_key_id uuid not null,
  session_token_hash text not null check (session_token_hash ~ '^[0-9a-f]{64}$'),
  session_started_at timestamptz not null,
  last_seen_at timestamptz not null,
  expires_at timestamptz not null,
  ended_at timestamptz,
  check (ended_at is not null or expires_at > last_seen_at)
);

create index if not exists minecraft_account_sessions_expiry_idx
  on public.minecraft_account_sessions(expires_at);

create table if not exists public.account_link_requests (
  request_id uuid primary key default pg_catalog.gen_random_uuid(),
  player_id uuid not null references public.minecraft_accounts(player_id) on delete cascade,
  api_key_id uuid not null,
  purpose text not null check (purpose in ('link', 'change')),
  status text not null check (status in ('awaiting_discord', 'awaiting_old_discord', 'awaiting_new_discord', 'awaiting_confirmation', 'completed', 'expired', 'cancelled')),
  old_discord_id text,
  new_discord_id text,
  discord_display_name text,
  old_verified_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null default (pg_catalog.now() + interval '15 minutes'),
  completed_at timestamptz,
  check (old_discord_id is null or old_discord_id ~ '^[0-9]{17,20}$'),
  check (new_discord_id is null or new_discord_id ~ '^[0-9]{17,20}$'),
  check (discord_display_name is null or length(discord_display_name) between 1 and 100),
  check (expires_at > created_at)
);

create index if not exists account_link_requests_player_created_idx
  on public.account_link_requests(player_id, created_at desc);
create index if not exists account_link_requests_expires_idx
  on public.account_link_requests(expires_at);
create index if not exists account_link_requests_terminal_created_idx
  on public.account_link_requests(created_at)
  where status in ('completed', 'expired', 'cancelled');

create table if not exists public.account_oauth_states (
  state_hash text primary key check (state_hash ~ '^[0-9a-f]{64}$'),
  request_id uuid not null references public.account_link_requests(request_id) on delete cascade,
  step text not null check (step in ('old', 'new')),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null default (pg_catalog.now() + interval '10 minutes'),
  used_at timestamptz,
  check (expires_at > created_at)
);
create index if not exists account_oauth_states_expires_idx
  on public.account_oauth_states(expires_at);
create index if not exists account_oauth_states_used_idx
  on public.account_oauth_states(used_at) where used_at is not null;
create index if not exists account_oauth_states_request_idx
  on public.account_oauth_states(request_id);

create table if not exists public.account_link_audit (
  audit_id bigint generated always as identity primary key,
  player_id uuid not null,
  actor_api_key_id uuid not null,
  action text not null check (action in ('link', 'change', 'admin_recovery')),
  old_discord_id text,
  new_discord_id text,
  reason text check (reason is null or length(reason) between 1 and 500),
  created_at timestamptz not null default pg_catalog.now()
);

create index if not exists account_link_audit_player_created_idx
  on public.account_link_audit(player_id, created_at desc);

create table if not exists public.account_skins (
  player_id uuid primary key references public.minecraft_accounts(player_id) on delete cascade,
  texture_hash text not null check (texture_hash ~ '^[0-9a-f]{40,64}$'),
  model text not null check (model in ('classic', 'slim')),
  texture_value text not null check (length(texture_value) between 1 and 8192),
  texture_signature text not null check (length(texture_signature) between 1 and 8192),
  updated_at timestamptz not null default pg_catalog.now()
);
create index if not exists account_skins_texture_model_idx
  on public.account_skins(texture_hash, model);

create table if not exists public.account_skin_requests (
  request_id uuid primary key,
  player_id uuid not null references public.minecraft_accounts(player_id) on delete cascade,
  api_key_id uuid not null,
  input text not null check (length(input) between 1 and 2048),
  status text not null check (status in ('reserved', 'committed', 'cancelled', 'expired')),
  created_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null,
  commit_fingerprint text check (commit_fingerprint is null or commit_fingerprint ~ '^[0-9a-f]{64}$'),
  result jsonb,
  check (expires_at > created_at)
);

create unique index if not exists account_skin_requests_one_reserved_per_player_idx
  on public.account_skin_requests(player_id) where status = 'reserved';
create index if not exists account_skin_requests_terminal_created_idx
  on public.account_skin_requests(created_at) where status <> 'reserved';

create table if not exists public.account_skin_throttles (
  player_id uuid primary key references public.minecraft_accounts(player_id) on delete cascade,
  last_attempt_at timestamptz not null
);

alter table public.minecraft_accounts enable row level security;
alter table public.minecraft_account_sessions enable row level security;
alter table public.account_link_requests enable row level security;
alter table public.account_oauth_states enable row level security;
alter table public.account_link_audit enable row level security;
alter table public.account_skins enable row level security;
alter table public.account_skin_requests enable row level security;
alter table public.account_skin_throttles enable row level security;

revoke all on table public.minecraft_accounts, public.minecraft_account_sessions,
  public.account_link_requests, public.account_oauth_states, public.account_link_audit,
  public.account_skins, public.account_skin_requests, public.account_skin_throttles
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

-- Expand the existing key issuer and in-database authorization guard without editing old migrations.
create or replace function public.issue_api_key(p_label text, p_scopes text[])
returns table(api_key text, key_prefix text, key_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_prefix text;
  v_id uuid;
  v_scope text;
begin
  if p_label is null or length(btrim(p_label)) not between 1 and 80 then
    raise exception 'label must have 1 to 80 characters' using errcode = '22023';
  end if;
  if p_scopes is null or cardinality(p_scopes) = 0 then
    raise exception 'at least one scope is required' using errcode = '22023';
  end if;
  foreach v_scope in array p_scopes loop
    if v_scope is null or v_scope not in (
      'leaderboards:read', 'points:read', 'points:write',
      'accounts:read', 'accounts:write', 'accounts:admin'
    ) then
      raise exception 'unsupported API key scope' using errcode = '22023';
    end if;
  end loop;

  v_token := 'ssmp_live_' || pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
  v_prefix := pg_catalog.left(v_token, 21);
  insert into public.api_keys(label, key_prefix, key_hash, scopes)
  values (
    btrim(p_label),
    v_prefix,
    pg_catalog.encode(extensions.digest(pg_catalog.convert_to(v_token, 'UTF8'), 'sha256'), 'hex'),
    array(select distinct scope from unnest(p_scopes) as scopes(scope) order by scope)
  )
  returning id into v_id;

  return query select v_token, v_prefix, v_id;
end;
$$;

create or replace function strafe_api.require_point_api_key(p_key_hash text, p_required_scope text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_scopes text[];
begin
  if p_required_scope is null or p_required_scope not in (
    'leaderboards:read', 'points:read', 'points:write',
    'accounts:read', 'accounts:write', 'accounts:admin'
  ) then
    raise exception 'invalid API scope' using errcode = '22023';
  end if;
  select key_row.id, key_row.scopes
    into v_key_id, v_scopes
    from public.api_keys as key_row
    where p_key_hash ~ '^[0-9a-f]{64}$'
      and key_row.key_hash = p_key_hash
      and key_row.revoked_at is null
      and (key_row.expires_at is null or key_row.expires_at > pg_catalog.now());
  if v_key_id is null then
    raise exception 'api_key_invalid' using errcode = 'P0001';
  end if;
  if not (p_required_scope = any(v_scopes)) then
    raise exception 'api_key_scope_denied' using errcode = 'P0001';
  end if;
  return v_key_id;
end;
$$;

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
    v_next_change := v_skin.updated_at + interval '24 hours';
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

create or replace function strafe_api.api_account_session_end(
  p_key_hash text, p_player_id uuid, p_session_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_deleted integer;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  update public.minecraft_account_sessions as session_row
     set ended_at = pg_catalog.clock_timestamp(),
         expires_at = greatest(session_row.last_seen_at + interval '1 microsecond', pg_catalog.clock_timestamp())
   where session_row.player_id = p_player_id
     and session_row.api_key_id = v_key_id
     and session_row.session_token_hash = p_session_token_hash
     and session_row.ended_at is null
  returning 1 into v_deleted;
  return pg_catalog.jsonb_build_object('ended', coalesce(v_deleted, 0) = 1);
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
    v_next_change := v_skin.updated_at + interval '24 hours';
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

create or replace function strafe_api.api_get_account_skins(p_key_hash text, p_player_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_result jsonb;
begin
  select auth_key.id into v_key_id from strafe_api.authenticate_point_api_key(p_key_hash) as auth_key;
  if v_key_id is null then raise exception 'api_key_invalid' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.api_keys k where k.id = v_key_id and
      (('accounts:read' = any(k.scopes)) or ('leaderboards:read' = any(k.scopes)))) then
    raise exception 'api_key_scope_denied' using errcode = 'P0001';
  end if;
  if p_player_ids is null or cardinality(p_player_ids) > 100 then
    raise exception 'invalid skin lookup' using errcode = '22023';
  end if;
  select coalesce(pg_catalog.jsonb_object_agg(s.player_id::text, pg_catalog.jsonb_build_object(
      'textureHash', s.texture_hash, 'model', s.model,
      'textureUrl', 'https://textures.minecraft.net/texture/' || s.texture_hash,
      'portraitPath', '/v1/accounts/portraits/' || s.texture_hash || '/' || s.model || '.png')),
    '{}'::jsonb)
    into v_result
    from public.account_skins s
   where s.player_id = any(p_player_ids);
  return pg_catalog.jsonb_build_object('skins', v_result);
end;
$$;

create or replace function strafe_api.api_has_account_portrait(p_texture_hash text, p_model text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.account_skins
    where texture_hash = p_texture_hash and model = p_model
  )
$$;

create or replace function strafe_api.api_start_account_link(
  p_key_hash text, p_player_id uuid, p_session_token_hash text, p_purpose text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_discord_id text;
  v_request_id uuid;
  v_status text;
  v_session record;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  if p_purpose not in ('link', 'change') then raise exception 'invalid link purpose' using errcode = '22023'; end if;
  select player_id into v_session from public.minecraft_account_sessions s where s.player_id = p_player_id
      and s.api_key_id = v_key_id and s.session_token_hash = p_session_token_hash and s.expires_at > pg_catalog.now()
      and s.ended_at is null for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'session_unavailable');
  end if;
  select discord_id into v_discord_id from public.minecraft_accounts where player_id = p_player_id for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'code', 'account_not_found'); end if;
  if p_purpose = 'link' and v_discord_id is not null then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'already_linked');
  end if;
  if p_purpose = 'change' and v_discord_id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'not_linked');
  end if;
  update public.account_link_requests set status = 'cancelled'
   where player_id = p_player_id and status not in ('completed', 'expired', 'cancelled');
  delete from public.account_link_requests
   where expires_at < pg_catalog.now() - interval '1 day'
      or (status in ('completed', 'cancelled', 'expired') and created_at < pg_catalog.now() - interval '1 day');
  v_status := case when p_purpose = 'link' then 'awaiting_discord' else 'awaiting_old_discord' end;
  insert into public.account_link_requests(player_id, api_key_id, purpose, status, old_discord_id)
  values (p_player_id, v_key_id, p_purpose, v_status, case when p_purpose = 'change' then v_discord_id else null end)
  returning request_id into v_request_id;
  return pg_catalog.jsonb_build_object('ok', true, 'requestId', v_request_id, 'status', v_status,
    'expiresAt', pg_catalog.now() + interval '15 minutes');
end;
$$;

create or replace function strafe_api.api_get_account_link(
  p_key_hash text, p_player_id uuid, p_session_token_hash text, p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_link record;
  v_session record;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  select player_id into v_session from public.minecraft_account_sessions s where s.player_id = p_player_id
      and s.api_key_id = v_key_id and s.session_token_hash = p_session_token_hash and s.expires_at > pg_catalog.now()
      and s.ended_at is null for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'session_unavailable');
  end if;
  select request_id, status, expires_at, discord_display_name
    into v_link from public.account_link_requests
   where request_id = p_request_id and player_id = p_player_id and api_key_id = v_key_id;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'code', 'link_request_not_found'); end if;
  if v_link.expires_at <= pg_catalog.now() and v_link.status not in ('completed', 'cancelled') then
    update public.account_link_requests set status = 'expired' where request_id = p_request_id;
    v_link.status := 'expired';
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'requestId', v_link.request_id,
    'status', v_link.status, 'expiresAt', v_link.expires_at,
    'discordDisplayName', case when v_link.status = 'awaiting_confirmation' or v_link.status = 'completed'
      then v_link.discord_display_name else null end);
end;
$$;

create or replace function strafe_api.api_begin_account_oauth(p_request_id uuid, p_step text, p_state_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link record;
  v_expected_step text;
begin
  if p_step not in ('old', 'new') or p_state_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid account OAuth state' using errcode = '22023';
  end if;
  select purpose, status, expires_at into v_link
    from public.account_link_requests where request_id = p_request_id for update;
  if not found or v_link.expires_at <= pg_catalog.now() then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'link_request_expired');
  end if;
  v_expected_step := case
    when v_link.purpose = 'link' and v_link.status = 'awaiting_discord' then 'new'
    when v_link.purpose = 'change' and v_link.status = 'awaiting_old_discord' then 'old'
    when v_link.purpose = 'change' and v_link.status = 'awaiting_new_discord' then 'new'
    else null end;
  if p_step is distinct from v_expected_step then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'oauth_step_not_expected');
  end if;
  delete from public.account_oauth_states where expires_at <= pg_catalog.now() or used_at < pg_catalog.now() - interval '10 minutes';
  delete from public.account_link_requests
   where expires_at < pg_catalog.now() - interval '1 day'
      or (status in ('completed', 'cancelled', 'expired') and created_at < pg_catalog.now() - interval '1 day');
  delete from public.account_oauth_states where request_id = p_request_id and used_at is null;
  insert into public.account_oauth_states(state_hash, request_id, step)
    values (p_state_hash, p_request_id, p_step);
  return pg_catalog.jsonb_build_object('ok', true, 'step', p_step);
end;
$$;

create or replace function strafe_api.api_finish_account_oauth(
  p_request_id uuid, p_step text, p_state_hash text, p_discord_id text, p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt record;
  v_link record;
  v_status text;
begin
  if p_discord_id !~ '^[0-9]{17,20}$' or p_display_name is null or length(p_display_name) not between 1 and 100 then
    raise exception 'invalid Discord identity' using errcode = '22023';
  end if;
  select request_id, step, expires_at, used_at into v_attempt
    from public.account_oauth_states where state_hash = p_state_hash for update;
  if not found or v_attempt.request_id <> p_request_id or v_attempt.step <> p_step
      or v_attempt.expires_at <= pg_catalog.now() or v_attempt.used_at is not null then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'oauth_state_invalid');
  end if;
  update public.account_oauth_states set used_at = pg_catalog.now() where state_hash = p_state_hash;
  select request_id, player_id, api_key_id, purpose, status, old_discord_id, expires_at
    into v_link from public.account_link_requests where request_id = p_request_id for update;
  if not found or v_link.expires_at <= pg_catalog.now() then
    update public.account_link_requests set status = 'expired' where request_id = p_request_id and status <> 'completed';
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'link_request_expired');
  end if;
  if p_step = 'old' then
    if v_link.purpose <> 'change' or v_link.status <> 'awaiting_old_discord' or p_discord_id <> v_link.old_discord_id then
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'old_discord_proof_mismatch');
    end if;
    update public.account_link_requests set status = 'awaiting_new_discord', old_verified_at = pg_catalog.now()
      where request_id = p_request_id;
    return pg_catalog.jsonb_build_object('ok', true, 'status', 'awaiting_new_discord');
  end if;
  if (v_link.purpose = 'link' and v_link.status <> 'awaiting_discord')
      or (v_link.purpose = 'change' and (v_link.status <> 'awaiting_new_discord'
        or v_link.old_verified_at is null or p_discord_id = v_link.old_discord_id)) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'new_discord_proof_invalid');
  end if;
  update public.account_link_requests set status = 'awaiting_confirmation',
    new_discord_id = p_discord_id, discord_display_name = p_display_name
    where request_id = p_request_id;
  return pg_catalog.jsonb_build_object('ok', true, 'status', 'awaiting_confirmation');
end;
$$;

create or replace function strafe_api.api_confirm_account_link(
  p_key_hash text, p_player_id uuid, p_session_token_hash text, p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_link record;
  v_current_discord_id text;
  v_session record;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  select player_id into v_session from public.minecraft_account_sessions s where s.player_id = p_player_id
      and s.api_key_id = v_key_id and s.session_token_hash = p_session_token_hash and s.expires_at > pg_catalog.now()
      and s.ended_at is null for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'session_unavailable');
  end if;
  select request_id, player_id, api_key_id, purpose, status, old_discord_id, new_discord_id,
    discord_display_name, expires_at into v_link
    from public.account_link_requests where request_id = p_request_id for update;
  if not found or v_link.player_id <> p_player_id or v_link.api_key_id <> v_key_id then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'link_request_not_found');
  end if;
  if v_link.status = 'completed' then return pg_catalog.jsonb_build_object('ok', true, 'status', 'completed', 'duplicate', true); end if;
  if v_link.expires_at <= pg_catalog.now() then
    update public.account_link_requests set status = 'expired' where request_id = p_request_id;
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'link_request_expired');
  end if;
  if v_link.status <> 'awaiting_confirmation' then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'discord_confirmation_required');
  end if;
  select discord_id into v_current_discord_id from public.minecraft_accounts where player_id = p_player_id for update;
  if (v_link.purpose = 'link' and v_current_discord_id is not null)
      or (v_link.purpose = 'change' and (v_current_discord_id is distinct from v_link.old_discord_id
        or v_link.new_discord_id = v_link.old_discord_id)) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'account_link_changed');
  end if;
  begin
    update public.minecraft_accounts set discord_id = v_link.new_discord_id,
      discord_display_name = v_link.discord_display_name, linked_at = pg_catalog.now(), updated_at = pg_catalog.now()
      where player_id = p_player_id;
    insert into public.account_link_audit(player_id, actor_api_key_id, action, old_discord_id, new_discord_id)
      values (p_player_id, v_key_id, v_link.purpose, v_current_discord_id, v_link.new_discord_id);
  exception when unique_violation then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'discord_already_linked');
  end;
  update public.account_link_requests set status = 'completed', completed_at = pg_catalog.now()
    where request_id = p_request_id;
  return pg_catalog.jsonb_build_object('ok', true, 'status', 'completed', 'duplicate', false);
end;
$$;

create or replace function strafe_api.api_admin_recover_account_link(
  p_key_hash text, p_player_id uuid, p_discord_id text, p_display_name text, p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_old_discord_id text;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:admin');
  if p_discord_id !~ '^[0-9]{17,20}$' or p_display_name is null or length(p_display_name) not between 1 and 100
      or p_reason is null or length(btrim(p_reason)) not between 1 and 500 then
    raise exception 'invalid account recovery request' using errcode = '22023';
  end if;
  select discord_id into v_old_discord_id from public.minecraft_accounts where player_id = p_player_id for update;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'code', 'account_not_found'); end if;
  begin
    update public.minecraft_accounts set discord_id = p_discord_id, discord_display_name = p_display_name,
      linked_at = pg_catalog.now(), updated_at = pg_catalog.now() where player_id = p_player_id;
    insert into public.account_link_audit(player_id, actor_api_key_id, action, old_discord_id, new_discord_id, reason)
      values (p_player_id, v_key_id, 'admin_recovery', v_old_discord_id, p_discord_id, btrim(p_reason));
  exception when unique_violation then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'discord_already_linked');
  end;
  update public.account_link_requests set status = 'cancelled'
    where player_id = p_player_id and status not in ('completed', 'expired', 'cancelled');
  return pg_catalog.jsonb_build_object('ok', true, 'playerId', p_player_id);
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
  if not exists (select 1 from public.minecraft_accounts a where a.player_id = p_player_id and (a.premium or a.discord_id is not null)) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'account_link_required');
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
  if not exists (select 1 from public.minecraft_accounts a where a.player_id = p_player_id and (a.premium or a.discord_id is not null)) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'account_link_required');
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

create or replace function strafe_api.api_cancel_account_skin(
  p_key_hash text, p_player_id uuid, p_session_token_hash text, p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_request record;
  v_session record;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  select player_id into v_session from public.minecraft_account_sessions s where s.player_id = p_player_id
      and s.api_key_id = v_key_id and s.session_token_hash = p_session_token_hash and s.expires_at > pg_catalog.now()
      and s.ended_at is null for update;
  if not found then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'session_unavailable');
  end if;
  select api_key_id, player_id, status into v_request from public.account_skin_requests where request_id = p_request_id for update;
  if not found or v_request.api_key_id <> v_key_id or v_request.player_id <> p_player_id then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'skin_reservation_not_found');
  end if;
  if v_request.status = 'reserved' then update public.account_skin_requests set status = 'cancelled' where request_id = p_request_id; end if;
  return pg_catalog.jsonb_build_object('ok', true, 'cancelled', v_request.status = 'reserved');
end;
$$;

alter function public.issue_api_key(text, text[]) owner to postgres;
alter function strafe_api.require_point_api_key(text, text) owner to postgres;
alter function strafe_api.api_account_session_upsert(text, uuid, text, boolean, text, timestamptz, integer) owner to postgres;
alter function strafe_api.api_account_session_end(text, uuid, text) owner to postgres;
alter function strafe_api.api_get_account(text, uuid) owner to postgres;
alter function strafe_api.api_get_account_skins(text, uuid[]) owner to postgres;
alter function strafe_api.api_has_account_portrait(text, text) owner to postgres;
alter function strafe_api.api_start_account_link(text, uuid, text, text) owner to postgres;
alter function strafe_api.api_get_account_link(text, uuid, text, uuid) owner to postgres;
alter function strafe_api.api_begin_account_oauth(uuid, text, text) owner to postgres;
alter function strafe_api.api_finish_account_oauth(uuid, text, text, text, text) owner to postgres;
alter function strafe_api.api_confirm_account_link(text, uuid, text, uuid) owner to postgres;
alter function strafe_api.api_admin_recover_account_link(text, uuid, text, text, text) owner to postgres;
alter function strafe_api.api_prepare_account_skin(text, uuid, text, uuid, text) owner to postgres;
alter function strafe_api.api_commit_account_skin(text, uuid, text, uuid, text, text, text, text, text) owner to postgres;
alter function strafe_api.api_cancel_account_skin(text, uuid, text, uuid) owner to postgres;

revoke all on function public.issue_api_key(text, text[]) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.require_point_api_key(text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_account_session_upsert(text, uuid, text, boolean, text, timestamptz, integer) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_account_session_end(text, uuid, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_account(text, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_account_skins(text, uuid[]) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_has_account_portrait(text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_start_account_link(text, uuid, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_account_link(text, uuid, text, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_begin_account_oauth(uuid, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_finish_account_oauth(uuid, text, text, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_confirm_account_link(text, uuid, text, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_admin_recover_account_link(text, uuid, text, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_prepare_account_skin(text, uuid, text, uuid, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_commit_account_skin(text, uuid, text, uuid, text, text, text, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_cancel_account_skin(text, uuid, text, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

grant execute on function public.issue_api_key(text, text[]) to postgres;
grant execute on function strafe_api.api_account_session_upsert(text, uuid, text, boolean, text, timestamptz, integer) to strafe_points_runtime;
grant execute on function strafe_api.api_account_session_end(text, uuid, text) to strafe_points_runtime;
grant execute on function strafe_api.api_get_account(text, uuid) to strafe_points_runtime;
grant execute on function strafe_api.api_get_account_skins(text, uuid[]) to strafe_points_runtime;
grant execute on function strafe_api.api_has_account_portrait(text, text) to strafe_points_runtime;
grant execute on function strafe_api.api_start_account_link(text, uuid, text, text) to strafe_points_runtime;
grant execute on function strafe_api.api_get_account_link(text, uuid, text, uuid) to strafe_points_runtime;
grant execute on function strafe_api.api_begin_account_oauth(uuid, text, text) to strafe_points_runtime;
grant execute on function strafe_api.api_finish_account_oauth(uuid, text, text, text, text) to strafe_points_runtime;
grant execute on function strafe_api.api_confirm_account_link(text, uuid, text, uuid) to strafe_points_runtime;
grant execute on function strafe_api.api_admin_recover_account_link(text, uuid, text, text, text) to strafe_points_runtime;
grant execute on function strafe_api.api_prepare_account_skin(text, uuid, text, uuid, text) to strafe_points_runtime;
grant execute on function strafe_api.api_commit_account_skin(text, uuid, text, uuid, text, text, text, text, text) to strafe_points_runtime;
grant execute on function strafe_api.api_cancel_account_skin(text, uuid, text, uuid) to strafe_points_runtime;

