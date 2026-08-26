-- ============================================================================
-- 0036 — The Muse roster: who is actually in the circle.
--
-- The staff Muse desk only ever showed the PIPELINE — candidates in flight. The
-- moment someone was onboarded she fell out of view, so there was no way to
-- answer "who are our Muses?", let alone see her details, whether she is still
-- coming, or what the house has given her.
--
-- Visibility follows the Governance & Access note (§4): the full member list
-- belongs to owners/founders (full visibility) and the Head of Sales & Loyalty
-- (full operational visibility). A venue manager sees only candidates they put
-- forward — muse_list_pipeline already enforces that — and never the roster.
-- Hosts get recognition at the door and nothing else.
--
-- Reads are logged, as every Muse read is.
-- ============================================================================

create or replace function muse_list_members()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_result jsonb;
begin
  if v_role is null or v_role not in ('hosl', 'founder') then
    raise exception 'the Muse roster is visible to the HoSL and founders';
  end if;

  perform log_audit('staff', auth.uid(), 'muse.roster.read', 'muse.members', null);

  select coalesce(jsonb_agg(row_data order by sort_name), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'muse_member_id', mm.id,
      'muse_no', mm.muse_no,
      'full_name', mm.full_name,
      'phone', mm.phone,
      'email', mm.email,
      'date_of_birth', mm.date_of_birth,
      -- Age is what the team actually reads; the date is there when needed.
      'age', extract(year from age(mm.date_of_birth))::int,
      'status', mm.status,
      'joined_at', ms.onboarded_at,
      'onboarded_by', sp.full_name,
      'has_portal', mm.auth_user_id is not null,
      'card_token', mc.qr_token,
      -- Is she actually coming, and what has the house given her?
      'visits', coalesce(t.tickets, 0),
      'spend_kobo', coalesce(t.spend, 0),
      'last_seen', t.last_seen,
      'benefits_given', coalesce(b.given, 0),
      'last_benefit_at', b.last_at
    ) as row_data, mm.full_name as sort_name
    from muse.members mm
    left join muse.memberships ms on ms.member_id = mm.id and ms.status = 'active'
    left join staff_profiles sp on sp.id = ms.onboarded_by
    left join muse.cards mc on mc.muse_member_id = mm.id and mc.status = 'active'
    left join lateral (
      select count(*)::int as tickets,
             sum(pt.total_kobo)::bigint as spend,
             max(pt.occurred_at) as last_seen
      from pos_tickets pt
      where pt.muse_member_id = mm.id and pt.voided_at is null
    ) t on true
    left join lateral (
      select count(*)::int as given, max(bg.created_at) as last_at
      from muse.benefit_grants bg
      where bg.membership_id = ms.id
    ) b on true
    where mm.status in ('active', 'paused')
  ) s;

  return v_result;
end;
$$;

revoke execute on function muse_list_members() from public, anon;
grant  execute on function muse_list_members() to authenticated;
