-- ─────────────────────────────────────────────────────────────────────────────
-- 0081 — send a Muse her welcome again
--
-- Post goes missing. A welcome can be accepted by the provider, recorded sent,
-- and still never arrive — a spam folder, a fresh sending domain a mailbox has
-- not learned to trust yet, a typo in an address nobody notices until she says
-- she is waiting. Until now the only answer was to erase her and start again,
-- which is a preposterous way to resend an email.
--
-- IT CANNOT BE THE SAME EMAIL, and that is the part worth being plain about.
-- muse.credentials stores a bcrypt hash and nothing else, so the code in the
-- first message is not recoverable by anyone, including us. Sending "the same
-- welcome again" is not possible; what is possible is a new code and a new
-- welcome carrying it. So this mints one, and says so in what it returns —
-- because the old code stops working the moment it runs, and whoever presses
-- the button needs to know that before they do, not after she calls.
--
-- HoSL and founder, matching who may onboard her in the first place. This is
-- the same act as onboarding minus the paperwork, and it would be strange for
-- the resend to be held to a different bar than the original.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function muse_resend_welcome(p_muse_member_id uuid)
returns jsonb
language plpgsql
volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_m muse.members%rowtype;
  v_card_token text;
  v_code text;
  v_queued uuid;
begin
  if v_role is null or v_role not in ('hosl', 'founder') then
    raise exception 'resending a Muse welcome is done by the Head of Sales or a founder';
  end if;

  select * into v_m from muse.members where id = p_muse_member_id for update;
  if not found then
    raise exception 'no such Muse member';
  end if;
  if v_m.erased_at is not null then
    raise exception 'that record has been erased';
  end if;
  if v_m.status not in ('active', 'paused') then
    raise exception '% has not been onboarded yet — approve and onboard her, and the welcome sends itself',
      v_m.full_name;
  end if;
  if not is_sendable_email(v_m.email) then
    raise exception '% is not an address we can deliver to — correct it first', v_m.email;
  end if;

  select qr_token into v_card_token
    from muse.cards where muse_member_id = v_m.id and status = 'active'
   order by issued_at desc limit 1;

  -- A new one, because the old one cannot be read back.
  v_code := gen_login_code();
  insert into muse.credentials (muse_member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (v_m.id, extensions.crypt(v_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (muse_member_id) do update
    set code_hash = excluded.code_hash, code_set_at = now(),
        failed_attempts = 0, locked_until = null, updated_at = now();

  -- The dedupe key carries the moment, or the outbox would silently swallow
  -- this as a duplicate of the welcome that never arrived — which is precisely
  -- the failure being recovered from.
  v_queued := enqueue_muse_email(
    v_m.id, 'member_welcome',
    'muse_welcome_resend:' || v_m.id::text || ':' || extract(epoch from clock_timestamp())::bigint::text,
    jsonb_build_object(
      'full_name',  v_m.full_name,
      'muse_no',    v_m.muse_no,
      'card_token', v_card_token,
      'code',       v_code
    )
  );

  perform log_audit('staff', auth.uid(), 'muse.welcome.resend',
                    'muse.members', v_m.id::text, null, null,
                    jsonb_build_object('to', v_m.email));  -- never the code

  return jsonb_build_object(
    'muse_no', v_m.muse_no,
    'full_name', v_m.full_name,
    'to', v_m.email,
    'queued', v_queued is not null,
    'login_code', v_code,
    'detail', 'A new sign-in code has been issued and her welcome is queued. '
              || 'Any code she was given before this no longer works.');
end;
$$;

revoke execute on function muse_resend_welcome(uuid) from public, anon;
grant  execute on function muse_resend_welcome(uuid) to authenticated;
