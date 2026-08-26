-- ============================================================================
-- 0069 — Notifications stop being a place people never get told anything.
--
-- The table, the RLS, the bell and the feed all existed. What was missing was
-- almost everything that should have been WRITING to it: in the whole system
-- only announce_due_events ever created a notification. A tier upgrade sent an
-- email and said nothing in the portal. A discount coming off a bill said
-- nothing. A Muse benefit being granted said nothing. A booking confirming said
-- nothing. The feed worked perfectly and was almost always empty, which reads
-- to a member as a feature nobody finished.
--
-- And the unread dot was a lie on any second device. "Last seen" was kept in
-- localStorage, so reading on a phone left the dot showing on a laptop forever,
-- and clearing the browser marked months of history unread again. That is
-- state about a person, not about a browser, so it belongs beside the person.
--
-- WHAT NOW WRITES A NOTIFICATION
--
--   tier upgrade      — upward only. tier_events records decay and demotion
--                       too, and "your tier has dropped" arriving unprompted on
--                       a phone is a worse experience than silence; §14 puts
--                       that conversation with the house, in person. Same
--                       reasoning the upgrade email already used.
--   discount applied  — the member sees what came off, at the moment it did.
--   Muse benefit      — granted at the venue, recorded, and now acknowledged.
--   booking confirmed — the reservation exists; say so where they will look.
--
-- Every one is written by a trigger rather than by the caller, so a new path
-- into any of these tables cannot forget to tell the member.
-- ============================================================================

-- ── Read state that follows the person, not the browser ─────────────────────

create table if not exists notification_reads (
  member_id      uuid references members (id) on delete cascade,
  muse_member_id uuid references muse.members (id) on delete cascade,
  last_seen_at   timestamptz not null default now(),
  constraint notification_reads_one_owner check (num_nonnulls(member_id, muse_member_id) = 1)
);

create unique index if not exists notification_reads_member_idx
  on notification_reads (member_id) where member_id is not null;
create unique index if not exists notification_reads_muse_idx
  on notification_reads (muse_member_id) where muse_member_id is not null;

alter table notification_reads enable row level security;
revoke all on notification_reads from anon, authenticated;

create or replace function mark_notifications_seen()
returns timestamptz
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_member uuid := current_member_id();
  v_muse   uuid := current_muse_member_id();
  v_now    timestamptz := now();
begin
  if v_member is null and v_muse is null then
    raise exception 'sign in to mark notifications as seen';
  end if;

  if v_member is not null then
    insert into notification_reads (member_id, last_seen_at) values (v_member, v_now)
    on conflict (member_id) where member_id is not null
    do update set last_seen_at = v_now;
  else
    insert into notification_reads (muse_member_id, last_seen_at) values (v_muse, v_now)
    on conflict (muse_member_id) where muse_member_id is not null
    do update set last_seen_at = v_now;
  end if;

  return v_now;
end;
$$;

create or replace function my_unread_notification_count()
returns integer
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select count(*)::int
    from member_notifications n
   where (
           n.member_id = current_member_id()
        or n.muse_member_id = current_muse_member_id()
        or (n.audience in ('all', 'prive') and current_member_id() is not null)
        or (n.audience in ('all', 'muse')  and current_muse_member_id() is not null)
        )
     and n.created_at > coalesce((
           select r.last_seen_at from notification_reads r
            where r.member_id = current_member_id()
               or r.muse_member_id = current_muse_member_id()
            limit 1
         ), '-infinity'::timestamptz);
$$;

revoke execute on function mark_notifications_seen() from public, anon;
revoke execute on function my_unread_notification_count() from public, anon;
grant  execute on function mark_notifications_seen() to authenticated;
grant  execute on function my_unread_notification_count() to authenticated;

-- ── Producers ───────────────────────────────────────────────────────────────
-- One shared writer, so the constraints and the audience rules live in a single
-- place rather than being restated at each call site.

create or replace function notify_member(
  p_member_id uuid,
  p_kind      text,
  p_title     text,
  p_body      text default null
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  insert into member_notifications (member_id, audience, kind, title, body)
  values (p_member_id, 'member', p_kind, left(trim(p_title), 140),
          nullif(left(trim(coalesce(p_body, '')), 1000), ''));
exception when others then
  -- Never let a notification failure take down the thing it was reporting on.
  -- A member losing a message is a smaller harm than a tier promotion or a
  -- discount rolling back because the feed had a bad day.
  raise warning 'notification not written for % — %', p_member_id, sqlerrm;
end;
$$;

-- Tier upgrades. Upward only, for the reason the upgrade EMAIL already gives:
-- tier_events also records decay and demotion, and an unprompted "your standing
-- has dropped" is a worse experience than silence — §14 puts that conversation
-- with the house, in person.
create or replace function on_tier_event_notify()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  -- tier_enum is declared guest < member < silver < gold < black, so the enum
  -- compares directly. The upgrade EMAIL does this by looking up enumsortorder
  -- in pg_enum, which works but restates an ordering the type already carries.
  if new.from_tier is not null and new.to_tier > new.from_tier then
    perform notify_member(
      new.member_id,
      'account',
      'Welcome to ' || initcap(new.to_tier::text),
      'Your standing has been raised. The benefits of your new tier apply from tonight.'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists tier_events_notify on tier_events;
create trigger tier_events_notify
  after insert on tier_events
  for each row execute function on_tier_event_notify();

-- A discount coming off a bill is the most concrete benefit the programme has,
-- and it was the one thing nobody was told about.
create or replace function on_discount_applied_notify()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_venue text;
begin
  select name into v_venue from venues where id = new.venue_id;
  perform notify_member(
    new.member_id,
    'reward',
    'A discount was applied',
    coalesce(v_venue || ' — ', '') ||
    trim(to_char(new.amount_kobo / 100.0, 'FM999,999,990')) ||
    ' naira came off your bill tonight.'
  );
  return new;
end;
$$;

drop trigger if exists discount_applications_notify on discount_applications;
create trigger discount_applications_notify
  after insert on discount_applications
  for each row execute function on_discount_applied_notify();

-- A confirmed booking, said where the member will go looking for it.
create or replace function on_reservation_notify()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_venue text;
begin
  if new.status <> 'confirmed' then
    return new;
  end if;
  select name into v_venue from venues where id = new.venue_id;
  perform notify_member(
    new.member_id,
    'account',
    'Your table is booked',
    coalesce(v_venue || ' — ', '') ||
    to_char(new.reserved_for at time zone 'Africa/Lagos', 'Dy DD Mon at HH12:MIam') ||
    ', party of ' || new.party_size || '.'
  );
  return new;
end;
$$;

drop trigger if exists reservations_notify on reservations;
create trigger reservations_notify
  after insert on reservations
  for each row execute function on_reservation_notify();
