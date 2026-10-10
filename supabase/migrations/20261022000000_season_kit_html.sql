-- Editable presentation content for each season's website Kit tab.
alter table public.point_seasons
  add column if not exists kit_html text;

alter table public.point_seasons
  add constraint point_seasons_kit_html_length_check
  check (kit_html is null or length(kit_html) <= 20000);

grant update (kit_html) on public.point_seasons to service_role;

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
        'completedAt', season.completed_at,
        'kitImageUrl', season.kit_image_url,
        'kitHtml', season.kit_html
      ) order by season.started_at desc, season.season desc)
      from public.point_seasons as season
    ), '[]'::jsonb)
  )
  from public.point_settings as settings
  where settings.singleton = true
$$;

alter function public.get_smp_leaderboard_seasons() owner to postgres;
revoke all on function public.get_smp_leaderboard_seasons()
  from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
