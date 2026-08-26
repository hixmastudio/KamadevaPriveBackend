-- ============================================================================
-- 0049 — Email members about events, where they have asked to hear from us.
--
-- 0045 announces each occurrence into the in-app feed. This adds the other
-- channel: an email, to members who have consented to marketing by email.
--
-- CONSENT IS THE WHOLE DESIGN HERE. The welcome and tier-change emails from
-- 0042 are transactional — service messages about the member's own account —
-- and rightly go out regardless. An event announcement is marketing: it is us
-- asking someone to come and spend money. The privacy policy states plainly
-- that marketing goes out "only where you have said yes" and that consent is
-- recorded separately for email and for WhatsApp, so this gates on
-- marketing_email specifically and treats WhatsApp consent as saying nothing
-- about email.
--
-- Consequence, stated rather than buried: nobody holds marketing_email today
-- (0 rows, granted or denied), so this sends to nobody until members opt in.
-- The door and the portal are updated alongside this migration to start
-- recording it. Existing members are NOT backfilled from marketing_whatsapp —
-- consent given for a named channel is not consent for another one.
--
-- email_announce is per series and defaults TRUE for one-off-feeling nights,
-- but exists so a DAILY series can keep its in-app notice while not putting
-- mail in 365 inboxes a year. In-app and email are separately controllable
-- because they cost the reader very differently.
-- ============================================================================

alter type email_template add value if not exists 'event_announced';

alter table event_series
  add column if not exists email_announce boolean not null default true;

comment on column event_series.email_announce is
  'Whether occurrences also email consented members. In-app notices are governed
   separately by announce — a daily series usually wants the feed but not the inbox.';

create or replace function announce_due_events()
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  e record;
  m record;
  v_sent int := 0;
  v_body text;
begin
  for e in
    select ev.id, ev.name, ev.starts_at, ev.description, v.name as venue_name,
           s.announce_audience, s.created_by, s.email_announce
      from events ev
      join event_series s on s.id = ev.series_id
      left join venues v on v.id = ev.venue_id
     where ev.announced_at is null
       and ev.status = 'published'
       and s.announce
       and s.status = 'published'
       and ev.starts_at >= now()
       and ev.starts_at <= now() + (s.announce_days_before || ' days')::interval
     order by ev.starts_at
     limit 200
  loop
    v_body := trim(both from
      coalesce(e.venue_name || ' · ', '') ||
      to_char(e.starts_at at time zone 'Africa/Lagos', 'Dy DD Mon, HH12:MIam'));

    insert into member_notifications (audience, kind, title, body, created_by)
    values (e.announce_audience, 'event', left(e.name, 140), v_body, e.created_by);

    -- The inbox, for those who asked for it. Muse is excluded by construction
    -- rather than by choice: email_outbox.member_id references public.members,
    -- and a standalone Muse guest has no row there. A Muse audience still gets
    -- the in-app notice above.
    if e.email_announce and e.announce_audience in ('all', 'prive') then
      for m in
        select mem.id
          from members mem
          join current_consents c
            on c.member_id = mem.id
           and c.consent_type = 'marketing_email'
           and c.granted
         where mem.status = 'active'
           and is_sendable_email(mem.email)
      loop
        -- One email per member per event, whatever else re-runs.
        perform enqueue_member_email(
          m.id,
          'event_announced',
          'event_announced:' || e.id::text || ':' || m.id::text,
          jsonb_build_object(
            'event_name',  e.name,
            'description', e.description,
            'venue_name',  e.venue_name,
            'starts_at',   e.starts_at,
            'when_label',  v_body
          )
        );
      end loop;
    end if;

    update events set announced_at = now() where id = e.id;
    v_sent := v_sent + 1;
  end loop;

  return v_sent;
end;
$$;

revoke execute on function announce_due_events() from public, anon, authenticated;
