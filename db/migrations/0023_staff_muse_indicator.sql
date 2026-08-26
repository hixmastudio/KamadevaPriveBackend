-- ============================================================================
-- 0023 — Staff-side Muse indicator.
--
-- The Command Centre members list and profile need to show which members hold
-- an active Muse membership. The muse schema has no client grants, so this goes
-- through SECURITY DEFINER helpers — and the roster stays confidential: only
-- HoSL and founders get the flag. Venue managers (who can see the aggregate
-- count and their own initiations, but never the roster) and everyone below get
-- an empty set / false, so no Muse status leaks through these views.
-- ============================================================================

-- Active Muse member ids, for badging a members list in one round-trip.
create or replace function muse_member_ids()
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, muse, pg_temp
as $$
begin
  if current_staff_role() not in ('hosl', 'founder') then
    return array[]::uuid[]; -- roster is confidential below HoSL
  end if;
  return array(select member_id from muse.memberships where status = 'active');
end;
$$;

revoke execute on function muse_member_ids() from public, anon;
grant execute on function muse_member_ids() to authenticated;

-- Is one member an active Muse patron? For the staff profile page.
create or replace function member_is_muse(p_member_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, muse, pg_temp
as $$
begin
  if current_staff_role() not in ('hosl', 'founder') then
    return false; -- roster is confidential below HoSL
  end if;
  return exists (
    select 1 from muse.memberships
    where member_id = p_member_id and status = 'active'
  );
end;
$$;

revoke execute on function member_is_muse(uuid) from public, anon;
grant execute on function member_is_muse(uuid) to authenticated;
