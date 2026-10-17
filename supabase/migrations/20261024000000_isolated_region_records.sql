-- AS keeps the existing tables and every existing record. Other regions start
-- empty. Accounts/skins/Discord links and tier bans remain shared identities.
-- Region is an immutable property of a points API key, never client input.
alter table public.api_keys add column point_region text not null default 'AS'
  check (point_region in ('AS','EU','NA','SA','OC','AF'));

create function public.prevent_point_key_region_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.point_region is distinct from old.point_region then
    raise exception 'Issue a new API key for another region; existing keys cannot change region.' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.prevent_point_key_region_change() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
create trigger api_keys_immutable_point_region before update of point_region on public.api_keys
for each row execute function public.prevent_point_key_region_change();

create function public.enforce_point_profile_region() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.region := case when tg_table_schema = 'public' then 'AS'
    else upper(substr(tg_table_schema, length('strafe_points_') + 1)) end;
  if new.region not in ('AS','EU','NA','SA','OC','AF') then
    raise exception 'Invalid points schema' using errcode = '22023';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_point_profile_region() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
alter table public.point_profiles alter column region set default 'AS';
create trigger point_profiles_region before insert or update on public.point_profiles
for each row execute function public.enforce_point_profile_region();
update public.point_profiles set region = 'AS' where region is distinct from 'AS';

-- Refreshable implementation copies preserve the existing SQL's row locks,
-- idempotency, season guards and triggers. Only points relations/functions are
-- redirected; global account/authentication/moderation references stay global.
-- Future migrations changing points SQL must call this helper at their end.
create function public.refresh_regional_points_implementations() returns void
language plpgsql security definer set search_path = '' as $refresh$
declare
  v_region text;
  v_schema text;
  v_names text[];
  v_table text;
  v_name text;
  v_definition text;
  v_created boolean;
  item record;
  v_tables constant text[] := array['point_settings','point_seasons','point_balances','point_profiles',
    'point_mutations','point_matches','point_matches_archive','point_subject_tombstones',
    'point_season_balances','point_season_team_rosters'];
  v_entries constant text[] := array['api_get_point_balance','api_get_points_snapshot',
    'api_get_points_leaderboard','api_get_points_leaderboard_for_season','api_get_smp_leaderboard_seasons',
    'api_mutate_points','api_seed_point_snapshot','api_finalize_point_snapshot_import','api_sync_point_profiles','api_get_tier_profile'];
begin
  select array_agg(distinct p.proname::text) into v_names
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname <> 'refresh_regional_points_implementations'
      and (p.prosrc ~ 'public[.]point_' or p.proname = 'enforce_point_profile_region');
  foreach v_region in array array['EU','NA','SA','OC','AF'] loop
    v_schema := 'strafe_points_' || lower(v_region);
    v_created := not exists (select 1 from pg_catalog.pg_namespace where nspname = v_schema);
    execute format('create schema if not exists %I authorization postgres', v_schema);
    execute format('revoke all on schema %I from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api', v_schema);
    foreach v_table in array v_tables loop
      execute format('create table if not exists %I.%I (like public.%I including all)', v_schema, v_table, v_table);
      execute format('alter table %I.%I enable row level security', v_schema, v_table);
    end loop;
    -- LIKE deliberately does not copy foreign keys. Copy them with regional
    -- references, preserving any references to shared identity tables.
    if v_created then
      for item in select c.conname, t.relname, pg_catalog.pg_get_constraintdef(c.oid) as definition
        from pg_catalog.pg_constraint c join pg_catalog.pg_class t on t.oid = c.conrelid
        join pg_catalog.pg_namespace n on n.oid = t.relnamespace
        where n.nspname = 'public' and t.relname = any(v_tables) and c.contype = 'f'
      loop
        v_definition := item.definition;
        foreach v_table in array v_tables loop
          v_definition := replace(v_definition, 'REFERENCES public.' || v_table || '(', 'REFERENCES ' || v_schema || '.' || v_table || '(');
          v_definition := replace(v_definition, 'REFERENCES ' || v_table || '(', 'REFERENCES ' || v_schema || '.' || v_table || '(');
        end loop;
        execute format('alter table %I.%I add constraint %I %s', v_schema, item.relname, item.conname, v_definition);
      end loop;
      -- Regional season metadata begins at the current AS season, with its own
      -- import gate and subsequent season lifecycle. No AS balances are copied.
      execute format('insert into %I.point_seasons select s.* from public.point_seasons s join public.point_settings p on p.current_season=s.season where p.singleton', v_schema);
      execute format('update %I.point_seasons set allow_snapshot_import=true, enforce_match_start_cutoff=false, completed_at=null', v_schema);
      execute format('insert into %I.point_settings select * from public.point_settings', v_schema);
    end if;
    for item in select n.nspname, p.proname, pg_catalog.pg_get_functiondef(p.oid) as definition
      from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
      where (n.nspname = 'public' and p.proname = any(v_names))
        or (n.nspname = 'strafe_api' and p.proname = any(v_entries))
      order by n.nspname, p.proname, p.oid
    loop
      v_definition := item.definition;
      -- Longest first avoids replacing point_matches inside point_matches_archive.
      for v_table in select t.name from unnest(v_tables) as t(name) order by length(t.name) desc loop
        v_definition := replace(v_definition, 'public.' || v_table, v_schema || '.' || v_table);
      end loop;
      foreach v_name in array v_names loop
        v_definition := replace(v_definition, 'public.' || v_name || '(', v_schema || '.' || v_name || '(');
      end loop;
      if item.nspname = 'strafe_api' then
        v_definition := replace(v_definition, 'FUNCTION strafe_api.' || item.proname || '(', 'FUNCTION ' || v_schema || '.' || item.proname || '(');
      end if;
      -- Namespaced advisory locks keep unrelated regions from contending.
      v_definition := replace(v_definition, 'pg_catalog.hashtextextended(', 'pg_catalog.hashtextextended(' || quote_literal('region:' || v_region || ':') || ' || ');
      -- The AS entry point guard is also rewritten when refreshing later.
      v_definition := replace(v_definition, 'strafe_api.require_point_region(p_key_hash, ''AS'')', 'strafe_api.require_point_region(p_key_hash, ' || quote_literal(v_region) || ')');
      execute v_definition;
    end loop;
    for item in select t.tgname, c.relname, pg_catalog.pg_get_triggerdef(t.oid) as definition
      from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid
      join pg_catalog.pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=any(v_tables) and not t.tgisinternal
    loop
      v_definition := item.definition;
      foreach v_table in array v_tables loop
        v_definition := replace(v_definition, ' ON public.' || v_table || ' ', ' ON ' || v_schema || '.' || v_table || ' ');
      end loop;
      foreach v_name in array v_names loop
        v_definition := replace(v_definition, 'public.' || v_name || '(', v_schema || '.' || v_name || '(');
      end loop;
      execute format('drop trigger if exists %I on %I.%I', item.tgname, v_schema, item.relname);
      execute v_definition;
    end loop;
    execute format('alter table %I.point_profiles alter column region set default %L', v_schema, v_region);
    execute format('revoke all on all tables in schema %I from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api', v_schema);
    execute format('revoke all on all functions in schema %I from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api', v_schema);
  end loop;
end;
$refresh$;
revoke all on function public.refresh_regional_points_implementations() from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

create function strafe_api.require_point_region(p_key_hash text, p_region text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.api_keys k where k.key_hash=p_key_hash and k.point_region=p_region
    and k.revoked_at is null and (k.expires_at is null or k.expires_at > pg_catalog.now())) then
    raise exception 'api_key_region_denied' using errcode='P0001';
  end if;
end;
$$;
revoke all on function strafe_api.require_point_region(text,text) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;

-- Guard legacy AS points entry points, including direct RPC access. Leaderboard
-- readers may select any region; points readers/writers stay bound to their key.
do $guard$
declare item record; v_definition text;
begin
  for item in select pg_catalog.pg_get_functiondef(p.oid) as definition
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where n.nspname='strafe_api' and p.proname in ('api_get_point_balance','api_get_points_snapshot',
      'api_mutate_points','api_seed_point_snapshot','api_finalize_point_snapshot_import','api_sync_point_profiles')
  loop
    v_definition := regexp_replace(item.definition, E'\\mbegin\\M', E'begin\n  perform strafe_api.require_point_region(p_key_hash, ''AS'');', 'i');
    if v_definition = item.definition then
      raise exception 'Could not install AS region guard';
    end if;
    execute v_definition;
  end loop;
end;
$guard$;
select public.refresh_regional_points_implementations();

-- One allowlisted RPC dispatcher supports both HTTPS PostgREST and PostgreSQL
-- transports. It never accepts an arbitrary schema or function name.
create function strafe_api.regional_points_call(p_key_hash text, p_region text, p_call text, p_parameters jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_key uuid;
  v_region text;
  v_schema text;
  v_scope text;
  v_result jsonb;
  v_args text;
begin
  v_scope := case when p_call in ('get_tier_profile','get_points_leaderboard','get_points_leaderboard_for_season','get_smp_leaderboard_seasons') then 'leaderboards:read'
    when p_call in ('get_point_balance','get_points_snapshot') then 'points:read'
    when p_call in ('mutate_points','seed_point_snapshot','finalize_point_snapshot_import','sync_point_profiles') then 'points:write'
    else null end;
  if v_scope is null then raise exception 'Invalid regional operation' using errcode='22023'; end if;
  v_key := strafe_api.require_point_api_key(p_key_hash, v_scope);
  select point_region into strict v_region from public.api_keys where id=v_key;
  if p_region is not null then
    if p_region not in ('AS','EU','NA','SA','OC','AF') then raise exception 'Invalid region' using errcode='22023'; end if;
    if v_scope <> 'leaderboards:read' and p_region <> v_region then
      raise exception 'api_key_region_denied' using errcode='P0001';
    end if;
    v_region := p_region;
  end if;
  v_schema := case when v_region='AS' then 'strafe_api' else 'strafe_points_' || lower(v_region) end;
  v_args := case p_call
    when 'get_tier_profile' then '$1, ($2->>''p_name'')'
    when 'get_point_balance' then '$1, ($2->>''p_subject_type''), ($2->>''p_subject_id'')::uuid'
    when 'get_points_snapshot' then '$1, ($2->>''p_subject_type''), ($2->>''p_limit'')::integer, ($2->>''p_after'')::uuid'
    when 'get_points_leaderboard' then '$1, ($2->>''p_subject_type''), ($2->>''p_limit'')::integer, ($2->>''p_offset'')::integer, ($2->>''p_mode'')'
    when 'get_points_leaderboard_for_season' then '$1, ($2->>''p_subject_type''), ($2->>''p_limit'')::integer, ($2->>''p_offset'')::integer, ($2->>''p_mode''), ($2->>''p_season'')'
    when 'get_smp_leaderboard_seasons' then '$1'
    when 'mutate_points' then '$1, ($2->>''p_event_id'')::uuid, ($2->>''p_request_hash''), ($2->>''p_operation''), ($2->''p_payload'')'
    when 'seed_point_snapshot' then '$1, ($2->''p_balances''), ($2->>''p_create_missing'')::boolean'
    when 'finalize_point_snapshot_import' then '$1'
    when 'sync_point_profiles' then '$1, ($2->''p_profiles'')' end;
  execute format('select %I.%I(%s)', v_schema, 'api_' || p_call, v_args) into v_result using p_key_hash, p_parameters;
  v_result := v_result || jsonb_build_object('region', v_region);
  -- Include region even when a standing has no profile metadata yet.
  if jsonb_typeof(v_result->'items')='array' then
    v_result := jsonb_set(v_result, '{items}', (select coalesce(jsonb_agg(e.value || jsonb_build_object('region',v_region) order by e.ordinality),'[]'::jsonb) from jsonb_array_elements(v_result->'items') with ordinality e));
  end if;
  if jsonb_typeof(v_result->'standings')='array' then
    v_result := jsonb_set(v_result, '{standings}', (select coalesce(jsonb_agg(e.value || jsonb_build_object('region',v_region) order by e.ordinality),'[]'::jsonb) from jsonb_array_elements(v_result->'standings') with ordinality e));
  end if;
  return v_result;
end;
$$;
revoke all on function strafe_api.regional_points_call(text,text,text,jsonb) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
grant execute on function strafe_api.regional_points_call(text,text,text,jsonb) to service_role, strafe_points_runtime;
create or replace function strafe_api.points_api_ready() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.point_settings where singleton=true)
    and (select count(*)=5 from pg_catalog.pg_namespace where nspname in
      ('strafe_points_eu','strafe_points_na','strafe_points_sa','strafe_points_oc','strafe_points_af'))
$$;
notify pgrst, 'reload schema';
