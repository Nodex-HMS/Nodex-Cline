-- NODEX Phase 2, Module 31 follow-up: the client cannot supply its own total.
--
-- Dry-run finding: a client that supplied amount_received_minor explicitly
-- bypassed the derived value, so a second device's stale total overwrote the
-- running one and two settlements could coexist. The running total is a
-- server-derived fact: the trigger now always recomputes it from the ledger,
-- and only the exclusion constraint arbitrates a genuine concurrent replay
-- (both events computed from the same prior state), which is the documented
-- transactional policy.
create or replace function nodex.tg_payment_running_total()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  prior bigint;
  invoice_total bigint;
  invoice_status text;
begin
  select total_minor, status into invoice_total, invoice_status from public.invoices where id = new.invoice_id;
  if invoice_status in ('settled','cancelled') then
    raise exception using message = 'NODEX: closed invoices cannot receive payments', errcode = '42501';
  end if;
  -- Always derived, never accepted from the client.
  select coalesce(sum(p.amount_minor), 0) into prior from public.payments p where p.invoice_id = new.invoice_id;
  new.amount_received_minor := prior + new.amount_minor;
  if new.amount_received_minor > invoice_total then
    raise exception using message = 'NODEX: payment exceeds the outstanding invoice balance', errcode = '42501';
  end if;
  return new;
end;
$$;
