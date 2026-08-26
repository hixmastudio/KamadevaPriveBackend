-- ============================================================================
-- 0007 — Events + tier-gated access windows, member cards, click-and-collect,
-- comms. Design doc §3.8.
-- ============================================================================

create table events (
  id uuid primary key default gen_random_uuid(),
  -- Oxymor for the events arm; nullable venue for off-site productions.
  venue_id uuid references venues (id) on delete restrict,
  name text not null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  capacity integer check (capacity > 0),
  status text not null default 'draft',
  -- Member-only Silver+ events (spec §12).
  min_reservation_tier tier_enum,
  created_by uuid not null references staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);

-- Tier gating as data: Gold/Black early access, Silver next wave (§3.8).
create table event_access_windows (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events (id) on delete restrict,
  min_tier tier_enum not null,
  opens_at timestamptz not null,
  unique (event_id, min_tier)
);

-- Server-side gate — must hold for portal AND staff-entered bookings alike.
create or replace function event_booking_open_for(p_event_id uuid, p_tier tier_enum)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when p_event_id is null then true
    when not exists (select 1 from event_access_windows w where w.event_id = p_event_id)
      then true
    else exists (
      select 1 from event_access_windows w
      where w.event_id = p_event_id
        and w.opens_at <= now()
        and p_tier >= w.min_tier
    )
  end;
$$;

-- Late FKs now that events exists.
alter table visits
  add constraint visits_event_fk foreign key (event_id) references events (id) on delete restrict;
alter table transactions
  add constraint transactions_event_fk foreign key (event_id) references events (id) on delete restrict;
alter table reservations
  add constraint reservations_event_fk foreign key (event_id) references events (id) on delete restrict;
alter table discount_designations
  add constraint discount_designations_event_fk foreign key (event_id) references events (id) on delete restrict;
alter table muse.event_calendar
  add constraint muse_event_calendar_event_fk foreign key (event_id) references events (id) on delete restrict;
alter table muse.benefit_grants
  add constraint muse_benefit_grants_event_fk foreign key (event_id) references events (id) on delete restrict;

-- ── Member cards (§3.8) ─────────────────────────────────────────────────────
-- qr_token is random and revocable; never encodes member identity. The same
-- token backs the Phase 2 web card and the Phase 3 wallet passes.

create table member_cards (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  kind card_kind not null,
  qr_token text not null unique default new_qr_token(),
  status card_status not null default 'active',
  wallet_pass_serial text,
  wallet_platform text,
  issued_at timestamptz not null default now(),
  revoked_at timestamptz
);

-- One active card per member per kind.
create unique index member_cards_active_idx
  on member_cards (member_id, kind)
  where status = 'active';

create trigger member_cards_audit
  after insert or update or delete on member_cards
  for each row execute function audit_row_change();

alter table muse.memberships
  add constraint muse_memberships_card_fk
  foreign key (card_id) references public.member_cards (id) on delete restrict;

-- Auto-issue a Privé card the first time a member reaches Member tier or
-- above (design §10.1: issued at the moment of tier activation).
create or replace function trg_issue_card_on_promotion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.to_tier != 'guest' and new.reason in ('auto_promotion', 'approved_promotion', 'invitation_accepted') then
    insert into member_cards (member_id, kind)
    select new.member_id, 'prive'
    where not exists (
      select 1 from member_cards
      where member_id = new.member_id and kind = 'prive' and status = 'active'
    );
  end if;
  return null;
end;
$$;

create trigger tier_events_issue_card
  after insert on tier_events
  for each row execute function trg_issue_card_on_promotion();

-- ── Click-and-collect (Phase 2 UI; schema now) ──────────────────────────────

create table catalog_items (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues (id) on delete restrict,
  name text not null,
  description text,
  price_kobo bigint not null check (price_kobo >= 0),
  is_active boolean not null default true,
  created_by uuid not null references staff_profiles (id) on delete restrict,
  created_at timestamptz not null default now()
);

create table collect_orders (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  venue_id uuid not null references venues (id) on delete restrict,
  status collect_order_status not null default 'placed',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger collect_orders_touch before update on collect_orders
  for each row execute function touch_updated_at();

create table collect_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references collect_orders (id) on delete restrict,
  catalog_item_id uuid not null references catalog_items (id) on delete restrict,
  quantity integer not null check (quantity > 0),
  unit_price_kobo bigint not null check (unit_price_kobo >= 0)
);

-- ── Comms (Phase 3 pipeline; schema now) ────────────────────────────────────

create table comms_messages (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members (id) on delete restrict,
  channel text not null default 'whatsapp',
  template_key text not null,
  payload jsonb not null default '{}',
  status comms_status not null default 'queued',
  provider_ref text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  delivered_at timestamptz
);

create index comms_messages_queue_idx on comms_messages (status, created_at)
  where status = 'queued';
