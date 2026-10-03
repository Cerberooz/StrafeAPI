-- Active tier bans hide solo player rows from current and historical rankings.
-- Point balances, mutations, snapshots, and team rows are intentionally unchanged.

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
           profile.display_name, profile.prefix, profile.member_count,
           pg_catalog.rank() over (order by balance.points desc)::integer as rank,
           pg_catalog.count(*) over () as total_count
    from public.point_balances as balance
    left join public.point_profiles as profile
      on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
    where balance.subject_type = p_subject_type
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
      'points', points,
      'rank', rank,
      'wins', wins,
      'losses', losses
    ) order by points desc, display_name asc nulls last, subject_id)
      from (select * from paged order by points desc, display_name asc nulls last, subject_id limit p_limit) as limited), '[]'::jsonb)
  );
$$;

create or replace function public.get_points_leaderboard_for_season(
  p_subject_type text,
  p_limit integer,
  p_offset integer,
  p_mode text,
  p_season text default null
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
  select current_season into strict v_current_season
    from public.point_settings where singleton = true;
  v_season := coalesce(p_season, v_current_season);
  select display_name into v_season_name from public.point_seasons where season = v_season;
  if v_season_name is null then
    raise exception 'leaderboard_season_not_found' using errcode = 'P0001';
  end if;

  return (
    with ranked as (
      select balance.subject_type, balance.subject_id, balance.display_name,
             balance.prefix, balance.member_count, balance.points, balance.wins, balance.losses,
             pg_catalog.rank() over (order by balance.points desc)::integer as rank,
             pg_catalog.count(*) over () as total_count
        from public.point_season_balances as balance
       where balance.season = v_season and balance.subject_type = p_subject_type
         and (p_subject_type <> 'player' or not strafe_api.api_is_tier_banned(balance.subject_id))
    ), paged as (
      select * from ranked
      order by points desc, display_name asc nulls last, subject_id
      offset p_offset
      limit p_limit + 1
    )
    select pg_catalog.jsonb_build_object(
      'mode', p_mode,
      'season', v_season,
      'seasonName', v_season_name,
      'currentSeason', v_current_season,
      'limit', p_limit,
      'offset', p_offset,
      'total', coalesce((select max(total_count) from ranked), 0),
      'nextOffset', case when (select count(*) from paged) > p_limit then p_offset + p_limit else null end,
      'items', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'season', v_season,
        'subjectType', subject_type,
        'subjectId', subject_id,
        'displayName', display_name,
        'prefix', prefix,
        'memberCount', member_count,
        'points', points,
        'rank', rank,
        'wins', wins,
        'losses', losses
      ) order by points desc, display_name asc nulls last, subject_id)
        from (select * from paged order by points desc, display_name asc nulls last, subject_id limit p_limit) as limited), '[]'::jsonb)
    )
  );
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

create or replace function strafe_api.api_get_points_leaderboard_for_season(
  p_key_hash text,
  p_subject_type text,
  p_limit integer,
  p_offset integer,
  p_mode text,
  p_season text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'leaderboards:read');
  return public.get_points_leaderboard_for_season(p_subject_type, p_limit, p_offset, p_mode, p_season);
end;
$$;

alter function public.get_points_leaderboard(text, integer, integer, text) owner to postgres;
alter function public.get_points_leaderboard_for_season(text, integer, integer, text, text) owner to postgres;
alter function strafe_api.api_get_points_leaderboard(text, text, integer, integer, text) owner to postgres;
alter function strafe_api.api_get_points_leaderboard_for_season(text, text, integer, integer, text, text) owner to postgres;

revoke all on function public.get_points_leaderboard(text, integer, integer, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.get_points_leaderboard_for_season(text, integer, integer, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_points_leaderboard(text, text, integer, integer, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_points_leaderboard_for_season(text, text, integer, integer, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

grant execute on function strafe_api.api_get_points_leaderboard(text, text, integer, integer, text) to strafe_points_runtime;
grant execute on function strafe_api.api_get_points_leaderboard_for_season(text, text, integer, integer, text, text) to strafe_points_runtime;
