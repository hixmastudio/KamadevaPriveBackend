-- ============================================================================
-- 0022 — Member gender (captured at the door, staff-only visibility).
--
-- Optional, soft-checked. Threaded through register_guest (new-guest sign-in)
-- and update_member_profile (staff edit). Shown only on the staff member
-- profile, never in the member portal.
-- ============================================================================

alter table members
  add column if not exists gender text
  check (gender is null or gender in ('female', 'male', 'other', 'undisclosed'));

-- ── register_guest: now also records gender ─────────────────────────────────
drop function if exists register_guest(text, text, text, uuid, text, boolean, consent_channel);

create or replace function register_guest(
  p_phone text,
  p_full_name text,
  p_email text,
  p_venue_id uuid,
  p_instagram text default null,
  p_consent_marketing boolean default false,
  p_channel consent_channel default 'door_tablet',
  p_gender text default null
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

  select * into v_member from members where phone = v_phone;
  if found then
    return v_member;
  end if;

  insert into members (phone, full_name, email, gender, instagram_handle, home_venue_id)
  values (v_phone, trim(p_full_name), v_email, v_gender,
          nullif(trim(coalesce(p_instagram, '')), ''), p_venue_id)
  returning * into v_member;

  insert into consents (member_id, consent_type, granted, channel, captured_by_staff_id)
  values
    (v_member.id, 'data_processing', true, p_channel, v_staff),
    (v_member.id, 'marketing_whatsapp', p_consent_marketing, p_channel, v_staff);

  insert into member_cards (member_id, kind) values (v_member.id, 'prive');

  return v_member;
end;
$$;

revoke execute on function
  register_guest(text, text, text, uuid, text, boolean, consent_channel, text)
  from public, anon;
grant execute on function
  register_guest(text, text, text, uuid, text, boolean, consent_channel, text)
  to authenticated;

-- ── update_member_profile: now also edits gender ────────────────────────────
drop function if exists update_member_profile(uuid, text, text, text);

create or replace function update_member_profile(
  p_member_id uuid,
  p_full_name text default null,
  p_instagram text default null,
  p_email text default null,
  p_gender text default null
)
returns members
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
  v_gender text := nullif(lower(trim(coalesce(p_gender, ''))), '');
begin
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'profile edits require venue manager or above';
  end if;
  if v_gender is not null and v_gender not in ('female', 'male', 'other', 'undisclosed') then
    v_gender := null;
  end if;
  update members
    set full_name = coalesce(nullif(trim(coalesce(p_full_name, '')), ''), full_name),
        instagram_handle = coalesce(nullif(trim(coalesce(p_instagram, '')), ''), instagram_handle),
        email = coalesce(nullif(trim(coalesce(p_email, '')), ''), email),
        gender = coalesce(v_gender, gender)
    where id = p_member_id and status = 'active'
    returning * into v_member;
  if not found then
    raise exception 'member not found';
  end if;
  return v_member;
end;
$$;

revoke execute on function update_member_profile(uuid, text, text, text, text) from public, anon;
grant execute on function update_member_profile(uuid, text, text, text, text) to authenticated;
