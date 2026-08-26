-- ============================================================================
-- 0002 — Audit spine: append-only, immutability enforced in-database,
-- monthly partitions from day one. Design doc §3.9.
-- ============================================================================

create table audit_events (
  id bigint generated always as identity,
  occurred_at timestamptz not null default now(),
  actor_type actor_type not null,
  actor_id uuid,
  action text not null, -- dot-namespaced: 'tier.promote', 'muse.candidate.read', …
  entity_type text not null,
  entity_id text,
  venue_id uuid,
  before_state jsonb,
  after_state jsonb,
  context jsonb,
  primary key (id, occurred_at)
) partition by range (occurred_at);

-- Default partition guarantees no write is ever lost to a missing partition.
create table audit_events_default partition of audit_events default;

-- Immutability: UPDATE and DELETE raise unconditionally, at the database.
create or replace function audit_events_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_events is append-only';
end;
$$;

create trigger audit_events_no_update
  before update or delete on audit_events
  for each row execute function audit_events_immutable();

-- Monthly partition creation (called at migration time and by pg_cron).
create or replace function ensure_audit_partition(p_month date)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  part_name text := 'audit_events_' || to_char(p_month, 'YYYY_MM');
  from_ts timestamptz := date_trunc('month', p_month);
  to_ts timestamptz := date_trunc('month', p_month) + interval '1 month';
begin
  if not exists (select 1 from pg_class where relname = part_name) then
    execute format(
      'create table %I partition of audit_events for values from (%L) to (%L)',
      part_name, from_ts, to_ts
    );
    execute format(
      'create trigger %I before update or delete on %I for each row execute function audit_events_immutable()',
      part_name || '_no_update', part_name
    );
  end if;
end;
$$;

select ensure_audit_partition(date_trunc('month', now())::date);
select ensure_audit_partition((date_trunc('month', now()) + interval '1 month')::date);
select ensure_audit_partition((date_trunc('month', now()) + interval '2 months')::date);

create index audit_events_entity_idx on audit_events (entity_type, entity_id, occurred_at desc);
create index audit_events_actor_idx on audit_events (actor_id, occurred_at desc);
create index audit_events_action_idx on audit_events (action, occurred_at desc);

-- The only write path. SECURITY DEFINER so RPCs can log regardless of the
-- caller's table grants; no direct INSERT grant is ever given to clients.
create or replace function log_audit(
  p_actor_type actor_type,
  p_actor_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id text,
  p_venue_id uuid default null,
  p_before jsonb default null,
  p_after jsonb default null,
  p_context jsonb default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into audit_events
    (actor_type, actor_id, action, entity_type, entity_id, venue_id, before_state, after_state, context)
  values
    (p_actor_type, p_actor_id, p_action, p_entity_type, p_entity_id, p_venue_id, p_before, p_after, p_context);
$$;

-- Generic row-change audit trigger for sensitive tables. Attached per-table
-- in later migrations as those tables are created.
create or replace function audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor uuid := auth.uid();
  v_entity_id text;
begin
  if tg_op = 'INSERT' then
    v_entity_id := new.id::text;
    perform log_audit(
      p_actor_type => case when v_actor is null then 'system'::actor_type else 'staff'::actor_type end,
      p_actor_id => v_actor,
      p_action => tg_table_schema || '.' || tg_table_name || '.insert',
      p_entity_type => tg_table_name::text,
      p_entity_id => v_entity_id,
      p_after => to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    v_entity_id := new.id::text;
    perform log_audit(
      p_actor_type => case when v_actor is null then 'system'::actor_type else 'staff'::actor_type end,
      p_actor_id => v_actor,
      p_action => tg_table_schema || '.' || tg_table_name || '.update',
      p_entity_type => tg_table_name::text,
      p_entity_id => v_entity_id,
      p_before => to_jsonb(old),
      p_after => to_jsonb(new));
    return new;
  else
    v_entity_id := old.id::text;
    perform log_audit(
      p_actor_type => case when v_actor is null then 'system'::actor_type else 'staff'::actor_type end,
      p_actor_id => v_actor,
      p_action => tg_table_schema || '.' || tg_table_name || '.delete',
      p_entity_type => tg_table_name::text,
      p_entity_id => v_entity_id,
      p_before => to_jsonb(old));
    return old;
  end if;
end;
$$;
