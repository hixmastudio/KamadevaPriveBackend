-- ============================================================================
-- 0033 — POS becomes attribution, not data entry.
--
-- The POS surface used to ask the host to key the bill amount by hand, which is
-- both slow at 11:40pm and a second source of truth for money Samba already
-- knows. Now the till closes the bill and Samba owns the receipt; the host's job
-- is only to say WHO it belonged to.
--
-- New flow: identify the guest (Privé member or standalone Muse), type the
-- ticket number off the slip, confirm. That is the whole interaction.
--
-- For a Privé member this delegates to close_bill() with the ticket's own total,
-- so everything that already hangs off a closed bill still happens exactly once:
-- the visit is captured, Gold/Black automatic discounts and any pre-approved
-- discretionary amount are applied, the transaction lands in the ledger, and the
-- tier engine recomputes off it. Nothing about that logic is duplicated here.
--
-- For a standalone Muse member the ticket is recorded against her and nothing
-- else: no transaction row, no points, no tier movement. Muse runs parallel to
-- Privé and has no ladder (see 0027–0029), and transactions.member_id cannot
-- reference a Muse subject anyway. Her spend history stays on pos_tickets.
-- ============================================================================

-- Look up a ticket by its printed number, so the host can confirm the total
-- and lines before attributing it to anyone.
create or replace function pos_lookup_ticket(p_venue_id uuid, p_ticket_no text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ticket pos_tickets%rowtype;
begin
  if current_staff_id() is null or not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;

  select * into v_ticket from pos_tickets
  where venue_id = p_venue_id and ticket_no = trim(p_ticket_no);
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'id', v_ticket.id,
    'ticket_no', v_ticket.ticket_no,
    'occurred_at', v_ticket.occurred_at,
    'cashier', v_ticket.cashier,
    'table_label', v_ticket.table_label,
    'subtotal_kobo', v_ticket.subtotal_kobo,
    'vat_kobo', v_ticket.vat_kobo,
    'consumption_tax_kobo', v_ticket.consumption_tax_kobo,
    'total_kobo', v_ticket.total_kobo,
    'voided', v_ticket.voided_at is not null,
    'already_attributed', (v_ticket.member_id is not null or v_ticket.muse_member_id is not null),
    'attributed_name', coalesce(
      (select full_name from members where id = v_ticket.member_id),
      (select full_name from muse.members where id = v_ticket.muse_member_id)),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', i.name, 'quantity', i.quantity, 'line_total_kobo', i.line_total_kobo
      ) order by i.line_no)
      from pos_ticket_items i where i.ticket_id = v_ticket.id
    ), '[]'::jsonb)
  );
end;
$$;

-- Attribute a ticket to a Privé member OR a standalone Muse member.
create or replace function pos_attach_ticket(
  p_venue_id uuid,
  p_ticket_no text,
  p_member_id uuid default null,
  p_muse_member_id uuid default null,
  p_client_capture_id uuid default null,
  p_promotion_applied boolean default false,
  p_discount_application_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
    -- Kamadeva Privé points: 1 point per ₦100 of the bill actually paid.
    'points', case when v_txn.id is null then null
                   else floor(v_txn.net_amount_kobo / 10000.0)::bigint end
  );
end;
$$;

revoke execute on function pos_lookup_ticket(uuid, text) from public, anon;
grant  execute on function pos_lookup_ticket(uuid, text) to authenticated;
revoke execute on function pos_attach_ticket(uuid, text, uuid, uuid, uuid, boolean, uuid) from public, anon;
grant  execute on function pos_attach_ticket(uuid, text, uuid, uuid, uuid, boolean, uuid) to authenticated;
