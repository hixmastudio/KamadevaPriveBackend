-- ============================================================================
-- 0030 — Samba POS receipts (the Transactions surface).
--
-- `transactions` is the loyalty/financial ledger: one row per attributed bill,
-- feeding the tier engine and the Command Centre. It has no itemisation, so it
-- cannot reproduce a receipt.
--
-- Samba POS is the source of truth for what was actually sold. This migration
-- adds the receipt layer that mirrors an Oso Lounge ticket exactly (ticket no,
-- cashier, table, line items, subtotal, 7.5% VAT, consumption tax, total,
-- change, settlement account) so the Transactions page can render a faithful
-- receipt preview.
--
-- Samba is NOT wired yet. `pos_ingest_ticket` is the adapter boundary: a single
-- idempotent entry point (upsert on venue + ticket_no) that a Samba sync job or
-- webhook will call later. Until then the same RPC seeds demo content, so the
-- UI is built against the real shape.
--
-- Attribution (POS rework): a ticket may later be tied to a Privé member OR a
-- standalone Muse member, which is what turns a receipt into loyalty.
-- ============================================================================

create type pos_source as enum ('samba', 'manual', 'demo');

-- Receipts print the venue's trading address; venues had no place to hold it.
alter table venues add column if not exists address text;

create table pos_tickets (
  id              uuid primary key default gen_random_uuid(),
  venue_id        uuid not null references venues (id) on delete restrict,
  ticket_no       text not null,
  source          pos_source not null default 'samba',
  external_id     text,
  occurred_at     timestamptz not null default now(),
  business_date   date not null generated always as (kp_business_date(occurred_at)) stored,
  cashier         text,
  table_label     text,

  -- Money, in kobo. Mirrors the printed receipt line for line.
  subtotal_kobo         bigint not null check (subtotal_kobo >= 0),
  vat_kobo              bigint not null default 0 check (vat_kobo >= 0),
  consumption_tax_kobo  bigint not null default 0 check (consumption_tax_kobo >= 0),
  service_charge_kobo   bigint not null default 0 check (service_charge_kobo >= 0),
  total_kobo            bigint not null check (total_kobo >= 0),
  change_kobo           bigint not null default 0 check (change_kobo >= 0),

  payment_method  text,
  acct_no         text,
  bank_name       text,

  -- Attribution — at most one subject; a ticket may stay unattributed (walk-in).
  member_id       uuid references members (id) on delete restrict,
  muse_member_id  uuid references muse.members (id) on delete restrict,
  transaction_id  uuid references transactions (id) on delete set null,
  attributed_at   timestamptz,
  attributed_by   uuid references staff_profiles (id) on delete restrict,

  voided_at       timestamptz,
  synced_at       timestamptz not null default now(),
  created_at      timestamptz not null default now(),

  constraint pos_tickets_ticket_no_uniq unique (venue_id, ticket_no),
  constraint pos_tickets_one_subject check (member_id is null or muse_member_id is null)
);

create index pos_tickets_recent_idx on pos_tickets (venue_id, occurred_at desc);
create index pos_tickets_business_date_idx on pos_tickets (business_date);
create index pos_tickets_member_idx on pos_tickets (member_id) where member_id is not null;

create table pos_ticket_items (
  id              uuid primary key default gen_random_uuid(),
  ticket_id       uuid not null references pos_tickets (id) on delete cascade,
  line_no         int not null default 1,
  name            text not null,
  quantity        numeric(10,2) not null default 1 check (quantity > 0),
  unit_price_kobo bigint not null check (unit_price_kobo >= 0),
  line_total_kobo bigint not null check (line_total_kobo >= 0)
);

create index pos_ticket_items_ticket_idx on pos_ticket_items (ticket_id, line_no);

create trigger pos_tickets_audit
  after insert or update or delete on pos_tickets
  for each row execute function audit_row_change();

-- ── RLS — same posture as `transactions`: managers and above, own venues ────
alter table pos_tickets      enable row level security;
alter table pos_ticket_items enable row level security;

create policy pos_tickets_read on pos_tickets for select to authenticated
  using (is_manager_up() and staff_has_venue(venue_id));

create policy pos_ticket_items_read on pos_ticket_items for select to authenticated
  using (exists (
    select 1 from pos_tickets t
    where t.id = pos_ticket_items.ticket_id
      and is_manager_up() and staff_has_venue(t.venue_id)
  ));

-- Writes go through the RPCs below only.
revoke insert, update, delete on pos_tickets      from anon, authenticated;
revoke insert, update, delete on pos_ticket_items from anon, authenticated;

-- ── Adapter boundary: the single entry point Samba will call ────────────────
-- Idempotent on (venue_id, ticket_no) so a re-sync never duplicates a receipt.
-- p_items: [{"name":"HONEY BBQ WINGS","quantity":1,"unit_price_kobo":1850000}, …]
create or replace function pos_ingest_ticket(
  p_venue_id uuid,
  p_ticket_no text,
  p_occurred_at timestamptz,
  p_items jsonb,
  p_cashier text default null,
  p_table_label text default null,
  p_vat_kobo bigint default null,
  p_consumption_tax_kobo bigint default null,
  p_service_charge_kobo bigint default 0,
  p_change_kobo bigint default 0,
  p_payment_method text default null,
  p_acct_no text default null,
  p_bank_name text default null,
  p_source pos_source default 'samba',
  p_external_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ticket_id uuid;
  v_subtotal bigint := 0;
  v_vat bigint;
  v_consumption bigint;
  v_total bigint;
  v_item jsonb;
  v_line int := 0;
begin
  -- Staff (any role) or the service role running the sync.
  if current_staff_id() is null and auth.uid() is not null then
    raise exception 'staff session required';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'a ticket needs at least one line item';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_subtotal := v_subtotal
      + round((v_item->>'unit_price_kobo')::numeric * coalesce((v_item->>'quantity')::numeric, 1));
  end loop;

  -- Nigerian VAT is 7.5%; consumption tax 5% (Abuja). Callers may override.
  v_vat := coalesce(p_vat_kobo, round(v_subtotal * 0.075));
  v_consumption := coalesce(p_consumption_tax_kobo, round(v_subtotal * 0.05));
  v_total := v_subtotal + v_vat + v_consumption + coalesce(p_service_charge_kobo, 0);

  insert into pos_tickets (
    venue_id, ticket_no, source, external_id, occurred_at, cashier, table_label,
    subtotal_kobo, vat_kobo, consumption_tax_kobo, service_charge_kobo,
    total_kobo, change_kobo, payment_method, acct_no, bank_name, synced_at
  ) values (
    p_venue_id, p_ticket_no, p_source, p_external_id, coalesce(p_occurred_at, now()),
    p_cashier, p_table_label, v_subtotal, v_vat, v_consumption,
    coalesce(p_service_charge_kobo, 0), v_total, coalesce(p_change_kobo, 0),
    p_payment_method, p_acct_no, p_bank_name, now()
  )
  on conflict (venue_id, ticket_no) do update
    set occurred_at = excluded.occurred_at,
        cashier = excluded.cashier,
        table_label = excluded.table_label,
        subtotal_kobo = excluded.subtotal_kobo,
        vat_kobo = excluded.vat_kobo,
        consumption_tax_kobo = excluded.consumption_tax_kobo,
        service_charge_kobo = excluded.service_charge_kobo,
        total_kobo = excluded.total_kobo,
        change_kobo = excluded.change_kobo,
        payment_method = excluded.payment_method,
        synced_at = now()
  returning id into v_ticket_id;

  -- Re-sync replaces the itemisation wholesale.
  delete from pos_ticket_items where ticket_id = v_ticket_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_line := v_line + 1;
    insert into pos_ticket_items (ticket_id, line_no, name, quantity, unit_price_kobo, line_total_kobo)
    values (
      v_ticket_id, v_line, v_item->>'name',
      coalesce((v_item->>'quantity')::numeric, 1),
      (v_item->>'unit_price_kobo')::bigint,
      round((v_item->>'unit_price_kobo')::numeric * coalesce((v_item->>'quantity')::numeric, 1))
    );
  end loop;

  return v_ticket_id;
end;
$$;

-- ── Full receipt for the preview drawer ─────────────────────────────────────
create or replace function pos_get_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if current_staff_role() is null or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'not authorized';
  end if;

  select jsonb_build_object(
    'id', t.id,
    'ticket_no', t.ticket_no,
    'venue', v2.name,
    'venue_address', v2.address,
    'occurred_at', t.occurred_at,
    'business_date', t.business_date,
    'cashier', t.cashier,
    'table_label', t.table_label,
    'subtotal_kobo', t.subtotal_kobo,
    'vat_kobo', t.vat_kobo,
    'consumption_tax_kobo', t.consumption_tax_kobo,
    'service_charge_kobo', t.service_charge_kobo,
    'total_kobo', t.total_kobo,
    'change_kobo', t.change_kobo,
    'payment_method', t.payment_method,
    'acct_no', t.acct_no,
    'bank_name', t.bank_name,
    'source', t.source,
    'voided_at', t.voided_at,
    'member', case when m.id is null then null else jsonb_build_object(
      'kind', 'prive', 'id', m.id, 'full_name', m.full_name,
      'member_no', m.member_no, 'tier', m.current_tier) end,
    'muse_member', case when mm.id is null then null else jsonb_build_object(
      'kind', 'muse', 'id', mm.id, 'full_name', mm.full_name, 'muse_no', mm.muse_no) end,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', i.name, 'quantity', i.quantity,
        'unit_price_kobo', i.unit_price_kobo, 'line_total_kobo', i.line_total_kobo
      ) order by i.line_no)
      from pos_ticket_items i where i.ticket_id = t.id
    ), '[]'::jsonb)
  ) into v
  from pos_tickets t
  join venues v2 on v2.id = t.venue_id
  left join members m on m.id = t.member_id
  left join muse.members mm on mm.id = t.muse_member_id
  where t.id = p_ticket_id
    and staff_has_venue(t.venue_id);

  return v;
end;
$$;

revoke execute on function pos_ingest_ticket(uuid, text, timestamptz, jsonb, text, text, bigint, bigint, bigint, bigint, text, text, text, pos_source, text) from public, anon;
grant  execute on function pos_ingest_ticket(uuid, text, timestamptz, jsonb, text, text, bigint, bigint, bigint, bigint, text, text, text, pos_source, text) to authenticated, service_role;
revoke execute on function pos_get_ticket(uuid) from public, anon;
grant  execute on function pos_get_ticket(uuid) to authenticated;
