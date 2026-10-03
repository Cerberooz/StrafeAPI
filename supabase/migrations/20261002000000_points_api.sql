-- Live API-owned point balances and match settlement data.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.api_keys (
  id uuid primary key default gen_random_uuid(),
  label text not null check (length(btrim(label)) between 1 and 80),
  key_prefix text not null unique check (length(key_prefix) between 12 and 32),
  key_hash text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  scopes text[] not null default '{}'::text[],
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz
);

create table if not exists public.point_settings (
  singleton boolean primary key default true check (singleton),
  starting_points integer not null default 1000 check (starting_points between 0 and 2147483647),
  updated_at timestamptz not null default now()
);

insert into public.point_settings(singleton, starting_points)
values (true, 1000)
on conflict (singleton) do nothing;

create table if not exists public.point_balances (
  subject_type text not null check (subject_type in ('team', 'player')),
  subject_id uuid not null,
  points integer not null default 1000 check (points between 0 and 2147483647),
  wins integer not null default 0 check (wins between 0 and 2147483647),
  losses integer not null default 0 check (losses between 0 and 2147483647),
  updated_at timestamptz not null default now(),
  primary key (subject_type, subject_id)
);

create index if not exists point_balances_leaderboard_idx
  on public.point_balances(subject_type, points desc, subject_id);

create table if not exists public.point_profiles (
  subject_type text not null check (subject_type in ('team', 'player')),
  subject_id uuid not null,
  display_name text check (display_name is null or length(display_name) <= 255),
  prefix text check (prefix is null or length(prefix) <= 64),
  member_count integer check (member_count is null or member_count between 0 and 1000),
  updated_at timestamptz not null default now(),
  primary key (subject_type, subject_id),
  check (subject_type = 'team' or member_count is null)
);

create table if not exists public.point_mutations (
  event_id uuid primary key,
  operation text not null check (operation in ('adjust', 'set', 'bulk', 'match', 'delete')),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  api_key_id uuid,
  reason text check (reason is null or length(reason) <= 128),
  result jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.point_matches (
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
  created_at timestamptz not null default now(),
  check (subject_a_id <> subject_b_id),
  check (winner_id is null or winner_id in (subject_a_id, subject_b_id)),
  check (ended_at >= started_at),
  check ((subject_type = 'team' and battle_size is not null) or (subject_type = 'player' and battle_size is null)),
  check (ranked or (delta_a = 0 and delta_b = 0))
);

create table if not exists public.point_subject_tombstones (
  subject_type text not null check (subject_type in ('team', 'player')),
  subject_id uuid not null,
  event_id uuid not null references public.point_mutations(event_id) on delete restrict,
  deleted_at timestamptz not null default now(),
  primary key (subject_type, subject_id)
);

alter table public.api_keys enable row level security;
alter table public.point_settings enable row level security;
alter table public.point_balances enable row level security;
alter table public.point_profiles enable row level security;
alter table public.point_mutations enable row level security;
alter table public.point_matches enable row level security;
alter table public.point_subject_tombstones enable row level security;

revoke all on table public.api_keys, public.point_settings, public.point_balances,
  public.point_profiles, public.point_mutations, public.point_matches
  from public, anon, authenticated, service_role;
revoke all on table public.point_subject_tombstones
  from public, anon, authenticated, service_role;

create or replace function public.issue_api_key(p_label text, p_scopes text[])
returns table(api_key text, key_prefix text, key_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_prefix text;
  v_id uuid;
  v_scope text;
begin
  if p_label is null or length(btrim(p_label)) not between 1 and 80 then
    raise exception 'label must have 1 to 80 characters' using errcode = '22023';
  end if;
  if p_scopes is null or cardinality(p_scopes) = 0 then
    raise exception 'at least one scope is required' using errcode = '22023';
  end if;
  foreach v_scope in array p_scopes loop
    if v_scope is null or v_scope not in ('leaderboards:read', 'points:read', 'points:write') then
      raise exception 'unsupported API key scope' using errcode = '22023';
    end if;
  end loop;

  v_token := 'ssmp_live_' || pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
  v_prefix := pg_catalog.left(v_token, 21);
  insert into public.api_keys(label, key_prefix, key_hash, scopes)
  values (
    btrim(p_label),
    v_prefix,
    pg_catalog.encode(extensions.digest(pg_catalog.convert_to(v_token, 'UTF8'), 'sha256'), 'hex'),
    array(select distinct scope from unnest(p_scopes) as scopes(scope) order by scope)
  )
  returning id into v_id;

  return query select v_token, v_prefix, v_id;
end;
$$;

revoke all on function public.issue_api_key(text, text[]) from public, anon, authenticated, service_role;
grant execute on function public.issue_api_key(text, text[]) to postgres;

create or replace function public.get_point_balance(p_subject_type text, p_subject_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_subject_type is null or p_subject_type not in ('team', 'player') or p_subject_id is null then
    raise exception 'invalid point subject' using errcode = '22023';
  end if;
  if exists (select 1 from public.point_subject_tombstones where subject_type = p_subject_type and subject_id = p_subject_id) then
    raise exception 'subject_deleted' using errcode = 'P0001';
  end if;
  return (
    select pg_catalog.jsonb_build_object(
    'balance', pg_catalog.jsonb_build_object(
      'subjectType', p_subject_type,
      'subjectId', p_subject_id,
      'displayName', profile.display_name,
      'prefix', profile.prefix,
      'memberCount', profile.member_count,
      'points', coalesce(balance.points, settings.starting_points),
      'wins', coalesce(balance.wins, 0),
      'losses', coalesce(balance.losses, 0)
    )
  )
  from public.point_settings as settings
  left join public.point_balances as balance
    on balance.subject_type = p_subject_type and balance.subject_id = p_subject_id
  left join public.point_profiles as profile
    on profile.subject_type = p_subject_type and profile.subject_id = p_subject_id
  where settings.singleton = true
  );
end;
$$;

create or replace function public.get_points_snapshot(p_subject_type text, p_limit integer, p_after uuid default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_item record;
  v_items jsonb := '[]'::jsonb;
  v_count integer := 0;
  v_next uuid := null;
begin
  if p_subject_type not in ('team', 'player') or p_limit < 1 or p_limit > 500 then
    raise exception 'invalid snapshot request' using errcode = '22023';
  end if;

  for v_item in
    select balance.subject_id, balance.points, balance.wins, balance.losses,
           profile.display_name, profile.prefix, profile.member_count
    from public.point_balances as balance
    left join public.point_profiles as profile
      on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
    where balance.subject_type = p_subject_type
      and (p_after is null or balance.subject_id > p_after)
    order by balance.subject_id
    limit p_limit + 1
  loop
    v_count := v_count + 1;
    if v_count <= p_limit then
      v_items := v_items || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'subjectType', p_subject_type,
        'subjectId', v_item.subject_id,
        'displayName', v_item.display_name,
        'prefix', v_item.prefix,
        'memberCount', v_item.member_count,
        'points', v_item.points,
        'wins', v_item.wins,
        'losses', v_item.losses
      ));
      v_next := v_item.subject_id;
    end if;
  end loop;

  if v_count <= p_limit then v_next := null; end if;
  return pg_catalog.jsonb_build_object(
    'subjectType', p_subject_type,
    'items', v_items,
    'nextCursor', v_next
  );
end;
$$;

create or replace function public.get_points_leaderboard(p_subject_type text, p_limit integer, p_offset integer, p_mode text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The public route validates pagination, and this guard also protects direct RPC callers.
  with ranked as (
    select balance.subject_type, balance.subject_id, balance.points, balance.wins, balance.losses,
           profile.display_name, profile.prefix, profile.member_count,
           pg_catalog.rank() over (order by balance.points desc)::integer as rank,
           pg_catalog.count(*) over () as total_count
    from public.point_balances as balance
    left join public.point_profiles as profile
      on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
    where balance.subject_type = p_subject_type
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

create or replace function public.mutate_points(
  p_event_id uuid,
  p_request_hash text,
  p_api_key_id uuid,
  p_operation text,
  p_payload jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_rows integer;
  v_cached public.point_mutations%rowtype;
  v_subject_type text;
  v_subject_id uuid;
  v_subject_a uuid;
  v_subject_b uuid;
  v_lock_first uuid;
  v_lock_second uuid;
  v_winner uuid;
  v_points integer;
  v_wins integer;
  v_losses integer;
  v_delta bigint;
  v_delta_a integer;
  v_delta_b integer;
  v_amount bigint;
  v_starting_points integer;
  v_ranked boolean;
  v_display jsonb;
  v_display_row record;
  v_display_name text;
  v_prefix text;
  v_member_count integer;
  v_reason text;
  v_battle_size integer;
  v_affected integer;
  v_result jsonb;
  v_item_a jsonb;
  v_item_b jsonb;
begin
  if p_event_id is null or p_request_hash is null or p_request_hash !~ '^[0-9a-f]{64}$' or p_payload is null or pg_catalog.jsonb_typeof(p_payload) <> 'object' then
    raise exception 'invalid mutation request' using errcode = '22023';
  end if;
  if p_operation is null or p_operation not in ('adjust', 'set', 'bulk', 'match', 'delete') then
    raise exception 'invalid mutation operation' using errcode = '22023';
  end if;

  insert into public.point_mutations(event_id, operation, request_hash, api_key_id, reason)
  values (p_event_id, p_operation, p_request_hash, p_api_key_id, nullif(p_payload->>'reason', ''))
  on conflict (event_id) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    select * into v_cached from public.point_mutations where event_id = p_event_id;
    if v_cached.request_hash <> p_request_hash then
      raise exception 'idempotency_conflict' using errcode = 'P0001';
    end if;
    return v_cached.result || pg_catalog.jsonb_build_object('duplicate', true);
  end if;

  select starting_points into strict v_starting_points from public.point_settings where singleton = true;

  if p_operation in ('adjust', 'set') then
    v_subject_type := p_payload->>'subjectType';
    v_subject_id := (p_payload->>'subjectId')::uuid;
    v_reason := p_payload->>'reason';
    if v_subject_type is null or v_subject_type not in ('team', 'player') or v_subject_id is null then
      raise exception 'invalid point subject' using errcode = '22023';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_subject_type || ':' || v_subject_id::text, 0));
    if exists (select 1 from public.point_subject_tombstones where subject_type = v_subject_type and subject_id = v_subject_id) then
      raise exception 'subject_deleted' using errcode = 'P0001';
    end if;

    if p_operation = 'adjust' then
      v_delta := (p_payload->>'delta')::bigint;
      if v_delta < -2147483647 or v_delta > 2147483647 then
        raise exception 'invalid point delta' using errcode = '22023';
      end if;
      insert into public.point_balances(subject_type, subject_id, points)
      values (v_subject_type, v_subject_id, greatest(0::bigint, least(2147483647::bigint, v_starting_points::bigint + v_delta))::integer)
      on conflict (subject_type, subject_id) do update set
        points = greatest(0::bigint, least(2147483647::bigint, public.point_balances.points::bigint + v_delta))::integer,
        updated_at = now()
      returning points, wins, losses into v_points, v_wins, v_losses;
    else
      v_points := (p_payload->>'points')::integer;
      if v_points < 0 or v_points > 2147483647 then
        raise exception 'invalid point value' using errcode = '22023';
      end if;
      insert into public.point_balances(subject_type, subject_id, points)
      values (v_subject_type, v_subject_id, v_points)
      on conflict (subject_type, subject_id) do update set
        points = excluded.points,
        updated_at = now()
      returning points, wins, losses into v_points, v_wins, v_losses;
    end if;

    if p_payload ? 'displayName' or p_payload ? 'prefix' or p_payload ? 'memberCount' then
      insert into public.point_profiles(subject_type, subject_id, display_name, prefix, member_count)
      values (v_subject_type, v_subject_id, p_payload->>'displayName', p_payload->>'prefix', nullif(p_payload->>'memberCount', '')::integer)
      on conflict (subject_type, subject_id) do update set
        display_name = case when p_payload ? 'displayName' then excluded.display_name else public.point_profiles.display_name end,
        prefix = case when p_payload ? 'prefix' then excluded.prefix else public.point_profiles.prefix end,
        member_count = case when p_payload ? 'memberCount' then excluded.member_count else public.point_profiles.member_count end,
        updated_at = now();
    end if;
    select display_name, prefix, member_count into v_display_name, v_prefix, v_member_count
      from public.point_profiles where subject_type = v_subject_type and subject_id = v_subject_id;
    v_result := pg_catalog.jsonb_build_object(
      'eventId', p_event_id,
      'duplicate', false,
      'items', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'subjectType', v_subject_type,
        'subjectId', v_subject_id,
        'displayName', v_display_name,
        'prefix', v_prefix,
        'memberCount', v_member_count,
        'points', v_points,
        'wins', v_wins,
        'losses', v_losses
      ))
    );
  elsif p_operation = 'bulk' then
    v_subject_type := p_payload->>'subjectType';
    if v_subject_type is null or v_subject_type not in ('team', 'player') then
      raise exception 'invalid point subject' using errcode = '22023';
    end if;
    if p_payload->>'operation' not in ('adjust', 'set') then
      raise exception 'invalid bulk operation' using errcode = '22023';
    end if;
    v_amount := (p_payload->>'amount')::bigint;
    if v_amount < -2147483647 or v_amount > 2147483647 or (p_payload->>'operation' = 'set' and v_amount < 0) then
      raise exception 'invalid bulk point value' using errcode = '22023';
    end if;
    perform 1 from public.point_balances
      where subject_type = v_subject_type
      order by subject_id
      for update;
    if p_payload->>'operation' = 'adjust' then
      update public.point_balances
      set points = greatest(0::bigint, least(2147483647::bigint, points::bigint + v_amount))::integer,
          updated_at = now()
      where subject_type = v_subject_type;
    else
      update public.point_balances
      set points = v_amount::integer,
          updated_at = now()
      where subject_type = v_subject_type;
    end if;
    get diagnostics v_affected = row_count;
    v_result := pg_catalog.jsonb_build_object('eventId', p_event_id, 'duplicate', false, 'affectedCount', v_affected);
  elsif p_operation = 'match' then
    v_subject_type := p_payload->>'subjectType';
    v_subject_a := (p_payload->>'subjectAId')::uuid;
    v_subject_b := (p_payload->>'subjectBId')::uuid;
    v_winner := nullif(p_payload->>'winnerId', '')::uuid;
    v_ranked := (p_payload->>'ranked')::boolean;
    v_delta_a := (p_payload->>'deltaA')::integer;
    v_delta_b := (p_payload->>'deltaB')::integer;
    v_battle_size := nullif(p_payload->>'battleSize', '')::integer;
    if v_subject_type is null or v_subject_type not in ('team', 'player') or v_subject_a is null or v_subject_b is null or v_subject_a = v_subject_b then
      raise exception 'invalid match subjects' using errcode = '22023';
    end if;
    if v_winner is not null and v_winner not in (v_subject_a, v_subject_b) then
      raise exception 'invalid match winner' using errcode = '22023';
    end if;
    if not v_ranked and (v_delta_a <> 0 or v_delta_b <> 0) then
      raise exception 'unranked matches cannot change points' using errcode = '22023';
    end if;
    if (v_subject_type = 'team' and (v_battle_size is null or v_battle_size < 2 or v_battle_size > 1000))
      or (v_subject_type = 'player' and v_battle_size is not null) then
      raise exception 'invalid match size' using errcode = '22023';
    end if;
    if v_winner is null and (v_delta_a <> 0 or v_delta_b <> 0) then
      raise exception 'draws cannot change points' using errcode = '22023';
    end if;

    -- Lock both identities in UUID order. Deletion, seed, and profile sync use the same lock.
    v_lock_first := least(v_subject_a, v_subject_b);
    v_lock_second := greatest(v_subject_a, v_subject_b);
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_subject_type || ':' || v_lock_first::text, 0));
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_subject_type || ':' || v_lock_second::text, 0));
    if exists (
      select 1 from public.point_subject_tombstones
      where subject_type = v_subject_type and subject_id in (v_subject_a, v_subject_b)
    ) then
      raise exception 'subject_deleted' using errcode = 'P0001';
    end if;

    insert into public.point_balances(subject_type, subject_id, points, wins, losses)
    values (
      v_subject_type,
      v_subject_a,
      greatest(0::bigint, least(2147483647::bigint, v_starting_points::bigint + v_delta_a))::integer,
      case when v_winner = v_subject_a then 1 else 0 end,
      case when v_winner = v_subject_b then 1 else 0 end
    )
    on conflict (subject_type, subject_id) do update set
      points = greatest(0::bigint, least(2147483647::bigint, public.point_balances.points::bigint + v_delta_a))::integer,
      wins = least(2147483647::bigint, public.point_balances.wins::bigint + excluded.wins::bigint)::integer,
      losses = least(2147483647::bigint, public.point_balances.losses::bigint + excluded.losses::bigint)::integer,
      updated_at = now();

    insert into public.point_balances(subject_type, subject_id, points, wins, losses)
    values (
      v_subject_type,
      v_subject_b,
      greatest(0::bigint, least(2147483647::bigint, v_starting_points::bigint + v_delta_b))::integer,
      case when v_winner = v_subject_b then 1 else 0 end,
      case when v_winner = v_subject_a then 1 else 0 end
    )
    on conflict (subject_type, subject_id) do update set
      points = greatest(0::bigint, least(2147483647::bigint, public.point_balances.points::bigint + v_delta_b))::integer,
      wins = least(2147483647::bigint, public.point_balances.wins::bigint + excluded.wins::bigint)::integer,
      losses = least(2147483647::bigint, public.point_balances.losses::bigint + excluded.losses::bigint)::integer,
      updated_at = now();

    for v_display_row in select key, value from pg_catalog.jsonb_each(p_payload) where key in ('displayA', 'displayB')
    loop
      v_display := v_display_row.value;
      if v_display ? 'displayName' or v_display ? 'prefix' or v_display ? 'memberCount' then
        if v_display_row.key = 'displayA' then
          v_subject_id := v_subject_a;
        else
          v_subject_id := v_subject_b;
        end if;
        insert into public.point_profiles(subject_type, subject_id, display_name, prefix, member_count)
        values (v_subject_type, v_subject_id, v_display->>'displayName', v_display->>'prefix', nullif(v_display->>'memberCount', '')::integer)
        on conflict (subject_type, subject_id) do update set
          display_name = case when v_display ? 'displayName' then excluded.display_name else public.point_profiles.display_name end,
          prefix = case when v_display ? 'prefix' then excluded.prefix else public.point_profiles.prefix end,
          member_count = case when v_display ? 'memberCount' then excluded.member_count else public.point_profiles.member_count end,
          updated_at = now();
      end if;
    end loop;

    insert into public.point_matches(match_id, subject_type, subject_a_id, subject_b_id, winner_id, ranked,
      started_at, ended_at, duration_seconds, battle_size, delta_a, delta_b)
    values (
      p_event_id,
      v_subject_type,
      v_subject_a,
      v_subject_b,
      v_winner,
      v_ranked,
      pg_catalog.to_timestamp(((p_payload->>'startedAt')::bigint)::double precision / 1000.0),
      pg_catalog.to_timestamp(((p_payload->>'endedAt')::bigint)::double precision / 1000.0),
      (p_payload->>'durationSeconds')::integer,
      v_battle_size,
      v_delta_a,
      v_delta_b
    );

    select pg_catalog.jsonb_build_object(
      'subjectType', balance.subject_type,
      'subjectId', balance.subject_id,
      'displayName', profile.display_name,
      'prefix', profile.prefix,
      'memberCount', profile.member_count,
      'points', balance.points,
      'wins', balance.wins,
      'losses', balance.losses
    ) into v_item_a
    from public.point_balances as balance
    left join public.point_profiles as profile
      on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
    where balance.subject_type = v_subject_type and balance.subject_id = v_subject_a;

    select pg_catalog.jsonb_build_object(
      'subjectType', balance.subject_type,
      'subjectId', balance.subject_id,
      'displayName', profile.display_name,
      'prefix', profile.prefix,
      'memberCount', profile.member_count,
      'points', balance.points,
      'wins', balance.wins,
      'losses', balance.losses
    ) into v_item_b
    from public.point_balances as balance
    left join public.point_profiles as profile
      on profile.subject_type = balance.subject_type and profile.subject_id = balance.subject_id
    where balance.subject_type = v_subject_type and balance.subject_id = v_subject_b;

    v_result := pg_catalog.jsonb_build_object(
      'eventId', p_event_id,
      'duplicate', false,
      'items', pg_catalog.jsonb_build_array(v_item_a, v_item_b)
    );
  else
    v_subject_type := p_payload->>'subjectType';
    v_subject_id := (p_payload->>'subjectId')::uuid;
    if v_subject_type is null or v_subject_type not in ('team', 'player') or v_subject_id is null then
      raise exception 'invalid point subject' using errcode = '22023';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_subject_type || ':' || v_subject_id::text, 0));
    insert into public.point_subject_tombstones(subject_type, subject_id, event_id)
    values (v_subject_type, v_subject_id, p_event_id)
    on conflict (subject_type, subject_id) do nothing;
    delete from public.point_balances where subject_type = v_subject_type and subject_id = v_subject_id;
    get diagnostics v_affected = row_count;
    delete from public.point_profiles where subject_type = v_subject_type and subject_id = v_subject_id;
    v_result := pg_catalog.jsonb_build_object('eventId', p_event_id, 'duplicate', false, 'deletedCount', v_affected);
  end if;

  update public.point_mutations set result = v_result where event_id = p_event_id;
  return v_result;
end;
$$;

create or replace function public.seed_point_snapshot(p_api_key_id uuid, p_balances jsonb)
returns jsonb
language plpgsql
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
begin
  if p_balances is null or pg_catalog.jsonb_typeof(p_balances) <> 'array' or pg_catalog.jsonb_array_length(p_balances) > 500 then
    raise exception 'snapshot must contain at most 500 rows' using errcode = '22023';
  end if;
  -- Reserve every identity in stable order before processing rows in caller order.
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

    insert into public.point_balances(subject_type, subject_id, points, wins, losses)
    values (v_subject_type, v_subject_id, (v_row->>'points')::integer,
      coalesce((v_row->>'wins')::integer, 0), coalesce((v_row->>'losses')::integer, 0))
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
  if p_profiles is null or pg_catalog.jsonb_typeof(p_profiles) <> 'array' or pg_catalog.jsonb_array_length(p_profiles) > 500 then
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
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_subject_type || ':' || v_subject_id::text, 0));
    if exists (select 1 from public.point_subject_tombstones where subject_type = v_subject_type and subject_id = v_subject_id) then
      continue;
    end if;
    insert into public.point_profiles(subject_type, subject_id, display_name, prefix, member_count)
    values (v_subject_type, v_subject_id, v_row->>'displayName', v_row->>'prefix', nullif(v_row->>'memberCount', '')::integer)
    on conflict (subject_type, subject_id) do update set
      display_name = case when v_row ? 'displayName' then excluded.display_name else public.point_profiles.display_name end,
      prefix = case when v_row ? 'prefix' then excluded.prefix else public.point_profiles.prefix end,
      member_count = case when v_row ? 'memberCount' then excluded.member_count else public.point_profiles.member_count end,
      updated_at = now();
    v_count := v_count + 1;
  end loop;
  return pg_catalog.jsonb_build_object('updatedCount', v_count);
end;
$$;

revoke all on function public.get_point_balance(text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.get_points_snapshot(text, integer, uuid) from public, anon, authenticated, service_role;
revoke all on function public.get_points_leaderboard(text, integer, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.mutate_points(uuid, text, uuid, text, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.seed_point_snapshot(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.sync_point_profiles(uuid, jsonb) from public, anon, authenticated, service_role;
