-- A restored plugin cache must never become a second source of point truth.
-- The plugin may import its existing cache during first setup; once it has
-- queued that import, the API permanently closes that path for the active
-- season. Later local-cache snapshots are ignored. Explicit new-subject seeds
-- can still create a balance using the API's configured starting points.

create or replace function public.seed_point_snapshot_guarded(
  p_api_key_id uuid,
  p_balances jsonb,
  p_create_missing boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb;
  v_lock_row record;
  v_subject_type text;
  v_subject_id uuid;
  v_inserted integer := 0;
  v_existing integer := 0;
  v_deleted integer := 0;
  v_skipped integer := 0;
  v_count integer;
  v_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_current_season text;
  v_allow_snapshot_import boolean;
  v_starting_points integer;
  v_points integer;
  v_wins integer;
  v_losses integer;
begin
  if p_create_missing is null then
    raise exception 'snapshot createMissing flag is required' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('strafe:smp-active-season', 0));
  if p_balances is null or pg_catalog.jsonb_typeof(p_balances) <> 'array' or pg_catalog.jsonb_array_length(p_balances) > 500 then
    raise exception 'snapshot must contain at most 500 rows' using errcode = '22023';
  end if;
  select settings.current_season, season.allow_snapshot_import, settings.starting_points
    into strict v_current_season, v_allow_snapshot_import, v_starting_points
  from public.point_settings as settings
  join public.point_seasons as season on season.season = settings.current_season
  where settings.singleton = true;

  for v_lock_row in
    select value from pg_catalog.jsonb_array_elements(p_balances)
    order by value->>'subjectType', value->>'subjectId'
  loop
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      v_lock_row.value->>'subjectType' || ':' || (v_lock_row.value->>'subjectId')::uuid::text, 0));
  end loop;

  for v_row in select value from pg_catalog.jsonb_array_elements(p_balances)
  loop
    v_subject_type := v_row->>'subjectType';
    v_subject_id := (v_row->>'subjectId')::uuid;
    if v_subject_type is null or v_subject_type not in ('team', 'player') or v_subject_id is null then
      raise exception 'invalid snapshot subject' using errcode = '22023';
    end if;
    if exists (select 1 from public.point_subject_tombstones where subject_type = v_subject_type and subject_id = v_subject_id) then
      v_deleted := v_deleted + 1;
      continue;
    end if;

    -- Cached rows are accepted only while the one-time import is open. Once it
    -- is closed, only an explicit new-subject seed may create a row, and its
    -- balance always comes from API starting_points rather than the cache.
    if not v_allow_snapshot_import and not p_create_missing then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    if (v_row->>'points')::integer not between 0 and 2147483647
      or coalesce((v_row->>'wins')::integer, 0) not between 0 and 2147483647
      or coalesce((v_row->>'losses')::integer, 0) not between 0 and 2147483647 then
      raise exception 'invalid snapshot balance' using errcode = '22023';
    end if;

    v_points := case when v_allow_snapshot_import then (v_row->>'points')::integer else v_starting_points end;
    v_wins := case when v_allow_snapshot_import then coalesce((v_row->>'wins')::integer, 0) else 0 end;
    v_losses := case when v_allow_snapshot_import then coalesce((v_row->>'losses')::integer, 0) else 0 end;
    insert into public.point_balances(subject_type, subject_id, points, wins, losses)
    values (v_subject_type, v_subject_id, v_points, v_wins, v_losses)
    on conflict (subject_type, subject_id) do nothing;
    get diagnostics v_count = row_count;
    if v_count = 1 then v_inserted := v_inserted + 1; else v_existing := v_existing + 1; end if;

    -- A closed-import seed is for a genuinely new subject. Never let a cached
    -- profile overwrite a central profile that already exists.
    if (v_allow_snapshot_import or v_count = 1)
      and (v_row ? 'displayName' or v_row ? 'prefix' or v_row ? 'memberCount') then
      insert into public.point_profiles(subject_type, subject_id, display_name, prefix, member_count)
      values (v_subject_type, v_subject_id, v_row->>'displayName', v_row->>'prefix', nullif(v_row->>'memberCount', '')::integer)
      on conflict (subject_type, subject_id) do update set
        display_name = case when v_row ? 'displayName' then excluded.display_name else public.point_profiles.display_name end,
        prefix = case when v_row ? 'prefix' then excluded.prefix else public.point_profiles.prefix end,
        member_count = case when v_row ? 'memberCount' then excluded.member_count else public.point_profiles.member_count end,
        updated_at = now();
    end if;

    select pg_catalog.jsonb_build_object(
      'subjectType', balance.subject_type,
      'subjectId', balance.subject_id,
      'displayName', profile.display_name,
      'prefix', profile.prefix,
      'memberCount', profile.member_count,
      'points', balance.points,
      'wins', balance.wins,
      'losses', balance.losses
    ) into v_item
    from public.point_balances as balance
    left join public.point_profiles as profile
      on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
    where balance.subject_type = v_subject_type and balance.subject_id = v_subject_id;
    v_items := v_items || pg_catalog.jsonb_build_array(v_item);
  end loop;

  return pg_catalog.jsonb_build_object(
    'insertedCount', v_inserted,
    'existingCount', v_existing,
    'deletedCount', v_deleted,
    'skippedCount', v_skipped,
    'items', v_items
  );
end;
$$;

create or replace function strafe_api.api_seed_point_snapshot(
  p_key_hash text,
  p_balances jsonb,
  p_create_missing boolean
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
  return public.seed_point_snapshot_guarded(v_api_key_id, p_balances, p_create_missing);
end;
$$;

create or replace function strafe_api.api_finalize_point_snapshot_import(p_key_hash text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_season text;
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'points:write');
  -- Exclusive with snapshot seeding and season transitions. When this returns,
  -- no in-flight cache import can still be using the old setting.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('strafe:smp-active-season', 0));
  select current_season into strict v_current_season
  from public.point_settings
  where singleton = true;
  update public.point_seasons
  set allow_snapshot_import = false
  where season = v_current_season;
  return pg_catalog.jsonb_build_object(
    'currentSeason', v_current_season,
    'snapshotImportEnabled', false
  );
end;
$$;

alter function public.seed_point_snapshot_guarded(uuid, jsonb, boolean) owner to postgres;
alter function strafe_api.api_seed_point_snapshot(text, jsonb, boolean) owner to postgres;
alter function strafe_api.api_finalize_point_snapshot_import(text) owner to postgres;

revoke all on function public.seed_point_snapshot_guarded(uuid, jsonb, boolean)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_seed_point_snapshot(text, jsonb, boolean)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_finalize_point_snapshot_import(text)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

grant execute on function strafe_api.api_seed_point_snapshot(text, jsonb, boolean) to strafe_points_runtime, service_role;
grant execute on function strafe_api.api_finalize_point_snapshot_import(text) to strafe_points_runtime, service_role;

notify pgrst, 'reload schema';
