-- ============================================================================
-- 0057 — A founder can place a member on any tier directly.
--
-- The ladder is earned: visits promote to Member and Silver automatically, and
-- Gold and Black are gated behind an approval (§5.1, §14.5). That is right for
-- the ordinary case and wrong for the ones that actually matter — the guest who
-- should obviously be Black tonight because of who they are rather than what
-- they have spent yet, or a tier applied in error that needs undoing before the
-- member notices.
--
-- IT DOES NOT BYPASS THE APPROVAL GATE. tier_events_gate refuses any promotion
-- to Gold or Black without an approved, unconsumed approval naming that member
-- and that tier. The lazy implementation adds 'manual_correction' to the gate's
-- exemption list, which would weaken the control for every caller in order to
-- serve one. Instead this creates the approval, records the founder as both the
-- requester and the deciding authority, and consumes it — which is exactly what
-- happened. §14.1 puts oversight with the founders and §5.1 makes Black an
-- invitation from management; a founder IS the approving authority, so the
-- paper trail should say so rather than route around itself.
--
-- The audit therefore reads: founder X approved member Y for Black at time Z
-- with this written reason, and that approval produced this tier event. A month
-- later nobody has to guess whether it was earned or granted.
--
-- Safe against the nightly jobs, which is not obvious and was checked:
--   • recompute_member_tier only auto-promotes INTO member/silver and only from
--     guest/member, so it cannot touch a granted Gold or Black.
--   • sweep_tier_decay only demotes member/silver; for gold/black it writes a
--     review flag to the audit log and changes nothing.
-- A granted tier therefore stands until a person moves it.
-- ============================================================================

create or replace function set_member_tier(
  p_member_id uuid,
  p_tier      tier_enum,
  p_reason    text
)
returns members
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
declare
  v_staff       uuid := current_staff_id();
  v_role        staff_role := current_staff_role();
  v_member      members%rowtype;
  v_approval_id uuid;
  v_event_id    uuid;
  v_promoting   boolean;
begin
  -- Positive allow-check. current_staff_role() is NULL for a non-staff caller
  -- and `<> 'founder'` on a NULL is NULL, which is not true and therefore does
  -- not raise — the guard would wave every member straight through.
  if v_role is null or v_role <> 'founder' then
    raise exception 'only a founder can place a member on a tier directly';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 10 then
    raise exception 'a written reason is required, and is kept on the record';
  end if;

  select * into v_member from members where id = p_member_id for update;
  if not found then
    raise exception 'member not found';
  end if;
  if v_member.status <> 'active' then
    raise exception 'this membership is not active';
  end if;
  if v_member.current_tier = p_tier then
    raise exception 'this member is already %', p_tier;
  end if;

  v_promoting := p_tier in ('gold', 'black');

  if v_promoting then
    -- Satisfy the gate honestly rather than exempt ourselves from it.
    insert into approvals (subject_type, member_id, target_tier, status,
                           requested_by, rationale, decided_by, decided_at,
                           decision_reason)
    values (
      case p_tier when 'gold' then 'tier_gold' else 'tier_black' end::approval_subject,
      p_member_id, p_tier, 'approved', v_staff, trim(p_reason), v_staff, now(),
      'Granted directly by a founder.'
    )
    returning id into v_approval_id;
  end if;

  insert into tier_events (member_id, from_tier, to_tier, reason, approval_id,
                           stats_snapshot, effected_by, staff_id)
  values (
    p_member_id, v_member.current_tier, p_tier,
    case when v_promoting then 'approved_promotion' else 'manual_correction' end::tier_event_reason,
    v_approval_id,
    jsonb_build_object('granted_by_founder', true, 'reason', trim(p_reason)),
    'staff'::actor_type, v_staff
  )
  returning id into v_event_id;

  if v_approval_id is not null then
    update approvals set consumed_by_tier_event_id = v_event_id where id = v_approval_id;
  end if;

  update members
     set current_tier = p_tier, tier_computed_at = now()
   where id = p_member_id
   returning * into v_member;

  perform log_audit(
    p_actor_type  => 'staff'::actor_type,
    p_actor_id    => v_staff,
    p_action      => 'tier.set.founder',
    p_entity_type => 'members',
    p_entity_id   => p_member_id::text,
    p_after       => jsonb_build_object('to_tier', p_tier, 'reason', trim(p_reason))
  );

  return v_member;
end;
$$;

revoke execute on function set_member_tier(uuid, tier_enum, text) from public, anon;
grant  execute on function set_member_tier(uuid, tier_enum, text) to authenticated;

comment on function set_member_tier(uuid, tier_enum, text) is
  'Founder-only. Places a member on any tier, creating and consuming an approval
   where the target is Gold or Black so the approval gate is satisfied rather
   than bypassed. The written reason is kept in the tier event and the audit log.';
