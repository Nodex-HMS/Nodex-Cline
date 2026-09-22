-- NODEX Phase 2, Module 17: Central Laboratory.
--
-- Order -> specimen -> entered result -> verified result. Verified values are
-- immutable; correction creates a linked result row. RLS uses membership-derived
-- permissions, and FKs target app_users rather than a nonexistent public.users.

create table public.lab_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  encounter_id uuid references public.clinical_encounters(id) on delete restrict,
  ordered_by uuid not null references public.app_users(id) on delete restrict,
  order_code text not null check (length(btrim(order_code)) > 0),
  priority text not null default 'routine' check (priority in ('routine','urgent','stat')),
  status text not null default 'ordered' check (status in ('ordered','partially_collected','collected','completed','cancelled')),
  clinical_indication text,
  tests jsonb not null default '[]'::jsonb,
  ordered_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, order_code),
  constraint lab_order_cancel_ck check ((status = 'cancelled' and cancelled_at is not null and cancelled_reason is not null) or status <> 'cancelled')
);
create index lab_orders_patient_idx on public.lab_orders(tenant_id, patient_id, ordered_at desc);
create index lab_orders_status_idx on public.lab_orders(tenant_id, status, priority, ordered_at);

create table public.lab_specimens (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  lab_order_id uuid not null references public.lab_orders(id) on delete restrict,
  accession_barcode text not null,
  specimen_type text not null check (length(btrim(specimen_type)) > 0),
  collected_by uuid references public.app_users(id) on delete set null,
  collected_at timestamptz,
  status text not null default 'pending' check (status in ('pending','collected','rejected','received','processed')),
  rejection_reason text,
  received_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, accession_barcode),
  constraint specimen_collected_ck check ((status in ('collected','rejected','received','processed') and collected_at is not null) or status = 'pending'),
  constraint specimen_rejected_ck check ((status = 'rejected' and rejection_reason is not null) or status <> 'rejected')
);
create index lab_specimens_order_idx on public.lab_specimens(lab_order_id, status);
create index lab_specimens_barcode_idx on public.lab_specimens(tenant_id, accession_barcode);

create table public.lab_results (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  lab_order_id uuid not null references public.lab_orders(id) on delete restrict,
  specimen_id uuid not null references public.lab_specimens(id) on delete restrict,
  analyte_code text not null check (length(btrim(analyte_code)) > 0),
  analyte_name text not null check (length(btrim(analyte_name)) > 0),
  value_text text,
  value_numeric numeric,
  unit text,
  reference_range text,
  abnormal_flag text check (abnormal_flag is null or abnormal_flag in ('low','high','critical','normal','unknown')),
  status text not null default 'entered' check (status in ('entered','verified','corrected','cancelled')),
  entered_by uuid not null references public.app_users(id) on delete restrict,
  verified_by uuid references public.app_users(id) on delete restrict,
  entered_at timestamptz not null default now(),
  verified_at timestamptz,
  correction_of uuid references public.lab_results(id) on delete restrict,
  correction_reason text,
  created_at timestamptz not null default now(),
  constraint lab_result_value_ck check (value_text is not null or value_numeric is not null),
  constraint lab_result_verified_ck check ((status in ('verified','corrected') and verified_by is not null and verified_at is not null) or status in ('entered','cancelled')),
  constraint lab_result_correction_ck check ((status = 'corrected' and correction_of is not null and correction_reason is not null and length(btrim(correction_reason)) > 0) or status <> 'corrected')
);
create unique index lab_results_current_analyte on public.lab_results(tenant_id, specimen_id, analyte_code) where status in ('entered','verified');
create index lab_results_order_idx on public.lab_results(lab_order_id, created_at desc);

create trigger lab_orders_set_updated_at before update on public.lab_orders for each row execute function nodex.tg_set_updated_at();
create trigger lab_specimens_set_updated_at before update on public.lab_specimens for each row execute function nodex.tg_set_updated_at();

create or replace function nodex.tg_lab_order_transition_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('cancelled','completed') and new.status <> old.status then
    raise exception using message = 'NODEX: terminal laboratory orders cannot transition', errcode = '42501';
  end if;
  if new.status = 'cancelled' and (new.cancelled_at is null or new.cancelled_reason is null) then
    raise exception using message = 'NODEX: cancelling a laboratory order requires timestamp and reason', errcode = '22000';
  end if;
  return new;
end;
$$;
create trigger lab_orders_transition_guard before update on public.lab_orders for each row execute function nodex.tg_lab_order_transition_guard();

create or replace function nodex.tg_lab_result_immutable_after_verify()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('verified','corrected') then
    if new.tenant_id is distinct from old.tenant_id or new.lab_order_id is distinct from old.lab_order_id or new.specimen_id is distinct from old.specimen_id or new.analyte_code is distinct from old.analyte_code or new.analyte_name is distinct from old.analyte_name or new.value_text is distinct from old.value_text or new.value_numeric is distinct from old.value_numeric or new.unit is distinct from old.unit or new.reference_range is distinct from old.reference_range or new.abnormal_flag is distinct from old.abnormal_flag or new.entered_by is distinct from old.entered_by or new.entered_at is distinct from old.entered_at or new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at or new.correction_of is distinct from old.correction_of or new.correction_reason is distinct from old.correction_reason then
      raise exception using message = 'NODEX: verified laboratory results are immutable; create a correction row', errcode = '42501';
    end if;
    if old.status = 'corrected' or new.status <> old.status then
      raise exception using message = 'NODEX: corrected laboratory results are terminal', errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger lab_results_immutable_after_verify before update on public.lab_results for each row execute function nodex.tg_lab_result_immutable_after_verify();
create trigger lab_results_append_only_delete before delete on public.lab_results for each row execute function nodex.tg_block_mutation();

alter table public.lab_orders enable row level security;
alter table public.lab_orders force row level security;
alter table public.lab_specimens enable row level security;
alter table public.lab_specimens force row level security;
alter table public.lab_results enable row level security;
alter table public.lab_results force row level security;

create policy lab_orders_select_member on public.lab_orders for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy lab_orders_insert_writer on public.lab_orders for insert to authenticated with check (nodex.has_permission(tenant_id,'lab_order.write'));
create policy lab_orders_update_writer on public.lab_orders for update to authenticated using (nodex.has_permission(tenant_id,'lab_order.write')) with check (nodex.has_permission(tenant_id,'lab_order.write'));
create policy lab_specimens_select_member on public.lab_specimens for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy lab_specimens_insert_writer on public.lab_specimens for insert to authenticated with check (nodex.has_permission(tenant_id,'lab_result.enter'));
create policy lab_specimens_update_writer on public.lab_specimens for update to authenticated using (nodex.has_permission(tenant_id,'lab_result.enter')) with check (nodex.has_permission(tenant_id,'lab_result.enter'));
create policy lab_results_select_member on public.lab_results for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy lab_results_insert_writer on public.lab_results for insert to authenticated with check (nodex.has_permission(tenant_id,'lab_result.enter'));
create policy lab_results_update_writer on public.lab_results for update to authenticated using (nodex.has_permission(tenant_id,'lab_result.verify')) with check (nodex.has_permission(tenant_id,'lab_result.verify'));
