-- ============================================================================
-- 0042 — Transactional email: a durable outbox, and the two things that fill it.
--
-- Members hand over an email address at the door and have never once heard from
-- us at it. This wires the two moments that are genuinely about their own
-- account: the welcome when they join, and the note when their tier goes up.
--
-- Both are TRANSACTIONAL — service messages about a membership the person just
-- asked for — so they do not require marketing_email consent, which nothing
-- records today anyway. Anything promotional (events, offers, newsletters) must
-- gate on that consent and does not belong in this table's triggers.
--
-- Mail goes through an OUTBOX rather than being sent inline. A trigger that
-- called an email API directly would hold the door's registration transaction
-- open on a third-party HTTP call, and would lose the message entirely if that
-- call failed. A row in a table survives a provider outage, a redeploy, and a
-- retry, and leaves the team a record of what was sent to whom.
-- ============================================================================

create type email_template as enum ('member_welcome', 'tier_upgraded');
create type email_status   as enum ('queued', 'sending', 'sent', 'failed', 'skipped');

create table email_outbox (
  id                  uuid primary key default gen_random_uuid(),
  member_id           uuid references members(id) on delete set null,
  to_email            text not null,
  template            email_template not null,
  payload             jsonb not null default '{}'::jsonb,
  -- One row per real-world event. The unique index is the whole idempotency
  -- story: a replacement card, a re-run trigger or a retried transaction can
  -- never produce a second welcome.
  dedupe_key          text not null unique,
  status              email_status not null default 'queued',
  attempts            int not null default 0,
  last_error          text,
  provider_message_id text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  sent_at             timestamptz
);

create index email_outbox_pending_idx
  on email_outbox (status, created_at)
  where status in ('queued', 'failed');

create trigger email_outbox_touch
  before update on email_outbox
  for each row execute function touch_updated_at();

alter table email_outbox enable row level security;

-- Staff can see what the house has sent; nobody writes directly.
create policy email_outbox_staff_read on email_outbox for select to authenticated
  using (is_manager_up());
revoke insert, update, delete on email_outbox from anon, authenticated;

-- ── Which addresses are real ────────────────────────────────────────────────
-- Twenty-four of twenty-six members carry @placeholder.kamadeva.dev seed
-- addresses. Mailing those would hard-bounce, and a bounce rate like that costs
-- a sending domain its reputation long before anyone notices. Unsendable
-- addresses are still recorded, as 'skipped' — silence with a reason beats an
-- empty table when someone asks why a member heard nothing.
create or replace function is_sendable_email(p_email text)
returns boolean
language sql
immutable
as $$
  select p_email is not null
     and p_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     and lower(split_part(p_email, '@', 2)) not in (
       'placeholder.kamadeva.dev', 'example.com', 'example.org', 'example.net',
       'kamadeva.dev', 'test.com', 'localhost'
     )
     and lower(split_part(p_email, '@', 2)) !~ '\.(test|local|invalid|localhost|example)$';
$$;

-- ── Enqueueing ──────────────────────────────────────────────────────────────

create or replace function enqueue_member_email(
  p_member_id  uuid,
  p_template   email_template,
  p_dedupe_key text,
  p_payload    jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_email text;
  v_id uuid;
begin
  select email into v_email from members where id = p_member_id;
  if v_email is null then
    return null;
  end if;

  insert into email_outbox (member_id, to_email, template, payload, dedupe_key, status, last_error)
  values (
    p_member_id, v_email, p_template, coalesce(p_payload, '{}'::jsonb), p_dedupe_key,
    (case when is_sendable_email(v_email) then 'queued' else 'skipped' end)::email_status,
    case when is_sendable_email(v_email) then null
         else 'address is a placeholder or non-deliverable domain' end
  )
  on conflict (dedupe_key) do nothing
  returning id into v_id;

  return v_id;
end;
$$;

-- ── Welcome ─────────────────────────────────────────────────────────────────
-- Fires on the card, not on the member row: register_guest inserts the member
-- first and the card last, so a trigger on members would run before the card
-- exists and could not put it in the email. A reissued card cannot produce a
-- second welcome — the dedupe key is per member, not per card.

create or replace function on_prive_card_issued()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_member members%rowtype;
begin
  if new.kind <> 'prive' then
    return new;
  end if;

  select * into v_member from members where id = new.member_id;
  if not found then
    return new;
  end if;

  -- Never let email get between a guest and the door. Anything that goes wrong
  -- here is logged and swallowed; the registration still stands.
  begin
    perform enqueue_member_email(
      v_member.id,
      'member_welcome',
      'member_welcome:' || v_member.id::text,
      jsonb_build_object(
        'full_name',  v_member.full_name,
        'member_no',  v_member.member_no,
        'card_token', new.qr_token
      )
    );
  exception when others then
    raise warning 'welcome email not queued for % — %', v_member.id, sqlerrm;
  end;

  return new;
end;
$$;

create trigger member_cards_welcome_email
  after insert on member_cards
  for each row execute function on_prive_card_issued();

-- ── Tier upgrades ───────────────────────────────────────────────────────────
-- Only upward moves. tier_events also records decay and downgrades, and an
-- unprompted "your tier has dropped" email is a worse experience than silence —
-- that conversation belongs to the house, in person.

create or replace function on_tier_event_email()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_member members%rowtype;
  v_from int;
  v_to   int;
begin
  select enumsortorder into v_from from pg_enum e join pg_type t on t.oid = e.enumtypid
   where t.typname = 'tier_enum' and e.enumlabel = new.from_tier::text;
  select enumsortorder into v_to from pg_enum e join pg_type t on t.oid = e.enumtypid
   where t.typname = 'tier_enum' and e.enumlabel = new.to_tier::text;

  if v_from is null or v_to is null or v_to <= v_from then
    return new;
  end if;

  select * into v_member from members where id = new.member_id;
  if not found then
    return new;
  end if;

  begin
    perform enqueue_member_email(
      v_member.id,
      'tier_upgraded',
      'tier_upgraded:' || new.id::text,
      jsonb_build_object(
        'full_name', v_member.full_name,
        'member_no', v_member.member_no,
        'from_tier', new.from_tier::text,
        'to_tier',   new.to_tier::text
      )
    );
  exception when others then
    raise warning 'tier email not queued for % — %', new.member_id, sqlerrm;
  end;

  return new;
end;
$$;

create trigger tier_events_upgrade_email
  after insert on tier_events
  for each row execute function on_tier_event_email();

-- ── Draining, for the sender ────────────────────────────────────────────────
-- service_role only: these are called by the send-emails Edge Function and by
-- nothing else. Access is controlled by the grants below rather than a role
-- check in the body, matching how the login helpers are locked down.

create or replace function email_outbox_claim(p_limit int default 20)
returns setof email_outbox
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  return query
  update email_outbox o
     set status = 'sending', attempts = o.attempts + 1
   where o.id in (
     select c.id from email_outbox c
      where c.status = 'queued'
         -- Give a failure room to be transient, but stop after five tries so a
         -- permanently bad address is not retried forever.
         or (c.status = 'failed' and c.attempts < 5 and c.updated_at < now() - interval '15 minutes')
      order by c.created_at
      limit greatest(coalesce(p_limit, 20), 1)
      for update skip locked
   )
  returning o.*;
end;
$$;

create or replace function email_outbox_mark(
  p_id          uuid,
  p_status      email_status,
  p_message_id  text default null,
  p_error       text default null
)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update email_outbox
     set status = p_status,
         provider_message_id = coalesce(p_message_id, provider_message_id),
         last_error = p_error,
         sent_at = case when p_status = 'sent' then now() else sent_at end
   where id = p_id;
$$;

revoke execute on function email_outbox_claim(int)                      from public, anon, authenticated;
revoke execute on function email_outbox_mark(uuid, email_status, text, text) from public, anon, authenticated;
grant  execute on function email_outbox_claim(int)                      to service_role;
grant  execute on function email_outbox_mark(uuid, email_status, text, text) to service_role;

-- enqueue_member_email is reachable only from the triggers above, which run as
-- definer; no client role needs it.
revoke execute on function enqueue_member_email(uuid, email_template, text, jsonb)
  from public, anon, authenticated;
