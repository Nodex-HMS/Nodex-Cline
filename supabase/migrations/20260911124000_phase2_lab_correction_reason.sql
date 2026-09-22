-- NODEX Phase 2, Module 17: correction rationale.
--
-- A corrected laboratory result preserves what/when/who through the result
-- row and its verification fields. This column preserves why explicitly.

alter table public.lab_results add column correction_reason text;

comment on column public.lab_results.correction_reason is
  'Required for corrected rows: why the original verified laboratory result was changed.';

alter table public.lab_results add constraint lab_result_correction_reason_ck check (
  (status = 'corrected' and correction_reason is not null and length(btrim(correction_reason)) > 0)
  or status <> 'corrected'
);
