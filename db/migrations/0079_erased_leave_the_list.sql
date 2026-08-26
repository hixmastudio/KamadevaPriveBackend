-- ─────────────────────────────────────────────────────────────────────────────
-- 0079 — the erased and the removed leave the list, and give back their number
--
-- Erasing a Muse member removed her details but left the row on the register,
-- three lines reading "Erased member" above a column of zeros. Removing a staff
-- account did the same on Team. Both are tombstones: nothing you can act on, in
-- the one place you go to act on people.
--
-- And each tombstone was still holding a number. KM-000001 belonged to somebody
-- who is gone, so the next woman invited into a circle of one would have been
-- KM-000004 — a number that says three people came before her when nobody did.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Giving the number back ──────────────────────────────────────────────────
-- muse_no is NOT NULL and UNIQUE, so a released number cannot simply be emptied.
-- It is rewritten into a form that is not a Muse number at all — 'X-' and the
-- row's own id — which frees the KM-###### it used to hold while keeping the
-- row unique and obviously a tombstone to anyone reading the table directly.
create or replace function muse_release_number(p_muse_member_id uuid)
returns void
language plpgsql
volatile security definer
set search_path = public, pg_temp
as $$
begin
  update muse.members
     set muse_no = 'X-' || replace(id::text, '-', '')
   where id = p_muse_member_id
     and muse_no ~ '^KM-[0-9]{6}$';
end;
$$;

revoke execute on function muse_release_number(uuid) from public, anon, authenticated;

-- ── The next number is the lowest one free ──────────────────────────────────
-- Was nextval with a skip-if-taken loop, which never went backwards: a released
-- number stayed released and unused for ever, which is the opposite of giving it
-- back. This scans instead. The register is invitation-only and numbered in the
-- tens, so counting up from one costs nothing, and it means a freed number is
-- the very next one handed out.
--
-- The sequence is kept in step behind it so anything still reading it is not
-- surprised, but it is no longer what decides.
create or replace function next_muse_no()
returns text
language plpgsql
volatile
set search_path = public, pg_temp
as $$
declare
  n bigint := 1;
  v_no text;
begin
  loop
    v_no := 'KM-' || lpad(n::text, 6, '0');
    exit when not exists (select 1 from muse.members where muse_no = v_no);
    n := n + 1;
    if n > 999999 then
      raise exception 'no Muse numbers left';
    end if;
  end loop;
  perform setval('muse_no_seq', greatest(n, 1), true);
  return v_no;
end;
$$;

-- ── The register shows the circle, not its headstones ───────────────────────
-- Candidates, the declined and those who have left all stay: they are the record
-- of how the circle was decided, and 0074 widened the list on purpose to show
-- them. An erased record is different in kind — there is no person left in it to
-- read, and the reason it went is in the audit trail where it belongs.
create or replace function muse_list_members()
returns jsonb
language plpgsql
volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_role staff_role := current_staff_role();
  v_result jsonb;
begin
  if v_role is null or v_role not in ('hosl', 'founder') then
    raise exception 'the Muse roster is visible to the HoSL and founders';
  end if;

  perform log_audit('staff', auth.uid(), 'muse.roster.read', 'muse.members', null);

  select coalesce(jsonb_agg(row_data order by sort_rank, sort_name), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'muse_member_id', mm.id,
      'muse_no', mm.muse_no,
      'full_name', mm.full_name,
      'phone', mm.phone,
      'email', mm.email,
      'date_of_birth', mm.date_of_birth,
      'age', case when mm.date_of_birth is null then null
                  else extract(year from age(mm.date_of_birth))::int end,
      'status', mm.status,
      'erased', false,
      'joined_at', ms.onboarded_at,
      'onboarded_by', sp.full_name,
      'has_portal', mm.auth_user_id is not null,
      'card_token', mc.qr_token,
      'visits', coalesce(t.tickets, 0),
      'spend_kobo', coalesce(t.spend, 0),
      'last_seen', t.last_seen,
      'benefits_given', coalesce(b.given, 0),
      'last_benefit_at', b.last_at
    ) as row_data,
    case mm.status when 'active' then 0 when 'paused' then 1 when 'candidate' then 2
                   when 'exited' then 3 else 4 end as sort_rank,
    mm.full_name as sort_name
    from muse.members mm
    left join muse.memberships ms on ms.member_id = mm.id and ms.status = 'active'
    left join staff_profiles sp on sp.id = ms.onboarded_by
    left join muse.cards mc on mc.muse_member_id = mm.id and mc.status = 'active'
    left join lateral (
      select count(*)::int as tickets,
             sum(pt.total_kobo)::bigint as spend,
             max(pt.occurred_at) as last_seen
      from pos_tickets pt
      where pt.muse_member_id = mm.id and pt.voided_at is null
    ) t on true
    left join lateral (
      select count(*)::int as given, max(bg.created_at) as last_at
      from muse.benefit_grants bg
      where bg.membership_id = ms.id
    ) b on true
    where mm.erased_at is null
  ) s;

  return v_result;
end;
$$;

revoke execute on function muse_list_members() from public, anon;
grant  execute on function muse_list_members() to authenticated;

-- ── A counter for tombstone phone numbers ──────────────────────────────────
-- The placeholder used to be built from her Muse number. That was fine while a
-- number belonged to one person for ever, and became a collision the moment
-- numbers started coming back: the second holder of KM-000001, once erased,
-- would want the same +00000000000001 the first one already has. Caught by the
-- test for exactly that, before it reached anybody.
--
-- A sequence cannot repeat, and unlike the row id it is all digits, which the
-- column's CHECK (phone ~ '^\+[0-9]{8,15}$') requires.
create sequence if not exists muse_erased_phone_seq;

-- ── Erasing now hands the number back ───────────────────────────────────────
-- Recreated from the live definition with one call added before the row is
-- rewritten, and the returned message saying so. Everything else — the founder
-- guard, the written reason, the delete-outright path for someone never
-- onboarded, the credential and card revocation — is exactly as 0074 left it.
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

  return jsonb_build_object('outcome', 'erased', 'muse_no', v_no,
    'detail', v_no || ' is free again for the next invitation. '
              || 'Her details are gone and her card and sign-in no longer work. '
              || v_refs || ' record(s) — bills, arrivals, her card — still point at the membership, so the shell remains.');
end;
$function$;


-- ── The three already stranded ──────────────────────────────────────────────
-- KM-000001, 2 and 3 are held by rows erased before this migration existed.
-- Released here so the register starts at one again.
do $$
declare r record;
begin
  for r in select id from muse.members where erased_at is not null and muse_no ~ '^KM-[0-9]{6}$' loop
    perform muse_release_number(r.id);
  end loop;
end $$;

select setval('muse_no_seq', 1, false);

-- The three erased before this migration still carry number-derived phones,
-- which are exactly the values a reissued number would later collide with.
update muse.members
   set phone = '+9' || lpad(nextval('muse_erased_phone_seq')::text, 13, '0')
 where erased_at is not null
   and phone ~ '^\+0{8,}[0-9]*$';
