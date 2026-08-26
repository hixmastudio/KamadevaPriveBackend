-- ============================================================================
-- 0063 — The welcome carries the code, and a member who loses it can recover.
--
-- Until now a code existed only if a host issued one at the door and read it
-- aloud. Lose it and there was no way back in: no reset, no self-service, and
-- nothing in the portal that could help. The only recovery was to find a member
-- of staff who could issue a new one.
--
-- TWO PARTS.
--
-- 1. A code is issued when the card is, and travels in the welcome email — with
--    the two things a member needs told: change it, and never give it to
--    anyone. Including us. Especially us: "someone from Kamadeva asking for your
--    code" is the shape almost every account-takeover call takes, and a member
--    who has been told plainly that we will never ask has a defence that no
--    amount of system hardening provides.
--
--    Only issued if the member has none. A member who has already set their own
--    code keeps it; the welcome is not a licence to reset somebody.
--
-- 2. A reset by emailed link.
--
-- THE TOKEN RULES, because this is a credential path and the details are the
-- security:
--
--   * 32 random bytes, hex — not guessable, not a counter, not derived from
--     anything about the member.
--   * Only the SHA-256 is stored. A dump of this table cannot be used to reset
--     anybody, which is the same reason the codes themselves are bcrypt.
--   * Thirty minutes, single use, and redeeming one invalidates every other
--     outstanding token for that member — so a stolen older link dies the
--     moment the real member completes a reset.
--   * Requesting NEVER reveals whether an address is on the register. The
--     function returns the same answer either way. A sign-in page that says
--     "no such member" is a membership-list oracle, and this one is a private
--     club's.
--   * Five requests an hour per member, so the mailbox cannot be used as a
--     weapon against someone whose address is known.
-- ============================================================================

alter type email_template add value if not exists 'code_reset';

create table if not exists member_code_resets (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references members (id) on delete cascade,
  -- The token itself is never stored, only this.
  token_hash  text not null unique,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists member_code_resets_member_idx
  on member_code_resets (member_id, created_at desc);

alter table member_code_resets enable row level security;
revoke all on member_code_resets from anon, authenticated;

-- ── Requesting a reset ──────────────────────────────────────────────────────

create or replace function request_member_code_reset(p_identifier text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_id     text := trim(coalesce(p_identifier, ''));
  v_member members%rowtype;
  v_token  text;
  v_recent int;
begin
  -- Resolved the same way sign-in resolves it: phone or email.
  if v_id like '%@%' then
    select * into v_member from members
     where lower(email) = lower(v_id) and status = 'active';
  else
    begin
      select * into v_member from members
       where phone = normalize_phone(v_id) and status = 'active';
    exception when others then
      v_member := null;   -- an unparseable number is simply no match
    end;
  end if;

  if v_member.id is not null and is_sendable_email(v_member.email) then
    select count(*) into v_recent from member_code_resets
     where member_id = v_member.id and created_at > now() - interval '1 hour';

    -- Silently declining past the limit keeps the answer identical from
    -- outside, which is the whole point of the response below.
    if v_recent < 5 then
      v_token := encode(extensions.gen_random_bytes(32), 'hex');

      insert into member_code_resets (member_id, token_hash, expires_at)
      values (v_member.id, encode(extensions.digest(v_token, 'sha256'), 'hex'),
              now() + interval '30 minutes');

      perform enqueue_member_email(
        v_member.id,
        'code_reset',
        -- Deduped per token, not per member: a second genuine request inside
        -- the hour must still arrive.
        'code_reset:' || left(encode(extensions.digest(v_token, 'sha256'), 'hex'), 24),
        jsonb_build_object(
          'full_name', v_member.full_name,
          'member_no', v_member.member_no,
          'token',     v_token,
          'minutes',   '30'
        )
      );
    end if;
  end if;

  -- The same answer whether or not anyone was found. Do not make this
  -- helpful: a private club's sign-in page must not confirm who is a member.
  return jsonb_build_object(
    'ok', true,
    'message', 'If that phone or email is on the register, a link is on its way.'
  );
end;
$$;

-- ── Redeeming it ────────────────────────────────────────────────────────────

create or replace function redeem_member_code_reset(p_token text, p_new_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_hash  text := encode(extensions.digest(trim(coalesce(p_token, '')), 'sha256'), 'hex');
  v_row   member_code_resets%rowtype;
begin
  if p_new_code !~ '^[0-9]{6}$' then
    raise exception 'your code must be exactly 6 digits';
  end if;

  select * into v_row from member_code_resets
   where token_hash = v_hash and used_at is null and expires_at > now()
   for update;
  if not found then
    -- One message for expired, used and invented alike: distinguishing them
    -- tells an attacker which guesses were close.
    raise exception 'that link has expired or has already been used — ask for a new one';
  end if;

  insert into member_credentials (member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (v_row.member_id, extensions.crypt(p_new_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (member_id) do update
    set code_hash       = excluded.code_hash,
        code_set_at     = now(),
        -- A successful reset clears a lockout: the person proving control of
        -- the mailbox is the owner, and leaving them locked out helps nobody.
        failed_attempts = 0,
        locked_until    = null,
        updated_at      = now();

  update member_code_resets set used_at = now() where id = v_row.id;
  -- Any other live link for this member dies here.
  update member_code_resets set used_at = now()
   where member_id = v_row.member_id and used_at is null and id <> v_row.id;

  perform log_audit(
    p_actor_type  => 'member'::actor_type,
    p_actor_id    => v_row.member_id,
    p_action      => 'member.code.reset',
    p_entity_type => 'members',
    p_entity_id   => v_row.member_id::text
  );

  return jsonb_build_object('ok', true);
end;
$$;

-- Both are pre-sign-in by nature, so anon must be able to call them. Neither
-- leaks: one always answers the same, the other needs a token.
grant execute on function request_member_code_reset(text) to anon, authenticated;
grant execute on function redeem_member_code_reset(text, text) to anon, authenticated;

-- ── The welcome now carries a code ──────────────────────────────────────────
-- Recreated from 0042's trigger with the code issuance added.

create or replace function on_prive_card_issued()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_member members%rowtype;
  v_code   text;
begin
  if new.kind <> 'prive' then
    return new;
  end if;

  select * into v_member from members where id = new.member_id;
  if not found then
    return new;
  end if;

  -- Only if they have none. A member who has already chosen a code keeps it —
  -- issuing a card is not a reason to reset somebody's sign-in.
  if not exists (select 1 from member_credentials where member_id = v_member.id) then
    v_code := gen_login_code();
    insert into member_credentials (member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
    values (v_member.id, extensions.crypt(v_code, extensions.gen_salt('bf')), now(), 0, null, now())
    on conflict (member_id) do nothing;
  end if;

  begin
    perform enqueue_member_email(
      v_member.id,
      'member_welcome',
      'member_welcome:' || v_member.id::text,
      jsonb_build_object(
        'full_name',  v_member.full_name,
        'member_no',  v_member.member_no,
        'card_token', new.qr_token,
        -- Null when they already had one; the template then omits the block
        -- rather than printing an empty box.
        'code',       v_code
      )
    );
  exception when others then
    raise warning 'welcome email not queued for % — %', v_member.id, sqlerrm;
  end;

  return new;
end;
$$;
