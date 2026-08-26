-- ============================================================================
-- 0024 — Harden Muse authorization guards (security fix).
--
-- current_staff_role() returns NULL for any non-staff caller (e.g. a portal
-- member, who is still an `authenticated` role and can invoke these RPCs).
-- The guard pattern `if current_staff_role() not in (...) then raise` is
-- fail-OPEN on NULL: `NULL not in (...)` is NULL, the IF never fires, and the
-- function proceeds. Likewise `current_staff_role() != 'founder'` is NULL.
--
-- Result: the Muse-reading RPCs (member count, the founder-only access-audit,
-- and the new indicator helpers) returned data to callers with no staff role.
-- Rewrite them as positive allow-checks — `if role in (...) then <do it> end
-- if; <deny>` — so NULL (and every unlisted role) falls through to deny.
-- Behavior is unchanged for real HoSL/founder/VM sessions.
--
-- NOTE: the same fail-open pattern still exists in Muse *write* RPCs
-- (muse_initiate, muse_onboard, grant_muse_benefit) and several non-Muse RPCs.
-- Those need the same treatment in a dedicated, tested pass and are left here.
-- ============================================================================

-- ── Indicator helpers (introduced in 0023) ─────────────────────────────────
create or replace function muse_member_ids()
returns uuid[]
language plpgsql
stable
security definer
set search_path = public, muse, pg_temp
as $$
begin
  if current_staff_role() in ('hosl', 'founder') then
    return array(select member_id from muse.memberships where status = 'active');
  end if;
  return array[]::uuid[]; -- NULL / any other role: roster stays confidential
end;
$$;

create or replace function member_is_muse(p_member_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, muse, pg_temp
as $$
begin
  if current_staff_role() in ('hosl', 'founder') then
    return exists (
      select 1 from muse.memberships
      where member_id = p_member_id and status = 'active'
    );
  end if;
  return false; -- NULL / any other role
end;
$$;

-- ── muse_member_count (was 0020) ────────────────────────────────────────────
create or replace function muse_member_count()
returns integer
language plpgsql
stable
security definer
set search_path = public, muse, pg_temp
as $$
begin
  if current_staff_role() in ('venue_manager', 'hosl', 'founder') then
    return (select count(*)::int from muse.memberships where status = 'active');
  end if;
  raise exception 'managers and above only';
end;
$$;

-- ── muse_read_audit (was 0017) ──────────────────────────────────────────────
create or replace function muse_read_audit(p_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if current_staff_role() = 'founder' then
    return (
      select coalesce(jsonb_agg(jsonb_build_object(
        'who', coalesce(sp.full_name, ae.actor_id::text),
        'action', ae.action,
        'when', ae.occurred_at
      ) order by ae.occurred_at desc), '[]'::jsonb)
      from audit_events ae
      left join staff_profiles sp on sp.auth_user_id = ae.actor_id
      where ae.action like 'muse.%'
        and ae.occurred_at > now() - make_interval(days => p_days)
    );
  end if;
  raise exception 'the Muse access log is founder-only';
end;
$$;
