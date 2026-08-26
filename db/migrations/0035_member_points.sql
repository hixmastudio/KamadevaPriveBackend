-- ============================================================================
-- 0035 — Members see Kamadeva Privé points, never naira.
--
-- The portal showed a member their rolling spend and the next tier's threshold
-- in cash ("₦11,264,879 of ₦20,000,000"). Progression should read as points:
-- it is the language of a membership, and putting a member's spend on their own
-- phone is both crude and needlessly exposing.
--
-- Rate: 1 Kamadeva Privé point per ₦100 (kobo / 10,000).
--
-- Enforced at the source rather than in the client: get_my_status simply stops
-- returning money. There is no spend_12m_kobo and no kobo threshold in the
-- member-facing payload, so no future UI change can leak it back. Staff keep the
-- naira view — they read the ledger and member_rolling_stats through their own
-- role-scoped surfaces, which are untouched.
--
-- Muse members are unaffected: they have no tier and earn no points, and their
-- portal (get_my_muse_status) never carried figures at all.
-- ============================================================================

create or replace function get_my_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
  v_stats record;
  v_card member_cards%rowtype;
  -- 1 point per ₦100.
  v_kobo_per_point constant bigint := 10000;
begin
  select * into v_member from members
  where auth_user_id = auth.uid() and status = 'active';
  if not found then
    return null;
  end if;

  select * into v_stats from compute_member_stats(v_member.id);

  select * into v_card from member_cards
  where member_id = v_member.id and kind = 'prive' and status = 'active';

  return jsonb_build_object(
    'member_id', v_member.id,
    'full_name', v_member.full_name,
    'member_no', v_member.member_no,
    'tier', v_member.current_tier,
    'phone', v_member.phone,
    'email', v_member.email,
    'card_token', v_card.qr_token,
    'stats', jsonb_build_object(
      'visits_90d', v_stats.visits_90d,
      'visits_12m', v_stats.visits_12m,
      -- Points earned over the rolling 12 months. No naira figure is returned.
      'points_12m', floor(v_stats.spend_12m_kobo / v_kobo_per_point)::bigint
    ),
    'thresholds', jsonb_build_object(
      'member_visits_90d', config_int('tier_member_visits_90d'),
      'silver_visits_12m', config_int('tier_silver_visits_12m'),
      'silver_points', floor(config_int('tier_silver_spend_kobo') / v_kobo_per_point)::bigint,
      'gold_points',   floor(config_int('tier_gold_spend_kobo')   / v_kobo_per_point)::bigint,
      'black_points',  floor(config_int('tier_black_spend_kobo')  / v_kobo_per_point)::bigint
    ),
    'consents', (
      select coalesce(jsonb_object_agg(consent_type, granted), '{}'::jsonb)
      from current_consents where member_id = v_member.id
    )
  );
end;
$$;
