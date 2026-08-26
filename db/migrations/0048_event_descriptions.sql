-- ============================================================================
-- 0048 — Tell guests what an event actually is.
--
-- events carried a name, a time and a venue, and nothing else. "Ladies' Night"
-- on a date tells a member when to turn up but not what they are turning up
-- for — no dress code, no what's included, no who is playing. The member
-- Events page had nothing to show beyond a title, so that is all it showed.
--
-- description lives on BOTH tables. On events for one-off nights, and on
-- event_series so a recurring night carries its description onto every
-- occurrence it generates — otherwise a weekly series would need the text
-- retyped on each date, which is exactly the work 0045 removed.
--
-- Nullable, because plenty of nights need no explanation, and capped rather
-- than unbounded: this is a paragraph shown on a phone, not an article.
-- ============================================================================

alter table events
  add column if not exists description text
    check (description is null or length(description) <= 2000);

alter table event_series
  add column if not exists description text
    check (description is null or length(description) <= 2000);

comment on column events.description is
  'Shown to members on the Events page. Nullable — many nights need no explanation.';
comment on column event_series.description is
  'Copied onto every occurrence the series generates, so recurring nights do not
   need the text retyped per date.';

-- Adding a defaulted parameter creates an OVERLOAD rather than replacing the
-- function, and two candidates make the PostgREST call ambiguous. Drop the old
-- signatures first.
drop function if exists save_event(text, timestamptz, uuid, uuid, timestamptz, int, text, tier_enum, jsonb);
drop function if exists create_event_series(text, event_recurrence, date, time, uuid, int, date, int, int, tier_enum, text, boolean, int, text);


CREATE OR REPLACE FUNCTION public.save_event(p_name text, p_starts_at timestamp with time zone, p_venue_id uuid DEFAULT NULL::uuid, p_event_id uuid DEFAULT NULL::uuid, p_ends_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_capacity integer DEFAULT NULL::integer, p_status text DEFAULT 'published'::text, p_min_reservation_tier tier_enum DEFAULT NULL::tier_enum, p_windows jsonb DEFAULT '[]'::jsonb, p_description text DEFAULT NULL::text)
 RETURNS events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_staff uuid := current_staff_id();
  v_event events%rowtype;
  w record;
begin
  if current_staff_role() is null or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'events are managed by venue managers and above';
  end if;
  if p_venue_id is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'event name is required';
  end if;
  if p_status not in ('draft', 'published', 'cancelled') then
    raise exception 'status must be draft, published, or cancelled';
  end if;

  if p_event_id is null then
    insert into events (venue_id, name, starts_at, ends_at, capacity, status,
                        min_reservation_tier, created_by, description)
    values (p_venue_id, trim(p_name), p_starts_at, p_ends_at, p_capacity,
            p_status, p_min_reservation_tier, v_staff,
            nullif(trim(coalesce(p_description, '')), ''))
    returning * into v_event;
  else
    update events
      set venue_id = p_venue_id, name = trim(p_name), starts_at = p_starts_at,
          ends_at = p_ends_at, capacity = p_capacity, status = p_status,
          min_reservation_tier = p_min_reservation_tier,
          description = nullif(trim(coalesce(p_description, '')), '')
      where id = p_event_id
      returning * into v_event;
    if not found then
      raise exception 'event not found';
    end if;
  end if;

  delete from event_access_windows where event_id = v_event.id;
  for w in
    select (j->>'min_tier')::tier_enum as min_tier, (j->>'opens_at')::timestamptz as opens_at
    from jsonb_array_elements(coalesce(p_windows, '[]'::jsonb)) j
  loop
    insert into event_access_windows (event_id, min_tier, opens_at)
    values (v_event.id, w.min_tier, w.opens_at);
  end loop;

  perform log_audit(
    p_actor_type => 'staff'::actor_type,
    p_actor_id   => v_staff,
    p_action     => case when p_event_id is null then 'event.create' else 'event.update' end,
    p_entity_type=> 'events',
    p_entity_id  => v_event.id::text,
    p_venue_id   => p_venue_id,
    p_after      => to_jsonb(v_event)
  );

  return v_event;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_event_series(p_name text, p_recurrence event_recurrence, p_starts_on date, p_time_of_day time without time zone, p_venue_id uuid DEFAULT NULL::uuid, p_every_n integer DEFAULT 1, p_until date DEFAULT NULL::date, p_duration_minutes integer DEFAULT NULL::integer, p_capacity integer DEFAULT NULL::integer, p_min_reservation_tier tier_enum DEFAULT NULL::tier_enum, p_status text DEFAULT 'published'::text, p_announce boolean DEFAULT true, p_announce_days_before integer DEFAULT 1, p_announce_audience text DEFAULT 'all'::text, p_description text DEFAULT NULL::text)
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
    announce, announce_days_before, announce_audience, created_by, description
  ) values (
    p_venue_id, trim(p_name), p_recurrence, coalesce(p_every_n, 1), p_starts_on,
    p_time_of_day, p_duration_minutes, p_until, p_capacity, p_min_reservation_tier,
    p_status, coalesce(p_announce, true), coalesce(p_announce_days_before, 1),
    coalesce(p_announce_audience, 'all'), v_staff,
    nullif(trim(coalesce(p_description, '')), '')
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

CREATE OR REPLACE FUNCTION public.materialise_event_series(p_horizon_days integer DEFAULT 60, p_series_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  s          event_series%rowtype;
  v_horizon  date := current_date + greatest(coalesce(p_horizon_days, 60), 1);
  v_date     date;
  v_starts   timestamptz;
  v_created  int := 0;
  i          int;
begin
  for s in
    select * from event_series
     where status <> 'cancelled'
       and (p_series_id is null or id = p_series_id)
  loop
    i := 0;
    loop
      -- Always measured from the anchor, never from the previous occurrence.
      -- Stepping month by month would drift: the 31st clamps to the 28th in
      -- February and then stays on the 28th forever. From the anchor,
      -- Jan 31 + 2 months is March 31 again.
      v_date := case s.recurrence
                  when 'daily'   then s.starts_on + ((i * s.every_n) || ' days')::interval
                  when 'weekly'  then s.starts_on + ((i * s.every_n) || ' weeks')::interval
                  when 'monthly' then s.starts_on + ((i * s.every_n) || ' months')::interval
                end::date;

      exit when v_date > v_horizon;
      exit when s.until is not null and v_date > s.until;
      i := i + 1;
      exit when i > 2000;  -- backstop; a daily series cannot outrun this

      if v_date >= current_date then
        -- Compose the instant in the venue's own wall clock, so 9pm is 9pm on
        -- every occurrence.
        v_starts := (v_date + s.time_of_day) at time zone 'Africa/Lagos';

        insert into events (
          venue_id, name, starts_at, ends_at, capacity, status,
          min_reservation_tier, created_by, series_id, occurrence_date, description
        ) values (
          s.venue_id, s.name, v_starts,
          case when s.duration_minutes is null then null
               else v_starts + (s.duration_minutes || ' minutes')::interval end,
          s.capacity, s.status, s.min_reservation_tier, s.created_by, s.id, v_date,
          s.description
        )
        on conflict (series_id, occurrence_date) where series_id is not null
        do nothing;

        if found then
          v_created := v_created + 1;
        end if;
      end if;
    end loop;
  end loop;

  return v_created;
end;
$function$;


grant execute on function
  save_event(text, timestamptz, uuid, uuid, timestamptz, int, text, tier_enum, jsonb, text)
to authenticated;
revoke execute on function
  save_event(text, timestamptz, uuid, uuid, timestamptz, int, text, tier_enum, jsonb, text)
from public, anon;

grant execute on function
  create_event_series(text, event_recurrence, date, time, uuid, int, date, int, int, tier_enum, text, boolean, int, text, text)
to authenticated;
revoke execute on function
  create_event_series(text, event_recurrence, date, time, uuid, int, date, int, int, tier_enum, text, boolean, int, text, text)
from public, anon;

revoke execute on function materialise_event_series(int, uuid) from public, anon, authenticated;
