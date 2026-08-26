-- ============================================================================
-- 0032 — Daily and monthly income for the Command Centre, from POS takings.
--
-- The dashboard's revenue tile sums `transactions`, which only ever holds
-- ATTRIBUTED bills — so it under-reports actual venue income by every walk-in.
-- Now that Samba tickets land in pos_tickets, real takings are available:
-- attributed or not, voided excluded.
--
-- Computed in Postgres because "today" is a business date, not a calendar date
-- (a 1 a.m. bill belongs to the previous night — kp_business_date, cutoff 06:00
-- Africa/Lagos). The client must not re-derive that rule.
--
-- Scoped to the venues the caller is assigned to, matching the pos_tickets RLS.
-- ============================================================================

create or replace function pos_income_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
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
            and t2.business_date >= v_month_start
          group by v.name
        ) s
      ), '[]'::jsonb)
    )
    from pos_tickets t
    where t.voided_at is null
      and staff_has_venue(t.venue_id)
      and t.business_date >= v_month_start
  );
end;
$$;

revoke execute on function pos_income_summary() from public, anon;
grant  execute on function pos_income_summary() to authenticated;
