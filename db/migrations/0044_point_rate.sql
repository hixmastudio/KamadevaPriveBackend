-- ============================================================================
-- 0044 — One point per ₦5,000, and one place that says so.
--
-- The earn rate was 1 point per ₦100, written as a bare 10000 in three
-- separate places: the constant in get_my_status, the divisor in
-- pos_attach_ticket, and again in the send-emails function. Three copies of one
-- business rule is three chances to change it in two places, and the rate is
-- exactly the sort of number a loyalty programme retunes.
--
-- So this moves it into program_config alongside the tier thresholds it is
-- read with, and points every caller at that. Changing the rate is now an
-- UPDATE, not a migration.
--
-- The new rate is ₦5,000 per point. Nothing about who qualifies for a tier
-- changes: promotion is still evaluated against spend in kobo
-- (tier_silver_spend_kobo and friends), and this only affects the number
-- members are shown. What they see does change, everywhere at once and
-- retroactively, because no points balance is stored anywhere — points are
-- always derived from spend:
--
--     Silver    20,000 points  ->    400
--     Gold      70,000 points  ->  1,400
--     Black    200,000 points  ->  4,000
--
-- A member sitting on 12,400 points today will open the portal on 248. That is
-- the intended effect of a rarer point, but it is a visible drop in a number
-- people attach meaning to, and worth a word to members who are already in.
-- ============================================================================

insert into program_config (key, value)
values ('points_kobo_per_point', '500000'::jsonb)
on conflict (key) do update set value = excluded.value;

comment on column program_config.value is
  'JSON scalar. points_kobo_per_point is kobo per Kamadeva Privé point — 500000 = one point per ₦5,000.';

CREATE OR REPLACE FUNCTION public.get_my_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_member members%rowtype;
  v_stats record;
  v_card member_cards%rowtype;
  -- 1 point per ₦100.
  v_kobo_per_point constant bigint := coalesce(config_int('points_kobo_per_point'), 500000);
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
$function$;

CREATE OR REPLACE FUNCTION public.pos_attach_ticket(p_venue_id uuid, p_ticket_no text, p_member_id uuid DEFAULT NULL::uuid, p_muse_member_id uuid DEFAULT NULL::uuid, p_client_capture_id uuid DEFAULT NULL::uuid, p_promotion_applied boolean DEFAULT false, p_discount_application_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_staff uuid := current_staff_id();
  v_ticket pos_tickets%rowtype;
  v_txn transactions%rowtype;
  v_name text;
  v_no text;
  v_kind text;
begin
  if v_staff is null or not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if (p_member_id is null) = (p_muse_member_id is null) then
    raise exception 'attribute the ticket to exactly one member';
  end if;

  select * into v_ticket from pos_tickets
  where venue_id = p_venue_id and ticket_no = trim(p_ticket_no)
  for update;
  if not found then
    raise exception 'no ticket % at this venue — check the number on the slip', p_ticket_no;
  end if;
  if v_ticket.voided_at is not null then
    raise exception 'ticket % was voided', p_ticket_no;
  end if;
  if v_ticket.member_id is not null or v_ticket.muse_member_id is not null then
    raise exception 'ticket % is already attributed', p_ticket_no;
  end if;

  if p_member_id is not null then
    -- Privé: the ticket's own total is the bill. close_bill captures the visit,
    -- applies discounts, writes the ledger row and triggers the tier engine.
    select full_name, member_no into v_name, v_no
      from members where id = p_member_id and status = 'active';
    if v_name is null then
      raise exception 'member not found';
    end if;
    v_kind := 'prive';

    v_txn := close_bill(
      p_venue_id => p_venue_id,
      p_member_id => p_member_id,
      p_gross_amount_kobo => v_ticket.total_kobo,
      p_client_capture_id => coalesce(p_client_capture_id, gen_random_uuid()),
      p_promotion_applied => p_promotion_applied,
      p_occurred_at => v_ticket.occurred_at,
      p_event_id => null,
      p_discount_application_id => p_discount_application_id
    );

    -- Stamp the ticket number on the ledger row: external_ref exists for POS
    -- reconciliation, and this is the link back to the printed slip.
    update transactions set external_ref = v_ticket.ticket_no where id = v_txn.id;

    update pos_tickets
      set member_id = p_member_id, transaction_id = v_txn.id,
          attributed_at = now(), attributed_by = v_staff
      where id = v_ticket.id;
  else
    -- Muse: recorded against her, and that is all. No ledger row, no points.
    select full_name, muse_no into v_name, v_no
      from muse.members where id = p_muse_member_id and status in ('active', 'paused');
    if v_name is null then
      raise exception 'Muse member not found';
    end if;
    v_kind := 'muse';

    update pos_tickets
      set muse_member_id = p_muse_member_id,
          attributed_at = now(), attributed_by = v_staff
      where id = v_ticket.id;

    perform log_audit('staff', auth.uid(), 'muse.spend.attribute',
                      'pos_tickets', v_ticket.id::text, p_venue_id);
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket.id,
    'ticket_no', v_ticket.ticket_no,
    'kind', v_kind,
    'full_name', v_name,
    'number', v_no,
    'total_kobo', v_ticket.total_kobo,
    'net_amount_kobo', case when v_txn.id is null then null else v_txn.net_amount_kobo end,
    'discount_kobo', case when v_txn.id is null then null else v_txn.discount_amount_kobo end,
    -- Kamadeva Privé points, at the rate in program_config.
    'points', case when v_txn.id is null then null
                   else floor(v_txn.net_amount_kobo::numeric
                              / coalesce(config_int('points_kobo_per_point'), 500000))::bigint end
  );
end;
$function$;
