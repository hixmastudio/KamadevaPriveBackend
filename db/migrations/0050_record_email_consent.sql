-- ============================================================================
-- 0050 — Record marketing_email at the door.
--
-- register_guest recorded data_processing and marketing_whatsapp, and nothing
-- for email. The checkbox the guest actually ticks says "happy to hear about
-- events and member benefits" — it names no channel, and they are handing over
-- an email address as they tick it. So the consent was being recorded more
-- narrowly than it was given, and 0049's event emails had nobody to send to:
-- marketing_email had zero rows, granted or denied.
--
-- New registrations from here record both. EXISTING members are deliberately
-- not backfilled from their WhatsApp answer — consent given for one named
-- channel is not consent for another, and inventing the difference in a
-- migration is exactly the kind of thing a privacy policy promises not to do.
-- They can opt in from the portal, which now offers the toggle.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.register_guest(p_phone text, p_full_name text, p_email text, p_venue_id uuid, p_instagram text DEFAULT NULL::text, p_consent_marketing boolean DEFAULT false, p_channel consent_channel DEFAULT 'door_tablet'::consent_channel, p_gender text DEFAULT NULL::text, p_date_of_birth date DEFAULT NULL::date)
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

  insert into members (phone, full_name, email, gender, instagram_handle, home_venue_id, date_of_birth)
  values (v_phone, trim(p_full_name), v_email, v_gender,
          nullif(trim(coalesce(p_instagram, '')), ''), p_venue_id, p_date_of_birth)
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
