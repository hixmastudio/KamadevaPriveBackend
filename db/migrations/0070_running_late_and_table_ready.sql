-- ============================================================================
-- 0070 — Running late, and the table being ready.
--
-- Two messages that a door already exchanges verbally, and badly. A member
-- stuck in Lagos traffic either calls the venue, or says nothing and is marked
-- a no-show. A host with a table coming free either phones, or watches the door
-- hoping to catch someone. Both are the same shape: a short message between the
-- house and one member about tonight, which the notification feed now exists
-- to carry (0069).
--
-- RUNNING LATE writes to the reservation as well as to the feed. Telling the
-- venue is the point — the floor is being planned around a 9pm arrival — so it
-- moves reserved_for and leaves a note, rather than only posting a message a
-- busy host might not read. Three fixed choices, not a free time picker,
-- because the useful version of this is one tap in a car.
--
-- It is deliberately NOT bound by the one-hour change window (0062). That
-- window stops a member re-planning the floor at the last minute; this is the
-- opposite — someone telling the truth about tonight, at exactly the moment the
-- window has closed and the information is most valuable. Refusing it would
-- guarantee the no-show it exists to prevent.
--
-- TABLE READY is the host's side. Any staff can send it, because whoever is
-- working the door is who notices, and it is a message about a table rather
-- than access to a record.
-- ============================================================================

create or replace function tell_them_im_running_late(
  p_reservation_id uuid,
  p_minutes        int
)
returns reservations
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_member uuid := current_member_id();
  v_res    reservations%rowtype;
  v_venue  text;
begin
  if v_member is null then
    raise exception 'sign in to update your booking';
  end if;
  -- Three choices, so the whole thing is one tap from a car.
  if p_minutes not in (15, 30, 45) then
    raise exception 'let us know by 15, 30 or 45 minutes';
  end if;

  select * into v_res from reservations
   where id = p_reservation_id and member_id = v_member
   for update;
  if not found then
    raise exception 'that booking is not yours';
  end if;
  if v_res.status not in ('requested', 'confirmed') then
    raise exception 'that booking is no longer live';
  end if;

  select name into v_venue from venues where id = v_res.venue_id;

  update reservations
     set reserved_for = v_res.reserved_for + make_interval(mins => p_minutes),
         notes = trim(both from coalesce(notes || ' · ', '') ||
                 'Member said running ' || p_minutes || ' min late'),
         updated_at = now()
   where id = p_reservation_id
   returning * into v_res;

  -- Their own copy of what they just told us.
  perform notify_member(
    v_member,
    'account',
    'We know you are running late',
    coalesce(v_venue || ' — ', '') || 'we have moved your table to ' ||
    to_char(v_res.reserved_for at time zone 'Africa/Lagos', 'HH12:MIam') || '. Travel safely.'
  );

  perform log_audit(
    p_actor_type  => 'member'::actor_type,
    p_actor_id    => v_member,
    p_action      => 'reservation.running_late',
    p_entity_type => 'reservations',
    p_entity_id   => p_reservation_id::text,
    p_venue_id    => v_res.venue_id,
    p_after       => jsonb_build_object('minutes', p_minutes, 'reserved_for', v_res.reserved_for)
  );

  return v_res;
end;
$$;

create or replace function tell_them_the_table_is_ready(
  p_reservation_id uuid,
  p_minutes        int default 0
)
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff uuid := current_staff_id();
  v_res   reservations%rowtype;
  v_venue text;
begin
  -- Any staff working the floor. This sends a message about a table; it opens
  -- no record and reveals nothing the member does not already know.
  if v_staff is null then
    raise exception 'staff session required';
  end if;

  select * into v_res from reservations where id = p_reservation_id;
  if not found then
    raise exception 'no such booking';
  end if;
  if not staff_has_venue(v_res.venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if v_res.status not in ('requested', 'confirmed') then
    raise exception 'that booking is no longer live';
  end if;

  select name into v_venue from venues where id = v_res.venue_id;

  perform notify_member(
    v_res.member_id,
    'account',
    case when coalesce(p_minutes, 0) > 0
         then 'Your table is nearly ready'
         else 'Your table is ready' end,
    coalesce(v_venue || ' — ', '') ||
    case when coalesce(p_minutes, 0) > 0
         then 'about ' || p_minutes || ' minutes away. Come through when you are ready.'
         else 'come through whenever you are ready.' end
  );

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'reservation.table_ready',
    p_entity_type => 'reservations',
    p_entity_id   => p_reservation_id::text,
    p_venue_id    => v_res.venue_id,
    p_after       => jsonb_build_object('minutes', coalesce(p_minutes, 0))
  );
end;
$$;

revoke execute on function tell_them_im_running_late(uuid, int) from public, anon;
revoke execute on function tell_them_the_table_is_ready(uuid, int) from public, anon;
grant  execute on function tell_them_im_running_late(uuid, int) to authenticated;
grant  execute on function tell_them_the_table_is_ready(uuid, int) to authenticated;
