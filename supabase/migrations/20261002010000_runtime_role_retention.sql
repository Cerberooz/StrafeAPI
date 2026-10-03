-- Give the HTTP service a restricted PostgreSQL identity and define safe history retention.

do $$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'strafe_points_runtime') then
    execute 'create role strafe_points_runtime nologin nosuperuser nocreatedb nocreaterole noinherit noreplication nobypassrls';
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'strafe_points_api') then
    execute 'create role strafe_points_api nologin nosuperuser nocreatedb nocreaterole inherit noreplication nobypassrls';
  end if;
end;
$$;

-- Supabase postgres is not a superuser. Even ALTER ROLE ... NOSUPERUSER
-- requires superuser privileges; verify restricted attributes instead.
do $role_safety$
begin
  if exists (
    select 1 from pg_catalog.pg_roles
    where rolname in ('strafe_points_runtime', 'strafe_points_api')
      and (rolsuper or rolreplication or rolbypassrls)
  ) then
    raise exception 'Strafe database roles have unsafe privileges; administrator intervention is required';
  end if;
end;
$role_safety$;
alter role strafe_points_runtime nologin nocreatedb nocreaterole noinherit;
alter role strafe_points_api nocreatedb nocreaterole inherit;
alter role strafe_points_api set search_path = pg_catalog;
grant strafe_points_runtime to strafe_points_api;

do $$
begin
  execute pg_catalog.format('grant connect on database %I to strafe_points_runtime', pg_catalog.current_database());
end;
$$;

create schema if not exists strafe_api authorization postgres;
revoke all on schema strafe_api from public, anon, authenticated, service_role;
grant usage on schema strafe_api to strafe_points_runtime;

create or replace function strafe_api.authenticate_point_api_key(p_key_hash text)
returns table(id uuid, label text, scopes text[], expires_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select key_row.id, key_row.label, key_row.scopes, key_row.expires_at
  from public.api_keys as key_row
  where p_key_hash ~ '^[0-9a-f]{64}$'
    and key_row.key_hash = p_key_hash
    and key_row.revoked_at is null
    and (key_row.expires_at is null or key_row.expires_at > pg_catalog.now())
  limit 1
$$;

create or replace function strafe_api.points_api_ready()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(select 1 from public.point_settings where singleton = true)
$$;

create or replace function strafe_api.require_point_api_key(p_key_hash text, p_required_scope text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_scopes text[];
begin
  if p_required_scope is null or p_required_scope not in ('leaderboards:read', 'points:read', 'points:write') then
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

create or replace function strafe_api.api_get_point_balance(p_key_hash text, p_subject_type text, p_subject_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'points:read');
  return public.get_point_balance(p_subject_type, p_subject_id);
end;
$$;

create or replace function strafe_api.api_get_points_snapshot(p_key_hash text, p_subject_type text, p_limit integer, p_after uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'points:read');
  return public.get_points_snapshot(p_subject_type, p_limit, p_after);
end;
$$;

create or replace function strafe_api.api_get_points_leaderboard(
  p_key_hash text,
  p_subject_type text,
  p_limit integer,
  p_offset integer,
  p_mode text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'leaderboards:read');
  return public.get_points_leaderboard(p_subject_type, p_limit, p_offset, p_mode);
end;
$$;

create or replace function strafe_api.api_mutate_points(
  p_key_hash text,
  p_event_id uuid,
  p_request_hash text,
  p_operation text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_api_key_id uuid;
begin
  v_api_key_id := strafe_api.require_point_api_key(p_key_hash, 'points:write');
  return public.mutate_points(p_event_id, p_request_hash, v_api_key_id, p_operation, p_payload);
end;
$$;

create or replace function strafe_api.api_seed_point_snapshot(p_key_hash text, p_balances jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_api_key_id uuid;
begin
  v_api_key_id := strafe_api.require_point_api_key(p_key_hash, 'points:write');
  return public.seed_point_snapshot(v_api_key_id, p_balances);
end;
$$;

create or replace function strafe_api.api_sync_point_profiles(p_key_hash text, p_profiles jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_api_key_id uuid;
begin
  v_api_key_id := strafe_api.require_point_api_key(p_key_hash, 'points:write');
  return public.sync_point_profiles(v_api_key_id, p_profiles);
end;
$$;


-- Called only by a database administrator in the Supabase SQL Editor. Re-running rotates the password.
create or replace function public.issue_points_database_password()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_password text;
begin
  v_password := pg_catalog.replace(
    pg_catalog.gen_random_uuid()::text || pg_catalog.gen_random_uuid()::text,
    '-', ''
  );
  execute pg_catalog.format('alter role strafe_points_api login inherit password %L', v_password);
  return v_password;
end;
$$;

create index if not exists point_mutations_created_at_idx
  on public.point_mutations(created_at, event_id);

create index if not exists point_matches_ended_at_idx
  on public.point_matches(ended_at, match_id);

create table if not exists public.point_matches_archive (
  match_id uuid primary key references public.point_mutations(event_id) on delete restrict,
  subject_type text not null check (subject_type in ('team', 'player')),
  subject_a_id uuid not null,
  subject_b_id uuid not null,
  winner_id uuid,
  ranked boolean not null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  duration_seconds integer not null check (duration_seconds >= 0),
  battle_size integer check (battle_size between 2 and 1000),
  delta_a integer not null,
  delta_b integer not null,
  created_at timestamptz not null,
  archived_at timestamptz not null default now(),
  check (subject_a_id <> subject_b_id),
  check (winner_id is null or winner_id in (subject_a_id, subject_b_id)),
  check (ended_at >= started_at),
  check ((subject_type = 'team' and battle_size is not null) or (subject_type = 'player' and battle_size is null)),
  check (ranked or (delta_a = 0 and delta_b = 0))
);

create index if not exists point_matches_archive_ended_at_idx
  on public.point_matches_archive(ended_at, match_id);

alter table public.point_matches_archive enable row level security;
revoke all on table public.point_matches_archive from public, anon, authenticated, service_role;

create or replace function public.archive_point_matches_before(
  p_before timestamptz,
  p_limit integer default 10000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_archived integer;
begin
  if p_before is null or p_before > pg_catalog.now() or p_limit is null or p_limit not between 1 and 10000 then
    raise exception 'invalid match archive request' using errcode = '22023';
  end if;

  with batch as (
    select match_row.*
    from public.point_matches as match_row
    where match_row.ended_at < p_before
    order by match_row.ended_at, match_row.match_id
    limit p_limit
    for update skip locked
  ), archived as (
    insert into public.point_matches_archive(
      match_id, subject_type, subject_a_id, subject_b_id, winner_id, ranked,
      started_at, ended_at, duration_seconds, battle_size, delta_a, delta_b, created_at
    )
    select match_id, subject_type, subject_a_id, subject_b_id, winner_id, ranked,
      started_at, ended_at, duration_seconds, battle_size, delta_a, delta_b, created_at
    from batch
    on conflict (match_id) do nothing
    returning match_id
  ), safe_to_delete as (
    select match_id from archived
    union
    select batch.match_id
    from batch
    join public.point_matches_archive as archived_match using (match_id)
    where archived_match.subject_type = batch.subject_type
      and archived_match.subject_a_id = batch.subject_a_id
      and archived_match.subject_b_id = batch.subject_b_id
      and archived_match.winner_id is not distinct from batch.winner_id
      and archived_match.ranked = batch.ranked
      and archived_match.started_at = batch.started_at
      and archived_match.ended_at = batch.ended_at
      and archived_match.duration_seconds = batch.duration_seconds
      and archived_match.battle_size is not distinct from batch.battle_size
      and archived_match.delta_a = batch.delta_a
      and archived_match.delta_b = batch.delta_b
      and archived_match.created_at = batch.created_at
  ), deleted as (
    delete from public.point_matches as active_match
    using safe_to_delete
    where active_match.match_id = safe_to_delete.match_id
    returning active_match.match_id
  )
  select pg_catalog.count(*)::integer into v_archived from deleted;

  return v_archived;
end;
$$;

create or replace function public.get_points_storage_metrics()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'pointMutations', pg_catalog.jsonb_build_object(
      'rows', (select pg_catalog.count(*) from public.point_mutations),
      'oldestCreatedAt', (select min(created_at) from public.point_mutations),
      'bytes', pg_catalog.pg_total_relation_size('public.point_mutations'::pg_catalog.regclass)
    ),
    'activeMatches', pg_catalog.jsonb_build_object(
      'rows', (select pg_catalog.count(*) from public.point_matches),
      'oldestEndedAt', (select min(ended_at) from public.point_matches),
      'bytes', pg_catalog.pg_total_relation_size('public.point_matches'::pg_catalog.regclass)
    ),
    'archivedMatches', pg_catalog.jsonb_build_object(
      'rows', (select pg_catalog.count(*) from public.point_matches_archive),
      'oldestEndedAt', (select min(ended_at) from public.point_matches_archive),
      'bytes', pg_catalog.pg_total_relation_size('public.point_matches_archive'::pg_catalog.regclass)
    )
  )
$$;

alter function public.get_point_balance(text, uuid) security definer;
alter function public.get_points_snapshot(text, integer, uuid) security definer;
alter function public.get_points_leaderboard(text, integer, integer, text) security definer;
alter function public.mutate_points(uuid, text, uuid, text, jsonb) security definer;
alter function public.seed_point_snapshot(uuid, jsonb) security definer;
alter function public.sync_point_profiles(uuid, jsonb) security definer;
alter function public.issue_api_key(text, text[]) security definer;

alter function strafe_api.authenticate_point_api_key(text) owner to postgres;
alter function strafe_api.points_api_ready() owner to postgres;
alter function strafe_api.require_point_api_key(text, text) owner to postgres;
alter function strafe_api.api_get_point_balance(text, text, uuid) owner to postgres;
alter function strafe_api.api_get_points_snapshot(text, text, integer, uuid) owner to postgres;
alter function strafe_api.api_get_points_leaderboard(text, text, integer, integer, text) owner to postgres;
alter function strafe_api.api_mutate_points(text, uuid, text, text, jsonb) owner to postgres;
alter function strafe_api.api_seed_point_snapshot(text, jsonb) owner to postgres;
alter function strafe_api.api_sync_point_profiles(text, jsonb) owner to postgres;
alter function public.issue_points_database_password() owner to postgres;
alter function public.get_point_balance(text, uuid) owner to postgres;
alter function public.get_points_snapshot(text, integer, uuid) owner to postgres;
alter function public.get_points_leaderboard(text, integer, integer, text) owner to postgres;
alter function public.mutate_points(uuid, text, uuid, text, jsonb) owner to postgres;
alter function public.seed_point_snapshot(uuid, jsonb) owner to postgres;
alter function public.sync_point_profiles(uuid, jsonb) owner to postgres;
alter function public.issue_api_key(text, text[]) owner to postgres;
alter function public.archive_point_matches_before(timestamptz, integer) owner to postgres;
alter function public.get_points_storage_metrics() owner to postgres;

revoke all on table public.api_keys, public.point_settings, public.point_balances,
  public.point_profiles, public.point_mutations, public.point_matches,
  public.point_subject_tombstones, public.point_matches_archive
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

-- Keep Supabase Studio key/settings management available without giving those table rights to the runtime login.
grant select, insert, update, delete on table public.api_keys to service_role;
grant select, update on table public.point_settings to service_role;

grant usage on schema strafe_api to strafe_points_runtime;

revoke all on function strafe_api.authenticate_point_api_key(text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.points_api_ready() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.require_point_api_key(text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_point_balance(text, text, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_points_snapshot(text, text, integer, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_points_leaderboard(text, text, integer, integer, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_mutate_points(text, uuid, text, text, jsonb) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_seed_point_snapshot(text, jsonb) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_sync_point_profiles(text, jsonb) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.issue_points_database_password() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.get_point_balance(text, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.get_points_snapshot(text, integer, uuid) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.get_points_leaderboard(text, integer, integer, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.mutate_points(uuid, text, uuid, text, jsonb) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.seed_point_snapshot(uuid, jsonb) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.sync_point_profiles(uuid, jsonb) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.issue_api_key(text, text[]) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.archive_point_matches_before(timestamptz, integer) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.get_points_storage_metrics() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

grant execute on function strafe_api.authenticate_point_api_key(text) to strafe_points_runtime;
grant execute on function strafe_api.points_api_ready() to strafe_points_runtime;
grant execute on function strafe_api.api_get_point_balance(text, text, uuid) to strafe_points_runtime;
grant execute on function strafe_api.api_get_points_snapshot(text, text, integer, uuid) to strafe_points_runtime;
grant execute on function strafe_api.api_get_points_leaderboard(text, text, integer, integer, text) to strafe_points_runtime;
grant execute on function strafe_api.api_mutate_points(text, uuid, text, text, jsonb) to strafe_points_runtime;
grant execute on function strafe_api.api_seed_point_snapshot(text, jsonb) to strafe_points_runtime;
grant execute on function strafe_api.api_sync_point_profiles(text, jsonb) to strafe_points_runtime;

grant execute on function public.issue_points_database_password() to postgres;
grant execute on function public.issue_api_key(text, text[]) to postgres;
grant execute on function public.archive_point_matches_before(timestamptz, integer) to postgres;
grant execute on function public.get_points_storage_metrics() to postgres;

