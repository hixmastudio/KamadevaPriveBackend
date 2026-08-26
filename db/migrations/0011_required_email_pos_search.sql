-- ============================================================================
-- 0011 — Email becomes compulsory on registration; POS member finder.
--
-- 1. members.email: backfill legacy rows with a greppable placeholder, then
--    NOT NULL + format CHECK. register_guest() and create_reservation()
--    require a real email for every new registration.
-- 2. pos_find_members(): one search box, three ways in — phone (exact,
--    normalized), member number (KP- prefix), or name (dropdown). Available
--    to every staff role but returns only the minimal recognition shape
--    (no phone/email) so host access stays consistent with design §4.2.
-- ============================================================================

-- Legacy rows (pre-email requirement): clearly-fake, greppable placeholders.
update members
  set email = lower(replace(member_no, '-', '')) || '@placeholder.kamadeva.dev'
  where email is null;

alter table members
  alter column email set not null;

alter table members
  add constraint members_email_format_chk
  check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');

-- ── register_guest: email is now a required parameter ───────────────────────
-- Signature changes, so drop the old function first (no overload left behind).

drop function if exists register_guest(text, text, uuid, text, boolean, consent_channel);

create or replace function register_guest(
  p_phone text,
  p_full_name text,
  p_email text,
  p_venue_id uuid,
  p_instagram text default null,
  p_consent_marketing boolean default false,
  p_channel consent_channel default 'door_tablet'
)
returns members
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_phone text := normalize_phone(p_phone);
  v_email text := lower(trim(coalesce(p_email, '')));
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

  -- Duplicate phones resolve to ONE profile, never a second row.
  select * into v_member from members where phone = v_phone;
  if found then
    return v_member;
  end if;

  insert into members (phone, full_name, email, instagram_handle, home_venue_id)
  values (v_phone, trim(p_full_name), v_email,
          nullif(trim(coalesce(p_instagram, '')), ''), p_venue_id)
  returning * into v_member;

  insert into consents (member_id, consent_type, granted, channel, captured_by_staff_id)
  values
    (v_member.id, 'data_processing', true, p_channel, v_staff),
    (v_member.id, 'marketing_whatsapp', p_consent_marketing, p_channel, v_staff);

  return v_member;
end;
$$;

-- ── create_reservation: inline registration now carries the email ───────────

drop function if exists create_reservation(uuid, timestamptz, integer, reservation_channel, uuid, text, text, uuid, text);

create or replace function create_reservation(
  p_venue_id uuid,
  p_reserved_for timestamptz,
  p_party_size integer,
  p_channel reservation_channel,
  p_member_id uuid default null,
  p_guest_phone text default null,
  p_guest_name text default null,
  p_guest_email text default null,
  p_event_id uuid default null,
  p_notes text default null
)
returns reservations
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_member members%rowtype;
  v_reservation reservations%rowtype;
begin
  if p_member_id is not null then
    select * into v_member from members where id = p_member_id and status = 'active';
    if not found then
      raise exception 'member not found';
    end if;
  elsif current_member_id() is not null then
    select * into v_member from members where id = current_member_id();
  elsif p_guest_phone is not null and p_guest_name is not null then
    if v_staff is null then
      raise exception 'staff session required for inline guest registration';
    end if;
    v_member := register_guest(p_guest_phone, p_guest_name, p_guest_email, p_venue_id,
                               null, false, 'staff_entry');
  else
    raise exception 'reservations require a registered member (the reservation rule)';
  end if;

  if v_staff is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  if p_event_id is not null
     and not event_booking_open_for(p_event_id, v_member.current_tier) then
    raise exception 'booking for this event has not opened for this member''s tier yet';
  end if;

  insert into reservations
    (member_id, venue_id, event_id, reserved_for, party_size, status, channel,
     created_by_staff_id, notes)
  values
    (v_member.id, p_venue_id, p_event_id, p_reserved_for, p_party_size,
     case when p_channel = 'staff' then 'confirmed'::reservation_status
          else 'requested'::reservation_status end,
     p_channel, v_staff, p_notes)
  returning * into v_reservation;

  return v_reservation;
end;
$$;

-- ── POS member finder: phone OR member number OR name, one box ──────────────
-- Minimal shape only (no contact details) so host access stays bounded.

create or replace function pos_find_members(p_query text, p_limit int default 8)
returns table (
  member_id uuid,
  member_no text,
  full_name text,
  tier tier_enum
)
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_query text := trim(coalesce(p_query, ''));
  v_phone text;
begin
  if current_staff_id() is null then
    raise exception 'staff session required';
  end if;
  if length(v_query) < 2 then
    return;
  end if;

  -- Phone-shaped input → exact match on the normalized number.
  if v_query ~ '^[+0-9][0-9 ()-]*$' then
    begin
      v_phone := normalize_phone(v_query);
    exception when others then
      v_phone := null;
    end;
  end if;

  return query
  select m.id, m.member_no, m.full_name, m.current_tier
  from members m
  where m.status = 'active'
    and (
      (v_phone is not null and m.phone = v_phone)
      or m.member_no ilike regexp_replace(upper(v_query), '^(KP-?)?', 'KP-') || '%'
      or m.full_name ilike '%' || v_query || '%'
    )
  order by
    (v_phone is not null and m.phone = v_phone) desc,
    (m.member_no ilike regexp_replace(upper(v_query), '^(KP-?)?', 'KP-') || '%') desc,
    m.full_name
  limit least(greatest(p_limit, 1), 20);
end;
$$;

revoke execute on function register_guest, create_reservation, pos_find_members from public, anon;
grant execute on function register_guest, create_reservation, pos_find_members to authenticated;
