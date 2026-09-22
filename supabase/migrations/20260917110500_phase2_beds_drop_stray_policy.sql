-- NODEX Phase 2, Module 11 follow-up: drop a stray policy.
--
-- The base migration accidentally shipped beds_insert_admin2 (check (false)),
-- which permits nothing but trips the multiple_permissive_policies linter.
-- The local base file never contained it; this restores parity.
drop policy if exists beds_insert_admin2 on public.beds;
