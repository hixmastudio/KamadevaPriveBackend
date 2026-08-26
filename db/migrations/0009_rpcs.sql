-- ============================================================================
-- 0009 — RPC write API. Design doc §4.1: sensitive writes never hit tables
-- directly; these SECURITY DEFINER functions validate role, venue scope, and
-- invariants, and write audit rows atomically. RLS shapes reads; this is the
-- write API. Every client — staff PWA, portal, WhatsApp handler, POS bridge —
-- inherits the same guarantees.
-- ============================================================================

-- ── Guest registration: the <1-minute on-ramp ───────────────────────────────

create or replace function register_guest(
  p_phone text,
  p_full_name text,
  p_venue_id uuid,
  p_instagram text default null,
  p_consent_marketing boolean default false,
  p_channel consent_channel default 'door_tablet'
)
returns members
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_phone text := normalize_phone(p_phone);
  v_member members%rowtype;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  -- Duplicate phones resolve to ONE profile, never a second row.
  select * into v_member from members where phone = v_phone;
  if found then
    return v_member;
  end if;

  insert into members (phone, full_name, instagram_handle, home_venue_id)
  values (v_phone, trim(p_full_name), nullif(trim(coalesce(p_instagram, '')), ''), p_venue_id)
  returning * into v_member;

  -- Consent captured in the same transaction as member creation (§3.1).
  insert into consents (member_id, consent_type, granted, channel, captured_by_staff_id)
  values
    (v_member.id, 'data_processing', true, p_channel, v_staff),
    (v_member.id, 'marketing_whatsapp', p_consent_marketing, p_channel, v_staff);

  return v_member;
end;
$$;

-- ── Visit capture: idempotent, one visit per member/venue/night ─────────────

create or replace function capture_visit(
  p_member_id uuid,
  p_venue_id uuid,
  p_channel capture_channel,
  p_client_capture_id uuid,
  p_occurred_at timestamptz default now(),
  p_reservation_id uuid default null
)
returns visits
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_visit visits%rowtype;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  -- Outbox replay: same client_capture_id → same visit, no double count.
  select * into v_visit from visits where client_capture_id = p_client_capture_id;
  if found then
    return v_visit;
  end if;

  -- Same night, second capture point → attach to the existing visit.
  select * into v_visit
  from visits
  where member_id = p_member_id
    and venue_id = p_venue_id
    and business_date = kp_business_date(p_occurred_at)
    and voided_at is null;
  if found then
    return v_visit;
  end if;

  insert into visits
    (member_id, venue_id, occurred_at, capture_channel, captured_by_staff_id,
     client_capture_id, reservation_id)
  values
    (p_member_id, p_venue_id, p_occurred_at, p_channel, v_staff,
     p_client_capture_id, p_reservation_id)
  returning * into v_visit;

  return v_visit;
end;
$$;

-- ── POS-confirm: bill closure, member optional (§3.3) ───────────────────────

create or replace function close_bill(
  p_venue_id uuid,
  p_member_id uuid,
  p_gross_amount_kobo bigint,
  p_client_capture_id uuid,
  p_promotion_applied boolean default false,
  p_occurred_at timestamptz default now()
)
returns transactions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_visit visits%rowtype;
  v_txn transactions%rowtype;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if p_gross_amount_kobo is null or p_gross_amount_kobo < 0 then
    raise exception 'invalid amount';
  end if;

  select * into v_txn from transactions where client_capture_id = p_client_capture_id;
  if found then
    return v_txn;
  end if;

  -- Attributed bill: spend attaches in real time and dedup-attaches the visit.
  if p_member_id is not null then
    v_visit := capture_visit(p_member_id, p_venue_id, 'pos', gen_random_uuid(), p_occurred_at);
  end if;

  insert into transactions
    (member_id, venue_id, visit_id, occurred_at, gross_amount_kobo,
     promotion_applied, source, client_capture_id, entered_by_staff_id)
  values
    (p_member_id, p_venue_id, v_visit.id, p_occurred_at, p_gross_amount_kobo,
     p_promotion_applied, 'pos_confirm', p_client_capture_id, v_staff)
  returning * into v_txn;

  return v_txn;
end;
$$;

-- ── Reservations: the rule, as one RPC (§4.6) ───────────────────────────────

create or replace function create_reservation(
  p_venue_id uuid,
  p_reserved_for timestamptz,
  p_party_size integer,
  p_channel reservation_channel,
  p_member_id uuid default null,
  p_guest_phone text default null,
  p_guest_name text default null,
  p_event_id uuid default null,
  p_notes text default null
)
returns reservations
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_member members%rowtype;
  v_reservation reservations%rowtype;
begin
  -- Resolve the member: existing id, portal self, or inline <1-min registration.
  if p_member_id is not null then
    select * into v_member from members where id = p_member_id and status = 'active';
    if not found then
      raise exception 'member not found';
    end if;
  elsif current_member_id() is not null then
    select * into v_member from members where id = current_member_id();
  elsif p_guest_phone is not null and p_guest_name is not null then
    if v_staff is null then
      raise exception 'staff session required for inline guest registration';
    end if;
    v_member := register_guest(p_guest_phone, p_guest_name, p_venue_id, null, false, 'staff_entry');
  else
    -- No schema path to a memberless reservation exists; this RPC mirrors it.
    raise exception 'reservations require a registered member (the reservation rule)';
  end if;

  if v_staff is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  -- Tier-gated event access windows hold for everyone (§3.8).
  if p_event_id is not null
     and not event_booking_open_for(p_event_id, v_member.current_tier) then
    raise exception 'booking for this event has not opened for this member''s tier yet';
  end if;

  insert into reservations
    (member_id, venue_id, event_id, reserved_for, party_size, status, channel,
     created_by_staff_id, notes)
  values
    (v_member.id, p_venue_id, p_event_id, p_reserved_for, p_party_size,
     case when p_channel = 'staff' then 'confirmed'::reservation_status
          else 'requested'::reservation_status end,
     p_channel, v_staff, p_notes)
  returning * into v_reservation;

  return v_reservation;
end;
$$;

-- Check-in: seats the reservation and creates the visit in one step.
create or replace function reservation_checkin(
  p_reservation_id uuid,
  p_client_capture_id uuid
)
returns reservations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_res reservations%rowtype;
  v_visit visits%rowtype;
begin
  select * into v_res from reservations where id = p_reservation_id for update;
  if not found then
    raise exception 'reservation not found';
  end if;
  if not staff_has_venue(v_res.venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if v_res.status = 'seated' then
    return v_res;
  end if;
  if v_res.status in ('cancelled', 'no_show') then
    raise exception 'reservation is %', v_res.status;
  end if;

  v_visit := capture_visit(v_res.member_id, v_res.venue_id, 'reservation_checkin',
                           p_client_capture_id, now(), v_res.id);

  update reservations
    set status = 'seated', seated_visit_id = v_visit.id
    where id = p_reservation_id
    returning * into v_res;

  return v_res;
end;
$$;

create or replace function mark_reservation(
  p_reservation_id uuid,
  p_status reservation_status
)
returns reservations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_res reservations%rowtype;
begin
  if p_status not in ('confirmed', 'no_show', 'cancelled') then
    raise exception 'use reservation_checkin() to seat a reservation';
  end if;
  select * into v_res from reservations where id = p_reservation_id for update;
  if not found then
    raise exception 'reservation not found';
  end if;
  if current_staff_id() is null or not staff_has_venue(v_res.venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  update reservations set status = p_status where id = p_reservation_id
    returning * into v_res;
  return v_res;
end;
$$;

-- ── Recognition: the ONLY member lookup surface hosts have (§4.2) ───────────

create or replace function get_recognition_profile(
  p_qr_token text default null,
  p_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_member members%rowtype;
  v_visits_month int;
  v_reservation reservations%rowtype;
  v_muse_active boolean := false;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;

  if p_qr_token is not null then
    select m.* into v_member
    from member_cards c join members m on m.id = c.member_id
    where c.qr_token = p_qr_token and c.status = 'active' and m.status = 'active';
  elsif p_phone is not null then
    select * into v_member from members
    where phone = normalize_phone(p_phone) and status = 'active';
  end if;

  if v_member.id is null then
    return null;
  end if;

  select count(*)::int into v_visits_month
  from visits
  where member_id = v_member.id and voided_at is null
    and occurred_at > date_trunc('month', now());

  select * into v_reservation
  from reservations
  where member_id = v_member.id
    and status in ('requested', 'confirmed')
    and kp_business_date(reserved_for) = kp_business_date(now())
  order by reserved_for
  limit 1;

  -- Muse: hosts learn only "priority entry / tonight's benefit", never status
  -- details. Read is audited (§4.3).
  select exists (
    select 1 from muse.memberships where member_id = v_member.id and status = 'active'
  ) into v_muse_active;

  if v_muse_active then
    perform log_audit('staff', auth.uid(), 'muse.recognition.read',
                      'members', v_member.id::text);
  end if;

  return jsonb_build_object(
    'member_id', v_member.id,
    'member_no', v_member.member_no,
    'full_name', v_member.full_name,
    'tier', v_member.current_tier,
    'visits_this_month', v_visits_month,
    'reservation_tonight', case when v_reservation.id is null then null
      else jsonb_build_object('id', v_reservation.id, 'party_size', v_reservation.party_size,
                              'reserved_for', v_reservation.reserved_for) end,
    'priority_entry', v_muse_active or v_member.current_tier in ('silver', 'gold', 'black'),
    'muse_benefit_tonight', case when v_muse_active then 'Muse member — priority entry' else null end
  );
end;
$$;

-- ── Committee workflow (§3.5) ───────────────────────────────────────────────

create or replace function open_tier_case(
  p_member_id uuid,
  p_target_tier tier_enum,
  p_venue_id uuid,
  p_rationale text
)
returns approvals
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_approval approvals%rowtype;
begin
  if v_staff is null or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'only venue managers, HoSL, or founders open tier cases';
  end if;
  if p_target_tier not in ('gold', 'black') then
    raise exception 'tier cases exist only for gold and black';
  end if;

  insert into approvals (subject_type, member_id, venue_id, target_tier, requested_by, rationale)
  values (
    case when p_target_tier = 'gold' then 'tier_gold'::approval_subject else 'tier_black'::approval_subject end,
    p_member_id, p_venue_id, p_target_tier, v_staff, p_rationale
  )
  returning * into v_approval;

  update eligibility_flags set status = 'case_opened'
  where member_id = p_member_id and target_tier = p_target_tier and status = 'open';

  return v_approval;
end;
$$;

create or replace function add_tier_signoff(p_approval_id uuid)
returns tier_approval_signoffs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_role staff_role := current_staff_role();
  v_approval approvals%rowtype;
  v_signoff_role signoff_role;
  v_signoff tier_approval_signoffs%rowtype;
begin
  select * into v_approval from approvals where id = p_approval_id;
  if not found or v_approval.status != 'pending' then
    raise exception 'approval not found or not pending';
  end if;
  if v_approval.subject_type not in ('tier_gold', 'tier_black') then
    raise exception 'sign-offs apply to tier approvals only';
  end if;

  if v_role = 'hosl' then
    v_signoff_role := 'hosl';
  elsif v_role = 'venue_manager' then
    if not staff_has_venue(v_approval.venue_id) then
      raise exception 'the venue_manager sign-off must come from a manager of the approval venue';
    end if;
    v_signoff_role := 'venue_manager';
  elsif v_role = 'founder' or staff_holds_delegation(v_staff, 'tier_founder_rep') then
    v_signoff_role := 'founder_rep';
  else
    raise exception 'not a committee member';
  end if;

  insert into tier_approval_signoffs (approval_id, signer_staff_id, role_at_signing)
  values (p_approval_id, v_staff, v_signoff_role)
  returning * into v_signoff;

  return v_signoff;
end;
$$;

-- Decide + (for Gold) immediately mint the promotion; Black issues an
-- invitation whose acceptance mints it (§3.5).
create or replace function decide_approval(
  p_approval_id uuid,
  p_decision approval_status,
  p_reason text default null
)
returns approvals
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_role staff_role := current_staff_role();
  v_approval approvals%rowtype;
  v_stats record;
  v_snapshot jsonb;
begin
  if p_decision not in ('approved', 'declined') then
    raise exception 'decision must be approved or declined';
  end if;

  select * into v_approval from approvals where id = p_approval_id for update;
  if not found or v_approval.status != 'pending' then
    raise exception 'approval not found or already decided';
  end if;

  -- Who may decide what (§4 matrix).
  if v_approval.subject_type in ('tier_gold', 'tier_black') then
    if v_role not in ('hosl', 'founder') then
      raise exception 'tier approvals are decided by HoSL or a founder after committee sign-offs';
    end if;
  elsif v_approval.subject_type = 'muse_membership' then
    if not (v_role = 'founder' or staff_holds_delegation(v_staff, 'muse_approval')) then
      raise exception 'Muse approvals are decided only by an owner or their recorded delegate';
    end if;
  elsif v_approval.subject_type = 'ndpr_erasure' then
    if v_role != 'founder' then
      raise exception 'NDPR erasure is founder-approved';
    end if;
  else
    if v_role not in ('hosl', 'founder') then
      raise exception 'not authorized to decide this approval';
    end if;
  end if;

  if p_decision = 'declined' and (p_reason is null or length(trim(p_reason)) = 0) then
    raise exception 'declines require a written reason';
  end if;

  update approvals
    set status = p_decision,
        decided_by = v_staff,
        decided_at = now(),
        decision_reason = nullif(trim(coalesce(p_reason, '')), '')
    where id = p_approval_id
    returning * into v_approval;

  -- Gold: promotion is immediate on approval. Black: issue the invitation.
  if p_decision = 'approved' and v_approval.subject_type = 'tier_gold' then
    select * into v_stats from compute_member_stats(v_approval.member_id);
    v_snapshot := jsonb_build_object(
      'visits_90d', v_stats.visits_90d,
      'visits_12m', v_stats.visits_12m,
      'spend_12m_kobo', v_stats.spend_12m_kobo);

    insert into tier_events (member_id, from_tier, to_tier, reason, approval_id,
                             stats_snapshot, effected_by, staff_id)
    select v_approval.member_id, m.current_tier, 'gold', 'approved_promotion',
           v_approval.id, v_snapshot, 'staff', v_staff
    from members m where m.id = v_approval.member_id;

    update members set current_tier = 'gold', tier_computed_at = now()
    where id = v_approval.member_id;

  elsif p_decision = 'approved' and v_approval.subject_type = 'tier_black' then
    insert into invitations (member_id, kind, approval_id, issued_by)
    values (v_approval.member_id, 'black', v_approval.id, v_staff);
  end if;

  return v_approval;
end;
$$;

create or replace function accept_invitation(p_invitation_id uuid)
returns invitations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_inv invitations%rowtype;
  v_stats record;
  v_snapshot jsonb;
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'invitation acceptance is recorded by HoSL or a founder';
  end if;

  select * into v_inv from invitations where id = p_invitation_id for update;
  if not found or v_inv.status != 'issued' then
    raise exception 'invitation not found or not open';
  end if;

  update invitations set status = 'accepted', accepted_at = now()
  where id = p_invitation_id returning * into v_inv;

  if v_inv.kind = 'black' then
    select * into v_stats from compute_member_stats(v_inv.member_id);
    v_snapshot := jsonb_build_object(
      'visits_90d', v_stats.visits_90d,
      'visits_12m', v_stats.visits_12m,
      'spend_12m_kobo', v_stats.spend_12m_kobo);

    insert into tier_events (member_id, from_tier, to_tier, reason, approval_id,
                             stats_snapshot, effected_by, staff_id)
    select v_inv.member_id, m.current_tier, 'black', 'invitation_accepted',
           v_inv.approval_id, v_snapshot, 'staff', v_staff
    from members m where m.id = v_inv.member_id;

    update members set current_tier = 'black', tier_computed_at = now()
    where id = v_inv.member_id;
  end if;

  return v_inv;
end;
$$;

-- ── Voids (corrections, never deletes) ──────────────────────────────────────

create or replace function void_visit(p_visit_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_visit visits%rowtype;
begin
  select * into v_visit from visits where id = p_visit_id for update;
  if not found or v_visit.voided_at is not null then
    raise exception 'visit not found or already voided';
  end if;
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder')
     or not staff_has_venue(v_visit.venue_id) then
    raise exception 'voids require a venue manager (own venue) or HoSL';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required';
  end if;
  update visits
    set voided_at = now(), voided_by = current_staff_id(), void_reason = trim(p_reason)
    where id = p_visit_id;
end;
$$;

create or replace function void_transaction(p_transaction_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_txn transactions%rowtype;
begin
  select * into v_txn from transactions where id = p_transaction_id for update;
  if not found or v_txn.voided_at is not null then
    raise exception 'transaction not found or already voided';
  end if;
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder')
     or not staff_has_venue(v_txn.venue_id) then
    raise exception 'voids require a venue manager (own venue) or HoSL';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required';
  end if;
  update transactions
    set voided_at = now(), voided_by = current_staff_id(), void_reason = trim(p_reason)
    where id = p_transaction_id;
end;
$$;

-- ── Nightly headcount (KPI denominator) ─────────────────────────────────────

create or replace function record_shift_entries(
  p_venue_id uuid,
  p_business_date date,
  p_total integer
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder')
     or not staff_has_venue(p_venue_id) then
    raise exception 'headcounts are entered by the venue manager';
  end if;
  insert into shift_entry_counts (venue_id, business_date, total_entries, entered_by_staff_id)
  values (p_venue_id, p_business_date, p_total, current_staff_id())
  on conflict (venue_id, business_date) do update
    set total_entries = excluded.total_entries,
        entered_by_staff_id = excluded.entered_by_staff_id;
end;
$$;

-- ── Member profile updates + merge (first-class, §3.1) ──────────────────────

create or replace function update_member_profile(
  p_member_id uuid,
  p_full_name text default null,
  p_instagram text default null,
  p_email text default null
)
returns members
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
begin
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'profile edits require venue manager or above';
  end if;
  update members
    set full_name = coalesce(nullif(trim(coalesce(p_full_name, '')), ''), full_name),
        instagram_handle = coalesce(nullif(trim(coalesce(p_instagram, '')), ''), instagram_handle),
        email = coalesce(nullif(trim(coalesce(p_email, '')), ''), email)
    where id = p_member_id and status = 'active'
    returning * into v_member;
  if not found then
    raise exception 'member not found';
  end if;
  return v_member;
end;
$$;

create or replace function merge_members(p_duplicate_id uuid, p_keep_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'member merges are performed by HoSL or a founder';
  end if;
  if p_duplicate_id = p_keep_id then
    raise exception 'cannot merge a member into itself';
  end if;

  perform 1 from members where id = p_keep_id and status = 'active';
  if not found then raise exception 'target member not found'; end if;
  perform 1 from members where id = p_duplicate_id and status = 'active' for update;
  if not found then raise exception 'duplicate member not found'; end if;

  -- Repoint activity. Same-night visit collisions void the duplicate's copy.
  for r in select id from visits where member_id = p_duplicate_id and voided_at is null loop
    begin
      update visits set member_id = p_keep_id where id = r.id;
    exception when unique_violation then
      update visits
        set voided_at = now(), voided_by = current_staff_id(),
            void_reason = 'merged duplicate: same-night visit already on surviving profile'
        where id = r.id;
    end;
  end loop;

  update transactions set member_id = p_keep_id where member_id = p_duplicate_id;
  update reservations set member_id = p_keep_id where member_id = p_duplicate_id;
  update consents set member_id = p_keep_id where member_id = p_duplicate_id;
  update member_cards set status = 'revoked', revoked_at = now()
    where member_id = p_duplicate_id and status = 'active';

  update members
    set status = 'merged',
        merged_into_member_id = p_keep_id,
        -- Free the phone slot: history is preserved in audit.
        phone = phone || ':merged:' || substr(id::text, 1, 8)
    where id = p_duplicate_id;

  perform recompute_member_tier(p_keep_id);
  perform log_audit('staff', auth.uid(), 'member.merge', 'members', p_keep_id::text,
                    null, jsonb_build_object('duplicate_id', p_duplicate_id), null);
end;
$$;

-- ── Staff PIN switching (§4) ────────────────────────────────────────────────

create or replace function set_staff_pin(p_staff_id uuid, p_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN must be 4-6 digits';
  end if;
  -- Self, or HoSL/founder provisioning.
  if not (p_staff_id = current_staff_id() or current_staff_role() in ('hosl', 'founder')) then
    raise exception 'not authorized to set this PIN';
  end if;
  update staff_profiles
    set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf'))
    where id = p_staff_id and is_active;
  if not found then
    raise exception 'staff member not found';
  end if;
  perform log_audit('staff', auth.uid(), 'staff.pin.set', 'staff_profiles', p_staff_id::text);
end;
$$;

-- Device session (VM login) verifies which host is capturing. Server-side
-- check; returns the staff row on success so the app can attribute captures.
create or replace function verify_staff_pin(p_staff_id uuid, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_hash text;
begin
  if current_staff_id() is null then
    raise exception 'staff device session required';
  end if;
  select pin_hash into v_hash from staff_profiles
  where id = p_staff_id and is_active;
  if v_hash is null then
    return false;
  end if;
  return v_hash = extensions.crypt(p_pin, v_hash);
end;
$$;

-- ── Search (VM+; hosts use recognition lookup only) ─────────────────────────

create or replace function search_members(p_query text, p_limit int default 20)
returns setof members
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_phone text;
begin
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'member search requires venue manager or above';
  end if;

  if p_query ~ '^[+0-9][0-9 -]*$' then
    begin
      v_phone := normalize_phone(p_query);
    exception when others then
      v_phone := null;
    end;
  end if;

  return query
  select * from members m
  where m.status = 'active'
    and (
      (v_phone is not null and m.phone = v_phone)
      or m.member_no ilike p_query || '%'
      or m.full_name ilike '%' || p_query || '%'
    )
  order by m.full_name
  limit least(p_limit, 50);
end;
$$;

-- ── Execute grants: staff/portal sessions only, never anonymous ─────────────

revoke execute on function
  register_guest, capture_visit, close_bill, create_reservation,
  reservation_checkin, mark_reservation, get_recognition_profile,
  open_tier_case, add_tier_signoff, decide_approval, accept_invitation,
  void_visit, void_transaction, record_shift_entries, update_member_profile,
  merge_members, set_staff_pin, verify_staff_pin, search_members,
  apply_discretionary_discount, sweep_tier_decay, ensure_audit_partition,
  recompute_member_tier
from public, anon;

grant execute on function
  register_guest, capture_visit, close_bill, create_reservation,
  reservation_checkin, mark_reservation, get_recognition_profile,
  open_tier_case, add_tier_signoff, decide_approval, accept_invitation,
  void_visit, void_transaction, record_shift_entries, update_member_profile,
  merge_members, set_staff_pin, verify_staff_pin, search_members,
  apply_discretionary_discount
to authenticated;
