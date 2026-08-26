-- ─────────────────────────────────────────────────────────────────────────────
-- 0082 — correcting an address that was written down wrong
--
-- Someone is registered at the door in under a minute, at night, and a letter
-- gets missed. What happens next is worse than a typo, because the welcome has
-- already gone — carrying a working sign-in code — to whoever does own that
-- address. Correcting the spelling does not take it back. Until now:
--
--   · a Privé member's email could be edited (update_member_profile), but the
--     code already delivered elsewhere kept working, and nothing checked
--     whether the new address already belonged to somebody else;
--   · a Muse's email could not be changed at all. Nothing existed.
--
-- So correcting an address is treated as what it is — a possible disclosure —
-- and does three things at once: fixes the address, kills the code that went to
-- the wrong one, and sends a fresh welcome to the right one.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Nobody else's address ───────────────────────────────────────────────────
-- members.email has no unique constraint — only phone and member_no do — and
-- verify_member_login matches on email with LIMIT 1. Two active members sharing
-- an address therefore means one of them silently cannot sign in, and which one
-- depends on row order. Guarded here rather than by adding the constraint,
-- because a hard index would start rejecting registrations at the door for a
-- couple who share a mailbox, and opening night is the wrong time to discover
-- that rule.
create or replace function email_is_free(p_email text, p_except_member uuid default null,
                                         p_except_muse uuid default null)
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select not exists (
    select 1 from members m
     where lower(m.email) = lower(trim(p_email)) and m.status = 'active'
       and (p_except_member is null or m.id <> p_except_member)
    union all
    select 1 from muse.members mm
     where lower(mm.email) = lower(trim(p_email)) and mm.erased_at is null
       and (p_except_muse is null or mm.id <> p_except_muse)
  );
$$;

revoke execute on function email_is_free(text, uuid, uuid) from public, anon;
grant  execute on function email_is_free(text, uuid, uuid) to authenticated;

-- ── A Privé member ──────────────────────────────────────────────────────────
create or replace function correct_member_email(
  p_member_id uuid,
  p_email text,
  p_resend boolean default true
)
returns jsonb
language plpgsql
volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_m members%rowtype;
  v_email text := lower(trim(coalesce(p_email, '')));
  v_old text;
  v_code text;
  v_card text;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'correcting an address requires a venue manager or above';
  end if;
  if v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'that is not a valid email address';
  end if;

  select * into v_m from members where id = p_member_id and status = 'active';
  if not found then
    raise exception 'member not found';
  end if;
  if lower(v_m.email) = v_email then
    raise exception 'that is already their address';
  end if;
  if not email_is_free(v_email, p_member_id, null) then
    raise exception 'another member is already registered with that address';
  end if;

  v_old := v_m.email;
  update members set email = v_email where id = p_member_id;

  -- The null is p_venue_id; before/after follow it. Correcting an address is
  -- not a venue's act.
  perform log_audit('staff', auth.uid(), 'member.email.correct', 'members', p_member_id::text,
                    null, jsonb_build_object('email', v_old), jsonb_build_object('email', v_email));

  if not p_resend then
    return jsonb_build_object('member_no', v_m.member_no, 'full_name', v_m.full_name,
      'from', v_old, 'to', v_email, 'code_reset', false,
      'detail', 'Address corrected. Their existing code still works — including the copy sent to '
                || v_old || ', if that address belongs to somebody else.');
  end if;

  -- The old address received a working code. Correcting the spelling does not
  -- take that back, so the code is replaced and the new one goes to the new
  -- address only.
  v_code := gen_login_code();
  insert into member_credentials (member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (p_member_id, extensions.crypt(v_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (member_id) do update
    set code_hash = excluded.code_hash, code_set_at = now(),
        failed_attempts = 0, locked_until = null, updated_at = now();

  select qr_token into v_card from member_cards
   where member_id = p_member_id and status = 'active'
   order by issued_at desc limit 1;

  perform enqueue_member_email(
    p_member_id, 'member_welcome',
    'member_welcome_recorrect:' || p_member_id::text || ':' || extract(epoch from clock_timestamp())::bigint::text,
    jsonb_build_object('full_name', v_m.full_name, 'member_no', v_m.member_no,
                       'card_token', v_card, 'code', v_code));

  return jsonb_build_object('member_no', v_m.member_no, 'full_name', v_m.full_name,
    'from', v_old, 'to', v_email, 'code_reset', true, 'login_code', v_code,
    'detail', 'Address corrected and a new welcome sent. The code that went to ' || v_old
              || ' no longer works.');
end;
$$;

revoke execute on function correct_member_email(uuid, text, boolean) from public, anon;
grant  execute on function correct_member_email(uuid, text, boolean) to authenticated;

-- ── A Muse ──────────────────────────────────────────────────────────────────
-- Same act, same reasoning, held to the pair who may onboard her.
create or replace function muse_correct_email(
  p_muse_member_id uuid,
  p_email text,
  p_resend boolean default true
)
returns jsonb
language plpgsql
volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_m muse.members%rowtype;
  v_email text := lower(trim(coalesce(p_email, '')));
  v_old text;
  v_code text;
  v_card text;
begin
  if v_role is null or v_role not in ('hosl', 'founder') then
    raise exception 'correcting a Muse address is done by the Head of Sales or a founder';
  end if;
  if v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'that is not a valid email address';
  end if;

  select * into v_m from muse.members where id = p_muse_member_id for update;
  if not found then
    raise exception 'no such Muse member';
  end if;
  if v_m.erased_at is not null then
    raise exception 'that record has been erased';
  end if;
  if lower(v_m.email) = v_email then
    raise exception 'that is already her address';
  end if;
  if not email_is_free(v_email, null, p_muse_member_id) then
    raise exception 'that address already belongs to someone on the register';
  end if;

  v_old := v_m.email;
  update muse.members set email = v_email, updated_at = now() where id = p_muse_member_id;

  perform log_audit('staff', auth.uid(), 'muse.email.correct', 'muse.members', p_muse_member_id::text,
                    null, jsonb_build_object('email', v_old), jsonb_build_object('email', v_email));

  -- A candidate has no code and no card yet, so there is nothing sent to the
  -- wrong address to take back and nothing to welcome her to.
  if not p_resend or v_m.status not in ('active', 'paused') then
    return jsonb_build_object('muse_no', v_m.muse_no, 'full_name', v_m.full_name,
      'from', v_old, 'to', v_email, 'code_reset', false,
      'detail', case when v_m.status in ('active','paused')
                     then 'Address corrected. Her existing code still works, including any copy sent to ' || v_old || '.'
                     else 'Address corrected. She has not been onboarded yet, so no code has been sent anywhere.' end);
  end if;

  v_code := gen_login_code();
  insert into muse.credentials (muse_member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (p_muse_member_id, extensions.crypt(v_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (muse_member_id) do update
    set code_hash = excluded.code_hash, code_set_at = now(),
        failed_attempts = 0, locked_until = null, updated_at = now();

  select qr_token into v_card from muse.cards
   where muse_member_id = p_muse_member_id and status = 'active'
   order by issued_at desc limit 1;

  perform enqueue_muse_email(
    p_muse_member_id, 'member_welcome',
    'muse_welcome_recorrect:' || p_muse_member_id::text || ':' || extract(epoch from clock_timestamp())::bigint::text,
    jsonb_build_object('full_name', v_m.full_name, 'muse_no', v_m.muse_no,
                       'card_token', v_card, 'code', v_code));

  return jsonb_build_object('muse_no', v_m.muse_no, 'full_name', v_m.full_name,
    'from', v_old, 'to', v_email, 'code_reset', true, 'login_code', v_code,
    'detail', 'Address corrected and a new welcome sent. The code that went to ' || v_old
              || ' no longer works.');
end;
$$;

revoke execute on function muse_correct_email(uuid, text, boolean) from public, anon;
grant  execute on function muse_correct_email(uuid, text, boolean) to authenticated;
