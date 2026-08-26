-- ============================================================================
-- 0065 — Names are captured in two parts.
--
-- The door and the Muse initiation both asked for one "full name" box, so
-- "Adébíọlá Emmanuel" and "YAKANA AVODO BRUNO" arrived as single strings and
-- nothing could tell which part was which. That matters for anything addressed
-- to a person: the welcome email already greets by first name and gets it by
-- taking the first word, which is a guess that fails the moment someone enters
-- a title, a double first name, or their surname first — a real risk in Nigeria,
-- where surname-first is common on official forms.
--
-- full_name STAYS, and stays authoritative. Thirty-one functions read it —
-- cards, recognition at the door, emails, the public card page, POS lookup.
-- Rewriting all of them to compose a name would be a large change for no gain,
-- and any one missed would print a blank where a member's name should be. So
-- the parts are captured and full_name is composed from them, rather than the
-- other way round.
--
-- Existing rows are split on the first space: first word to first_name, the
-- remainder to last_name. That is right for the four active members and would
-- be wrong for some future one — which is exactly why it is a backfill of what
-- we already hold rather than a rule applied to new sign-ups.
-- ============================================================================

alter table members
  add column if not exists first_name text,
  add column if not exists last_name  text;

alter table muse.members
  add column if not exists first_name text,
  add column if not exists last_name  text;

comment on column members.first_name is
  'Given name, captured separately since 0065. full_name remains authoritative
   and is composed from these; read that, not this, when displaying a member.';

update members
   set first_name = coalesce(first_name, nullif(split_part(trim(full_name), ' ', 1), '')),
       last_name  = coalesce(last_name,
                     nullif(trim(substr(trim(full_name), length(split_part(trim(full_name), ' ', 1)) + 2)), ''))
 where first_name is null or last_name is null;

update muse.members
   set first_name = coalesce(first_name, nullif(split_part(trim(full_name), ' ', 1), '')),
       last_name  = coalesce(last_name,
                     nullif(trim(substr(trim(full_name), length(split_part(trim(full_name), ' ', 1)) + 2)), ''))
 where first_name is null or last_name is null;

-- ── The door asks for both ──────────────────────────────────────────────────
-- Recreated from the live 8-argument definition with the two parts appended.
-- Dropped first: adding parameters creates an overload rather than replacing
-- the function, and PostgREST then refuses the call as ambiguous — the exact
-- failure 0055 caused at a door.
--
-- p_full_name stays REQUIRED rather than optional, because Postgres will not
-- accept a defaulted parameter ahead of p_email and p_venue_id, which have no
-- defaults and should not get them. Callers sending the two parts pass it as
-- null explicitly, which is clearer at the call site anyway.

drop function if exists register_guest(text, text, text, uuid, boolean, consent_channel, text, date);

CREATE OR REPLACE FUNCTION public.register_guest(p_phone text, p_full_name text, p_email text, p_venue_id uuid, p_consent_marketing boolean DEFAULT false, p_channel consent_channel DEFAULT 'door_tablet'::consent_channel, p_gender text DEFAULT NULL::text, p_date_of_birth date DEFAULT NULL::date, p_first_name text DEFAULT NULL::text, p_last_name text DEFAULT NULL::text)
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
  -- Two parts when the form sends them; the single box otherwise, so a client
  -- that has not been redeployed keeps working.
  v_name text := nullif(trim(coalesce(
    nullif(trim(coalesce(p_first_name, '') || ' ' || coalesce(p_last_name, '')), ''),
    p_full_name)), '');
begin
  if length(coalesce(v_name, '')) < 2 then
    raise exception 'a first name and surname are required';
  end if;
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

  insert into members (phone, full_name, first_name, last_name, email, gender, home_venue_id, date_of_birth)
  values (v_phone, v_name, nullif(trim(coalesce(p_first_name,'')),''), nullif(trim(coalesce(p_last_name,'')),''),
          v_email, v_gender, p_venue_id, p_date_of_birth)
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
$function$
;


-- ── Muse initiation asks for both too ───────────────────────────────────────
-- Its trailing parameters already carry defaults, so the two parts append
-- without disturbing the order.

drop function if exists muse_initiate(text, text, text, date, text, text);

CREATE OR REPLACE FUNCTION public.muse_initiate(p_full_name text, p_phone text, p_email text, p_dob date, p_rationale text, p_instagram text DEFAULT NULL::text, p_first_name text DEFAULT NULL::text, p_last_name text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_role        staff_role := current_staff_role();
  v_phone       text;
  v_instagram   text;
  v_muse_id     uuid;
  v_approval_id uuid;
  v_candidate_id uuid;
  v_name text := nullif(trim(coalesce(
    nullif(trim(coalesce(p_first_name, '') || ' ' || coalesce(p_last_name, '')), ''),
    p_full_name)), '');
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'Muse candidates are initiated by venue managers, the HoSL, or founders';
  end if;
  if length(coalesce(v_name, '')) < 2 then
    raise exception 'a first name and surname are required';
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
       set full_name = v_name,
           first_name = coalesce(nullif(trim(coalesce(p_first_name,'')),''), first_name),
           last_name  = coalesce(nullif(trim(coalesce(p_last_name,'')),''), last_name), email = lower(trim(p_email)),
           date_of_birth = p_dob, status = 'candidate',
           -- Keep what we already hold if this initiation does not supply one.
           instagram_handle = coalesce(v_instagram, instagram_handle)
     where id = v_muse_id;
  else
    insert into muse.members (full_name, first_name, last_name, phone, email, date_of_birth, status, instagram_handle)
    values (v_name, nullif(trim(coalesce(p_first_name,'')),''), nullif(trim(coalesce(p_last_name,'')),''), v_phone, lower(trim(p_email)), p_dob, 'candidate', v_instagram)
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
$function$
;
