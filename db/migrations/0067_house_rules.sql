-- ============================================================================
-- 0067 — Three house rules corrected.
--
-- 1. FOUR MONTHS, NOT THIRTY DAYS, before standing decays.
--
-- The grace period said 30 days. For a members' club that is punishing: a
-- member who travels for a season, or simply has a quiet couple of months,
-- came back to find their tier gone. Four months is long enough that losing
-- standing means someone genuinely stopped coming, which is the only thing the
-- decay is meant to detect.
--
-- 2. ONE DISCOUNT OR THE OTHER, NEVER BOTH.
--
-- The tier gate already refused Gold and Black, but explained itself in terms
-- of tiers — which tells a manager the rule and not the reason. It now looks up
-- what the member is already receiving at that venue and says so: "Black
-- already receives 8% automatically here". It also refuses a SECOND
-- discretionary discount on the same night, which was the other way a single
-- bill could end up discounted twice.
--
-- Checking the designation rather than hardcoding gold/black matters: the
-- designations are data the Head of Sales & Loyalty edits, so if Silver is ever
-- given an automatic discount at a venue, this refuses stacking on it the same
-- day — without anyone remembering to come back and change this function.
-- ============================================================================

update program_config
   set value = '120',
       description = 'Grace period before Member/Silver window-decay demotion. Four months — long enough that losing standing means someone genuinely stopped coming.',
       updated_at = now()
 where key = 'demotion_grace_days';

-- Recreated from the live definition with the stacking guards added.

CREATE OR REPLACE FUNCTION public.apply_discretionary_discount(p_member_id uuid, p_venue_id uuid, p_amount_kobo bigint, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_approver uuid := current_staff_id();
  v_role staff_role := current_staff_role();
  v_member members%rowtype;
  v_limit delegated_limits%rowtype;
  v_month date := date_trunc('month', now())::date;
  v_spent bigint;
  v_auto_percent numeric;
  v_id uuid;
begin
  if v_approver is null or v_role not in ('venue_manager', 'hosl') then
    raise exception 'discretionary discounts are approved only by venue managers or the HoSL';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if p_amount_kobo is null or p_amount_kobo <= 0 then
    raise exception 'discount amount must be positive';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'a reason is required for every discretionary discount';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found or v_member.status != 'active' then
    raise exception 'member not found';
  end if;
  -- You get one or the other, never both. The tier gate already blocked Gold
  -- and Black, but it explained itself in terms of tiers — which tells a
  -- manager the rule and not the reason. Look up what the member is ALREADY
  -- receiving here and say that instead, so the answer is about this bill
  -- rather than about policy.
  select coalesce(d.percent, 0) into v_auto_percent
    from discount_designations d
   where d.tier = v_member.current_tier
     and (d.venue_id is null or d.venue_id = p_venue_id)
     and d.active_from <= now()
     and (d.active_to is null or d.active_to > now())
   order by d.venue_id nulls last
   limit 1;

  if coalesce(v_auto_percent, 0) > 0 then
    raise exception
      '% already receives % per cent automatically here — a discretionary discount cannot be added on top',
      initcap(v_member.current_tier::text), rtrim(rtrim(to_char(v_auto_percent, 'FM990.00'), '0'), '.');
  end if;

  if v_member.current_tier not in ('member', 'silver') then
    raise exception
      'discretionary discounts are for Member and Silver — % is served by its own automatic discount',
      initcap(v_member.current_tier::text);
  end if;

  -- And not twice on the same night, which is the other way one bill ends up
  -- discounted more than once.
  if exists (
    select 1 from discount_applications
     where member_id = p_member_id
       and venue_id = p_venue_id
       and kind = 'discretionary'
       and kp_business_date(created_at) = kp_business_date(now())
  ) then
    raise exception 'a discretionary discount has already been approved for this member tonight';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_approver::text || to_char(v_month, 'YYYY-MM')));

  select * into v_limit
  from delegated_limits
  where staff_id = v_approver and venue_id = p_venue_id and period_month = v_month;

  if not found then
    raise exception 'no delegated limit set for you at this venue this month — escalate to HoSL';
  end if;

  select coalesce(sum(amount_kobo), 0) into v_spent
  from discount_applications
  where approved_by_staff_id = v_approver
    and delegated_limit_id = v_limit.id
    and kind = 'discretionary';

  if v_spent + p_amount_kobo > v_limit.limit_kobo then
    raise exception 'monthly discretionary envelope exceeded (spent % + % > limit %) — escalate to HoSL',
      v_spent, p_amount_kobo, v_limit.limit_kobo;
  end if;

  insert into discount_applications
    (member_id, venue_id, kind, approved_by_staff_id, delegated_limit_id, reason, amount_kobo)
  values
    (p_member_id, p_venue_id, 'discretionary', v_approver, v_limit.id, trim(p_reason), p_amount_kobo)
  returning id into v_id;

  perform log_audit('staff', auth.uid(), 'discount.discretionary.approve',
                    'discount_applications', v_id::text, p_venue_id,
                    null, jsonb_build_object('member_id', p_member_id, 'amount_kobo', p_amount_kobo));
  return v_id;
end;
$function$
;

-- ── 3. Click & collect is not open yet ──────────────────────────────────────
--
-- The shop lists three hundred real menu items and takes orders nobody is set
-- up to fulfil — no venue has a collection process running, and an order placed
-- tonight would go to a counter that is not expecting it. The menu is worth
-- browsing; the ordering is not ready.
--
-- Done as a config flag rather than by removing the button, because the whole
-- feature works and the only thing missing is the operation behind it. When the
-- venues are ready this becomes 'true' and nothing needs deploying.
--
-- Guarded in the database as well as the UI. A member on a cached bundle would
-- otherwise still be able to place an order that nobody sees.

insert into program_config (key, value, description)
values ('collect_orders_open', 'false',
        'Whether click & collect accepts orders. False shows the shop as browsable with ordering marked coming soon.')
on conflict (key) do nothing;

-- program_config.value is jsonb, and config_int is the only accessor. A flag
-- deserves the same treatment rather than each caller repeating the cast and
-- one of them eventually getting it wrong.
create or replace function config_bool(p_key text)
returns boolean
language sql
stable
set search_path to 'public', 'pg_temp'
as $$
  select coalesce((value)::boolean, false) from program_config where key = p_key;
$$;

-- Recreated from the live definition with the not-open-yet guard added.

CREATE OR REPLACE FUNCTION public.place_collect_order(p_venue_id uuid, p_items jsonb, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_member_id uuid := current_member_id();
  v_order_id uuid;
  v_line jsonb;
  v_item catalog_items%rowtype;
  v_count int := 0;
begin
  perform assert_venue_accepts(p_venue_id, 'orders');

  -- Not open yet (0067). Checked here as well as in the portal, so a cached
  -- bundle cannot place an order into a service that is not running.
  if not config_bool('collect_orders_open') then
    raise exception 'click & collect is not open yet — the menu is here to browse, ordering opens soon';
  end if;
  if v_member_id is null then
    raise exception 'member sign-in required';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'the order is empty';
  end if;

  insert into collect_orders (member_id, venue_id, notes)
  values (v_member_id, p_venue_id, p_notes)
  returning id into v_order_id;

  for v_line in select * from jsonb_array_elements(p_items) loop
    select * into v_item from catalog_items
    where id = (v_line->>'catalog_item_id')::uuid
      and venue_id = p_venue_id and is_active;
    if not found then
      raise exception 'an item in the order is no longer available';
    end if;
    if coalesce((v_line->>'quantity')::int, 0) < 1 then
      continue;
    end if;
    insert into collect_order_items (order_id, catalog_item_id, quantity, unit_price_kobo)
    values (v_order_id, v_item.id, (v_line->>'quantity')::int, v_item.price_kobo);
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'the order is empty';
  end if;
  return v_order_id;
end;
$function$
;
