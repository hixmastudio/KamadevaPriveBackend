-- ============================================================================
-- 0015 — Cards for every member + public card resolution (design §10, pulled
-- forward): the QR is the operational key — door recognition, POS attribution
-- — so every member gets one from the moment they register, not only at
-- Member promotion. The same token later backs native wallet passes (§3.8).
-- ============================================================================

-- Backfill: every active member without an active Privé card gets one.
insert into member_cards (member_id, kind)
select m.id, 'prive'
from members m
where m.status = 'active'
  and not exists (
    select 1 from member_cards c
    where c.member_id = m.id and c.kind = 'prive' and c.status = 'active'
  );

-- register_guest now issues the card at creation.
create or replace function register_guest(
  p_phone text,
  p_full_name text,
  p_email text,
  p_venue_id uuid,
  p_instagram text default null,
  p_consent_marketing boolean default false,
  p_channel consent_channel default 'door_tablet'
)
returns members
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_phone text := normalize_phone(p_phone);
  v_email text := lower(trim(coalesce(p_email, '')));
  v_member members%rowtype;
begin
  if v_staff is null then
    raise exception 'staff session required';
  end if;
  if not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'a valid email address is required';
  end if;

  select * into v_member from members where phone = v_phone;
  if found then
    return v_member;
  end if;

  insert into members (phone, full_name, email, instagram_handle, home_venue_id)
  values (v_phone, trim(p_full_name), v_email,
          nullif(trim(coalesce(p_instagram, '')), ''), p_venue_id)
  returning * into v_member;

  insert into consents (member_id, consent_type, granted, channel, captured_by_staff_id)
  values
    (v_member.id, 'data_processing', true, p_channel, v_staff),
    (v_member.id, 'marketing_whatsapp', p_consent_marketing, p_channel, v_staff);

  -- The card is issued the moment the relationship begins.
  insert into member_cards (member_id, kind) values (v_member.id, 'prive');

  return v_member;
end;
$$;

-- Public card resolution for /card/<token>: the page a member opens from
-- their own QR. Anonymous by design — the 128-bit random token is the
-- credential; the payload carries display data only (no phone, no email).
create or replace function get_card_public(p_qr_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_card member_cards%rowtype;
  v_member members%rowtype;
begin
  select * into v_card from member_cards
  where qr_token = p_qr_token and status = 'active';
  if not found then
    return null;
  end if;

  select * into v_member from members
  where id = v_card.member_id and status = 'active';
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'full_name', v_member.full_name,
    'member_no', v_member.member_no,
    'tier', v_member.current_tier,
    'kind', v_card.kind,
    'issued_at', v_card.issued_at
  );
end;
$$;

-- Staff-side: fetch a member's active card token to show/share the QR.
create or replace function get_member_card(p_member_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_card member_cards%rowtype;
begin
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'member cards are viewed by venue managers and above';
  end if;

  select * into v_card from member_cards
  where member_id = p_member_id and kind = 'prive' and status = 'active';
  if not found then
    -- Legacy member without a card (pre-backfill edge): issue one now.
    insert into member_cards (member_id, kind) values (p_member_id, 'prive')
    returning * into v_card;
  end if;

  return jsonb_build_object('qr_token', v_card.qr_token, 'issued_at', v_card.issued_at);
end;
$$;

revoke execute on function get_card_public, get_member_card from public, anon;
grant execute on function get_card_public to anon, authenticated;
grant execute on function get_member_card to authenticated;
