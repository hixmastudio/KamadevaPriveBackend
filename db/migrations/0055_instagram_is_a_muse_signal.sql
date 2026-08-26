-- ============================================================================
-- 0055 — Instagram moves from Privé to Muse, where it is actually used for
--        something.
--
-- The door asked every new Privé guest for an Instagram handle and nothing ever
-- read it: 1 of 26 members has one on file, and no screen, report or rule
-- consults it. That is a field collected out of habit — and under the NDPA the
-- question is not whether a field is harmless but whether we need it. We do not.
--
-- Muse is where it means something. §7.2 lists "credible social presence" among
-- the curation criteria, alongside attendance and brand alignment, and §7.4
-- offers content opportunities by mutual agreement. An initiation with a written
-- rationale is precisely the moment a handle is worth recording — the owners
-- deciding on a candidate can see who they are being asked to invite.
--
-- So: the Muse register gains the column and the initiation form asks for it,
-- and register_guest stops asking altogether. Its p_instagram parameter is
-- REMOVED rather than left in place and ignored, because a parameter a caller
-- can still pass and that silently goes nowhere is worse than no parameter.
-- Dropping the old signature explicitly matters here: Postgres overloads on
-- arguments, so creating the shorter version without dropping the longer one
-- leaves both, and PostgREST then refuses the call as ambiguous.
--
-- members.instagram_handle is deliberately LEFT IN PLACE. One real member's
-- handle is stored there, and quietly destroying a person's data as a side
-- effect of a product decision is not a migration's business. Nothing writes to
-- it after this. Clearing it and dropping the column is a follow-up for the
-- house to decide, and the honest end state — holding one value nobody can see
-- is the worst of both worlds.
-- ============================================================================

alter table muse.members
  add column if not exists instagram_handle text;

comment on column muse.members.instagram_handle is
  'Optional. Part of the "credible social presence" the governance document
   lists among the curation criteria (§7.2), and the basis of any content
   arrangement under §7.4.';

-- ── Initiation now records the handle ───────────────────────────────────────

drop function if exists muse_initiate(text, text, text, date, text);

create or replace function muse_initiate(
  p_full_name text,
  p_phone     text,
  p_email     text,
  p_dob       date,
  p_rationale text,
  p_instagram text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role        staff_role := current_staff_role();
  v_phone       text;
  v_instagram   text;
  v_muse_id     uuid;
  v_approval_id uuid;
  v_candidate_id uuid;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'Muse candidates are initiated by venue managers, the HoSL, or founders';
  end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then
    raise exception 'a full name is required';
  end if;
  if coalesce(p_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'a valid email is required';
  end if;
  if p_dob is null or p_dob > (current_date - interval '18 years') then
    raise exception 'date of birth is required and the member must be at least 18';
  end if;
  if length(trim(coalesce(p_rationale, ''))) < 10 then
    raise exception 'a written rationale is required';
  end if;
  v_phone := normalize_phone(p_phone);  -- raises on an invalid number

  -- Stored without the @, so it is one shape wherever it is read or linked.
  v_instagram := nullif(regexp_replace(trim(coalesce(p_instagram, '')), '^@+', ''), '');

  select id into v_muse_id from muse.members where phone = v_phone;
  if v_muse_id is not null then
    if exists (select 1 from muse.members
               where id = v_muse_id and status in ('candidate', 'active', 'paused')) then
      raise exception 'this person is already a Muse candidate or member';
    end if;
    update muse.members
       set full_name = trim(p_full_name), email = lower(trim(p_email)),
           date_of_birth = p_dob, status = 'candidate',
           -- Keep what we already hold if this initiation does not supply one.
           instagram_handle = coalesce(v_instagram, instagram_handle)
     where id = v_muse_id;
  else
    insert into muse.members (full_name, phone, email, date_of_birth, status, instagram_handle)
    values (trim(p_full_name), v_phone, lower(trim(p_email)), p_dob, 'candidate', v_instagram)
    returning id into v_muse_id;
  end if;

  insert into approvals (subject_type, member_id, requested_by, rationale)
  values ('muse_membership', null, current_staff_id(), trim(p_rationale))
  returning id into v_approval_id;

  insert into muse.candidates (member_id, initiated_by, initiator_role_snapshot, rationale, approval_id)
  values (v_muse_id, current_staff_id(), v_role, trim(p_rationale), v_approval_id)
  returning id into v_candidate_id;

  return v_candidate_id;
end;
$$;

revoke execute on function muse_initiate(text, text, text, date, text, text) from public, anon;
grant  execute on function muse_initiate(text, text, text, date, text, text) to authenticated;

-- ── The door stops asking ───────────────────────────────────────────────────
-- Same body as 0050 with the instagram parameter and column removed.

drop function if exists register_guest(text, text, text, uuid, text, boolean, consent_channel, text, date);

CREATE OR REPLACE FUNCTION public.register_guest(p_phone text, p_full_name text, p_email text, p_venue_id uuid, p_consent_marketing boolean DEFAULT false, p_channel consent_channel DEFAULT 'door_tablet'::consent_channel, p_gender text DEFAULT NULL::text, p_date_of_birth date DEFAULT NULL::date)
 RETURNS members
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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

  insert into members (phone, full_name, email, gender, home_venue_id, date_of_birth)
  values (v_phone, trim(p_full_name), v_email, v_gender, p_venue_id, p_date_of_birth)
  returning * into v_member;

  -- The consent checkbox at the door reads "happy to hear about events and
  -- member benefits" — channel-agnostic wording, and the guest hands over an
  -- email address in the same breath. Record it against BOTH channels rather
  -- than only WhatsApp: recording a narrower consent than was actually asked
  -- for is what left event email with nobody to send to.
  insert into consents (member_id, consent_type, granted, channel, captured_by_staff_id)
  values
    (v_member.id, 'data_processing', true, p_channel, v_staff),
    (v_member.id, 'marketing_whatsapp', p_consent_marketing, p_channel, v_staff),
    (v_member.id, 'marketing_email', p_consent_marketing, p_channel, v_staff);

  insert into member_cards (member_id, kind) values (v_member.id, 'prive');

  return v_member;
end;
$function$;

revoke execute on function register_guest(text, text, text, uuid, boolean, consent_channel, text, date) from public, anon;
grant  execute on function register_guest(text, text, text, uuid, boolean, consent_channel, text, date) to authenticated;

-- ── The reservation rule still has to work ──────────────────────────────────
-- create_reservation registers a guest inline when a booking is taken for
-- someone not yet on the register (§9.1: no reservation from outside the
-- programme). It passed a positional null where p_instagram used to sit, so
-- removing that parameter above breaks this call — and with it every booking
-- taken for a new guest. Recreated from the live definition with the stray
-- argument removed, rather than rewritten from memory.

CREATE OR REPLACE FUNCTION public.create_reservation(p_venue_id uuid, p_reserved_for timestamp with time zone, p_party_size integer, p_channel reservation_channel, p_member_id uuid DEFAULT NULL::uuid, p_guest_phone text DEFAULT NULL::text, p_guest_name text DEFAULT NULL::text, p_guest_email text DEFAULT NULL::text, p_event_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS reservations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
                               false, 'staff_entry');
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
$function$

