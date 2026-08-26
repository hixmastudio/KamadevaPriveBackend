-- ============================================================================
-- 0071 — Capture rate, measured at last.
--
-- §9.5 sets a minimum acceptable capture rate of 70% per staff member with
-- monthly recognition for the best, and §15 makes ≥80% the Month 5–6 success
-- test for the whole rollout. staff_capture_kpi_floor has sat in program_config
-- since 0001 as a number nothing ever compared anything to. The target was
-- written down, agreed, and never measured — which is the same as not having
-- one.
--
-- WHAT IS BEING MEASURED, because the honest answer is "two different things":
--
--   At the till — attributed tickets over all tickets. This is the number §15
--     actually means, and the one that decides whether the programme works:
--     spend that reaches nobody's profile is spend the tier engine never sees.
--     It is a VENUE figure, not a personal one. pos_tickets records `cashier`
--     as a Samba name string, not a staff_profiles row, so an unattributed
--     ticket cannot be laid at any particular person's door — and inventing a
--     per-person denominator out of a name field would produce a league table
--     that punishes whoever happens to be typed into Samba most often.
--
--   At the door — visits captured, per staff member. visits.captured_by_staff_id
--     is a real foreign key, so this one genuinely is personal, and it is the
--     ranking §9.5 asks for.
--
-- So: the venue is scored on the rate, and people are ranked on the count. That
-- distinction is deliberate and worth keeping — a ranking built on a number
-- nobody can be responsible for is worse than no ranking.
-- ============================================================================

create or replace function capture_rate_monthly(p_month date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
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
       where v.is_active
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function staff_capture_leaderboard(p_month date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_role  staff_role := current_staff_role();
  v_month date := date_trunc('month', coalesce(p_month, current_date))::date;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'capture reporting is for venue managers and above';
  end if;

  return coalesce((
    select jsonb_agg(x order by x.rank)
      from (
        select rank() over (order by count(*) desc) as rank,
               sp.full_name,
               sp.role::text as role,
               count(*) as arrivals_captured,
               count(*) filter (where v.capture_channel in ('qr_scan', 'card_scan')) as by_scan,
               count(distinct v.business_date) as nights_worked
          from visits v
          join staff_profiles sp on sp.id = v.captured_by_staff_id
         where v.voided_at is null
           and date_trunc('month', v.business_date)::date = v_month
         group by sp.id, sp.full_name, sp.role
      ) x
  ), '[]'::jsonb);
end;
$$;

revoke execute on function capture_rate_monthly(date) from public, anon;
revoke execute on function staff_capture_leaderboard(date) from public, anon;
grant  execute on function capture_rate_monthly(date) to authenticated;
grant  execute on function staff_capture_leaderboard(date) to authenticated;
