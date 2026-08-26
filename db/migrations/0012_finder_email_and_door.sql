-- ============================================================================
-- 0012 — Member finder everywhere: email joins phone / name / KP number as a
-- search key, and the recognition card becomes fetchable by member id so the
-- Door's returning-member flow can use the same typeahead as POS.
-- Returned shapes stay minimal (no contact details) — host access unchanged.
-- ============================================================================

create or replace function pos_find_members(p_query text, p_limit int default 8)
returns table (
  member_id uuid,
  member_no text,
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
  select m.id, m.member_no, m.full_name, m.current_tier
  from members m
  where m.status = 'active'
    and (
      (v_phone is not null and m.phone = v_phone)
      or m.member_no ilike regexp_replace(upper(v_query), '^(KP-?)?', 'KP-') || '%'
      or m.email ilike v_query || '%'
      or m.full_name ilike '%' || v_query || '%'
    )
  order by
    (v_phone is not null and m.phone = v_phone) desc,
    (m.member_no ilike regexp_replace(upper(v_query), '^(KP-?)?', 'KP-') || '%') desc,
    (m.email ilike v_query || '%') desc,
    m.full_name
  limit least(greatest(p_limit, 1), 20);
end;
$$;

-- Recognition card by qr token, phone, or (new) member id — the id path is
-- what a typeahead selection uses. Signature changes: drop the old overload.
drop function if exists get_recognition_profile(text, text);

create or replace function get_recognition_profile(
  p_qr_token text default null,
  p_phone text default null,
  p_member_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_member members%rowtype;
  v_visits_month int;
  v_reservation reservations%rowtype;
  v_muse_active boolean := false;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;

  if p_qr_token is not null then
    select m.* into v_member
    from member_cards c join members m on m.id = c.member_id
    where c.qr_token = p_qr_token and c.status = 'active' and m.status = 'active';
  elsif p_member_id is not null then
    select * into v_member from members
    where id = p_member_id and status = 'active';
  elsif p_phone is not null then
    select * into v_member from members
    where phone = normalize_phone(p_phone) and status = 'active';
  end if;

  if v_member.id is null then
    return null;
  end if;

  select count(*)::int into v_visits_month
  from visits
  where member_id = v_member.id and voided_at is null
    and occurred_at > date_trunc('month', now());

  select * into v_reservation
  from reservations
  where member_id = v_member.id
    and status in ('requested', 'confirmed')
    and kp_business_date(reserved_for) = kp_business_date(now())
  order by reserved_for
  limit 1;

  select exists (
    select 1 from muse.memberships where member_id = v_member.id and status = 'active'
  ) into v_muse_active;

  if v_muse_active then
    perform log_audit('staff', auth.uid(), 'muse.recognition.read',
                      'members', v_member.id::text);
  end if;

  return jsonb_build_object(
    'member_id', v_member.id,
    'member_no', v_member.member_no,
    'full_name', v_member.full_name,
    'tier', v_member.current_tier,
    'visits_this_month', v_visits_month,
    'reservation_tonight', case when v_reservation.id is null then null
      else jsonb_build_object('id', v_reservation.id, 'party_size', v_reservation.party_size,
                              'reserved_for', v_reservation.reserved_for) end,
    'priority_entry', v_muse_active or v_member.current_tier in ('silver', 'gold', 'black'),
    'muse_benefit_tonight', case when v_muse_active then 'Muse member — priority entry' else null end
  );
end;
$$;

revoke execute on function pos_find_members, get_recognition_profile from public, anon;
grant execute on function pos_find_members, get_recognition_profile to authenticated;
