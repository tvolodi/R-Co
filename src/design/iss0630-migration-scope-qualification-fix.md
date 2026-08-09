# ISS-0630 / GH-605 — Public-scope qualification fix for 9 migration files

## Module purpose

Nine numeric migration files declare `-- scope: public` (added by commit
a2a8c68 / ISS-0185 / GH-518) but perform unqualified `CREATE TABLE` /
`INSERT INTO` work that resolves through `search_path` rather than being
explicitly qualified to the `public` schema. `declaresUnqualifiedTableWork()`
in `src/db/migrations.zig` (built by ISS-0604 / GH-470 for exactly this
defect class) correctly refuses to apply any such file when
`declaresPublicScopeHeader()` is also true, returning
`MigrationError.MigrationScopeMismatch`. This is invisible on every
long-lived shared `db_test`/`bpm_dev` database because those files were
ledger-recorded as applied before a2a8c68 changed their content, and
`runForSchema` skips already-applied files outright — the guard's
`is_public_pass and declaresPublicScopeHeader(...) and
declaresUnqualifiedTableWork(...)` check (migrations.zig:414-419) is only
ever reached for a file the runner is about to execute for the first time.
Only a genuinely fresh database exercises it, which is exactly how
ORCH reproduced GH-482/ISS-0150's blocker.

This design is a pure content-correctness edit: qualify every unqualified
`CREATE TABLE` / `ALTER TABLE` / `INSERT INTO` statement identified below
with the `public.` prefix, in place, in each of the 9 files. All 9 tables
are genuinely global/platform-wide (metrics, rate limiting, OIDC realm
config, onboarding registry, service catalog, alerting state, IdP
lifecycle ledgers, entity-subsystem registries) — none hold per-tenant
business data — so the fix is schema-qualification of the existing
`-- scope: public` intent, never a change of the scope header itself to
`-- scope: all_schemas`.

## Guard semantics consulted (read directly from src/db/migrations.zig)

`declaresUnqualifiedTableWork(body: []const u8) bool` (migrations.zig:651-684)
scans every line of `body`, split on `\n` and trimmed:

- Skips comment lines (`--` prefix) and lines containing `%I` (dynamic
  schema interpolation).
- For each of the statement heads `CREATE TABLE IF NOT EXISTS `,
  `CREATE TABLE `, `ALTER TABLE IF EXISTS `, `ALTER TABLE `,
  `DROP TABLE IF EXISTS `, `DROP TABLE `, `INSERT INTO ` (in that order,
  first match wins per line), it inspects the identifier immediately
  following the head.
- If that identifier starts with `public.`, `pg_`, or `information_schema.`
  the line is **not** a violation (`break`, continue to next line).
- Otherwise the function returns `true` immediately — a single unqualified
  hit anywhere in the file is sufficient to trip the guard.

**`CREATE INDEX` / `CREATE UNIQUE INDEX` are NOT in the `heads` list** and
never trip this guard, regardless of qualification. `COMMENT ON TABLE` /
`COMMENT ON INDEX` are likewise not checked. This matters for File 5 and
File 6 below, which contain unqualified `CREATE INDEX ... ON <table>`
statements that do **not** need editing for the guard's sake — see the
per-file notes.

The guard is only evaluated when `is_public_pass and
declaresPublicScopeHeader(filename, sql_bytes)` — and at the guard's call
site (migrations.zig:401-419), `sql_bytes` is the **entire file content**
(read with a 16 MiB limit at line 402), not a truncated header probe. The
4096-byte-limited `scope_header` read at lines 303-312 is a *different*
code path used only for the per-tenant-pass skip decision
(`!is_public_pass`) and is irrelevant to the guard that is failing here.
Consequently, for File 9 (`094_entity_subsystem.sql`), where the
`-- scope: public` comment sits inside a `DO $$ BEGIN ... END $$;` block
rather than at the top of the file, `declaresPublicScopeHeader` still sees
it (it scans the whole file for the `-- scope: public` substring via
`std.mem.indexOf`), and `declaresUnqualifiedTableWork` still scans the
whole file for unqualified heads — including the `INSERT INTO
event_type_registry` near the end, ~90 lines after the comment.

## Public interface

No Zig public interface changes. This design touches only migration SQL
file bodies. The affected functions (`declaresUnqualifiedTableWork`,
`declaresPublicScopeHeader`, `migrationScope`, `runForSchema`) are
consulted as-is and are explicitly **not** modified — the guard is correct
and caught a real defect; the fix is to the data it inspects, not to the
guard itself (see `CLAUDE.md` "Never Satisfy a Gate by Editing What It
Measures").

Per-file edit list — statement-by-statement, confirmed by direct read of
each file's current content:

**File 1 — `migrations/011_webhook_subscriptions.sql`**
- `CREATE TABLE IF NOT EXISTS metric_snapshots (` → `CREATE TABLE IF NOT EXISTS public.metric_snapshots (`
- `CREATE TABLE IF NOT EXISTS rate_limit_buckets (` → `CREATE TABLE IF NOT EXISTS public.rate_limit_buckets (`
- `CREATE INDEX IF NOT EXISTS idx_ms_name_time ON metric_snapshots(...)` and
  `CREATE INDEX IF NOT EXISTS idx_rlb_cleanup ON rate_limit_buckets(...)`:
  not required by the guard (`CREATE INDEX` is not a checked head), but
  qualify the `ON` target to `public.metric_snapshots` /
  `public.rate_limit_buckets` for readability/consistency with the tables
  they index, now that those tables carry an explicit qualifier two lines
  above. Optional, not guard-mandatory — implementer's call, does not
  change guard behaviour either way.

**File 2 — `migrations/022_obs06_alerting_state.sql`**
- `CREATE TABLE IF NOT EXISTS obs_alert_trigger_state (` → `... public.obs_alert_trigger_state (`
- `CREATE TABLE IF NOT EXISTS obs_alert_hook_emission_state (` → `... public.obs_alert_hook_emission_state (`
- Same optional `CREATE INDEX ... ON` qualification note as File 1 (not guard-mandatory).

**File 3 — `migrations/038_oidc_claim_mapping_config.sql`**
- `CREATE TABLE IF NOT EXISTS realm_claim_mapping_config (` → `... public.realm_claim_mapping_config (`
- No indexes, no inserts in this file.

**File 4 — `migrations/039_jit_provisioning_config.sql`**
- `CREATE TABLE IF NOT EXISTS jit_provisioning_config (` → `... public.jit_provisioning_config (`
- `INSERT INTO jit_provisioning_config (realm, ...)` → `INSERT INTO public.jit_provisioning_config (realm, ...)`
- Not guard-checked but present: `CREATE OR REPLACE FUNCTION
  jit_provisioning_config_set_updated_at()`, `DROP TRIGGER IF EXISTS ... ON
  jit_provisioning_config`, `CREATE TRIGGER ... ON jit_provisioning_config`.
  None of `CREATE FUNCTION` / `DROP TRIGGER` / `CREATE TRIGGER` are in the
  guard's head list, so they are not required edits. For internal
  consistency, qualify the two `... ON jit_provisioning_config` clauses to
  `public.jit_provisioning_config` as well — same non-mandatory rationale
  as the index notes above.

**File 5 — `migrations/041_oidc15_realm_deletion_tracker.sql`**
- `CREATE TABLE IF NOT EXISTS realm_deletion_tracker (` → `... public.realm_deletion_tracker (`
- `CREATE INDEX IF NOT EXISTS idx_realm_deletion_tracker_pending ON
  realm_deletion_tracker (...)`: not guard-checked (`CREATE INDEX`), optional
  qualification only.
- `CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_idp_realm_id ON tenant
  (idp_realm_id) ...`: this references the **`tenant`** table, created in
  `031_adp04b_tenant_realm_binding.sql`, a file outside this fix's scope.
  `tenant` is not one of the 9 affected/newly-qualified tables. `CREATE
  INDEX` is not a guard-checked head regardless, so this line requires no
  change for guard purposes. Confirmed out of scope: qualifying it is
  optional polish, not correctness-required, and left as-is to keep the
  diff minimal and focused on the actual defect.
- No FK/cross-reference among the 9 files' own new tables appears here.

**File 6 — `migrations/042_oidc16_26_agent_lifecycle_foundations.sql`**
(largest file — 9 tables)
- `CREATE TABLE IF NOT EXISTS idp_operation_ledger (` → `... public.idp_operation_ledger (`
- `CREATE TABLE IF NOT EXISTS idp_transaction_log (` → `... public.idp_transaction_log (`
- `CREATE TABLE IF NOT EXISTS idp_adapter_audit (` → `... public.idp_adapter_audit (`
- `CREATE TABLE IF NOT EXISTS agent_identity_binding (` → `... public.agent_identity_binding (`
- `CREATE TABLE IF NOT EXISTS agent_secret_rotation (` → `... public.agent_secret_rotation (`
- `CREATE TABLE IF NOT EXISTS agent_bootstrap_state (` → `... public.agent_bootstrap_state (`
- `CREATE TABLE IF NOT EXISTS agent_bootstrap_audit (` → `... public.agent_bootstrap_audit (`
- `CREATE TABLE IF NOT EXISTS idp_federation_binding (` → `... public.idp_federation_binding (`
- `CREATE TABLE IF NOT EXISTS federation_attribute_mapping (` → `... public.federation_attribute_mapping (`
- `CREATE TABLE IF NOT EXISTS subsystem_health_probe (` → `... public.subsystem_health_probe (`
- All 10 `CREATE [UNIQUE ]INDEX IF NOT EXISTS ... ON <table> (...)` lines in
  this file target only these same 10 newly-qualified tables (no
  cross-references to tables outside this file) — not guard-checked, optional
  qualification only, consistent with the other files.
- No intra-file FK columns reference each other's tables by name (all
  columns like `transaction_id`, `realm_id` are plain typed columns, not
  `REFERENCES` clauses) — confirmed via grep, no `REFERENCES` keyword
  anywhere in this file.

**File 7 — `migrations/049_repository_service_catalog.sql`**
- `CREATE TABLE IF NOT EXISTS service_catalog (` → `... public.service_catalog (`
- Two duplicate pairs of `CREATE INDEX IF NOT EXISTS idx_service_catalog_created
  ON service_catalog (created_at)` / `idx_service_catalog_updated ON
  service_catalog (updated_at)` (file defines each index twice — pre-existing
  duplication, harmless because both are `IF NOT EXISTS`, out of scope for
  this fix to deduplicate). Not guard-checked; optional qualification only.
- `COMMENT ON TABLE service_catalog IS ...` / `COMMENT ON COLUMN
  service_catalog.* IS ...`: not guard-checked (`COMMENT ON` is not a head),
  no change required. Optionally qualify to `public.service_catalog` in the
  `COMMENT ON TABLE` line for consistency; not guard-mandatory.

**File 8 — `migrations/056_onboarding_registry.sql`**
- `CREATE TABLE IF NOT EXISTS onboarding_registry (` → `... public.onboarding_registry (`
- Three `CREATE INDEX IF NOT EXISTS ... ON onboarding_registry (...)` lines:
  not guard-checked, optional qualification only.

**File 9 — `migrations/094_entity_subsystem.sql`**
- `CREATE TABLE IF NOT EXISTS entity_definitions (` (inside the first `DO $$
  BEGIN ... EXCEPTION WHEN duplicate_table THEN NULL; END $$;` block, which
  also contains the `-- scope: public` comment two lines above it) →
  `... public.entity_definitions (`
- `CREATE TABLE IF NOT EXISTS entity_type_instances (` (second `DO $$` block)
  → `... public.entity_type_instances (`
- `CREATE TABLE IF NOT EXISTS entity_record_latest (` (third `DO $$` block)
  → `... public.entity_record_latest (`
- `INSERT INTO event_type_registry (name, schema_version, json_schema,
  description) VALUES (...) ON CONFLICT (name, schema_version) DO NOTHING;`
  → `INSERT INTO public.event_type_registry (...)`. `event_type_registry`
  itself is created in `002_event_type_registry.sql`, which carries **no**
  `-- scope: public` header (falls through `migrationScope()`'s default
  `.all_schemas` case) and is therefore unaffected by this fix — it is a
  pre-existing, differently-scoped file, out of scope here. Qualifying the
  `INSERT INTO` target in `094` to `public.event_type_registry` is required
  because `094` itself carries the `-- scope: public` header that trips the
  guard on this exact line.
- The five `CREATE INDEX IF NOT EXISTS ... ON entity_definitions /
  entity_record_latest (...)` lines: not guard-checked, optional
  qualification only.
- Because the guard scans the **entire file** (see "Guard semantics
  consulted" above), the `DO $$` block boundaries and the physical
  distance between the `-- scope: public` comment (line 22, inside block 1)
  and the `INSERT INTO event_type_registry` (line 102, ~80 lines later, well
  outside any `DO $$` block) do not exempt the INSERT from the guard. All
  four unqualified statements in this file must be fixed, not only the ones
  textually near the comment.

## Cross-file / FK reference check (acceptance criterion 2)

Searched all 9 files for `REFERENCES` (foreign-key clauses): **zero
matches**. None of the 9 files' new tables declare a `REFERENCES` clause
to any other table, so there is no intra-file or cross-file FK that also
needs `public.` qualification as a side effect of qualifying the primary
`CREATE TABLE` statements. The only cross-table reference found across all
9 files is File 5's `CREATE UNIQUE INDEX ... ON tenant (idp_realm_id)`,
already addressed above (out of scope: targets a table outside the 9, and
`CREATE INDEX` is not a guard-checked statement kind regardless).

## Error taxonomy

No new error variants. `MigrationError.MigrationScopeMismatch`
(pre-existing, `src/db/migrations.zig:56`) is the error this fix eliminates
for these 9 files on a fresh database; it remains defined and in use to
guard against any *future* recurrence of this same defect class in new
`-- scope: public` migrations.

## Data/backfill impact — none required

All 9 files are ledger-recorded as applied on every existing long-lived
`db_test`/`bpm_dev` database (recorded before a2a8c68 changed their
content), and every `CREATE TABLE` in them is already `CREATE TABLE IF NOT
EXISTS` — idempotent. The `INSERT INTO ... ON CONFLICT ... DO NOTHING`
statements in Files 4 and 9 are likewise idempotent. Editing the file
content in place changes nothing about already-applied databases (the
runner never re-executes a ledger-recorded file — see
`applied.contains(filename)` skip at migrations.zig:324-328); the edit only
changes what a **fresh** database receives when these files are applied
for the first time. No corrective/backfill migration file is needed or
should be created.

## Regression gate (acceptance criterion 3)

**No existing CI job migrates a genuinely fresh database.** Confirmed by
reading `.github/workflows/ci.yml` in full: it contains no `services:`
block anywhere (no Postgres/Keycloak service container is defined for any
job), so no job in this workflow can run `zig build migrate` against a
real, empty PostgreSQL instance at all. The only migration-related CI step
is `tools/lint_migration_schema.py` (the "Migration schema conventions"
step, `linters` job), which is a purely static/textual linter checking a
different property (that per-tenant business tables are never
`public.`-qualified) — it does not run any SQL and cannot have caught this
defect class, nor is it intended to. `tools/verify_test_env.py` (behind
`zig build test-env-verify`) checks infrastructure *health* of whatever
database is already configured; it does not provision a fresh one. This is
genuinely the second occurrence of "only exercised by a fresh database"
(ISS-0603/GH-467, ISS-0604/GH-470 built the runtime guard; this issue is
the guard firing for real for the first time) with **no automated gate
behind either occurrence** — both were caught by an agent manually
provisioning a throwaway database, not by CI.

**Design: add a new CI job, `fresh_database_migration`, to
`.github/workflows/ci.yml`.** Rationale for a new job rather than folding
into `build`: the `build` job (linked at ci.yml:129-303) is explicitly
scoped as "No database: integration tests need PostgreSQL and Keycloak,
which belong in a separate workflow rather than gating every PR" — adding
a Postgres service to it would contradict that documented boundary and
slow down every PR's fastest feedback job. A dedicated job keeps the
fast/no-DB and slow/DB-backed gates separated, consistent with how this
repo already isolates `clean_checkout_lua_build` from `build` for the same
kind of reason (testing a property the cached/shared-state job cannot).

Job shape:
```yaml
fresh_database_migration:
  name: Fresh-database migration bootstrap
  runs-on: ubuntu-latest
  timeout-minutes: 10
  services:
    postgres:
      image: postgres:15
      env:
        POSTGRES_USER: bpm
        POSTGRES_PASSWORD: bpm
        POSTGRES_DB: bpm_fresh_ci
      ports: ["5432:5432"]
      options: >-
        --health-cmd pg_isready
        --health-interval 5s
        --health-timeout 5s
        --health-retries 10
  steps:
    - uses: actions/checkout@v4
    - uses: mlugg/setup-zig@v2
      with: { version: 0.16.0 }
    - name: zig build migrate against a fresh, empty database
      env:
        BPM_DB_URL: postgres://bpm:bpm@localhost:5432/bpm_fresh_ci
      run: zig build migrate
```
This is the direct automation of the exact reproduction ORCH ran by hand
(`CREATE DATABASE bpm_fresh_check OWNER bpm; BPM_DB_URL=... zig build
migrate`, per `docs/issues/ISS-0630.json` `reproduction` field): a brand
new database that has never had any migration ledger row, so every
`-- scope: public` file's guard check is genuinely exercised on every PR,
not skipped by pre-existing ledger state the way the long-lived
`db_test` container skips it. The job is judged by `zig build migrate`'s
own exit code — no string-matching of its output — consistent with
`CLAUDE.md`'s "Never Satisfy a Gate by Editing What It Measures" and the
existing `test-env-verify` exit-code precedent.

This job addition is **not** part of the implementation scope of this
BACKEND-DEV step by default classification (it is a `.github/workflows/*`
change, not `src/`), but per WF-03 this design explicitly designates it as
required work for this run's acceptance criteria — BACKEND-DEV should add
it alongside the 9 SQL edits, since `ci.yml` is a plain YAML file requiring
no codegen and the job is fully specified above.

## Explicit scope exclusion (acceptance criterion 5)

This fix does **not** address the 35 residual `test-integration-svc`
failures noted in `docs/issue-reports/ISS-0150-gh482-20260809-diagnosis.yaml`
/ GH-482 / ISS-0150. Those failures are explicitly blocked on this fix
landing first (a trustworthy fresh-database measurement is only possible
once `zig build migrate` can complete against a fresh database at all) and
will be re-measured and addressed in a later, separate run. No file, test,
or diagnosis related to those 35 failures is touched by this design.

## Acceptance criteria mapping

1. All 9 files' unqualified `CREATE TABLE` / `INSERT INTO` statements
   qualified with `public.` — see per-file edit lists above.
2. `zig build migrate` against a genuinely fresh, empty database exits 0 —
   verified by BACKEND-DEV/TEST-RUNNER against a real throwaway database
   (e.g. `CREATE DATABASE bpm_fresh_check OWNER bpm;` as in the ISS-0630
   reproduction), not only the long-lived shared `db_test` container.
3. Regression gate: new `fresh_database_migration` CI job specified above.
4. No backfill/corrective migration — confirmed, edit-in-place only.
5. 35 residual `test-integration-svc` failures explicitly out of scope —
   confirmed above.
