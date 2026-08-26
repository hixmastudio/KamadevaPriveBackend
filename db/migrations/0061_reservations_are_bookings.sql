-- ============================================================================
-- 0061 — A reservation is a booking, and it can be moved until it is close.
--
-- Two changes a member actually feels.
--
-- FIRST, it is a booking rather than an application. create_reservation
-- confirmed staff-entered bookings and left everything from the portal sitting
-- at 'requested' — so a member who chose a venue, a night and a time was told
-- to wait for an answer that nothing in the system was going to send. The house
-- keeps every power it had: staff can still move, cancel or mark a no-show. The
-- default answer is simply yes.
--
-- SECOND, a member can move the time themselves, up to a point. Plans change,
-- and the alternative — cancel and rebook — loses the booking to whoever takes
-- the slot in between. The cut-off exists because a table held for 9pm stops
-- being reschedulable at some hour before it: the floor is planned, the covers
-- are counted, and past that point moving it is a conversation with the venue
-- rather than a tap in an app.
--
-- The window is configuration, not a constant, because the right number is an
-- operational judgement the house will want to change without a deploy — and it
-- may well differ once Cleanbite and Noh-Ra open.
-- ============================================================================

insert into program_config (key, value, description)
values ('reservation_change_cutoff_hours', '4',
        'How many hours before a reservation a member may still move it themselves. Inside this window they must speak to the venue.')
on conflict (key) do nothing;

-- Recreated from the live definition with only the status expression changed.

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
     -- A booking, not an application. A member who picks a night and a
     -- time in the portal has made a reservation; the house can still move
     -- or cancel it, but the default answer is yes.
     'confirmed'::reservation_status,
     p_channel, v_staff, p_notes)
  returning * into v_reservation;

  return v_reservation;
end;
$function$
;

-- ── Moving a booking ────────────────────────────────────────────────────────

create or replace function reschedule_my_reservation(
  p_reservation_id uuid,
  p_reserved_for   timestamptz
)
returns reservations
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_member uuid := current_member_id();
  v_res    reservations%rowtype;
  v_hours  int  := config_int('reservation_change_cutoff_hours');
begin
  if v_member is null then
    raise exception 'sign in to change a booking';
  end if;

  select * into v_res from reservations
   where id = p_reservation_id and member_id = v_member
   for update;
  if not found then
    raise exception 'that booking is not yours';
  end if;
  if v_res.status not in ('requested', 'confirmed') then
    raise exception 'a booking that is % cannot be moved', v_res.status;
  end if;

  -- Measured against the CURRENT time of the booking, not the new one: the
  -- question is whether tonight's floor has already been planned around it.
  if v_res.reserved_for - now() < make_interval(hours => v_hours) then
    raise exception
      'this booking is within % hours — please call the venue to move it', v_hours;
  end if;
  if p_reserved_for <= now() then
    raise exception 'choose a time in the future';
  end if;
  -- The new time must also sit outside the window, or a member could move a
  -- booking to twenty minutes away and strand the floor with it.
  if p_reserved_for - now() < make_interval(hours => v_hours) then
    raise exception 'please choose a time at least % hours from now', v_hours;
  end if;

  update reservations
     set reserved_for = p_reserved_for,
         -- Moving it re-opens the house's acceptance rather than assuming it.
         status = 'confirmed',
         updated_at = now()
   where id = p_reservation_id
   returning * into v_res;

  perform log_audit(
    p_actor_type  => 'member'::actor_type,
    p_actor_id    => v_member,
    p_action      => 'reservation.reschedule',
    p_entity_type => 'reservations',
    p_entity_id   => p_reservation_id::text,
    p_venue_id    => v_res.venue_id,
    p_after       => jsonb_build_object('reserved_for', p_reserved_for)
  );

  return v_res;
end;
$$;

revoke execute on function reschedule_my_reservation(uuid, timestamptz) from public, anon;
grant  execute on function reschedule_my_reservation(uuid, timestamptz) to authenticated;

comment on function reschedule_my_reservation(uuid, timestamptz) is
  'Lets a member move their own booking, until reservation_change_cutoff_hours
   before it. Inside that window the floor is already planned around it and the
   change is a conversation with the venue.';
