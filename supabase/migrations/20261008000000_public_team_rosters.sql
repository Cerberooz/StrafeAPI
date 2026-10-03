alter table public.point_profiles
  add column if not exists members jsonb not null default '[]'::jsonb;

alter table public.point_profiles
  drop constraint if exists point_profiles_members_shape;
alter table public.point_profiles
  add constraint point_profiles_members_shape check (
    case when pg_catalog.jsonb_typeof(members) = 'array'
      then pg_catalog.jsonb_array_length(members) <= 1000
      else false
    end
    and (subject_type = 'team' or members = '[]'::jsonb)
  );

create or replace function public.sync_point_profiles(p_api_key_id uuid, p_profiles jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_row jsonb;
  v_subject_type text;
  v_subject_id uuid;
  v_count integer := 0;
begin
  if p_profiles is null or pg_catalog.jsonb_typeof(p_profiles) <> 'array'
      or (case when pg_catalog.jsonb_typeof(p_profiles) = 'array' then pg_catalog.jsonb_array_length(p_profiles) > 500 else false end) then
    raise exception 'profiles must contain at most 500 rows' using errcode = '22023';
  end if;
  for v_row in select value from pg_catalog.jsonb_array_elements(p_profiles)
    order by value->>'subjectType', value->>'subjectId'
  loop
    v_subject_type := v_row->>'subjectType';
    v_subject_id := (v_row->>'subjectId')::uuid;
    if v_subject_type is null or v_subject_type not in ('team', 'player') or v_subject_id is null then
      raise exception 'invalid profile subject' using errcode = '22023';
    end if;
    if v_row ? 'members' and (v_subject_type <> 'team' or case
        when pg_catalog.jsonb_typeof(v_row->'members') = 'array' then pg_catalog.jsonb_array_length(v_row->'members') > 1000
        else true end) then
      raise exception 'invalid team roster' using errcode = '22023';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_subject_type || ':' || v_subject_id::text, 0));
    if exists (select 1 from public.point_subject_tombstones where subject_type = v_subject_type and subject_id = v_subject_id) then
      continue;
    end if;
    insert into public.point_profiles(subject_type, subject_id, display_name, prefix, member_count, members)
    values (v_subject_type, v_subject_id, v_row->>'displayName', v_row->>'prefix', nullif(v_row->>'memberCount', '')::integer,
      case when v_subject_type = 'team' then coalesce(v_row->'members', '[]'::jsonb) else '[]'::jsonb end)
    on conflict (subject_type, subject_id) do update set
      display_name = case when v_row ? 'displayName' then excluded.display_name else public.point_profiles.display_name end,
      prefix = case when v_row ? 'prefix' then excluded.prefix else public.point_profiles.prefix end,
      member_count = case when v_row ? 'memberCount' then excluded.member_count else public.point_profiles.member_count end,
      members = case when v_row ? 'members' then excluded.members else public.point_profiles.members end,
      updated_at = now();
    v_count := v_count + 1;
  end loop;
  return pg_catalog.jsonb_build_object('updatedCount', v_count);
end;
$$;

create or replace function public.get_points_leaderboard_for_season(
  p_subject_type text, p_limit integer, p_offset integer, p_mode text, p_season text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_season text;
  v_season_name text;
  v_current_season text;
begin
  if p_subject_type is null or p_subject_type not in ('team', 'player')
    or p_limit is null or p_limit not between 1 and 100
    or p_offset is null or p_offset not between 0 and 10000
    or p_mode is null or p_mode not in ('smp-teams', 'smp-solo') then
    raise exception 'invalid leaderboard request' using errcode = '22023';
  end if;
  select current_season into strict v_current_season from public.point_settings where singleton = true;
  v_season := coalesce(p_season, v_current_season);
  select display_name into v_season_name from public.point_seasons where season = v_season;
  if v_season_name is null then raise exception 'leaderboard_season_not_found' using errcode = 'P0001'; end if;

  return (
    with ranked as (
      select balance.subject_type, balance.subject_id, balance.display_name,
             balance.prefix, balance.member_count, profile.members, balance.points, balance.wins, balance.losses,
             pg_catalog.rank() over (order by balance.points desc)::integer as rank,
             pg_catalog.count(*) over () as total_count
        from public.point_season_balances as balance
        left join public.point_profiles as profile
          on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
       where balance.season = v_season and balance.subject_type = p_subject_type
         and (p_subject_type <> 'player' or not strafe_api.api_is_tier_banned(balance.subject_id))
    ), paged as (
      select * from ranked order by points desc, display_name asc nulls last, subject_id
      offset p_offset limit p_limit + 1
    )
    select pg_catalog.jsonb_build_object(
      'mode', p_mode, 'season', v_season, 'seasonName', v_season_name, 'currentSeason', v_current_season,
      'limit', p_limit, 'offset', p_offset,
      'total', coalesce((select max(total_count) from ranked), 0),
      'nextOffset', case when (select count(*) from paged) > p_limit then p_offset + p_limit else null end,
      'items', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'season', v_season, 'subjectType', subject_type, 'subjectId', subject_id,
        'displayName', display_name, 'prefix', prefix, 'memberCount', member_count,
        'members', coalesce(members, '[]'::jsonb), 'points', points, 'rank', rank, 'wins', wins, 'losses', losses
      ) order by points desc, display_name asc nulls last, subject_id)
        from (select * from paged order by points desc, display_name asc nulls last, subject_id limit p_limit) as limited), '[]'::jsonb)
    )
  );
end;
$$;

alter function public.sync_point_profiles(uuid, jsonb) owner to postgres;
alter function public.get_points_leaderboard_for_season(text, integer, integer, text, text) owner to postgres;
revoke all on function public.sync_point_profiles(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.get_points_leaderboard_for_season(text, integer, integer, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
