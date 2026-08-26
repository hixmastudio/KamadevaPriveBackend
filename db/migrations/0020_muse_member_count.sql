-- ============================================================================
-- 0020 — muse_member_count() (audit fix).
--
-- The Command Centre's "Muse members" KPI was a hardcoded 0 with "activates
-- in Phase 2" copy — but Phase 2 shipped. The muse schema deliberately has
-- zero direct grants, so the dashboard needs an audited-boundary RPC that
-- returns just the aggregate (no roster exposure: a count only).
-- ============================================================================

create or replace function muse_member_count()
returns integer
language plpgsql
stable
security definer
set search_path = public, muse, pg_temp
as $$
begin
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'managers and above only';
  end if;
  return (select count(*)::int from muse.memberships where status = 'active');
end;
$$;

revoke execute on function muse_member_count() from public, anon;
grant execute on function muse_member_count() to authenticated;
