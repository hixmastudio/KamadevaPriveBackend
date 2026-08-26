-- ============================================================================
-- 0054 — Muse members are recognised and logged at the door.
--
-- Scanning a Muse card at the door returned "Card not recognized". The card was
-- perfectly valid; the door simply never looked for it. get_recognition_profile
-- resolves member_cards only, and since 0027 a Muse card lives in muse.cards.
-- So the one artefact the programme gives a Muse member — the thing §10.1 calls
-- the most visible object in the whole scheme — did nothing at the only moment
-- it exists for.
--
-- WHY A SEPARATE ARRIVAL LEDGER, rather than a nullable column on visits.
--
-- visits.member_id is NOT NULL and references public.members. A Muse member has
-- no row there, by design — 0027 made her a standalone subject precisely so the
-- tier engine could never reach her. Widening visits would mean making that
-- column nullable and then teaching all six of its readers to exclude Muse
-- rows: compute_member_stats, capture_visit, void_visit, merge_members,
-- pos_tonight_guests and get_recognition_profile. Miss one and a Muse arrival
-- starts counting toward a Privé tier, which is exactly what §7.5 of the
-- governance document forbids and what the standalone rework existed to
-- prevent. The separation is not duplication here; it is the guarantee.
--
-- So muse.arrivals is its own ledger, in the schema that already holds her
-- register, her card and her credentials. The tier engine cannot see it because
-- it does not know the table exists.
-- ============================================================================

create table if not exists muse.arrivals (
  id                uuid primary key default gen_random_uuid(),
  muse_member_id    uuid not null references muse.members (id) on delete restrict,
  venue_id          uuid not null references public.venues (id) on delete restrict,
  occurred_at       timestamptz not null default now(),
  -- Same 06:00 Lagos cut-off the rest of the platform runs on, so "tonight"
  -- means the same thing here as it does on every other screen.
  business_date     date generated always as (public.kp_business_date(occurred_at)) stored,
  capture_channel   public.capture_channel not null default 'qr_scan',
  captured_by       uuid not null references public.staff_profiles (id) on delete restrict,
  -- The door is a place where a tired host taps twice. Same idempotency key the
  -- Privé capture uses, so a double tap is one arrival.
  client_capture_id uuid not null,
  created_at        timestamptz not null default now(),
  constraint muse_arrivals_once unique (muse_member_id, client_capture_id)
);

create index if not exists muse_arrivals_night_idx on muse.arrivals (business_date desc, venue_id);
create index if not exists muse_arrivals_member_idx on muse.arrivals (muse_member_id, occurred_at desc);

drop trigger if exists muse_arrivals_audit on muse.arrivals;
create trigger muse_arrivals_audit
  after insert or update or delete on muse.arrivals
  for each row execute function public.audit_row_change();

-- The 0008 boundary, restated for a new table: RLS on with no policy, grants
-- revoked, reachable only through the definer functions below.
alter table muse.arrivals enable row level security;
revoke all on muse.arrivals from anon, authenticated;

-- ── Recognising her at the door ─────────────────────────────────────────────
-- One scanner, one function. The door should not have to know which programme
-- a card belongs to before it reads it, so the answer carries a 'kind' and the
-- terminal renders accordingly.

-- The parameter ORDER below must stay (qr_token, phone, member_id) — that is
-- the signature every existing caller and PostgREST already knows. Recreating
-- it with the arguments in a different order does not replace the function, it
-- overloads it, and PostgREST then refuses the call as ambiguous rather than
-- picking one. This drop clears exactly that mistake if it is already present.
drop function if exists get_recognition_profile(text, uuid, text);

create or replace function get_recognition_profile(
  p_qr_token  text default null,
  p_phone     text default null,
  p_member_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff        uuid := current_staff_id();
  v_member       members%rowtype;
  v_visits_month int;
  v_reservation  reservations%rowtype;
  v_muse         muse.members%rowtype;
  v_muse_month   int;
  v_benefits     jsonb;
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

  -- No Privé card matched. Before giving up, try the Muse register — this is
  -- the branch whose absence made a valid Muse card read as unrecognised.
  if v_member.id is null then
    if p_qr_token is not null then
      select mm.* into v_muse
        from muse.cards c join muse.members mm on mm.id = c.muse_member_id
       where c.qr_token = p_qr_token and c.status = 'active' and mm.status = 'active';
    elsif p_phone is not null then
      select * into v_muse from muse.members
       where phone = normalize_phone(p_phone) and status = 'active';
    end if;

    if v_muse.id is null then
      return null;
    end if;

    select count(*)::int into v_muse_month
      from muse.arrivals
     where muse_member_id = v_muse.id and occurred_at > date_trunc('month', now());

    select coalesce(jsonb_agg(distinct bg.type::text), '[]'::jsonb) into v_benefits
      from muse.memberships ms
      join muse.benefit_grants bg on bg.membership_id = ms.id
     where ms.member_id = v_muse.id and ms.status = 'active';

    return jsonb_build_object(
      'kind', 'muse',
      'muse_member_id', v_muse.id,
      'member_no', v_muse.muse_no,
      'full_name', v_muse.full_name,
      -- Explicitly null, not absent. A Muse holds no Privé tier and the door
      -- should show nothing where a tier badge would otherwise go.
      'tier', null,
      'visits_this_month', v_muse_month,
      'reservation_tonight', null,
      -- §7.4: priority entry across all venues, at all times.
      'priority_entry', true,
      'benefits_seen', v_benefits
    );
  end if;

  select count(*)::int into v_visits_month from visits
   where member_id = v_member.id and voided_at is null
     and occurred_at > date_trunc('month', now());

  select * into v_reservation from reservations
   where member_id = v_member.id and status in ('requested', 'confirmed')
     and kp_business_date(reserved_for) = kp_business_date(now())
   order by reserved_for limit 1;

  return jsonb_build_object(
    'kind', 'prive',
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

-- ── Logging the arrival ─────────────────────────────────────────────────────

create or replace function muse_capture_arrival(
  p_muse_member_id    uuid,
  p_venue_id          uuid,
  p_channel           public.capture_channel default 'qr_scan',
  p_client_capture_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff uuid := current_staff_id();
  v_row   muse.arrivals%rowtype;
begin
  -- Any member of staff working a door may record an arrival, exactly as they
  -- may for a Privé member. Reading the Muse register is the restricted act,
  -- not welcoming someone who is standing in front of you.
  if v_staff is null then
    raise exception 'staff session required';
  end if;
  -- Checked explicitly, and before the venue guard. staff_has_venue() returns
  -- TRUE outright for a founder or the HoSL whatever venue it is handed —
  -- including none at all — so a null would sail past it and fail later on the
  -- NOT NULL constraint, reporting a database error to a host at a door
  -- instead of saying which venue is missing.
  if p_venue_id is null then
    raise exception 'a venue is required to record an arrival';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if not exists (select 1 from muse.members where id = p_muse_member_id and status = 'active') then
    raise exception 'not an active Muse member';
  end if;

  insert into muse.arrivals (muse_member_id, venue_id, capture_channel,
                             captured_by, client_capture_id)
  values (p_muse_member_id, p_venue_id, coalesce(p_channel, 'qr_scan'),
          v_staff, coalesce(p_client_capture_id, gen_random_uuid()))
  on conflict (muse_member_id, client_capture_id) do nothing
  returning * into v_row;

  -- A repeated tap is not an error; it is the same arrival.
  if v_row.id is null then
    select * into v_row from muse.arrivals
     where muse_member_id = p_muse_member_id and client_capture_id = p_client_capture_id;
  end if;

  return jsonb_build_object('arrival_id', v_row.id, 'occurred_at', v_row.occurred_at,
                            'business_date', v_row.business_date);
end;
$$;

-- ── What the Muse tab shows ─────────────────────────────────────────────────
-- VOLATILE deliberately: like the other Muse readers it records that the
-- register was looked at, and PostgREST runs a STABLE function in a read-only
-- transaction, where that write fails and takes the read with it (see 0053).

create or replace function muse_recent_arrivals(p_days int default 14)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_role staff_role := current_staff_role();
begin
  if v_role is null or v_role not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'the Muse register is read by venue managers and above';
  end if;

  perform log_audit('staff', auth.uid(), 'muse.arrivals.read', 'muse.arrivals', null);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'arrival_id', a.id,
             'muse_no',    m.muse_no,
             'full_name',  m.full_name,
             'venue_name', v.name,
             'occurred_at', a.occurred_at,
             'business_date', a.business_date
           ) order by a.occurred_at desc)
      from muse.arrivals a
      join muse.members m on m.id = a.muse_member_id
      left join venues v on v.id = a.venue_id
     where a.business_date >= current_date - greatest(coalesce(p_days, 14), 1)
  ), '[]'::jsonb);
end;
$$;

revoke execute on function muse_capture_arrival(uuid, uuid, public.capture_channel, uuid) from public, anon;
revoke execute on function muse_recent_arrivals(int) from public, anon;
grant  execute on function muse_capture_arrival(uuid, uuid, public.capture_channel, uuid) to authenticated;
grant  execute on function muse_recent_arrivals(int) to authenticated;
