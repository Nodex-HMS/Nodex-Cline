-- NODEX Phase 2, Module 11: Beds and occupancy assignments.
--
-- Beds are ward master data; occupancy is derived from the active assignment,
-- never stored twice. A bed is either available or under maintenance —
-- "occupied" is the presence of an active assignment row, so the two cannot
-- disagree. Allocation is server-arbitrated (ConflictPolicy.serverAuthoritative):
-- one active assignment per bed and per patient, enforced by exclusion
-- constraints, so a conflicting offline allocation is rejected on upload and
-- the client reconciles to server state.
-- RLS uses membership-derived permissions; FKs target app_users.
--
-- No delete policy by design: mistaken assignments retire through cancelled,
-- and the mutation path refuses deletes.

create table public.beds (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  ward_id uuid not null references public.wards(id) on delete restrict,
  bed_code text not null check (length(btrim(bed_code)) > 0),
  bed_type text not null default 'general' check (bed_type in ('general','private','icu','hdu','emergency','maternity','paediatric','isolation','other')),
  status text not null default 'available' check (status in ('available','maintenance')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (ward_id, bed_code)
);
create index beds_ward_idx on public.beds(ward_id, status, bed_code);

create table public.bed_assignments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  bed_id uuid not null references public.beds(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  encounter_id uuid references public.clinical_encounters(id) on delete restrict,
  assigned_by uuid not null references public.app_users(id) on delete restrict,
  status text not null default 'active' check (status in ('active','released','cancelled')),
  admitted_at timestamptz not null default now(),
  released_at timestamptz,
  release_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bed_assignment_release_ck check ((status in ('released','cancelled') and released_at is not null and release_reason is not null and length(btrim(release_reason)) > 0) or status = 'active')
);
create index bed_assignments_bed_idx on public.bed_assignments(bed_id, status, admitted_at desc);
create index bed_assignments_patient_idx on public.bed_assignments(tenant_id, patient_id, admitted_at desc);

-- One live occupant per bed and one live bed per patient. Transfers release
-- the old assignment before creating the new one: a crash between the two
-- leaves a visibly bedless patient (recoverable), never a double allocation.
alter table public.bed_assignments add constraint bed_assignment_one_per_bed
  exclude using gist (bed_id with =) where (status = 'active');
alter table public.bed_assignments add constraint bed_assignment_one_per_patient
  exclude using gist (patient_id with =) where (status = 'active');

create trigger beds_set_updated_at before update on public.beds for each row execute function nodex.tg_set_updated_at();
create trigger bed_assignments_set_updated_at before update on public.bed_assignments for each row execute function nodex.tg_set_updated_at();

-- Only available beds accept occupants; maintenance beds hold no one.
create or replace function nodex.tg_bed_assignment_bed_available()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  bed_status text;
begin
  if TG_OP = 'DELETE' then
    return old;
  end if;
  select status into bed_status from public.beds where id = new.bed_id;
  if new.status = 'active' and bed_status <> 'available' then
    raise exception using message = 'NODEX: only available beds accept occupants', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger bed_assignments_bed_available before insert or update on public.bed_assignments for each row execute function nodex.tg_bed_assignment_bed_available();

create or replace function nodex.tg_bed_assignment_transition_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('released','cancelled') and new.status <> old.status then
    raise exception using message = 'NODEX: closed bed assignments cannot transition', errcode = '42501';
  end if;
  if new.status <> old.status and new.status not in ('released','cancelled') then
    raise exception using message = 'NODEX: active bed assignments only release or cancel', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger bed_assignments_transition_guard before update on public.bed_assignments for each row execute function nodex.tg_bed_assignment_transition_guard();

alter table public.beds enable row level security;
alter table public.beds force row level security;
alter table public.bed_assignments enable row level security;
alter table public.bed_assignments force row level security;

create policy beds_select_member on public.beds for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy beds_insert_admin on public.beds for insert to authenticated with check (nodex.has_permission(tenant_id,'ward.administer'));
create policy beds_update_admin on public.beds for update to authenticated using (nodex.has_permission(tenant_id,'ward.administer')) with check (nodex.has_permission(tenant_id,'ward.administer'));
create policy bed_assignments_select_member on public.bed_assignments for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy bed_assignments_insert_assigner on public.bed_assignments for insert to authenticated with check (nodex.has_permission(tenant_id,'bed.assign'));
create policy bed_assignments_update_assigner on public.bed_assignments for update to authenticated using (nodex.has_permission(tenant_id,'bed.assign')) with check (nodex.has_permission(tenant_id,'bed.assign'));
