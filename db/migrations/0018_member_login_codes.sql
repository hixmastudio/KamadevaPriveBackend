-- ============================================================================
-- 0018 — Member login codes (replaces email-OTP portal auth).
--
-- Members sign in to the portal with their phone OR email + a personal
-- 6-digit code. The code is generated at registration and handed over in
-- person; the member can change it later, and staff can reissue it at the
-- venue if forgotten. This removes the dependency on Supabase email delivery
-- and redirect configuration entirely.
--
-- Security posture for a 6-digit secret:
--   • Stored only as a bcrypt hash (pgcrypto), never in plaintext.
--   • Verified exclusively through verify_member_login(), which is granted to
--     service_role ONLY — the browser can never call it, so attempts run
--     through our own API route where we control rate limiting.
--   • 5 failed attempts locks the account for 15 minutes.
-- ============================================================================

-- ── Credential store — locked down; no anon/authenticated access ────────────
create table if not exists member_credentials (
  member_id       uuid primary key references members(id) on delete cascade,
  code_hash       text not null,
  code_set_at     timestamptz not null default now(),
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  updated_at      timestamptz not null default now()
);

alter table member_credentials enable row level security;
-- No policies → only service_role and SECURITY DEFINER functions can touch it.
revoke all on member_credentials from anon, authenticated;

-- ── Cryptographically-random 6-digit code (leading zeros preserved) ─────────
create or replace function gen_login_code()
returns text
language sql
volatile
set search_path = public, extensions, pg_temp
as $$
  select lpad(
    ((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text,
    6, '0');
$$;

-- ── Staff: (re)issue a member's code, returning the plaintext ONCE ──────────
create or replace function issue_member_code(p_member_id uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_code  text;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;
  if not exists (select 1 from members where id = p_member_id and status = 'active') then
    raise exception 'member not found';
  end if;

  v_code := gen_login_code();

  insert into member_credentials (member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (p_member_id, extensions.crypt(v_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (member_id) do update
    set code_hash = excluded.code_hash,
        code_set_at = now(),
        failed_attempts = 0,
        locked_until = null,
        updated_at = now();

  perform log_audit(
    p_actor_type => 'staff'::actor_type,
    p_actor_id   => v_staff,
    p_action     => 'member.login_code.issue',
    p_entity_type=> 'members',
    p_entity_id  => p_member_id::text
  );

  return v_code;
end;
$$;

-- ── Member self-service: change your own code ───────────────────────────────
create or replace function set_my_code(p_new_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_member uuid := current_member_id();
begin
  if v_member is null then
    raise exception 'not signed in as a member';
  end if;
  if p_new_code !~ '^[0-9]{6}$' then
    raise exception 'your code must be exactly 6 digits';
  end if;

  insert into member_credentials (member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (v_member, extensions.crypt(p_new_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (member_id) do update
    set code_hash = excluded.code_hash,
        code_set_at = now(),
        failed_attempts = 0,
        locked_until = null,
        updated_at = now();

  perform log_audit(
    p_actor_type => 'member'::actor_type,
    p_actor_id   => (select auth.uid()),
    p_action     => 'member.login_code.change',
    p_entity_type=> 'members',
    p_entity_id  => v_member::text
  );
end;
$$;

-- ── Service-role only: verify identifier + code, with lockout ───────────────
-- Returns the matched member on success, or a null member with lock/remaining
-- metadata on failure. NEVER granted to anon/authenticated.
create or replace function verify_member_login(p_identifier text, p_code text)
returns table (member_id uuid, member_no text, locked boolean, remaining int)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id    text := trim(coalesce(p_identifier, ''));
  v_max   int := 5;
  v_lock  interval := interval '15 minutes';
  v_member members%rowtype;
  v_cred  member_credentials%rowtype;
begin
  if position('@' in v_id) > 0 then
    select * into v_member from members
      where lower(email) = lower(v_id) and status = 'active' limit 1;
  else
    select * into v_member from members
      where phone = normalize_phone(v_id) and status = 'active' limit 1;
  end if;

  if not found then
    return query select null::uuid, null::text, false, v_max; return;
  end if;

  select * into v_cred from member_credentials mc where mc.member_id = v_member.id;
  if not found then
    -- No code set yet — indistinguishable from a wrong code to the caller.
    return query select null::uuid, null::text, false, v_max; return;
  end if;

  if v_cred.locked_until is not null and v_cred.locked_until > now() then
    return query select null::uuid, null::text, true, 0; return;
  end if;

  if v_cred.code_hash = extensions.crypt(p_code, v_cred.code_hash) then
    update member_credentials mc
      set failed_attempts = 0, locked_until = null, updated_at = now()
      where mc.member_id = v_member.id;
    return query select v_member.id, v_member.member_no, false, v_max; return;
  end if;

  update member_credentials mc
    set failed_attempts = mc.failed_attempts + 1,
        locked_until = case when mc.failed_attempts + 1 >= v_max then now() + v_lock else null end,
        updated_at = now()
    where mc.member_id = v_member.id
    returning * into v_cred;

  return query select
    null::uuid, null::text,
    (v_cred.locked_until is not null and v_cred.locked_until > now()),
    greatest(0, v_max - v_cred.failed_attempts);
end;
$$;

-- ── Service-role only: resolve the auth user backing a synthesized email ────
-- Lets the login route link members.auth_user_id idempotently.
create or replace function member_auth_user_id(p_email text)
returns uuid
language sql
security definer
set search_path = auth, public, pg_temp
as $$
  select id from auth.users where lower(email) = lower(p_email) limit 1;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
revoke execute on function gen_login_code()             from public;
revoke execute on function verify_member_login(text, text) from public, anon, authenticated;
revoke execute on function member_auth_user_id(text)    from public, anon, authenticated;
grant  execute on function verify_member_login(text, text) to service_role;
grant  execute on function member_auth_user_id(text)    to service_role;

revoke execute on function issue_member_code(uuid) from public, anon;
revoke execute on function set_my_code(text)       from public, anon;
grant  execute on function issue_member_code(uuid) to authenticated;
grant  execute on function set_my_code(text)       to authenticated;
