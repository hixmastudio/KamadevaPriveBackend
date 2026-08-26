-- ============================================================================
-- 0034 — One guest lookup across both programmes.
--
-- The POS surface made the host choose "Privé" or "Muse" before searching, which
-- asks them to know something they often won't at the till — and gets it wrong
-- for a woman who is both. Identification should be one action: search a name,
-- a phone, a number, or scan the card, and the system says which programme she
-- belongs to.
--
-- pos_find_guest searches the Privé register and the standalone Muse register
-- together, tagging each hit with its kind. pos_resolve_card does the same for a
-- scanned QR, resolving either a member_cards token or a muse.cards token.
--
-- Both return the minimal recognition shape only — name, number, tier (null for
-- Muse) — so host access stays inside the recognition boundary (design §4.2).
-- Muse hits carry no tier because Muse has no ladder.
-- ============================================================================

create or replace function pos_find_guest(p_query text, p_limit int default 8)
returns table (
  kind text,
  subject_id uuid,
  number text,
  full_name text,
  tier tier_enum
)
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_query text := trim(coalesce(p_query, ''));
  v_phone text;
  v_lim int := least(greatest(p_limit, 1), 20);
begin
  if current_staff_id() is null then
    raise exception 'staff session required';
  end if;
  if length(v_query) < 2 then
    return;
  end if;

  -- Phone-shaped input → exact match on the normalized number.
  if v_query ~ '^[+0-9][0-9 ()-]*$' then
    begin
      v_phone := normalize_phone(v_query);
    exception when others then
      v_phone := null;
    end;
  end if;

  return query
  with prive as (
    select 'prive'::text as kind, m.id as subject_id, m.member_no as number,
           m.full_name, m.current_tier as tier,
           (v_phone is not null and m.phone = v_phone) as phone_hit,
           (m.member_no ilike regexp_replace(upper(v_query), '^(KP-?)?', 'KP-') || '%') as no_hit
    from members m
    where m.status = 'active'
      and (
        (v_phone is not null and m.phone = v_phone)
        or m.member_no ilike regexp_replace(upper(v_query), '^(KP-?)?', 'KP-') || '%'
        or m.full_name ilike '%' || v_query || '%'
      )
  ),
  muse_hits as (
    select 'muse'::text as kind, mm.id as subject_id, mm.muse_no as number,
           mm.full_name, null::tier_enum as tier,
           (v_phone is not null and mm.phone = v_phone) as phone_hit,
           (mm.muse_no ilike regexp_replace(upper(v_query), '^(KM-?)?', 'KM-') || '%') as no_hit
    from muse.members mm
    where mm.status in ('active', 'paused')
      and (
        (v_phone is not null and mm.phone = v_phone)
        or mm.muse_no ilike regexp_replace(upper(v_query), '^(KM-?)?', 'KM-') || '%'
        or mm.full_name ilike '%' || v_query || '%'
      )
  ),
  all_hits as (select * from prive union all select * from muse_hits)
  select b.kind, b.subject_id, b.number, b.full_name, b.tier
  from all_hits b
  order by b.phone_hit desc, b.no_hit desc, b.full_name
  limit v_lim;
end;
$$;

-- Scanning: one token, either card kind.
create or replace function pos_resolve_card(p_qr_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member members%rowtype;
  v_muse muse.members%rowtype;
begin
  if current_staff_id() is null then
    raise exception 'staff session required';
  end if;

  select m.* into v_member
  from member_cards c join members m on m.id = c.member_id
  where c.qr_token = p_qr_token and c.status = 'active' and m.status = 'active';
  if found then
    return jsonb_build_object(
      'kind', 'prive', 'subject_id', v_member.id, 'number', v_member.member_no,
      'full_name', v_member.full_name, 'tier', v_member.current_tier);
  end if;

  select mm.* into v_muse
  from muse.cards c join muse.members mm on mm.id = c.muse_member_id
  where c.qr_token = p_qr_token and c.status = 'active' and mm.status in ('active', 'paused');
  if found then
    -- Muse recognition is a sensitive read; keep it in the access log.
    perform log_audit('staff', auth.uid(), 'muse.recognition.read',
                      'muse.members', v_muse.id::text);
    return jsonb_build_object(
      'kind', 'muse', 'subject_id', v_muse.id, 'number', v_muse.muse_no,
      'full_name', v_muse.full_name, 'tier', null);
  end if;

  return null;
end;
$$;

revoke execute on function pos_find_guest(text, int)  from public, anon;
grant  execute on function pos_find_guest(text, int)  to authenticated;
revoke execute on function pos_resolve_card(text)     from public, anon;
grant  execute on function pos_resolve_card(text)     to authenticated;
