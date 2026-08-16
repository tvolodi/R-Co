# Test Spec: SPT-02 — Data migration: copy rows into tenant schemas and remove RLS

**Requirement:** SPT-02 — The platform MUST migrate all existing tenant data from the `public` schema into per-tenant schemas. For every distinct `tenant_id` present in the system, the platform MUST call `bpm_provision_tenant_schema()` to create the schema if it does not already exist, copy all rows belonging to that tenant from every table in `public` into the corresponding table in the tenant schema, and then drop the `tenant_id` columns, the `bpm_effective_tenant_id()` function, all RLS policies, and all tenant-scoped composite indexes from the `public` schema tables. The migration MUST be atomic per tenant (all tables for one tenant in a single transaction).
**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `BPM_TEST_DB_URL`)
**Implementation:** `tests/integration/spt02_03_04_schema_tenant_migration_test.zig`
**Design authority:** `src/design/spt-02-03-04-schema-per-tenant-migration.md` §5–§7, §15 (SPT-02 trace)

> **Scope notes (authoritative — OQ-2 / validator ruling):** the requirement's literal table list
> (`process_definitions`, `process_instances`, `tenant_hostnames`, `sessions`) does not match the
> live schema (`process_instances` does not exist; `sessions` has no `tenant_id`;
> `tenant_hostnames` is a Class-G registry table). The design's Class-B reconciliation (§4) is
> authoritative. These tests verify the *post-migration end state* of migrations 061/062/063 on a
> live `bpm_test` database, plus direct re-execution of the migration SQL text for idempotency and
> the 062 pre-flight gate — mirroring the `test_iss503_rls_removal.zig` precedent.

## Test Cases

| TC ID | Name | Acceptance Criterion |
|---|---|---|
| TC-SPT-02-01 | N distinct tenant IDs → N `tenant_schemas` rows and N schemas | SPT-02 AC1 |
| TC-SPT-02-02 | Each tenant schema table holds exactly that tenant's rows (no cross-tenant contamination) | SPT-02 AC2 |
| TC-SPT-02-03 | After 062: no `tenant_id` column, no `bpm_effective_tenant_id()`, no RLS, no composite indexes in `public` (Class G exempt) | SPT-02 AC3 |
| TC-SPT-02-04 | 063 re-issues `DROP POLICY IF EXISTS` for every known policy (belt-and-suspenders) | SPT-02 AC4 |
| TC-SPT-02-05 | Re-running 061/062/063 raises no error and leaves state unchanged (idempotency) | SPT-02 AC5 |
| TC-SPT-02-06 | Interrupted copy detected via `public.tenant_schemas.data_migrated_at IS NULL`; 062 pre-flight gates | SPT-02 AC6 |

### TC-SPT-02-01: N distinct tenant IDs → N `tenant_schemas` rows and N schemas

**Given:** Migration 061 has run against `bpm_test` (every `tenant_schemas` row carries `data_migrated_at`).
**When:** `public.tenant_schemas` is queried and each row's schema is resolved via `schemaNameForTenant`.
**Then:** Every `tenant_schemas` row has `data_migrated_at IS NOT NULL`, and every referenced schema exists in `information_schema.schemata` (N rows → N schemas).
**Layer:** integration
**Acceptance criterion mapped:** SPT-02 AC1 — N distinct tenant IDs → N `tenant_schemas` rows and N schemas.

### TC-SPT-02-02: Each tenant schema table holds exactly that tenant's rows (no cross-tenant contamination)

**Given:** Two per-test schemas A and B are provisioned via `provisionTestTenantSchema()`; N rows are inserted into a Class-B table in schema A (via schema `search_path` routing).
**When:** The same table is queried in schema B and in schema A.
**Then:** Schema A sees exactly the N rows it was given; schema B sees zero of them (no cross-tenant contamination / no data loss).
**Layer:** integration
**Acceptance criterion mapped:** SPT-02 AC2 — each tenant schema table contains exactly the rows that belonged to that tenant; no data loss, no cross-tenant contamination.

### TC-SPT-02-03: After 062: no `tenant_id` column, no `bpm_effective_tenant_id()`, no RLS, no composite indexes in `public`

**Given:** Migration 062 has run (its pre-flight gate passed).
**When:** `information_schema.columns`, `pg_proc`, `pg_policies`, and `pg_indexes`/`pg_attribute` are queried against the `public` schema.
**Then:** (a) every public table still carrying a `tenant_id` column is in the Class-G allow-list; (b) `public.bpm_effective_tenant_id()` is absent from `pg_proc`; (c) `pg_policies` has zero rows for `schemaname = 'public'`; (d) no public index references a `tenant_id` column on a Class-B table.
**Layer:** integration
**Acceptance criterion mapped:** SPT-02 AC3 — 062 leaves no `tenant_id` column, no function, no RLS, no composite indexes in `public`.

### TC-SPT-02-04: 063 re-issues `DROP POLICY IF EXISTS` for every known policy

**Given:** Migration 062 has run (no policies remain on `public`).
**When:** Migration 063's raw SQL text is executed directly on a test connection (belt-and-suspenders re-check).
**Then:** Execution succeeds (exit 0, no exception) and `pg_policies` still has zero rows for `schemaname = 'public'`.
**Layer:** integration
**Acceptance criterion mapped:** SPT-02 AC4 — `DROP POLICY IF EXISTS` is executed for every previously-known policy on every affected table.

### TC-SPT-02-05: Re-running 061/062/063 raises no error and leaves state unchanged

**Given:** Migrations 061/062/063 have already been applied to `bpm_test`.
**When:** The raw SQL text of all three migration files is executed in sequence inside a controlled transaction (`simpleQuery`).
**Then:** Every statement succeeds (no error raised), and the end-state invariants are unchanged: `data_migrated_at` still set for all `tenant_schemas` rows, no public RLS policies, no Class-B `tenant_id` column in `public`.
**Layer:** integration
**Acceptance criterion mapped:** SPT-02 AC5 — full idempotency on re-run; no error and unchanged state.

### TC-SPT-02-06: Interrupted copy detected via `public.tenant_schemas.data_migrated_at IS NULL`; 062 pre-flight gates

**Given:** A per-test synthetic `tenant_schemas` row is inserted with `data_migrated_at IS NULL` (simulating a tenant whose copy was interrupted mid-way).
**When:** Migration 062's raw SQL text is executed inside a controlled transaction.
**Then:** Execution fails with a server error (the 062 pre-flight `RAISE EXCEPTION` aborts the migration) — proving the partially-migrated tenant is detected via the `tenant_schemas` row; the transaction is rolled back so nothing persists, and a subsequent re-attempt (with the marker set) proceeds cleanly without duplicating rows.
**Layer:** integration
**Acceptance criterion mapped:** SPT-02 AC6 — interrupted copy detected via `public.tenant_schemas` row; clean retry without duplicating rows.
