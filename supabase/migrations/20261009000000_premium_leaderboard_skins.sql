create or replace function strafe_api.api_get_account_skins(p_key_hash text, p_player_ids uuid[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key_id uuid;
  v_result jsonb;
begin
  select auth_key.id into v_key_id from strafe_api.authenticate_point_api_key(p_key_hash) as auth_key;
  if v_key_id is null then raise exception 'api_key_invalid' using errcode = 'P0001'; end if;
  if not exists (select 1 from public.api_keys k where k.id = v_key_id and
      (('accounts:read' = any(k.scopes)) or ('leaderboards:read' = any(k.scopes)))) then
    raise exception 'api_key_scope_denied' using errcode = 'P0001';
  end if;
  if p_player_ids is null or cardinality(p_player_ids) > 100 then
    raise exception 'invalid skin lookup' using errcode = '22023';
  end if;
  select coalesce(pg_catalog.jsonb_object_agg(a.player_id::text, pg_catalog.jsonb_build_object(
      'premium', a.premium,
      'linked', a.discord_id is not null,
      'model', s.model,
      'textureUrl', case when s.texture_hash is null then null else 'https://textures.minecraft.net/texture/' || s.texture_hash end,
      'portraitPath', case when s.texture_hash is null then null else '/v1/accounts/portraits/' || s.texture_hash || '/' || s.model || '.png' end)),
    '{}'::jsonb)
    into v_result
    from public.minecraft_accounts a
    left join public.account_skins s on s.player_id = a.player_id
   where a.player_id = any(p_player_ids);
  return pg_catalog.jsonb_build_object('skins', v_result);
end;
$$;

alter function strafe_api.api_get_account_skins(text, uuid[]) owner to postgres;
revoke all on function strafe_api.api_get_account_skins(text, uuid[]) from public, anon, authenticated, service_role, strafe_points_runtime, strafe_points_api;
grant execute on function strafe_api.api_get_account_skins(text, uuid[]) to strafe_points_runtime;
