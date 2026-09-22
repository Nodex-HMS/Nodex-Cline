-- NODEX Phase 2, Module 25: Prescriptions and pharmacy dispensing.
--
-- Draft -> finalized prescription versions; a change creates a new version that
-- supersedes the prior order, which remains readable exactly as authorized
-- (ConflictPolicy.immutable_version). Dispensing and medication administration
-- are immutable event rows with no update or delete policies, deduplicated by
-- event identity (ConflictPolicy.event_transaction for the MAR).
-- RLS uses membership-derived permissions, and FKs target app_users rather
-- than a nonexistent public.users.
--
-- Deliberate deviation from the Module 17 pattern: the order series code is
-- unique per (tenant, code, version) rather than (tenant, code), because each
-- version is its own row linked by supersedes.

create table public.prescriptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  encounter_id uuid references public.clinical_encounters(id) on delete restrict,
  prescribed_by uuid not null references public.app_users(id) on delete restrict,
  prescription_code text not null check (length(btrim(prescription_code)) > 0),
  version integer not null check (version > 0),
  priority text not null default 'routine' check (priority in ('routine','urgent','stat')),
  status text not null default 'draft' check (status in ('draft','finalized','superseded','discontinued','cancelled')),
  indication text,
  finalized_by uuid references public.app_users(id) on delete restrict,
  finalized_at timestamptz,
  supersedes uuid references public.prescriptions(id) on delete restrict,
  closed_at timestamptz,
  closure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, prescription_code, version),
  constraint prescription_finalize_ck check ((status in ('finalized','superseded','discontinued') and finalized_by is not null and finalized_at is not null) or status in ('draft','cancelled')),
  constraint prescription_supersede_ck check ((status = 'superseded' and supersedes is not null) or status <> 'superseded'),
  constraint prescription_close_ck check ((status in ('cancelled','discontinued') and closed_at is not null and closure_reason is not null and length(btrim(closure_reason)) > 0) or status not in ('cancelled','discontinued'))
);
create index prescriptions_patient_idx on public.prescriptions(tenant_id, patient_id, created_at desc);
create index prescriptions_status_idx on public.prescriptions(tenant_id, status, priority, created_at);

create table public.prescription_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  prescription_id uuid not null references public.prescriptions(id) on delete restrict,
  line_number integer not null check (line_number > 0),
  drug_code text not null check (length(btrim(drug_code)) > 0),
  drug_name text not null check (length(btrim(drug_name)) > 0),
  strength text,
  dosage_text text not null check (length(btrim(dosage_text)) > 0),
  route text,
  frequency text,
  duration_days integer check (duration_days is null or duration_days > 0),
  quantity_prescribed numeric not null check (quantity_prescribed > 0),
  status text not null default 'draft' check (status in ('draft','ordered','partially_dispensed','dispensed','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (prescription_id, line_number)
);
create index prescription_items_prescription_idx on public.prescription_items(prescription_id, line_number);
create index prescription_items_drug_idx on public.prescription_items(tenant_id, drug_code);

create table public.pharmacy_dispenses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  prescription_id uuid not null references public.prescriptions(id) on delete restrict,
  item_id uuid not null references public.prescription_items(id) on delete restrict,
  dispensed_by uuid not null references public.app_users(id) on delete restrict,
  quantity_dispensed numeric not null check (quantity_dispensed > 0),
  batch_number text,
  note text,
  dispensed_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index pharmacy_dispenses_item_idx on public.pharmacy_dispenses(item_id, dispensed_at);
create index pharmacy_dispenses_prescription_idx on public.pharmacy_dispenses(prescription_id, dispensed_at desc);

create table public.medication_administrations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  prescription_id uuid not null references public.prescriptions(id) on delete restrict,
  item_id uuid not null references public.prescription_items(id) on delete restrict,
  dispense_id uuid references public.pharmacy_dispenses(id) on delete restrict,
  administered_by uuid not null references public.app_users(id) on delete restrict,
  administered_at timestamptz not null default now(),
  dose_text text not null check (length(btrim(dose_text)) > 0),
  route text,
  site text,
  note text,
  created_at timestamptz not null default now()
);
create index medication_administrations_patient_idx on public.medication_administrations(tenant_id, patient_id, administered_at desc);
create index medication_administrations_item_idx on public.medication_administrations(item_id, administered_at);

create trigger prescriptions_set_updated_at before update on public.prescriptions for each row execute function nodex.tg_set_updated_at();
create trigger prescription_items_set_updated_at before update on public.prescription_items for each row execute function nodex.tg_set_updated_at();

create or replace function nodex.tg_prescription_transition_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('superseded','cancelled','discontinued') and new.status <> old.status then
    raise exception using message = 'NODEX: terminal prescriptions cannot transition', errcode = '42501';
  end if;
  -- Finalizing, superseding and discontinuing are clinical authorizations, not
  -- drafts: the trigger enforces the finalize permission because RLS alone
  -- cannot distinguish the transition from a draft edit. A null auth.uid()
  -- (service-role server path, which already bypasses RLS) is trusted.
  if new.status <> old.status and new.status in ('finalized','superseded','discontinued') and auth.uid() is not null and not nodex.has_permission(new.tenant_id, 'prescription.finalize') then
    raise exception using message = 'NODEX: prescription authorization requires prescription.finalize', errcode = '42501';
  end if;
  if new.status = 'finalized' and old.status = 'draft' and (new.finalized_by is null or new.finalized_at is null) then
    raise exception using message = 'NODEX: finalizing a prescription requires authorizer and timestamp', errcode = '22000';
  end if;
  if new.status in ('cancelled','discontinued') and (new.closed_at is null or new.closure_reason is null) then
    raise exception using message = 'NODEX: closing a prescription requires timestamp and reason', errcode = '22000';
  end if;
  -- A finalized order is immutable except for its terminal transitions; any
  -- content change is a new version, never a mutation.
  if old.status = 'finalized' and new.status = 'finalized' then
    if new.tenant_id is distinct from old.tenant_id or new.patient_id is distinct from old.patient_id or new.encounter_id is distinct from old.encounter_id or new.prescribed_by is distinct from old.prescribed_by or new.prescription_code is distinct from old.prescription_code or new.version is distinct from old.version or new.priority is distinct from old.priority or new.indication is distinct from old.indication or new.finalized_by is distinct from old.finalized_by or new.finalized_at is distinct from old.finalized_at or new.supersedes is distinct from old.supersedes then
      raise exception using message = 'NODEX: finalized prescriptions are immutable; create a new version', errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger prescriptions_transition_guard before update on public.prescriptions for each row execute function nodex.tg_prescription_transition_guard();

-- Finalizing a prescription releases its lines to the pharmacy: draft lines
-- become ordered atomically with the header transition.
create or replace function nodex.tg_prescription_release_items()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status = 'draft' and new.status = 'finalized' then
    update public.prescription_items set status = 'ordered' where prescription_id = new.id and status = 'draft';
  end if;
  return new;
end;
$$;
create trigger prescriptions_release_items after update on public.prescriptions for each row execute function nodex.tg_prescription_release_items();

-- Item lines are editable while the parent order is a draft. Once released,
-- only the dispense progression (status) may move; content is frozen with the
-- authorized version. Deletes are draft-only for the same reason.
create or replace function nodex.tg_prescription_item_draft_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  parent_status text;
begin
  select status into parent_status from public.prescriptions where id = coalesce(new.prescription_id, old.prescription_id);
  if TG_OP = 'DELETE' then
    if parent_status <> 'draft' then
      raise exception using message = 'NODEX: only draft prescription lines can be removed', errcode = '42501';
    end if;
    return old;
  end if;
  if parent_status in ('superseded','cancelled','discontinued') then
    raise exception using message = 'NODEX: lines of a closed prescription are frozen', errcode = '42501';
  end if;
  if parent_status = 'draft' then
    -- A null auth.uid() (service-role server path) is trusted, as with RLS.
    if auth.uid() is not null and not nodex.has_permission(new.tenant_id, 'prescription.draft') then
      raise exception using message = 'NODEX: editing draft prescription lines requires prescription.draft', errcode = '42501';
    end if;
    return new;
  end if;
  if new.status not in ('ordered','partially_dispensed','dispensed','cancelled') then
    raise exception using message = 'NODEX: released prescription lines only progress dispense status', errcode = '42501';
  end if;
  if new.tenant_id is distinct from old.tenant_id or new.prescription_id is distinct from old.prescription_id or new.line_number is distinct from old.line_number or new.drug_code is distinct from old.drug_code or new.drug_name is distinct from old.drug_name or new.strength is distinct from old.strength or new.dosage_text is distinct from old.dosage_text or new.route is distinct from old.route or new.frequency is distinct from old.frequency or new.duration_days is distinct from old.duration_days or new.quantity_prescribed is distinct from old.quantity_prescribed then
    raise exception using message = 'NODEX: released prescription line content is immutable', errcode = '42501';
  end if;
  -- The draft -> ordered release rides on the header finalize authorization,
  -- which the prescriber holds; only onward dispensing needs the dispense
  -- permission.
  if not (old.status = 'draft' and new.status = 'ordered') and auth.uid() is not null and not nodex.has_permission(new.tenant_id, 'pharmacy.dispense') then
    raise exception using message = 'NODEX: dispensing progression requires pharmacy.dispense', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger prescription_items_draft_guard before insert or update or delete on public.prescription_items for each row execute function nodex.tg_prescription_item_draft_guard();

-- Dispense and administration rows are clinical events: append-only.
create trigger pharmacy_dispenses_append_only before update or delete on public.pharmacy_dispenses for each row execute function nodex.tg_block_mutation();
create trigger medication_administrations_append_only before update or delete on public.medication_administrations for each row execute function nodex.tg_block_mutation();

alter table public.prescriptions enable row level security;
alter table public.prescriptions force row level security;
alter table public.prescription_items enable row level security;
alter table public.prescription_items force row level security;
alter table public.pharmacy_dispenses enable row level security;
alter table public.pharmacy_dispenses force row level security;
alter table public.medication_administrations enable row level security;
alter table public.medication_administrations force row level security;

create policy prescriptions_select_member on public.prescriptions for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy prescriptions_insert_drafter on public.prescriptions for insert to authenticated with check (nodex.has_permission(tenant_id,'prescription.draft'));
create policy prescriptions_update_drafter on public.prescriptions for update to authenticated using (nodex.has_permission(tenant_id,'prescription.draft')) with check (nodex.has_permission(tenant_id,'prescription.draft'));
create policy prescriptions_update_finalizer on public.prescriptions for update to authenticated using (nodex.has_permission(tenant_id,'prescription.finalize')) with check (nodex.has_permission(tenant_id,'prescription.finalize'));
create policy prescription_items_select_member on public.prescription_items for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy prescription_items_insert_drafter on public.prescription_items for insert to authenticated with check (nodex.has_permission(tenant_id,'prescription.draft'));
create policy prescription_items_update_drafter on public.prescription_items for update to authenticated using (nodex.has_permission(tenant_id,'prescription.draft')) with check (nodex.has_permission(tenant_id,'prescription.draft'));
create policy prescription_items_update_dispenser on public.prescription_items for update to authenticated using (nodex.has_permission(tenant_id,'pharmacy.dispense')) with check (nodex.has_permission(tenant_id,'pharmacy.dispense'));
create policy pharmacy_dispenses_select_member on public.pharmacy_dispenses for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy pharmacy_dispenses_insert_dispenser on public.pharmacy_dispenses for insert to authenticated with check (nodex.has_permission(tenant_id,'pharmacy.dispense'));
create policy medication_administrations_select_member on public.medication_administrations for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy medication_administrations_insert_nurse on public.medication_administrations for insert to authenticated with check (nodex.has_permission(tenant_id,'medication.administer'));
