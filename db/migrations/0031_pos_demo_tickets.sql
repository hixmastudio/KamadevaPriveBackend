-- ============================================================================
-- 0031 — Demo POS tickets, seeded through the real Samba adapter.
--
-- Samba is not wired yet, so the Transactions surface needs content to be built
-- and reviewed against. Everything below goes in through pos_ingest_ticket —
-- the same entry point the Samba sync will call — so the demo data has exactly
-- the shape real data will have, and swapping in the live feed changes nothing
-- downstream.
--
-- Ticket #70941 is a faithful copy of a printed Oso Lounge slip (Honey BBQ Wings
-- + Crispy French Fries, ₦29,000 subtotal, 7.5% VAT ₦2,175, consumption tax
-- ₦1,450, total ₦32,625, settled to Access Bank 1772083981). Its numbers are
-- what pin the tax defaults in pos_ingest_ticket.
--
-- Venues are resolved by name, and the whole thing is idempotent: the ingest RPC
-- upserts on (venue_id, ticket_no), so re-running only refreshes.
-- ============================================================================

do $$
declare
  v_oso   uuid;
  v_boom  uuid;
  v_oxy   uuid;
  v_ticket uuid;
  v_member uuid;
  v_muse   uuid;
  i int;
  v_venue uuid;
  v_when timestamptz;
  v_no int;
  -- A small, plausible menu to draw from.
  v_menu jsonb := jsonb_build_array(
    jsonb_build_object('name', 'HONEY BBQ WINGS',      'unit_price_kobo', 1850000),
    jsonb_build_object('name', 'CRISPY FRENCH FRIES',  'unit_price_kobo', 1050000),
    jsonb_build_object('name', 'GRILLED CROAKER FISH', 'unit_price_kobo', 2200000),
    jsonb_build_object('name', 'JOLLOF RICE & CHICKEN','unit_price_kobo', 1600000),
    jsonb_build_object('name', 'PEPPERED SNAILS',      'unit_price_kobo', 2500000),
    jsonb_build_object('name', 'MOET & CHANDON',       'unit_price_kobo', 18500000),
    jsonb_build_object('name', 'HENNESSY VS',          'unit_price_kobo', 12000000),
    jsonb_build_object('name', 'CHAPMAN',              'unit_price_kobo', 450000),
    jsonb_build_object('name', 'SMALL CHOPS PLATTER',  'unit_price_kobo', 1500000),
    jsonb_build_object('name', 'HEINEKEN',             'unit_price_kobo', 350000)
  );
  v_cashiers text[] := array['JOHN', 'BLESSING', 'EMEKA', 'TUNDE'];
begin
  select id into v_oso  from venues where name ilike '%oso%'    limit 1;
  select id into v_boom from venues where name ilike '%boom%'   limit 1;
  select id into v_oxy  from venues where name ilike '%oxymor%' limit 1;

  -- Trading address as printed on the slip.
  update venues set address = 'Sunset Place 141 Adetokumbo Ademola Crescent, Wuse 2, Abuja.'
    where id = v_oso and address is null;
  update venues set address = 'Wuse 2, Abuja.'
    where id in (v_boom, v_oxy) and address is null;

  -- ── The reference ticket, exactly as printed ──────────────────────────────
  if v_oso is not null then
    v_ticket := pos_ingest_ticket(
      p_venue_id => v_oso,
      p_ticket_no => '70941',
      p_occurred_at => now() - interval '2 hours',
      p_items => jsonb_build_array(
        jsonb_build_object('name', 'HONEY BBQ WINGS',     'quantity', 1, 'unit_price_kobo', 1850000),
        jsonb_build_object('name', 'CRISPY FRENCH FRIES', 'quantity', 1, 'unit_price_kobo', 1050000)
      ),
      p_cashier => 'JOHN',
      p_table_label => 'W09',
      p_change_kobo => 0,
      p_payment_method => 'Transfer',
      p_acct_no => '1772083981',
      p_bank_name => 'ACCESS BANK',
      p_source => 'demo'
    );
  end if;

  -- ── A night's worth of traffic across the venues ──────────────────────────
  v_no := 70942;
  for i in 1..27 loop
    v_venue := case (i % 3) when 0 then v_oso when 1 then v_boom else v_oxy end;
    continue when v_venue is null;
    v_when := now() - make_interval(hours => (i * 5) % 96, mins => (i * 17) % 60);

    v_ticket := pos_ingest_ticket(
      p_venue_id => v_venue,
      p_ticket_no => v_no::text,
      p_occurred_at => v_when,
      p_items => (
        -- 1–3 lines drawn deterministically from the menu.
        select jsonb_agg(jsonb_build_object(
          'name', item->>'name',
          'quantity', 1 + ((i + ord) % 2),
          'unit_price_kobo', (item->>'unit_price_kobo')::bigint
        ))
        from (
          select v_menu->(((i * 3 + s) % jsonb_array_length(v_menu))) as item, s as ord
          from generate_series(0, (i % 3)) s
        ) picks
      ),
      p_cashier => v_cashiers[1 + (i % array_length(v_cashiers, 1))],
      p_table_label => (array['W01','W05','W09','VIP2','B14','L07'])[1 + (i % 6)],
      p_change_kobo => 0,
      p_payment_method => (array['Cash','Transfer','POS Card'])[1 + (i % 3)],
      p_acct_no => '1772083981',
      p_bank_name => 'ACCESS BANK',
      p_source => 'demo'
    );
    v_no := v_no + 1;
  end loop;

  -- ── Attribute a handful, so the surface shows both programmes ─────────────
  -- Privé members: the most recent few tickets at each venue.
  for v_member in select id from members where status = 'active' order by created_at desc limit 4 loop
    update pos_tickets t
      set member_id = v_member, attributed_at = now()
      where t.id = (
        select id from pos_tickets
        where member_id is null and muse_member_id is null
        order by occurred_at desc limit 1
      );
  end loop;

  -- One standalone Muse member, proving Muse purchases log too.
  select id into v_muse from muse.members where status = 'active' limit 1;
  if v_muse is not null then
    update pos_tickets t
      set muse_member_id = v_muse, attributed_at = now()
      where t.id = (
        select id from pos_tickets
        where member_id is null and muse_member_id is null
        order by occurred_at desc limit 1
      );
  end if;
end $$;
