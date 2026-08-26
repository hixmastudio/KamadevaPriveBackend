-- ============================================================================
-- 0062 — Members edit their own bookings: time and party size.
--
-- Supersedes the reschedule-only function from 0061, which had only just been
-- added and has never been in a deployed bundle, so there is no client in the
-- field to keep working — unlike register_guest in 0055, which taught that
-- lesson the expensive way.
--
-- THE WINDOW APPLIES TO THE TIME, AND ONLY THE TIME. Moving a table to another
-- hour re-plans the floor; adding or dropping a chair does not, and a party
-- that shrinks from six to four an hour before is information the venue wants,
-- not a change it needs protecting from. So party size stays editable for as
-- long as the booking is live, and the cut-off — now one hour — guards the time
-- alone.
--
-- CANCELLING IS NEVER BLOCKED. A member who cannot come should always be able
-- to say so; the alternative is a no-show, which is worse for the venue than a
-- late cancellation. cancel_my_reservation is untouched.
--
-- AN EVENT BOOKING CANNOT HAVE ITS TIME MOVED, and this is a judgement I have
-- made rather than one that was asked for, so it should be easy to overturn: a
-- booking with an event_id takes its time FROM the event. Letting a member move
-- it produces a booking for 9pm against an event that starts at 11pm — the
-- reservation silently detaches from the thing it was made for, and the door
-- has no way to tell which is right. Party size on an event booking stays
-- editable, which is the change people actually make. Eleven of the fifteen
-- bookings on the system today are event bookings, so this is the common path,
-- not an edge case. Say the word and it comes out.
-- ============================================================================

update program_config
   set value = '1',
       description = 'How many hours before a booking a member may still move its time. Party size stays editable, and cancelling is never blocked.',
       updated_at = now()
 where key = 'reservation_change_cutoff_hours';

drop function if exists reschedule_my_reservation(uuid, timestamptz);

create or replace function update_my_reservation(
  p_reservation_id uuid,
  p_reserved_for   timestamptz default null,
  p_party_size     int         default null
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
  if p_reserved_for is null and p_party_size is null then
    raise exception 'nothing to change';
  end if;

  select * into v_res from reservations
   where id = p_reservation_id and member_id = v_member
   for update;
  if not found then
    raise exception 'that booking is not yours';
  end if;
  if v_res.status not in ('requested', 'confirmed') then
    raise exception 'a booking that is % can no longer be changed', v_res.status;
  end if;

  -- ── Party size: editable while the booking is live ────────────────────────
  if p_party_size is not null then
    if p_party_size < 1 or p_party_size > 100 then
      raise exception 'a party is between 1 and 100 people';
    end if;
    update reservations set party_size = p_party_size, updated_at = now()
     where id = p_reservation_id;
  end if;

  -- ── Time: guarded ─────────────────────────────────────────────────────────
  if p_reserved_for is not null then
    if v_res.event_id is not null then
      raise exception
        'this booking is for an event, so its time is the event''s — change the party size, or cancel and book another night';
    end if;
    -- Against the time it currently holds: past this point the floor is planned.
    if v_res.reserved_for - now() < make_interval(hours => v_hours) then
      raise exception
        'this booking is within % hour(s) — you can still cancel, but the venue has to move it', v_hours;
    end if;
    if p_reserved_for <= now() then
      raise exception 'choose a time in the future';
    end if;
    -- And against the time being asked for, or a booking days out could be
    -- dropped ten minutes from now — the same problem from the other side.
    if p_reserved_for - now() < make_interval(hours => v_hours) then
      raise exception 'please choose a time at least % hour(s) from now', v_hours;
    end if;

    update reservations set reserved_for = p_reserved_for, status = 'confirmed', updated_at = now()
     where id = p_reservation_id;
  end if;

  select * into v_res from reservations where id = p_reservation_id;

  perform log_audit(
    p_actor_type  => 'member'::actor_type,
    p_actor_id    => v_member,
    p_action      => 'reservation.update',
    p_entity_type => 'reservations',
    p_entity_id   => p_reservation_id::text,
    p_venue_id    => v_res.venue_id,
    p_after       => jsonb_build_object('reserved_for', v_res.reserved_for,
                                        'party_size', v_res.party_size)
  );

  return v_res;
end;
$$;

revoke execute on function update_my_reservation(uuid, timestamptz, int) from public, anon;
grant  execute on function update_my_reservation(uuid, timestamptz, int) to authenticated;
