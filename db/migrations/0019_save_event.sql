-- ============================================================================
-- 0019 — Events write path (audit fix).
--
-- The events + event_access_windows tables shipped in 0007 with read
-- policies only: members could browse and book published events, but no RPC
-- or policy allowed staff to CREATE one — events could only be inserted via
-- raw SQL. save_event() closes that gap: create or update an event and
-- replace its tier access windows in one audited call.
-- ============================================================================

create or replace function save_event(
  p_name text,
  p_starts_at timestamptz,
  p_venue_id uuid default null,
  p_event_id uuid default null,
  p_ends_at timestamptz default null,
  p_capacity integer default null,
  p_status text default 'published',
  p_min_reservation_tier tier_enum default null,
  p_windows jsonb default '[]'::jsonb  -- [{"min_tier":"gold","opens_at":"…"}]
)
returns events
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_staff uuid := current_staff_id();
  v_event events%rowtype;
  w record;
begin
  if current_staff_role() not in ('venue_manager', 'hosl', 'founder') then
    raise exception 'events are managed by venue managers and above';
  end if;
  if p_venue_id is not null and not staff_has_venue(p_venue_id) then
    raise exception 'no active assignment at this venue';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'event name is required';
  end if;
  if p_status not in ('draft', 'published', 'cancelled') then
    raise exception 'status must be draft, published, or cancelled';
  end if;

  if p_event_id is null then
    insert into events (venue_id, name, starts_at, ends_at, capacity, status,
                        min_reservation_tier, created_by)
    values (p_venue_id, trim(p_name), p_starts_at, p_ends_at, p_capacity,
            p_status, p_min_reservation_tier, v_staff)
    returning * into v_event;
  else
    update events
      set venue_id = p_venue_id, name = trim(p_name), starts_at = p_starts_at,
          ends_at = p_ends_at, capacity = p_capacity, status = p_status,
          min_reservation_tier = p_min_reservation_tier
      where id = p_event_id
      returning * into v_event;
    if not found then
      raise exception 'event not found';
    end if;
  end if;

  -- Replace the tier windows wholesale — the form always sends the full set.
  delete from event_access_windows where event_id = v_event.id;
  for w in
    select (j->>'min_tier')::tier_enum as min_tier, (j->>'opens_at')::timestamptz as opens_at
    from jsonb_array_elements(coalesce(p_windows, '[]'::jsonb)) j
  loop
    insert into event_access_windows (event_id, min_tier, opens_at)
    values (v_event.id, w.min_tier, w.opens_at);
  end loop;

  perform log_audit(
    p_actor_type => 'staff'::actor_type,
    p_actor_id   => v_staff,
    p_action     => case when p_event_id is null then 'event.create' else 'event.update' end,
    p_entity_type=> 'events',
    p_entity_id  => v_event.id::text,
    p_venue_id   => p_venue_id,
    p_after      => to_jsonb(v_event)
  );

  return v_event;
end;
$$;

revoke execute on function save_event from public, anon;
grant execute on function save_event to authenticated;
