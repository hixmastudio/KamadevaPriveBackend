-- ============================================================================
-- 0064 — A Muse can recover her code too.
--
-- 0063 gave Privé members a reset by emailed link and left Muse with nothing:
-- muse.credentials had set_my_muse_code for someone already signed in, and no
-- way back for someone who was not. She could only ask the Head of Service &
-- Loyalty — which for an invitation-only programme run on least visibility is
-- exactly the conversation nobody wants to have over a forgotten number.
--
-- The outbox already stores the destination address on the row, so the drain
-- never asks who a message belongs to. Reaching Muse therefore needs one
-- nullable column, not a second mailing system.
--
-- Both tables get the same shape: two optional owners, at most one set. A CHECK
-- rather than a convention, because "exactly one of these" is the sort of rule
-- that quietly stops being true.
-- ============================================================================

alter table email_outbox
  add column if not exists muse_member_id uuid references muse.members (id) on delete set null;

alter table email_outbox drop constraint if exists email_outbox_one_owner;
alter table email_outbox add constraint email_outbox_one_owner
  check (num_nonnulls(member_id, muse_member_id) <= 1);

alter table member_code_resets alter column member_id drop not null;
alter table member_code_resets
  add column if not exists muse_member_id uuid references muse.members (id) on delete cascade;

alter table member_code_resets drop constraint if exists member_code_resets_one_owner;
alter table member_code_resets add constraint member_code_resets_one_owner
  check (num_nonnulls(member_id, muse_member_id) = 1);

create index if not exists member_code_resets_muse_idx
  on member_code_resets (muse_member_id, created_at desc);

-- ── Reaching her ────────────────────────────────────────────────────────────

create or replace function enqueue_muse_email(
  p_muse_member_id uuid,
  p_template       email_template,
  p_dedupe_key     text,
  p_payload        jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_email text;
  v_id    uuid;
begin
  select email into v_email from muse.members where id = p_muse_member_id;
  if v_email is null then
    return null;
  end if;

  insert into email_outbox (muse_member_id, to_email, template, payload, dedupe_key, status, last_error)
  values (
    p_muse_member_id, v_email, p_template, coalesce(p_payload, '{}'::jsonb), p_dedupe_key,
    (case when is_sendable_email(v_email) then 'queued' else 'skipped' end)::email_status,
    case when is_sendable_email(v_email) then null
         else 'address is a placeholder or non-deliverable domain' end
  )
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  return v_id;
end;
$$;

-- ── Requesting ──────────────────────────────────────────────────────────────

create or replace function request_muse_code_reset(p_identifier text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_id     text := trim(coalesce(p_identifier, ''));
  v_muse   muse.members%rowtype;
  v_token  text;
  v_recent int;
begin
  if v_id like '%@%' then
    select * into v_muse from muse.members
     where lower(email) = lower(v_id) and status = 'active';
  else
    begin
      select * into v_muse from muse.members
       where phone = normalize_phone(v_id) and status = 'active';
    exception when others then
      v_muse := null;
    end;
  end if;

  if v_muse.id is not null and is_sendable_email(v_muse.email) then
    select count(*) into v_recent from member_code_resets
     where muse_member_id = v_muse.id and created_at > now() - interval '1 hour';

    if v_recent < 5 then
      v_token := encode(extensions.gen_random_bytes(32), 'hex');
      insert into member_code_resets (muse_member_id, token_hash, expires_at)
      values (v_muse.id, encode(extensions.digest(v_token, 'sha256'), 'hex'),
              now() + interval '30 minutes');

      perform enqueue_muse_email(
        v_muse.id,
        'code_reset',
        'code_reset:' || left(encode(extensions.digest(v_token, 'sha256'), 'hex'), 24),
        jsonb_build_object(
          'full_name', v_muse.full_name,
          'member_no', v_muse.muse_no,
          'token',     v_token,
          'minutes',   '30'
        )
      );
    end if;
  end if;

  -- Identical answer either way, and more pointedly than for Privé: confirming
  -- that an address is on the Muse register would disclose membership of an
  -- invitation-only programme to anyone who could guess an email address.
  return jsonb_build_object(
    'ok', true,
    'message', 'If that phone or email is on the register, a link is on its way.'
  );
end;
$$;

-- ── Redeeming, for either programme ─────────────────────────────────────────
-- One function: the token already says who it belongs to, so the page that
-- redeems it does not need to know, and cannot get it wrong.

drop function if exists redeem_member_code_reset(text, text);

create or replace function redeem_code_reset(p_token text, p_new_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_hash text := encode(extensions.digest(trim(coalesce(p_token, '')), 'sha256'), 'hex');
  v_row  member_code_resets%rowtype;
begin
  if p_new_code !~ '^[0-9]{6}$' then
    raise exception 'your code must be exactly 6 digits';
  end if;

  select * into v_row from member_code_resets
   where token_hash = v_hash and used_at is null and expires_at > now()
   for update;
  if not found then
    raise exception 'that link has expired or has already been used — ask for a new one';
  end if;

  if v_row.member_id is not null then
    insert into member_credentials (member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
    values (v_row.member_id, extensions.crypt(p_new_code, extensions.gen_salt('bf')), now(), 0, null, now())
    on conflict (member_id) do update
      set code_hash = excluded.code_hash, code_set_at = now(),
          failed_attempts = 0, locked_until = null, updated_at = now();
  else
    insert into muse.credentials (muse_member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
    values (v_row.muse_member_id, extensions.crypt(p_new_code, extensions.gen_salt('bf')), now(), 0, null, now())
    on conflict (muse_member_id) do update
      set code_hash = excluded.code_hash, code_set_at = now(),
          failed_attempts = 0, locked_until = null, updated_at = now();
  end if;

  update member_code_resets set used_at = now() where id = v_row.id;
  update member_code_resets set used_at = now()
   where used_at is null and id <> v_row.id
     and (   (v_row.member_id      is not null and member_id      = v_row.member_id)
          or (v_row.muse_member_id is not null and muse_member_id = v_row.muse_member_id));

  perform log_audit(
    p_actor_type  => 'member'::actor_type,
    p_actor_id    => coalesce(v_row.member_id, v_row.muse_member_id),
    p_action      => 'member.code.reset',
    p_entity_type => case when v_row.member_id is not null then 'members' else 'muse.members' end,
    p_entity_id   => coalesce(v_row.member_id, v_row.muse_member_id)::text
  );

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function request_muse_code_reset(text) to anon, authenticated;
grant execute on function redeem_code_reset(text, text) to anon, authenticated;
