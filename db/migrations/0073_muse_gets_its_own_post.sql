-- ─────────────────────────────────────────────────────────────────────────────
-- 0073 — Muse gets its own post
--
-- A Privé member has had a welcome email with their sign-in code since 0001. A
-- Muse never has: 6 member_welcome and 8 tier_upgraded emails have gone out,
-- all Privé, none to a Muse. The only thing that has ever reached a Muse inbox
-- is a code reset.
--
-- It was an omission, not a decision. The Privé welcome hangs off a trigger on
-- member_cards; the standalone Muse rework gave Muse its own muse.cards table,
-- and only the audit trigger was carried across. The welcome was left behind.
--
-- So: the same welcome, in her own colours, carrying her code and saying she
-- can change it — and her own nights announced to her inbox rather than only
-- in the app.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.muse_onboard(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_candidate muse.candidates%rowtype;
  v_muse muse.members%rowtype;
  v_membership_id uuid;
  v_card_id uuid;
  v_card_token text;
  v_code text;
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'Muse onboarding is done by the HoSL';
  end if;
  select * into v_candidate from muse.candidates where id = p_candidate_id for update;
  if not found or v_candidate.status != 'approved' then
    raise exception 'candidate is not approved';
  end if;
  if exists (select 1 from muse.memberships where member_id = v_candidate.member_id and status = 'active') then
    raise exception 'already onboarded';
  end if;
  select * into v_muse from muse.members where id = v_candidate.member_id;

  insert into muse.cards (muse_member_id) values (v_muse.id)
  returning id, qr_token into v_card_id, v_card_token;

  insert into muse.memberships (member_id, candidate_id, approved_via, onboarded_by, onboarded_at, card_id, status)
  values (v_muse.id, v_candidate.id, v_candidate.approval_id, current_staff_id(), now(), v_card_id, 'active')
  returning id into v_membership_id;

  update muse.members set status = 'active' where id = v_muse.id;

  v_code := gen_login_code();
  insert into muse.credentials (muse_member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (v_muse.id, extensions.crypt(v_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (muse_member_id) do update
    set code_hash = excluded.code_hash, code_set_at = now(),
        failed_attempts = 0, locked_until = null, updated_at = now();

  -- The welcome, with her code — the same courtesy a Privé member has had since
  -- 0001 and a Muse never has.
  --
  -- Sent from here rather than from a trigger on muse.cards, which is where the
  -- Privé equivalent lives. Two reasons, and both bite. The card is inserted at
  -- the top of this function, before the credential exists, so a trigger would
  -- have to mint its own code — and the insert below would immediately replace
  -- it, leaving her holding a code that no longer opens anything. And the
  -- plaintext only exists here: muse.credentials stores a bcrypt hash, so
  -- nothing downstream can recover the code to put in an email. This is the one
  -- moment it can be said.
  --
  -- Wrapped, because a mail provider having a bad afternoon must never be the
  -- reason an onboarding fails. The HoSL is standing with her when this runs and
  -- still receives the code in the return value to hand over in person.
  begin
    perform enqueue_muse_email(
      v_muse.id,
      'member_welcome',
      'muse_welcome:' || v_muse.id::text,
      jsonb_build_object(
        'full_name',  v_muse.full_name,
        'muse_no',    v_muse.muse_no,
        'card_token', v_card_token,
        'code',       v_code
      )
    );
  exception when others then
    raise warning 'Muse welcome email not queued for % — %', v_muse.id, sqlerrm;
  end;

  perform log_audit('staff', auth.uid(), 'muse.onboard', 'muse.members', v_muse.id::text);

  return jsonb_build_object(
    'membership_id', v_membership_id, 'muse_no', v_muse.muse_no,
    'full_name', v_muse.full_name, 'card_token', v_card_token, 'login_code', v_code
  );
end;
$function$;



CREATE OR REPLACE FUNCTION public.announce_due_events()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

    -- The inbox, for those who asked for it.
    --
    -- That comment used to say Muse was "excluded by construction rather than by
    -- choice: email_outbox.member_id references public.members, and a standalone
    -- Muse guest has no row there". True when it was written, and no longer: the
    -- outbox gained muse_member_id and enqueue_muse_email in the standalone Muse
    -- rework. The constraint was lifted and the code never caught up.
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

    -- Muse, for her own nights, and only those.
    --
    -- The audience split is doing real work here, not just addressing. An
    -- invitation to a Muse night is not marketing sent to a member — being
    -- invited IS the membership, which is what an invitation-only circle is for.
    -- That makes it a service message about her own standing, in the same
    -- family as the welcome above.
    --
    -- A house-wide 'all' announcement is a different thing, and is deliberately
    -- NOT sent. It is ordinary marketing, the privacy policy promises marketing
    -- only where someone has said yes, and Muse has no consent record to check:
    -- `consents` keys on public.members. Sending anyway would quietly break that
    -- promise. She still sees 'all' events in the app, where she chose to look.
    -- Opening that up needs a Muse consent trail first.
    if e.email_announce and e.announce_audience = 'muse' then
      for m in
        select mm.id
          from muse.members mm
         where mm.status = 'active'
           and is_sendable_email(mm.email)
      loop
        perform enqueue_muse_email(
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
$function$;
