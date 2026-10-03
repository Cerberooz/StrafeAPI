-- Persistent SMP tier moderation state. Existing account and key migrations stay immutable.

create table if not exists public.tier_bans (
  player_id uuid primary key,
  active boolean not null default true,
  captured_discord_id text check (captured_discord_id is null or captured_discord_id ~ '^[0-9]{17,20}$'),
  banned_at timestamptz not null default pg_catalog.clock_timestamp(),
  banned_by_api_key_id uuid not null,
  banned_by_actor text not null check (length(banned_by_actor) between 1 and 64),
  revoked_at timestamptz,
  revoked_by_api_key_id uuid,
  revoked_by_actor text,
  check ((active and revoked_at is null and revoked_by_api_key_id is null and revoked_by_actor is null)
      or (not active and revoked_at is not null and revoked_by_api_key_id is not null
          and revoked_by_actor is not null and length(revoked_by_actor) between 1 and 64))
);

create index if not exists tier_bans_active_discord_idx
  on public.tier_bans(captured_discord_id) where active and captured_discord_id is not null;

create table if not exists public.tier_ban_audit (
  audit_id bigint generated always as identity primary key,
  player_id uuid not null,
  action text not null check (action in ('ban', 'unban')),
  api_key_id uuid not null,
  actor text not null check (length(actor) between 1 and 64),
  captured_discord_id text check (captured_discord_id is null or captured_discord_id ~ '^[0-9]{17,20}$'),
  created_at timestamptz not null default pg_catalog.clock_timestamp()
);

create index if not exists tier_ban_audit_player_created_idx
  on public.tier_ban_audit(player_id, created_at desc);

alter table public.tier_bans enable row level security;
alter table public.tier_ban_audit enable row level security;
revoke all on table public.tier_bans, public.tier_ban_audit
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

create index if not exists minecraft_accounts_player_name_ci_idx
  on public.minecraft_accounts (pg_catalog.lower(player_name));

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
      'accounts:read', 'accounts:write', 'accounts:admin', 'tiers:moderate'
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
    'accounts:read', 'accounts:write', 'accounts:admin', 'tiers:moderate'
  ) then
    raise exception 'invalid API scope' using errcode = '22023';
  end if;
  select key_row.id, key_row.scopes into v_key_id, v_scopes
    from public.api_keys as key_row
   where p_key_hash ~ '^[0-9a-f]{64}$'
     and key_row.key_hash = p_key_hash
     and key_row.revoked_at is null
     and (key_row.expires_at is null or key_row.expires_at > pg_catalog.now());
  if v_key_id is null then raise exception 'api_key_invalid' using errcode = 'P0001'; end if;
  if not (p_required_scope = any(v_scopes)) then
    raise exception 'api_key_scope_denied' using errcode = 'P0001';
  end if;
  return v_key_id;
end;
$$;

create or replace function strafe_api.api_is_tier_banned(p_player_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
      select 1 from public.tier_bans b
       where b.player_id = p_player_id and b.active
    )
    or exists (
      select 1
        from public.minecraft_accounts a
        join public.tier_bans b on b.captured_discord_id = a.discord_id and b.active
       where a.player_id = p_player_id and a.discord_id is not null
    )
$$;

create or replace function strafe_api.api_get_account_with_tier_status(p_key_hash text, p_player_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  v_result := strafe_api.api_get_account(p_key_hash, p_player_id);
  return v_result || pg_catalog.jsonb_build_object(
    'tiersBanned', strafe_api.api_is_tier_banned(p_player_id)
  );
end;
$$;

create or replace function strafe_api.api_account_session_upsert_with_tier_status(
  p_key_hash text, p_player_id uuid, p_player_name text, p_premium boolean, p_session_token_hash text,
  p_session_started_at timestamptz, p_ttl_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if p_player_id is null then raise exception 'player UUID is required' using errcode = '22023'; end if;
  perform strafe_api.require_point_api_key(p_key_hash, 'accounts:write');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('tier-ban:' || p_player_id::text));
  v_result := strafe_api.api_account_session_upsert(
    p_key_hash, p_player_id, p_player_name, p_premium, p_session_token_hash, p_session_started_at, p_ttl_seconds
  );
  if v_result ->> 'ok' is distinct from 'true' then return v_result; end if;
  return v_result || pg_catalog.jsonb_build_object(
    'tiersBanned', strafe_api.api_is_tier_banned(p_player_id)
  );
end;
$$;

create or replace function strafe_api.api_get_tier_ban_statuses(p_key_hash text, p_player_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_bans jsonb;
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'accounts:read');
  if p_player_ids is null or cardinality(p_player_ids) not between 1 and 100
      or exists (select 1 from unnest(p_player_ids) as ids(player_id) where player_id is null)
      or cardinality(p_player_ids) <> (select count(distinct player_id) from unnest(p_player_ids) as ids(player_id)) then
    raise exception 'player UUIDs must contain 1 to 100 unique values' using errcode = '22023';
  end if;
  select coalesce(pg_catalog.jsonb_object_agg(ids.player_id::text,
      strafe_api.api_is_tier_banned(ids.player_id)), '{}'::jsonb)
    into v_bans
    from unnest(p_player_ids) as ids(player_id);
  return pg_catalog.jsonb_build_object('bans', v_bans);
end;
$$;

create or replace function strafe_api.api_get_tier_players(p_key_hash text, p_name text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_matches jsonb;
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'tiers:moderate');
  if p_name is null or p_name !~ '^[A-Za-z0-9_]{1,16}$' then
    raise exception 'invalid Minecraft player name' using errcode = '22023';
  end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'playerId', player_id, 'playerName', player_name
    ) order by player_id), '[]'::jsonb)
    into v_matches
    from public.minecraft_accounts
   where pg_catalog.lower(player_name) = pg_catalog.lower(p_name);
  return pg_catalog.jsonb_build_object('matches', v_matches);
end;
$$;

create or replace function strafe_api.api_moderate_tier_ban(
  p_key_hash text, p_player_id uuid, p_actor text, p_banned boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_player_name text;
  v_premium boolean;
  v_discord_id text;
  v_capture_discord_id text;
  v_active boolean;
  v_account_exists boolean;
begin
  v_key_id := strafe_api.require_point_api_key(p_key_hash, 'tiers:moderate');
  if p_player_id is null or p_banned is null or p_actor is null
      or length(btrim(p_actor)) not between 1 and 64 or p_actor !~ '^[A-Za-z0-9_ .:@/-]{1,64}$' then
    raise exception 'invalid tier moderation request' using errcode = '22023';
  end if;
  p_actor := btrim(p_actor);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('tier-ban:' || p_player_id::text));
  select player_name, premium, discord_id into v_player_name, v_premium, v_discord_id
    from public.minecraft_accounts where player_id = p_player_id for update;
  v_account_exists := found;

  select active into v_active from public.tier_bans where player_id = p_player_id for update;
  if p_banned then
    if found and v_active then
      return pg_catalog.jsonb_build_object('playerId', p_player_id, 'playerName', v_player_name,
        'banned', true, 'changed', false, 'tiersBanned', strafe_api.api_is_tier_banned(p_player_id));
    end if;
    v_capture_discord_id := case when v_account_exists and v_premium is false then v_discord_id else null end;
    insert into public.tier_bans(player_id, active, captured_discord_id, banned_at, banned_by_api_key_id, banned_by_actor,
      revoked_at, revoked_by_api_key_id, revoked_by_actor)
    values (p_player_id, true, v_capture_discord_id, pg_catalog.clock_timestamp(), v_key_id, p_actor, null, null, null)
    on conflict (player_id) do update set
      active = true,
      captured_discord_id = excluded.captured_discord_id,
      banned_at = excluded.banned_at,
      banned_by_api_key_id = excluded.banned_by_api_key_id,
      banned_by_actor = excluded.banned_by_actor,
      revoked_at = null,
      revoked_by_api_key_id = null,
      revoked_by_actor = null;
    insert into public.tier_ban_audit(player_id, action, api_key_id, actor, captured_discord_id)
      values (p_player_id, 'ban', v_key_id, p_actor, v_capture_discord_id);
    return pg_catalog.jsonb_build_object('playerId', p_player_id, 'playerName', v_player_name,
      'banned', true, 'changed', true, 'tiersBanned', strafe_api.api_is_tier_banned(p_player_id));
  end if;

  if not found or not v_active then
    return pg_catalog.jsonb_build_object('playerId', p_player_id, 'playerName', v_player_name,
      'banned', false, 'changed', false, 'tiersBanned', strafe_api.api_is_tier_banned(p_player_id));
  end if;
  v_capture_discord_id := null;
  select captured_discord_id into v_capture_discord_id from public.tier_bans where player_id = p_player_id;
  update public.tier_bans set active = false, revoked_at = pg_catalog.clock_timestamp(),
      revoked_by_api_key_id = v_key_id, revoked_by_actor = p_actor
    where player_id = p_player_id;
  insert into public.tier_ban_audit(player_id, action, api_key_id, actor, captured_discord_id)
    values (p_player_id, 'unban', v_key_id, p_actor, v_capture_discord_id);
  return pg_catalog.jsonb_build_object('playerId', p_player_id, 'playerName', v_player_name,
    'banned', false, 'changed', true, 'tiersBanned', strafe_api.api_is_tier_banned(p_player_id));
end;
$$;

alter function public.issue_api_key(text, text[]) owner to postgres;
alter function strafe_api.require_point_api_key(text, text) owner to postgres;
alter function strafe_api.api_is_tier_banned(uuid) owner to postgres;
alter function strafe_api.api_get_account_with_tier_status(text, uuid) owner to postgres;
alter function strafe_api.api_account_session_upsert_with_tier_status(text, uuid, text, boolean, text, timestamptz, integer) owner to postgres;
alter function strafe_api.api_get_tier_players(text, text) owner to postgres;
alter function strafe_api.api_get_tier_ban_statuses(text, uuid[]) owner to postgres;
alter function strafe_api.api_moderate_tier_ban(text, uuid, text, boolean) owner to postgres;

revoke all on function public.issue_api_key(text, text[]) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.require_point_api_key(text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_is_tier_banned(uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_account_with_tier_status(text, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_account_session_upsert_with_tier_status(text, uuid, text, boolean, text, timestamptz, integer) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_tier_players(text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_tier_ban_statuses(text, uuid[]) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_moderate_tier_ban(text, uuid, text, boolean) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

grant execute on function public.issue_api_key(text, text[]) to postgres;
grant execute on function strafe_api.api_get_account_with_tier_status(text, uuid) to strafe_points_runtime;
grant execute on function strafe_api.api_account_session_upsert_with_tier_status(text, uuid, text, boolean, text, timestamptz, integer) to strafe_points_runtime;
grant execute on function strafe_api.api_get_tier_players(text, text) to strafe_points_runtime;
grant execute on function strafe_api.api_get_tier_ban_statuses(text, uuid[]) to strafe_points_runtime;
grant execute on function strafe_api.api_moderate_tier_ban(text, uuid, text, boolean) to strafe_points_runtime;
