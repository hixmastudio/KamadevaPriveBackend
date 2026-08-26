-- ============================================================================
-- 0027 — Muse becomes a standalone programme.
--
-- Until now Muse was an overlay on public.members: muse.candidates/memberships
-- FK'd into members, the Muse card was a member_cards row, and the tier engine
-- (which keys off members + visits + spend) could move a Muse member up the
-- Privé ladder. Per the Kamadeva Muse Governance & Access note (v1.0) Muse runs
-- on a PARALLEL track that must never confer or merge with Privé tier status.
--
-- This migration adds the standalone subject and its card + credential store.
-- 0028 repoints the two FKs (candidates/memberships) off members onto it and
-- migrates the one demo membership; 0029 rewrites the RPCs.
--
-- Registration is staff-entered at initiation (invitation-only, no public form)
-- and captures full name, phone, email, and DATE OF BIRTH — the last of which
-- exists nowhere in the Privé schema.
-- ============================================================================

-- Subject lifecycle (distinct from muse_membership_status active/paused/exited,
-- which tracks the *membership* once onboarded).
create type muse_member_status as enum ('candidate', 'active', 'declined', 'paused', 'exited');

-- Human-readable Muse numbers: KM-000001, never reused (mirrors next_member_no).
create sequence muse_no_seq start 1;
create or replace function next_muse_no()
returns text
language sql
volatile
as $$
  select 'KM-' || lpad(nextval('muse_no_seq')::text, 6, '0');
$$;

-- ── The standalone Muse subject — independent of public.members ──────────────
create table muse.members (
  id            uuid primary key default gen_random_uuid(),
  muse_no       text not null unique default next_muse_no(),
  full_name     text not null check (length(trim(full_name)) >= 2),
  phone         text not null unique check (phone ~ '^\+[0-9]{8,15}$'),
  email         text not null,
  date_of_birth date not null,
  auth_user_id  uuid unique references auth.users (id) on delete set null,
  status        muse_member_status not null default 'candidate',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger muse_members_touch
  before update on muse.members
  for each row execute function public.touch_updated_at();
create trigger muse_members_audit
  after insert or update or delete on muse.members
  for each row execute function public.audit_row_change();

-- ── The aubergine Muse card — its own table. member_cards.member_id is NOT
--    NULL → public.members, so it cannot hold a standalone Muse subject. ─────
create table muse.cards (
  id             uuid primary key default gen_random_uuid(),
  muse_member_id uuid not null references muse.members (id) on delete restrict,
  qr_token       text not null unique default public.new_qr_token(),
  status         card_status not null default 'active',
  issued_at      timestamptz not null default now(),
  revoked_at     timestamptz
);
create unique index muse_cards_active_idx on muse.cards (muse_member_id) where status = 'active';

create trigger muse_cards_audit
  after insert or update or delete on muse.cards
  for each row execute function public.audit_row_change();

-- ── Login credentials — mirrors public.member_credentials (0018). NO audit
--    trigger: it would write code_hash into the audit spine. Also has no `id`
--    column, so audit_row_change() (which reads new.id) would fail anyway. ───
create table muse.credentials (
  muse_member_id  uuid primary key references muse.members (id) on delete cascade,
  code_hash       text not null,
  code_set_at     timestamptz not null default now(),
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  updated_at      timestamptz not null default now()
);

-- ── Namespace boundary — repeat 0008 for these NEW tables ───────────────────
-- 0008's blanket "revoke all on all tables in schema muse" only covered tables
-- that existed then. RLS is enabled with ZERO policies (default-deny); all Muse
-- access flows through SECURITY DEFINER RPCs (0029). The muse schema is never
-- exposed to PostgREST. muse.credentials is reachable only by service_role and
-- SECURITY DEFINER functions.
alter table muse.members     enable row level security;
alter table muse.cards       enable row level security;
alter table muse.credentials enable row level security;
revoke all on muse.members     from anon, authenticated;
revoke all on muse.cards       from anon, authenticated;
revoke all on muse.credentials from anon, authenticated;
