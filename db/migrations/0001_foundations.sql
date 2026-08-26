-- ============================================================================
-- 0001 — Foundations: extensions, enums, helper functions.
-- Design doc: docs/decisions/000-implementation-plan.md §1, §3 conventions.
-- ============================================================================

create extension if not exists pg_trgm with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- ── Enums ───────────────────────────────────────────────────────────────────
-- Clients must decode enums resiliently: adding a value here must never crash
-- an app build that predates it.

create type tier_enum as enum ('guest', 'member', 'silver', 'gold', 'black');

create type staff_role as enum ('founder', 'hosl', 'venue_manager', 'host');

create type venue_type as enum ('lounge', 'club', 'events', 'kitchen', 'cabaret');

create type member_status as enum ('active', 'merged', 'erased');

create type consent_type as enum
  ('data_processing', 'marketing_whatsapp', 'marketing_email', 'photography');

create type consent_channel as enum ('door_tablet', 'portal', 'staff_entry', 'whatsapp');

create type capture_channel as enum
  ('entrance_tablet', 'qr_scan', 'card_scan', 'pos', 'reservation_checkin', 'manual_backfill');

create type txn_source as enum ('pos_confirm', 'csv_import', 'pos_webhook', 'manual_backfill');

create type reservation_status as enum
  ('requested', 'confirmed', 'seated', 'no_show', 'cancelled');

create type reservation_channel as enum ('portal', 'whatsapp', 'staff');

create type tier_event_reason as enum
  ('auto_promotion', 'approved_promotion', 'invitation_accepted',
   'demotion_window_decay', 'manual_correction', 'revocation');

create type approval_subject as enum
  ('tier_gold', 'tier_black', 'muse_membership', 'promo_stacking_exception', 'ndpr_erasure');

create type approval_status as enum ('pending', 'approved', 'declined', 'expired');

create type signoff_role as enum ('hosl', 'venue_manager', 'founder_rep');

create type invitation_kind as enum ('black', 'muse');

create type invitation_status as enum ('issued', 'accepted', 'declined', 'expired');

create type delegation_scope as enum ('muse_approval', 'tier_founder_rep');

create type eligibility_status as enum ('open', 'case_opened', 'dismissed');

create type discount_kind as enum ('automatic_tier', 'discretionary');

create type card_kind as enum ('prive', 'muse');

create type card_status as enum ('active', 'revoked');

create type actor_type as enum ('staff', 'member', 'system', 'service');

create type muse_candidate_status as enum
  ('submitted', 'under_review', 'approved', 'declined', 'withdrawn');

create type muse_membership_status as enum ('active', 'paused', 'exited');

create type muse_benefit_type as enum
  ('cocktail_50', 'comp_shots', 'comp_drink', 'priority_entry', 'content_opportunity');

create type collect_order_status as enum ('placed', 'accepted', 'ready', 'collected', 'cancelled');

create type comms_status as enum ('queued', 'sent', 'delivered', 'failed');

-- ── Helper functions ────────────────────────────────────────────────────────

-- The ONE authoritative phone normalizer (design doc §1). Client-side
-- formatting is UX only. Nigerian default: 0803… → +234803….
create or replace function normalize_phone(raw text)
returns text
language plpgsql
immutable
as $$
declare
  digits text;
begin
  if raw is null then
    return null;
  end if;
  digits := regexp_replace(raw, '[^0-9+]', '', 'g');
  if digits like '+%' then
    digits := '+' || regexp_replace(substr(digits, 2), '[^0-9]', '', 'g');
  elsif digits like '234%' then
    digits := '+' || digits;
  elsif digits like '0%' then
    digits := '+234' || substr(digits, 2);
  else
    digits := '+234' || digits;
  end if;
  if digits !~ '^\+[0-9]{8,15}$' then
    raise exception 'invalid phone number: %', raw
      using errcode = 'check_violation';
  end if;
  return digits;
end;
$$;

-- Business date: a 1 a.m. bill belongs to the previous night. Cutoff 06:00
-- Africa/Lagos (design doc §3.3). Declared IMMUTABLE knowingly — Africa/Lagos
-- has no DST and a stable UTC+1 offset; tzdata changes would be a manual
-- migration anyway. Required so generated columns can use it.
create or replace function kp_business_date(ts timestamptz)
returns date
language sql
immutable
as $$
  select ((ts at time zone 'Africa/Lagos') - interval '6 hours')::date;
$$;

-- Human-readable member numbers: KP-000001, never reused.
create sequence member_no_seq start 1;

create or replace function next_member_no()
returns text
language sql
volatile
as $$
  select 'KP-' || lpad(nextval('member_no_seq')::text, 6, '0');
$$;

-- Random, revocable QR token — never encodes member identity (design §3.8).
create or replace function new_qr_token()
returns text
language sql
volatile
as $$
  select encode(extensions.gen_random_bytes(16), 'hex');
$$;

-- ── Programme configuration ─────────────────────────────────────────────────
-- Thresholds and knobs are data, not hardcoded constants (design §3, §5 wk1-2).

create table program_config (
  key text primary key,
  value jsonb not null,
  description text,
  updated_at timestamptz not null default now()
);

insert into program_config (key, value, description) values
  ('tier_member_visits_90d', '3', 'Visits within rolling 90 days for auto-promotion to Member'),
  ('tier_silver_spend_kobo', '200000000', '₦2M annual spend threshold for Silver'),
  ('tier_silver_visits_12m', '15', 'Visit-count alternative threshold for Silver'),
  ('tier_gold_spend_kobo', '700000000', '₦7M annual spend eligibility for Gold (approval still required)'),
  ('tier_black_spend_kobo', '2000000000', '₦20M annual spend eligibility for Black (invitation still required)'),
  ('discount_gold_percent', '5', 'Automatic Gold discount percent in designated settings'),
  ('discount_black_percent', '8', 'Automatic Black discount percent in designated settings'),
  ('demotion_grace_days', '30', 'Grace period before Member/Silver window-decay demotion'),
  ('staff_capture_kpi_floor', '70', 'Minimum acceptable per-staff capture rate (percent)');

create or replace function config_int(p_key text)
returns bigint
language sql
stable
as $$
  select (value)::bigint from program_config where key = p_key;
$$;
