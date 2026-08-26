-- ============================================================================
-- 0066 — A host can show a member their own card.
--
-- Every member has had a scannable card since 0015, Guests included — the QR
-- resolves at the door and the recognition profile comes back correctly. The
-- gap was never the card; it was that the one person who needs to hand it over
-- could not see it.
--
-- member_cards is readable by the member themselves and by is_manager_up().
-- A host is below that line, so the role that actually works the door could
-- register a guest and then have nothing scannable to give them. The guest had
-- to sign into the portal to find a card they were standing next to a host to
-- receive.
--
-- This returns the card link and nothing else. Not spend, not tier history, not
-- contact details — the same information that is printed on the physical card
-- the host would otherwise be writing out by hand, for a member they are
-- already looking at. Reading it is logged, because a token that identifies a
-- member at a door deserves a record of who asked for it.
-- ============================================================================

create or replace function staff_member_card(p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff uuid := current_staff_id();
  v_row   record;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;

  select m.member_no, m.full_name, m.current_tier, c.qr_token
    into v_row
    from members m
    join member_cards c on c.member_id = m.id and c.status = 'active'
   where m.id = p_member_id and m.status = 'active'
   limit 1;

  if not found then
    raise exception 'no active card for that member';
  end if;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'member.card.shown',
    p_entity_type => 'members',
    p_entity_id   => p_member_id::text
  );

  return jsonb_build_object(
    'member_no', v_row.member_no,
    'full_name', v_row.full_name,
    'tier',      v_row.current_tier,
    'qr_token',  v_row.qr_token
  );
end;
$$;

revoke execute on function staff_member_card(uuid) from public, anon;
grant  execute on function staff_member_card(uuid) to authenticated;
