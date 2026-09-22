-- NODEX Phase 2, Module 31 follow-up: settlement events are sequential.
--
-- Dry-run finding: the exclusion on payments compared running totals with
-- `&&`, so the second instalment (running 20k -> 50k) overlapped the first
-- instalment's range and was refused. Overlap is the wrong predicate here:
-- each event is a strictly increasing running total, so the invariant is that
-- no two events on the same invoice may share a running total. A truly
-- concurrent duplicate computed from the same pre-state collides, which is
-- the arbitration the transactional policy needs, and sequential instalments
-- are accepted.
alter table public.payments drop constraint payment_no_over_settlement;
alter table public.payments add constraint payment_running_total_unique
  exclude using gist (invoice_id with =, int8range(0, amount_received_minor) with =)
  where (amount_received_minor is not null);
