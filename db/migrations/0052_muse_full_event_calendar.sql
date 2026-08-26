-- ============================================================================
-- 0052 — Muse sees the whole calendar, and the Muse calendar can be written to.
--
-- Two problems, one of which was invisible.
--
-- The visible one: a Muse member's Events page read muse.event_calendar and
-- nothing else, so the house's own nights — the five published events sitting
-- in public.events right now — never appeared to her. She was already being
-- NOTIFIED about them (create_event_series defaults announce_audience to 'all',
-- and 0040's RLS lets a Muse member read 'all' notices), so the effect was a
-- notification about an evening she then could not find anywhere in her portal.
--
-- The invisible one: muse.event_calendar has existed since 0006 and has never
-- had a single row, because nothing can write to it. No RPC, no UI, no seed.
-- The Muse nights page could only ever have rendered its empty state. So this
-- migration does not "also" add authoring — authoring is the missing half.
--
-- Direction matters and is deliberate. Muse sees house events; Privé members do
-- NOT see Muse nights. The governance document puts Muse on a least-visibility
-- model, and a Muse night is an invitation, not a listing. Nothing here touches
-- what a Privé member reads.
-- ============================================================================

-- A night deserves the same sentence of explanation an event got in 0048.
alter table muse.event_calendar
  add column if not exists description text;

comment on column muse.event_calendar.description is
  'What the night is, in the member''s language. Optional.';

-- Stops a double-submit becoming two identical nights. Venue is folded into the
-- key through a sentinel rather than left NULL, because NULLs are never equal to
-- each other and a unique index over them would not constrain anything at all —
-- exactly the case (a night with no venue set) most likely to be double-entered.
create unique index if not exists muse_event_calendar_night_label_idx
  on muse.event_calendar (
    night,
    lower(label),
    coalesce(venue_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );

-- ── What a Muse member sees ─────────────────────────────────────────────────

create or replace function muse_upcoming_events()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id uuid := current_muse_member_id();
begin
  if v_id is null then
    return null;  -- not a Muse auth user; same contract as get_my_muse_status
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.night, x.starts_at nulls last, x.title)
    from (
      -- Muse-exclusive nights. A night may or may not be pinned to a real
      -- events row; when it is, we borrow that row's clock time and venue so
      -- she is not told a different hour to everyone else.
      select 'muse'::text   as kind,
             ec.id          as id,
             ec.label       as title,
             ec.night       as night,
             ev.starts_at   as starts_at,
             coalesce(ec.description, ev.description) as description,
             ven.name       as venue_name,
             ec.benefits    as benefits
        from muse.event_calendar ec
        left join events ev  on ev.id  = ec.event_id
        left join venues ven on ven.id = coalesce(ec.venue_id, ev.venue_id)
       where ec.night >= current_date

      union all

      -- The house calendar, minus anything already listed above as a Muse
      -- night. Without this NOT EXISTS a night pinned to an event appears
      -- twice — once with its benefits and once without — and the second copy
      -- reads as a correction of the first.
      select 'house'::text,
             ev.id,
             ev.name,
             (ev.starts_at at time zone 'Africa/Lagos')::date,
             ev.starts_at,
             ev.description,
             ven.name,
             '[]'::jsonb
        from events ev
        left join venues ven on ven.id = ev.venue_id
       where ev.status = 'published'
         -- Same horizon the Privé Events page uses, on purpose: the two
         -- audiences should not be shown different versions of tonight.
         and ev.starts_at >= now()
         and not exists (
           select 1
             from muse.event_calendar ec
            where ec.event_id = ev.id
              and ec.night >= current_date
         )
    ) x
  ), '[]'::jsonb);
end;
$$;

comment on function muse_upcoming_events() is
  'Everything a Muse member is invited to: her own circle''s nights and the
   house calendar, merged and deduplicated. NULL when the caller is not a Muse
   member.';

-- ── Authoring a Muse night ──────────────────────────────────────────────────

create or replace function muse_add_night(
  p_label       text,
  p_night       date,
  p_venue_id    uuid    default null,
  p_benefits    jsonb   default '["cocktail_50"]'::jsonb,
  p_event_id    uuid    default null,
  p_description text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_role  text := current_staff_role();
  v_row   muse.event_calendar%rowtype;
begin
  -- Positive allow-check, not a negated one: current_staff_role() is NULL for
  -- a non-staff caller and `not in (...)` is NULL — never true — so a negated
  -- guard would wave every member straight through.
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'the Muse calendar is kept by venue managers and above';
  end if;
  if p_venue_id is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if p_label is null or length(trim(p_label)) < 2 then
    raise exception 'give the night a name';
  end if;
  if p_night is null or p_night < current_date then
    raise exception 'a night cannot be put in the past';
  end if;
  if p_benefits is null
     or jsonb_typeof(p_benefits) <> 'array'
     or jsonb_array_length(p_benefits) = 0 then
    raise exception 'choose at least one benefit for the night';
  end if;

  -- Benefits are stored as free jsonb by 0006, so nothing at the column level
  -- stops a typo becoming a badge that renders as raw text in her portal.
  perform 1
     from jsonb_array_elements_text(p_benefits) b
    where b not in (select unnest(enum_range(null::muse_benefit_type))::text);
  if found then
    raise exception 'that is not a benefit the house offers: %', p_benefits;
  end if;

  if p_event_id is not null
     and not exists (select 1 from events where id = p_event_id) then
    raise exception 'no such event to pin this night to';
  end if;

  begin
    insert into muse.event_calendar (event_id, venue_id, night, label, benefits,
                                     description, created_by)
    values (p_event_id, p_venue_id, p_night, trim(p_label), p_benefits,
            nullif(trim(coalesce(p_description, '')), ''), v_staff)
    returning * into v_row;
  exception when unique_violation then
    raise exception 'that night is already on the Muse calendar';
  end;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'muse.night.add',
    p_entity_type => 'muse_event_calendar',
    p_entity_id   => v_row.id::text,
    p_venue_id    => p_venue_id,
    p_after       => to_jsonb(v_row)
  );

  return to_jsonb(v_row);
end;
$$;

create or replace function muse_remove_night(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_role  text := current_staff_role();
  v_row   muse.event_calendar%rowtype;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'the Muse calendar is kept by venue managers and above';
  end if;

  select * into v_row from muse.event_calendar where id = p_id;
  if not found then
    raise exception 'no such night';
  end if;
  if v_row.venue_id is not null and not staff_has_venue(v_row.venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  -- A benefit already granted against this night is a record of something that
  -- actually happened to a person, and must outlive a tidy-up of the calendar.
  if exists (select 1 from muse.benefit_grants where event_id = v_row.event_id
                                                and v_row.event_id is not null) then
    raise exception 'benefits were already granted on this night — it stays on the record';
  end if;

  delete from muse.event_calendar where id = p_id;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'muse.night.remove',
    p_entity_type => 'muse_event_calendar',
    p_entity_id   => p_id::text,
    p_venue_id    => v_row.venue_id,
    p_before      => to_jsonb(v_row)
  );
end;
$$;

-- ── What the staff desk sees ────────────────────────────────────────────────

create or replace function muse_list_nights()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_role text := current_staff_role();
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'the Muse calendar is kept by venue managers and above';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',          ec.id,
             'label',       ec.label,
             'night',       ec.night,
             'description', ec.description,
             'benefits',    ec.benefits,
             'venue_name',  ven.name,
             'event_name',  ev.name
           ) order by ec.night desc)
      from muse.event_calendar ec
      left join venues ven on ven.id = ec.venue_id
      left join events ev  on ev.id  = ec.event_id
     -- A short tail of past nights, so a mistake made yesterday is still
     -- visible to whoever has to correct it.
     where ec.night >= current_date - 30
  ), '[]'::jsonb);
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
-- Each function gates itself on the caller's own identity, so `authenticated`
-- is the right grant; anon has no business in any of them.

revoke execute on function muse_upcoming_events()                              from public, anon;
revoke execute on function muse_add_night(text, date, uuid, jsonb, uuid, text)  from public, anon;
revoke execute on function muse_remove_night(uuid)                             from public, anon;
revoke execute on function muse_list_nights()                                  from public, anon;

grant  execute on function muse_upcoming_events()                              to authenticated;
grant  execute on function muse_add_night(text, date, uuid, jsonb, uuid, text)  to authenticated;
grant  execute on function muse_remove_night(uuid)                             to authenticated;
grant  execute on function muse_list_nights()                                  to authenticated;
