# Continuation notes

Written at the end of the Phase 1 session so the next session can resume without
re-deriving decisions. Read this first, then `README.md` for architecture.

---

## Where everything is

| Thing | Location |
|---|---|
| Repository | `github.com/Nodex-HMS/Nodex-Cline`, branch `main` |
| Phase 1 + 2 commit | `de396ca` — "feat: NODEX Enterprise HMS - Phase 1 platform foundation + Phase 2 core clinical modules"; merge `57aef73` |
| Supabase project | ref `afvncnzdhobvnweixgdm`, URL `https://afvncnzdhobvnweixgdm.supabase.co` |
| Migrations | `supabase/migrations/` — 41 files, all 41 applied to `afvncnzdhobvnweixgdm` and confirmed via `list_migrations`. Statement content verified against `supabase_migrations.schema_migrations`. Note: the migration tool strips `--` comments when recording, so verify semantics not bytes. |
| Source spec | `NODEX_HMS_Final.pdf`, 44 pages (read with `pdftotext -layout`; the PDF reader tool cannot handle PDFs on this model) |

---

## Resuming

### Toolchain

The verification toolchain is Flutter 3.47.2 stable. If the sandbox was reset,
reinstall before doing anything else:

```bash
git clone --depth 1 --branch stable https://github.com/flutter/flutter.git /opt/sdk/flutter
export PATH=/opt/sdk/flutter/bin:$PATH
flutter --version          # first run downloads the Dart SDK; ~6 min on a slow link
flutter config --no-analytics
```

On aarch64 the Dart SDK download and the `flutter_tools` snapshot build each take
several minutes and will exceed a 120 s command timeout. Run them detached
(`setsid nohup … &`) and poll, rather than waiting inline. If a run is
interrupted, delete `/opt/sdk/flutter/bin/cache/lockfile` before retrying.

### Verify the checkout is sound

```bash
cd /root/workspace/nodex_hms
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos --fatal-warnings
flutter test
```

Expected: no formatting changes, no analyzer issues, 410 tests passing. If any of
those fail on a clean checkout, fix that before writing new code — CI enforces
all three.

### Verify the backend matches

```bash
supabase link --project-ref neoernavfntxsotwvmwq
supabase migration list     # local and remote should agree on all 19
```

---

## Decisions already made

Recorded so they are not relitigated. Each was a real choice with alternatives.

**Migrations are kept unsquashed.** Two of the nineteen supersede earlier work
(`phase1_snapshot_revocation_guard`, `phase1_dedupe_app_user_guard`). They stay
because the history explains why the first attempt was wrong — a blanket UPDATE
block on snapshots also blocked legitimate device revocation.

**Governance gates live in the database, not the client.** The AI model lifecycle
gate is a CHECK constraint; audit immutability is a trigger. A client bug cannot
route around either.

**The offline permission subset is computed server-side.** `requires_online` is a
column on `permissions`, and the issuance RPC filters on it. The client's
catalogue in `permission_catalog.dart` is a defensive second gate for stale
snapshots, not the source of truth.

**Bedside high-risk actions stay available offline.** Medication administration,
dispensing and triage escalation are `high_risk` but not `requires_online`: they
happen where connectivity cannot be assumed, and the audit trail records that
they occurred offline. Finalization actions (prescription, discharge, transfusion,
billing settlement) are online-only.

**AI adapters ship unconfigured.** Every engine resolves to a manual workflow.
This is the correct state before any model has passed evaluation, and it means
the Orchestrator's failover path is exercised by real code rather than mocked.

**`ClinicalDocumentExtraction` is `onDeviceOnly`.** LFM2.5-VL-450M is the
designated edge vision model, so document images do not leave the device unless a
separately validated cloud vision model is explicitly enabled in the profile.

**Analysis is strict on purpose.** `discarded_futures` and `unawaited_futures` are
errors because an unawaited future in a clinical write path silently drops a
mutation. `avoid_print` is an error because PHI must not reach a general log.

---

## Phase 2 in dependency order

The backend mutation path is shipped and MPI is landed. The PowerSync instance
is still the gating item: without it, MPI writes queue locally but never
upload, and no replicated data reaches a device.

### 1. PowerSync instance (rules done, instance missing)

Rules are written at `powersync/sync-rules.yaml` with parameters derived from
the JWT (`request.user_id()`) plus the membership graph — never client input.
`powersync/SETUP.md` documents the reader-role grant matrix, including why the
reader needs BYPASSRLS (ten tables are FORCE RLS with `TO authenticated`
policies, so a non-bypass reader sees zero rows and every bucket comes back
silently empty).

Still missing: the instance itself. Without it no data reaches a device, so no
clinical module can be tested offline.

Acceptance: a device holding a ward-scoped nursing membership replicates rows for
that ward only. Verify by inspecting the local database directly, not by checking
that the interface hides other wards.

### 2. Backend mutation path (shipped)

`supabase/functions/mutation-handler` is deployed with `verify_jwt: true` and
uses `withSupabase({ auth: 'user' })` per the supabase-server skill (auth key is
`auth`, not `allow`; modes are `user`/`publishable`/`secret`/`none`). The
Flutter connector submits CRUD batches with stable UUIDv5 ids and decodes
per-mutation outcomes; unknown outcomes decode as rejections. The table
allowlist is empty by design: a table registers with a validator in the same
change that adds its offline write path.

Next on this path: `device_id` in the mutations ledger (connector currently
sends null) and a real SHA-256 `payload_digest` instead of the idempotency-key
placeholder.

### 3. First clinical modules (MPI, encounters, laboratory and Rx vertical slices landed)

**Master Patient Index (module 10)** and **Longitudinal EMR encounters
(module 16)** are implemented as reference vertical slices: Postgres schema
with RLS, PowerSync local schema, repository with test seam, `*.write`-gated
use cases, screens, field-level merge (MPI) and signature-gated freeze with
append-only amendments (encounters), the laboratory state machine (order ->
specimen -> entered result -> verified/corrected), and the prescription
lifecycle (draft -> finalized version -> dispense events -> MAR events, module
25). All clinical tables are registered in the mutation-handler allowlist,
local schema/repositories/use-case tests are present, and the patient detail
UI now links to encounter, laboratory and prescription workflows.

Handbook deviations applied while building it (all deliberate, all documented
in the migration headers):
- `(tenant_id, mrn)` uniqueness instead of global `mrn UNIQUE`
- FKs to `app_users(id)`, not `users(id)`
- Membership-derived RLS instead of `auth.jwt() ->> 'tenant_id'`
- Allergies as a separate frozen-column entity instead of JSONB columns
- Registry `mergeableFields` corrected to real column names (`phone_number`,
  not `phone`); six contact columns added to match
- Prescription series code is unique per `(tenant_id, code, version)`, with a
  forward `superseded_by` link, because each version is its own row
- Prescription finalize-class transitions enforce `prescription.finalize` in
  the trigger (RLS cannot distinguish them from draft edits); item release
  rides on the header authorization so prescribers need no dispense permission

Billing (31) and inventory (13) landed after these slices; section 4 records the
wiring defects found and fixed in the session that applied their migrations.
The discharge vertical slice is complete at the
code level (410 tests passing): one finalized record per encounter, draft on
encounter.write with high-risk online-only finalization enforced in-trigger,
immutable after finalizing, encounter picker on the patient record, and a
bed-release shortcut closing the stay loop. Hardware barcode scanning,
PowerSync device verification and clinical deployment validation remain
across all clinical slices.

### 4. Billing (module 31) and inventory (module 13) wiring (fixed)

Both modules shipped migrations, domain models, repositories and screens before
their client-side wiring existed, and the tree did not compile:
`lib/core/storage/local_schema.dart` declared no local tables for them while
`billing_repository.dart` and `inventory_repository.dart` referenced
`LocalTables.invoices`, `LocalTables.invoiceLines`, `LocalTables.payments`,
`LocalTables.refunds`, `LocalTables.stockItems`, `LocalTables.stockLocations`,
`LocalTables.stockBatches` and `LocalTables.stockMovements` — eight unresolved
symbols, which no test could catch because neither module had a repository test
yet. Three defects, fixed together:

- **Missing local tables.** The eight tables are now declared with every server
  column and registered in `NodexLocalSchema.build()`, pinned by
  `local_schema_test.dart`. A drift check that resolves every local column
  against `information_schema.columns` now returns zero rows across all 37
  synced tables.
- **Missing sync buckets.** `sync-rules.yaml` had no bucket for either module,
  so the local tables would have stayed empty even once they existed.
  `billing_ledger` (`billing.read`) and `stock_control` (`patient.read`) mirror
  their RLS policy families; both parameter queries and all eight data queries
  were executed against the live project to prove the SQL and the scope.
- **A boolean cast that only fails offline.** `StockItem.fromRow` read
  `requires_batch` / `requires_expiry` with `as bool?`. PostgREST sends JSON
  booleans, but the SQLite projection holds 0/1, so the cast would have thrown
  on the device and never in a server test. It now parses both shapes and
  throws a named `FormatException` otherwise, matching the MPI convention.

Applying the inventory migration also surfaced that `stock_movements` — the
module's append-only ledger, and the table balances replay from — had no
append-only guard and still carried a writer-scoped UPDATE policy, so a recorded
movement could be rewritten through the API by anyone holding
`inventory.movement`. `phase2_stock_movements_append_only` adds the same
`tg_block_mutation` guard `payments`, `refunds`, `pharmacy_dispenses` and the
event tables use, and drops the UPDATE policy; the mutation-handler rule is
`upsert`-only for that table. Enforcement was verified by writing a movement and
observing the UPDATE refused with `42501` inside a subtransaction that rolls the
probe back, so no probe row survives.

---

## Known gaps

Deferred deliberately, not overlooked.

- **Release signing is not configured.** The release build type falls back to the
  debug key so verification builds succeed. Supply real signing material before
  distributing anything.
- **No widget or integration tests.** All 332 tests are unit tests. The adaptive
  shell, route guards and session lifecycle have no widget coverage; the spec's
  integration flows (appointment → encounter → prescription → pharmacy → billing)
  have none either.
- **No storage buckets.** DICOM, PDFs, scans and signatures need tenant-scoped
  buckets with short-lived signed URLs and checksum validation on upload.
- **No backup or restore procedure.** RPO/RTO targets must be defined and a
  restore actually exercised, not merely documented.
- ~~**`app_users` rows are not created automatically**~~ — **resolved.**
  `phase1_user_provisioning` adds `user_invites` plus an `AFTER INSERT` trigger
  on `auth.users`: invited emails auto-provision `app_users` + membership on
  first signup; uninvited signups get nothing. Verified end-to-end with a
  dry-run, including proof that the append-only audit guard cannot be bypassed
  even by the table owner.
- ~~**No seeded tenant**~~ — **resolved.** `phase1_bootstrap_tenant_seed`
  creates `nodex-bootstrap` (Asia/Dhaka, fixed UUIDs): 1 facility, 2
  departments, 2 wards.
- ~~**No bootstrap administrator exist on a fresh project**~~ — **resolved.**
  Invite `0ab1bf61-5bb2-4045-b8e9-e7cbc4871a05` (`admin@nodex.local`,
  `hospital_super_admin`) created, then the Auth user was created; the
  `on_auth_user_created_provision` trigger consumed the invite and produced an
  `app_users` row (`active`), an `active` membership in tenant
  `10000000-0000-4000-8000-000000000001`, and a `user.provisioned` audit event.
  Password sign-in against `/auth/v1/token?grant_type=password` returns a token
  and authenticated reads resolve to exactly the bootstrap tenant, while the
  same reads without a token return nothing (RLS holding). The bootstrap
  password is a throwaway and **must be rotated** before the instance is shared.
- **Auth hardening toggles are dashboard-only.** Leaked-password protection is
  reported disabled by the security advisor and cannot be enabled from SQL.
- **CI secrets are not populated.** `.github/workflows/ci.yml` needs
  `NODEX_SUPABASE_URL` and `NODEX_SUPABASE_PUBLISHABLE_KEY` repository secrets
  before a release APK job will pass its preflight check.

---

## Fastest path to a running app

1. Insert a `user_invites` row (needs `user.administer` in the tenant, or run as
   owner): tenant `10000000-0000-4000-8000-000000000001`, the admin email,
   `role_key = 'hospital_super_admin'`.
2. Create the Supabase Auth user for the same email (dashboard or API). The
   provisioning trigger creates `app_users` + membership automatically. With no
   mail delivery, `supabase/bootstrap/bootstrap_admin.sql` does both steps when
   fed to `psql`, taking the throwaway password from a `nodex.bootstrap_password`
   setting rather than the file, and is idempotent on re-run.
3. Build with `--dart-define=NODEX_SUPABASE_URL=…` and
   `--dart-define=NODEX_SUPABASE_PUBLISHABLE_KEY=…` (publishable, never a secret
   key — startup validation rejects privileged keys).
4. Sign in with the tenant UUID, email and password. The app will issue a
   snapshot, land on the role-aware home, and show which modules that role
   reaches. An uninvited account lands on the awaiting-authorization screen with
   a first-run explanation instead of a database error string.

### Creating the first Auth user from SQL

Sign-up through the dashboard or the Auth API is the normal path. When there is
no mail delivery and the user must be created from SQL, three details decide
whether sign-in works:

- `auth.identities.email` is a **generated column**; supply
  `provider_id = user_id::text`, `provider = 'email'` and an `identity_data`
  containing `sub` and `email`. Only `id`, `user_id`, `provider_id`,
  `provider`, `identity_data` and the timestamps are insertable.
- GoTrue scans `confirmation_token`, `recovery_token`, `email_change` and
  `email_change_token_new` as strings. A row inserted without them carries
  `NULL`, and every password grant then fails with `500` before any credential
  comparison. Set them to `''` (or coalesce them after insert).
- Set `email_confirmed_at` so the account is usable without a verification mail,
  and insert `auth.users` plus `auth.identities` in one statement so a failure
  cannot leave an account that exists but cannot be looked up.

Verify with a real grant rather than by reading rows: `POST
/auth/v1/token?grant_type=password` must return an access token, and an
authenticated `GET /rest/v1/tenants` must return only the invited tenant while
the same request without a token returns nothing.

Replication stays disconnected until `NODEX_POWERSYNC_URL` is supplied; the app
runs local-only and says so in the settings screen.
