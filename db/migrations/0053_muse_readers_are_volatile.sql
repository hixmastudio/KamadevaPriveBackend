-- ============================================================================
-- 0053 — The Muse roster and pipeline could not be read at all.
--
-- Both readers log the fact that they were read. That is deliberate and it is
-- the point: §7 of the governance document runs Muse on a least-visibility
-- model, so who looked at the register, and when, is itself part of the record.
--
-- But both were declared STABLE. STABLE is not a hint — it is a promise to
-- Postgres that the function does not modify the database, and PostgREST acts
-- on it by running the call inside a READ-ONLY transaction. The audit INSERT
-- then fails with "cannot execute INSERT in a read-only transaction", and
-- because that error aborts the whole call, it takes the read down with it.
--
-- The effect on the floor: the Muse tab showed a red error where the pipeline
-- should be and listed no candidates — not because there were none, but because
-- the query could never complete. The roster behaved the same way. Anyone
-- initiating a candidate then had no way to see whether it had worked.
--
-- The functions were simply mislabelled. They write; VOLATILE says so. Nothing
-- about their behaviour changes, and the logging stays exactly as it was.
--
-- Worth stating for whoever writes the next one: a SECURITY DEFINER function
-- that logs its own reads must be VOLATILE. The two ideas fight each other by
-- default, and the failure only appears through PostgREST — calling the same
-- function over psql works perfectly, which is what makes it easy to ship.
-- ============================================================================

alter function muse_list_pipeline() volatile;
alter function muse_list_members()  volatile;
