# Test Spec: SPT-02 — Data Migration: Copy Rows into Tenant Schemas and Remove RLS

**Requirement:** SPT-02 — Data migration: copy rows into tenant schemas and remove RLS
infrastructure.  
**Design artefact:** `src/design/spt-02.md`  
**Test file:** `tests/integration/spt02_data_migration_test.zig`  
**Requirement severity:** MUST

---

## Context

Migrations 061, 062, and 063 are applied to the test database by `TestHarness.init()` before
any test block runs. The tests therefore operate against the **post-migration state**:

- `public.*` tables **do not** have a `tenant_id` column (dropped by migration 062).
- The `bpm_effective_tenant_id()` function **does not** exist (dropped by migration 062).
- All six known tenant RLS policies **are absent** (dropped by migrations 062 and 063).
- `public.tenant_schemas` **has** a `status TEXT NOT NULL DEFAULT 'pending'` column (added by
  migration 061).

Migration 061's DO block cannot be re-executed in isolation after migration 062 (because it
performs `SELECT tenant_id FROM public.<table>` which would fail on column-dropped tables).
AC-1 and AC-6 therefore test the *provisioning mechanism* and *state-machine semantics* that
migration 061 relies on, rather than re-running the DO block itself.

All tests use `TestHarness.init()` which begins an open transaction. `h.deinit()` always
rolls back, providing automatic schema cleanup with no leakage between tests.

---

## Test Case Summary

| ID | Title | Layer | Pass Condition |
|---|---|---|---|
| TC-SPT-02-01 | N tenants provisioned → N rows in tenant_schemas + N schemas in pg_namespace | integration | 2 UUIDs provisioned: 2 tenant_schemas rows, 2 schemas in information_schema.schemata |
| TC-SPT-02-02 | Per-tenant data isolation — no cross-tenant contamination | integration | Row inserted in schema A is absent in schema B's table |
| TC-SPT-02-03 | Migration 062 structural verification | integration | 0 tenant_id columns, 0 bpm_effective_tenant_id() function, 0 RLS policies, 0 tenant_id composite indexes on public tables |
| TC-SPT-02-04 | Migration 063 re-run is a no-op | integration | All 6 DROP POLICY IF EXISTS statements execute without error; 0 policies remain |
| TC-SPT-02-05 | Full idempotency of migrations 062 + 063 | integration | All IF EXISTS-guarded DDL executes without error; structural state is unchanged (0 tenant_id columns, 0 policies) |
| TC-SPT-02-06 | Interrupted copy state machine via status column | integration | Initial status='pending', re-provisioning is idempotent (1 row, no duplicate), status transitions to 'active', active guard produces count=1 |

---

## Test Cases (Detail)

### TC-SPT-02-01: N tenants provisioned produce N rows in tenant_schemas and N schemas in pg_namespace

**Acceptance criterion:** AC-1 — GIVEN N distinct tenant IDs, WHEN migration 061 is applied,
THEN `public.tenant_schemas` has N rows and N schemas exist in the database.

**Test strategy:** Call `bpm_provision_tenant_schema($uuid)` for 2 fresh test UUIDs on
`h.conn` (inside TestHarness transaction). Verify both are in `public.tenant_schemas` and
both schemas appear in `information_schema.schemata`. Rollback on `h.deinit()` removes both.

**Expected:**
- `SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $uuid_a` → 1
- `SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $uuid_b` → 1
- `SELECT count(*) FROM information_schema.schemata WHERE schema_name = $schema_a` → 1
- `SELECT count(*) FROM information_schema.schemata WHERE schema_name = $schema_b` → 1

---

### TC-SPT-02-02: Tenant schema data is isolated — rows in schema A do not appear in schema B

**Acceptance criterion:** AC-2 — GIVEN any tenant schema after migration 061, WHEN tables are
queried, THEN each table contains only data belonging to that tenant (no cross-tenant
contamination).

**Test strategy:** Provision 2 test schemas via `bpm_provision_tenant_schema()`. Create a
test table `spt02_isolation_check` in both schemas. Insert 1 row into schema A only. Verify
schema A has 1 row and schema B has 0 rows. Rollback via `h.deinit()` drops tables and schemas.

Schema names are UUID-derived (`tenant_<32hex>`) — safe to embed in DDL.

**Expected:**
- `SELECT count(*) FROM <schema_a>.spt02_isolation_check` → 1
- `SELECT count(*) FROM <schema_b>.spt02_isolation_check` → 0

---

### TC-SPT-02-03: Migration 062 removed tenant_id columns, bpm_effective_tenant_id function, and RLS policies

**Acceptance criterion:** AC-3 — GIVEN migration 062 was applied, THEN public tables have no
`tenant_id` column, `bpm_effective_tenant_id()` does not exist, all RLS policies are dropped,
and all tenant_id-based composite indexes are absent.

**Test strategy:** Query information_schema, pg_proc, pg_policies, pg_class, and pg_indexes
for the affected objects. All counts must be 0.

**Checks:**
1. `SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND column_name='tenant_id' AND table_name IN (affected tables)` → 0
2. `SELECT count(*) FROM pg_proc p JOIN pg_namespace n ... WHERE proname='bpm_effective_tenant_id'` → 0
3. `SELECT count(*) FROM pg_policies WHERE policyname IN (6 known policy names)` → 0
4. `SELECT count(*) FROM pg_class c ... WHERE relrowsecurity=true AND relname IN (affected tables)` → 0
5. `SELECT count(*) FROM pg_indexes WHERE indexname IN (representative tenant_id composite indexes)` → 0

---

### TC-SPT-02-04: Migration 063 DROP POLICY IF EXISTS statements execute without error when policies are already absent

**Acceptance criterion:** AC-4 — GIVEN migration 062 completed, WHEN migration 063 is applied,
THEN `DROP POLICY IF EXISTS` executes for all 6 known policies without error.

**Test strategy:** Re-execute all 6 `DROP POLICY IF EXISTS` statements from migration 063 on
`h.conn`. If no error is raised, the test passes. Post-verify: 0 known policies remain.

**Statements:**
- `DROP POLICY IF EXISTS process_definitions_tenant_policy ON public.process_definitions`
- `DROP POLICY IF EXISTS instance_projections_tenant_policy ON public.instance_projections`
- `DROP POLICY IF EXISTS tasks_tenant_policy ON public.tasks`
- `DROP POLICY IF EXISTS tokens_tenant_policy ON public.tokens`
- `DROP POLICY IF EXISTS audit_entries_tenant_policy ON public.audit_entries`
- `DROP POLICY IF EXISTS audit_log_tenant_policy ON public.audit_log`

---

### TC-SPT-02-05: Re-running migrations 062 and 063 DDL statements raises no error and leaves state unchanged

**Acceptance criterion:** AC-5 — GIVEN a re-run of migrations 061–063 on an already-applied
database, THEN no error is raised and the database state is unchanged.

**Test strategy:** Execute all `DROP POLICY IF EXISTS`, `DROP INDEX IF EXISTS`, `DROP FUNCTION
IF EXISTS`, and `ALTER TABLE ... DROP COLUMN IF EXISTS` statements from migrations 062 and 063
on `h.conn`. These are all guarded with `IF EXISTS` and are no-ops. Post-verify that 0
`tenant_id` columns remain on affected tables.

---

### TC-SPT-02-06: Interrupted copy state machine enables idempotent retry without row duplication

**Acceptance criterion:** AC-6 — GIVEN the migration is interrupted mid-copy, WHEN the runner
retries, THEN the partially-migrated tenant's data is detected via `public.tenant_schemas.status`
and retry proceeds without duplicating rows.

**Test strategy:**
1. Provision a test tenant via `bpm_provision_tenant_schema()`. Verify initial status = 'pending'
   (represents pre-copy state; DEFAULT from migration 061's ALTER TABLE ADD COLUMN).
2. Verify "pending" guard: `SELECT count(*) FROM public.tenant_schemas WHERE tenant_id=$1 AND
   status='active'` → 0 (tenant would NOT be skipped by migration 061's CONTINUE WHEN check).
3. Re-provision the same UUID. Verify ON CONFLICT DO NOTHING: exactly 1 row remains in
   `public.tenant_schemas` (no duplicate). Verify exactly 1 schema in pg_namespace.
4. Update status to 'active' (simulate migration copy completion).
5. Verify "active" guard: same query → 1 (tenant WOULD be skipped on re-run; no duplicate copy).
6. Re-provision once more. Verify still exactly 1 row and 1 schema.

---

## Fixture Rules

- **Per-test UUIDs:** Every test generates a fresh UUID via `randomUuidStr()` (Zig 0.16 secure
  random via `std.testing.io.random`).
- **Cleanup:** `TestHarness.deinit()` rolls back the open transaction, automatically removing
  all provisioned schemas, `tenant_schemas` rows, and test tables. No explicit cleanup required.
- **No `error.SkipZigTest`:** None of the 6 test blocks may use `error.SkipZigTest`.
- **BPM_TEST_DB_URL:** `TestHarness.init()` fails with `error.MissingTestDatabaseUrl` if the
  env var is absent — no silent skip.

---

## Traceability

| Test case | Requirement AC | Migration tested |
|---|---|---|
| TC-SPT-02-01 | AC-1 | 060 (bpm_provision_tenant_schema) + 061 (status column) |
| TC-SPT-02-02 | AC-2 | Post-migration isolation via schema-per-tenant |
| TC-SPT-02-03 | AC-3 | 062 (DROP COLUMN / DROP FUNCTION / DROP POLICY / DROP INDEX) |
| TC-SPT-02-04 | AC-4 | 063 (DROP POLICY IF EXISTS belt-and-suspenders) |
| TC-SPT-02-05 | AC-5 | 062 + 063 (full idempotency) |
| TC-SPT-02-06 | AC-6 | 061 (status column state machine + ON CONFLICT DO NOTHING) |
