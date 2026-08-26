-- ============================================================================
-- 0051 — Let staff choose whether a series emails, not just whether it notifies.
--
-- 0049 added event_series.email_announce but nothing could set it, so every
-- series took the default. The two channels cost a reader very differently — a
-- daily night in the in-app feed is a list that scrolls, the same night in the
-- inbox is 365 emails a year — so the person setting the series up decides.
--
-- Dropping the old signature first: a defaulted parameter creates an overload
-- rather than replacing the function, and two candidates make the PostgREST
-- call ambiguous.
-- ============================================================================

drop function if exists create_event_series(text, event_recurrence, date, time, uuid, int, date, int, int, tier_enum, text, boolean, int, text, text);

CREATE OR REPLACE FUNCTION public.create_event_series(p_name text, p_recurrence event_recurrence, p_starts_on date, p_time_of_day time without time zone, p_venue_id uuid DEFAULT NULL::uuid, p_every_n integer DEFAULT 1, p_until date DEFAULT NULL::date, p_duration_minutes integer DEFAULT NULL::integer, p_capacity integer DEFAULT NULL::integer, p_min_reservation_tier tier_enum DEFAULT NULL::tier_enum, p_status text DEFAULT 'published'::text, p_announce boolean DEFAULT true, p_announce_days_before integer DEFAULT 1, p_announce_audience text DEFAULT 'all'::text, p_description text DEFAULT NULL::text, p_email_announce boolean DEFAULT true)
 RETURNS event_series
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_staff uuid := current_staff_id();
  v_series event_series%rowtype;
begin
  -- Same gate as save_event: a positive allow-list, since current_staff_role()
  -- is null for a non-staff caller and a negated test would let that through.
  if current_staff_role() is null
     or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'events are managed by venue managers and above';
  end if;
  if p_venue_id is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if p_status not in ('draft', 'published', 'cancelled') then
    raise exception 'status must be draft, published, or cancelled';
  end if;

  insert into event_series (
    venue_id, name, recurrence, every_n, starts_on, time_of_day, duration_minutes,
    until, capacity, min_reservation_tier, status,
    announce, announce_days_before, announce_audience, created_by, description,
    email_announce
  ) values (
    p_venue_id, trim(p_name), p_recurrence, coalesce(p_every_n, 1), p_starts_on,
    p_time_of_day, p_duration_minutes, p_until, p_capacity, p_min_reservation_tier,
    p_status, coalesce(p_announce, true), coalesce(p_announce_days_before, 1),
    coalesce(p_announce_audience, 'all'), v_staff,
    nullif(trim(coalesce(p_description, '')), ''),
    coalesce(p_email_announce, true)
  ) returning * into v_series;

  -- Fill the calendar straight away, so the person who just set this up can see
  -- the dates rather than waiting for tonight's job.
  perform materialise_event_series(60, v_series.id);

  perform log_audit(
    p_actor_type => 'staff'::actor_type,
    p_actor_id   => v_staff,
    p_action     => 'event_series.create',
    p_entity_type=> 'event_series',
    p_entity_id  => v_series.id::text,
    p_venue_id   => p_venue_id,
    p_after      => to_jsonb(v_series)
  );

  return v_series;
end;
$function$;

grant execute on function create_event_series(text, event_recurrence, date, time, uuid, int, date, int, int, tier_enum, text, boolean, int, text, text, boolean) to authenticated;
revoke execute on function create_event_series(text, event_recurrence, date, time, uuid, int, date, int, int, tier_enum, text, boolean, int, text, text, boolean) from public, anon;
