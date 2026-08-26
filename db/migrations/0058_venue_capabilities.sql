-- ============================================================================
-- 0058 — Oxymor Concepts is not a room you can book a table in.
--
-- It appeared in the member portal's reservation picker and in click & collect
-- beside Oso and Boom Boom Room, because both lists ask only whether a venue is
-- active. Oxymor is the group's events arm (§12) — it programmes nights at the
-- other venues. It has no tables to reserve and no kitchen to collect from, and
-- the data agrees: no menu items, no reservations, no orders have ever been
-- attached to it. A member choosing it would have been offered an empty menu
-- and a booking nobody could honour.
--
-- Done as capabilities on the venue rather than by excluding a slug in the
-- frontend, or by testing type = 'events'. Both of those hide the rule inside
-- code that has to be found and redeployed to change. Cleanbite Kitchen will
-- take orders and not bookings; a future pop-up may take neither. Those are
-- operational facts about a venue, so they belong on the venue — and the same
-- two columns then answer the question everywhere it is asked.
--
-- Defaults are true so every existing venue keeps behaving exactly as it does
-- today, and only the events arm is switched off.
-- ============================================================================

alter table venues
  add column if not exists accepts_reservations boolean not null default true,
  add column if not exists accepts_orders       boolean not null default true;

comment on column venues.accepts_reservations is
  'Whether a member can book a table here. False for the events arm, which
   programmes nights at other venues rather than seating anyone itself.';
comment on column venues.accepts_orders is
  'Whether a member can order ahead for collection here.';

update venues
   set accepts_reservations = false,
       accepts_orders       = false
 where type = 'events';

-- ── Enforced, not merely hidden ─────────────────────────────────────────────
-- Removing a venue from a dropdown is a suggestion. These make it a rule, so a
-- stale tablet, a cached bundle or a direct call cannot book a table at an
-- events company.

create or replace function assert_venue_accepts(p_venue_id uuid, p_capability text)
returns void
language plpgsql
stable
set search_path to 'public', 'pg_temp'
as $$
declare
  v venues%rowtype;
begin
  select * into v from venues where id = p_venue_id;
  if not found then
    raise exception 'no such venue';
  end if;
  if p_capability = 'reservations' and not v.accepts_reservations then
    raise exception '% does not take table reservations', v.name;
  end if;
  if p_capability = 'orders' and not v.accepts_orders then
    raise exception '% does not take orders for collection', v.name;
  end if;
end;
$$;

-- ── The two entry points now enforce it ─────────────────────────────────────
-- Recreated from their live definitions with a single capability check added at
-- the top of each body, rather than rewritten from memory — the same discipline
-- 0055 needed after a hand-written register_guest quietly dropped card issuance.

CREATE OR REPLACE FUNCTION public.create_reservation(p_venue_id uuid, p_reserved_for timestamp with time zone, p_party_size integer, p_channel reservation_channel, p_member_id uuid DEFAULT NULL::uuid, p_guest_phone text DEFAULT NULL::text, p_guest_name text DEFAULT NULL::text, p_guest_email text DEFAULT NULL::text, p_event_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS reservations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_staff uuid := current_staff_id();
  v_member members%rowtype;
  v_reservation reservations%rowtype;
begin
  perform assert_venue_accepts(p_venue_id, 'reservations');
  if p_member_id is not null then
    select * into v_member from members where id = p_member_id and status = 'active';
    if not found then
      raise exception 'member not found';
    end if;
  elsif current_member_id() is not null then
    select * into v_member from members where id = current_member_id();
  elsif p_guest_phone is not null and p_guest_name is not null then
    if v_staff is null then
      raise exception 'staff session required for inline guest registration';
    end if;
    v_member := register_guest(p_guest_phone, p_guest_name, p_guest_email, p_venue_id,
                               false, 'staff_entry');
  else
    raise exception 'reservations require a registered member (the reservation rule)';
  end if;

  if v_staff is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  if p_event_id is not null
     and not event_booking_open_for(p_event_id, v_member.current_tier) then
    raise exception 'booking for this event has not opened for this member''s tier yet';
  end if;

  insert into reservations
    (member_id, venue_id, event_id, reserved_for, party_size, status, channel,
     created_by_staff_id, notes)
  values
    (v_member.id, p_venue_id, p_event_id, p_reserved_for, p_party_size,
     case when p_channel = 'staff' then 'confirmed'::reservation_status
          else 'requested'::reservation_status end,
     p_channel, v_staff, p_notes)
  returning * into v_reservation;

  return v_reservation;
end;
$function$;

CREATE OR REPLACE FUNCTION public.place_collect_order(p_venue_id uuid, p_items jsonb, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_member_id uuid := current_member_id();
  v_order_id uuid;
  v_line jsonb;
  v_item catalog_items%rowtype;
  v_count int := 0;
begin
  perform assert_venue_accepts(p_venue_id, 'orders');
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
$function$;

