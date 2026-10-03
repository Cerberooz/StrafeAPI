-- Season history is kept in a separate leaderboard table. The live point balance
-- remains the source used by gameplay and is reset when an administrator starts
-- a new season by changing point_settings.current_season.

create table if not exists public.point_seasons (
  season text primary key check (season ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  display_name text not null check (length(btrim(display_name)) between 1 and 80),
  allow_snapshot_import boolean not null default false,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

alter table public.point_settings
  add column if not exists current_season text not null default 'season-1';

insert into public.point_seasons(season, display_name, started_at)
select settings.current_season,
       pg_catalog.initcap(pg_catalog.replace(settings.current_season, '-', ' ')),
       settings.updated_at
from public.point_settings as settings
where settings.singleton = true
on conflict (season) do nothing;

update public.point_seasons set allow_snapshot_import = true
where season = (select current_season from public.point_settings where singleton = true);

alter table public.point_settings
  add constraint point_settings_current_season_fk
  foreign key (current_season) references public.point_seasons(season);

create table if not exists public.point_season_balances (
  season text not null references public.point_seasons(season) on delete restrict,
  subject_type text not null check (subject_type in ('team', 'player')),
  subject_id uuid not null,
  display_name text check (display_name is null or length(display_name) <= 255),
  prefix text check (prefix is null or length(prefix) <= 64),
  member_count integer check (member_count is null or member_count between 0 and 1000),
  points integer not null default 0 check (points between 0 and 2147483647),
  wins integer not null default 0 check (wins between 0 and 2147483647),
  losses integer not null default 0 check (losses between 0 and 2147483647),
  updated_at timestamptz not null default now(),
  primary key (season, subject_type, subject_id),
  check (subject_type = 'team' or member_count is null)
);

create index if not exists point_season_balances_leaderboard_idx
  on public.point_season_balances(season, subject_type, points desc, subject_id);

alter table public.point_mutations
  add column if not exists season text not null default 'season-1'
  references public.point_seasons(season);
alter table public.point_matches
  add column if not exists season text not null default 'season-1'
  references public.point_seasons(season);
alter table public.point_matches_archive
  add column if not exists season text not null default 'season-1'
  references public.point_seasons(season);

insert into public.point_season_balances(
  season, subject_type, subject_id, display_name, prefix, member_count,
  points, wins, losses, updated_at
)
select settings.current_season, balance.subject_type, balance.subject_id,
       profile.display_name, profile.prefix, profile.member_count,
       balance.points, balance.wins, balance.losses, balance.updated_at
from public.point_balances as balance
cross join public.point_settings as settings
left join public.point_profiles as profile
  on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
where settings.singleton = true
on conflict (season, subject_type, subject_id) do nothing;

alter table public.point_seasons enable row level security;
alter table public.point_season_balances enable row level security;
revoke all on table public.point_seasons, public.point_season_balances
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
grant select on table public.point_seasons to service_role;
grant update (display_name) on table public.point_seasons to service_role;

create or replace function public.seed_point_snapshot(p_api_key_id uuid, p_balances jsonb)
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

    if v_row ? 'displayName' or v_row ? 'prefix' or v_row ? 'memberCount' then
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

  return pg_catalog.jsonb_build_object('insertedCount', v_inserted, 'existingCount', v_existing, 'deletedCount', v_deleted, 'items', v_items);
end;
$$;

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
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('strafe:smp-active-season', 0));
  if new.current_season !~ '^[a-z0-9][a-z0-9._-]{0,63}$' then
    raise exception 'invalid_current_season' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.point_seasons
    where season = new.current_season and completed_at is not null
  ) then
    raise exception 'completed_season_cannot_be_reactivated' using errcode = '22023';
  end if;
  insert into public.point_seasons(season, display_name)
  values (
    new.current_season,
    pg_catalog.initcap(pg_catalog.replace(new.current_season, '-', ' '))
  )
  on conflict (season) do nothing;
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
  update public.point_seasons set completed_at = now()
  where season = old.current_season and completed_at is null;

  -- A fresh SMP leaderboard starts at zero. The plugin will pull these
  -- authoritative balances during its next sync.
  update public.point_settings set starting_points = 0
  where singleton = true and starting_points <> 0;
  update public.point_balances
  set points = 0, wins = 0, losses = 0, updated_at = now();
  return new;
end;
$$;

create or replace function public.sync_point_season_balance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_season text;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('strafe:smp-active-season', 0));
  select current_season into strict v_season
  from public.point_settings where singleton = true;
  if tg_op = 'DELETE' then
    delete from public.point_season_balances
    where season = v_season and subject_type = old.subject_type and subject_id = old.subject_id;
    return old;
  end if;
  insert into public.point_season_balances(
    season, subject_type, subject_id, display_name, prefix, member_count,
    points, wins, losses, updated_at
  )
  select v_season, new.subject_type, new.subject_id,
         profile.display_name, profile.prefix, profile.member_count,
         new.points, new.wins, new.losses, new.updated_at
  from (select 1) as source
  left join public.point_profiles as profile
    on profile.subject_type = new.subject_type and profile.subject_id = new.subject_id
  on conflict (season, subject_type, subject_id) do update set
    display_name = excluded.display_name,
    prefix = excluded.prefix,
    member_count = excluded.member_count,
    points = excluded.points,
    wins = excluded.wins,
    losses = excluded.losses,
    updated_at = excluded.updated_at;
  return new;
end;
$$;

create or replace function public.sync_point_season_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_season text;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('strafe:smp-active-season', 0));
  select current_season into strict v_season
  from public.point_settings where singleton = true;
  update public.point_season_balances
  set display_name = new.display_name,
      prefix = new.prefix,
      member_count = new.member_count,
      updated_at = now()
  where season = v_season and subject_type = new.subject_type and subject_id = new.subject_id;
  return new;
end;
$$;

create or replace function public.tag_smp_season_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(pg_catalog.hashtextextended('strafe:smp-active-season', 0));
  select current_season into strict new.season
  from public.point_settings where singleton = true;
  return new;
end;
$$;

create or replace function public.tag_archived_match_season()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select season into new.season
  from public.point_matches where match_id = new.match_id;
  return new;
end;
$$;

drop trigger if exists point_settings_prepare_smp_season on public.point_settings;
create trigger point_settings_prepare_smp_season
before update of current_season on public.point_settings
for each row execute function public.prepare_smp_season_change();

drop trigger if exists point_settings_start_smp_season on public.point_settings;
create trigger point_settings_start_smp_season
after update of current_season on public.point_settings
for each row execute function public.start_smp_season();

drop trigger if exists point_balances_sync_smp_season on public.point_balances;
create trigger point_balances_sync_smp_season
after insert or update or delete on public.point_balances
for each row execute function public.sync_point_season_balance();

drop trigger if exists point_profiles_sync_smp_season on public.point_profiles;
create trigger point_profiles_sync_smp_season
after insert or update on public.point_profiles
for each row execute function public.sync_point_season_profile();

drop trigger if exists point_matches_tag_smp_season on public.point_matches;
create trigger point_matches_tag_smp_season
before insert on public.point_matches
for each row execute function public.tag_smp_season_row();

drop trigger if exists point_mutations_tag_smp_season on public.point_mutations;
create trigger point_mutations_tag_smp_season
before insert on public.point_mutations
for each row execute function public.tag_smp_season_row();

drop trigger if exists point_matches_archive_tag_smp_season on public.point_matches_archive;
create trigger point_matches_archive_tag_smp_season
before insert on public.point_matches_archive
for each row execute function public.tag_archived_match_season();

alter function public.prepare_smp_season_change() owner to postgres;
alter function public.start_smp_season() owner to postgres;
alter function public.sync_point_season_balance() owner to postgres;
alter function public.sync_point_season_profile() owner to postgres;
alter function public.tag_smp_season_row() owner to postgres;
alter function public.tag_archived_match_season() owner to postgres;
revoke all on function public.prepare_smp_season_change() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.start_smp_season() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.sync_point_season_balance() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.sync_point_season_profile() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.tag_smp_season_row() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.tag_archived_match_season() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

create or replace function public.get_smp_leaderboard_seasons()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'currentSeason', settings.current_season,
    'seasons', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', season.season,
        'name', season.display_name,
        'current', season.season = settings.current_season,
        'completedAt', season.completed_at
      ) order by season.started_at desc, season.season desc)
      from public.point_seasons as season
    ), '[]'::jsonb)
  )
  from public.point_settings as settings
  where settings.singleton = true
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
  select display_name into v_season_name
  from public.point_seasons where season = v_season;
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

create or replace function strafe_api.api_get_smp_leaderboard_seasons(p_key_hash text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform strafe_api.require_point_api_key(p_key_hash, 'leaderboards:read');
  return public.get_smp_leaderboard_seasons();
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

alter function public.get_smp_leaderboard_seasons() owner to postgres;
alter function public.get_points_leaderboard_for_season(text, integer, integer, text, text) owner to postgres;
alter function strafe_api.api_get_smp_leaderboard_seasons(text) owner to postgres;
alter function strafe_api.api_get_points_leaderboard_for_season(text, text, integer, integer, text, text) owner to postgres;
revoke all on function public.get_smp_leaderboard_seasons() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function public.get_points_leaderboard_for_season(text, integer, integer, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_smp_leaderboard_seasons(text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_get_points_leaderboard_for_season(text, text, integer, integer, text, text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
grant execute on function strafe_api.api_get_smp_leaderboard_seasons(text) to strafe_points_runtime;
grant execute on function strafe_api.api_get_points_leaderboard_for_season(text, text, integer, integer, text, text) to strafe_points_runtime;
