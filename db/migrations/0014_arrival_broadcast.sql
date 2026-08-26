-- ============================================================================
-- 0014 — Arrival flag via Realtime broadcast-from-database (design §5 wk5-6).
-- New Supabase projects run the broadcast pipeline, not legacy
-- postgres_changes: a trigger on visits broadcasts to the private channel
-- `arrivals:<venue_id>`, and an RLS policy on realtime.messages authorizes
-- venue managers/HoSL/founders of that venue to subscribe.
-- ============================================================================

create or replace function notify_arrival()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  begin
    perform realtime.send(
      jsonb_build_object(
        'visit_id', new.id,
        'member_id', new.member_id,
        'venue_id', new.venue_id,
        'capture_channel', new.capture_channel
      ),
      'arrival',
      'arrivals:' || new.venue_id::text,
      true -- private channel
    );
  exception when others then
    -- Environments without the realtime schema (CI shadow DB) still insert
    -- visits fine; the flag is a nicety, never a write-path dependency.
    null;
  end;
  return null;
end;
$$;

drop trigger if exists visits_notify_arrival on visits;
create trigger visits_notify_arrival
  after insert on visits
  for each row execute function notify_arrival();

-- Private-channel authorization: who may LISTEN to arrivals:<venue_id>.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'realtime') then
    execute $pol$
      create policy managers_read_arrival_broadcasts
      on realtime.messages for select
      to authenticated
      using (
        realtime.topic() like 'arrivals:%'
        and public.is_manager_up()
        and public.staff_has_venue(split_part(realtime.topic(), ':', 2)::uuid)
      )
    $pol$;
  end if;
exception when duplicate_object then
  null;
end;
$$;
