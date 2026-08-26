-- ============================================================================
-- 0028 — Repoint Muse off public.members, migrate the demo membership.
--
-- muse.candidates.member_id and muse.memberships.member_id currently FK into
-- public.members, and muse.memberships.card_id into public.member_cards. This
-- migration swaps those three FKs onto the standalone muse.members / muse.cards
-- from 0027. Existing rows must be repointed to a valid muse.members id BEFORE
-- the new FK is validated, so seed + UPDATE + re-add happen in ONE transaction.
--
-- Production has exactly one legacy Muse membership (Adaeze Nwosu, KP-000009).
-- We create a fresh standalone Muse subject from her details (with a known demo
-- login code so the standalone Muse can be tested), repoint her candidate +
-- membership onto it, and revoke her old Privé-linked Muse card — after which
-- KP-000009 is a plain Privé Gold member again (the tier engine keys off
-- public.members and never touches the muse schema).
--
-- Written as a DO block that resolves rows by lookup, so it is a safe no-op
-- (just the FK swap) on a fresh environment with no legacy Muse rows.
-- ============================================================================

do $$
declare
  v_member  public.members%rowtype;
  v_new     uuid;
  v_newcard uuid;
begin
  select * into v_member from public.members where member_no = 'KP-000009';

  -- 1) Drop the FKs that bind Muse to the Privé tables.
  alter table muse.candidates  drop constraint if exists candidates_member_id_fkey;
  alter table muse.memberships drop constraint if exists memberships_member_id_fkey;
  alter table muse.memberships drop constraint if exists muse_memberships_card_fk;

  -- 2) Migrate any legacy Muse rows (which still reference public.members ids)
  --    onto a fresh standalone subject, so the new FK will validate.
  if (exists (select 1 from muse.candidates) or exists (select 1 from muse.memberships))
     and v_member.id is not null then

    insert into muse.members (full_name, phone, email, date_of_birth, status)
    values (v_member.full_name, v_member.phone,
            coalesce(v_member.email, 'demo@kamadevaprive.com'),
            date '1990-01-01', 'active')
    returning id into v_new;

    insert into muse.cards (muse_member_id) values (v_new) returning id into v_newcard;

    -- Known demo login code (matches the Privé demo code) so the standalone
    -- Muse can sign in with kind:'muse'. Bcrypt via pgcrypto, never plaintext.
    insert into muse.credentials (muse_member_id, code_hash)
    values (v_new, extensions.crypt('604218', extensions.gen_salt('bf')));

    update muse.candidates  set member_id = v_new
      where member_id = v_member.id;
    update muse.memberships set member_id = v_new, card_id = v_newcard
      where member_id = v_member.id;

    -- Retire her old Privé-linked Muse card so KP-000009 no longer resolves as
    -- Muse via get_card_public / recognition.
    update public.member_cards set status = 'revoked', revoked_at = now()
      where member_id = v_member.id and kind = 'muse' and status = 'active';
  end if;

  -- 3) Re-add the FKs, now pointing at the standalone muse tables.
  alter table muse.candidates  add constraint candidates_member_id_fkey
    foreign key (member_id) references muse.members (id) on delete restrict;
  alter table muse.memberships add constraint memberships_member_id_fkey
    foreign key (member_id) references muse.members (id) on delete restrict;
  alter table muse.memberships add constraint muse_memberships_card_fk
    foreign key (card_id) references muse.cards (id) on delete restrict;
end $$;
