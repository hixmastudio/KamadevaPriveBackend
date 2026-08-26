-- ============================================================================
-- 0043 — Drain the email outbox on a schedule.
--
-- 0042 fills email_outbox; something has to empty it. A minute's cadence is
-- well inside what anyone notices for a welcome message, and the query costs
-- almost nothing when the queue is empty, which is most of the time.
--
-- The job posts to the send-emails Edge Function rather than sending from
-- Postgres, because the provider call belongs somewhere it can fail without
-- holding a transaction open. net.http_post is asynchronous — it queues the
-- request and returns immediately, so a slow provider never blocks the cron
-- worker.
--
-- The key the job presents is read from Vault at call time and is NOT in this
-- file. Set it once, out of band:
--
--   select vault.create_secret(
--     '<the project secret key, sb_secret_...>',
--     'edge_function_key',
--     'Authorises pg_cron to invoke Edge Functions');
--
-- Note it must be the project's SECRET key (sb_secret_…): the Edge Function
-- runtime populates SUPABASE_SERVICE_ROLE_KEY with that newer format, not the
-- legacy service_role JWT, and send-emails compares the two directly.
-- ============================================================================

-- Guarded the way 0005 guards its own scheduling: an environment without
-- pg_cron/pg_net still migrates cleanly instead of stopping the whole run
-- here. Nothing above this point depends on the schedule — the outbox fills
-- either way, and a database that cannot drain it on a timer is one where mail
-- would be sent by something else anyway.
do $guard$
begin
  create extension if not exists pg_net;

  -- Replacing a schedule with the same name is an update, but unschedule first
  -- so re-running this migration cannot leave two jobs racing the same queue.
  perform cron.unschedule('drain-email-outbox')
   where exists (select 1 from cron.job where jobname = 'drain-email-outbox');

  perform cron.schedule(
    'drain-email-outbox',
    '* * * * *',
    $job$
    select net.http_post(
      url     := 'https://vouormpeyrdxpxytvfce.supabase.co/functions/v1/send-emails',
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || (
          select decrypted_secret from vault.decrypted_secrets where name = 'edge_function_key'
        )
      ),
      body    := jsonb_build_object('limit', 50)
    );
    $job$
  );
exception when others then
  raise notice 'pg_cron/pg_net unavailable here (%) — drain email_outbox externally', sqlerrm;
end;
$guard$;
