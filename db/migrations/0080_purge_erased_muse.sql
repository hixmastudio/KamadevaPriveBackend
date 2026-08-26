-- ─────────────────────────────────────────────────────────────────────────────
-- 0080 — an erased Muse goes completely
--
-- 0074 erased her details and 0079 took her off the register and gave back her
-- number, but the row survived, and so did the candidacy behind it — which is
-- why three "Erased member X-2fc15e9b…" cards were still sitting in the
-- pipeline with their original rationales underneath them. Scrubbing a name
-- from one list while the reason she was invited stays legible on another is
-- not erasure, it is filing.
--
-- The shell existed for one reason: attributed bills and door arrivals point at
-- her, and those are not ours to delete. That is a condition, not a rule — and
-- for a Muse with no trade against her name it is simply not true. So the row
-- goes when it can, and stays only when something outside her own records
-- genuinely depends on it.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function muse_purge_member(p_muse_member_id uuid)
returns boolean
language plpgsql
volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_outside int;
begin
  -- What genuinely cannot go: a bill, because it is money, and an arrival,
  -- because the door's record of a night is not hers to delete.
  --
  -- Post and notifications are NOT in that list, and the first version of this
  -- had them there — which the test caught immediately, because muse_onboard
  -- queues a welcome the moment anyone is onboarded. Every Muse would have had
  -- an outbox row from her first minute, so none would ever have been
  -- purgeable, and the backfill only appeared to work because the pre-launch
  -- clearance had emptied that table.
  --
  -- Counting them was wrong on its own terms too. A queued email holds her
  -- address and a notification holds her name, so leaving them behind would
  -- keep the very details the erasure exists to remove. They are messages to
  -- her, not records of what she did: they go with her.
  select
    (select count(*) from pos_tickets   where muse_member_id = p_muse_member_id)
  + (select count(*) from muse.arrivals where muse_member_id = p_muse_member_id)
    into v_outside;

  if v_outside > 0 then
    return false;
  end if;

  -- Children first, then her.
  delete from email_outbox           where muse_member_id = p_muse_member_id;
  delete from member_notifications   where muse_member_id = p_muse_member_id;
  delete from muse.benefit_grants    where membership_id in (select id from muse.memberships where member_id = p_muse_member_id);
  delete from muse.content_agreements where membership_id in (select id from muse.memberships where member_id = p_muse_member_id);
  delete from muse.memberships       where member_id = p_muse_member_id;
  delete from muse.cards             where muse_member_id = p_muse_member_id;
  delete from muse.credentials       where muse_member_id = p_muse_member_id;
  delete from notification_reads     where muse_member_id = p_muse_member_id;
  delete from member_code_resets     where muse_member_id = p_muse_member_id;
  delete from muse.candidates        where member_id = p_muse_member_id;
  delete from muse.members           where id = p_muse_member_id;

  -- The approvals row is deliberately left. It is a founder's decision, made
  -- and recorded, and it belongs to the governance trail rather than to her —
  -- the same reason the audit entry for the erasure survives.
  return true;
end;
$$;

revoke execute on function muse_purge_member(uuid) from public, anon, authenticated;

-- ── The pipeline stops showing the erased ───────────────────────────────────
-- Belt and braces for the case the purge cannot run — a Muse with bills against
-- her keeps her shell, and that shell should not reappear here reading
-- "Erased member" beside the reason she was once invited.
create or replace function muse_list_pipeline()
returns jsonb
language plpgsql
volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_result jsonb;
begin
  if v_role in ('hosl', 'founder') then
    perform log_audit('staff', auth.uid(), 'muse.pipeline.read', 'muse.candidates', null);
    select coalesce(jsonb_agg(row_data order by created_at desc), '[]'::jsonb) into v_result
    from (
      select jsonb_build_object(
        'candidate_id', c.id, 'muse_member_id', c.member_id, 'full_name', mm.full_name,
        'muse_no', mm.muse_no, 'status', c.status, 'rationale', c.rationale,
        'initiated_by', sp.full_name, 'decision_reason', a.decision_reason,
        'onboarded', exists (select 1 from muse.memberships ms where ms.candidate_id = c.id)
      ) as row_data, c.created_at
      from muse.candidates c
      join muse.members mm on mm.id = c.member_id
      left join staff_profiles sp on sp.id = c.initiated_by
      left join approvals a on a.id = c.approval_id
      where mm.erased_at is null
    ) s;
    return v_result;
  end if;
  raise exception 'the Muse pipeline is visible to the HoSL and founders';
end;
$$;

revoke execute on function muse_list_pipeline() from public, anon;
grant  execute on function muse_list_pipeline() to authenticated;

-- ── Erasing now takes the row too, when it can ──────────────────────────────
-- Recreated from the live definition with the purge attempted after the scrub.
-- The scrub still happens first and unconditionally: if the purge is refused
-- because bills point at her, what is left is a shell with no personal details
-- in it — which is the whole point, and the state 0074 was already producing.
CREATE OR REPLACE FUNCTION public.muse_erase_member(p_muse_member_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_m muse.members%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_refs int;
  v_no text;
begin
  if current_staff_role() is distinct from 'founder' then
    raise exception 'removing a Muse member is the founder''s decision';
  end if;
  -- A written reason, for the same reason a decline needs one: this is a
  -- decision about a person, and it should be answerable later.
  if v_reason is null or length(v_reason) < 10 then
    raise exception 'say why, in a sentence — this is recorded against the decision';
  end if;

  select * into v_m from muse.members where id = p_muse_member_id for update;
  if not found then
    raise exception 'no such Muse member';
  end if;
  if v_m.erased_at is not null then
    raise exception '% has already been erased', v_m.muse_no;
  end if;
  v_no := v_m.muse_no;

  select
    (select count(*) from muse.memberships where member_id = v_m.id)
  + (select count(*) from muse.cards      where muse_member_id = v_m.id)
  + (select count(*) from muse.arrivals   where muse_member_id = v_m.id)
  + (select count(*) from pos_tickets     where muse_member_id = v_m.id)
    into v_refs;

  -- Logged BEFORE the row changes, so the audit entry is written while there is
  -- still something to describe — and so an erasure can never be silent.
  perform log_audit('staff', auth.uid(), 'muse.member.erase',
                    'muse.members', p_muse_member_id::text);

  if v_refs = 0 then
    -- Never onboarded and referenced by nothing: the entry can simply go.
    delete from muse.candidates where member_id = v_m.id;
    delete from muse.members where id = v_m.id;
    return jsonb_build_object('outcome', 'deleted', 'muse_no', v_no,
      'detail', 'The entry was removed outright — she had never been onboarded.');
  end if;

  -- Stop the credentials working before anything else, so a half-finished
  -- erasure never leaves a working sign-in behind.
  delete from muse.credentials where muse_member_id = v_m.id;
  update muse.cards set status = 'revoked', revoked_at = now()
   where muse_member_id = v_m.id and status = 'active';

  -- Hand the number back before the row is rewritten, so the next woman
  -- invited gets it. She is a different person holding the same number, which
  -- is only safe because nothing references a Muse by her number — every
  -- ticket, arrival and audit entry points at the id, which is hers alone and
  -- never reissued.
  perform muse_release_number(v_m.id);

  update muse.members
     set full_name = 'Erased member',
         first_name = null,
         last_name = null,
         -- phone, email and date_of_birth are all NOT NULL (phone and email
         -- UNIQUE besides), so they are overwritten with values that are unique
         -- per row and obviously not a person, rather than emptied. The date is
         -- a sentinel for the same reason; `erased_at` is what the surfaces
         -- read, never the birthday.
         -- Built from her Muse number, which is unique and all digits, because
         -- the column also carries CHECK (phone ~ '^\+[0-9]{8,15}$') — a uuid
         -- fragment has letters in it and would be rejected.
         phone = '+9' || lpad(nextval('muse_erased_phone_seq')::text, 13, '0'),
         email = 'erased+' || replace(v_m.id::text, '-', '') || '@kamadeva.invalid',
         instagram_handle = null,
         date_of_birth = date '1900-01-01',
         auth_user_id = null,
         status = 'exited',
         erased_at = now(),
         erased_reason = v_reason,
         updated_at = now()
   where id = v_m.id;

  -- With her details gone, try to take the row too. It succeeds whenever
  -- nothing outside her own records depends on her, which for a Muse who never
  -- had a bill attributed is always — and leaves nothing behind to turn up in
  -- a list later reading "Erased member".
  if muse_purge_member(v_m.id) then
    return jsonb_build_object('outcome', 'deleted', 'muse_no', v_no,
      'detail', v_no || ' is free again for the next invitation. Nothing of hers remains — '
                || 'she had no bills or arrivals recorded, so the record went with the details.');
  end if;

  return jsonb_build_object('outcome', 'erased', 'muse_no', v_no,
    'detail', v_no || ' is free again for the next invitation. '
              || 'Her details are gone and her card and sign-in no longer work. '
              || v_refs || ' record(s) — bills, arrivals, her card — still point at the membership, so the shell remains.');
end;
$function$;


-- ── The three already erased ────────────────────────────────────────────────
-- They hold one candidacy, one membership and one card each and nothing else:
-- their arrivals and bills went with the pre-launch clearance. So they go.
do $$
declare r record; v_gone int := 0;
begin
  for r in select id, muse_no from muse.members where erased_at is not null loop
    if muse_purge_member(r.id) then
      v_gone := v_gone + 1;
    else
      raise notice 'kept % — something outside her own records still points at her', r.muse_no;
    end if;
  end loop;
  raise notice 'purged % erased Muse record(s)', v_gone;
end $$;
