-- A narrow, read-only profile projection for Discord. No Discord IDs, sessions,
-- signatures or moderation privileges are exposed to the bot.
create index if not exists point_season_team_rosters_members_lookup_idx
  on public.point_season_team_rosters using gin(members jsonb_path_ops);

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
      rank() over (partition by season, subject_type order by points desc)::integer as standing,
      row_number() over (partition by season, subject_type order by points desc,
        lower(regexp_replace(coalesce(display_name, ''), '[&§][0-9a-fk-or]', '', 'gi')), subject_id)::integer as position,
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
