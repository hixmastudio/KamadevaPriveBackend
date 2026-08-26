-- ============================================================================
-- 0026 — Close the audit-spine hole (Supabase advisor: rls_disabled_in_public).
--
-- The parent `audit_events` is a PARTITIONED table with RLS enabled and a
-- correct policy (`audit_read`: HoSL and above, or a venue manager for their
-- own venue). But RLS in Postgres is enforced per relation: querying a
-- PARTITION directly applies that partition's own RLS, not the parent's. The
-- monthly partitions were created with RLS off and still carried the schema's
-- blanket grants to anon/authenticated — so
--
--     GET /rest/v1/audit_events_2026_08   (with the public anon key)
--
-- returned the whole audit spine: who did what to whom, the before/after
-- payloads, and the `muse.*` read-audit rows the Muse confidentiality model
-- depends on. The parent was locked; the back doors were not.
--
-- Root cause: ensure_audit_partition() creates each month's table and its
-- immutability trigger but never enables RLS, so every new month silently
-- opened another public table. Patching only today's partitions would leave
-- September's to reopen it, so the creator is fixed too.
--
-- RLS is enabled WITHOUT `force`: the partitions are owned by `postgres`, which
-- holds rolbypassrls, so log_audit() and the other SECURITY DEFINER writers
-- keep working while anon/authenticated (no bypass, and now no policy) are
-- denied. Reads continue to go through the parent, where audit_read governs.
-- ============================================================================

do $$
declare
  part regclass;
begin
  for part in
    select inhrelid::regclass
    from pg_inherits
    where inhparent = 'public.audit_events'::regclass
  loop
    -- Deny-all for clients: RLS on, no policies of its own.
    execute format('alter table %s enable row level security', part);
    -- Defence in depth — nothing should reach a partition by name.
    execute format('revoke all on %s from anon, authenticated', part);
  end loop;
end $$;

-- ── The creator, so future months are born closed ───────────────────────────
create or replace function ensure_audit_partition(p_month date)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  part_name text := 'audit_events_' || to_char(p_month, 'YYYY_MM');
  from_ts timestamptz := date_trunc('month', p_month);
  to_ts timestamptz := date_trunc('month', p_month) + interval '1 month';
begin
  if not exists (select 1 from pg_class where relname = part_name) then
    execute format(
      'create table %I partition of audit_events for values from (%L) to (%L)',
      part_name, from_ts, to_ts
    );
    execute format(
      'create trigger %I before update or delete on %I for each row execute function audit_events_immutable()',
      part_name || '_no_update', part_name
    );
    -- A partition is reachable by name over PostgREST, so it must carry its own
    -- RLS: the parent's policy does not apply to a direct partition query.
    execute format('alter table %I enable row level security', part_name);
    execute format('revoke all on %I from anon, authenticated', part_name);
  end if;
end;
$$;

-- ── Advisor: security_definer_view on public.current_consents ────────────────
-- The view is owned by postgres and ran with the owner's rights, so a direct
-- client query would have read consents past that table's RLS. Only
-- get_my_status() (SECURITY DEFINER, runs as postgres) uses it, so switching to
-- the invoker's rights and dropping the client grants changes no app behaviour.
alter view public.current_consents set (security_invoker = on);
revoke all on public.current_consents from anon, authenticated;
