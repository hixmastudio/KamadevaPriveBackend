-- 0087 -- Include venue address in WhatsApp booking template variables.

create or replace function public.engagement_get_booking(p_booking_id text)
returns jsonb
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
    'id', r.id::text,
    'customer_id', r.member_id::text,
    'customer_name', m.full_name,
    'service_id', r.venue_id::text,
    'service_name', coalesce(v.name, 'Kamadeva Prive booking'),
    'service_address', coalesce(nullif(trim(v.address), ''), 'Address to be confirmed'),
    'status', r.status::text,
    'starts_at', r.reserved_for,
    'ends_at', null,
    'party_size', r.party_size
  )
  from public.reservations r
  join public.members m on m.id = r.member_id
  join public.venues v on v.id = r.venue_id
  where r.id::text = p_booking_id
  limit 1;
$$;

create or replace function public.engagement_get_customer_active_bookings(p_customer_id uuid)
returns jsonb
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id::text,
    'customer_id', r.member_id::text,
    'customer_name', m.full_name,
    'service_id', r.venue_id::text,
    'service_name', coalesce(v.name, 'Kamadeva Prive booking'),
    'service_address', coalesce(nullif(trim(v.address), ''), 'Address to be confirmed'),
    'status', r.status::text,
    'starts_at', r.reserved_for,
    'ends_at', null,
    'party_size', r.party_size
  ) order by r.reserved_for), '[]'::jsonb)
  from public.reservations r
  join public.members m on m.id = r.member_id
  join public.venues v on v.id = r.venue_id
  where r.member_id = p_customer_id
    and r.status in ('requested', 'confirmed')
    and r.reserved_for >= now() - interval '6 hours';
$$;

notify pgrst, 'reload schema';
