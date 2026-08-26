-- ============================================================================
-- 0025 — Harden the remaining fail-open role guards (security fix).
--
-- Follow-up to 0024. `current_staff_role()` / `current_staff_id()` are NULL for
-- any non-staff caller — and a portal member is still the `authenticated`
-- Postgres role, which holds EXECUTE on every RPC below (see the `grant execute
-- ... to authenticated` blocks in 0009/0013/0015/0017/0019/0022). The guard
-- `if current_staff_role() not in (...) then raise` is fail-OPEN on NULL:
-- `NULL not in (...)` is NULL, the IF never fires, and the function proceeds.
-- The same is true when the role is read into a variable first
-- (`v_role not in (...)`, `v_caller_role not in (...)`, `v_role != 'founder'`) —
-- which is why 0024's `current_staff_role() not in` grep did not surface the
-- decide_approval and 0013 staff-admin functions.
--
-- Fix: deny the NULL-role caller explicitly, using the codebase's own existing
-- null-safe guard idiom (see open_tier_case: `v_staff is null or ...`,
-- apply_discretionary_discount: `v_approver is null or ...`). Each function body
-- below is reproduced verbatim; only the guard line changes, so behaviour for
-- real venue_manager / hosl / founder sessions is identical. This is the same
-- deny-on-NULL outcome as 0024's positive allow-checks — kept as an inline null
-- guard here to leave these larger bodies byte-for-byte unchanged.
--
-- Left untouched because they already deny NULL:
--   open_tier_case (v_staff is null or ...), void_visit / void_transaction /
--   record_shift_entries (or not staff_has_venue() — returns non-NULL false for
--   non-staff), add_tier_signoff (positive allow + else-deny),
--   apply_discretionary_discount (v_approver is null or ...), grant_muse_benefit
--   (current_staff_id() is null or ...), muse_list_pipeline (positive allow),
--   muse_decide (delegates to decide_approval, hardened below), and the four
--   Muse read RPCs already fixed in 0024.
-- ============================================================================

-- ── 0009 — accept_invitation ────────────────────────────────────────────────
create or replace function accept_invitation(p_invitation_id uuid)
returns invitations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_inv invitations%rowtype;
  v_stats record;
  v_snapshot jsonb;
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'invitation acceptance is recorded by HoSL or a founder';
  end if;

  select * into v_inv from invitations where id = p_invitation_id for update;
  if not found or v_inv.status != 'issued' then
    raise exception 'invitation not found or not open';
  end if;

  update invitations set status = 'accepted', accepted_at = now()
  where id = p_invitation_id returning * into v_inv;

  if v_inv.kind = 'black' then
    select * into v_stats from compute_member_stats(v_inv.member_id);
    v_snapshot := jsonb_build_object(
      'visits_90d', v_stats.visits_90d,
      'visits_12m', v_stats.visits_12m,
      'spend_12m_kobo', v_stats.spend_12m_kobo);

    insert into tier_events (member_id, from_tier, to_tier, reason, approval_id,
                             stats_snapshot, effected_by, staff_id)
    select v_inv.member_id, m.current_tier, 'black', 'invitation_accepted',
           v_inv.approval_id, v_snapshot, 'staff', v_staff
    from members m where m.id = v_inv.member_id;

    update members set current_tier = 'black', tier_computed_at = now()
    where id = v_inv.member_id;
  end if;

  return v_inv;
end;
$$;

-- ── 0009 — decide_approval ──────────────────────────────────────────────────
-- Every branch below guards with `v_role not in (...)` / `v_role != 'founder'`,
-- all fail-open on a NULL role. A single leading staff gate denies the non-staff
-- caller before any decision logic; the per-subject-type role matrix is exact
-- for real staff and left verbatim.
create or replace function decide_approval(
  p_approval_id uuid,
  p_decision approval_status,
  p_reason text default null
)
returns approvals
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_role staff_role := current_staff_role();
  v_approval approvals%rowtype;
  v_stats record;
  v_snapshot jsonb;
begin
  if v_staff is null then
    raise exception 'not authorized to decide this approval';
  end if;
  if p_decision not in ('approved', 'declined') then
    raise exception 'decision must be approved or declined';
  end if;

  select * into v_approval from approvals where id = p_approval_id for update;
  if not found or v_approval.status != 'pending' then
    raise exception 'approval not found or already decided';
  end if;

  -- Who may decide what (§4 matrix).
  if v_approval.subject_type in ('tier_gold', 'tier_black') then
    if v_role not in ('hosl', 'founder') then
      raise exception 'tier approvals are decided by HoSL or a founder after committee sign-offs';
    end if;
  elsif v_approval.subject_type = 'muse_membership' then
    if not (v_role = 'founder' or staff_holds_delegation(v_staff, 'muse_approval')) then
      raise exception 'Muse approvals are decided only by an owner or their recorded delegate';
    end if;
  elsif v_approval.subject_type = 'ndpr_erasure' then
    if v_role != 'founder' then
      raise exception 'NDPR erasure is founder-approved';
    end if;
  else
    if v_role not in ('hosl', 'founder') then
      raise exception 'not authorized to decide this approval';
    end if;
  end if;

  if p_decision = 'declined' and (p_reason is null or length(trim(p_reason)) = 0) then
    raise exception 'declines require a written reason';
  end if;

  update approvals
    set status = p_decision,
        decided_by = v_staff,
        decided_at = now(),
        decision_reason = nullif(trim(coalesce(p_reason, '')), '')
    where id = p_approval_id
    returning * into v_approval;

  -- Gold: promotion is immediate on approval. Black: issue the invitation.
  if p_decision = 'approved' and v_approval.subject_type = 'tier_gold' then
    select * into v_stats from compute_member_stats(v_approval.member_id);
    v_snapshot := jsonb_build_object(
      'visits_90d', v_stats.visits_90d,
      'visits_12m', v_stats.visits_12m,
      'spend_12m_kobo', v_stats.spend_12m_kobo);

    insert into tier_events (member_id, from_tier, to_tier, reason, approval_id,
                             stats_snapshot, effected_by, staff_id)
    select v_approval.member_id, m.current_tier, 'gold', 'approved_promotion',
           v_approval.id, v_snapshot, 'staff', v_staff
    from members m where m.id = v_approval.member_id;

    update members set current_tier = 'gold', tier_computed_at = now()
    where id = v_approval.member_id;

  elsif p_decision = 'approved' and v_approval.subject_type = 'tier_black' then
    insert into invitations (member_id, kind, approval_id, issued_by)
    values (v_approval.member_id, 'black', v_approval.id, v_staff);
  end if;

  return v_approval;
end;
$$;

-- ── 0009 — merge_members ────────────────────────────────────────────────────
create or replace function merge_members(p_duplicate_id uuid, p_keep_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r record;
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'member merges are performed by HoSL or a founder';
  end if;
  if p_duplicate_id = p_keep_id then
    raise exception 'cannot merge a member into itself';
  end if;

  perform 1 from members where id = p_keep_id and status = 'active';
  if not found then raise exception 'target member not found'; end if;
  perform 1 from members where id = p_duplicate_id and status = 'active' for update;
  if not found then raise exception 'duplicate member not found'; end if;

  -- Repoint activity. Same-night visit collisions void the duplicate's copy.
  for r in select id from visits where member_id = p_duplicate_id and voided_at is null loop
    begin
      update visits set member_id = p_keep_id where id = r.id;
    exception when unique_violation then
      update visits
        set voided_at = now(), voided_by = current_staff_id(),
            void_reason = 'merged duplicate: same-night visit already on surviving profile'
        where id = r.id;
    end;
  end loop;

  update transactions set member_id = p_keep_id where member_id = p_duplicate_id;
  update reservations set member_id = p_keep_id where member_id = p_duplicate_id;
  update consents set member_id = p_keep_id where member_id = p_duplicate_id;
  update member_cards set status = 'revoked', revoked_at = now()
    where member_id = p_duplicate_id and status = 'active';

  update members
    set status = 'merged',
        merged_into_member_id = p_keep_id,
        -- Free the phone slot: history is preserved in audit.
        phone = phone || ':merged:' || substr(id::text, 1, 8)
    where id = p_duplicate_id;

  perform recompute_member_tier(p_keep_id);
  perform log_audit('staff', auth.uid(), 'member.merge', 'members', p_keep_id::text,
                    null, jsonb_build_object('duplicate_id', p_duplicate_id), null);
end;
$$;

-- ── 0009 — search_members ───────────────────────────────────────────────────
create or replace function search_members(p_query text, p_limit int default 20)
returns setof members
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_phone text;
begin
  if current_staff_role() is null or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'member search requires venue manager or above';
  end if;

  if p_query ~ '^[+0-9][0-9 -]*$' then
    begin
      v_phone := normalize_phone(p_query);
    exception when others then
      v_phone := null;
    end;
  end if;

  return query
  select * from members m
  where m.status = 'active'
    and (
      (v_phone is not null and m.phone = v_phone)
      or m.member_no ilike p_query || '%'
      or m.full_name ilike '%' || p_query || '%'
    )
  order by m.full_name
  limit least(p_limit, 50);
end;
$$;

-- ── 0013 — create_staff_account ─────────────────────────────────────────────
-- The primary guard and the founder sub-guard (`p_role = 'founder' and
-- v_caller_role != 'founder'`) are both fail-open on a NULL role — a portal
-- member could mint a staff, or even a founder, account. The leading null gate
-- denies non-staff; both role checks are then exact for real staff.
create or replace function create_staff_account(
  p_email text,
  p_full_name text,
  p_role staff_role,
  p_venue_ids uuid[] default '{}',
  p_pin text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_email text := lower(trim(p_email));
  v_temp_password text;
  v_auth_id uuid := gen_random_uuid();
  v_staff_id uuid;
  v_venue uuid;
begin
  if v_caller_role is null or v_caller_role not in ('hosl', 'founder') then
    raise exception 'staff accounts are managed by the HoSL or a founder';
  end if;
  -- Founders are appointed only by founders.
  if p_role = 'founder' and v_caller_role != 'founder' then
    raise exception 'only a founder can create a founder account';
  end if;
  if v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'a valid email address is required';
  end if;
  if length(trim(p_full_name)) < 2 then
    raise exception 'full name is required';
  end if;
  if exists (select 1 from auth.users where email = v_email) then
    raise exception 'an account with this email already exists';
  end if;
  if p_pin is not null and p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN must be 4-6 digits';
  end if;

  -- Readable one-time password: kp-XXXX-XXXX from random bytes.
  v_temp_password := 'kp-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 4)
                   || '-' || substr(encode(extensions.gen_random_bytes(6), 'hex'), 5, 4);

  insert into auth.users
    (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
     raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
     confirmation_token, recovery_token, email_change,
     email_change_token_new, email_change_token_current,
     phone_change, phone_change_token, reauthentication_token)
  values
    ('00000000-0000-0000-0000-000000000000', v_auth_id, 'authenticated', 'authenticated',
     v_email, extensions.crypt(v_temp_password, extensions.gen_salt('bf')), now(),
     '{"provider":"email","providers":["email"]}', '{}', now(), now(),
     '', '', '', '', '', '', '', '');

  insert into auth.identities
    (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values
    (gen_random_uuid(), v_auth_id, v_auth_id::text, 'email',
     jsonb_build_object('sub', v_auth_id::text, 'email', v_email, 'email_verified', true),
     now(), now(), now());

  insert into staff_profiles (auth_user_id, full_name, role, pin_hash)
  values (v_auth_id, trim(p_full_name), p_role,
          case when p_pin is null then null
               else extensions.crypt(p_pin, extensions.gen_salt('bf')) end)
  returning id into v_staff_id;

  foreach v_venue in array coalesce(p_venue_ids, '{}') loop
    insert into staff_venue_assignments (staff_id, venue_id) values (v_staff_id, v_venue);
  end loop;

  perform log_audit('staff', auth.uid(), 'staff.account.create',
                    'staff_profiles', v_staff_id::text, null, null,
                    jsonb_build_object('email', v_email, 'role', p_role));

  return jsonb_build_object(
    'staff_id', v_staff_id,
    'email', v_email,
    'temp_password', v_temp_password
  );
end;
$$;

-- ── 0013 — set_staff_active ─────────────────────────────────────────────────
create or replace function set_staff_active(p_staff_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_target staff_profiles%rowtype;
begin
  if v_caller_role is null or v_caller_role not in ('hosl', 'founder') then
    raise exception 'staff accounts are managed by the HoSL or a founder';
  end if;
  select * into v_target from staff_profiles where id = p_staff_id for update;
  if not found then
    raise exception 'staff member not found';
  end if;
  if v_target.id = current_staff_id() then
    raise exception 'you cannot deactivate your own account';
  end if;
  if v_target.role = 'founder' and v_caller_role != 'founder' then
    raise exception 'only a founder can manage a founder account';
  end if;

  update staff_profiles
    set is_active = p_active,
        deactivated_at = case when p_active then null else now() end
    where id = p_staff_id;
end;
$$;

-- ── 0013 — set_staff_venues ─────────────────────────────────────────────────
create or replace function set_staff_venues(p_staff_id uuid, p_venue_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_caller_role staff_role := current_staff_role();
  v_venue uuid;
begin
  if v_caller_role is null or v_caller_role not in ('hosl', 'founder') then
    raise exception 'venue assignments are managed by the HoSL or a founder';
  end if;
  perform 1 from staff_profiles where id = p_staff_id;
  if not found then
    raise exception 'staff member not found';
  end if;

  update staff_venue_assignments
    set revoked_at = now()
    where staff_id = p_staff_id
      and revoked_at is null
      and not (venue_id = any (coalesce(p_venue_ids, '{}')));

  foreach v_venue in array coalesce(p_venue_ids, '{}') loop
    if not exists (
      select 1 from staff_venue_assignments
      where staff_id = p_staff_id and venue_id = v_venue and revoked_at is null
    ) then
      insert into staff_venue_assignments (staff_id, venue_id) values (p_staff_id, v_venue);
    end if;
  end loop;

  perform log_audit('staff', auth.uid(), 'staff.venues.set',
                    'staff_profiles', p_staff_id::text, null, null,
                    jsonb_build_object('venue_ids', p_venue_ids));
end;
$$;

-- ── 0015 — get_member_card ──────────────────────────────────────────────────
create or replace function get_member_card(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_card member_cards%rowtype;
begin
  if current_staff_role() is null or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'member cards are viewed by venue managers and above';
  end if;

  select * into v_card from member_cards
  where member_id = p_member_id and kind = 'prive' and status = 'active';
  if not found then
    -- Legacy member without a card (pre-backfill edge): issue one now.
    insert into member_cards (member_id, kind) values (p_member_id, 'prive')
    returning * into v_card;
  end if;

  return jsonb_build_object('qr_token', v_card.qr_token, 'issued_at', v_card.issued_at);
end;
$$;

-- ── 0017 — set_discount_designation ─────────────────────────────────────────
create or replace function set_discount_designation(
  p_tier tier_enum,
  p_percent numeric,
  p_venue_id uuid default null,
  p_event_id uuid default null,
  p_allow_promo_stacking boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'the published designation list is maintained by the HoSL';
  end if;
  if (p_venue_id is null) = (p_event_id is null) then
    raise exception 'designate exactly one venue or one event';
  end if;

  update discount_designations
    set active_to = now()
    where tier = p_tier
      and active_to is null
      and venue_id is not distinct from p_venue_id
      and event_id is not distinct from p_event_id;

  insert into discount_designations
    (venue_id, event_id, tier, percent, created_by, allow_promo_stacking)
  values
    (p_venue_id, p_event_id, p_tier, p_percent, current_staff_id(), p_allow_promo_stacking)
  returning id into v_id;
  return v_id;
end;
$$;

-- ── 0017 — end_discount_designation ─────────────────────────────────────────
create or replace function end_discount_designation(p_designation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'the published designation list is maintained by the HoSL';
  end if;
  update discount_designations set active_to = now()
  where id = p_designation_id and active_to is null;
end;
$$;

-- ── 0017 — set_delegated_limit ──────────────────────────────────────────────
create or replace function set_delegated_limit(
  p_staff_id uuid,
  p_venue_id uuid,
  p_period_month date,
  p_limit_kobo bigint
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'delegated limits are set by the HoSL';
  end if;
  insert into delegated_limits (staff_id, venue_id, period_month, limit_kobo, set_by)
  values (p_staff_id, p_venue_id, date_trunc('month', p_period_month)::date, p_limit_kobo, current_staff_id())
  on conflict (staff_id, venue_id, period_month) do update
    set limit_kobo = excluded.limit_kobo, set_by = excluded.set_by;
end;
$$;

-- ── 0017 — muse_initiate ────────────────────────────────────────────────────
create or replace function muse_initiate(p_member_id uuid, p_rationale text)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_approval_id uuid;
  v_candidate_id uuid;
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'Muse candidates are initiated by venue managers, the HoSL, or founders';
  end if;
  if length(trim(coalesce(p_rationale, ''))) < 10 then
    raise exception 'a written rationale is required';
  end if;
  perform 1 from members where id = p_member_id and status = 'active';
  if not found then
    raise exception 'member not found';
  end if;
  if exists (select 1 from muse.memberships where member_id = p_member_id and status = 'active') then
    raise exception 'already a Muse member';
  end if;

  insert into approvals (subject_type, member_id, requested_by, rationale)
  values ('muse_membership', p_member_id, current_staff_id(), trim(p_rationale))
  returning id into v_approval_id;

  insert into muse.candidates (member_id, initiated_by, initiator_role_snapshot, rationale, approval_id)
  values (p_member_id, current_staff_id(), v_role, trim(p_rationale), v_approval_id)
  returning id into v_candidate_id;

  return v_candidate_id;
end;
$$;

-- ── 0017 — muse_onboard ─────────────────────────────────────────────────────
create or replace function muse_onboard(p_candidate_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_candidate muse.candidates%rowtype;
  v_membership_id uuid;
  v_card_id uuid;
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

  insert into member_cards (member_id, kind) values (v_candidate.member_id, 'muse')
  on conflict do nothing;
  select id into v_card_id from member_cards
  where member_id = v_candidate.member_id and kind = 'muse' and status = 'active';

  insert into muse.memberships (member_id, candidate_id, approved_via, onboarded_by, onboarded_at, card_id)
  values (v_candidate.member_id, v_candidate.id, v_candidate.approval_id,
          current_staff_id(), now(), v_card_id)
  returning id into v_membership_id;

  return v_membership_id;
end;
$$;

-- ── 0017 — set_catalog_item ─────────────────────────────────────────────────
create or replace function set_catalog_item(
  p_venue_id uuid,
  p_name text,
  p_price_kobo bigint,
  p_description text default null,
  p_item_id uuid default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'the catalog is curated by the HoSL';
  end if;
  if p_item_id is null then
    insert into catalog_items (venue_id, name, description, price_kobo, is_active, created_by)
    values (p_venue_id, trim(p_name), p_description, p_price_kobo, p_is_active, current_staff_id())
    returning id into v_id;
  else
    update catalog_items
      set name = trim(p_name), description = p_description,
          price_kobo = p_price_kobo, is_active = p_is_active
      where id = p_item_id
      returning id into v_id;
    if not found then
      raise exception 'item not found';
    end if;
  end if;
  return v_id;
end;
$$;

-- ── 0017 — answer_enquiry ───────────────────────────────────────────────────
create or replace function answer_enquiry(p_enquiry_id uuid, p_answer text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() is null or current_staff_role() not in ('hosl', 'founder') then
    raise exception 'enquiries are answered by the HoSL';
  end if;
  update enquiries
    set status = 'answered', answer = trim(p_answer),
        answered_by = current_staff_id(), answered_at = now()
    where id = p_enquiry_id;
  if not found then
    raise exception 'enquiry not found';
  end if;
end;
$$;

-- ── 0019 — save_event ───────────────────────────────────────────────────────
create or replace function save_event(
  p_name text,
  p_starts_at timestamptz,
  p_venue_id uuid default null,
  p_event_id uuid default null,
  p_ends_at timestamptz default null,
  p_capacity integer default null,
  p_status text default 'published',
  p_min_reservation_tier tier_enum default null,
  p_windows jsonb default '[]'::jsonb  -- [{"min_tier":"gold","opens_at":"…"}]
)
returns events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_event events%rowtype;
  w record;
begin
  if current_staff_role() is null or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'events are managed by venue managers and above';
  end if;
  if p_venue_id is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'event name is required';
  end if;
  if p_status not in ('draft', 'published', 'cancelled') then
    raise exception 'status must be draft, published, or cancelled';
  end if;

  if p_event_id is null then
    insert into events (venue_id, name, starts_at, ends_at, capacity, status,
                        min_reservation_tier, created_by)
    values (p_venue_id, trim(p_name), p_starts_at, p_ends_at, p_capacity,
            p_status, p_min_reservation_tier, v_staff)
    returning * into v_event;
  else
    update events
      set venue_id = p_venue_id, name = trim(p_name), starts_at = p_starts_at,
          ends_at = p_ends_at, capacity = p_capacity, status = p_status,
          min_reservation_tier = p_min_reservation_tier
      where id = p_event_id
      returning * into v_event;
    if not found then
      raise exception 'event not found';
    end if;
  end if;

  -- Replace the tier windows wholesale — the form always sends the full set.
  delete from event_access_windows where event_id = v_event.id;
  for w in
    select (j->>'min_tier')::tier_enum as min_tier, (j->>'opens_at')::timestamptz as opens_at
    from jsonb_array_elements(coalesce(p_windows, '[]'::jsonb)) j
  loop
    insert into event_access_windows (event_id, min_tier, opens_at)
    values (v_event.id, w.min_tier, w.opens_at);
  end loop;

  perform log_audit(
    p_actor_type => 'staff'::actor_type,
    p_actor_id   => v_staff,
    p_action     => case when p_event_id is null then 'event.create' else 'event.update' end,
    p_entity_type=> 'events',
    p_entity_id  => v_event.id::text,
    p_venue_id   => p_venue_id,
    p_after      => to_jsonb(v_event)
  );

  return v_event;
end;
$$;

-- ── 0022 — update_member_profile (live 5-arg form) ──────────────────────────
create or replace function update_member_profile(
  p_member_id uuid,
  p_full_name text default null,
  p_instagram text default null,
  p_email text default null,
  p_gender text default null
)
returns members
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
  v_gender text := nullif(lower(trim(coalesce(p_gender, ''))), '');
begin
  if current_staff_role() is null or current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'profile edits require venue manager or above';
  end if;
  if v_gender is not null and v_gender not in ('female', 'male', 'other', 'undisclosed') then
    v_gender := null;
  end if;
  update members
    set full_name = coalesce(nullif(trim(coalesce(p_full_name, '')), ''), full_name),
        instagram_handle = coalesce(nullif(trim(coalesce(p_instagram, '')), ''), instagram_handle),
        email = coalesce(nullif(trim(coalesce(p_email, '')), ''), email),
        gender = coalesce(v_gender, gender)
    where id = p_member_id and status = 'active'
    returning * into v_member;
  if not found then
    raise exception 'member not found';
  end if;
  return v_member;
end;
$$;
