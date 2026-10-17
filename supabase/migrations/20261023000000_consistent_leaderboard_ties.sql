-- Use the same unique standings in the API, website, plugin and Discord.
-- Order by points descending, then UUID ascending; display-name changes cannot reorder ties.
-- Only read projections change. Balances, match records and season history are not rewritten.

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
           pg_catalog.row_number() over (order by balance.points desc, balance.subject_id)::integer as rank,
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
    order by points desc, subject_id
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
    ) order by points desc, subject_id)
      from (select * from paged order by points desc, subject_id limit p_limit) as limited), '[]'::jsonb)
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
             pg_catalog.row_number() over (order by balance.points desc, balance.subject_id)::integer as rank,
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
      select * from ranked order by points desc, subject_id
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
      ) order by points desc, subject_id)
        from (select * from paged order by points desc, subject_id limit p_limit) as limited), '[]'::jsonb)
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
create or replace function strafe_api.api_get_tier_profile(p_key_hash text, p_name text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_player_id uuid;
  v_account record;
  v_matches integer;
  v_current text;
  v_results jsonb;
begin
  select auth_key.id into v_key_id from strafe_api.authenticate_point_api_key(p_key_hash) as auth_key;
  if v_key_id is null then raise exception 'api_key_invalid' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.api_keys k where k.id = v_key_id and 'leaderboards:read' = any(k.scopes)) then
    raise exception 'api_key_scope_denied' using errcode = 'P0001';
  end if;
  if p_name is null or p_name !~ '^[A-Za-z0-9_]{1,16}$' then
    raise exception 'invalid profile name' using errcode = '22023';
  end if;
  select count(*) into v_matches from public.minecraft_accounts where lower(player_name) = lower(p_name);
  if v_matches = 0 then return jsonb_build_object('code', 'player_not_found'); end if;
  if v_matches > 1 then return jsonb_build_object('code', 'ambiguous_player_name'); end if;
  select a.*, s.texture_hash, s.model, profile.region into v_account
    from public.minecraft_accounts a
    left join public.account_skins s on s.player_id = a.player_id
    left join public.point_profiles profile on profile.subject_type = 'player' and profile.subject_id = a.player_id
    where lower(a.player_name) = lower(p_name);
  v_player_id := v_account.player_id;
  if strafe_api.api_is_tier_banned(v_player_id) then return jsonb_build_object('code', 'player_not_found'); end if;
  select current_season into strict v_current from public.point_settings where singleton = true;

  with associated as (
    select season, team_id from public.point_season_team_rosters
      where members @> jsonb_build_array(jsonb_build_object('playerId', v_player_id::text))
  ), eligible as (
    select b.*, season.display_name as season_name, season.started_at, metadata.region as standing_region
      from public.point_season_balances b
      join public.point_seasons season on season.season = b.season
      left join public.point_profiles metadata on metadata.subject_type = b.subject_type and metadata.subject_id = b.subject_id
      where (b.subject_type <> 'player' or not strafe_api.api_is_tier_banned(b.subject_id))
        and (b.season <> v_current or b.subject_type <> 'team' or (
          exists (select 1 from public.point_balances live where live.subject_type = 'team' and live.subject_id = b.subject_id)
          and not exists (select 1 from public.point_subject_tombstones deleted where deleted.subject_type = 'team' and deleted.subject_id = b.subject_id)
        ))
  ), ranked as (
    select eligible.*,
      row_number() over (partition by season, subject_type order by points desc, subject_id)::integer as standing,
      row_number() over (partition by season, subject_type order by points desc, subject_id)::integer as position,
      count(*) over (partition by season, subject_type)::integer as population
    from eligible
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'mode', case when subject_type = 'team' then 'smp-teams' else 'smp-solo' end,
    'subjectId', subject_id, 'displayName', display_name, 'points', points,
    'rank', standing, 'position', position, 'total', population, 'region', standing_region,
    'season', season, 'seasonName', season_name, 'seasonStartedAt', started_at
  ) order by started_at desc, subject_type, subject_id), '[]'::jsonb) into v_results
    from ranked
    where (subject_type = 'player' and subject_id = v_player_id)
      or (subject_type = 'team' and exists (select 1 from associated where associated.season = ranked.season and associated.team_id = ranked.subject_id));

  return jsonb_build_object(
    'playerId', v_player_id, 'playerName', v_account.player_name,
    'premium', v_account.premium, 'linked', v_account.discord_id is not null,
    'region', v_account.region, 'currentSeason', v_current,
    'skin', jsonb_build_object('model', v_account.model, 'textureHash', v_account.texture_hash),
    'standings', v_results
  );
end;
$$;

alter function strafe_api.api_get_tier_profile(text, text) owner to postgres;
revoke all on function strafe_api.api_get_tier_profile(text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
grant execute on function strafe_api.api_get_tier_profile(text, text) to service_role, strafe_points_runtime;
notify pgrst, 'reload schema';
