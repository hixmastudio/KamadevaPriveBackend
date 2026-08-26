-- ─────────────────────────────────────────────────────────────────────────────
-- 0078 — three SECURITY DEFINER writers were reachable without signing in
--
-- Found in a pre-launch pass over the database linter, which is the right time
-- to find it and very nearly wasn't.
--
-- In Postgres a new function grants EXECUTE to PUBLIC unless told otherwise, and
-- PostgREST exposes every function in `public` as an endpoint. So a definer
-- function nobody remembered to revoke is a write, running as the owner,
-- available to anyone who can reach the API — no account required.
--
-- Three had been left that way. Their siblings show it was an oversight rather
-- than a decision: enqueue_member_email and enqueue_staff_email are both
-- correctly held to postgres and service_role.
--
--   enqueue_muse_email(muse_member_id, template, dedupe_key, payload)
--     The worst of them. The payload is what the template renders, so a stranger
--     with a Muse member's id could have the house's own mail sender deliver her
--     a message from noreply@kamadevaprive.com saying whatever they liked —
--     including a sign-in code. Phishing with our return address on it.
--
--   log_audit(...)
--     Writes the audit trail. Forgeable audit entries are worse than none,
--     because they are believed. The Muse governance model rests on "every read
--     is logged", and that claim is only worth what the log is worth.
--
--   notify_member(member_id, kind, title, body)
--     Arbitrary in-app notifications to any member. The same phishing, delivered
--     inside the product instead of the inbox.
--
-- Revoking is safe, and checked before doing it: all thirty-eight callers are
-- themselves SECURITY DEFINER and so run as the owner regardless of what the
-- caller may execute, and no client code calls any of the three directly.
-- ─────────────────────────────────────────────────────────────────────────────

revoke execute on function public.enqueue_muse_email(uuid, email_template, text, jsonb)
  from public, anon, authenticated;

revoke execute on function public.notify_member(uuid, text, text, text)
  from public, anon, authenticated;

revoke execute on function public.log_audit(actor_type, uuid, text, text, text, uuid, jsonb, jsonb, jsonb)
  from public, anon, authenticated;

-- ── Hygiene: pin the search_path on the last few functions without one ──────
-- None of these are SECURITY DEFINER, so they run with the caller's own rights
-- and the usual definer/search_path escalation does not apply. Pinned anyway:
-- it costs nothing, and "the ones without a search_path are the harmless ones"
-- is a fact about today that nobody will remember when one of them is later
-- made a definer.
alter function public.normalize_phone(text)              set search_path = public, extensions, pg_temp;
alter function public.kp_business_date(timestamptz)      set search_path = public, extensions, pg_temp;
alter function public.new_qr_token()                     set search_path = public, extensions, pg_temp;
alter function public.config_int(text)                   set search_path = public, extensions, pg_temp;
alter function public.audit_events_immutable()           set search_path = public, extensions, pg_temp;
alter function public.touch_updated_at()                 set search_path = public, extensions, pg_temp;
alter function public.is_sendable_email(text)            set search_path = public, extensions, pg_temp;
alter function public.next_member_no()                   set search_path = public, extensions, pg_temp;
