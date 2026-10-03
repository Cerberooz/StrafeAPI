-- No table grants or public access: only scoped RPC entry points.
grant usage on schema strafe_api to service_role;
do $https_grants$
declare item record;
begin
  for item in select p.oid::regprocedure as signature
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'strafe_api' and p.proname in ('authenticate_point_api_key', 'api_account_session_end', 'api_account_session_upsert_with_tier_status', 'api_admin_recover_account_link', 'api_begin_account_oauth', 'api_cancel_account_skin', 'api_commit_account_skin', 'api_confirm_account_link', 'api_finish_account_oauth', 'api_get_account_link', 'api_get_account_skins', 'api_get_account_with_tier_status', 'api_get_point_balance', 'api_get_points_leaderboard', 'api_get_points_leaderboard_for_season', 'api_get_points_snapshot', 'api_get_smp_leaderboard_seasons', 'api_get_tier_ban_statuses', 'api_get_tier_players', 'api_has_account_portrait', 'api_moderate_tier_ban', 'api_mutate_points', 'api_prepare_account_skin', 'api_seed_point_snapshot', 'api_start_account_link', 'api_sync_point_profiles', 'points_api_ready')
  loop
    execute format('grant execute on function %s to service_role', item.signature);
  end loop;
end;
$https_grants$;
notify pgrst, 'reload schema';
