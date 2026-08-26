-- ─────────────────────────────────────────────────────────────────────────────
-- 0074 — Muse profiles, and removing someone from the circle
--
-- Two gaps the founder found. A Privé member has a page of her own — tier
-- history, visits, flags — reached by tapping her name. A Muse had a row that
-- expanded in place, showing six facts, and only if she was active or paused:
-- anyone declined, exited, or still a candidate simply was not in the register
-- at all. And there was no way to remove anybody, ever.
-- ─────────────────────────────────────────────────────────────────────────────

-- When her record was erased, and why. A column rather than a status, because
-- 'exited' and 'erased' are different facts and a status can only hold one:
-- exited means she left the circle and we still know who she is; erased means
-- her details are gone. Someone can be both, in that order.
alter table muse.members add column if not exists erased_at timestamptz;
alter table muse.members add column if not exists erased_reason text;

comment on column muse.members.erased_at is
  'Set when a founder erased her personal details. The row survives because financial and audit records point at it; the person no longer does.';

-- ── The register, all of it ─────────────────────────────────────────────────
-- Was filtered to active and paused, which quietly answered a different
-- question than the one the page asks. A candidate who was declined is part of
-- the record of how the circle was decided, and the founder is exactly who is
-- entitled to see that. Status comes back with every row so the surface can
-- group them rather than the query deciding what exists.
create or replace function muse_list_members()
returns jsonb
language plpgsql
volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_result jsonb;
begin
  if v_role is null or v_role not in ('hosl', 'founder') then
    raise exception 'the Muse roster is visible to the HoSL and founders';
  end if;

  perform log_audit('staff', auth.uid(), 'muse.roster.read', 'muse.members', null);

  select coalesce(jsonb_agg(row_data order by sort_rank, sort_name), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'muse_member_id', mm.id,
      'muse_no', mm.muse_no,
      'full_name', mm.full_name,
      'phone', mm.phone,
      'email', mm.email,
      'date_of_birth', case when mm.erased_at is not null then null else mm.date_of_birth end,
      'age', case when mm.erased_at is not null or mm.date_of_birth is null then null
                  else extract(year from age(mm.date_of_birth))::int end,
      'status', mm.status,
      'erased', mm.erased_at is not null,
      'joined_at', ms.onboarded_at,
      'onboarded_by', sp.full_name,
      'has_portal', mm.auth_user_id is not null,
      'card_token', mc.qr_token,
      'visits', coalesce(t.tickets, 0),
      'spend_kobo', coalesce(t.spend, 0),
      'last_seen', t.last_seen,
      'benefits_given', coalesce(b.given, 0),
      'last_benefit_at', b.last_at
    ) as row_data,
    -- Those in the circle first; those who never made it, or have left, after.
    case mm.status when 'active' then 0 when 'paused' then 1 when 'candidate' then 2
                   when 'exited' then 3 else 4 end as sort_rank,
    mm.full_name as sort_name
    from muse.members mm
    left join muse.memberships ms on ms.member_id = mm.id and ms.status = 'active'
    left join staff_profiles sp on sp.id = ms.onboarded_by
    left join muse.cards mc on mc.muse_member_id = mm.id and mc.status = 'active'
    left join lateral (
      select count(*)::int as tickets,
             sum(pt.total_kobo)::bigint as spend,
             max(pt.occurred_at) as last_seen
      from pos_tickets pt
      where pt.muse_member_id = mm.id and pt.voided_at is null
    ) t on true
    left join lateral (
      select count(*)::int as given, max(bg.created_at) as last_at
      from muse.benefit_grants bg
      where bg.membership_id = ms.id
    ) b on true
  ) s;

  return v_result;
end;
$$;

revoke execute on function muse_list_members() from public, anon;
grant  execute on function muse_list_members() to authenticated;

-- ── One woman's page ────────────────────────────────────────────────────────
-- The Privé equivalent is assembled in the client from five table reads, which
-- it can be because those tables are readable under RLS. The muse schema is
-- not: it is RLS-on, zero-policy, grants revoked, reachable only through
-- SECURITY DEFINER functions. So the page is assembled here instead, and the
-- read is logged — which the roster already does, and which §4 of the
-- governance document asks for on every look at a Muse record.
create or replace function muse_member_profile(p_muse_member_id uuid)
returns jsonb
language plpgsql
volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_m muse.members%rowtype;
  v_result jsonb;
begin
  if v_role is null or v_role not in ('hosl', 'founder') then
    raise exception 'Muse records are visible to the HoSL and founders';
  end if;

  select * into v_m from muse.members where id = p_muse_member_id;
  if not found then
    return null;
  end if;

  perform log_audit('staff', auth.uid(), 'muse.profile.read',
                    'muse.members', p_muse_member_id::text);

  select jsonb_build_object(
    'muse_member_id', v_m.id,
    'muse_no', v_m.muse_no,
    'full_name', v_m.full_name,
    'first_name', v_m.first_name,
    'last_name', v_m.last_name,
    'phone', v_m.phone,
    'email', v_m.email,
    'instagram_handle', v_m.instagram_handle,
    'date_of_birth', case when v_m.erased_at is not null then null else v_m.date_of_birth end,
    'age', case when v_m.erased_at is not null or v_m.date_of_birth is null then null
                else extract(year from age(v_m.date_of_birth))::int end,
    'status', v_m.status,
    'erased', v_m.erased_at is not null,
    'erased_at', v_m.erased_at,
    'erased_reason', v_m.erased_reason,
    'created_at', v_m.created_at,
    'has_portal', v_m.auth_user_id is not null,

    'membership', (
      select jsonb_build_object(
        'id', ms.id, 'status', ms.status, 'onboarded_at', ms.onboarded_at,
        'onboarded_by', (select full_name from staff_profiles where id = ms.onboarded_by))
      from muse.memberships ms
      where ms.member_id = v_m.id order by ms.onboarded_at desc nulls last limit 1),

    -- How she was decided: who put her forward, on what grounds, who approved.
    -- This is the part of a Muse record that has no Privé equivalent, and the
    -- part the governance document is most particular about.
    'candidacy', (
      select jsonb_build_object(
        'rationale', mc.rationale, 'status', mc.status, 'created_at', mc.created_at,
        'initiated_by', (select full_name from staff_profiles where id = mc.initiated_by),
        'initiator_role', mc.initiator_role_snapshot)
      from muse.candidates mc
      where mc.member_id = v_m.id order by mc.created_at desc limit 1),

    'card', (
      select jsonb_build_object('qr_token', c.qr_token, 'status', c.status,
                                'issued_at', c.issued_at, 'revoked_at', c.revoked_at)
      from muse.cards c where c.muse_member_id = v_m.id
      order by (c.status = 'active') desc, c.issued_at desc limit 1),

    'totals', (
      select jsonb_build_object(
        'tickets', coalesce(count(*), 0),
        'spend_kobo', coalesce(sum(pt.total_kobo), 0),
        'last_seen', max(pt.occurred_at))
      from pos_tickets pt
      where pt.muse_member_id = v_m.id and pt.voided_at is null),

    'arrivals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'occurred_at', a.occurred_at, 'venue', v.name, 'channel', a.capture_channel)
        order by a.occurred_at desc)
      from (select * from muse.arrivals where muse_member_id = v_m.id
             order by occurred_at desc limit 15) a
      left join venues v on v.id = a.venue_id), '[]'::jsonb),

    'tickets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ticket_no', pt.ticket_no, 'occurred_at', pt.occurred_at,
        'total_kobo', pt.total_kobo, 'venue', v.name)
        order by pt.occurred_at desc)
      from (select * from pos_tickets where muse_member_id = v_m.id and voided_at is null
             order by occurred_at desc limit 10) pt
      left join venues v on v.id = pt.venue_id), '[]'::jsonb),

    'benefits', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', bg.type, 'value_kobo', bg.value_kobo,
        'created_at', bg.created_at, 'venue', v.name)
        order by bg.created_at desc)
      from (select bg.* from muse.benefit_grants bg
              join muse.memberships ms on ms.id = bg.membership_id
             where ms.member_id = v_m.id
             order by bg.created_at desc limit 15) bg
      left join venues v on v.id = bg.venue_id), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function muse_member_profile(uuid) from public, anon;
grant  execute on function muse_member_profile(uuid) to authenticated;

-- ── Removing someone from the circle ────────────────────────────────────────
-- The founder asked to be able to delete a Muse account. This does not delete
-- the row, and the reason is not caution — it is that the database refuses.
-- Five things reference muse.members with ON DELETE RESTRICT: pos_tickets,
-- muse.arrivals, muse.cards, muse.candidates and muse.memberships. A DELETE
-- against any onboarded Muse fails on the first of those, and the one that
-- matters most is pos_tickets: those are attributed bills. Deleting a person
-- would mean destroying or orphaning financial records, and no privacy
-- obligation is served by losing the books.
--
-- So the person is erased and the skeleton is kept. Name, phone, email, date of
-- birth and Instagram are overwritten — not blanked to NULL where a NOT NULL
-- constraint stands in the way, but replaced with a marker that reads as
-- deliberate rather than as missing data. Her card is revoked, her credentials
-- are dropped so the code stops working, and her portal login is unlinked so
-- the auth user can no longer reach anything. What survives is a numbered shell
-- that tickets and audit rows can still point at.
--
-- THE ONE CASE WHERE A REAL DELETE HAPPENS: someone entered by mistake who was
-- never onboarded — no membership, no card, no arrival, no ticket. Nothing
-- references her, nothing is lost, and leaving a tombstone for a typo would be
-- its own small dishonesty. The function reports which of the two it did, and
-- the caller shows that, so nobody is told a record is gone when it is not.
--
-- Founder only. The HoSL runs the circle day to day and can read everything
-- here; ending a membership is a different act, and §4 puts it with the founder.
create or replace function muse_erase_member(p_muse_member_id uuid, p_reason text)
returns jsonb
language plpgsql
volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_m muse.members%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_refs int;
  v_no text;
begin
  if current_staff_role() is distinct from 'founder' then
    raise exception 'removing a Muse member is the founder''s decision';
  end if;
  -- A written reason, for the same reason a decline needs one: this is a
  -- decision about a person, and it should be answerable later.
  if v_reason is null or length(v_reason) < 10 then
    raise exception 'say why, in a sentence — this is recorded against the decision';
  end if;

  select * into v_m from muse.members where id = p_muse_member_id for update;
  if not found then
    raise exception 'no such Muse member';
  end if;
  if v_m.erased_at is not null then
    raise exception '% has already been erased', v_m.muse_no;
  end if;
  v_no := v_m.muse_no;

  select
    (select count(*) from muse.memberships where member_id = v_m.id)
  + (select count(*) from muse.cards      where muse_member_id = v_m.id)
  + (select count(*) from muse.arrivals   where muse_member_id = v_m.id)
  + (select count(*) from pos_tickets     where muse_member_id = v_m.id)
    into v_refs;

  -- Logged BEFORE the row changes, so the audit entry is written while there is
  -- still something to describe — and so an erasure can never be silent.
  perform log_audit('staff', auth.uid(), 'muse.member.erase',
                    'muse.members', p_muse_member_id::text);

  if v_refs = 0 then
    -- Never onboarded and referenced by nothing: the entry can simply go.
    delete from muse.candidates where member_id = v_m.id;
    delete from muse.members where id = v_m.id;
    return jsonb_build_object('outcome', 'deleted', 'muse_no', v_no,
      'detail', 'The entry was removed outright — she had never been onboarded.');
  end if;

  -- Stop the credentials working before anything else, so a half-finished
  -- erasure never leaves a working sign-in behind.
  delete from muse.credentials where muse_member_id = v_m.id;
  update muse.cards set status = 'revoked', revoked_at = now()
   where muse_member_id = v_m.id and status = 'active';

  update muse.members
     set full_name = 'Erased member',
         first_name = null,
         last_name = null,
         -- phone, email and date_of_birth are all NOT NULL (phone and email
         -- UNIQUE besides), so they are overwritten with values that are unique
         -- per row and obviously not a person, rather than emptied. The date is
         -- a sentinel for the same reason; `erased_at` is what the surfaces
         -- read, never the birthday.
         -- Built from her Muse number, which is unique and all digits, because
         -- the column also carries CHECK (phone ~ '^\+[0-9]{8,15}$') — a uuid
         -- fragment has letters in it and would be rejected.
         phone = '+' || lpad(regexp_replace(v_m.muse_no, '\D', '', 'g'), 14, '0'),
         email = 'erased+' || replace(v_m.id::text, '-', '') || '@kamadeva.invalid',
         instagram_handle = null,
         date_of_birth = date '1900-01-01',
         auth_user_id = null,
         status = 'exited',
         erased_at = now(),
         erased_reason = v_reason,
         updated_at = now()
   where id = v_m.id;

  return jsonb_build_object('outcome', 'erased', 'muse_no', v_no,
    'detail', 'Her details are gone and her card and sign-in no longer work. '
              || v_refs || ' record(s) — bills, arrivals, her card — still point at the membership, so the shell remains.');
end;
$$;

revoke execute on function muse_erase_member(uuid, text) from public, anon;
grant  execute on function muse_erase_member(uuid, text) to authenticated;

-- ── Muse numbers stop stranding ─────────────────────────────────────────────
-- next_muse_no was a bare nextval, so every rolled-back transaction burned a
-- number permanently — sequences do not roll back. Verifying this migration
-- against production left the sequence at 17 with two Muse members on the
-- register, which would have made the next real invitation KM-000018.
--
-- 0060 taught next_member_no to skip numbers already taken rather than trusting
-- the sequence alone. The same reasoning applies here, and for a register this
-- small and this deliberate the gaps are conspicuous: a circle of three people
-- numbered 1, 2 and 18 invites a question nobody wants to answer.
create or replace function next_muse_no()
returns text
language plpgsql
volatile
set search_path = public, pg_temp
as $$
declare
  v_no text;
begin
  loop
    v_no := 'KM-' || lpad(nextval('muse_no_seq')::text, 6, '0');
    exit when not exists (select 1 from muse.members where muse_no = v_no);
  end loop;
  return v_no;
end;
$$;

-- Wind the sequence back to the highest number actually issued. Safe only
-- because of the skip above: if anything in between is still held, the loop
-- steps over it rather than colliding.
select setval('muse_no_seq',
              greatest((select coalesce(max(regexp_replace(muse_no, '\D', '', 'g')::bigint), 0)
                          from muse.members), 1),
              true);
