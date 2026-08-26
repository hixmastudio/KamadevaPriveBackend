-- ============================================================================
-- 0029 — Muse RPCs for the standalone model.
--
-- Rewrites the pipeline RPCs to operate on muse.members (staff-entered
-- registration incl. date of birth), adds a tier-less member portal surface
-- (get_my_muse_status) + Muse login (verify_muse_login), and unions the public
-- card lookup. The founder approval gate stays in decide_approval; the RLS
-- namespace boundary and null-safe guard idiom are preserved.
--
-- The obsolete Privé-roster indicators (current_member_is_muse, muse_member_ids,
-- member_is_muse) are intentionally NOT dropped here — after the FK repoint they
-- can never match a Privé member, so they return false/empty harmlessly. That
-- keeps the currently-deployed SPA working until the new frontend ships; their
-- callers are removed in the frontend change and they can be dropped later.
-- ============================================================================

-- ── Initiation: staff enter the person's details (invitation-only) ──────────
drop function if exists muse_initiate(uuid, text);
create or replace function muse_initiate(
  p_full_name text, p_phone text, p_email text, p_dob date, p_rationale text
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_phone text;
  v_muse_id uuid;
  v_approval_id uuid;
  v_candidate_id uuid;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'Muse candidates are initiated by venue managers, the HoSL, or founders';
  end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then
    raise exception 'a full name is required';
  end if;
  if coalesce(p_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'a valid email is required';
  end if;
  if p_dob is null or p_dob > (current_date - interval '18 years') then
    raise exception 'date of birth is required and the member must be at least 18';
  end if;
  if length(trim(coalesce(p_rationale, ''))) < 10 then
    raise exception 'a written rationale is required';
  end if;
  v_phone := normalize_phone(p_phone);  -- raises on an invalid number

  select id into v_muse_id from muse.members where phone = v_phone;
  if v_muse_id is not null then
    if exists (select 1 from muse.members
               where id = v_muse_id and status in ('candidate', 'active', 'paused')) then
      raise exception 'this person is already a Muse candidate or member';
    end if;
    -- Reactivate a previously declined/exited subject.
    update muse.members
      set full_name = trim(p_full_name), email = lower(trim(p_email)),
          date_of_birth = p_dob, status = 'candidate'
      where id = v_muse_id;
  else
    insert into muse.members (full_name, phone, email, date_of_birth, status)
    values (trim(p_full_name), v_phone, lower(trim(p_email)), p_dob, 'candidate')
    returning id into v_muse_id;
  end if;

  insert into approvals (subject_type, member_id, requested_by, rationale)
  values ('muse_membership', null, current_staff_id(), trim(p_rationale))
  returning id into v_approval_id;

  insert into muse.candidates (member_id, initiated_by, initiator_role_snapshot, rationale, approval_id)
  values (v_muse_id, current_staff_id(), v_role, trim(p_rationale), v_approval_id)
  returning id into v_candidate_id;

  return v_candidate_id;
end;
$$;

-- ── Decision: founder/delegate gate lives in decide_approval ────────────────
create or replace function muse_decide(
  p_candidate_id uuid,
  p_decision approval_status,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_candidate muse.candidates%rowtype;
begin
  select * into v_candidate from muse.candidates where id = p_candidate_id for update;
  if not found or v_candidate.status not in ('submitted', 'under_review') then
    raise exception 'candidate not found or already decided';
  end if;

  perform decide_approval(v_candidate.approval_id, p_decision, p_reason);

  update muse.candidates
    set status = case when p_decision = 'approved' then 'approved'::muse_candidate_status
                      else 'declined'::muse_candidate_status end
    where id = p_candidate_id;

  if p_decision = 'declined' then
    update muse.members set status = 'declined' where id = v_candidate.member_id;
  end if;
end;
$$;

-- ── Onboarding: membership + Muse card + one-time login code (HoSL) ──────────
drop function if exists muse_onboard(uuid);
create or replace function muse_onboard(p_candidate_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
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

  perform log_audit('staff', auth.uid(), 'muse.onboard', 'muse.members', v_muse.id::text);

  return jsonb_build_object(
    'membership_id', v_membership_id,
    'muse_no', v_muse.muse_no,
    'full_name', v_muse.full_name,
    'card_token', v_card_token,
    'login_code', v_code
  );
end;
$$;

-- ── Benefit delivery on the floor ───────────────────────────────────────────
drop function if exists grant_muse_benefit(uuid, uuid, muse_benefit_type, bigint);
create or replace function grant_muse_benefit(
  p_muse_member_id uuid,
  p_venue_id uuid,
  p_type muse_benefit_type,
  p_value_kobo bigint default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_membership muse.memberships%rowtype;
begin
  if current_staff_id() is null or not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  select * into v_membership from muse.memberships
  where member_id = p_muse_member_id and status = 'active';
  if not found then
    raise exception 'not an active Muse member';
  end if;
  insert into muse.benefit_grants (membership_id, venue_id, type, value_kobo, granted_by)
  values (v_membership.id, p_venue_id, p_type, p_value_kobo, current_staff_id());
end;
$$;

-- ── Pipeline read (repointed to muse.members; no tier) ──────────────────────
create or replace function muse_list_pipeline()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_result jsonb;
begin
  if v_role in ('hosl', 'founder') then
    perform log_audit('staff', auth.uid(), 'muse.pipeline.read', 'muse.candidates', null);
    select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_result
    from (
      select jsonb_build_object(
        'candidate_id', c.id,
        'muse_member_id', c.member_id,
        'full_name', mm.full_name,
        'muse_no', mm.muse_no,
        'status', c.status,
        'rationale', c.rationale,
        'initiated_by', sp.full_name,
        'decision_reason', a.decision_reason,
        'onboarded', exists (select 1 from muse.memberships ms where ms.candidate_id = c.id)
      ) as row_data, c.created_at
      from muse.candidates c
      join muse.members mm on mm.id = c.member_id
      join staff_profiles sp on sp.id = c.initiated_by
      left join approvals a on a.id = c.approval_id
    ) t;
    return v_result;
  elsif v_role = 'venue_manager' then
    select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_result
    from (
      select jsonb_build_object(
        'candidate_id', c.id,
        'full_name', mm.full_name,
        'status', c.status
      ) as row_data, c.created_at
      from muse.candidates c
      join muse.members mm on mm.id = c.member_id
      where c.initiated_by = current_staff_id()
    ) t;
    return v_result;
  else
    raise exception 'not authorized';
  end if;
end;
$$;

-- ── Staff typeahead for benefit delivery ────────────────────────────────────
create or replace function muse_find_members(p_query text, p_limit int default 8)
returns table (muse_member_id uuid, muse_no text, full_name text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_q text := trim(coalesce(p_query, ''));
  v_digits text := regexp_replace(coalesce(p_query, ''), '[^0-9]', '', 'g');
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'not authorized';
  end if;
  if length(v_q) < 2 then
    return;
  end if;
  return query
    select mm.id, mm.muse_no, mm.full_name
    from muse.members mm
    where mm.status = 'active'
      and (mm.full_name ilike '%' || v_q || '%'
           or mm.muse_no ilike '%' || v_q || '%'
           or (v_digits <> '' and regexp_replace(mm.phone, '[^0-9]', '', 'g') like '%' || v_digits || '%'))
    order by mm.full_name
    limit least(greatest(p_limit, 1), 25);
end;
$$;

-- ── Member portal: self-scoped Muse status (tier-less) ──────────────────────
create or replace function current_muse_member_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select id from muse.members
  where auth_user_id = auth.uid() and status in ('active', 'paused')
  limit 1;
$$;

create or replace function get_my_muse_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid := current_muse_member_id();
  v_muse muse.members%rowtype;
  v_membership muse.memberships%rowtype;
  v_token text;
begin
  if v_id is null then
    return null;  -- not a Muse auth user; the SPA falls through to Privé/staff
  end if;
  select * into v_muse from muse.members where id = v_id;
  select * into v_membership from muse.memberships where member_id = v_id and status = 'active';
  select qr_token into v_token from muse.cards where muse_member_id = v_id and status = 'active' limit 1;

  return jsonb_build_object(
    'muse_no', v_muse.muse_no,
    'full_name', v_muse.full_name,
    'status', v_muse.status,
    'card_token', v_token,
    'benefits', coalesce((
      select jsonb_agg(jsonb_build_object('type', bg.type, 'when', bg.created_at) order by bg.created_at desc)
      from muse.benefit_grants bg where bg.membership_id = v_membership.id
    ), '[]'::jsonb),
    'upcoming_events', coalesce((
      select jsonb_agg(jsonb_build_object('night', ec.night, 'label', ec.label, 'benefits', ec.benefits) order by ec.night)
      from muse.event_calendar ec where ec.night >= current_date
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function set_my_muse_code(p_new_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id uuid := current_muse_member_id();
begin
  if v_id is null then
    raise exception 'not signed in as a Muse member';
  end if;
  if p_new_code !~ '^[0-9]{6}$' then
    raise exception 'your code must be exactly 6 digits';
  end if;
  insert into muse.credentials (muse_member_id, code_hash, code_set_at, failed_attempts, locked_until, updated_at)
  values (v_id, extensions.crypt(p_new_code, extensions.gen_salt('bf')), now(), 0, null, now())
  on conflict (muse_member_id) do update
    set code_hash = excluded.code_hash, code_set_at = now(),
        failed_attempts = 0, locked_until = null, updated_at = now();
end;
$$;

-- ── Login (service_role only — mirrors verify_member_login) ─────────────────
create or replace function verify_muse_login(p_identifier text, p_code text)
returns table (muse_member_id uuid, muse_no text, locked boolean, remaining int)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id   text := trim(coalesce(p_identifier, ''));
  v_max  int := 5;
  v_lock interval := interval '15 minutes';
  v_muse muse.members%rowtype;
  v_cred muse.credentials%rowtype;
begin
  if position('@' in v_id) > 0 then
    select * into v_muse from muse.members
      where lower(email) = lower(v_id) and status in ('active', 'paused') limit 1;
  else
    select * into v_muse from muse.members
      where phone = normalize_phone(v_id) and status in ('active', 'paused') limit 1;
  end if;
  if not found then
    return query select null::uuid, null::text, false, v_max; return;
  end if;

  select * into v_cred from muse.credentials mc where mc.muse_member_id = v_muse.id;
  if not found then
    return query select null::uuid, null::text, false, v_max; return;
  end if;

  if v_cred.locked_until is not null and v_cred.locked_until > now() then
    return query select null::uuid, null::text, true, 0; return;
  end if;

  if v_cred.code_hash = extensions.crypt(p_code, v_cred.code_hash) then
    update muse.credentials mc set failed_attempts = 0, locked_until = null, updated_at = now()
      where mc.muse_member_id = v_muse.id;
    return query select v_muse.id, v_muse.muse_no, false, v_max; return;
  end if;

  update muse.credentials mc
    set failed_attempts = mc.failed_attempts + 1,
        locked_until = case when mc.failed_attempts + 1 >= v_max then now() + v_lock else null end,
        updated_at = now()
    where mc.muse_member_id = v_muse.id
    returning * into v_cred;

  return query select null::uuid, null::text,
    (v_cred.locked_until is not null and v_cred.locked_until > now()),
    greatest(0, v_max - v_cred.failed_attempts);
end;
$$;

create or replace function muse_member_auth_user_id(p_muse_member_id uuid)
returns uuid
language sql
security definer
set search_path = public, pg_temp
as $$ select auth_user_id from muse.members where id = p_muse_member_id; $$;

create or replace function muse_link_auth_user(p_muse_member_id uuid, p_auth_user_id uuid)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$ update muse.members set auth_user_id = p_auth_user_id where id = p_muse_member_id; $$;

-- ── Public card lookup: union Privé + Muse ──────────────────────────────────
create or replace function get_card_public(p_qr_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_card member_cards%rowtype;
  v_member members%rowtype;
  v_mcard muse.cards%rowtype;
  v_muse muse.members%rowtype;
begin
  select * into v_card from member_cards where qr_token = p_qr_token and status = 'active';
  if found then
    select * into v_member from members where id = v_card.member_id and status = 'active';
    if not found then return null; end if;
    return jsonb_build_object(
      'full_name', v_member.full_name, 'member_no', v_member.member_no,
      'tier', v_member.current_tier, 'kind', v_card.kind, 'issued_at', v_card.issued_at);
  end if;

  select * into v_mcard from muse.cards where qr_token = p_qr_token and status = 'active';
  if found then
    select * into v_muse from muse.members where id = v_mcard.muse_member_id and status in ('active', 'paused');
    if not found then return null; end if;
    return jsonb_build_object(
      'full_name', v_muse.full_name, 'member_no', v_muse.muse_no,
      'tier', null, 'kind', 'muse', 'issued_at', v_mcard.issued_at);
  end if;

  return null;
end;
$$;

-- ── Recognition: strip the (now-dead) Privé-coupled Muse block ───────────────
create or replace function get_recognition_profile(
  p_qr_token text default null,
  p_phone text default null,
  p_member_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_member members%rowtype;
  v_visits_month int;
  v_reservation reservations%rowtype;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;

  if p_qr_token is not null then
    select m.* into v_member
    from member_cards c join members m on m.id = c.member_id
    where c.qr_token = p_qr_token and c.status = 'active' and m.status = 'active';
  elsif p_member_id is not null then
    select * into v_member from members where id = p_member_id and status = 'active';
  elsif p_phone is not null then
    select * into v_member from members where phone = normalize_phone(p_phone) and status = 'active';
  end if;

  if v_member.id is null then
    return null;
  end if;

  select count(*)::int into v_visits_month
  from visits
  where member_id = v_member.id and voided_at is null
    and occurred_at > date_trunc('month', now());

  select * into v_reservation
  from reservations
  where member_id = v_member.id
    and status in ('requested', 'confirmed')
    and kp_business_date(reserved_for) = kp_business_date(now())
  order by reserved_for
  limit 1;

  return jsonb_build_object(
    'member_id', v_member.id,
    'member_no', v_member.member_no,
    'full_name', v_member.full_name,
    'tier', v_member.current_tier,
    'visits_this_month', v_visits_month,
    'reservation_tonight', case when v_reservation.id is null then null
      else jsonb_build_object('id', v_reservation.id, 'party_size', v_reservation.party_size,
                              'reserved_for', v_reservation.reserved_for) end,
    'priority_entry', v_member.current_tier in ('silver', 'gold', 'black')
  );
end;
$$;

-- ── Grants ──────────────────────────────────────────────────────────────────
-- Staff + portal (all authenticated); anon never.
revoke execute on function muse_initiate(text, text, text, date, text)                 from public, anon;
revoke execute on function muse_onboard(uuid)                                           from public, anon;
revoke execute on function grant_muse_benefit(uuid, uuid, muse_benefit_type, bigint)    from public, anon;
revoke execute on function muse_find_members(text, int)                                 from public, anon;
revoke execute on function current_muse_member_id()                                     from public, anon;
revoke execute on function get_my_muse_status()                                         from public, anon;
revoke execute on function set_my_muse_code(text)                                       from public, anon;
grant  execute on function muse_initiate(text, text, text, date, text)                  to authenticated;
grant  execute on function muse_onboard(uuid)                                           to authenticated;
grant  execute on function grant_muse_benefit(uuid, uuid, muse_benefit_type, bigint)    to authenticated;
grant  execute on function muse_find_members(text, int)                                 to authenticated;
grant  execute on function current_muse_member_id()                                     to authenticated;
grant  execute on function get_my_muse_status()                                         to authenticated;
grant  execute on function set_my_muse_code(text)                                       to authenticated;

-- Login helpers: service_role ONLY (called by the member-login Edge Function).
revoke execute on function verify_muse_login(text, text)          from public, anon, authenticated;
revoke execute on function muse_member_auth_user_id(uuid)         from public, anon, authenticated;
revoke execute on function muse_link_auth_user(uuid, uuid)        from public, anon, authenticated;
grant  execute on function verify_muse_login(text, text)          to service_role;
grant  execute on function muse_member_auth_user_id(uuid)         to service_role;
grant  execute on function muse_link_auth_user(uuid, uuid)        to service_role;

-- get_card_public stays anon + authenticated (public /card/<token> page).
grant execute on function get_card_public(text) to anon, authenticated;
