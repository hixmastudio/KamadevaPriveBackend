-- ─────────────────────────────────────────────────────────────────────────────
-- 0076 — who may do what to a staff account
--
-- The model until now was one line: HoSL or founder, for everything. That put
-- creating an account, resetting anyone's password, and standing someone down
-- all at the same height. The founder asked for the real shape:
--
--   · a new account arrives by email, with the password and what the role means
--   · a host and a venue manager cannot change their own password
--   · the HoSL may reset a host's or a venue manager's password, nobody else's
--   · only the founder may reset any password, and only the founder may remove
--     an account outright
-- ─────────────────────────────────────────────────────────────────────────────

-- The outbox learns to address a member of staff. Same shape as the Muse column
-- added in the standalone rework: nullable, and exactly one of the three
-- recipient columns is ever set.
alter table email_outbox add column if not exists staff_id uuid references staff_profiles(id);

-- Why an account was removed, and by whom. Kept on the profile rather than only
-- in the audit log because the Team screen has to be able to say "removed" and
-- give a reason without a log query.
-- A removed account has no auth user, so the link has to be allowed to be
-- empty. The code already assumed it could be: reset_staff_password has raised
-- 'this staff member has no sign-in account' on a null since it was written,
-- against a column that could not actually hold one.
alter table staff_profiles alter column auth_user_id drop not null;

alter table staff_profiles add column if not exists removed_at timestamptz;
alter table staff_profiles add column if not exists removed_reason text;
alter table staff_profiles add column if not exists removed_by uuid references staff_profiles(id);

comment on column staff_profiles.removed_at is
  'Set when a founder removed the sign-in. The profile survives because 32 tables reference it — every visit captured, transaction entered and approval signed.';

create or replace function enqueue_staff_email(
  p_staff_id uuid,
  p_template email_template,
  p_dedupe_key text,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_email text;
  v_id uuid;
begin
  select u.email into v_email
    from staff_profiles sp join auth.users u on u.id = sp.auth_user_id
   where sp.id = p_staff_id;
  if v_email is null then
    return null;
  end if;

  insert into email_outbox (staff_id, to_email, template, payload, dedupe_key, status, last_error)
  values (
    p_staff_id, v_email, p_template, coalesce(p_payload, '{}'::jsonb), p_dedupe_key,
    (case when is_sendable_email(v_email) then 'queued' else 'skipped' end)::email_status,
    case when is_sendable_email(v_email) then null
         else 'address is a placeholder or non-deliverable domain' end
  )
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function enqueue_staff_email(uuid, email_template, text, jsonb) from public, anon, authenticated;

-- ── A host's password is not a host's to change ─────────────────────────────
-- Enforced here rather than by hiding the form, because hiding a form is not a
-- rule: supabase.auth.updateUser() is a plain HTTPS call and anyone who has
-- signed in can make it. A restriction that only exists in the interface is one
-- the interface is lying about.
--
-- Scoped as tightly as it can be. It fires only when the password hash actually
-- changes, only for auth users who are staff, only for hosts and venue
-- managers, and it stands aside when our own reset function announces itself
-- through a transaction-local setting. Members are not staff, so the lookup
-- finds nothing and their code changes are untouched; the founder and the HoSL
-- are not in the list and change their own passwords freely.
create or replace function staff_password_is_not_self_service()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role;
begin
  if new.encrypted_password is not distinct from old.encrypted_password then
    return new;
  end if;
  -- Our own reset path sets this for the length of its transaction.
  if coalesce(current_setting('kamadeva.staff_password_reset', true), '') = 'on' then
    return new;
  end if;

  select sp.role into v_role
    from staff_profiles sp
   where sp.auth_user_id = new.id and sp.is_active;

  if v_role in ('host', 'venue_manager') then
    raise exception
      'your sign-in password is set for you — ask the Head of Sales or a founder to reset it';
  end if;

  return new;
end;
$$;

drop trigger if exists staff_password_is_not_self_service on auth.users;
create trigger staff_password_is_not_self_service
  before update on auth.users
  for each row execute function staff_password_is_not_self_service();

-- ── Resetting somebody else's password ──────────────────────────────────────
-- The rule the founder asked for, in place of "HoSL or founder, anyone":
--   founder → any account, including another founder's
--   HoSL    → hosts and venue managers only
-- Everyone else → nothing, which the positive allow-check below is what makes
-- true: current_staff_role() is NULL for a non-staff caller, and a negated test
-- would let that NULL straight through.
create or replace function reset_staff_password(p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_staff       staff_profiles%rowtype;
  v_email       text;
  v_password    text;
begin
  if v_caller_role is null or v_caller_role not in ('hosl', 'founder') then
    raise exception 'staff passwords are reset by the Head of Sales or a founder';
  end if;

  select * into v_staff from staff_profiles where id = p_staff_id;
  if not found then
    raise exception 'staff member not found';
  end if;
  if v_staff.removed_at is not null then
    raise exception 'that account has been removed';
  end if;
  if v_staff.auth_user_id is null then
    raise exception 'this staff member has no sign-in account';
  end if;

  -- The HoSL's reach stops at the people she runs the floor with. A founder's
  -- or another HoSL's password is a founder's business.
  if v_caller_role = 'hosl' and v_staff.role not in ('host', 'venue_manager') then
    raise exception 'the Head of Sales can reset a host or a venue manager — % is a founder''s to reset',
      v_staff.full_name;
  end if;

  select email into v_email from auth.users where id = v_staff.auth_user_id;

  v_password := 'kp-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 4)
                      || '-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 5, 4);

  -- Announce ourselves to the trigger above for the length of this transaction,
  -- so the one legitimate way a host's password changes is not blocked by the
  -- rule that stops them changing it themselves.
  perform set_config('kamadeva.staff_password_reset', 'on', true);

  update auth.users
     set encrypted_password = extensions.crypt(v_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_staff.auth_user_id;

  -- A reset is also how a lost or shared login gets taken back, so end any
  -- session already running on the old password rather than leaving it live.
  delete from auth.sessions where user_id = v_staff.auth_user_id;
  update auth.refresh_tokens set revoked = true
   where user_id = v_staff.auth_user_id::text;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => current_staff_id(),
    p_action      => 'staff.password_reset',
    p_entity_type => 'staff_profiles',
    p_entity_id   => p_staff_id::text,
    p_after       => jsonb_build_object('email', v_email)  -- never the password
  );

  -- Posted as well as shown. The screen still returns it so it can be handed
  -- over in person, which is the better way when the two are in the same room.
  begin
    perform enqueue_staff_email(
      p_staff_id, 'staff_welcome',
      'staff_password_reset:' || p_staff_id::text || ':' || extract(epoch from now())::bigint::text,
      jsonb_build_object(
        'full_name', v_staff.full_name,
        'role', v_staff.role::text,
        'password', v_password,
        'is_reset', true)
    );
  exception when others then
    raise warning 'password email not queued for % — %', p_staff_id, sqlerrm;
  end;

  return jsonb_build_object(
    'full_name',     v_staff.full_name,
    'email',         v_email,
    'temp_password', v_password
  );
end;
$$;

revoke execute on function reset_staff_password(uuid) from public, anon;
grant  execute on function reset_staff_password(uuid) to authenticated;

-- ── Removing an account ─────────────────────────────────────────────────────
-- Founder only, and what it removes is the SIGN-IN, not the person's history.
--
-- The staff_profiles row cannot go: thirty-two tables reference it, almost all
-- ON DELETE RESTRICT — every visit they captured, every transaction they
-- entered, every approval they signed. Deleting the row would mean deleting the
-- night's record along with them, and "who served this table" is not ours to
-- erase because someone has left.
--
-- So the auth user is deleted outright. That is the account: no password to
-- guess, no session to resume, no way back in. The profile stays, marked
-- removed and inactive, and the audit trail keeps their name — which is the
-- point of an audit trail.
create or replace function remove_staff_account(p_staff_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff staff_profiles%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_email text;
begin
  if current_staff_role() is distinct from 'founder' then
    raise exception 'removing a staff account is the founder''s decision';
  end if;
  if v_reason is null or length(v_reason) < 10 then
    raise exception 'say why, in a sentence — this is recorded against the decision';
  end if;

  select * into v_staff from staff_profiles where id = p_staff_id for update;
  if not found then
    raise exception 'staff member not found';
  end if;
  if v_staff.id = current_staff_id() then
    raise exception 'you cannot remove your own account';
  end if;
  if v_staff.removed_at is not null then
    raise exception '% has already been removed', v_staff.full_name;
  end if;

  select email into v_email from auth.users where id = v_staff.auth_user_id;

  -- Logged before the fact, so the entry is written while there is still
  -- something to describe.
  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => current_staff_id(),
    p_action      => 'staff.account_removed',
    p_entity_type => 'staff_profiles',
    p_entity_id   => p_staff_id::text,
    p_after       => jsonb_build_object('email', v_email, 'reason', v_reason)
  );

  -- Order matters, and it is the opposite of the obvious one. The profile has
  -- a foreign key onto auth.users, so the account cannot be deleted while the
  -- profile still points at it — the row has to let go first. v_staff was read
  -- before any of this, so the id survives the nulling.
  update staff_profiles
     set auth_user_id = null,
         is_active = false,
         deactivated_at = coalesce(deactivated_at, now()),
         removed_at = now(),
         removed_reason = v_reason,
         removed_by = current_staff_id()
   where id = p_staff_id;

  if v_staff.auth_user_id is not null then
    -- Sessions first, then the account. The delete would cascade them anyway,
    -- but this order means even a half-failed removal leaves nobody signed in.
    delete from auth.sessions where user_id = v_staff.auth_user_id;
    update auth.refresh_tokens set revoked = true
     where user_id = v_staff.auth_user_id::text;
    delete from auth.users where id = v_staff.auth_user_id;
  end if;

  -- Their assignments go with the account; the venues should stop listing
  -- someone who can no longer walk in.
  update staff_venue_assignments set revoked_at = now()
   where staff_id = p_staff_id and revoked_at is null;

  return jsonb_build_object(
    'full_name', v_staff.full_name,
    'email', v_email,
    'detail', 'Their sign-in is gone and every session ended. The staff record stays '
              || 'because past visits, bills and approvals are recorded against it.');
end;
$$;

revoke execute on function remove_staff_account(uuid, text) from public, anon;
grant  execute on function remove_staff_account(uuid, text) to authenticated;

-- ── The welcome ─────────────────────────────────────────────────────────────
-- Recreated from the live definition rather than retyped, with one block added
-- before the return. Everything else — the founder-only guard on creating
-- another founder, the email validation, the auth.users insert with its eight
-- empty-string token columns — is exactly as it was.
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
