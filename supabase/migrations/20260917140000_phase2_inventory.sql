-- NODEX Phase 2, Module 13: Inventory management.
--
-- Stock items are master data; movements are append-only events that
-- derive current stock levels (ConflictPolicy.transactional: balances
-- replay rather than overwrite). RLS uses membership-derived permissions;
-- FKs target app_users.
--
-- No delete policy by design: movements are immutable events; items are
-- retired via status, never deleted.

create table public.stock_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  item_code text not null check (length(btrim(item_code)) > 0),
  name text not null check (length(btrim(name)) > 0),
  description text,
  category text not null check (length(btrim(category)) > 0),
  unit text not null check (length(btrim(unit)) > 0),
  status text not null default 'active' check (status in ('active','inactive','discontinued')),
  reorder_level numeric not null default 0 check (reorder_level >= 0),
  standard_cost_minor bigint,
  requires_batch boolean not null default false,
  requires_expiry boolean not null default false,
  created_by uuid not null references public.app_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, item_code)
);
create index stock_items_tenant_idx on public.stock_items(tenant_id, status, category);

create table public.stock_locations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  facility_id uuid references public.facilities(id) on delete restrict,
  ward_id uuid references public.wards(id) on delete restrict,
  location_code text not null check (length(btrim(location_code)) > 0),
  name text not null check (length(btrim(name)) > 0),
  location_type text not null default 'warehouse' check (location_type in ('warehouse','pharmacy','ward','clinic','laboratory','blood_bank','other')),
  status text not null default 'active' check (status in ('active','inactive','maintenance')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, location_code)
);
create index stock_locations_facility_idx on public.stock_locations(tenant_id, facility_id, status);

create table public.stock_batches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  item_id uuid not null references public.stock_items(id) on delete restrict,
  batch_number text not null check (length(btrim(batch_number)) > 0),
  expiry_date date,
  manufactured_date date,
  quantity_minor bigint not null default 0 check (quantity_minor >= 0),
  cost_per_unit_minor bigint,
  status text not null default 'available' check (status in ('available','reserved','expired','recalled','consumed')),
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, item_id, batch_number)
);
create index stock_batches_item_idx on public.stock_batches(tenant_id, item_id, status, expiry_date);
create index stock_batches_expiry_idx on public.stock_batches(tenant_id, expiry_date) where expiry_date is not null;

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  item_id uuid not null references public.stock_items(id) on delete restrict,
  batch_id uuid references public.stock_batches(id) on delete restrict,
  from_location_id uuid references public.stock_locations(id) on delete restrict,
  to_location_id uuid references public.stock_locations(id) on delete restrict,
  movement_type text not null check (movement_type in ('receipt','issue','transfer','adjustment','return','write_off','cycle_count')),
  quantity_minor bigint not null check (quantity_minor <> 0),
  unit_cost_minor bigint,
  reference_type text,
  reference_id uuid,
  reason text,
  recorded_by uuid not null references public.app_users(id) on delete restrict,
  recorded_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index stock_movements_item_idx on public.stock_movements(tenant_id, item_id, recorded_at desc);
create index stock_movements_location_idx on public.stock_movements(tenant_id, from_location_id, to_location_id, recorded_at desc);
create index stock_movements_batch_idx on public.stock_movements(batch_id, recorded_at desc);
create index stock_movements_type_idx on public.stock_movements(tenant_id, movement_type, recorded_at desc);

-- Stock levels are a derived projection; the transactional conflict policy
-- replays movements to derive the authoritative balance.

create trigger stock_items_set_updated_at before update on public.stock_items for each row execute function nodex.tg_set_updated_at();
create trigger stock_locations_set_updated_at before update on public.stock_locations for each row execute function nodex.tg_set_updated_at();
create trigger stock_batches_set_updated_at before update on public.stock_batches for each row execute function nodex.tg_set_updated_at();

create or replace function nodex.tg_stock_item_draft_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'discontinued' and new.status <> old.status then
    raise exception using message = 'NODEX: discontinued items cannot be reactivated', errcode = '42501';
  end if;
  if new.status = 'discontinued' and old.status <> 'discontinued' and auth.uid() is not null and not nodex.has_permission(new.tenant_id, 'inventory.movement') then
    raise exception using message = 'NODEX: discontinuing an item requires inventory.movement', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger stock_items_transition_guard before update on public.stock_items for each row execute function nodex.tg_stock_item_draft_guard();

create or replace function nodex.tg_stock_batch_status_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('expired','recalled','consumed') and new.status <> old.status then
    raise exception using message = 'NODEX: terminal batch status cannot transition', errcode = '42501';
  end if;
  if new.status = 'consumed' and new.quantity_minor > 0 then
    raise exception using message = 'NODEX: consumed batch must have zero quantity', errcode = '22000';
  end if;
  if new.expiry_date is not null and new.expiry_date < current_date and new.status = 'available' then
    raise exception using message = 'NODEX: expired batches cannot be available', errcode = '22000';
  end if;
  return new;
end;
$$;
create trigger stock_batches_status_guard before update on public.stock_batches for each row execute function nodex.tg_stock_batch_status_guard();

alter table public.stock_items enable row level security;
alter table public.stock_items force row level security;
alter table public.stock_locations enable row level security;
alter table public.stock_locations force row level security;
alter table public.stock_batches enable row level security;
alter table public.stock_batches force row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_movements force row level security;

create policy stock_items_select_member on public.stock_items for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy stock_items_insert_admin on public.stock_items for insert to authenticated with check (nodex.has_permission(tenant_id,'inventory.movement'));
create policy stock_items_update_admin on public.stock_items for update to authenticated using (nodex.has_permission(tenant_id,'inventory.movement')) with check (nodex.has_permission(tenant_id,'inventory.movement'));

create policy stock_locations_select_member on public.stock_locations for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy stock_locations_insert_admin on public.stock_locations for insert to authenticated with check (nodex.has_permission(tenant_id,'inventory.movement'));
create policy stock_locations_update_admin on public.stock_locations for update to authenticated using (nodex.has_permission(tenant_id,'inventory.movement')) with check (nodex.has_permission(tenant_id,'inventory.movement'));

create policy stock_batches_select_member on public.stock_batches for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy stock_batches_insert_writer on public.stock_batches for insert to authenticated with check (nodex.has_permission(tenant_id,'inventory.movement'));
create policy stock_batches_update_writer on public.stock_batches for update to authenticated using (nodex.has_permission(tenant_id,'inventory.movement')) with check (nodex.has_permission(tenant_id,'inventory.movement'));

create policy stock_movements_select_member on public.stock_movements for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy stock_movements_insert_writer on public.stock_movements for insert to authenticated with check (nodex.has_permission(tenant_id,'inventory.movement'));
create policy stock_movements_update_writer on public.stock_movements for update to authenticated using (nodex.has_permission(tenant_id,'inventory.movement')) with check (nodex.has_permission(tenant_id,'inventory.movement'));