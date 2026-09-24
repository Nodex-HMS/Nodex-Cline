# Supabase backend

The authoritative cloud system of record for NODEX Enterprise HMS.

PostgreSQL is authoritative; the encrypted PowerSync SQLite database on each
device is an operational projection of the rows that device is authorized to
hold. Row level security is the authoritative CRUD boundary, and PowerSync sync
streams define replication scope from the same authorization model.

## Applied migrations

`migrations/` holds the SQL applied to the linked project. Statement content was
verified against `supabase_migrations.schema_migrations` (normalized-hash
comparison plus object-level checks: every table, function, trigger, policy and
index confirmed live). One caveat for future verification: the migration tool
strips `--` comment lines when recording statements, so remote text differs from
these files by comments only — compare semantics, not bytes.

| Version | Name |
|---|---|
| 20260905155521 | `phase1_foundation_schema_and_helpers` |
| 20260905155624 | `phase1_tenancy_and_identity` |
| 20260905155707 | `phase1_users_roles_permissions` |
| 20260905155746 | `phase1_authorization_helper_functions` |
| 20260905155821 | `phase1_devices_and_offline_authorization` |
| 20260905155844 | `phase1_snapshot_revocation_guard` |
| 20260905155932 | `phase1_audit_and_clinical_events` |
| 20260905160818 | `phase1_sync_mutations_and_conflicts` |
| 20260905161314 | `phase1_ai_governance_registry` |
| 20260905161411 | `phase1_ai_execution_and_safety_records` |
| 20260905161515 | `phase1_enable_rls_and_core_policies` |
| 20260905161622 | `phase1_rls_policies_devices_audit_sync_ai` |
| 20260905161711 | `phase1_app_users_admin_field_guard` |
| 20260905161801 | `phase1_app_user_self_update_guard` |
| 20260905161834 | `phase1_dedupe_app_user_guard` |
| 20260905161942 | `phase1_seed_roles_and_permissions` |
| 20260905162031 | `phase1_seed_role_permission_grants` |
| 20260905162157 | `phase1_snapshot_issuance_rpc` |
| 20260905162531 | `phase1_revoke_anon_rpc_execute` |
| 20260910120545 | `phase1_user_provisioning` |
| 20260910120953 | `phase1_bootstrap_tenant_seed` |
| 20260911145344 | `phase2_mpi_patient_identity` |
| 20260911151649 | `phase2_mpi_contact_fields` |
| 20260911171737 | `phase2_mutations_device_nullable` |
| 20260912013739 | `phase2_emr_encounters` |
| 20260914154316 | `phase2_lab_workflows` |
| 20260914154755 | `phase2_lab_correction_reason` |

Two of these supersede earlier work rather than adding new objects, and are kept
rather than squashed so the history explains itself:
`phase1_snapshot_revocation_guard` replaces a blanket UPDATE block that also
blocked legitimate device revocation, and `phase1_dedupe_app_user_guard` removes
a redundant second guard trigger on `app_users`.

### Working with them

```bash
supabase login
supabase link --project-ref neoernavfntxsotwvmwq
supabase migration list      # local and remote should match
```

Apply further changes with `supabase migration new <name>` then
`supabase db push`. Do not edit the schema through the dashboard: the
specification prohibits uncontrolled schema changes, and an out-of-band edit
breaks the correspondence between RLS policies and sync stream definitions.

Reproducing the schema on a fresh project:

```bash
supabase link --project-ref <new-ref>
supabase db push
```

## What Phase 1 established

### Tenancy and identity

`tenants` → `facilities` → `departments` → `wards` form the scope hierarchy.
`app_users` is the authorization subject, mirroring `auth.users` with clinical
and HR attributes. `memberships` binds a user to a role within a tenant and an
optional facility, department or ward, and is the single source both RLS and sync
streams derive scope from.

### Role-based access control

`roles`, `permissions` and `role_permissions` implement the specification's role
matrix. Two permission attributes carry security weight:

- `requires_online` — the action must not execute from a cached offline
  authorization snapshot. The snapshot issuance function excludes these from the
  offline subset by construction rather than relying on client filtering.
- `risk_tier` — `high_risk` actions require backend/domain authorization beyond
  generic row-level access and always produce an audit event.

### Authorization helpers

`nodex.has_tenant_access`, `nodex.has_permission`, `nodex.has_role`,
`nodex.has_facility_access`, `nodex.has_department_access` and
`nodex.has_ward_access` are `SECURITY DEFINER` with a locked empty
`search_path`, so a membership lookup inside a policy cannot re-enter RLS and
recurse. Every policy consumes these rather than inlining its own subquery.

### Devices and offline authorization

`devices` is the enforcement point for lost or stolen device procedures:
revoking a device or setting `wipe_requested_at` stops snapshot issuance.
`authorization_snapshots` records every issued snapshot. It is append-only
except for a single permitted transition — setting `revoked_at` from the backend
path — enforced by `nodex.tg_snapshot_revocation_only`.

`public.issue_authorization_snapshot(...)` is the authorized issuance path. It
derives roles, permissions and scopes server-side from the membership graph and
never trusts client-supplied authorization input. `EXECUTE` is granted to
`authenticated` only; the `anon` grant is revoked.

The security advisor flags this grant (`0029_authenticated_security_definer_function_executable`).
That finding is **accepted, not ignored**: the function is the client-facing
issuance endpoint by design, and it authenticates the caller before doing
anything — it raises `28000` when `auth.uid()` is null, requires an `active`,
in-date membership in the requested tenant (`42501` otherwise), refuses devices
assigned to another user or pending a wipe, and returns only the caller's own
derived rights. A caller cannot pass a user id, role or permission in, so the
grant widens reachability, not privilege. Revoking it would break offline
authorization for every client.

### User provisioning

Access is granted by invitation, never by signup. An administrator holding
`user.administer` creates a `user_invites` row; when the invited email signs up
through Supabase Auth, the `on_auth_user_created_provision` trigger
(`nodex.tg_provision_invited_user`, executable by `supabase_auth_admin` only)
provisions the `app_users` row and every matching pending membership. A signup
without an invite provisions nothing: fail closed.

Invite governance: a pending invite may only transition to
cancelled/expired, never be edited; an accepted invite is frozen evidence
(`nodex.tg_user_invite_freeze`). Invitation creation and provisioning each write
an elevated audit event. The pipeline was verified end-to-end with a dry-run
provisioning (asserted `app_users` + `membership` + audit + invite acceptance,
then cleaned up) — including the discovery that the append-only audit guard
cannot be bypassed even by the table owner, which is the invariant working as
designed.

Bootstrap tenant (`slug = 'nodex-bootstrap'`, id
`10000000-0000-4000-8000-000000000001`, Asia/Dhaka): one hospital facility, two
departments (Medicine, Emergency), two wards (general, resuscitation). First
admin onboarding is an invite row plus a Supabase Auth signup for the same
email — no dashboard surgery on `app_users` or `memberships` required.

### Master Patient Index (Module 10)

`patients` holds one row per person per tenant with `(tenant_id, mrn)`
uniqueness (global MRN uniqueness would reject valid cross-hospital
collisions), a partial unique index on `(tenant_id, national_id_hash)`, and
name/phone/DOB search indexes over active records. Raw national IDs are never
stored — only hashes.

`patient_allergies` is a separate entity, not JSONB: allergy changes are
safety-critical, so `nodex.tg_allergy_retire_only` permits exactly one
transition (active → retired with reason and timestamp) and freezes every
clinical column. Corrections retire and re-insert; nothing is edited.

`patient_merge_history` is append-only (`tg_block_mutation`): surviving id,
absorbed id, decider, reason, per-field winners. Absorbed patient rows are
deactivated, never deleted.

All three tables carry FORCE RLS with membership-derived policies
(`patient.read` / `patient.write`) — never JWT claims, which cannot represent
multi-tenant principals.

### Longitudinal EMR encounters (Module 16)

`clinical_encounters` holds the SOAP record with a closed status machine
(`planned → in_progress → signed_and_locked → amended`) and a signature
consistency CHECK: `signed_at` exists exactly when the status is signed. Once
signed, `nodex.tg_encounter_freeze_after_sign` freezes every clinical column
and permits exactly one transition (`signed_and_locked → amended`).

`encounter_amendments` is append-only (`tg_block_mutation` plus no
update/delete RLS policy): corrections reference the frozen record with a
reason, field changes and author — the signed row is never rewritten.

The mutation path registers both tables: `encounter.started` /
`encounter.updated` for the shell, `encounter.amended` for amendments
(upsert-only, matching the append-only table).

### Laboratory workflow (Module 17)

`lab_orders`, `lab_specimens` and `lab_results` implement the handbook's
order -> specimen collected -> result entered -> verified workflow. Accession
barcodes are unique within a tenant. `lab_results` freezes verified values and
requires corrections to be new rows linked through `correction_of` with an
explicit `correction_reason`; the original value, verifier and timestamp remain
auditable. Order cancellation/completion and result transitions are guarded by
database triggers and CHECK constraints.

The mutation path registers the three laboratory tables with per-operation
audit actions. The PowerSync rules include them in the `lab_workflows` bucket;
the local repository/use cases enforce the same state gates before writes.

### Billing ledger (Module 31)

`invoices`, `invoice_lines`, `payments` and `refunds` store money in integer
minor units with an ISO-4217 currency code, never as a floating-point amount:
binary floating point cannot represent decimal currency exactly, and a
half-paisa rounding error in a settlement is a defect. The balance is derived,
never stored twice — `tg_payment_running_total` always recomputes
`amount_received_minor` from the ledger instead of trusting a client-supplied
value, and settlement writes `settled_minor` from the invoice's own total
(`tg_invoice_settlement_snapshot`), because that is what "settled" means.

Concurrency is arbitrated by the database, not the client
(`ConflictPolicy.transactional`): `payment_running_total_unique` excludes two
payment events on the same invoice that share a running total, so a genuinely
concurrent replay computed from the same prior state collides and is rejected on
upload, while sequential instalments are accepted. The earlier overlap-based
exclusion refused the legitimate second instalment, which is why the predicate
is equality on the running total rather than a range overlap.

`payments` and `refunds` are append-only (`tg_block_mutation` refuses UPDATE and
DELETE for every role), and a refund cannot exceed what was received for that
payment (`tg_refund_within_received`). Line edits are confined to draft
invoices (`tg_invoice_line_draft_guard`) and invoice transitions are guarded by
`tg_invoice_transition_guard`. RLS grants reads under `billing.read` and writes
under `billing.settle`; the sync rules replicate the ledger through
`billing_ledger`, and the mutation path registers all four tables.

### Inventory and stock control (Module 13)

`stock_items`, `stock_locations`, `stock_batches` and `stock_movements` hold
stock as a replayed ledger: balances derive from movements rather than being
overwritten (`ConflictPolicy.transactional`). Item and batch lifecycle
transitions are guarded in the database (`tg_stock_item_draft_guard`,
`tg_stock_batch_status_guard`), and items are retired by status, never deleted.

`stock_movements` is append-only on the same terms as the financial ledger:
`stock_movements_append_only` refuses UPDATE and DELETE for every role, and the
writer-scoped UPDATE policy was dropped with it, so a recorded movement cannot
be edited through the API even by a holder of `inventory.movement`. That guard
was added after the module's first cut, where the migration's own note
("movements are immutable events") had nothing enforcing it.

RLS grants reads under `patient.read` — a ward sees the stock it may issue
against — and writes under `inventory.movement`. The sync rules replicate the
module through `stock_control`, because a ward validates a request offline and
needs expiry and availability to do so.

### Backend mutation path

`supabase/functions/mutation-handler` (deployed, `verify_jwt: true`,
`withSupabase({ auth: 'user' })`) is the only route for offline-originated
writes. Per-mutation contract: validation → table allowlist → operation
allowlist → column validation (null passes; the database enforces NOT NULL
finally) → idempotency ledger (`received` first, so a ledger failure blocks the
apply) → audit-before-apply → apply under RLS → ledger marked
applied/rejected. Unknown outcomes from the client side decode as rejections.

Registered tables: 24 across the Phase 2 clinical modules — MPI (`patients`,
`patient_allergies`, `patient_merge_history`), EMR (`clinical_encounters`,
`encounter_amendments`), laboratory (`lab_orders`, `lab_specimens`,
`lab_results`), prescriptions and pharmacy (`prescriptions`,
`prescription_items`, `pharmacy_dispenses`, `medication_administrations`),
scheduling and stay management (`appointments`, `beds`, `bed_assignments`,
`discharges`), billing (`invoices`, `invoice_lines`, `payments`, `refunds`) and
inventory (`stock_items`, `stock_locations`, `stock_batches`,
`stock_movements`). Each entry carries its own operation allowlist and audit
actions: append-only event tables accept `upsert` only, and the retire-only and
status-transition tables are refused at the database as well as here.

The Flutter connector (`NodexBackendConnector.uploadData`) submits PowerSync
CRUD batches with UUIDv5 ids derived from the queue position, so retries land
on the same ledger row. Deletes are refused on both ends; retirement is a
status transition.

### Audit and clinical events

`audit_events` is the high-risk audit envelope and `clinical_events` the
immutable per-aggregate event stream. Both block `UPDATE` and `DELETE` at the
database level through `nodex.tg_block_mutation`, so application-facing history
cannot be silently rewritten. Administrative tools query and export; they do not
edit.

### Synchronization bookkeeping

`mutations` carries a unique `(tenant_id, idempotency_key)`, which is what makes
reconnection produce exactly-once business effect for idempotent mutations.
`mutation_attempts` separates transient failures from permanent rejections.
`conflict_records.entity_policy` names the deterministic per-entity strategy
applied; there is no global last-write-wins for clinical data.

### AI governance

`ai_model_registry` encodes the governance gate as a table constraint: a model
cannot reach `approved` or `active` without `evaluation_status = 'passed'`, a
recorded `evaluation_set_revision`, and a recorded approver. A provider catalog
scan therefore cannot promote a model into clinical production.

`ai_routing_policies` holds a per-engine primary/secondary/tertiary/offline
chain — deliberately not one universal chain shared by every engine.
`ai_requests`, `ai_responses`, `ai_safety_decisions` and `ai_reviews` record
engine, policy revision, profile revision, model, provider, attempt number,
failure class, circuit state and the human review decision.

## Remaining backend work

- **PowerSync instance.** Rules are written (`powersync/sync-rules.yaml`, parameters
  derived from the JWT via `request.user_id()` and the membership graph, never
  client input) and the reader-role grant matrix is documented
  (`powersync/SETUP.md`, including why the reader needs BYPASSRLS under FORCE'd
  tables). No instance is provisioned yet; acceptance is a ward-scoped user
  receiving that ward's rows only, verified against the local database.
- **Storage buckets.** DICOM, PDFs, scans and signatures need tenant-scoped
  buckets with short-lived signed URLs and checksum validation on upload.
- **Backup and restore.** RPO/RTO targets defined and a restore actually
  exercised, not merely documented.
