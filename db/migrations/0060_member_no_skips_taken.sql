-- ============================================================================
-- 0060 — next_member_no() steps over numbers already in use.
--
-- It was 'KP-' || lpad(nextval('member_no_seq'), 6, '0') — the sequence and
-- nothing else. That is fine while numbers are only ever issued upward, and
-- breaks the moment one is assigned by hand or the sequence is wound back:
-- the counter walks into a number somebody already holds, member_no is UNIQUE,
-- and the insert fails. Which happens at a door, in front of a guest, with a
-- host who can do nothing about it.
--
-- That is not hypothetical here. The founders were moved to KP-000001–000003,
-- the seeded batch was retired out of the low range, and the sequence was wound
-- back so real registrations run 4, 5, 6. One real member still holds KP-000046
-- from the testing period, so the counter is on a path to collide with it in
-- about forty registrations' time.
--
-- The loop is bounded rather than open: if it somehow could not find a free
-- number in a thousand steps, failing with a clear message beats spinning.
-- ============================================================================

create or replace function next_member_no()
returns text
language plpgsql
as $$
declare
  v_no    text;
  v_tries int := 0;
begin
  loop
    v_no := 'KP-' || lpad(nextval('member_no_seq')::text, 6, '0');
    exit when not exists (select 1 from members where member_no = v_no);
    v_tries := v_tries + 1;
    if v_tries > 1000 then
      raise exception 'could not find a free member number after 1000 attempts';
    end if;
  end loop;
  return v_no;
end;
$$;
