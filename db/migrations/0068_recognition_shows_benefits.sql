-- ============================================================================
-- 0068 — The door sees what the member is owed, not just who they are.
--
-- Recognition returned a name, a tier and a visit count. Everything the host or
-- cashier then had to DO with that — apply the automatic discount, know it is
-- someone's birthday, remember which tier gets priority entry — lived in their
-- head or in a document nobody reads at 11pm on a Friday.
--
-- Two facts are added here because only the database knows them:
--
--   auto_discount_percent — §6 makes the automatic discount venue-specific and
--     editable by the Head of Sales & Loyalty. The till must be TOLD the number
--     rather than assuming 5 for Gold and 8 for Black, because those are
--     designations that can be changed, ended, or set per venue.
--
--   birthday_today — §8 promises birthday recognition at every tier. A host
--     cannot deliver that from memory, and the moment it matters is the moment
--     the person walks in. Compared in Lagos time, not UTC, or it lands a day
--     early for anyone arriving after midnight.
--
-- The tier's standing entitlements — priority entry, queue bypass, a table held
-- back, complimentary experiences — are NOT returned here. They are fixed copy
-- from the benefits matrix, identical for every member of a tier, and belong in
-- the client next to the Muse list rather than being re-fetched per scan.
-- ============================================================================

-- The venue is a PARAMETER, not a guess. The first cut derived it from the
-- caller's staff_venue_assignments row, which is wrong twice over: the HoSL and
-- founders hold no assignment at all, so it silently found nothing and reported
-- a Black member as having no discount; and a manager covering two venues would
-- have got whichever row came back first. The terminal always knows where it is
-- standing, so it passes it.
--
-- Added as a trailing optional argument, and the old signature dropped, because
-- adding a parameter creates an overload rather than replacing the function and
-- PostgREST then refuses the call as ambiguous.

drop function if exists get_recognition_profile(text, text, uuid);

CREATE OR REPLACE FUNCTION public.get_recognition_profile(p_qr_token text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_member_id uuid DEFAULT NULL::uuid, p_venue_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_staff        uuid := current_staff_id();
  v_member       members%rowtype;
  v_visits_month int;
  v_reservation  reservations%rowtype;
  v_muse         muse.members%rowtype;
  v_muse_month   int;
  v_benefits     jsonb;
  v_auto_pct     numeric;
  v_birthday     boolean;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;

  if p_qr_token is not null then
    select m.* into v_member
      from member_cards c join members m on m.id = c.member_id
     where c.qr_token = p_qr_token and c.status = 'active' and m.status = 'active';
  elsif p_member_id is not null then
    select * into v_member from members where id = p_member_id and status = 'active';
  elsif p_phone is not null then
    select * into v_member from members where phone = normalize_phone(p_phone) and status = 'active';
  end if;

  -- No Privé card matched. Before giving up, try the Muse register — this is
  -- the branch whose absence made a valid Muse card read as unrecognised.
  if v_member.id is null then
    if p_qr_token is not null then
      select mm.* into v_muse
        from muse.cards c join muse.members mm on mm.id = c.muse_member_id
       where c.qr_token = p_qr_token and c.status = 'active' and mm.status = 'active';
    elsif p_phone is not null then
      select * into v_muse from muse.members
       where phone = normalize_phone(p_phone) and status = 'active';
    end if;

    if v_muse.id is null then
      return null;
    end if;

    select count(*)::int into v_muse_month
      from muse.arrivals
     where muse_member_id = v_muse.id and occurred_at > date_trunc('month', now());

    select coalesce(jsonb_agg(distinct bg.type::text), '[]'::jsonb) into v_benefits
      from muse.memberships ms
      join muse.benefit_grants bg on bg.membership_id = ms.id
     where ms.member_id = v_muse.id and ms.status = 'active';

    return jsonb_build_object(
      'kind', 'muse',
      'muse_member_id', v_muse.id,
      'member_no', v_muse.muse_no,
      'full_name', v_muse.full_name,
      -- Explicitly null, not absent. A Muse holds no Privé tier and the door
      -- should show nothing where a tier badge would otherwise go.
      'tier', null,
      'visits_this_month', v_muse_month,
      'reservation_tonight', null,
      -- §7.4: priority entry across all venues, at all times.
      'priority_entry', true,
      'benefits_seen', v_benefits
    );
  end if;

  select count(*)::int into v_visits_month from visits
   where member_id = v_member.id and voided_at is null
     and occurred_at > date_trunc('month', now());

  select * into v_reservation from reservations
   where member_id = v_member.id and status in ('requested', 'confirmed')
     and kp_business_date(reserved_for) = kp_business_date(now())
   order by reserved_for limit 1;

  -- What the cashier has to apply, looked up rather than remembered. §6 makes
  -- the automatic discount venue-specific and editable by the Head of Sales &
  -- Loyalty, so the till must be told the number rather than assuming 5 or 8.
  select coalesce(d.percent, 0) into v_auto_pct
    from discount_designations d
   where d.tier = v_member.current_tier
     -- Passed in by the terminal, which always knows where it is standing.
     -- Deriving it from the staff assignment was wrong twice over: the HoSL and
     -- founders hold no assignment at all, and a manager covering two venues
     -- would have got whichever row came back first.
     and (d.venue_id is null or p_venue_id is null or d.venue_id = p_venue_id)
     and d.active_from <= now()
     and (d.active_to is null or d.active_to > now())
   order by d.venue_id nulls last
   limit 1;

  -- §8 promises birthday recognition at every tier. A host cannot deliver it
  -- from memory, and the one moment it matters is the moment they arrive.
  v_birthday := v_member.date_of_birth is not null
    and to_char(v_member.date_of_birth, 'MM-DD')
        = to_char((now() at time zone 'Africa/Lagos')::date, 'MM-DD');

  return jsonb_build_object(
    'kind', 'prive',
    'member_id', v_member.id,
    'member_no', v_member.member_no,
    'full_name', v_member.full_name,
    'tier', v_member.current_tier,
    'visits_this_month', v_visits_month,
    'reservation_tonight', case when v_reservation.id is null then null
      else jsonb_build_object('id', v_reservation.id, 'party_size', v_reservation.party_size,
                              'reserved_for', v_reservation.reserved_for) end,
    'priority_entry', v_member.current_tier in ('silver', 'gold', 'black'),
    'auto_discount_percent', coalesce(v_auto_pct, 0),
    'birthday_today', v_birthday
  );
end;
$function$
;
