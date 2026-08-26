-- ─────────────────────────────────────────────────────────────────────────────
-- 0077 — Oxymor Concepts is not a floor
--
-- It has been sitting in the venue switcher and on the Command Centre as though
-- it were a room you could stand in. It is the events arm: no door, no host, no
-- shift, and — checked before writing this — nobody assigned to it.
--
-- `is_active` was the wrong flag to reach for; Oxymor genuinely is an active
-- part of the group. What it lacks is a floor. So that is what the column says,
-- and 0058's accepts_reservations / accepts_orders keep saying their own
-- narrower things about booking and ordering.
--
-- What this does NOT do is delete anything. Oxymor holds nine tickets and three
-- visits, and those stay exactly where they are, readable on Transactions and
-- against the members they belong to. It stops being a place to work; it does
-- not stop having happened.
-- ─────────────────────────────────────────────────────────────────────────────

alter table venues add column if not exists has_floor boolean not null default true;

comment on column venues.has_floor is
  'A room with a door, where a shift is worked and a terminal stands. False for arms of the group that trade without a floor — they keep their history but are not somewhere staff sign in to.';

update venues set has_floor = false where slug = 'oxymor-concepts' or name = 'Oxymor Concepts';

CREATE OR REPLACE FUNCTION public.capture_rate_monthly(p_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_role  staff_role := current_staff_role();
  v_month date := date_trunc('month', coalesce(p_month, current_date))::date;
  v_floor int := coalesce(config_int('staff_capture_kpi_floor'), 70);
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'capture reporting is for venue managers and above';
  end if;

  return jsonb_build_object(
    'month', v_month,
    'floor_percent', v_floor,
    'venues', coalesce((
      select jsonb_agg(jsonb_build_object(
               'venue', v.name,
               'tickets', t.tickets,
               'attributed', t.attributed,
               -- Guarded: a venue with no trade divides by zero otherwise, and
               -- reporting 0% for a night nobody opened is a false alarm.
               'percent', case when t.tickets = 0 then null
                          else round(100.0 * t.attributed / t.tickets, 1) end,
               'meets_floor', case when t.tickets = 0 then null
                              else (100.0 * t.attributed / t.tickets) >= v_floor end
             ) order by v.name)
        from venues v
        join lateral (
          select count(*) as tickets, count(member_id) as attributed
            from pos_tickets pt
           where pt.venue_id = v.id
             and pt.voided_at is null
             and date_trunc('month', pt.business_date)::date = v_month
        ) t on true
       -- Only floors. A venue with no room has no door team to hold
       -- to a capture rate, so scoring it would be scoring nobody.
       where v.is_active and v.has_floor
    ), '[]'::jsonb)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.pos_income_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_role staff_role := current_staff_role();
  v_today date := kp_business_date(now());
  v_month_start date := date_trunc('month', kp_business_date(now()))::date;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'not authorized';
  end if;

  return (
    select jsonb_build_object(
      'business_date', v_today,
      'today_kobo',    coalesce(sum(total_kobo) filter (where business_date = v_today), 0),
      'today_tickets', coalesce(count(*) filter (where business_date = v_today), 0),
      'month_kobo',    coalesce(sum(total_kobo) filter (where business_date >= v_month_start), 0),
      'month_tickets', coalesce(count(*) filter (where business_date >= v_month_start), 0),
      'today_attributed', coalesce(count(*) filter (
        where business_date = v_today and (member_id is not null or muse_member_id is not null)), 0),
      'by_venue', coalesce((
        select jsonb_agg(x order by x->>'venue')
        from (
          select jsonb_build_object(
            'venue', v.name,
            'today_kobo', coalesce(sum(t2.total_kobo) filter (where t2.business_date = v_today), 0),
            'month_kobo', coalesce(sum(t2.total_kobo) filter (where t2.business_date >= v_month_start), 0)
          ) as x
          from pos_tickets t2
          join venues v on v.id = t2.venue_id
          where t2.voided_at is null
            and staff_has_venue(t2.venue_id)
            and v.has_floor
            and t2.business_date >= v_month_start
          group by v.name
        ) s
      ), '[]'::jsonb)
    )
    from pos_tickets t
    -- The same restriction as the breakdown below it, and for the sake of the
    -- reader rather than the rule: a by-venue list that does not add up to the
    -- figure above it reads as a bug, and gets reported as one.
    join venues fv on fv.id = t.venue_id and fv.has_floor
    where t.voided_at is null
      and staff_has_venue(t.venue_id)
      and t.business_date >= v_month_start
  );
end;
$function$;
