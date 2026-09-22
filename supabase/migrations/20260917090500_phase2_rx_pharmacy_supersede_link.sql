-- NODEX Phase 2, Module 25 follow-up: forward version link.
--
-- Dry-run finding: prescription_supersede_ck required the SUPERSEDED (old) row
-- to carry supersedes, but the link lives on the NEW version (v2.supersedes =
-- v1). The old row needs its own forward pointer, so superseding sets
-- superseded_by and the check enforces that instead.

alter table public.prescriptions add column superseded_by uuid references public.prescriptions(id) on delete restrict;
alter table public.prescriptions drop constraint prescription_supersede_ck;
alter table public.prescriptions add constraint prescription_supersede_ck check ((status = 'superseded' and superseded_by is not null) or status <> 'superseded');
