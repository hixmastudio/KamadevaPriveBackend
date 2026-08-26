-- ============================================================================
-- 0041 — Date of birth on the Privé member record.
--
-- Muse members have carried a date of birth since 0027; Privé members never
-- have, so the house has no way to know whose birthday it is and no basis for
-- a birthday reward. This adds the column, captures it at the door, and gives
-- the team one way to ask the only question the data exists to answer: whose
-- birthday is coming up.
--
-- The column is NULLABLE and stays that way. Twenty-six members are already
-- registered without one, and a guest at the door may simply decline — a
-- birthday reward that reaches most members is worth more than a registration
-- form that refuses to submit. register_guest backfills it on a later visit if
-- it was missing and is offered then.
--
-- Reads inherit the existing members policies: managers and above
-- (members_staff_read), plus the member's own row (members_self_read). Door
-- hosts sit below that and go through get_recognition_profile, which this
-- migration deliberately does NOT extend — a host needs to recognise a guest,
-- not read their date of birth.
-- ============================================================================

alter table members
  add column if not exists date_of_birth date;

comment on column members.date_of_birth is
  'Optional. Captured at registration for birthday recognition; 18+ is enforced '
  'in register_guest rather than here, since a CHECK cannot compare against '
  'current_date without the constraint''s meaning drifting as rows age.';

-- Plausibility only. The real age rule lives in register_guest where it can be
-- evaluated against today and reported back to the door staff.
alter table members
  drop constraint if exists members_dob_plausible;
alter table members
  add constraint members_dob_plausible
  check (date_of_birth is null or date_of_birth > date '1900-01-01');

-- Birthday lookups ask for a month and day, never a year, so index those.
-- extract() over a date is immutable, which to_char() is not — it would drag
-- lc_time into the index definition.
create index if not exists members_birthday_idx
  on members ((extract(month from date_of_birth)), (extract(day from date_of_birth)))
  where date_of_birth is not null;

-- ── Registration ────────────────────────────────────────────────────────────
-- Adding a defaulted parameter to a function creates an OVERLOAD rather than
-- replacing it, and two candidates would make the PostgREST call ambiguous.
-- Drop the old signature first.
drop function if exists register_guest(text, text, text, uuid, text, boolean, consent_channel, text);

create or replace function register_guest(
  p_phone              text,
  p_full_name          text,
  p_email              text,
  p_venue_id           uuid,
  p_instagram          text default null,
  p_consent_marketing  boolean default false,
  p_channel            consent_channel default 'door_tablet',
  p_gender             text default null,
  p_date_of_birth      date default null
)
returns members
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff uuid := current_staff_id();
  v_phone text := normalize_phone(p_phone);
  v_email text := lower(trim(coalesce(p_email, '')));
  v_gender text := nullif(lower(trim(coalesce(p_gender, ''))), '');
  v_member members%rowtype;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'a valid email address is required';
  end if;
  if v_gender is not null and v_gender not in ('female', 'male', 'other', 'undisclosed') then
    v_gender := null;
  end if;

  -- Optional, but if given it has to be real: not in the future, not absurdly
  -- old, and old enough to be in the room. Messages are written for the person
  -- holding the tablet, who has to say something to the guest.
  if p_date_of_birth is not null then
    if p_date_of_birth > current_date then
      raise exception 'date of birth cannot be in the future';
    end if;
    if p_date_of_birth <= current_date - interval '120 years' then
      raise exception 'date of birth does not look right';
    end if;
    if p_date_of_birth > current_date - interval '18 years' then
      raise exception 'members must be 18 or older';
    end if;
  end if;

  select * into v_member from members where phone = v_phone;
  if found then
    -- Already known. Take the chance to fill in a date of birth we never had;
    -- never overwrite one we did, since the record on file was captured with
    -- the same care as this one.
    if v_member.date_of_birth is null and p_date_of_birth is not null then
      update members set date_of_birth = p_date_of_birth
       where id = v_member.id
       returning * into v_member;
    end if;
    return v_member;
  end if;

  insert into members (phone, full_name, email, gender, instagram_handle, home_venue_id, date_of_birth)
  values (v_phone, trim(p_full_name), v_email, v_gender,
          nullif(trim(coalesce(p_instagram, '')), ''), p_venue_id, p_date_of_birth)
  returning * into v_member;

  insert into consents (member_id, consent_type, granted, channel, captured_by_staff_id)
  values
    (v_member.id, 'data_processing', true, p_channel, v_staff),
    (v_member.id, 'marketing_whatsapp', p_consent_marketing, p_channel, v_staff);

  insert into member_cards (member_id, kind) values (v_member.id, 'prive');

  return v_member;
end;
$$;

grant execute on function
  register_guest(text, text, text, uuid, text, boolean, consent_channel, text, date)
to authenticated;
revoke execute on function
  register_guest(text, text, text, uuid, text, boolean, consent_channel, text, date)
from public, anon;

-- ── Whose birthday is coming up ─────────────────────────────────────────────
-- The one question the column exists to answer. Deliberately reports only; it
-- grants nothing, so the house decides what a birthday is worth each time.

create or replace function member_birthdays(p_days int default 7)
returns table (
  member_id     uuid,
  member_no     text,
  full_name     text,
  phone         text,
  current_tier  tier_enum,
  date_of_birth date,
  next_birthday date,
  turning       int
)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 7), 0), 366);
begin
  -- Positive allow-check: is_manager_up() is NULL for a non-staff caller, and
  -- a negated test would let that NULL through (see 0025).
  if not coalesce(is_manager_up(), false) then
    raise exception 'venue manager or above required';
  end if;

  return query
  with dated as (
    select
      m.id, m.member_no, m.full_name, m.phone, m.current_tier, m.date_of_birth,
      extract(month from m.date_of_birth)::int as bmonth,
      extract(day   from m.date_of_birth)::int as bday
    from members m
    where m.date_of_birth is not null
      and m.status = 'active'
  ),
  candidates as (
    -- Check this year's and next year's occurrence rather than deciding which
    -- applies: it costs one extra row and removes the wrap-around arithmetic
    -- that gets December-into-January wrong.
    select d.*, y.yr
    from dated d
    cross join (
      select extract(year from current_date)::int as yr
      union all
      select extract(year from current_date)::int + 1
    ) y
  ),
  resolved as (
    select
      c.*,
      make_date(
        c.yr,
        c.bmonth,
        -- 29 February only exists in a leap year; elsewhere the birthday is
        -- kept on the 28th so these members are never silently dropped (and
        -- make_date never raises).
        case
          when c.bmonth = 2 and c.bday = 29
           and not (c.yr % 4 = 0 and (c.yr % 100 <> 0 or c.yr % 400 = 0))
          then 28
          else c.bday
        end
      ) as occurrence
    from candidates c
  )
  -- One row per member. Over a long enough window both occurrences qualify —
  -- at p_days = 366 a birthday today matches this year's and next year's — and
  -- a column called next_birthday should only ever hold the nearer one.
  select * from (
    select distinct on (r.id)
      r.id, r.member_no, r.full_name, r.phone, r.current_tier, r.date_of_birth,
      r.occurrence,
      (r.yr - extract(year from r.date_of_birth)::int) as turning
    from resolved r
    where r.occurrence >= current_date
      and r.occurrence <= current_date + v_days
    order by r.id, r.occurrence
  ) picked
  order by picked.occurrence, picked.full_name;
end;
$$;

grant execute on function member_birthdays(int) to authenticated;
revoke execute on function member_birthdays(int) from public, anon;
