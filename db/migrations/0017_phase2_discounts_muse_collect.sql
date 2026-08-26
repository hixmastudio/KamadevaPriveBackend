-- ============================================================================
-- 0017 — Phase 2 completion (design §6): the discount framework live at bill
-- closure, the Muse two-stage pipeline, click-and-collect, and enquiries.
-- ============================================================================

-- ── Discount designations & limits: HoSL administration ─────────────────────

-- Publish (or replace) a designation for a tier at a venue/event. History is
-- preserved by closing the previous row (design §3.6).
create or replace function set_discount_designation(
  p_tier tier_enum,
  p_percent numeric,
  p_venue_id uuid default null,
  p_event_id uuid default null,
  p_allow_promo_stacking boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'the published designation list is maintained by the HoSL';
  end if;
  if (p_venue_id is null) = (p_event_id is null) then
    raise exception 'designate exactly one venue or one event';
  end if;

  update discount_designations
    set active_to = now()
    where tier = p_tier
      and active_to is null
      and venue_id is not distinct from p_venue_id
      and event_id is not distinct from p_event_id;

  insert into discount_designations
    (venue_id, event_id, tier, percent, created_by, allow_promo_stacking)
  values
    (p_venue_id, p_event_id, p_tier, p_percent, current_staff_id(), p_allow_promo_stacking)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function end_discount_designation(p_designation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'the published designation list is maintained by the HoSL';
  end if;
  update discount_designations set active_to = now()
  where id = p_designation_id and active_to is null;
end;
$$;

create or replace function set_delegated_limit(
  p_staff_id uuid,
  p_venue_id uuid,
  p_period_month date,
  p_limit_kobo bigint
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'delegated limits are set by the HoSL';
  end if;
  insert into delegated_limits (staff_id, venue_id, period_month, limit_kobo, set_by)
  values (p_staff_id, p_venue_id, date_trunc('month', p_period_month)::date, p_limit_kobo, current_staff_id())
  on conflict (staff_id, venue_id, period_month) do update
    set limit_kobo = excluded.limit_kobo, set_by = excluded.set_by;
end;
$$;

-- POS preview: what applies for this member at this venue/event right now.
create or replace function get_bill_preview(
  p_member_id uuid,
  p_venue_id uuid,
  p_event_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
  v_designation discount_designations%rowtype;
  v_pending discount_applications%rowtype;
begin
  if current_staff_id() is null then
    raise exception 'staff session required';
  end if;

  select * into v_member from members where id = p_member_id and status = 'active';
  if not found then
    return null;
  end if;

  if v_member.current_tier in ('gold', 'black') then
    select * into v_designation from discount_designations d
    where d.tier = v_member.current_tier
      and d.active_from <= now() and (d.active_to is null or d.active_to > now())
      and (d.venue_id = p_venue_id or (p_event_id is not null and d.event_id = p_event_id))
    order by (d.event_id is not null) desc
    limit 1;
  end if;

  select * into v_pending from discount_applications a
  where a.member_id = p_member_id and a.venue_id = p_venue_id
    and a.kind = 'discretionary' and a.transaction_id is null
  order by a.created_at desc
  limit 1;

  return jsonb_build_object(
    'tier', v_member.current_tier,
    'auto_percent', v_designation.percent,
    'designation_id', v_designation.id,
    'pending_discretionary', case when v_pending.id is null then null
      else jsonb_build_object('id', v_pending.id, 'amount_kobo', v_pending.amount_kobo,
                              'reason', v_pending.reason) end
  );
end;
$$;

-- ── close_bill v2: the automatic 5%/8% at closure (§6 wk9-10) ───────────────
-- Signature grows (event + discretionary attachment); drop the old overload.

drop function if exists close_bill(uuid, uuid, bigint, uuid, boolean, timestamptz);

create or replace function close_bill(
  p_venue_id uuid,
  p_member_id uuid,
  p_gross_amount_kobo bigint,
  p_client_capture_id uuid,
  p_promotion_applied boolean default false,
  p_occurred_at timestamptz default now(),
  p_event_id uuid default null,
  p_discount_application_id uuid default null
)
returns transactions
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_member members%rowtype;
  v_visit visits%rowtype;
  v_txn transactions%rowtype;
  v_designation discount_designations%rowtype;
  v_application discount_applications%rowtype;
  v_discount bigint := 0;
  v_application_id uuid;
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

  if p_member_id is not null then
    select * into v_member from members where id = p_member_id and status = 'active';
    if not found then
      raise exception 'member not found';
    end if;
    v_visit := capture_visit(p_member_id, p_venue_id, 'pos', gen_random_uuid(), p_occurred_at);
  end if;

  -- Discretionary attachment (Member/Silver): an approval minted moments ago
  -- by the venue manager, consumed exactly once.
  if p_discount_application_id is not null then
    select * into v_application from discount_applications
    where id = p_discount_application_id for update;
    if not found or v_application.kind != 'discretionary' then
      raise exception 'discretionary approval not found';
    end if;
    if v_application.transaction_id is not null then
      raise exception 'this discretionary approval was already used';
    end if;
    if v_application.member_id is distinct from p_member_id
       or v_application.venue_id is distinct from p_venue_id then
      raise exception 'discretionary approval does not match this bill';
    end if;
    v_discount := least(v_application.amount_kobo, p_gross_amount_kobo);
    v_application_id := v_application.id;

  -- Automatic tier discount (Gold/Black) in designated settings; never
  -- stacks with promotions unless the designation explicitly allows (§3.6).
  elsif p_member_id is not null and v_member.current_tier in ('gold', 'black') then
    select * into v_designation from discount_designations d
    where d.tier = v_member.current_tier
      and d.active_from <= p_occurred_at
      and (d.active_to is null or d.active_to > p_occurred_at)
      and (d.venue_id = p_venue_id or (p_event_id is not null and d.event_id = p_event_id))
    order by (d.event_id is not null) desc
    limit 1;

    if found and (not p_promotion_applied or v_designation.allow_promo_stacking) then
      v_discount := (p_gross_amount_kobo * v_designation.percent / 100)::bigint;
      insert into discount_applications
        (member_id, venue_id, kind, designation_id, member_tier_at_application,
         amount_kobo, percent)
      values
        (p_member_id, p_venue_id, 'automatic_tier', v_designation.id,
         v_member.current_tier, v_discount, v_designation.percent)
      returning id into v_application_id;
    end if;
  end if;

  insert into transactions
    (member_id, venue_id, visit_id, event_id, occurred_at, gross_amount_kobo,
     discount_amount_kobo, discount_application_id, promotion_applied, source,
     client_capture_id, entered_by_staff_id)
  values
    (p_member_id, p_venue_id, v_visit.id, p_event_id, p_occurred_at, p_gross_amount_kobo,
     v_discount, v_application_id, p_promotion_applied, 'pos_confirm',
     p_client_capture_id, v_staff)
  returning * into v_txn;

  if v_application_id is not null then
    update discount_applications set transaction_id = v_txn.id where id = v_application_id;
  end if;

  return v_txn;
end;
$$;

-- ── Muse pipeline (§6 wk11-12): initiate → founder decision → onboarding ───

create or replace function muse_initiate(p_member_id uuid, p_rationale text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_approval_id uuid;
  v_candidate_id uuid;
begin
  if v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'Muse candidates are initiated by venue managers, the HoSL, or founders';
  end if;
  if length(trim(coalesce(p_rationale, ''))) < 10 then
    raise exception 'a written rationale is required';
  end if;
  perform 1 from members where id = p_member_id and status = 'active';
  if not found then
    raise exception 'member not found';
  end if;
  if exists (select 1 from muse.memberships where member_id = p_member_id and status = 'active') then
    raise exception 'already a Muse member';
  end if;

  insert into approvals (subject_type, member_id, requested_by, rationale)
  values ('muse_membership', p_member_id, current_staff_id(), trim(p_rationale))
  returning id into v_approval_id;

  insert into muse.candidates (member_id, initiated_by, initiator_role_snapshot, rationale, approval_id)
  values (p_member_id, current_staff_id(), v_role, trim(p_rationale), v_approval_id)
  returning id into v_candidate_id;

  return v_candidate_id;
end;
$$;

-- Founder (or recorded delegate) decides; declines carry the written reason
-- into the audit trail via the approvals constraint.
create or replace function muse_decide(
  p_candidate_id uuid,
  p_decision approval_status,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_candidate muse.candidates%rowtype;
begin
  select * into v_candidate from muse.candidates where id = p_candidate_id for update;
  if not found or v_candidate.status not in ('submitted', 'under_review') then
    raise exception 'candidate not found or already decided';
  end if;

  -- decide_approval enforces founder/delegate authority and written declines.
  perform decide_approval(v_candidate.approval_id, p_decision, p_reason);

  update muse.candidates
    set status = case when p_decision = 'approved' then 'approved'::muse_candidate_status
                      else 'declined'::muse_candidate_status end
    where id = p_candidate_id;
end;
$$;

-- HoSL onboarding: membership + the aubergine Muse card (§10.1).
create or replace function muse_onboard(p_candidate_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_candidate muse.candidates%rowtype;
  v_membership_id uuid;
  v_card_id uuid;
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'Muse onboarding is done by the HoSL';
  end if;
  select * into v_candidate from muse.candidates where id = p_candidate_id for update;
  if not found or v_candidate.status != 'approved' then
    raise exception 'candidate is not approved';
  end if;
  if exists (select 1 from muse.memberships where member_id = v_candidate.member_id and status = 'active') then
    raise exception 'already onboarded';
  end if;

  insert into member_cards (member_id, kind) values (v_candidate.member_id, 'muse')
  on conflict do nothing;
  select id into v_card_id from member_cards
  where member_id = v_candidate.member_id and kind = 'muse' and status = 'active';

  insert into muse.memberships (member_id, candidate_id, approved_via, onboarded_by, onboarded_at, card_id)
  values (v_candidate.member_id, v_candidate.id, v_candidate.approval_id,
          current_staff_id(), now(), v_card_id)
  returning id into v_membership_id;

  return v_membership_id;
end;
$$;

-- Reads are RPC-only and audited (§4.3). HoSL/founder see the pipeline and
-- roster; a venue manager sees only their own submissions' status.
create or replace function muse_list_pipeline()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_result jsonb;
begin
  if v_role in ('hosl', 'founder') then
    perform log_audit('staff', auth.uid(), 'muse.pipeline.read', 'muse.candidates', null);
    select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_result
    from (
      select jsonb_build_object(
        'candidate_id', c.id,
        'member_id', c.member_id,
        'full_name', m.full_name,
        'member_no', m.member_no,
        'tier', m.current_tier,
        'status', c.status,
        'rationale', c.rationale,
        'initiated_by', sp.full_name,
        'decision_reason', a.decision_reason,
        'onboarded', exists (select 1 from muse.memberships mm where mm.candidate_id = c.id)
      ) as row_data, c.created_at
      from muse.candidates c
      join members m on m.id = c.member_id
      join staff_profiles sp on sp.id = c.initiated_by
      left join approvals a on a.id = c.approval_id
    ) t;
    return v_result;
  elsif v_role = 'venue_manager' then
    select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_result
    from (
      select jsonb_build_object(
        'candidate_id', c.id,
        'full_name', m.full_name,
        'status', c.status
      ) as row_data, c.created_at
      from muse.candidates c
      join members m on m.id = c.member_id
      where c.initiated_by = current_staff_id()
    ) t;
    return v_result;
  else
    raise exception 'not authorized';
  end if;
end;
$$;

create or replace function muse_read_audit(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() != 'founder' then
    raise exception 'the Muse access log is founder-only';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'who', coalesce(sp.full_name, ae.actor_id::text),
      'action', ae.action,
      'when', ae.occurred_at
    ) order by ae.occurred_at desc), '[]'::jsonb)
    from audit_events ae
    left join staff_profiles sp on sp.auth_user_id = ae.actor_id
    where ae.action like 'muse.%'
      and ae.occurred_at > now() - make_interval(days => p_days)
  );
end;
$$;

-- Benefit delivery on the floor, logged with discount-grade rigor (§3.7).
create or replace function grant_muse_benefit(
  p_member_id uuid,
  p_venue_id uuid,
  p_type muse_benefit_type,
  p_value_kobo bigint default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_membership muse.memberships%rowtype;
begin
  if current_staff_id() is null or not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  select * into v_membership from muse.memberships
  where member_id = p_member_id and status = 'active';
  if not found then
    raise exception 'not an active Muse member';
  end if;
  insert into muse.benefit_grants (membership_id, venue_id, type, value_kobo, granted_by)
  values (v_membership.id, p_venue_id, p_type, p_value_kobo, current_staff_id());
end;
$$;

-- ── Click-and-collect (§6 wk14-16): pay at venue on collection ─────────────

create or replace function set_catalog_item(
  p_venue_id uuid,
  p_name text,
  p_price_kobo bigint,
  p_description text default null,
  p_item_id uuid default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'the catalog is curated by the HoSL';
  end if;
  if p_item_id is null then
    insert into catalog_items (venue_id, name, description, price_kobo, is_active, created_by)
    values (p_venue_id, trim(p_name), p_description, p_price_kobo, p_is_active, current_staff_id())
    returning id into v_id;
  else
    update catalog_items
      set name = trim(p_name), description = p_description,
          price_kobo = p_price_kobo, is_active = p_is_active
      where id = p_item_id
      returning id into v_id;
    if not found then
      raise exception 'item not found';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function place_collect_order(
  p_venue_id uuid,
  p_items jsonb, -- [{"catalog_item_id": uuid, "quantity": int}]
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member_id uuid := current_member_id();
  v_order_id uuid;
  v_line jsonb;
  v_item catalog_items%rowtype;
  v_count int := 0;
begin
  if v_member_id is null then
    raise exception 'member sign-in required';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'the order is empty';
  end if;

  insert into collect_orders (member_id, venue_id, notes)
  values (v_member_id, p_venue_id, p_notes)
  returning id into v_order_id;

  for v_line in select * from jsonb_array_elements(p_items) loop
    select * into v_item from catalog_items
    where id = (v_line->>'catalog_item_id')::uuid
      and venue_id = p_venue_id and is_active;
    if not found then
      raise exception 'an item in the order is no longer available';
    end if;
    if coalesce((v_line->>'quantity')::int, 0) < 1 then
      continue;
    end if;
    insert into collect_order_items (order_id, catalog_item_id, quantity, unit_price_kobo)
    values (v_order_id, v_item.id, (v_line->>'quantity')::int, v_item.price_kobo);
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'the order is empty';
  end if;
  return v_order_id;
end;
$$;

create or replace function advance_collect_order(p_order_id uuid, p_status collect_order_status)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order collect_orders%rowtype;
begin
  select * into v_order from collect_orders where id = p_order_id for update;
  if not found then
    raise exception 'order not found';
  end if;

  -- Members may cancel their own un-fulfilled orders; staff work the queue.
  if v_order.member_id = current_member_id() then
    if p_status != 'cancelled' or v_order.status not in ('placed', 'accepted') then
      raise exception 'this order can no longer be cancelled';
    end if;
  elsif current_staff_id() is not null and staff_has_venue(v_order.venue_id) then
    if p_status = 'cancelled' and v_order.status = 'collected' then
      raise exception 'collected orders cannot be cancelled';
    end if;
  else
    raise exception 'not authorized';
  end if;

  update collect_orders set status = p_status where id = p_order_id;
end;
$$;

-- ── Enquiries (§6 wk14-16): a simple queue to the HoSL, not a ticket system ─

create table enquiries (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  message text not null check (length(trim(message)) > 0),
  status text not null default 'open' check (status in ('open', 'answered')),
  answer text,
  answered_by uuid references staff_profiles (id) on delete restrict,
  answered_at timestamptz,
  created_at timestamptz not null default now()
);

alter table enquiries enable row level security;

create policy enquiries_self_read on enquiries for select to authenticated
  using (member_id = current_member_id());
create policy enquiries_hosl_read on enquiries for select to authenticated
  using (is_hosl_up());

revoke insert, update, delete on enquiries from anon, authenticated;

create or replace function submit_enquiry(p_message text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if current_member_id() is null then
    raise exception 'member sign-in required';
  end if;
  insert into enquiries (member_id, message)
  values (current_member_id(), trim(p_message))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function answer_enquiry(p_enquiry_id uuid, p_answer text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() not in ('hosl', 'founder') then
    raise exception 'enquiries are answered by the HoSL';
  end if;
  update enquiries
    set status = 'answered', answer = trim(p_answer),
        answered_by = current_staff_id(), answered_at = now()
    where id = p_enquiry_id;
  if not found then
    raise exception 'enquiry not found';
  end if;
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────

revoke execute on function
  set_discount_designation, end_discount_designation, set_delegated_limit,
  get_bill_preview, close_bill, muse_initiate, muse_decide, muse_onboard,
  muse_list_pipeline, muse_read_audit, grant_muse_benefit, set_catalog_item,
  place_collect_order, advance_collect_order, submit_enquiry, answer_enquiry
from public, anon;

grant execute on function
  set_discount_designation, end_discount_designation, set_delegated_limit,
  get_bill_preview, close_bill, muse_initiate, muse_decide, muse_onboard,
  muse_list_pipeline, muse_read_audit, grant_muse_benefit, set_catalog_item,
  place_collect_order, advance_collect_order, submit_enquiry, answer_enquiry
to authenticated;
