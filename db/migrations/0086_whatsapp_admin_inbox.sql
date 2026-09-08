-- 0086 -- WhatsApp admin inbox helpers.
--
-- These RPCs expose the existing WhatsApp conversation tables to the admin
-- backend endpoints without changing the customer booking flow.

create or replace function public.engagement_get_customer(p_customer_id uuid)
returns jsonb
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
    'id', m.id::text,
    'name', m.full_name,
    'phone', m.phone
  )
  from public.members m
  where m.id = p_customer_id
    and m.status = 'active'
  limit 1;
$$;

create or replace function public.engagement_admin_list_conversations(
  p_status text default null,
  p_limit integer default 50
) returns jsonb
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  with scoped as (
    select c.*
    from public.conversations c
    where c.channel = 'whatsapp'
      and (
        nullif(trim(coalesce(p_status, '')), '') is null
        or c.status = upper(trim(p_status))
      )
    order by c.updated_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id::text,
    'customer_id', c.customer_id::text,
    'customer_name', m.full_name,
    'customer_phone', m.phone,
    'booking_id', c.booking_id,
    'venue_name', v.name,
    'booking_status', r.status::text,
    'booking_starts_at', r.reserved_for,
    'party_size', r.party_size,
    'channel', c.channel,
    'status', c.status,
    'last_message', lm.body,
    'last_direction', lm.direction,
    'last_message_at', lm.created_at,
    'unread_count', coalesce(uc.unread_count, 0),
    'updated_at', c.updated_at
  ) order by c.updated_at desc), '[]'::jsonb)
  from scoped c
  left join public.members m on m.id = c.customer_id
  left join public.reservations r on r.id::text = c.booking_id
  left join public.venues v on v.id = r.venue_id
  left join lateral (
    select cm.body, cm.direction, cm.created_at
    from public.conversation_messages cm
    where cm.conversation_id = c.id
    order by cm.created_at desc
    limit 1
  ) lm on true
  left join lateral (
    select max(cm.created_at) as replied_at
    from public.conversation_messages cm
    where cm.conversation_id = c.id
      and cm.direction = 'OUTBOUND'
      and cm.sender_type = 'HUMAN'
  ) hr on true
  left join lateral (
    select count(*)::integer as unread_count
    from public.conversation_messages cm
    where cm.conversation_id = c.id
      and cm.direction = 'INBOUND'
      and cm.created_at > coalesce(hr.replied_at, '-infinity'::timestamptz)
  ) uc on true;
$$;

create or replace function public.engagement_admin_send_whatsapp_reply(
  p_conversation_id uuid,
  p_body text
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_role text := current_staff_role();
  v_staff uuid := current_staff_id();
  v_conversation public.conversations;
  v_event_id uuid;
begin
  if v_role is null or v_role not in ('hosl', 'founder') then
    raise exception 'WhatsApp conversations are answered by the HoSL or a founder';
  end if;
  if length(trim(coalesce(p_body, ''))) < 1 then
    raise exception 'reply is required';
  end if;

  select *
  into v_conversation
  from public.conversations
  where id = p_conversation_id
    and channel = 'whatsapp'
  limit 1;

  if v_conversation.id is null then
    raise exception 'conversation not found';
  end if;

  update public.conversations
  set status = 'HUMAN_ACTIVE',
      assigned_agent_id = v_staff,
      updated_at = now()
  where id = v_conversation.id;

  insert into public.outbox_events(type, aggregate_id, payload)
  values (
    'whatsapp.admin.reply_requested',
    v_conversation.id::text,
    jsonb_build_object(
      'conversation_id', v_conversation.id::text,
      'customer_id', v_conversation.customer_id::text,
      'body', trim(p_body),
      'staff_id', v_staff::text
    )
  )
  returning id into v_event_id;

  return jsonb_build_object(
    'ok', true,
    'event_id', v_event_id::text,
    'conversation_id', v_conversation.id::text
  );
end;
$$;

revoke execute on function public.engagement_get_customer(uuid) from public, anon;
revoke execute on function public.engagement_admin_list_conversations(text, integer) from public, anon;
revoke execute on function public.engagement_admin_send_whatsapp_reply(uuid, text) from public, anon;

grant execute on function public.engagement_get_customer(uuid) to authenticated;
grant execute on function public.engagement_recent_messages(uuid, integer) to authenticated;
grant execute on function public.engagement_admin_list_conversations(text, integer) to authenticated;
grant execute on function public.engagement_admin_send_whatsapp_reply(uuid, text) to authenticated;
