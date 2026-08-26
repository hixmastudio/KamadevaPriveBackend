-- ─────────────────────────────────────────────────────────────────────────────
-- 0083 — create_staff_account wrote to a table that does not exist
--
-- "relation \"staff_venues\" does not exist", raised at the Team screen while
-- trying to create the first host before opening. The table is, and always has
-- been, staff_venue_assignments.
--
-- HOW IT SURVIVED THIS LONG, because a wrong table name usually announces
-- itself immediately. PL/pgSQL does not resolve table names until the statement
-- actually runs, and this one is inside a FOREACH over p_venue_ids — so it only
-- runs when at least one venue is ticked. Every account made until now was
-- either seeded directly or created for a founder or a Head of Sales, and
-- neither is scoped to a venue: staff_has_venue() returns true for them
-- outright, so nobody ever ticks a box. The first person it could have failed
-- for is the first host, which is exactly who it failed for.
--
-- It predates the 0076 rework — that recreated this function from its live
-- definition and preserved the fault faithfully, which is what "every original
-- statement preserved" means when one of them is wrong.
--
-- Nothing was left half-made: the venue loop runs after the auth user and the
-- profile are inserted, and the exception rolled the whole function back, so
-- there is no orphaned login for the host who could not be created.
--
-- The ON CONFLICT DO NOTHING goes with it. There is no unique constraint on
-- (staff_id, venue_id) for it to act on, so it was doing nothing but suggesting
-- a protection that is not there; set_staff_venues does the equivalent with an
-- explicit NOT EXISTS, and a freshly created account has no prior rows anyway.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.create_staff_account(p_email text, p_full_name text, p_role staff_role, p_venue_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_caller_role staff_role := current_staff_role();
  v_email text := lower(trim(p_email));
  v_temp_password text;
  v_auth_id uuid := gen_random_uuid();
  v_staff_id uuid;
  v_venue uuid;
begin
  if v_caller_role is null or v_caller_role not in ('hosl', 'founder') then
    raise exception 'staff accounts are managed by the HoSL or a founder';
  end if;
  if p_role = 'founder' and v_caller_role != 'founder' then
    raise exception 'only a founder can create a founder account';
  end if;
  if v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'a valid email address is required';
  end if;
  if length(trim(p_full_name)) < 2 then
    raise exception 'full name is required';
  end if;
  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'an account with this email already exists';
  end if;

  v_temp_password := 'kp-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 4)
                   || '-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 5, 4);

  insert into auth.users
    (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
     raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
     confirmation_token, recovery_token, email_change,
     email_change_token_new, email_change_token_current,
     phone_change, phone_change_token, reauthentication_token)
  values
    ('00000000-0000-0000-0000-000000000000', v_auth_id, 'authenticated', 'authenticated',
     v_email, extensions.crypt(v_temp_password, extensions.gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}'::jsonb,
     jsonb_build_object('full_name', trim(p_full_name)),
     now(), now(), '', '', '', '', '', '', '', '');

  insert into staff_profiles (auth_user_id, full_name, role)
  values (v_auth_id, trim(p_full_name), p_role)
  returning id into v_staff_id;

  foreach v_venue in array coalesce(p_venue_ids, '{}'::uuid[]) loop
    -- staff_venue_assignments, not staff_venues. The latter has never existed;
    -- see the header for how that survived.
    insert into staff_venue_assignments (staff_id, venue_id)
    values (v_staff_id, v_venue);
  end loop;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => current_staff_id(),
    p_action      => 'staff.create',
    p_entity_type => 'staff_profiles',
    p_entity_id   => v_staff_id::text,
    p_after       => jsonb_build_object('email', v_email, 'role', p_role)
  );

  -- The welcome, with the password and what the role actually lets them do.
  -- Wrapped: a mail provider having a bad afternoon must never be the reason an
  -- account fails to be created. The password is still returned below, so the
  -- HoSL can hand it over in person when they are standing together — which is
  -- the better of the two ways.
  begin
    perform enqueue_staff_email(
      v_staff_id, 'staff_welcome', 'staff_welcome:' || v_staff_id::text,
      jsonb_build_object(
        'full_name', trim(p_full_name),
        'role', p_role::text,
        'password', v_temp_password,
        'is_reset', false)
    );
  exception when others then
    raise warning 'welcome email not queued for % — %', v_staff_id, sqlerrm;
  end;

  return jsonb_build_object(
    'staff_id', v_staff_id,
    'email',    v_email,
    -- Key kept as temp_password: the Team screen already reads it, and 0013
    -- established the name. Renaming it here would have silently blanked the
    -- one-time password on the handover panel.
    'temp_password', v_temp_password
  );
end;
$function$;
