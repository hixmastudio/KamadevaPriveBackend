-- ============================================================================
-- 0006 — Discount framework (§3.6) and the isolated Muse schema (§3.7).
-- Schema ships in Phase 1 even though the UIs are Phase 2: cheap now,
-- expensive to retrofit under RLS.
-- ============================================================================

-- ── Discount designations: HoSL's published list ────────────────────────────

create table discount_designations (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid references venues (id) on delete restrict,
  event_id uuid, -- FK added in 0007
  tier tier_enum not null check (tier in ('gold', 'black')),
  percent numeric(4,2) not null check (percent > 0 and percent <= 50),
  active_from timestamptz not null default now(),
  active_to timestamptz,
  created_by uuid not null references staff_profiles (id) on delete restrict,
  allow_promo_stacking boolean not null default false,
  stacking_exception_approval_id uuid references approvals (id) on delete restrict,
  created_at timestamptz not null default now(),
  -- venue XOR event
  check ((venue_id is null) != (event_id is null))
);

create trigger discount_designations_audit
  after insert or update or delete on discount_designations
  for each row execute function audit_row_change();

-- ── Per-approver monthly envelopes (§3.6) ───────────────────────────────────

create table delegated_limits (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff_profiles (id) on delete restrict,
  venue_id uuid not null references venues (id) on delete restrict,
  period_month date not null check (extract(day from period_month) = 1),
  limit_kobo bigint not null check (limit_kobo >= 0),
  set_by uuid not null references staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (staff_id, venue_id, period_month)
);

create trigger delegated_limits_audit
  after insert or update or delete on delegated_limits
  for each row execute function audit_row_change();

-- ── Every discount ever granted — this IS the discount audit ────────────────

create table discount_applications (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid references transactions (id) on delete restrict,
  member_id uuid not null references members (id) on delete restrict,
  venue_id uuid not null references venues (id) on delete restrict,
  kind discount_kind not null,
  -- automatic path
  designation_id uuid references discount_designations (id) on delete restrict,
  member_tier_at_application tier_enum,
  -- discretionary path
  approved_by_staff_id uuid references staff_profiles (id) on delete restrict,
  delegated_limit_id uuid references delegated_limits (id) on delete restrict,
  reason text,
  amount_kobo bigint not null check (amount_kobo > 0),
  percent numeric(4,2),
  created_at timestamptz not null default now(),
  check (kind != 'automatic_tier' or (designation_id is not null and member_tier_at_application is not null)),
  check (kind != 'discretionary' or (approved_by_staff_id is not null and delegated_limit_id is not null and reason is not null))
);

create index discount_applications_approver_idx
  on discount_applications (approved_by_staff_id, created_at desc)
  where kind = 'discretionary';

create trigger discount_applications_audit
  after insert or update or delete on discount_applications
  for each row execute function audit_row_change();

alter table transactions
  add constraint transactions_discount_application_fk
  foreign key (discount_application_id) references discount_applications (id) on delete restrict;

-- Race-proof discretionary envelope enforcement (§3.6): the ONLY insert path
-- for discretionary discounts. Advisory xact lock on (staff, month) so two
-- simultaneous approvals by the same manager cannot both squeeze under the cap.
create or replace function apply_discretionary_discount(
  p_member_id uuid,
  p_venue_id uuid,
  p_amount_kobo bigint,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_approver uuid := current_staff_id();
  v_role staff_role := current_staff_role();
  v_member members%rowtype;
  v_limit delegated_limits%rowtype;
  v_month date := date_trunc('month', now())::date;
  v_spent bigint;
  v_id uuid;
begin
  if v_approver is null or v_role not in ('venue_manager', 'hosl') then
    raise exception 'discretionary discounts are approved only by venue managers or the HoSL';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if p_amount_kobo is null or p_amount_kobo <= 0 then
    raise exception 'discount amount must be positive';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required for every discretionary discount';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found or v_member.status != 'active' then
    raise exception 'member not found';
  end if;
  -- Spec §6: discretionary applies to Member and Silver tiers.
  if v_member.current_tier not in ('member', 'silver') then
    raise exception 'discretionary discounts apply to Member and Silver tiers only (member is %)', v_member.current_tier;
  end if;

  -- Serialize this approver's month.
  perform pg_advisory_xact_lock(hashtext(v_approver::text || to_char(v_month, 'YYYY-MM')));

  select * into v_limit
  from delegated_limits
  where staff_id = v_approver and venue_id = p_venue_id and period_month = v_month;

  if not found then
    raise exception 'no delegated limit set for you at this venue this month — escalate to HoSL';
  end if;

  select coalesce(sum(amount_kobo), 0) into v_spent
  from discount_applications
  where approved_by_staff_id = v_approver
    and delegated_limit_id = v_limit.id
    and kind = 'discretionary';

  if v_spent + p_amount_kobo > v_limit.limit_kobo then
    raise exception 'monthly discretionary envelope exceeded (spent % + % > limit %) — escalate to HoSL',
      v_spent, p_amount_kobo, v_limit.limit_kobo;
  end if;

  insert into discount_applications
    (member_id, venue_id, kind, approved_by_staff_id, delegated_limit_id, reason, amount_kobo)
  values
    (p_member_id, p_venue_id, 'discretionary', v_approver, v_limit.id, trim(p_reason), p_amount_kobo)
  returning id into v_id;

  perform log_audit('staff', auth.uid(), 'discount.discretionary.approve',
                    'discount_applications', v_id::text, p_venue_id,
                    null, jsonb_build_object('member_id', p_member_id, 'amount_kobo', p_amount_kobo));
  return v_id;
end;
$$;

-- ============================================================================
-- Muse: own schema = hard namespace boundary (§3.7). No grants to anon /
-- authenticated → no direct access exists to be misconfigured. All reads via
-- logging RPCs (0008/0009).
-- ============================================================================

create schema muse;

create table muse.candidates (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members (id) on delete restrict,
  initiated_by uuid not null references public.staff_profiles (id) on delete restrict,
  initiator_role_snapshot staff_role not null,
  rationale text not null check (length(trim(rationale)) > 0),
  status muse_candidate_status not null default 'submitted',
  -- Stage 2 rides the founder-only approvals gate; declines carry the
  -- mandatory written reason there.
  approval_id uuid references public.approvals (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One open candidacy per member.
create unique index muse_candidates_open_idx
  on muse.candidates (member_id)
  where status in ('submitted', 'under_review');

create trigger muse_candidates_touch before update on muse.candidates
  for each row execute function public.touch_updated_at();

create trigger muse_candidates_audit
  after insert or update or delete on muse.candidates
  for each row execute function public.audit_row_change();

create table muse.memberships (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null unique references public.members (id) on delete restrict,
  candidate_id uuid not null references muse.candidates (id) on delete restrict,
  approved_via uuid not null references public.approvals (id) on delete restrict,
  onboarded_by uuid references public.staff_profiles (id) on delete restrict,
  onboarded_at timestamptz,
  card_id uuid, -- FK added in 0007 after member_cards exists
  status muse_membership_status not null default 'active',
  exit_reason text,
  created_at timestamptz not null default now()
);

create trigger muse_memberships_audit
  after insert or update or delete on muse.memberships
  for each row execute function public.audit_row_change();

create table muse.event_calendar (
  id uuid primary key default gen_random_uuid(),
  event_id uuid, -- FK added in 0007
  venue_id uuid references public.venues (id) on delete restrict,
  night date not null,
  label text not null, -- e.g. "Casamigas Thursday"
  benefits jsonb not null default '["cocktail_50"]',
  created_by uuid not null references public.staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);

create table muse.benefit_grants (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references muse.memberships (id) on delete restrict,
  venue_id uuid not null references public.venues (id) on delete restrict,
  type muse_benefit_type not null,
  value_kobo bigint,
  granted_by uuid not null references public.staff_profiles (id) on delete restrict,
  event_id uuid, -- FK added in 0007
  created_at timestamptz not null default now()
);

create trigger muse_benefit_grants_audit
  after insert or update or delete on muse.benefit_grants
  for each row execute function public.audit_row_change();

create table muse.content_agreements (
  id uuid primary key default gen_random_uuid(),
  membership_id uuid not null references muse.memberships (id) on delete restrict,
  summary text not null,
  agreed_terms_ref text,
  member_consented_at timestamptz,
  recorded_by uuid not null references public.staff_profiles (id) on delete restrict,
  status text not null default 'draft',
  created_at timestamptz not null default now()
);

create trigger muse_content_agreements_audit
  after insert or update or delete on muse.content_agreements
  for each row execute function public.audit_row_change();
