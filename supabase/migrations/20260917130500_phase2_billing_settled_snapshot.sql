-- NODEX Phase 2, Module 31 follow-up: settlement snapshots the balance.
--
-- Dry-run finding: the settlement guard compared new.settled_minor against
-- total_minor, so a partial payment followed by a settlement that did not
-- carry the running paid total could never reach the derived settlement
-- helper's expected state. Settlement now writes settled_minor from the
-- invoice's own invariant (total), which is what "settled" means, while the
-- guard still refuses a settlement that has no timestamp or under-covers.
create or replace function nodex.tg_invoice_settlement_snapshot()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'settled' and old.status <> 'settled' then
    new.settled_minor := new.total_minor;
    new.settled_at := coalesce(new.settled_at, now());
  end if;
  return new;
end;
$$;
create trigger invoices_settlement_snapshot before update on public.invoices for each row execute function nodex.tg_invoice_settlement_snapshot();
