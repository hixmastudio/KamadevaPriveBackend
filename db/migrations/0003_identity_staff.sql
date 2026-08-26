-- ============================================================================
-- 0003 — Identity (venues, members, consents) and staff. Design doc §3.1–§3.2.
-- ============================================================================

-- ── Venues ──────────────────────────────────────────────────────────────────
-- All five seeded from day one; launching a venue later = flip is_active.

create table venues (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  type venue_type not null,
  is_active boolean not null default true,
  launched_at date,
  timezone text not null default 'Africa/Lagos',
  created_at timestamptz not null default now()
);

-- ── Members: the unified cross-venue profile ────────────────────────────────

create table members (
  id uuid primary key default gen_random_uuid(),
  member_no text not null unique default next_member_no(),
  -- Phone is THE business identifier (non-negotiable #2). uuid stays the PK:
  -- numbers change — merge, don't re-key.
  phone text not null unique check (phone ~ '^\+[0-9]{8,15}$'),
  full_name text not null check (length(trim(full_name)) >= 2),
  instagram_handle text,
  email text,
  -- Sensitive; surfaced only inside Muse initiation flows (design §3.1).
  gender text,
  -- Projection of the latest tier_events row — written only by the tier engine.
  current_tier tier_enum not null default 'guest',
  tier_computed_at timestamptz,
  home_venue_id uuid references venues (id) on delete restrict,
  -- Linked when the member claims a portal account (Phase 2).
  auth_user_id uuid unique references auth.users (id) on delete set null,
  status member_status not null default 'active',
  merged_into_member_id uuid references members (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status != 'merged' or merged_into_member_id is not null)
);

create index members_full_name_trgm_idx on members using gin (full_name extensions.gin_trgm_ops);
create index members_tier_idx on members (current_tier) where status = 'active';

create or replace function touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger members_touch before update on members
  for each row execute function touch_updated_at();

create trigger members_audit
  after insert or update or delete on members
  for each row execute function audit_row_change();

-- ── Consents: append-only history, never booleans (NDPR provenance) ─────────

create table consents (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  consent_type consent_type not null,
  granted boolean not null,
  channel consent_channel not null,
  captured_by_staff_id uuid, -- FK added after staff_profiles exists
  wording_version text not null default 'v1',
  granted_at timestamptz not null default now()
);

create index consents_member_idx on consents (member_id, consent_type, granted_at desc);

-- Latest consent per member/type.
create view current_consents as
select distinct on (member_id, consent_type)
  member_id, consent_type, granted, channel, wording_version, granted_at
from consents
order by member_id, consent_type, granted_at desc;

-- ── Staff ───────────────────────────────────────────────────────────────────

create table staff_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users (id) on delete restrict,
  full_name text not null,
  role staff_role not null,
  -- bcrypt hash of the 4-digit PIN for shared-tablet identity switching (§4).
  pin_hash text,
  is_active boolean not null default true,
  deactivated_at timestamptz,
  created_at timestamptz not null default now()
);

create trigger staff_profiles_audit
  after insert or update or delete on staff_profiles
  for each row execute function audit_row_change();

create table staff_venue_assignments (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references staff_profiles (id) on delete restrict,
  venue_id uuid not null references venues (id) on delete restrict,
  assigned_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index sva_staff_idx on staff_venue_assignments (staff_id) where revoked_at is null;
create index sva_venue_idx on staff_venue_assignments (venue_id) where revoked_at is null;

alter table consents
  add constraint consents_captured_by_fk
  foreign key (captured_by_staff_id) references staff_profiles (id) on delete restrict;

-- ── RLS helper functions (design §4) ────────────────────────────────────────
-- JWT claims are a cache; these re-verify against tables on every policy check.

create or replace function current_staff_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from staff_profiles
  where auth_user_id = auth.uid() and is_active;
$$;

create or replace function current_staff_role()
returns staff_role
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select role from staff_profiles
  where auth_user_id = auth.uid() and is_active;
$$;

-- One definition of venue scoping for every policy (design §4.5).
-- Founders and HoSL are global; VMs and hosts need an active assignment.
create or replace function staff_has_venue(p_venue_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when current_staff_role() in ('founder', 'hosl') then true
    else exists (
      select 1 from staff_venue_assignments a
      where a.staff_id = current_staff_id()
        and a.venue_id = p_venue_id
        and a.revoked_at is null
    )
  end;
$$;

create or replace function current_member_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from members
  where auth_user_id = auth.uid() and status = 'active';
$$;
