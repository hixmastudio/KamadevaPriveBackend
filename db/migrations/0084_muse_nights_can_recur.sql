-- ─────────────────────────────────────────────────────────────────────────────
-- 0084 — a Muse night can recur
--
-- Privé nights have recurred since event_series was built: pick weekly, every
-- two weeks, monthly, and materialise_event_series lays the occurrences down to
-- a rolling horizon. A Muse night was a single row typed one date at a time,
-- so a standing Thursday had to be entered again every Thursday, for ever, by
-- hand.
--
-- Built on the engine that already exists rather than beside it. A second
-- recurrence implementation would be a second place for the month-end drift
-- bug to be fixed — materialise measures every occurrence from the anchor
-- precisely so that Jan 31 plus two months is March 31 and not February 28
-- for ever after, and that reasoning should not have to be rediscovered for
-- Muse.
--
-- So a recurring Muse night IS an event series, marked as one by carrying the
-- benefits it grants. Each occurrence writes an events row as before, and a
-- muse.event_calendar row pinned to it — pinned rather than freestanding so she
-- reads the same hour and venue as everybody else.
-- ─────────────────────────────────────────────────────────────────────────────

-- Non-null marks the series as a Muse night series and says what the night
-- gives her. Nullable, so every existing series is unaffected and continues to
-- generate ordinary Privé events.
alter table event_series add column if not exists muse_benefits jsonb;

comment on column event_series.muse_benefits is
  'When set, every occurrence of this series is also a Muse night carrying these benefits. Null for an ordinary Privé series.';

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
  v_event    uuid;
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

        -- A Muse series carries its benefits on the series row, and every
        -- occurrence becomes a night on her calendar pinned to the events row
        -- just written. Pinned rather than freestanding so she is told the same
        -- hour and venue as everyone else — muse_upcoming_events borrows the
        -- clock from the event when one is attached.
        --
        -- Looked up rather than RETURNINGed, because the insert above is
        -- ON CONFLICT DO NOTHING and returns nothing on the second pass. The
        -- NOT EXISTS makes this idempotent for the same reason the event insert
        -- is: materialise runs repeatedly as the horizon rolls forward.
        if s.muse_benefits is not null then
          select id into v_event
            from events
           where series_id = s.id and occurrence_date = v_date;

          insert into muse.event_calendar
            (event_id, venue_id, night, label, benefits, created_by, description)
          select v_event, s.venue_id, v_date, s.name, s.muse_benefits, s.created_by, s.description
           where v_event is not null
             and not exists (select 1 from muse.event_calendar mc where mc.event_id = v_event);
        end if;
      end if;
    end loop;
  end loop;

  return v_created;
end;
$function$;

-- ── Setting a standing night ────────────────────────────────────────────────
-- Same authority as muse_add_night, which this is the repeating form of:
-- venue managers and above keep the calendar. The benefits validation is the
-- same too, because a night with no benefit is not a Muse night.
create or replace function muse_add_night_series(
  p_label text,
  p_recurrence event_recurrence,
  p_starts_on date,
  p_time_of_day time,
  p_venue_id uuid,
  p_benefits jsonb,
  p_every_n int default 1,
  p_until date default null,
  p_description text default null
)
returns jsonb
language plpgsql
volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := current_staff_role();
  v_staff uuid := current_staff_id();
  v_series uuid;
  v_made int;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'the Muse calendar is kept by venue managers and above';
  end if;
  if p_venue_id is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if p_label is null or length(trim(p_label)) < 2 then
    raise exception 'give the night a name';
  end if;
  if p_starts_on is null or p_starts_on < current_date then
    raise exception 'a night cannot be put in the past';
  end if;
  if p_benefits is null
     or jsonb_typeof(p_benefits) <> 'array'
     or jsonb_array_length(p_benefits) = 0 then
    raise exception 'choose at least one benefit for the night';
  end if;
  if p_until is not null and p_until < p_starts_on then
    raise exception 'the end date is before the first night';
  end if;

  insert into event_series (
    name, recurrence, every_n, starts_on, time_of_day, until, venue_id,
    status, announce, announce_days_before, announce_audience, email_announce,
    description, created_by, muse_benefits
  ) values (
    trim(p_label), p_recurrence, greatest(coalesce(p_every_n, 1), 1),
    p_starts_on, coalesce(p_time_of_day, time '22:00'), p_until, p_venue_id,
    'published', true, 3,
    -- Hers, and announced as hers: announce_due_events emails a 'muse'
    -- audience to the circle and to nobody else (0073).
    'muse', true,
    nullif(trim(coalesce(p_description, '')), ''), v_staff, p_benefits
  )
  returning id into v_series;

  -- Lay down the occurrences now, so the calendar is populated before anyone
  -- looks rather than at the next scheduled run.
  v_made := materialise_event_series(180, v_series);

  perform log_audit('staff', auth.uid(), 'muse.night_series.add',
                    'event_series', v_series::text, null, null,
                    jsonb_build_object('label', trim(p_label), 'recurrence', p_recurrence::text));

  return jsonb_build_object(
    'series_id', v_series,
    'nights_created', v_made,
    'detail', v_made || ' night(s) placed on the calendar, and more as the horizon rolls forward.');
end;
$$;

revoke execute on function muse_add_night_series(text, event_recurrence, date, time, uuid, jsonb, int, date, text) from public, anon;
grant  execute on function muse_add_night_series(text, event_recurrence, date, time, uuid, jsonb, int, date, text) to authenticated;

-- ── Stopping one ────────────────────────────────────────────────────────────
-- A standing night nobody can stop is a trap. Cancelling the series stops
-- future occurrences being laid down; the nights already on the calendar are
-- removed from today forward, and past ones are left alone because they
-- happened.
create or replace function muse_remove_night_series(p_series_id uuid)
returns jsonb
language plpgsql
volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := current_staff_role();
  v_s event_series%rowtype;
  v_removed int;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'the Muse calendar is kept by venue managers and above';
  end if;

  select * into v_s from event_series where id = p_series_id;
  if not found or v_s.muse_benefits is null then
    raise exception 'no such Muse night series';
  end if;
  if v_s.venue_id is not null and not staff_has_venue(v_s.venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  update event_series set status = 'cancelled', updated_at = now() where id = p_series_id;

  delete from muse.event_calendar mc
   where mc.night >= current_date
     and mc.event_id in (select id from events where series_id = p_series_id);
  get diagnostics v_removed = row_count;

  update events set status = 'cancelled'
   where series_id = p_series_id and starts_at >= now();

  perform log_audit('staff', auth.uid(), 'muse.night_series.remove',
                    'event_series', p_series_id::text, null, null,
                    jsonb_build_object('label', v_s.name, 'nights_removed', v_removed));

  return jsonb_build_object('series_id', p_series_id, 'nights_removed', v_removed,
    'detail', v_removed || ' upcoming night(s) taken off the calendar. Nights already past are untouched.');
end;
$$;

revoke execute on function muse_remove_night_series(uuid) from public, anon;
grant  execute on function muse_remove_night_series(uuid) to authenticated;
