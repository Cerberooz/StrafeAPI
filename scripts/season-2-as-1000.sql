-- Run in the Supabase SQL Editor after pausing AS ranked queues and sending pending results.
begin;

select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('strafe:smp-active-season', 0));

do $$
declare
  active_season text;
  previous_start integer;
  switched boolean := false;
begin
  select current_season, starting_points into strict active_season, previous_start
  from public.point_settings where singleton = true for update;

  if active_season = 'season-1' then
    update public.point_settings set current_season = 'season-2' where singleton = true;
    switched := true;
  elsif active_season <> 'season-2' then
    raise exception 'Expected AS Season 1 or Season 2, found %', active_season;
  elsif previous_start = 1000 then
    return;
  end if;

  -- The season switch resets the balances to zero. Apply the new baseline before commit.
  update public.point_settings
  set starting_points = 1000, updated_at = pg_catalog.clock_timestamp()
  where singleton = true;

  if switched or previous_start = 0 then
    -- Manual and bulk writes can intentionally put an unplayed entry at zero.
    -- Their results do not always identify all touched rows, so keep those balances.
    if not switched and exists (
      select 1 from public.point_mutations
      where season = 'season-2' and operation in ('set', 'adjust', 'bulk')
    ) then
      raise notice 'Season 2 has manual points adjustments. Existing balances were preserved.';
    else
      update public.point_balances
      set points = 1000, updated_at = pg_catalog.clock_timestamp()
      where points = 0 and wins = 0 and losses = 0;
    end if;
  end if;
end;
$$;

commit;

select current_season, starting_points from public.point_settings where singleton = true;
