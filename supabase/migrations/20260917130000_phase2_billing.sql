-- NODEX Phase 2, Module 31: Billing, invoices and settlement.
--
-- Money is stored in integer minor units with an ISO-4217 currency code, never
-- as a floating-point amount: a half-paisa rounding error in a financial
-- settlement is a defect, and binary floating point cannot represent decimal
-- currency exactly.
--
-- Invoices accumulate lines, payments and refunds as append-only events; the
-- balance is derived, never stored twice. Settlement is server-arbitrated
-- (ConflictPolicy.transactional): an exclusion constraint refuses an event
-- whose new amount_received would exceed the invoice total, so a concurrent
-- over-settlement is rejected on upload and the client replays against current
-- server state.
-- RLS uses membership-derived permissions; FKs target app_users.
--
-- No delete policy by design: mistaken drafts retire through cancelled, and
-- the mutation path refuses deletes. A settled invoice is immutable.

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  patient_id uuid not null references public.patients(id) on delete restrict,
  encounter_id uuid references public.clinical_encounters(id) on delete restrict,
  created_by uuid not null references public.app_users(id) on delete restrict,
  invoice_code text not null check (length(btrim(invoice_code)) > 0),
  status text not null default 'draft' check (status in ('draft','issued','settled','cancelled')),
  currency text not null default 'BDT' check (currency ~ '^[A-Z]{3}$'),
  total_minor bigint not null default 0 check (total_minor >= 0),
  settled_minor bigint not null default 0 check (settled_minor >= 0),
  notes text,
  issued_at timestamptz,
  settled_at timestamptz,
  closed_at timestamptz,
  closure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, invoice_code),
  constraint invoice_settled_ck check ((status = 'settled' and settled_at is not null and settled_minor >= total_minor) or status <> 'settled'),
  constraint invoice_issued_ck check ((status in ('issued','settled') and issued_at is not null) or status in ('draft','cancelled')),
  constraint invoice_close_ck check ((status = 'cancelled' and closed_at is not null and closure_reason is not null and length(btrim(closure_reason)) > 0) or status <> 'cancelled')
);
create index invoices_patient_idx on public.invoices(tenant_id, patient_id, created_at desc);
create index invoices_status_idx on public.invoices(tenant_id, status, created_at);

create table public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  line_number integer not null check (line_number > 0),
  description text not null check (length(btrim(description)) > 0),
  quantity numeric not null default 1 check (quantity > 0),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  line_total_minor bigint not null check (line_total_minor >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (invoice_id, line_number)
);
create index invoice_lines_invoice_idx on public.invoice_lines(invoice_id, line_number);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  recorded_by uuid not null references public.app_users(id) on delete restrict,
  amount_minor bigint not null check (amount_minor <> 0),
  amount_received_minor bigint,
  method text not null default 'cash' check (method in ('cash','card','mobile_money','bank_transfer','insurance','waiver')),
  reference text,
  note text,
  paid_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index payments_invoice_idx on public.payments(invoice_id, paid_at);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  payment_id uuid references public.payments(id) on delete restrict,
  recorded_by uuid not null references public.app_users(id) on delete restrict,
  amount_minor bigint not null check (amount_minor > 0),
  reason text not null check (length(btrim(reason)) > 0),
  refunded_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index refunds_invoice_idx on public.refunds(invoice_id, refunded_at);

-- Settlement arbitration. Each event carries the running amount_received
-- (payments) or amount_refunded (refunds) including itself; the exclusion
-- refuses any event that would pass the invoice total or refund more than was
-- received. Over-settlement is impossible even under concurrent uploads.
alter table public.payments add constraint payment_no_over_settlement
  exclude using gist (invoice_id with =, int8range(0, amount_received_minor) with &&)
  where (amount_received_minor is not null);

create trigger invoices_set_updated_at before update on public.invoices for each row execute function nodex.tg_set_updated_at();
create trigger invoice_lines_set_updated_at before update on public.invoice_lines for each row execute function nodex.tg_set_updated_at();

-- Invoice transitions: settlement requires full coverage, and a settled or
-- cancelled invoice is frozen. Totals are recomputed from the lines, never
-- accepted from the client.
create or replace function nodex.tg_invoice_transition_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status in ('settled','cancelled') and new.status <> old.status then
    raise exception using message = 'NODEX: closed invoices cannot transition', errcode = '42501';
  end if;
  if new.status <> old.status and new.status = 'issued' and old.status = 'draft' and new.issued_at is null then
    raise exception using message = 'NODEX: issuing an invoice requires a timestamp', errcode = '22000';
  end if;
  if new.status <> old.status and new.status = 'settled' and (new.settled_minor < new.total_minor or new.settled_at is null) then
    raise exception using message = 'NODEX: settling an invoice requires full payment', errcode = '22000';
  end if;
  if new.status = 'cancelled' and (new.closed_at is null or new.closure_reason is null) then
    raise exception using message = 'NODEX: cancelling an invoice requires timestamp and reason', errcode = '22000';
  end if;
  -- Settlement is a financial authorization, not a draft edit: enforce the
  -- settle permission here. A null auth.uid() (service-role server path) is
  -- trusted, as with RLS.
  if new.status <> old.status and new.status = 'settled' and auth.uid() is not null and not nodex.has_permission(new.tenant_id, 'billing.settle') then
    raise exception using message = 'NODEX: invoice settlement requires billing.settle', errcode = '42501';
  end if;
  -- A settled invoice is immutable: amounts and status cannot be rewritten.
  if old.status = 'settled' then
    if new.total_minor is distinct from old.total_minor or new.settled_minor is distinct from old.settled_minor or new.currency is distinct from old.currency or new.issued_at is distinct from old.issued_at or new.settled_at is distinct from old.settled_at or new.patient_id is distinct from old.patient_id then
      raise exception using message = 'NODEX: settled invoices are immutable', errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger invoices_transition_guard before update on public.invoices for each row execute function nodex.tg_invoice_transition_guard();

-- Lines are editable while the invoice is a draft only.
create or replace function nodex.tg_invoice_line_draft_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  parent_status text;
begin
  select status into parent_status from public.invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if TG_OP = 'DELETE' then
    if parent_status <> 'draft' then
      raise exception using message = 'NODEX: only draft invoice lines can be removed', errcode = '42501';
    end if;
    return old;
  end if;
  if parent_status <> 'draft' then
    raise exception using message = 'NODEX: issued invoices cannot be re-priced; adjust with a new invoice', errcode = '42501';
  end if;
  if auth.uid() is not null and not nodex.has_permission(new.tenant_id, 'billing.settle') then
    raise exception using message = 'NODEX: pricing an invoice requires billing.settle', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger invoice_lines_draft_guard before insert or update or delete on public.invoice_lines for each row execute function nodex.tg_invoice_line_draft_guard();

-- Payments carry the running received total, derived server-side from the
-- invoice's prior events so the exclusion constraint has something to arbitrate.
create or replace function nodex.tg_payment_running_total()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  prior bigint;
  invoice_total bigint;
begin
  select coalesce(sum(p.amount_minor), 0) into prior from public.payments p where p.invoice_id = new.invoice_id;
  select total_minor into invoice_total from public.invoices where id = new.invoice_id;
  new.amount_received_minor := prior + new.amount_minor;
  if new.amount_received_minor > invoice_total then
    raise exception using message = 'NODEX: payment exceeds the outstanding invoice balance', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger payments_running_total before insert on public.payments for each row execute function nodex.tg_payment_running_total();

-- Refunds cannot exceed what was received.
create or replace function nodex.tg_refund_within_received()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  received bigint;
  refunded bigint;
begin
  select coalesce(sum(p.amount_minor), 0) into received from public.payments p where p.invoice_id = new.invoice_id;
  select coalesce(sum(r.amount_minor), 0) into refunded from public.refunds r where r.invoice_id = new.invoice_id;
  if refunded + new.amount_minor > received then
    raise exception using message = 'NODEX: refund exceeds the amount received', errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger refunds_within_received before insert on public.refunds for each row execute function nodex.tg_refund_within_received();

-- Events are append-only clinical/financial facts.
create trigger payments_append_only before update or delete on public.payments for each row execute function nodex.tg_block_mutation();
create trigger refunds_append_only before update or delete on public.refunds for each row execute function nodex.tg_block_mutation();

alter table public.invoices enable row level security;
alter table public.invoices force row level security;
alter table public.invoice_lines enable row level security;
alter table public.invoice_lines force row level security;
alter table public.payments enable row level security;
alter table public.payments force row level security;
alter table public.refunds enable row level security;
alter table public.refunds force row level security;

create policy invoices_select_member on public.invoices for select to authenticated using (nodex.has_permission(tenant_id,'billing.read'));
create policy invoices_insert_writer on public.invoices for insert to authenticated with check (nodex.has_permission(tenant_id,'billing.settle'));
create policy invoices_update_writer on public.invoices for update to authenticated using (nodex.has_permission(tenant_id,'billing.settle')) with check (nodex.has_permission(tenant_id,'billing.settle'));
create policy invoice_lines_select_member on public.invoice_lines for select to authenticated using (nodex.has_permission(tenant_id,'billing.read'));
create policy invoice_lines_insert_writer on public.invoice_lines for insert to authenticated with check (nodex.has_permission(tenant_id,'billing.settle'));
create policy invoice_lines_update_writer on public.invoice_lines for update to authenticated using (nodex.has_permission(tenant_id,'billing.settle')) with check (nodex.has_permission(tenant_id,'billing.settle'));
create policy payments_select_member on public.payments for select to authenticated using (nodex.has_permission(tenant_id,'billing.read'));
create policy payments_insert_writer on public.payments for insert to authenticated with check (nodex.has_permission(tenant_id,'billing.settle'));
create policy refunds_select_member on public.refunds for select to authenticated using (nodex.has_permission(tenant_id,'billing.read'));
create policy refunds_insert_writer on public.refunds for insert to authenticated with check (nodex.has_permission(tenant_id,'billing.settle'));
