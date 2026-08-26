-- ============================================================================
-- 0040 — In-app member notifications.
--
-- Staff push updates (events, rewards, account notes) that members see behind
-- the bell in the mobile app and portal. Rows are either targeted at one
-- member — Privé (public.members) or standalone Muse (muse.members) — or
-- broadcast to an audience ('all' | 'prive' | 'muse').
--
-- Reads go through RLS (members see exactly their own feed); writes go only
-- through the staff-guarded RPCs below, per the house rule that the anon/
-- authenticated roles never hold direct DML. Guards follow 0025: deny the
-- NULL-role caller explicitly (fail-closed).
-- ============================================================================

create table member_notifications (
  id uuid primary key default gen_random_uuid(),
  -- Exactly one target column is set for audience='member'; both NULL for
  -- broadcasts (enforced below).
  member_id uuid references members(id) on delete cascade,
  muse_member_id uuid references muse.members(id) on delete cascade,
  audience text not null default 'member'
    check (audience in ('member', 'all', 'prive', 'muse')),
  kind text not null default 'general'
    check (kind in ('event', 'reward', 'account', 'general')),
  title text not null check (length(trim(title)) between 1 and 140),
  body text check (body is null or length(body) <= 1000),
  created_by uuid references staff_profiles(id),
  created_at timestamptz not null default now(),
  constraint member_notifications_target check (
    case when audience = 'member'
      then (member_id is not null) <> (muse_member_id is not null)  -- exactly one
      else member_id is null and muse_member_id is null
    end
  )
);

create index member_notifications_member_idx
  on member_notifications (member_id, created_at desc);
create index member_notifications_muse_idx
  on member_notifications (muse_member_id, created_at desc);
create index member_notifications_audience_idx
  on member_notifications (audience, created_at desc);

alter table member_notifications enable row level security;

-- Members read exactly their own feed: rows targeted at them, plus broadcasts
-- for a programme they belong to. One person can be both (docs §3) — each
-- signed-in identity resolves independently.
create policy notif_self_read on member_notifications for select to authenticated
  using (
    member_id = current_member_id()
    or muse_member_id = current_muse_member_id()
    or (audience in ('all', 'prive') and current_member_id() is not null)
    or (audience in ('all', 'muse') and current_muse_member_id() is not null)
  );

create policy notif_staff_read on member_notifications for select to authenticated
  using (is_staff());

revoke insert, update, delete on member_notifications from anon, authenticated;

-- ── Send: any active staff member may notify a single member ───────────────

create or replace function send_member_notification(
  p_member_id uuid,
  p_kind text,
  p_title text,
  p_body text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_id uuid;
begin
  if v_staff is null then
    raise exception 'staff sign-in required';
  end if;
  insert into member_notifications (member_id, audience, kind, title, body, created_by)
  values (p_member_id, 'member', p_kind, trim(p_title), nullif(trim(p_body), ''), v_staff)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function send_muse_notification(
  p_muse_member_id uuid,
  p_kind text,
  p_title text,
  p_body text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_id uuid;
begin
  if v_staff is null then
    raise exception 'staff sign-in required';
  end if;
  insert into member_notifications (muse_member_id, audience, kind, title, body, created_by)
  values (p_muse_member_id, 'member', p_kind, trim(p_title), nullif(trim(p_body), ''), v_staff)
  returning id into v_id;
  return v_id;
end;
$$;

-- ── Broadcast: venue managers and above ────────────────────────────────────

create or replace function broadcast_notification(
  p_audience text,
  p_kind text,
  p_title text,
  p_body text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_id uuid;
begin
  if v_staff is null or not coalesce(is_manager_up(), false) then
    raise exception 'venue manager or above required';
  end if;
  if p_audience not in ('all', 'prive', 'muse') then
    raise exception 'audience must be all, prive or muse';
  end if;
  insert into member_notifications (audience, kind, title, body, created_by)
  values (p_audience, p_kind, trim(p_title), nullif(trim(p_body), ''), v_staff)
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function
  send_member_notification(uuid, text, text, text),
  send_muse_notification(uuid, text, text, text),
  broadcast_notification(text, text, text, text)
to authenticated;

revoke execute on function
  send_member_notification(uuid, text, text, text),
  send_muse_notification(uuid, text, text, text),
  broadcast_notification(text, text, text, text)
from public, anon;
