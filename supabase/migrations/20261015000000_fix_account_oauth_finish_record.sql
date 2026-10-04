create or replace function strafe_api.api_finish_account_oauth(
  p_request_id uuid, p_step text, p_state_hash text, p_discord_id text, p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt record;
  v_link record;
begin
  if p_discord_id !~ '^[0-9]{17,20}$' or p_display_name is null or length(p_display_name) not between 1 and 100 then
    raise exception 'invalid Discord identity' using errcode = '22023';
  end if;
  select request_id, step, expires_at, used_at into v_attempt
    from public.account_oauth_states where state_hash = p_state_hash for update;
  if not found or v_attempt.request_id <> p_request_id or v_attempt.step <> p_step
      or v_attempt.expires_at <= pg_catalog.now() or v_attempt.used_at is not null then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'oauth_state_invalid');
  end if;
  update public.account_oauth_states set used_at = pg_catalog.now() where state_hash = p_state_hash;
  select request_id, player_id, api_key_id, purpose, status, old_discord_id, old_verified_at, expires_at
    into v_link from public.account_link_requests where request_id = p_request_id for update;
  if not found or v_link.expires_at <= pg_catalog.now() then
    update public.account_link_requests set status = 'expired' where request_id = p_request_id and status <> 'completed';
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'link_request_expired');
  end if;
  if p_step = 'old' then
    if v_link.purpose <> 'change' or v_link.status <> 'awaiting_old_discord' or p_discord_id <> v_link.old_discord_id then
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'old_discord_proof_mismatch');
    end if;
    update public.account_link_requests set status = 'awaiting_new_discord', old_verified_at = pg_catalog.now()
      where request_id = p_request_id;
    return pg_catalog.jsonb_build_object('ok', true, 'status', 'awaiting_new_discord');
  end if;
  if (v_link.purpose = 'link' and v_link.status <> 'awaiting_discord')
      or (v_link.purpose = 'change' and (v_link.status <> 'awaiting_new_discord'
        or v_link.old_verified_at is null or p_discord_id = v_link.old_discord_id)) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'new_discord_proof_invalid');
  end if;
  update public.account_link_requests set status = 'awaiting_confirmation',
    new_discord_id = p_discord_id, discord_display_name = p_display_name
    where request_id = p_request_id;
  return pg_catalog.jsonb_build_object('ok', true, 'status', 'awaiting_confirmation');
end;
$$;
