-- ============================================================================
-- 0004 — Activity ledger: visits, transactions, shift headcounts,
-- reservations. Ground truth for tiers and KPIs. Design doc §3.3–§3.4.
-- Append-only: corrections are voids, never deletes.
-- ============================================================================

-- Placeholder FK targets created in later migrations: events (0007).

create table visits (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  venue_id uuid not null references venues (id) on delete restrict,
  event_id uuid, -- FK added in 0007 when events exists
  reservation_id uuid, -- FK added below after reservations exists
  -- THE column tier windows read; distinct from created_at so a back-entry
  -- doesn't distort windows.
  occurred_at timestamptz not null default now(),
  business_date date not null generated always as (kp_business_date(occurred_at)) stored,
  capture_channel capture_channel not null,
  -- The atom of the 70% staff KPI.
  captured_by_staff_id uuid not null references staff_profiles (id) on delete restrict,
  -- Idempotency key from the tablet outbox — a replayed sync can never
  -- double-count a visit.
  client_capture_id uuid not null unique,
  voided_at timestamptz,
  voided_by uuid references staff_profiles (id) on delete restrict,
  void_reason text,
  created_at timestamptz not null default now(),
  check (voided_at is null or void_reason is not null)
);

-- Door scan + POS confirm the same night = ONE visit (design §3.3). The RPCs
-- upsert against this instead of erroring.
create unique index visits_one_per_night_idx
  on visits (member_id, venue_id, business_date)
  where voided_at is null;

-- The tier-window scan path.
create index visits_member_window_idx on visits (member_id, occurred_at)
  where voided_at is null;
create index visits_venue_date_idx on visits (venue_id, business_date);

create table transactions (
  id uuid primary key default gen_random_uuid(),
  -- NULLABLE by design: unattributed bills are recordable — the honest
  -- capture-rate denominator and the POS-reconciliation landing zone.
  member_id uuid references members (id) on delete restrict,
  venue_id uuid not null references venues (id) on delete restrict,
  visit_id uuid references visits (id) on delete restrict,
  event_id uuid, -- FK added in 0007
  occurred_at timestamptz not null default now(),
  business_date date not null generated always as (kp_business_date(occurred_at)) stored,
  gross_amount_kobo bigint not null check (gross_amount_kobo >= 0),
  discount_amount_kobo bigint not null default 0 check (discount_amount_kobo >= 0),
  net_amount_kobo bigint not null
    generated always as (gross_amount_kobo - discount_amount_kobo) stored,
  discount_application_id uuid, -- FK added in 0006
  promotion_applied boolean not null default false,
  source txn_source not null,
  external_ref text,
  client_capture_id uuid unique,
  entered_by_staff_id uuid not null references staff_profiles (id) on delete restrict,
  voided_at timestamptz,
  voided_by uuid references staff_profiles (id) on delete restrict,
  void_reason text,
  created_at timestamptz not null default now(),
  check (voided_at is null or void_reason is not null)
);

-- Idempotent POS/CSV ingest.
create unique index transactions_external_ref_idx
  on transactions (source, external_ref)
  where external_ref is not null;

-- Rolling-12-month SUM as an index-only scan.
create index transactions_member_window_idx
  on transactions (member_id, occurred_at) include (gross_amount_kobo)
  where voided_at is null;
create index transactions_venue_date_idx on transactions (venue_id, business_date);

-- VM-entered nightly headcount: the honest door-side KPI denominator (§3.3).
create table shift_entry_counts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues (id) on delete restrict,
  business_date date not null,
  total_entries integer not null check (total_entries >= 0),
  entered_by_staff_id uuid not null references staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (venue_id, business_date)
);

-- ── Reservations: member_id NOT NULL *is* the reservation rule (§3.4) ───────

create table reservations (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  venue_id uuid not null references venues (id) on delete restrict,
  event_id uuid, -- FK added in 0007
  reserved_for timestamptz not null,
  party_size integer not null check (party_size between 1 and 100),
  status reservation_status not null default 'requested',
  channel reservation_channel not null,
  created_by_staff_id uuid references staff_profiles (id) on delete restrict,
  seated_visit_id uuid references visits (id) on delete restrict,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- seated requires the visit link — reservation-coverage KPI is a join,
  -- not an estimate.
  check (status != 'seated' or seated_visit_id is not null)
);

create index reservations_venue_time_idx on reservations (venue_id, reserved_for);
create index reservations_member_idx on reservations (member_id, reserved_for desc);

create trigger reservations_touch before update on reservations
  for each row execute function touch_updated_at();

alter table visits
  add constraint visits_reservation_fk
  foreign key (reservation_id) references reservations (id) on delete restrict;
