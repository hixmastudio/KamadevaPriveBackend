-- 0085 -- WhatsApp booking confirmations.
--
-- The Go engagement worker polls outbox_events and sends booking.created
-- confirmations through Meta WhatsApp. These support objects map the existing
-- reservation/member schema into the worker contract and enqueue confirmed
-- reservations automatically.

create table if not exists public.outbox_events (
  id uuid primary key default gen_random_uuid(),
  type text not null,
  aggregate_id text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending',
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists outbox_events_pending_idx
  on public.outbox_events (status, next_attempt_at, created_at);

create unique index if not exists outbox_booking_created_once_idx
  on public.outbox_events (type, aggregate_id)
  where type = 'booking.created';

create unique index if not exists outbox_whatsapp_inbound_once_idx
  on public.outbox_events (type, aggregate_id)
  where type = 'whatsapp.inbound.received';

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null,
  booking_id text,
  channel text not null,
  status text not null default 'AI_ACTIVE',
  assigned_agent_id uuid,
  pending_action jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint conversations_status_check check (status in ('AI_ACTIVE', 'WAITING_FOR_HUMAN', 'HUMAN_ACTIVE', 'CLOSED'))
);

create index if not exists conversations_customer_channel_idx
  on public.conversations (customer_id, channel, status);

create table if not exists public.conversation_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  external_message_id text,
  direction text not null,
  sender_type text not null,
  body text not null,
  delivery_status text,
  failure_code text,
  failure_text text,
  created_at timestamptz not null default now(),
  constraint conversation_messages_direction_check check (direction in ('INBOUND', 'OUTBOUND')),
  constraint conversation_messages_sender_check check (sender_type in ('CUSTOMER', 'AI', 'HUMAN', 'SYSTEM'))
);

create unique index if not exists conversation_messages_external_message_id_idx
  on public.conversation_messages (external_message_id)
  where external_message_id is not null;

create table if not exists public.ai_actions (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  customer_id uuid,
  booking_id text,
  action text not null,
  arguments jsonb,
  result jsonb,
  status text not null,
  created_at timestamptz not null default now(),
  constraint ai_actions_status_check check (status in ('pending', 'success', 'failed'))
);

create or replace function public.engagement_enqueue_booking_created(
  p_booking_id text,
  p_phone text,
  p_payload jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_id uuid;
begin
  insert into public.outbox_events(type, aggregate_id, payload)
  values (
    'booking.created',
    p_booking_id,
    coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('booking_id', p_booking_id, 'phone', p_phone)
  )
  on conflict do nothing
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.engagement_claim_outbox_events(p_limit integer)
returns setof public.outbox_events
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update public.outbox_events
  set status = 'processing',
      locked_at = now(),
      attempts = attempts + 1,
      updated_at = now()
  where id in (
    select id
    from public.outbox_events
    where status in ('pending', 'failed')
      and next_attempt_at <= now()
      and attempts < 10
    order by created_at
    limit greatest(1, p_limit)
    for update skip locked
  )
  returning *;
$$;

create or replace function public.engagement_mark_outbox_done(p_event_id uuid)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update public.outbox_events
  set status = 'done', updated_at = now()
  where id = p_event_id;
$$;

create or replace function public.engagement_mark_outbox_failed(p_event_id uuid, p_reason text)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update public.outbox_events
  set status = 'failed',
      last_error = left(coalesce(p_reason, ''), 2000),
      next_attempt_at = now() + make_interval(secs => least(3600, power(4, greatest(0, attempts - 1))::integer)),
      updated_at = now()
  where id = p_event_id;
$$;

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

create or replace function public.engagement_get_customer_by_phone(p_phone text)
returns jsonb
language sql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $$
  select jsonb_build_object(
    'id', m.id::text,
    'name', m.full_name,
    'phone', m.phone
  )
  from public.members m
  where m.phone = public.normalize_phone(p_phone)
    and m.status = 'active'
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

create or replace function public.engagement_find_or_create_conversation(
  p_customer_id uuid,
  p_booking_id text,
  p_channel text
) returns public.conversations
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_conversation public.conversations;
begin
  select *
  into v_conversation
  from public.conversations
  where customer_id = p_customer_id
    and channel = p_channel
    and coalesce(booking_id, '') = coalesce(p_booking_id, '')
    and status in ('AI_ACTIVE', 'WAITING_FOR_HUMAN', 'HUMAN_ACTIVE')
  order by updated_at desc
  limit 1;

  if v_conversation.id is null then
    insert into public.conversations(customer_id, booking_id, channel)
    values (p_customer_id, p_booking_id, p_channel)
    returning * into v_conversation;
  end if;

  return v_conversation;
end;
$$;

create or replace function public.engagement_save_message(
  p_conversation_id uuid,
  p_external_message_id text,
  p_direction text,
  p_sender_type text,
  p_body text,
  p_created_at timestamptz
) returns public.conversation_messages
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_message public.conversation_messages;
begin
  insert into public.conversation_messages(
    conversation_id,
    external_message_id,
    direction,
    sender_type,
    body,
    created_at
  ) values (
    p_conversation_id,
    p_external_message_id,
    p_direction,
    p_sender_type,
    p_body,
    coalesce(p_created_at, now())
  )
  on conflict (external_message_id) where external_message_id is not null
  do update set external_message_id = excluded.external_message_id
  returning * into v_message;

  update public.conversations
  set updated_at = now()
  where id = p_conversation_id;

  return v_message;
end;
$$;

create or replace function public.engagement_recent_messages(p_conversation_id uuid, p_limit integer)
returns setof public.conversation_messages
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  select *
  from public.conversation_messages
  where conversation_id = p_conversation_id
  order by created_at desc
  limit greatest(1, p_limit);
$$;

create or replace function public.engagement_enqueue_whatsapp_inbound(
  p_message_id text,
  p_from text,
  p_body text,
  p_sent_at timestamptz
) returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  insert into public.outbox_events(type, aggregate_id, payload)
  values (
    'whatsapp.inbound.received',
    p_message_id,
    jsonb_build_object('message_id', p_message_id, 'from', p_from, 'body', p_body, 'sent_at', p_sent_at)
  )
  on conflict do nothing;
$$;

create or replace function public.engagement_get_conversation(p_conversation_id uuid)
returns public.conversations
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  select * from public.conversations where id = p_conversation_id;
$$;

create or replace function public.engagement_set_conversation_status(p_conversation_id uuid, p_status text)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update public.conversations
  set status = p_status, updated_at = now()
  where id = p_conversation_id
    and p_status in ('AI_ACTIVE', 'WAITING_FOR_HUMAN', 'HUMAN_ACTIVE', 'CLOSED');
$$;

create or replace function public.engagement_set_pending_action(p_conversation_id uuid, p_pending_action jsonb)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update public.conversations
  set pending_action = p_pending_action, updated_at = now()
  where id = p_conversation_id;
$$;

create or replace function public.engagement_update_whatsapp_status(
  p_message_id text,
  p_status text,
  p_error_code text,
  p_error_text text
) returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update public.conversation_messages
  set delivery_status = p_status,
      failure_code = p_error_code,
      failure_text = p_error_text
  where external_message_id = p_message_id;
$$;

create or replace function public.engagement_record_ai_action(
  p_conversation_id uuid,
  p_customer_id uuid,
  p_booking_id text,
  p_action text,
  p_arguments jsonb,
  p_result jsonb,
  p_status text
) returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  insert into public.ai_actions(conversation_id, customer_id, booking_id, action, arguments, result, status)
  values (p_conversation_id, p_customer_id, p_booking_id, p_action, p_arguments, p_result, p_status);
$$;

create or replace function public.engagement_get_business_information()
returns jsonb
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
    'company_name', 'Kamadeva Prive',
    'location', '',
    'opening_hours', '',
    'cancellation_policy', '',
    'services', '[]'::jsonb,
    'extra', '{}'::jsonb
  );
$$;

create or replace function public.booking_check_availability(
  p_service_id text,
  p_requested_time timestamptz
) returns jsonb
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  select '[]'::jsonb;
$$;

create or replace function public.booking_reschedule(
  p_booking_id text,
  p_slot_id text,
  p_source text
) returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_reserved_for timestamptz;
begin
  begin
    v_reserved_for := p_slot_id::timestamptz;
  exception when others then
    raise exception 'slot_id must be a timestamp for reservation bookings';
  end;

  update public.reservations
  set reserved_for = v_reserved_for,
      status = 'confirmed',
      updated_at = now(),
      notes = concat_ws(E'\n', notes, 'Rescheduled from ' || coalesce(p_source, 'whatsapp_ai'))
  where id::text = p_booking_id
    and status in ('requested', 'confirmed');
end;
$$;

create or replace function public.booking_cancel(
  p_booking_id text,
  p_source text
) returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  update public.reservations
  set status = 'cancelled',
      updated_at = now(),
      notes = concat_ws(E'\n', notes, 'Cancelled from ' || coalesce(p_source, 'whatsapp_ai'))
  where id::text = p_booking_id
    and status in ('requested', 'confirmed');
$$;

create or replace function public.on_reservation_whatsapp_booking_created()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_phone text;
begin
  if new.status <> 'confirmed' then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status = new.status then
    return new;
  end if;

  select phone into v_phone
  from public.members
  where id = new.member_id
    and status = 'active';

  if v_phone is not null then
    begin
      perform public.engagement_enqueue_booking_created(
        new.id::text,
        v_phone,
        jsonb_build_object(
          'venue_id', new.venue_id,
          'reserved_for', new.reserved_for,
          'party_size', new.party_size
        )
      );
    exception when others then
      raise warning 'whatsapp booking outbox enqueue failed for reservation %: %', new.id, sqlerrm;
    end;
  end if;

  return new;
end;
$$;

drop trigger if exists reservations_whatsapp_booking_created on public.reservations;
create trigger reservations_whatsapp_booking_created
  after insert or update of status on public.reservations
  for each row execute function public.on_reservation_whatsapp_booking_created();
