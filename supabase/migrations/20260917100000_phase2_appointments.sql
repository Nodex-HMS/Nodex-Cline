-- NODEX Phase 2, Module 07: Appointments and visit scheduling.
--
-- Booking -> confirmed -> checked-in -> in-progress -> completed, with cancel
-- and no-show as terminal markers. Slot allocation is a scarce shared resource
-- arbitrated by the server (ConflictPolicy.serverAuthoritative): the
-- no-double-book exclusion constraint is the arbiter, so a conflicting offline
-- booking is rejected on upload and the client reconciles to server state.
-- RLS uses membership-derived permissions; FKs target app_users.
--
-- No delete policy by design: mistaken bookings retire through cancelled, and
-- the mutation path refuses deletes. History stays queryable for the timeline.

create extension if not exists btree_gist with schema extensions;

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  facility_id uuid references public.facilities(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  provider_id uuid not null references public.app_users(id) on delete restrict,
  booked_by uuid not null references public.app_users(id) on delete restrict,
  encounter_id uuid references public.clinical_encounters(id) on delete restrict,
  appointment_code text not null check (length(btrim(appointment_code)) > 0),
  visit_type text not null default 'outpatient' check (visit_type in ('outpatient','follow_up','telehealth','emergency','procedure')),
  priority text not null default 'routine' check (priority in ('routine','urgent','stat')),
  status text not null default 'booked' check (status in ('booked','confirmed','checked_in','in_progress','completed','cancelled','no_show')),
  reason text,
  scheduled_start timestamptz not null,
  scheduled_end timestamptz not null,
  checked_in_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, appointment_code),
  constraint appointment_range_ck check (scheduled_end > scheduled_start),
  constraint appointment_cancel_ck check ((status = 'cancelled' and cancelled_at is not null and cancel_reason is not null and length(btrim(cancel_reason)) > 0) or status <> 'cancelled'),
  constraint appointment_completed_ck check ((status = 'completed' and completed_at is not null) or status <> 'completed'),
  constraint appointment_progress_ck check ((status in ('checked_in','in_progress','completed') and checked_in_at is not null) or status not in ('checked_in','in_progress','completed')),
  constraint appointment_started_ck check ((status = 'in_progress' and started_at is not null) or status <> 'in_progress')
);
create index appointments_patient_idx on public.appointments(tenant_id, patient_id, scheduled_start desc);
create index appointments_provider_idx on public.appointments(provider_id, scheduled_start);
create index appointments_status_idx on public.appointments(tenant_id, status, scheduled_start);

-- A provider cannot hold two live bookings over the same time. Terminal rows
-- leave the constraint so freed slots rebook; the constraint is the server
-- arbitration behind the serverAuthoritative conflict policy.
alter table public.appointments add constraint appointment_no_double_book
  exclude using gist (provider_id with =, tstzrange(scheduled_start, scheduled_end) with &&)
  where (status not in ('completed','cancelled','no_show'));

create trigger appointments_set_updated_at before update on public.appointments for each row execute function nodex.tg_set_updated_at();

create or replace function nodex.tg_appointment_transition_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('completed','cancelled','no_show') and new.status <> old.status then
    raise exception using message = 'NODEX: terminal appointments cannot transition', errcode = '42501';
  end if;
  if new.status <> old.status and not (
    (old.status = 'booked' and new.status in ('confirmed','checked_in','cancelled')) or
    (old.status = 'confirmed' and new.status in ('checked_in','cancelled')) or
    (old.status = 'checked_in' and new.status in ('in_progress','no_show','cancelled')) or
    (old.status = 'in_progress' and new.status in ('completed','cancelled'))
  ) then
    raise exception using message = 'NODEX: appointment transition is not permitted', errcode = '42501';
  end if;
  -- Rescheduling (moving the slot) is only meaningful before check-in; after
  -- that the visit owns the slot and the record moves forward, not sideways.
  if (new.scheduled_start is distinct from old.scheduled_start or new.scheduled_end is distinct from old.scheduled_end) and old.status not in ('booked','confirmed') then
    raise exception using message = 'NODEX: only unconfirmed bookings can be rescheduled', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger appointments_transition_guard before update on public.appointments for each row execute function nodex.tg_appointment_transition_guard();

alter table public.appointments enable row level security;
alter table public.appointments force row level security;

create policy appointments_select_member on public.appointments for select to authenticated using (nodex.has_permission(tenant_id,'appointment.read'));
create policy appointments_insert_writer on public.appointments for insert to authenticated with check (nodex.has_permission(tenant_id,'appointment.write'));
create policy appointments_update_writer on public.appointments for update to authenticated using (nodex.has_permission(tenant_id,'appointment.write')) with check (nodex.has_permission(tenant_id,'appointment.write'));
