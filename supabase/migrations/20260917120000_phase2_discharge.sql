-- NODEX Phase 2, Module 23: Discharge finalization.
--
-- Draft -> finalized discharge per encounter; a finalized discharge is the
-- authorized record of the episode and stays readable exactly as issued
-- (ConflictPolicy.immutable_version). A readmission is a new encounter with
-- its own discharge, so no version chain is needed. Finalizing is a
-- high-risk online-only authorization (discharge.finalize); drafting rides on
-- encounter.write, and the trigger enforces the split because RLS alone
-- cannot distinguish finalizing from editing a draft.
-- RLS uses membership-derived permissions; FKs target app_users.
--
-- No delete policy by design: mistaken drafts retire through cancelled, and
-- the mutation path refuses deletes.

create table public.discharges (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  encounter_id uuid not null references public.clinical_encounters(id) on delete restrict,
  created_by uuid not null references public.app_users(id) on delete restrict,
  discharge_code text not null check (length(btrim(discharge_code)) > 0),
  discharge_type text not null default 'routine' check (discharge_type in ('routine','referral_transfer','against_advice','absconded','death')),
  status text not null default 'draft' check (status in ('draft','finalized','cancelled')),
  summary text,
  follow_up_plan text,
  finalized_by uuid references public.app_users(id) on delete restrict,
  finalized_at timestamptz,
  closed_at timestamptz,
  closure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, discharge_code),
  unique (encounter_id),
  constraint discharge_finalize_ck check ((status = 'finalized' and finalized_by is not null and finalized_at is not null) or status in ('draft','cancelled')),
  constraint discharge_close_ck check ((status = 'cancelled' and closed_at is not null and closure_reason is not null and length(btrim(closure_reason)) > 0) or status <> 'cancelled')
);
create index discharges_patient_idx on public.discharges(tenant_id, patient_id, created_at desc);

create trigger discharges_set_updated_at before update on public.discharges for each row execute function nodex.tg_set_updated_at();

create or replace function nodex.tg_discharge_transition_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('finalized','cancelled') and new.status <> old.status then
    raise exception using message = 'NODEX: closed discharges cannot transition', errcode = '42501';
  end if;
  -- Finalizing is a clinical authorization, not a draft edit: enforce the
  -- finalize permission here. A null auth.uid() (service-role server path,
  -- which already bypasses RLS) is trusted.
  if new.status <> old.status and new.status = 'finalized' and auth.uid() is not null and not nodex.has_permission(new.tenant_id, 'discharge.finalize') then
    raise exception using message = 'NODEX: discharge authorization requires discharge.finalize', errcode = '42501';
  end if;
  if new.status = 'finalized' and old.status = 'draft' and (new.finalized_by is null or new.finalized_at is null) then
    raise exception using message = 'NODEX: finalizing a discharge requires authorizer and timestamp', errcode = '22000';
  end if;
  if new.status = 'cancelled' and (new.closed_at is null or new.closure_reason is null) then
    raise exception using message = 'NODEX: cancelling a discharge requires timestamp and reason', errcode = '22000';
  end if;
  -- A finalized discharge is immutable; any correction is a clinical decision
  -- recorded against the encounter, never a silent rewrite.
  if old.status = 'finalized' and new.status = 'finalized' then
    if new.tenant_id is distinct from old.tenant_id or new.patient_id is distinct from old.patient_id or new.encounter_id is distinct from old.encounter_id or new.created_by is distinct from old.created_by or new.discharge_code is distinct from old.discharge_code or new.discharge_type is distinct from old.discharge_type or new.summary is distinct from old.summary or new.follow_up_plan is distinct from old.follow_up_plan or new.finalized_by is distinct from old.finalized_by or new.finalized_at is distinct from old.finalized_at then
      raise exception using message = 'NODEX: finalized discharges are immutable', errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger discharges_transition_guard before update on public.discharges for each row execute function nodex.tg_discharge_transition_guard();

alter table public.discharges enable row level security;
alter table public.discharges force row level security;

create policy discharges_select_member on public.discharges for select to authenticated using (nodex.has_permission(tenant_id,'patient.read'));
create policy discharges_insert_writer on public.discharges for insert to authenticated with check (nodex.has_permission(tenant_id,'encounter.write'));
create policy discharges_update_writer on public.discharges for update to authenticated using (nodex.has_permission(tenant_id,'encounter.write') or nodex.has_permission(tenant_id,'discharge.finalize')) with check (nodex.has_permission(tenant_id,'encounter.write') or nodex.has_permission(tenant_id,'discharge.finalize'));
