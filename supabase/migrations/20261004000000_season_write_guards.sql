-- Keep profile writes and season transitions in a single lock order. Reject a
-- newly submitted match from an earlier season before its transaction commits.

alter table public.point_seasons
  add column if not exists enforce_match_start_cutoff boolean not null default true;

-- The season active when the API is first installed can contain queued plugin
-- events from before this database was connected. Preserve those events while
-- enforcing the cutoff for every season created from this migration onward.
update public.point_seasons
set enforce_match_start_cutoff = false
where allow_snapshot_import = true;

create or replace function public.prepare_smp_season_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.current_season is not distinct from old.current_season then
    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('strafe:smp-active-season', 0)
  );
  if new.current_season !~ '^[a-z0-9][a-z0-9._-]{0,63}$' then
    raise exception 'invalid_current_season' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.point_seasons
    where season = new.current_season and completed_at is not null
  ) then
    raise exception 'completed_season_cannot_be_reactivated' using errcode = '22023';
  end if;

  -- Use wall-clock time after waiting for in-flight writes; now() is fixed at
  -- transaction start and could otherwise move the cutoff ahead of the commit.
  insert into public.point_seasons(season, display_name, started_at)
  values (
    new.current_season,
    pg_catalog.initcap(pg_catalog.replace(new.current_season, '-', ' ')),
    pg_catalog.clock_timestamp()
  )
  on conflict (season) do update
    set started_at = excluded.started_at
    where public.point_seasons.completed_at is null;
  return new;
end;
$$;

create or replace function public.start_smp_season()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.current_season is not distinct from old.current_season then
    return new;
  end if;
  update public.point_seasons
  set completed_at = pg_catalog.clock_timestamp()
  where season = old.current_season and completed_at is null;

  -- A fresh SMP leaderboard starts at zero. The plugin will pull these
  -- authoritative balances during its next sync.
  update public.point_settings set starting_points = 0
  where singleton = true and starting_points <> 0;
  update public.point_balances
  set points = 0, wins = 0, losses = 0, updated_at = pg_catalog.clock_timestamp();
  return new;
end;
$$;

create or replace function strafe_api.api_get_points_snapshot(
  p_key_hash text,
  p_subject_type text,
  p_limit integer,
  p_after uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_current_season text;
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'points:read');
  v_snapshot := public.get_points_snapshot(p_subject_type, p_limit, p_after);
  select current_season into v_current_season
  from public.point_settings
  where singleton = true;
  return v_snapshot || pg_catalog.jsonb_build_object('currentSeason', v_current_season);
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
  -- Lock order is active season first, then the identities locked by the
  -- profile-sync function. Rollover uses the exclusive form of this lock.
  perform pg_catalog.pg_advisory_xact_lock_shared(
    pg_catalog.hashtextextended('strafe:smp-active-season', 0)
  );
  return public.sync_point_profiles(v_api_key_id, p_profiles);
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
  v_result jsonb;
  v_event_season text;
  v_current_season text;
begin
  v_api_key_id := strafe_api.require_point_api_key(p_key_hash, 'points:write');
  v_result := public.mutate_points(p_event_id, p_request_hash, v_api_key_id, p_operation, p_payload);

  -- A duplicate can return its original cached items after a season change.
  -- Publish both values so the plugin can safely avoid merging those old rows.
  select mutation.season into strict v_event_season
  from public.point_mutations as mutation
  where mutation.event_id = p_event_id;
  select settings.current_season into strict v_current_season
  from public.point_settings as settings
  where settings.singleton = true;

  return v_result || pg_catalog.jsonb_build_object(
    'eventSeason', v_event_season,
    'currentSeason', v_current_season
  );
end;
$$;

create or replace function public.reject_pre_season_match()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_season_started_at timestamptz;
  v_enforce_match_start_cutoff boolean;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(
    pg_catalog.hashtextextended('strafe:smp-active-season', 0)
  );
  select season.started_at, season.enforce_match_start_cutoff
    into strict v_current_season_started_at, v_enforce_match_start_cutoff
  from public.point_settings as settings
  join public.point_seasons as season on season.season = settings.current_season
  where settings.singleton = true;

  if v_enforce_match_start_cutoff and new.started_at < v_current_season_started_at then
    raise exception 'season_mismatch' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists point_matches_reject_pre_season on public.point_matches;
create trigger point_matches_reject_pre_season
before insert on public.point_matches
for each row execute function public.reject_pre_season_match();

alter function strafe_api.api_get_points_snapshot(text, text, integer, uuid) owner to postgres;
alter function strafe_api.api_mutate_points(text, uuid, text, text, jsonb) owner to postgres;
alter function strafe_api.api_sync_point_profiles(text, jsonb) owner to postgres;
alter function public.prepare_smp_season_change() owner to postgres;
alter function public.start_smp_season() owner to postgres;
alter function public.reject_pre_season_match() owner to postgres;

revoke all on function strafe_api.api_get_points_snapshot(text, text, integer, uuid)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_mutate_points(text, uuid, text, text, jsonb)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_sync_point_profiles(text, jsonb)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.prepare_smp_season_change()
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.start_smp_season()
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.reject_pre_season_match()
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

grant execute on function strafe_api.api_get_points_snapshot(text, text, integer, uuid)
  to strafe_points_runtime;
grant execute on function strafe_api.api_mutate_points(text, uuid, text, text, jsonb)
  to strafe_points_runtime;
grant execute on function strafe_api.api_sync_point_profiles(text, jsonb)
  to strafe_points_runtime;
