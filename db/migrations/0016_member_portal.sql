-- ============================================================================
-- 0016 — Member portal (design §6 wk14-16, adapted): account claiming,
-- self-status, consent management, self-service reservations, and member
-- visibility of published events. Sign-in is email-OTP for now (every member
-- has an email on file); WhatsApp/SMS OTP replaces it in Phase 3.
-- ============================================================================

-- Link the signed-in auth user to their member row by verified email — the
-- account-claim moment (design §4): first login shows their existing visits
-- and tier.
create or replace function claim_member_account()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_email text;
  v_member members%rowtype;
begin
  if auth.uid() is null then
    raise exception 'sign in first';
  end if;

  -- Already claimed?
  select * into v_member from members where auth_user_id = auth.uid();
  if found then
    return jsonb_build_object('claimed', true, 'member_no', v_member.member_no);
  end if;

  select lower(email) into v_email from auth.users where id = auth.uid();

  update members
    set auth_user_id = auth.uid()
    where id = (
      select id from members
      where lower(email) = v_email
        and auth_user_id is null
        and status = 'active'
      order by created_at
      limit 1
    )
    returning * into v_member;

  if not found then
    return jsonb_build_object('claimed', false);
  end if;

  perform log_audit('member', auth.uid(), 'member.account.claim',
                    'members', v_member.id::text);

  return jsonb_build_object('claimed', true, 'member_no', v_member.member_no);
end;
$$;

-- Everything the member's home screen needs, in one call: profile, live
-- rolling stats, tier thresholds for progress display, and their card token.
create or replace function get_my_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
  v_stats record;
  v_card member_cards%rowtype;
begin
  select * into v_member from members
  where auth_user_id = auth.uid() and status = 'active';
  if not found then
    return null;
  end if;

  select * into v_stats from compute_member_stats(v_member.id);

  select * into v_card from member_cards
  where member_id = v_member.id and kind = 'prive' and status = 'active';

  return jsonb_build_object(
    'member_id', v_member.id,
    'full_name', v_member.full_name,
    'member_no', v_member.member_no,
    'tier', v_member.current_tier,
    'phone', v_member.phone,
    'email', v_member.email,
    'card_token', v_card.qr_token,
    'stats', jsonb_build_object(
      'visits_90d', v_stats.visits_90d,
      'visits_12m', v_stats.visits_12m,
      'spend_12m_kobo', v_stats.spend_12m_kobo
    ),
    'thresholds', jsonb_build_object(
      'member_visits_90d', config_int('tier_member_visits_90d'),
      'silver_spend_kobo', config_int('tier_silver_spend_kobo'),
      'silver_visits_12m', config_int('tier_silver_visits_12m'),
      'gold_spend_kobo', config_int('tier_gold_spend_kobo'),
      'black_spend_kobo', config_int('tier_black_spend_kobo')
    ),
    'consents', (
      select coalesce(jsonb_object_agg(consent_type, granted), '{}'::jsonb)
      from current_consents where member_id = v_member.id
    )
  );
end;
$$;

-- Consent self-service: appends to the immutable history (NDPR provenance).
create or replace function set_my_consent(p_type consent_type, p_granted boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member_id uuid := current_member_id();
begin
  if v_member_id is null then
    raise exception 'no membership linked to this account';
  end if;
  if p_type = 'data_processing' and not p_granted then
    raise exception 'to withdraw data processing consent, please speak to the Head of Sales & Loyalty — this closes your membership';
  end if;
  insert into consents (member_id, consent_type, granted, channel)
  values (v_member_id, p_type, p_granted, 'portal');
end;
$$;

-- Members may cancel their own open reservations.
create or replace function cancel_my_reservation(p_reservation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_res reservations%rowtype;
begin
  select * into v_res from reservations where id = p_reservation_id for update;
  if not found or v_res.member_id is distinct from current_member_id() then
    raise exception 'reservation not found';
  end if;
  if v_res.status not in ('requested', 'confirmed') then
    raise exception 'this reservation can no longer be cancelled';
  end if;
  update reservations set status = 'cancelled' where id = p_reservation_id;
end;
$$;

-- Members see published events (staff policy already covers the rest).
create policy events_member_read on events for select to authenticated
  using (status = 'published');

revoke execute on function
  claim_member_account, get_my_status, set_my_consent, cancel_my_reservation
from public, anon;
grant execute on function
  claim_member_account, get_my_status, set_my_consent, cancel_my_reservation
to authenticated;
