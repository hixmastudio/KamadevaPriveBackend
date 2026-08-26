-- ============================================================================
-- 0059 — Exchange two members' numbers, and nothing else.
--
-- A member number is the one piece of a membership a person actually sees and
-- quotes: it is on the card, it is read at the door, it is what they give when
-- they call. Occasionally two get issued the wrong way round — at a busy door,
-- or across a pair of registrations taken minutes apart — and the fix is to
-- exchange them rather than to re-register anybody.
--
-- WHAT THIS MOVES: the number, and only the number. member_no is stored in
-- exactly one place in the database; every other table — visits, transactions,
-- tier_events, member_cards, reservations, collect_orders, consents — refers to
-- the member's UUID. So a swap cannot take anyone's history, spend, tier, card
-- or sign-in with it. That is worth knowing before running it, and worth
-- knowing after, when someone asks whether the visit count moved too. It did
-- not.
--
-- Founder-only, and a written reason is required. This edits the identifier a
-- member has been told is theirs; if it happens, the record should say who did
-- it and why.
--
-- The three-step shuffle through a temporary value is not fussiness — member_no
-- is UNIQUE, so assigning A's number to B while A still holds it fails outright.
-- The whole function is one statement to the caller, so a failure part-way
-- leaves neither member renumbered.
-- ============================================================================

create or replace function swap_member_numbers(
  p_member_no_a text,
  p_member_no_b text,
  p_reason      text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff uuid := current_staff_id();
  v_role  staff_role := current_staff_role();
  v_a     members%rowtype;
  v_b     members%rowtype;
  v_tmp   text;
begin
  -- Positive allow-check: current_staff_role() is NULL for a non-staff caller,
  -- and `<> 'founder'` on NULL is NULL, which never raises.
  if v_role is null or v_role <> 'founder' then
    raise exception 'only a founder can exchange member numbers';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then
    raise exception 'a written reason is required, and is kept on the record';
  end if;
  if trim(coalesce(p_member_no_a,'')) = trim(coalesce(p_member_no_b,'')) then
    raise exception 'those are the same member number';
  end if;

  -- Locked in a stable order so two concurrent swaps cannot deadlock.
  select * into v_a from members where member_no = upper(trim(p_member_no_a))
   order by member_no for update;
  if not found then raise exception 'no member with number %', p_member_no_a; end if;

  select * into v_b from members where member_no = upper(trim(p_member_no_b))
   order by member_no for update;
  if not found then raise exception 'no member with number %', p_member_no_b; end if;

  -- member_no is UNIQUE, so they cannot pass each other directly.
  v_tmp := 'SWAP-' || gen_random_uuid()::text;
  update members set member_no = v_tmp        where id = v_a.id;
  update members set member_no = v_a.member_no where id = v_b.id;
  update members set member_no = v_b.member_no where id = v_a.id;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'member.number.swap',
    p_entity_type => 'members',
    p_entity_id   => v_a.id::text,
    p_before      => jsonb_build_object('member_no', v_a.member_no),
    p_after       => jsonb_build_object('member_no', v_b.member_no, 'reason', trim(p_reason))
  );
  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'member.number.swap',
    p_entity_type => 'members',
    p_entity_id   => v_b.id::text,
    p_before      => jsonb_build_object('member_no', v_b.member_no),
    p_after       => jsonb_build_object('member_no', v_a.member_no, 'reason', trim(p_reason))
  );

  return jsonb_build_object(
    'swapped', true,
    'now_' || v_b.member_no, v_a.full_name,
    'now_' || v_a.member_no, v_b.full_name
  );
end;
$$;

revoke execute on function swap_member_numbers(text, text, text) from public, anon;
grant  execute on function swap_member_numbers(text, text, text) to authenticated;

comment on function swap_member_numbers(text, text, text) is
  'Founder-only. Exchanges two members'' numbers and nothing else — history,
   spend, tier, cards and sign-ins all key on the UUID and stay where they are.';

-- ── Moving one member to a free number ──────────────────────────────────────
-- The commoner case, and not a swap: the founders taking KP-000001 onward, or a
-- number corrected before anyone has quoted it. Separate function because the
-- preconditions genuinely differ — a swap needs both numbers to exist, this
-- needs the destination to be empty — and folding them together would mean one
-- function that silently does two different things depending on its arguments.

create or replace function renumber_member(
  p_from   text,
  p_to     text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff uuid := current_staff_id();
  v_role  staff_role := current_staff_role();
  v_m     members%rowtype;
  v_to    text := upper(trim(coalesce(p_to, '')));
begin
  if v_role is null or v_role <> 'founder' then
    raise exception 'only a founder can renumber a member';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then
    raise exception 'a written reason is required, and is kept on the record';
  end if;
  -- The column has no format constraint, so the shape is enforced here rather
  -- than trusting a caller not to invent one.
  if v_to !~ '^KP-[0-9]{6}$' then
    raise exception 'a member number looks like KP-000001, not %', p_to;
  end if;

  select * into v_m from members where member_no = upper(trim(p_from)) for update;
  if not found then
    raise exception 'no member with number %', p_from;
  end if;
  if v_m.member_no = v_to then
    raise exception 'that member already holds %', v_to;
  end if;
  if exists (select 1 from members where member_no = v_to) then
    raise exception '% is already held by another member — exchange them instead', v_to;
  end if;

  update members set member_no = v_to where id = v_m.id;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'member.number.change',
    p_entity_type => 'members',
    p_entity_id   => v_m.id::text,
    p_before      => jsonb_build_object('member_no', v_m.member_no),
    p_after       => jsonb_build_object('member_no', v_to, 'reason', trim(p_reason))
  );

  return jsonb_build_object('from', v_m.member_no, 'to', v_to, 'name', v_m.full_name);
end;
$$;

revoke execute on function renumber_member(text, text, text) from public, anon;
grant  execute on function renumber_member(text, text, text) to authenticated;

comment on function renumber_member(text, text, text) is
  'Founder-only. Moves a member to an unused number. Only the number moves —
   history, spend, tier, cards and sign-in all key on the UUID.';
