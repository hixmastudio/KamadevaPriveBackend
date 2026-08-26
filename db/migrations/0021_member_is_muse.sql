-- ============================================================================
-- 0021 — current_member_is_muse(): does the signed-in member hold an active
-- Muse membership? The muse schema has no client grants, so the member portal
-- reads this through a SECURITY DEFINER helper to decide whether to show the
-- aubergine Muse theme.
-- ============================================================================

create or replace function current_member_is_muse()
returns boolean
language sql
stable
security definer
set search_path = public, muse, pg_temp
as $$
  select exists (
    select 1 from muse.memberships mm
    where mm.member_id = current_member_id() and mm.status = 'active'
  );
$$;

revoke execute on function current_member_is_muse() from public, anon;
grant execute on function current_member_is_muse() to authenticated;
