-- Recreated teams have distinct IDs. Hide stale deleted teams before calculating ranks.
-- Historical season standings remain unchanged; never deduplicate legitimate teams by name.
create or replace function public.get_points_leaderboard(
  p_subject_type text, p_limit integer, p_offset integer, p_mode text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with ranked as (
    select balance.subject_type, balance.subject_id, balance.points, balance.wins, balance.losses,
           profile.display_name, profile.prefix, profile.member_count, profile.region,
           pg_catalog.rank() over (order by balance.points desc)::integer as rank,
           pg_catalog.count(*) over () as total_count
    from public.point_balances as balance
    left join public.point_profiles as profile
      on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
    where balance.subject_type = p_subject_type
      and not exists (
        select 1 from public.point_subject_tombstones as deleted
        where deleted.subject_type = balance.subject_type and deleted.subject_id = balance.subject_id
      )
      and (p_subject_type <> 'player' or not strafe_api.api_is_tier_banned(balance.subject_id))
  ), paged as (
    select * from ranked
    order by points desc, display_name asc nulls last, subject_id
    offset p_offset
    limit p_limit + 1
  )
  select pg_catalog.jsonb_build_object(
    'mode', p_mode,
    'limit', p_limit,
    'offset', p_offset,
    'total', coalesce((select max(total_count) from ranked), 0),
    'nextOffset', case when (select count(*) from paged) > p_limit then p_offset + p_limit else null end,
    'items', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'subjectType', subject_type,
      'subjectId', subject_id,
      'displayName', display_name,
      'prefix', prefix,
      'memberCount', member_count,
      'region', region,
      'points', points,
      'rank', rank,
      'wins', wins,
      'losses', losses
    ) order by points desc, display_name asc nulls last, subject_id)
      from (select * from paged order by points desc, display_name asc nulls last, subject_id limit p_limit) as limited), '[]'::jsonb)
  );
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
             balance.prefix, balance.member_count, profile.region, roster.members,
             balance.points, balance.wins, balance.losses,
             pg_catalog.rank() over (order by balance.points desc)::integer as rank,
             pg_catalog.count(*) over () as total_count
        from public.point_season_balances as balance
        left join public.point_profiles as profile
          on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
        left join public.point_season_team_rosters as roster
          on balance.subject_type = 'team' and roster.team_id = balance.subject_id and roster.season = balance.season
       where balance.season = v_season and balance.subject_type = p_subject_type
         -- Completed seasons keep their historical standings. Current teams must still exist.
         and (v_season <> v_current_season or p_subject_type <> 'team' or (
           exists (
             select 1 from public.point_balances as live
             where live.subject_type = balance.subject_type and live.subject_id = balance.subject_id
           )
           and not exists (
             select 1 from public.point_subject_tombstones as deleted
             where deleted.subject_type = balance.subject_type and deleted.subject_id = balance.subject_id
           )
         ))
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
        'region', region, 'members', coalesce(members, '[]'::jsonb),
        'points', points, 'rank', rank, 'wins', wins, 'losses', losses
      ) order by points desc, display_name asc nulls last, subject_id)
        from (select * from paged order by points desc, display_name asc nulls last, subject_id limit p_limit) as limited), '[]'::jsonb)
    )
  );
end;
$$;


alter function public.get_points_leaderboard(text, integer, integer, text) owner to postgres;
alter function public.get_points_leaderboard_for_season(text, integer, integer, text, text) owner to postgres;
revoke all on function public.get_points_leaderboard(text, integer, integer, text)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.get_points_leaderboard_for_season(text, integer, integer, text, text)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;