-- NODEX Phase 2, Module 25 follow-up: single update policy per table.
--
-- The draft/finalizer (and drafter/dispenser) policy pairs are semantically an
-- OR, which is exactly how multiple permissive policies evaluate — but the
-- pair trips the multiple_permissive_policies linter on every query. One
-- policy with the OR inside is identical in meaning and lint-clean. The
-- transition-level permission split still lives in the triggers, where RLS
-- cannot express it.

drop policy prescriptions_update_drafter on public.prescriptions;
drop policy prescriptions_update_finalizer on public.prescriptions;
create policy prescriptions_update_writer on public.prescriptions for update to authenticated
  using (nodex.has_permission(tenant_id,'prescription.draft') or nodex.has_permission(tenant_id,'prescription.finalize'))
  with check (nodex.has_permission(tenant_id,'prescription.draft') or nodex.has_permission(tenant_id,'prescription.finalize'));

drop policy prescription_items_update_drafter on public.prescription_items;
drop policy prescription_items_update_dispenser on public.prescription_items;
create policy prescription_items_update_writer on public.prescription_items for update to authenticated
  using (nodex.has_permission(tenant_id,'prescription.draft') or nodex.has_permission(tenant_id,'pharmacy.dispense'))
  with check (nodex.has_permission(tenant_id,'prescription.draft') or nodex.has_permission(tenant_id,'pharmacy.dispense'));
