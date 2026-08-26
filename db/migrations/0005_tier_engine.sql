-- ============================================================================
-- 0005 — Tier engine: tier ledger + unbypassable Gold/Black gate, approvals,
-- committee sign-offs, invitations, delegations, eligibility flags, the
-- canonical rolling-window function, and recompute. Design doc §3.5, §3.11,
-- §3.12, §4.4.
-- ============================================================================

-- ── Approvals: the gated-decision record ────────────────────────────────────

create table approvals (
  id uuid primary key default gen_random_uuid(),
  subject_type approval_subject not null,
  member_id uuid references members (id) on delete restrict,
  -- The "relevant venue" for committee checks.
  venue_id uuid references venues (id) on delete restrict,
  target_tier tier_enum,
  status approval_status not null default 'pending',
  requested_by uuid not null references staff_profiles (id) on delete restrict,
  rationale text not null check (length(trim(rationale)) > 0),
  decided_by uuid references staff_profiles (id) on delete restrict,
  decided_at timestamptz,
  -- Written declines are structural (design §3.5).
  decision_reason text,
  consumed_by_tier_event_id uuid, -- FK added below after tier_events exists
  minutes text,
  created_at timestamptz not null default now(),
  check (status != 'declined' or decision_reason is not null),
  check (subject_type not in ('tier_gold', 'tier_black') or target_tier is not null)
);

create index approvals_pending_idx on approvals (subject_type, created_at)
  where status = 'pending';
create index approvals_member_idx on approvals (member_id, created_at desc);

create trigger approvals_audit
  after insert or update or delete on approvals
  for each row execute function audit_row_change();

-- ── Committee sign-offs: the committee, in the schema (§3.5) ────────────────

create table tier_approval_signoffs (
  id uuid primary key default gen_random_uuid(),
  approval_id uuid not null references approvals (id) on delete restrict,
  signer_staff_id uuid not null references staff_profiles (id) on delete restrict,
  role_at_signing signoff_role not null,
  signed_at timestamptz not null default now(),
  unique (approval_id, role_at_signing)
);

create trigger tier_approval_signoffs_audit
  after insert or update or delete on tier_approval_signoffs
  for each row execute function audit_row_change();

-- ── Named, audited delegates (§3.5) ─────────────────────────────────────────

create table approval_delegations (
  id uuid primary key default gen_random_uuid(),
  scope delegation_scope not null,
  delegate_staff_id uuid not null references staff_profiles (id) on delete restrict,
  granted_by uuid not null references staff_profiles (id) on delete restrict,
  active_from timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create trigger approval_delegations_audit
  after insert or update or delete on approval_delegations
  for each row execute function audit_row_change();

create or replace function staff_holds_delegation(p_staff_id uuid, p_scope delegation_scope)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from approval_delegations
    where delegate_staff_id = p_staff_id
      and scope = p_scope
      and active_from <= now()
      and revoked_at is null
  );
$$;

-- Committee completeness gate: an approval for Gold/Black cannot reach
-- 'approved' without all three sign-offs, with venue and role validation.
create or replace function approvals_committee_gate()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signoffs int;
  v_vm_ok boolean;
  v_founder_ok boolean;
begin
  if new.status = 'approved'
     and old.status is distinct from 'approved'
     and new.subject_type in ('tier_gold', 'tier_black') then

    select count(*) into v_signoffs
    from tier_approval_signoffs where approval_id = new.id;

    if v_signoffs < 3 then
      raise exception 'tier approval % requires all three committee sign-offs (hosl, venue_manager, founder_rep); has %',
        new.id, v_signoffs;
    end if;

    -- The venue-manager signer must hold an active assignment at the
    -- approval's venue.
    select exists (
      select 1
      from tier_approval_signoffs s
      join staff_venue_assignments a
        on a.staff_id = s.signer_staff_id
       and a.venue_id = new.venue_id
       and a.revoked_at is null
      where s.approval_id = new.id
        and s.role_at_signing = 'venue_manager'
    ) into v_vm_ok;

    if not v_vm_ok then
      raise exception 'venue_manager sign-off on approval % must come from a manager assigned to the approval venue', new.id;
    end if;

    -- The founder-rep signer must be a founder or hold a recorded delegation.
    select exists (
      select 1
      from tier_approval_signoffs s
      join staff_profiles p on p.id = s.signer_staff_id
      where s.approval_id = new.id
        and s.role_at_signing = 'founder_rep'
        and (p.role = 'founder' or staff_holds_delegation(p.id, 'tier_founder_rep'))
    ) into v_founder_ok;

    if not v_founder_ok then
      raise exception 'founder_rep sign-off on approval % must come from a founder or a recorded delegate', new.id;
    end if;
  end if;

  return new;
end;
$$;

create trigger approvals_committee_gate_trg
  before update on approvals
  for each row execute function approvals_committee_gate();

-- ── Tier ledger + THE gate (§3.5) ───────────────────────────────────────────

create table tier_events (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  from_tier tier_enum not null,
  to_tier tier_enum not null,
  reason tier_event_reason not null,
  approval_id uuid references approvals (id) on delete restrict,
  -- Visits/spend at decision time — evidence forever.
  stats_snapshot jsonb not null,
  effected_by actor_type not null,
  staff_id uuid references staff_profiles (id) on delete restrict,
  occurred_at timestamptz not null default now()
);

create index tier_events_member_idx on tier_events (member_id, occurred_at desc);

alter table approvals
  add constraint approvals_consumed_by_fk
  foreign key (consumed_by_tier_event_id) references tier_events (id) on delete restrict;

-- THE GATE: no tier_events row may promote to gold/black without a matching
-- approved, unconsumed approval. One approval mints exactly one promotion.
-- Unbypassable: lives below every client, every RPC, every buggy app build.
create or replace function tier_events_gate()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_approval approvals%rowtype;
begin
  if new.to_tier in ('gold', 'black')
     and new.to_tier is distinct from new.from_tier
     and new.reason not in ('demotion_window_decay', 'revocation') then

    if new.approval_id is null then
      raise exception 'promotion to % requires an approval', new.to_tier;
    end if;

    select * into v_approval from approvals where id = new.approval_id for update;

    if not found then
      raise exception 'approval % not found', new.approval_id;
    end if;
    if v_approval.status != 'approved' then
      raise exception 'approval % is not approved (status: %)', new.approval_id, v_approval.status;
    end if;
    if v_approval.member_id is distinct from new.member_id then
      raise exception 'approval % is for a different member', new.approval_id;
    end if;
    if v_approval.target_tier is distinct from new.to_tier then
      raise exception 'approval % targets tier %, not %', new.approval_id, v_approval.target_tier, new.to_tier;
    end if;
    if v_approval.consumed_by_tier_event_id is not null then
      raise exception 'approval % has already been consumed', new.approval_id;
    end if;
    -- The FOR UPDATE above holds the approval locked until commit, so a
    -- concurrent insert cannot pass this validation before consumption below.
  end if;

  return new;
end;
$$;

create trigger tier_events_gate_trg
  before insert on tier_events
  for each row execute function tier_events_gate();

-- Consumption happens AFTER insert (the FK target row must exist).
-- One approval = one promotion, no replay.
create or replace function tier_events_consume_approval()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.to_tier in ('gold', 'black')
     and new.to_tier is distinct from new.from_tier
     and new.reason not in ('demotion_window_decay', 'revocation')
     and new.approval_id is not null then
    update approvals
      set consumed_by_tier_event_id = new.id
      where id = new.approval_id;
  end if;
  return null;
end;
$$;

create trigger tier_events_consume_trg
  after insert on tier_events
  for each row execute function tier_events_consume_approval();

-- tier_events is a ledger: no updates or deletes, ever.
create trigger tier_events_immutable
  before update or delete on tier_events
  for each row execute function audit_events_immutable();

create trigger tier_events_audit
  after insert on tier_events
  for each row execute function audit_row_change();

-- ── Invitations (Black, Muse): only exist after approval (§3.5) ─────────────

create table invitations (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  kind invitation_kind not null,
  approval_id uuid not null references approvals (id) on delete restrict,
  issued_by uuid not null references staff_profiles (id) on delete restrict,
  status invitation_status not null default 'issued',
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create trigger invitations_audit
  after insert or update or delete on invitations
  for each row execute function audit_row_change();

-- ── Eligibility flags: surfacing, never promotion (§3.5) ────────────────────

create table eligibility_flags (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  target_tier tier_enum not null,
  stats_snapshot jsonb not null,
  status eligibility_status not null default 'open',
  first_flagged_at timestamptz not null default now(),
  last_refreshed_at timestamptz not null default now(),
  unique (member_id, target_tier)
);

-- ── The canonical rolling-window function (§3.11) ───────────────────────────
-- The ONLY definition of window math anywhere in the system. No TypeScript
-- copy may exist.

create or replace function compute_member_stats(p_member_id uuid, p_as_of timestamptz default now())
returns table (visits_90d integer, visits_12m integer, spend_12m_kobo bigint)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    (select count(*)::int from visits v
      where v.member_id = p_member_id
        and v.voided_at is null
        and v.occurred_at > p_as_of - interval '90 days'
        and v.occurred_at <= p_as_of),
    (select count(*)::int from visits v
      where v.member_id = p_member_id
        and v.voided_at is null
        and v.occurred_at > p_as_of - interval '12 months'
        and v.occurred_at <= p_as_of),
    (select coalesce(sum(t.gross_amount_kobo), 0)::bigint from transactions t
      where t.member_id = p_member_id
        and t.voided_at is null
        and t.occurred_at > p_as_of - interval '12 months'
        and t.occurred_at <= p_as_of);
$$;

-- Dashboard cache — rebuildable, zero authority (§3.11). Tier decisions
-- never read it.
create table member_rolling_stats (
  member_id uuid primary key references members (id) on delete cascade,
  visits_90d integer not null,
  visits_12m integer not null,
  spend_12m_kobo bigint not null,
  computed_at timestamptz not null default now()
);

-- ── Recompute: the heart of the system (§3.12) ──────────────────────────────
-- Applied tier = min(eligibility, approval ceiling). Guest→Member and →Silver
-- auto-apply. Gold/Black eligibility only flags. Never demotes — decay is the
-- nightly sweep's job (sweep_tier_decay), and Gold/Black exits are human-only.

create or replace function recompute_member_tier(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
  v_stats record;
  v_eligible tier_enum;
  v_target tier_enum;
  v_snapshot jsonb;
begin
  -- Serialize per member; convergent because we re-read the full window.
  select * into v_member from members where id = p_member_id for update;
  if not found or v_member.status != 'active' then
    return;
  end if;

  select * into v_stats from compute_member_stats(p_member_id);
  v_snapshot := jsonb_build_object(
    'visits_90d', v_stats.visits_90d,
    'visits_12m', v_stats.visits_12m,
    'spend_12m_kobo', v_stats.spend_12m_kobo
  );

  -- Refresh the dashboard cache (no authority).
  insert into member_rolling_stats (member_id, visits_90d, visits_12m, spend_12m_kobo, computed_at)
  values (p_member_id, v_stats.visits_90d, v_stats.visits_12m, v_stats.spend_12m_kobo, now())
  on conflict (member_id) do update
    set visits_90d = excluded.visits_90d,
        visits_12m = excluded.visits_12m,
        spend_12m_kobo = excluded.spend_12m_kobo,
        computed_at = excluded.computed_at;

  -- Eligibility ladder (auto-applicable portion).
  v_eligible := 'guest';
  if v_stats.visits_90d >= config_int('tier_member_visits_90d') then
    v_eligible := 'member';
  end if;
  if v_stats.spend_12m_kobo >= config_int('tier_silver_spend_kobo')
     or v_stats.visits_12m >= config_int('tier_silver_visits_12m') then
    v_eligible := 'silver';
  end if;

  -- Gold/Black: flag, never promote (§3.12).
  if v_stats.spend_12m_kobo >= config_int('tier_black_spend_kobo')
     and v_member.current_tier not in ('black') then
    insert into eligibility_flags (member_id, target_tier, stats_snapshot)
    values (p_member_id, 'black', v_snapshot)
    on conflict (member_id, target_tier) do update
      set stats_snapshot = excluded.stats_snapshot,
          last_refreshed_at = now(),
          status = case when eligibility_flags.status = 'dismissed'
                        then eligibility_flags.status else eligibility_flags.status end;
  elsif v_stats.spend_12m_kobo >= config_int('tier_gold_spend_kobo')
     and v_member.current_tier not in ('gold', 'black') then
    insert into eligibility_flags (member_id, target_tier, stats_snapshot)
    values (p_member_id, 'gold', v_snapshot)
    on conflict (member_id, target_tier) do update
      set stats_snapshot = excluded.stats_snapshot,
          last_refreshed_at = now();
  end if;

  -- Auto-promotion only ever moves UP into member/silver; approval-granted
  -- tiers are a ceiling recompute never touches.
  if v_eligible in ('member', 'silver')
     and (
       (v_member.current_tier = 'guest') or
       (v_member.current_tier = 'member' and v_eligible = 'silver')
     ) then
    v_target := v_eligible;

    insert into tier_events (member_id, from_tier, to_tier, reason, stats_snapshot, effected_by)
    values (p_member_id, v_member.current_tier, v_target, 'auto_promotion', v_snapshot, 'system');

    update members
      set current_tier = v_target, tier_computed_at = now()
      where id = p_member_id;
  else
    update members set tier_computed_at = now() where id = p_member_id;
  end if;
end;
$$;

-- Triggers: recompute on every ledger change (insert + void). AFTER row-level;
-- volumes are small (design §1 volume reality).
create or replace function trg_recompute_from_visit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform recompute_member_tier(coalesce(new.member_id, old.member_id));
  return null;
end;
$$;

create trigger visits_recompute
  after insert or update of voided_at on visits
  for each row execute function trg_recompute_from_visit();

create or replace function trg_recompute_from_txn()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(new.member_id, old.member_id) is not null then
    perform recompute_member_tier(coalesce(new.member_id, old.member_id));
  end if;
  return null;
end;
$$;

create trigger transactions_recompute
  after insert or update of voided_at, member_id on transactions
  for each row execute function trg_recompute_from_txn();

-- ── Nightly sweep (§3.12): decay + self-healing drift detection ─────────────
-- Runs at 06:30 Africa/Lagos (05:30 UTC), just after the business-date cutoff.

create or replace function sweep_tier_decay()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
  v_stats record;
  v_eligible tier_enum;
  v_grace interval := make_interval(days => config_int('demotion_grace_days')::int);
  v_snapshot jsonb;
  v_last_change timestamptz;
begin
  for r in select id, current_tier from members where status = 'active' loop
    select * into v_stats from compute_member_stats(r.id);
    v_snapshot := jsonb_build_object(
      'visits_90d', v_stats.visits_90d,
      'visits_12m', v_stats.visits_12m,
      'spend_12m_kobo', v_stats.spend_12m_kobo
    );

    -- Refresh cache for everyone (windows decay with no writes).
    insert into member_rolling_stats (member_id, visits_90d, visits_12m, spend_12m_kobo, computed_at)
    values (r.id, v_stats.visits_90d, v_stats.visits_12m, v_stats.spend_12m_kobo, now())
    on conflict (member_id) do update
      set visits_90d = excluded.visits_90d,
          visits_12m = excluded.visits_12m,
          spend_12m_kobo = excluded.spend_12m_kobo,
          computed_at = excluded.computed_at;

    v_eligible := 'guest';
    if v_stats.visits_90d >= config_int('tier_member_visits_90d') then
      v_eligible := 'member';
    end if;
    if v_stats.spend_12m_kobo >= config_int('tier_silver_spend_kobo')
       or v_stats.visits_12m >= config_int('tier_silver_visits_12m') then
      v_eligible := 'silver';
    end if;

    -- Member/Silver decay with grace; Gold/Black are never auto-demoted —
    -- decay there raises an HoSL review flag instead (design §3.12).
    if r.current_tier in ('member', 'silver')
       and v_eligible < r.current_tier then
      select max(occurred_at) into v_last_change
      from tier_events where member_id = r.id;

      if v_last_change is not null and now() - v_last_change > v_grace then
        insert into tier_events (member_id, from_tier, to_tier, reason, stats_snapshot, effected_by)
        values (r.id, r.current_tier, v_eligible, 'demotion_window_decay', v_snapshot, 'system');
        update members set current_tier = v_eligible, tier_computed_at = now() where id = r.id;
        perform log_audit('system', null, 'tier.demote.decay', 'members', r.id::text,
                          null, null, v_snapshot);
      end if;
    elsif r.current_tier in ('gold', 'black') then
      -- Spend below qualification → review flag, human decision.
      if (r.current_tier = 'gold' and v_stats.spend_12m_kobo < config_int('tier_gold_spend_kobo'))
         or (r.current_tier = 'black' and v_stats.spend_12m_kobo < config_int('tier_black_spend_kobo')) then
        perform log_audit('system', null, 'tier.decay.review_flag', 'members', r.id::text,
                          null, null, v_snapshot);
      end if;
    end if;
  end loop;
end;
$$;

-- pg_cron scheduling — guarded so environments without the extension
-- (local test databases) still migrate cleanly.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('tier-decay-sweep', '30 5 * * *', 'select sweep_tier_decay()');
  perform cron.schedule(
    'audit-partition-ensure', '0 4 1 * *',
    $cron$select ensure_audit_partition((date_trunc('month', now()) + interval '2 months')::date)$cron$
  );
exception when others then
  raise notice 'pg_cron unavailable here (%) — schedule sweep_tier_decay() externally', sqlerrm;
end;
$$;
