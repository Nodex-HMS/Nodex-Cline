-- NODEX Phase 2, Module 25 follow-up: frozen history.
--
-- Dry-run finding: the immutability block only covered finalized rows staying
-- finalized, so content edits to superseded/discontinued/cancelled rows passed
-- silently. Any authorized (non-draft) row that is not transitioning is now
-- frozen; a change is a new version, never a mutation.

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
  -- An authorized order is immutable except for its terminal transitions; any
  -- content change is a new version, never a mutation. Drafts remain editable.
  if old.status <> 'draft' and new.status = old.status then
    if new.tenant_id is distinct from old.tenant_id or new.patient_id is distinct from old.patient_id or new.encounter_id is distinct from old.encounter_id or new.prescribed_by is distinct from old.prescribed_by or new.prescription_code is distinct from old.prescription_code or new.version is distinct from old.version or new.priority is distinct from old.priority or new.indication is distinct from old.indication or new.finalized_by is distinct from old.finalized_by or new.finalized_at is distinct from old.finalized_at or new.supersedes is distinct from old.supersedes or new.superseded_by is distinct from old.superseded_by or new.closed_at is distinct from old.closed_at or new.closure_reason is distinct from old.closure_reason then
      raise exception using message = 'NODEX: authorized prescriptions are immutable; create a new version', errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
