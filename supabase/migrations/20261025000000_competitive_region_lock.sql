-- A player's competitive region is claimed atomically when their first match
-- reaches combat. Queue checks are read-only; they never assign a region.
create table public.competitive_player_regions (
  player_id uuid primary key,
  region text not null check (region in ('AS','EU','NA','SA','OC','AF')),
  assigned_at timestamptz not null default now(),
  last_match_id uuid
);
create index competitive_player_regions_region_idx on public.competitive_player_regions(region, player_id);
alter table public.competitive_player_regions enable row level security;
revoke all on table public.competitive_player_regions
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

create table public.competitive_match_claims (
  match_id uuid primary key,
  region text not null check (region in ('AS','EU','NA','SA','OC','AF')),
  player_ids uuid[] not null check (cardinality(player_ids) between 2 and 1000),
  subject_type text not null check (subject_type in ('player','team')),
  subject_a_id uuid not null,
  subject_b_id uuid not null,
  check (subject_a_id <> subject_b_id),
  claimed_at timestamptz not null default now()
);
create index competitive_match_claims_region_claimed_idx on public.competitive_match_claims(region, claimed_at);
alter table public.competitive_match_claims enable row level security;
revoke all on table public.competitive_match_claims
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

create table public.competitive_region_transfer_audit (
  transfer_id bigint generated always as identity primary key,
  player_id uuid not null,
  old_region text check (old_region is null or old_region in ('AS','EU','NA','SA','OC','AF')),
  new_region text not null check (new_region in ('AS','EU','NA','SA','OC','AF')),
  actor text not null check (length(btrim(actor)) between 1 and 80),
  reason text not null check (length(btrim(reason)) between 1 and 500),
  transferred_at timestamptz not null default now()
);
create index competitive_region_transfer_audit_player_idx on public.competitive_region_transfer_audit(player_id, transferred_at desc);
alter table public.competitive_region_transfer_audit enable row level security;
revoke all on table public.competitive_region_transfer_audit
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

-- Treat existing Asia records as already assigned. Include solo history and
-- team rosters published before a recorded team match. Do not lock every member
-- just because their team has a published roster.
insert into public.competitive_player_regions(player_id, region, last_match_id)
select legacy.player_id, 'AS', legacy.match_id
from (
  select p.subject_id as player_id, null::uuid as match_id
    from public.point_profiles p where p.subject_type='player'
  union all
  select b.subject_id, null::uuid
    from public.point_balances b where b.subject_type='player'
  union all
  select m.subject_a_id, m.match_id
    from public.point_matches m where m.subject_type='player'
  union all
  select m.subject_b_id, m.match_id
    from public.point_matches m where m.subject_type='player'
  union all
  select m.subject_a_id, m.match_id
    from public.point_matches_archive m where m.subject_type='player'
  union all
  select m.subject_b_id, m.match_id
    from public.point_matches_archive m where m.subject_type='player'
  union all
  select case when roster_member.value->>'playerId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (roster_member.value->>'playerId')::uuid else null end, battle_row.match_id
    from public.point_season_team_rosters roster
    join (
      select match_id, season, subject_a_id as team_id, started_at from public.point_matches where subject_type='team'
      union all
      select match_id, season, subject_b_id as team_id, started_at from public.point_matches where subject_type='team'
      union all
      select match_id, season, subject_a_id as team_id, started_at from public.point_matches_archive where subject_type='team'
      union all
      select match_id, season, subject_b_id as team_id, started_at from public.point_matches_archive where subject_type='team'
    ) battle_row on battle_row.season=roster.season and battle_row.team_id=roster.team_id
      and roster.published_at_ms <= (extract(epoch from battle_row.started_at) * 1000)::bigint
    cross join lateral pg_catalog.jsonb_array_elements(roster.members) roster_member(value)
) legacy
where legacy.player_id is not null
on conflict (player_id) do nothing;

create function public.claim_competitive_match(
  p_region text, p_match_id uuid, p_player_ids uuid[],
  p_subject_type text, p_subject_a_id uuid, p_subject_b_id uuid
)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_count integer;
  v_existing_region text;
  v_existing_ids uuid[];
  v_existing_subject_type text;
  v_existing_subject_a_id uuid;
  v_existing_subject_b_id uuid;
  v_player_id uuid;
  v_conflict record;
begin
  if p_region is null or p_region not in ('AS','EU','NA','SA','OC','AF')
    or p_match_id is null or p_player_ids is null or cardinality(p_player_ids) not between 2 and 1000
    or p_subject_type is null or p_subject_type not in ('player','team')
    or p_subject_a_id is null or p_subject_b_id is null or p_subject_a_id = p_subject_b_id
    or (p_subject_type = 'player' and (cardinality(p_player_ids) <> 2
      or not (p_subject_a_id = any(p_player_ids)) or not (p_subject_b_id = any(p_player_ids))))
    or array_position(p_player_ids, null) is not null then
    raise exception 'invalid competitive match authorization' using errcode='22023';
  end if;
  select array_agg(id order by id), count(*) into v_ids, v_count
    from (select distinct unnest(p_player_ids) as id) players;
  if v_count <> cardinality(p_player_ids) then
    raise exception 'duplicate competitive match participant' using errcode='22023';
  end if;

  -- Serialize retries of this match, then lock player IDs in deterministic
  -- order. Different regions racing the same player cannot both assign them.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('competitive-match:' || p_match_id::text, 0));
  select region, player_ids, subject_type, subject_a_id, subject_b_id
    into v_existing_region, v_existing_ids, v_existing_subject_type, v_existing_subject_a_id, v_existing_subject_b_id
    from public.competitive_match_claims where match_id=p_match_id;
  if found then
    if v_existing_region <> p_region or v_existing_ids is distinct from v_ids
      or v_existing_subject_type <> p_subject_type
      or v_existing_subject_a_id <> p_subject_a_id or v_existing_subject_b_id <> p_subject_b_id then
      raise exception 'competitive_match_claim_conflict' using errcode='P0001';
    end if;
    return pg_catalog.jsonb_build_object('allowed', true, 'region', p_region, 'duplicate', true);
  end if;
  foreach v_player_id in array v_ids loop
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('competitive-player:' || v_player_id::text, 0));
  end loop;

  select player_id, region into v_conflict
    from public.competitive_player_regions
    where player_id = any(v_ids) and region <> p_region
    order by player_id limit 1;
  if found then
    return pg_catalog.jsonb_build_object('allowed', false, 'region', p_region,
      'conflictPlayerId', v_conflict.player_id, 'conflictRegion', v_conflict.region);
  end if;

  insert into public.competitive_player_regions(player_id, region, last_match_id)
    select id, p_region, p_match_id from pg_catalog.unnest(v_ids) as ids(id)
    on conflict (player_id) do update set last_match_id=excluded.last_match_id;
  insert into public.competitive_match_claims(match_id, region, player_ids, subject_type, subject_a_id, subject_b_id)
    values (p_match_id, p_region, v_ids, p_subject_type, p_subject_a_id, p_subject_b_id);
  return pg_catalog.jsonb_build_object('allowed', true, 'region', p_region, 'duplicate', false);
end;
$$;
alter function public.claim_competitive_match(text, uuid, uuid[], text, uuid, uuid) owner to postgres;
revoke all on function public.claim_competitive_match(text, uuid, uuid[], text, uuid, uuid)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

create function public.check_competitive_regions(p_region text, p_player_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_players jsonb;
begin
  if p_region is null or p_region not in ('AS','EU','NA','SA','OC','AF')
    or p_player_ids is null or cardinality(p_player_ids) not between 1 and 1000
    or array_position(p_player_ids, null) is not null
    or (select count(distinct id) from pg_catalog.unnest(p_player_ids) as ids(id)) <> cardinality(p_player_ids) then
    raise exception 'invalid competitive region check' using errcode='22023';
  end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'playerId', ids.id, 'region', assigned.region) order by ids.id), '[]'::jsonb)
    into v_players
    from pg_catalog.unnest(p_player_ids) as ids(id)
    left join public.competitive_player_regions assigned on assigned.player_id=ids.id;
  return pg_catalog.jsonb_build_object('region', p_region, 'players', v_players);
end;
$$;
alter function public.check_competitive_regions(text, uuid[]) owner to postgres;
revoke all on function public.check_competitive_regions(text, uuid[])
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

create function strafe_api.api_check_competitive_regions(p_key_hash text, p_player_ids uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_key uuid; v_region text;
begin
  v_key := strafe_api.require_point_api_key(p_key_hash, 'points:write');
  select point_region into strict v_region from public.api_keys where id=v_key;
  return public.check_competitive_regions(v_region, p_player_ids);
end;
$$;

create function strafe_api.api_authorize_competitive_match(
  p_key_hash text, p_match_id uuid, p_player_ids uuid[], p_expected_region text,
  p_subject_type text, p_subject_a_id uuid, p_subject_b_id uuid
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_key uuid; v_region text;
begin
  v_key := strafe_api.require_point_api_key(p_key_hash, 'points:write');
  select point_region into strict v_region from public.api_keys where id=v_key;
  if p_expected_region is null or p_expected_region not in ('AS','EU','NA','SA','OC','AF') then
    raise exception 'invalid expected competitive region' using errcode='22023';
  end if;
  if p_expected_region <> v_region then
    return pg_catalog.jsonb_build_object('allowed', false, 'reason', 'server_region_mismatch', 'region', v_region);
  end if;
  return public.claim_competitive_match(v_region, p_match_id, p_player_ids,
    p_subject_type, p_subject_a_id, p_subject_b_id);
end;
$$;
alter function strafe_api.api_check_competitive_regions(text, uuid[]) owner to postgres;
alter function strafe_api.api_authorize_competitive_match(text, uuid, uuid[], text, text, uuid, uuid) owner to postgres;
revoke all on function strafe_api.api_check_competitive_regions(text, uuid[])
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
revoke all on function strafe_api.api_authorize_competitive_match(text, uuid, uuid[], text, text, uuid, uuid)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
grant execute on function strafe_api.api_check_competitive_regions(text, uuid[]),
  strafe_api.api_authorize_competitive_match(text, uuid, uuid[], text, text, uuid, uuid)
  to service_role, strafe_points_runtime;

-- The rollout drains all old matches and point outbox events first, so every
-- settlement written after this migration must have an API-issued claim.
create function public.require_competitive_match_claim() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_region text;
begin
  v_region := case when tg_table_schema='public' then 'AS'
    else upper(substr(tg_table_schema, length('strafe_points_') + 1)) end;
  if not exists (select 1 from public.competitive_match_claims claim
      where claim.match_id=new.match_id and claim.region=v_region
        and claim.subject_type=new.subject_type
        and claim.subject_a_id=new.subject_a_id and claim.subject_b_id=new.subject_b_id) then
    raise exception 'competitive_match_claim_required' using errcode='P0001';
  end if;
  return new;
end;
$$;
alter function public.require_competitive_match_claim() owner to postgres;
revoke all on function public.require_competitive_match_claim()
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
create trigger point_matches_require_competitive_region
  before insert on public.point_matches for each row execute function public.require_competitive_match_claim();
do $$
declare v_schema text;
begin
  foreach v_schema in array array['strafe_points_eu','strafe_points_na','strafe_points_sa','strafe_points_oc','strafe_points_af'] loop
    execute format('create trigger point_matches_require_competitive_region before insert on %I.point_matches for each row execute function public.require_competitive_match_claim()', v_schema);
  end loop;
end;
$$;

-- Supabase SQL Editor support operation. It intentionally has no API route or
-- runtime-key grant; use an audited support reason and keep match claims intact.
create function public.transfer_competitive_player_region(p_player_id uuid, p_new_region text, p_actor text, p_reason text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old_region text;
begin
  if p_player_id is null or p_new_region is null or p_new_region not in ('AS','EU','NA','SA','OC','AF')
    or p_actor is null or length(btrim(p_actor)) not between 1 and 80
    or p_reason is null or length(btrim(p_reason)) not between 1 and 500 then
    raise exception 'invalid competitive region transfer' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('competitive-player:' || p_player_id::text, 0));
  select region into v_old_region from public.competitive_player_regions where player_id=p_player_id for update;
  if v_old_region is not distinct from p_new_region then
    return pg_catalog.jsonb_build_object('playerId', p_player_id, 'region', p_new_region, 'changed', false);
  end if;
  insert into public.competitive_region_transfer_audit(player_id, old_region, new_region, actor, reason)
    values (p_player_id, v_old_region, p_new_region, btrim(p_actor), btrim(p_reason));
  insert into public.competitive_player_regions(player_id, region, last_match_id)
    values (p_player_id, p_new_region, null)
    on conflict (player_id) do update set region=excluded.region, assigned_at=now(), last_match_id=excluded.last_match_id;
  return pg_catalog.jsonb_build_object('playerId', p_player_id, 'oldRegion', v_old_region,
    'region', p_new_region, 'changed', true);
end;
$$;
alter function public.transfer_competitive_player_region(uuid, text, text, text) owner to postgres;
revoke all on function public.transfer_competitive_player_region(uuid, text, text, text)
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

notify pgrst, 'reload schema';
