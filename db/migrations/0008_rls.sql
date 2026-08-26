-- ============================================================================
-- 0008 — Row-Level Security. Design doc §4.
--
-- Principles:
--  * RLS shapes READS. Sensitive writes have NO insert/update policies —
--    they go exclusively through SECURITY DEFINER RPCs (0009).
--  * Hosts have zero direct access to members or muse.* — the recognition
--    RPC is their only lookup surface.
--  * JWT claims are never trusted; helpers re-verify against tables.
--  * muse schema: no grants at all to anon/authenticated → the namespace
--    boundary itself denies access; HoSL/founder read via logging RPCs.
-- ============================================================================

-- ── Enable RLS everywhere ───────────────────────────────────────────────────

alter table program_config enable row level security;
alter table audit_events enable row level security;
alter table venues enable row level security;
alter table members enable row level security;
alter table consents enable row level security;
alter table staff_profiles enable row level security;
alter table staff_venue_assignments enable row level security;
alter table visits enable row level security;
alter table transactions enable row level security;
alter table shift_entry_counts enable row level security;
alter table reservations enable row level security;
alter table approvals enable row level security;
alter table tier_approval_signoffs enable row level security;
alter table approval_delegations enable row level security;
alter table tier_events enable row level security;
alter table invitations enable row level security;
alter table eligibility_flags enable row level security;
alter table member_rolling_stats enable row level security;
alter table discount_designations enable row level security;
alter table delegated_limits enable row level security;
alter table discount_applications enable row level security;
alter table events enable row level security;
alter table event_access_windows enable row level security;
alter table member_cards enable row level security;
alter table catalog_items enable row level security;
alter table collect_orders enable row level security;
alter table collect_order_items enable row level security;
alter table comms_messages enable row level security;

alter table muse.candidates enable row level security;
alter table muse.memberships enable row level security;
alter table muse.event_calendar enable row level security;
alter table muse.benefit_grants enable row level security;
alter table muse.content_agreements enable row level security;

-- muse schema: the hard boundary. No usage grant to client roles at all.
revoke all on schema muse from public;
revoke all on all tables in schema muse from anon, authenticated;

-- Convenience predicates.
create or replace function is_staff()
returns boolean language sql stable
security definer set search_path = public, pg_temp
as $$ select current_staff_id() is not null $$;

create or replace function is_manager_up()
returns boolean language sql stable
security definer set search_path = public, pg_temp
as $$ select current_staff_role() in ('venue_manager', 'hosl', 'founder') $$;

create or replace function is_hosl_up()
returns boolean language sql stable
security definer set search_path = public, pg_temp
as $$ select current_staff_role() in ('hosl', 'founder') $$;

-- ── Reference data ──────────────────────────────────────────────────────────

create policy venues_read on venues for select to authenticated using (true);
create policy config_read on program_config for select to authenticated
  using (is_staff());

-- ── Members: VM+ read; hosts get NOTHING here (recognition RPC only §4.2) ──
-- Portal members (Phase 2) read exactly their own row.

create policy members_staff_read on members for select to authenticated
  using (is_manager_up());
create policy members_self_read on members for select to authenticated
  using (auth_user_id = auth.uid());
-- No INSERT/UPDATE policies: writes via RPCs only.

create policy consents_staff_read on consents for select to authenticated
  using (is_manager_up());
create policy consents_self_read on consents for select to authenticated
  using (member_id = current_member_id());

-- ── Staff ───────────────────────────────────────────────────────────────────
-- Every active staff member can see the staff list minus PIN hashes (column
-- protection via view in app; base read limited to managers+ and self).

create policy staff_self_read on staff_profiles for select to authenticated
  using (auth_user_id = auth.uid());
create policy staff_manager_read on staff_profiles for select to authenticated
  using (is_manager_up());
create policy sva_read on staff_venue_assignments for select to authenticated
  using (is_staff());

-- ── Activity ledger: venue-scoped reads; writes via RPCs only ───────────────

create policy visits_read on visits for select to authenticated
  using (is_staff() and staff_has_venue(venue_id));
create policy transactions_read on transactions for select to authenticated
  using (is_manager_up() and staff_has_venue(venue_id));
create policy shift_entry_counts_read on shift_entry_counts for select to authenticated
  using (is_staff() and staff_has_venue(venue_id));

create policy reservations_staff_read on reservations for select to authenticated
  using (is_staff() and staff_has_venue(venue_id));
create policy reservations_self_read on reservations for select to authenticated
  using (member_id = current_member_id());

-- ── Tier machinery: manager+ visibility; ZERO write policies (gate §4.4) ────

create policy tier_events_read on tier_events for select to authenticated
  using (is_manager_up());
create policy eligibility_flags_read on eligibility_flags for select to authenticated
  using (is_manager_up());
create policy approvals_read on approvals for select to authenticated
  using (is_manager_up());
create policy signoffs_read on tier_approval_signoffs for select to authenticated
  using (is_manager_up());
create policy delegations_read on approval_delegations for select to authenticated
  using (is_hosl_up());
create policy invitations_read on invitations for select to authenticated
  using (is_hosl_up());
create policy rolling_stats_read on member_rolling_stats for select to authenticated
  using (is_manager_up());

-- ── Discounts ───────────────────────────────────────────────────────────────

create policy designations_read on discount_designations for select to authenticated
  using (is_staff());
create policy delegated_limits_read on delegated_limits for select to authenticated
  using (is_hosl_up() or staff_id = current_staff_id());
create policy discount_applications_read on discount_applications for select to authenticated
  using (is_manager_up() and staff_has_venue(venue_id));

-- ── Events & cards ──────────────────────────────────────────────────────────

create policy events_staff_read on events for select to authenticated
  using (is_staff());
create policy event_windows_read on event_access_windows for select to authenticated
  using (true);
create policy member_cards_staff_read on member_cards for select to authenticated
  using (is_manager_up());
create policy member_cards_self_read on member_cards for select to authenticated
  using (member_id = current_member_id());

-- ── Click-and-collect & comms (Phase 2/3 surfaces) ─────────────────────────

create policy catalog_read on catalog_items for select to authenticated
  using (true);
create policy collect_orders_staff_read on collect_orders for select to authenticated
  using (is_staff() and staff_has_venue(venue_id));
create policy collect_orders_self on collect_orders for select to authenticated
  using (member_id = current_member_id());
create policy collect_items_read on collect_order_items for select to authenticated
  using (exists (
    select 1 from collect_orders o
    where o.id = order_id
      and ((is_staff() and staff_has_venue(o.venue_id)) or o.member_id = current_member_id())
  ));
create policy comms_read on comms_messages for select to authenticated
  using (is_hosl_up());

-- ── Audit: HoSL/founder full; VMs their own venue's rows (§4 matrix) ────────

create policy audit_read on audit_events for select to authenticated
  using (
    is_hosl_up()
    or (current_staff_role() = 'venue_manager'
        and venue_id is not null
        and staff_has_venue(venue_id))
  );

-- ── Column hardening ────────────────────────────────────────────────────────
-- pin_hash must never reach any client, including its owner.
revoke select (pin_hash) on staff_profiles from anon, authenticated;

-- Sensitive write paths: belt-and-braces revokes (RLS already denies —
-- no write policies exist — but explicit revokes survive policy mistakes).
revoke insert, update, delete on
  members, consents, visits, transactions, reservations, tier_events,
  approvals, tier_approval_signoffs, approval_delegations, invitations,
  eligibility_flags, member_rolling_stats, discount_designations,
  delegated_limits, discount_applications, member_cards, audit_events,
  shift_entry_counts, program_config, staff_profiles, staff_venue_assignments,
  venues, events, event_access_windows, catalog_items, collect_orders,
  collect_order_items, comms_messages
from anon, authenticated;

-- Realtime: the arrival flag rides postgres_changes on visits (§5 wk5-6).
do $$
begin
  alter publication supabase_realtime add table visits;
exception when others then
  raise notice 'supabase_realtime publication not present here (%)', sqlerrm;
end;
$$;
