-- ============================================================================
-- 0046 — Staff sign in with a password. Retire the PIN, and add the reset that
--        was missing.
--
-- Two problems, one of them serious.
--
-- The PIN was never a credential. Staff sign in through
-- supabase.auth.signInWithPassword with an email and password; verify_staff_pin
-- exists but is called by NOTHING — not the portal, not an edge function, not a
-- policy. Setting a PIN and trying to sign in with it could never have worked,
-- and the Team screen offered it prominently enough to look like the way in.
--
-- The serious one: there was no way to reset a staff password. create_staff_account
-- shows a temporary password once, at creation. Lose it — or set a PIN thinking
-- that was the credential — and the account is unreachable forever, with no
-- recovery anywhere in the product. One account is in exactly that state.
--
-- So: passwords become the whole story. reset_staff_password issues a fresh
-- temporary password and hands it back once, the same shape as account
-- creation. The PIN column, its two functions and the create parameter go.
--
-- Dropping pin_hash discards stored bcrypt hashes of PINs. That is the point:
-- they secure nothing, and keeping credential material for a removed feature is
-- worse than deleting it. Nobody loses access — the PIN opened nothing.
-- ============================================================================

-- ── The reset that should always have existed ───────────────────────────────

create or replace function reset_staff_password(p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_staff       staff_profiles%rowtype;
  v_email       text;
  v_password    text;
begin
  -- Positive allow-list: current_staff_role() is null for a non-staff caller,
  -- and a negated test would let that null through.
  if v_caller_role is null or v_caller_role not in ('hosl', 'founder') then
    raise exception 'staff accounts are managed by the HoSL or a founder';
  end if;

  select * into v_staff from staff_profiles where id = p_staff_id;
  if not found then
    raise exception 'staff member not found';
  end if;
  -- A founder's password is a founder's business.
  if v_staff.role = 'founder' and v_caller_role <> 'founder' then
    raise exception 'only a founder can reset a founder password';
  end if;
  if v_staff.auth_user_id is null then
    raise exception 'this staff member has no sign-in account';
  end if;

  select email into v_email from auth.users where id = v_staff.auth_user_id;

  -- Same shape as the one create_staff_account issues, so the handover script
  -- at the door does not change.
  v_password := 'kp-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 4)
                      || '-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 5, 4);

  update auth.users
     set encrypted_password = extensions.crypt(v_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_staff.auth_user_id;

  -- A reset is also how a lost or shared login gets taken back, so end any
  -- session already running on the old password rather than leaving it live.
  delete from auth.sessions where user_id = v_staff.auth_user_id;
  update auth.refresh_tokens
     set revoked = true
   where user_id = v_staff.auth_user_id::text;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => current_staff_id(),
    p_action      => 'staff.password_reset',
    p_entity_type => 'staff_profiles',
    p_entity_id   => p_staff_id::text,
    p_after       => jsonb_build_object('email', v_email)  -- never the password
  );

  return jsonb_build_object(
    'full_name',     v_staff.full_name,
    'email',         v_email,
    'temp_password', v_password
  );
end;
$$;

revoke execute on function reset_staff_password(uuid) from public, anon;
grant  execute on function reset_staff_password(uuid) to authenticated;

-- ── Retire the PIN ──────────────────────────────────────────────────────────

drop function if exists set_staff_pin(uuid, text);
drop function if exists verify_staff_pin(uuid, text);

-- create_staff_account loses its p_pin parameter. Dropping the old signature
-- first: a defaulted parameter makes an overload rather than a replacement, and
-- two candidates would leave the PostgREST call ambiguous.
drop function if exists create_staff_account(text, text, staff_role, uuid[], text);

create or replace function create_staff_account(
  p_email     text,
  p_full_name text,
  p_role      staff_role,
  p_venue_ids uuid[] default '{}'::uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
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
    insert into staff_venues (staff_id, venue_id) values (v_staff_id, v_venue)
    on conflict do nothing;
  end loop;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => current_staff_id(),
    p_action      => 'staff.create',
    p_entity_type => 'staff_profiles',
    p_entity_id   => v_staff_id::text,
    p_after       => jsonb_build_object('email', v_email, 'role', p_role)
  );

  return jsonb_build_object(
    'staff_id', v_staff_id,
    'email',    v_email,
    -- Key kept as temp_password: the Team screen already reads it, and 0013
    -- established the name. Renaming it here would have silently blanked the
    -- one-time password on the handover panel.
    'temp_password', v_temp_password
  );
end;
$$;

revoke execute on function create_staff_account(text, text, staff_role, uuid[]) from public, anon;
grant  execute on function create_staff_account(text, text, staff_role, uuid[]) to authenticated;

-- Last, now that nothing reads it.
alter table staff_profiles drop column if exists pin_hash;
