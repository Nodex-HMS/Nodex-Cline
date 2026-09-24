-- NODEX Phase 2, Module 13 follow-up: stock movements are append-only.
--
-- The inventory migration documents movements as immutable events, but the
-- guard was never created and a writer-scoped UPDATE policy was left in place,
-- so a recorded movement could be rewritten through the API. Balances replay
-- from this ledger (ConflictPolicy.transactional), which only holds if a
-- movement cannot be edited after the fact.
--
-- Mirrors payments_append_only and pharmacy_dispenses_append_only: UPDATE and
-- DELETE are refused for every role.

create trigger stock_movements_append_only before update or delete on public.stock_movements for each row execute function nodex.tg_block_mutation();

-- The UPDATE policy goes with the guard: there is no legitimate update to
-- authorize, and leaving it would advertise a capability the database refuses.
drop policy stock_movements_update_writer on public.stock_movements;
