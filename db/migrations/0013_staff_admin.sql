-- ============================================================================
-- 0013 — Staff administration: HoSL/founders provision and manage staff
-- accounts from the app (design §4 matrix: "Staff accounts, PINs, limits
-- admin" = HoSL, founder oversight). Account creation writes auth.users
-- directly inside a SECURITY DEFINER function — the same GoTrue-compatible
-- shape as the environment seeds — so the app never needs the service key.
-- ============================================================================

-- Create a staff account: auth user + identity + profile + venue assignments
-- in one transaction. Returns the one-time temporary password.
create or replace function create_staff_account(
  p_email text,
  p_full_name text,
  p_role staff_role,
  p_venue_ids uuid[] default '{}',
  p_pin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_email text := lower(trim(p_email));
  v_temp_password text;
  v_auth_id uuid := gen_random_uuid();
  v_staff_id uuid;
  v_venue uuid;
begin
  if v_caller_role not in ('hosl', 'founder') then
    raise exception 'staff accounts are managed by the HoSL or a founder';
  end if;
  -- Founders are appointed only by founders.
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
  if p_pin is not null and p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN must be 4-6 digits';
  end if;

  -- Readable one-time password: kp-XXXX-XXXX from random bytes.
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
     '{"provider":"email","providers":["email"]}', '{}', now(), now(),
     '', '', '', '', '', '', '', '');

  insert into auth.identities
    (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values
    (gen_random_uuid(), v_auth_id, v_auth_id::text, 'email',
     jsonb_build_object('sub', v_auth_id::text, 'email', v_email, 'email_verified', true),
     now(), now(), now());

  insert into staff_profiles (auth_user_id, full_name, role, pin_hash)
  values (v_auth_id, trim(p_full_name), p_role,
          case when p_pin is null then null
               else extensions.crypt(p_pin, extensions.gen_salt('bf')) end)
  returning id into v_staff_id;

  foreach v_venue in array coalesce(p_venue_ids, '{}') loop
    insert into staff_venue_assignments (staff_id, venue_id) values (v_staff_id, v_venue);
  end loop;

  perform log_audit('staff', auth.uid(), 'staff.account.create',
                    'staff_profiles', v_staff_id::text, null, null,
                    jsonb_build_object('email', v_email, 'role', p_role));

  return jsonb_build_object(
    'staff_id', v_staff_id,
    'email', v_email,
    'temp_password', v_temp_password
  );
end;
$$;

-- Activate / deactivate. A deactivated profile fails current_staff_id()
-- everywhere instantly — JWTs are never the authority (design §4).
create or replace function set_staff_active(p_staff_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_target staff_profiles%rowtype;
begin
  if v_caller_role not in ('hosl', 'founder') then
    raise exception 'staff accounts are managed by the HoSL or a founder';
  end if;
  select * into v_target from staff_profiles where id = p_staff_id for update;
  if not found then
    raise exception 'staff member not found';
  end if;
  if v_target.id = current_staff_id() then
    raise exception 'you cannot deactivate your own account';
  end if;
  if v_target.role = 'founder' and v_caller_role != 'founder' then
    raise exception 'only a founder can manage a founder account';
  end if;

  update staff_profiles
    set is_active = p_active,
        deactivated_at = case when p_active then null else now() end
    where id = p_staff_id;
end;
$$;

-- Reconcile venue assignments to exactly the given set (revoke missing,
-- add new; history preserved via revoked_at).
create or replace function set_staff_venues(p_staff_id uuid, p_venue_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_venue uuid;
begin
  if v_caller_role not in ('hosl', 'founder') then
    raise exception 'venue assignments are managed by the HoSL or a founder';
  end if;
  perform 1 from staff_profiles where id = p_staff_id;
  if not found then
    raise exception 'staff member not found';
  end if;

  update staff_venue_assignments
    set revoked_at = now()
    where staff_id = p_staff_id
      and revoked_at is null
      and not (venue_id = any (coalesce(p_venue_ids, '{}')));

  foreach v_venue in array coalesce(p_venue_ids, '{}') loop
    if not exists (
      select 1 from staff_venue_assignments
      where staff_id = p_staff_id and venue_id = v_venue and revoked_at is null
    ) then
      insert into staff_venue_assignments (staff_id, venue_id) values (p_staff_id, v_venue);
    end if;
  end loop;

  perform log_audit('staff', auth.uid(), 'staff.venues.set',
                    'staff_profiles', p_staff_id::text, null, null,
                    jsonb_build_object('venue_ids', p_venue_ids));
end;
$$;

revoke execute on function create_staff_account, set_staff_active, set_staff_venues
from public, anon;
grant execute on function create_staff_account, set_staff_active, set_staff_venues
to authenticated;
