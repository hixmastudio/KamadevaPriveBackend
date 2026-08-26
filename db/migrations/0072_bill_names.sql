-- ─────────────────────────────────────────────────────────────────────────────
-- 0072 — Tie profiles to Samba bill names
--
-- 0071 measured the thing nobody had measured: 0 of 978 tickets at Oso in July
-- were attributed to a member. The tier engine is fed by attributed spend, so
-- an unattributed till is a tier engine running on nothing.
--
-- The reason is structural rather than anyone's fault. Attribution today is a
-- cashier opening the POS screen, typing a ticket number and searching for a
-- member — real work, at the busiest moment of the night, for a benefit the
-- cashier does not personally see. It does not happen, and 978 says so.
--
-- Samba already knows the answer. A bill carries a customer name, because that
-- is how a tab is run. We have simply never asked for it: pos_ingest_ticket,
-- the adapter boundary, has fifteen parameters and not one of them is the name
-- on the bill.
--
-- So: capture the name, and let an unambiguous one attribute itself.
-- ─────────────────────────────────────────────────────────────────────────────

alter table pos_tickets add column if not exists bill_name text;

-- How a ticket came to be attributed. Null while unattributed. This exists so
-- that "the computer did it" is never indistinguishable from "a person did it"
-- — if the matching turns out to be wrong, the damage has to be findable.
alter table pos_tickets add column if not exists attribution_method text
  check (attribution_method in ('manual', 'bill_name'));

comment on column pos_tickets.bill_name is
  'Customer name as typed on the Samba bill. Free text, entered under pressure: expect initials, titles, nicknames and misspellings.';
comment on column pos_tickets.attribution_method is
  'manual = a member of staff chose; bill_name = matched automatically from the bill.';

-- ── Name normalisation ──────────────────────────────────────────────────────
-- Bill names are typed at a till by someone with a queue in front of them, so
-- comparing them raw is hopeless. This reduces both sides to a comparable form:
--
--   'CHIEF  Adaeze O. Okonkwo' → 'adaeze okonkwo'
--   'okonkwo adaeze'           → 'adaeze okonkwo'   (token order is not signal)
--
-- Honorifics are stripped because Nigerian bills carry them constantly and they
-- say nothing about identity — two different Chiefs are still two people.
-- Single letters go too: 'O.' is an initial, and matching on an initial would
-- make 'Adaeze O' and 'Adaeze Obi' the same person.
create or replace function normalize_bill_name(p_name text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select nullif(
    (select string_agg(t, ' ' order by t)
       from unnest(string_to_array(
              regexp_replace(
                regexp_replace(lower(coalesce(p_name, '')), '[^a-z ]', ' ', 'g'),
                '\s+', ' ', 'g'),
              ' ')) as t
      where length(t) > 1
        and t not in ('mr','mrs','miss','ms','dr','prof','chief','alhaji','alhaja',
                      'engr','barr','hon','sir','madam','mallam','oga','otunba','high')),
    '');
$$;

comment on function normalize_bill_name(text) is
  'Reduces a human-typed name to a comparable form: lowercased, punctuation dropped, honorifics and initials removed, tokens sorted so word order does not matter.';

-- Matching happens once per ingested ticket, so it is worth an index.
create index if not exists members_normalized_name_idx
  on members (normalize_bill_name(full_name)) where status = 'active';

-- ── Candidates for a bill name ──────────────────────────────────────────────
-- Returns everyone the name could plausibly mean, best first, with `exact`
-- marking a normalised equality rather than a resemblance. The distinction is
-- the whole safety argument below: only `exact` is ever acted on unattended.
create or replace function pos_match_bill_name(p_bill_name text, p_limit int default 5)
returns table (member_id uuid, member_no text, full_name text, tier tier_enum,
               exact boolean, score real)
language plpgsql
stable security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_norm text := normalize_bill_name(p_bill_name);
begin
  if current_staff_id() is null then
    raise exception 'staff session required';
  end if;
  if v_norm is null then
    return;
  end if;

  return query
  select m.id, m.member_no, m.full_name, m.current_tier,
         normalize_bill_name(m.full_name) = v_norm,
         similarity(normalize_bill_name(m.full_name), v_norm)
  from members m
  where m.status = 'active'
    and (normalize_bill_name(m.full_name) = v_norm
         or similarity(normalize_bill_name(m.full_name), v_norm) > 0.45)
  order by 5 desc, 6 desc, m.full_name
  limit least(greatest(p_limit, 1), 20);
end;
$$;

revoke execute on function pos_match_bill_name(text, int) from public, anon;
grant  execute on function pos_match_bill_name(text, int) to authenticated;

-- ── Attribution in bulk, authorised by a person ─────────────────────────────
-- The first shape of this was automatic attribution at the ingest boundary. It
-- does not work, and the reason is worth recording so it is not attempted
-- again: close_bill — which captures the visit, applies the tier discount and
-- writes the ledger row — requires a staff session and an assignment at the
-- venue. A Samba sync runs as the service role and has neither.
--
-- That guard could have been widened. It should not be: close_bill is where
-- money enters the member ledger, and "a person, at this venue, did this" is
-- precisely the property it exists to hold.
--
-- So the split is matching from attributing. Matching is mechanical and needs
-- no authority, and it is what was actually missing — the cashier's problem was
-- never one lookup, it was 978 of them. A manager reviews what the names
-- matched and authorises the lot in one action: the machine does the work, a
-- person remains accountable, and close_bill's guard is satisfied honestly
-- rather than bypassed.
--
-- WHAT MATCHING REFUSES TO DO, and why each refusal is load-bearing.
-- Attributing a bill to the wrong person is not cosmetic: it moves their spend,
-- their points and eventually their tier, handing out benefits never earned
-- while whoever actually spent the money gets nothing. A wrong match is worse
-- than no match, so the bar is exact-and-unique:
--
--   · fuzzy resemblance never attributes. Candidates above the similarity
--     floor are offered to a human by pos_match_bill_name and go no further.
--   · a single token never attributes. 'TUNDE' on a bill is not a person in a
--     city of millions, and normalize_bill_name having reduced a surname to an
--     initial is indistinguishable from there never having been one.
--   · an ambiguous name never attributes. Two active members normalising to
--     the same string means the bill genuinely does not say which, and picking
--     a row would be a coin toss recorded as a fact.
--
-- Muse is out of scope by design: Muse spend carries no ledger row and no
-- points (see pos_attach_ticket), so there is nothing here for a name match to
-- fix, and least-visibility is a poor fit for automatic anything.

create or replace function pos_auto_attach_bill_name(p_ticket_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_ticket pos_tickets%rowtype;
  v_norm text;
  v_member_id uuid;
  v_matches int;
  v_txn transactions%rowtype;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;

  select * into v_ticket from pos_tickets where id = p_ticket_id for update;
  if not found
     or not staff_has_venue(v_ticket.venue_id)
     or v_ticket.voided_at is not null
     or v_ticket.member_id is not null
     or v_ticket.muse_member_id is not null then
    return null;
  end if;

  v_norm := normalize_bill_name(v_ticket.bill_name);
  -- A name that survives normalisation as one token is not enough to act on.
  if v_norm is null or array_length(string_to_array(v_norm, ' '), 1) < 2 then
    return null;
  end if;

  -- array_agg rather than min(): uuid has no min aggregate, and taking "the
  -- lowest id" would be meaningless anyway — the count is what decides, and
  -- the id is only read when that count is exactly one.
  select count(*), (array_agg(m.id))[1] into v_matches, v_member_id
    from members m
   where m.status = 'active'
     and normalize_bill_name(m.full_name) = v_norm;

  if v_matches <> 1 then
    return null;
  end if;

  -- From here the work is exactly pos_attach_ticket's Privé branch: close_bill
  -- captures the visit, applies the tier's automatic discount, writes the
  -- ledger row and triggers the tier engine.
  v_txn := close_bill(
    p_venue_id => v_ticket.venue_id,
    p_member_id => v_member_id,
    p_gross_amount_kobo => v_ticket.total_kobo,
    p_client_capture_id => gen_random_uuid(),
    p_promotion_applied => false,
    p_occurred_at => v_ticket.occurred_at,
    p_event_id => null,
    p_discount_application_id => null
  );

  update transactions set external_ref = v_ticket.ticket_no where id = v_txn.id;

  -- attributed_by is the person who authorised the batch, not a placeholder:
  -- they are answerable for it. attribution_method records that a name match
  -- proposed it, so a bad rule stays distinguishable from a bad decision.
  update pos_tickets
     set member_id = v_member_id,
         transaction_id = v_txn.id,
         attributed_at = now(),
         attributed_by = v_staff,
         attribution_method = 'bill_name'
   where id = v_ticket.id;

  perform log_audit('staff', auth.uid(), 'pos.attribute.bill_name',
                    'pos_tickets', v_ticket.id::text, v_ticket.venue_id);

  return v_member_id;
end;
$$;

revoke execute on function pos_auto_attach_bill_name(uuid) from public, anon;
grant  execute on function pos_auto_attach_bill_name(uuid) to authenticated;

-- ── The adapter boundary learns to ask for the name ─────────────────────────
-- p_bill_name is appended last so the existing positional callers (0031's demo
-- seed) keep working untouched. The old fifteen-argument signature is dropped
-- rather than left alongside: every parameter after p_items has a default, so
-- keeping both would leave PostgREST unable to tell which one a fifteen-
-- argument call meant, and it answers ambiguity with a 300, not a guess.
drop function if exists pos_ingest_ticket(uuid, text, timestamptz, jsonb, text, text,
  bigint, bigint, bigint, bigint, text, text, text, pos_source, text);

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
  p_external_id text default null,
  p_bill_name text default null
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

  v_vat := coalesce(p_vat_kobo, round(v_subtotal * 0.075));
  v_consumption := coalesce(p_consumption_tax_kobo, round(v_subtotal * 0.05));
  v_total := v_subtotal + v_vat + v_consumption + coalesce(p_service_charge_kobo, 0);

  insert into pos_tickets (
    venue_id, ticket_no, source, external_id, occurred_at, cashier, table_label,
    bill_name, subtotal_kobo, vat_kobo, consumption_tax_kobo, service_charge_kobo,
    total_kobo, change_kobo, payment_method, acct_no, bank_name, synced_at
  ) values (
    p_venue_id, p_ticket_no, p_source, p_external_id, coalesce(p_occurred_at, now()),
    p_cashier, p_table_label, nullif(trim(coalesce(p_bill_name, '')), ''),
    v_subtotal, v_vat, v_consumption,
    coalesce(p_service_charge_kobo, 0), v_total, coalesce(p_change_kobo, 0),
    p_payment_method, p_acct_no, p_bank_name, now()
  )
  on conflict (venue_id, ticket_no) do update
    set occurred_at = excluded.occurred_at,
        cashier = excluded.cashier,
        table_label = excluded.table_label,
        -- A re-sync may carry a name the first push lacked, but must not erase
        -- one we already hold: coalesce keeps the better of the two.
        bill_name = coalesce(excluded.bill_name, pos_tickets.bill_name),
        subtotal_kobo = excluded.subtotal_kobo,
        vat_kobo = excluded.vat_kobo,
        consumption_tax_kobo = excluded.consumption_tax_kobo,
        service_charge_kobo = excluded.service_charge_kobo,
        total_kobo = excluded.total_kobo,
        change_kobo = excluded.change_kobo,
        payment_method = excluded.payment_method,
        acct_no = excluded.acct_no,
        bank_name = excluded.bank_name,
        synced_at = now()
  returning id into v_ticket_id;

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

  -- Deliberately does NOT attribute here: a sync has no staff session, and
  -- close_bill requires one. Attribution is the batch below.
  return v_ticket_id;
end;
$$;

revoke execute on function pos_ingest_ticket(uuid, text, timestamptz, jsonb, text, text,
  bigint, bigint, bigint, bigint, text, text, text, pos_source, text, text) from public, anon;
grant  execute on function pos_ingest_ticket(uuid, text, timestamptz, jsonb, text, text,
  bigint, bigint, bigint, bigint, text, text, text, pos_source, text, text)
  to authenticated, service_role;

-- ── What the names would do, before anyone commits to it ────────────────────
-- A manager should be able to see the size and the shape of the thing before
-- authorising it — how many bills carry a name at all, how many of those the
-- rules will act on, and how many are being left for a human on purpose. The
-- last number is the honest one: it is the residue the automation cannot
-- responsibly touch, and hiding it would make this look better than it is.
create or replace function pos_bill_name_preview(
  p_venue_id uuid,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
stable security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_from date := coalesce(p_from, kp_business_date(now()) - 30);
  v_to   date := coalesce(p_to, kp_business_date(now()));
  v_result jsonb;
begin
  if current_staff_id() is null or not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  with candidate as (
    select t.id, t.ticket_no, t.bill_name, t.total_kobo,
           normalize_bill_name(t.bill_name) as norm
      from pos_tickets t
     where t.venue_id = p_venue_id
       and t.business_date between v_from and v_to
       and t.voided_at is null
       and t.member_id is null
       and t.muse_member_id is null
  ), scored as (
    select c.*,
           (select count(*) from members m
             where m.status = 'active'
               and normalize_bill_name(m.full_name) = c.norm) as hits,
           (select min(m.full_name) from members m
             where m.status = 'active'
               and normalize_bill_name(m.full_name) = c.norm) as matched_name
      from candidate c
  )
  select jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'unattributed', (select count(*) from candidate),
    'with_bill_name', (select count(*) from candidate where norm is not null),
    'will_attribute', (select count(*) from scored
                        where hits = 1
                          and array_length(string_to_array(norm, ' '), 1) >= 2),
    'value_kobo', (select coalesce(sum(total_kobo), 0) from scored
                    where hits = 1
                      and array_length(string_to_array(norm, ' '), 1) >= 2),
    -- Left for a person, and why. Not a failure — a boundary.
    'needs_a_human', (select count(*) from scored
                       where norm is not null
                         and not (hits = 1
                                  and array_length(string_to_array(norm, ' '), 1) >= 2)),
    'sample', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ticket_no', s.ticket_no, 'bill_name', s.bill_name, 'member', s.matched_name))
      from (select * from scored
             where hits = 1
               and array_length(string_to_array(norm, ' '), 1) >= 2
             order by ticket_no limit 10) s
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function pos_bill_name_preview(uuid, date, date) from public, anon;
grant  execute on function pos_bill_name_preview(uuid, date, date) to authenticated;

-- ── Authorise the lot ───────────────────────────────────────────────────────
-- Restricted to managers and above rather than any staff: this writes ledger
-- rows and moves tiers in bulk, which is a different act from a cashier
-- attributing the ticket in front of them.
create or replace function pos_attribute_matched_bills(
  p_venue_id uuid,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_from date := coalesce(p_from, kp_business_date(now()) - 30);
  v_to   date := coalesce(p_to, kp_business_date(now()));
  v_ticket record;
  v_member uuid;
  v_done int := 0;
  v_value bigint := 0;
begin
  if current_staff_id() is null or not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if not is_manager_up() then
    raise exception 'attributing bills in bulk is a manager''s decision';
  end if;

  for v_ticket in
    select t.id, t.total_kobo
      from pos_tickets t
     where t.venue_id = p_venue_id
       and t.business_date between v_from and v_to
       and t.voided_at is null
       and t.member_id is null
       and t.muse_member_id is null
       and t.bill_name is not null
     order by t.occurred_at
  loop
    -- Each ticket decides for itself; the refusals live in one place.
    v_member := pos_auto_attach_bill_name(v_ticket.id);
    if v_member is not null then
      v_done := v_done + 1;
      v_value := v_value + v_ticket.total_kobo;
    end if;
  end loop;

  perform log_audit('staff', auth.uid(), 'pos.attribute.bill_name.batch',
                    'venues', p_venue_id::text, p_venue_id);

  return jsonb_build_object('attributed', v_done, 'value_kobo', v_value,
                            'from', v_from, 'to', v_to);
end;
$$;

revoke execute on function pos_attribute_matched_bills(uuid, date, date) from public, anon;
grant  execute on function pos_attribute_matched_bills(uuid, date, date) to authenticated;

-- ── The single-ticket screen shows the name, and who it might be ────────────
-- The cashier's path stays a human one, but stops being a blank search box:
-- the bill already says a name, so show it, and show who it resembles.
create or replace function pos_lookup_ticket(p_venue_id uuid, p_ticket_no text)
returns jsonb
language plpgsql
stable security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_ticket pos_tickets%rowtype;
begin
  if current_staff_id() is null or not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  select * into v_ticket from pos_tickets
  where venue_id = p_venue_id and ticket_no = trim(p_ticket_no);
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'id', v_ticket.id,
    'ticket_no', v_ticket.ticket_no,
    'occurred_at', v_ticket.occurred_at,
    'cashier', v_ticket.cashier,
    'table_label', v_ticket.table_label,
    'bill_name', v_ticket.bill_name,
    'subtotal_kobo', v_ticket.subtotal_kobo,
    'vat_kobo', v_ticket.vat_kobo,
    'consumption_tax_kobo', v_ticket.consumption_tax_kobo,
    'total_kobo', v_ticket.total_kobo,
    'voided', v_ticket.voided_at is not null,
    'already_attributed', (v_ticket.member_id is not null or v_ticket.muse_member_id is not null),
    'attributed_name', coalesce(
      (select full_name from members where id = v_ticket.member_id),
      (select full_name from muse.members where id = v_ticket.muse_member_id)),
    -- Suggestions, not decisions: `exact` tells the cashier which of these the
    -- system would have been willing to act on by itself.
    'suggestions', case when v_ticket.member_id is null and v_ticket.muse_member_id is null
      then coalesce((
        select jsonb_agg(jsonb_build_object(
          'member_id', s.member_id, 'member_no', s.member_no,
          'full_name', s.full_name, 'tier', s.tier, 'exact', s.exact))
        from pos_match_bill_name(v_ticket.bill_name, 5) s
      ), '[]'::jsonb)
      else '[]'::jsonb end,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', i.name, 'quantity', i.quantity, 'line_total_kobo', i.line_total_kobo
      ) order by i.line_no)
      from pos_ticket_items i where i.ticket_id = v_ticket.id
    ), '[]'::jsonb)
  );
end;
$$;
