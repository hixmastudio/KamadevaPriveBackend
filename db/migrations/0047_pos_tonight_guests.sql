-- ============================================================================
-- 0047 — Who is in the room tonight, on the POS screen.
--
-- The door already identifies people: a host scans a card or looks a member up,
-- and capture_visit writes the arrival. Then the bill comes, and at the POS
-- that work is thrown away — the host searches for the same person a second
-- time, from scratch, while they wait.
--
-- This closes the loop. Everyone captured at this venue tonight is offered as a
-- list, so attributing a ticket is a tap rather than a search. No new data is
-- recorded: it reads the visits the door already writes.
--
-- "Tonight" is the business date, not the calendar day. kp_business_date puts
-- the cut at 06:00 Africa/Lagos, so a guest who arrived at 1am is still in
-- tonight's room at 3am — which is the entire point on a club floor and the
-- thing a naive current_date would get wrong every single night.
--
-- Only Privé members appear, because only they can be captured: visits.member_id
-- is NOT NULL and references members, so a standalone Muse guest has nowhere to
-- be recorded. The POS search box still finds them, and giving Muse arrivals a
-- home is a larger change than this one.
-- ============================================================================

create or replace function pos_tonight_guests(p_venue_id uuid)
returns table (
  kind             text,
  subject_id       uuid,
  number           text,
  full_name        text,
  tier             tier_enum,
  arrived_at       timestamptz,
  tickets_tonight  int,
  attributed_kobo  bigint
)
language plpgsql
stable
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_business_date date := kp_business_date(now());
begin
  if current_staff_id() is null then
    raise exception 'staff session required';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  return query
  with arrivals as (
    -- visits_one_per_night_idx already makes a live visit unique per member,
    -- venue and night, so this aggregate is not deduplicating a re-scan — the
    -- door cannot create one. It is here because that index is PARTIAL on
    -- voided_at is null: a voided arrival and a later live one can coexist for
    -- the same member, and max() over the live rows takes the one that counts.
    select v.member_id,
           max(v.occurred_at) as arrived_at
      from visits v
     where v.venue_id = p_venue_id
       and v.business_date = v_business_date
       and v.voided_at is null
     group by v.member_id
  ),
  attributed as (
    -- What has already been put on their name tonight, so a host can tell a
    -- first round from a fourth.
    select t.member_id,
           count(*)::int                      as tickets_tonight,
           coalesce(sum(t.net_amount_kobo), 0) as attributed_kobo
      from transactions t
     where t.venue_id = p_venue_id
       and t.business_date = v_business_date
       and t.voided_at is null
     group by t.member_id
  )
  select
    'prive'::text,
    m.id,
    m.member_no,
    m.full_name,
    m.current_tier,
    a.arrived_at,
    coalesce(x.tickets_tonight, 0),
    coalesce(x.attributed_kobo, 0)::bigint
  from arrivals a
  join members m on m.id = a.member_id
  left join attributed x on x.member_id = a.member_id
  where m.status = 'active'
  -- Newest arrival first: the person who just walked in is the one most likely
  -- to be standing at the till.
  order by a.arrived_at desc;
end;
$$;

revoke execute on function pos_tonight_guests(uuid) from public, anon;
grant  execute on function pos_tonight_guests(uuid) to authenticated;
