# Fix Design: ISS-0126 — Schema-qualified bootstrap audit constraint introspection

## Module purpose

This Type E test-infrastructure fix corrects TC-OIDC-22-01 so that its PostgreSQL catalog query verifies the `BOOTSTRAP_REENABLED` check constraint on `public.agent_bootstrap_audit` only. The current query omits `pg_namespace`, while migration `042_oidc16_26_agent_lifecycle_foundations.sql` is not GBL-prefixed and is therefore applied independently to `public` and every `tenant_*` schema; each schema intentionally owns its own copy of the table and constraint, so the schema-agnostic query counts multiple valid constraints and returns `2` instead of the expected `1`.

## Classification

**Type E — test assertion logic.** This is an OIDC integration-test correction with system-catalog semantics and does not match the Type A–D CRUD, list-page, migration, or React Flow templates.

## Public interface

No public production interface changes.

The only existing test-infrastructure interface affected by the optional hygiene change is:

```zig
fn resetTestData(conn: *pg.Conn) !void
```

Its signature, visibility, callers, and behavior contract remain unchanged; only its internal transient-table cleanup list is extended.

## Data types

No data types, structs, unions, enums, database objects, or wire formats change.

## Root cause

TC-OIDC-22-01 joins `pg_constraint` to `pg_class` and filters only by the unqualified relation name `agent_bootstrap_audit`. PostgreSQL system catalogs span all schemas, and migration 042 is non-GBL-prefixed, so the migration runner applies it to `public` and to every `tenant_*` schema, including `tenant_default`; consequently, the same intentional check-constraint definition exists once per schema. Because the test query has no `pg_namespace` join and no `nspname = 'public'` predicate, it counts all matching schema-local constraints rather than the single public-schema constraint the test intends to verify.

## Required change #1 — schema-qualify TC-OIDC-22-01

**File:** `tests/integration/oidc16_26_agent_lifecycle_foundations_test.zig`

**Insertion point:** Inside the test block named `TC-OIDC-22-01: bootstrap state is singleton and bootstrap audit event types are enforced`, in the `constraint_result` SQL query around line 224.

Add a `pg_namespace` join through `pg_class.relnamespace`, then restrict the query to `public`. Keep the expected count at `1` because the assertion is specifically about the public-schema table.

### Before

```sql
SELECT COUNT(*)::text
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
WHERE t.relname = 'agent_bootstrap_audit'
  AND pg_get_constraintdef(c.oid) LIKE '%BOOTSTRAP_REENABLED%'
```

### After

```sql
SELECT COUNT(*)::text
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE t.relname = 'agent_bootstrap_audit'
  AND n.nspname = 'public'
  AND pg_get_constraintdef(c.oid) LIKE '%BOOTSTRAP_REENABLED%'
```

This change addresses the diagnosed root cause directly: it changes the assertion scope from every schema to the intended `public` schema. It does not modify database state or reinterpret the valid tenant-schema constraints as duplicates.

## Optional change #2 — reset hygiene

**File:** `tests/integration/helpers.zig`

**Insertion point:** In `resetTestData()`, within the existing sequence of `truncateTableBestEffort` calls; place the two bootstrap tables together in a logical or alphabetical position.

Add cleanup entries for:

- `agent_bootstrap_state`
- `agent_bootstrap_audit`

The implementer is to add one existing-helper invocation per table. This is independent test-isolation hygiene for tests that may later insert bootstrap lifecycle rows. It is **not** the remedy for TC-OIDC-22-01, because that test performs schema introspection and its failure is unrelated to table rows.

## Data flow

```text
Migration 042 (non-GBL)
    |
    +--> public.agent_bootstrap_audit --------+
    |                                         |
    +--> tenant_default.agent_bootstrap_audit +--> pg_constraint / pg_class / pg_namespace
    |                                         |                |
    +--> other tenant_*.agent_bootstrap_audit +                v
                                                       TC-OIDC-22-01 filters
                                                       n.nspname = 'public'
                                                                |
                                                                v
                                                       exactly one matching
                                                       public constraint
```

Optional reset hygiene follows a separate path:

```text
TestHarness.init()
    -> resetTestData(conn)
        -> best-effort cleanup of transient tables
        -> agent_bootstrap_state
        -> agent_bootstrap_audit
```

## Key invariants

1. TC-OIDC-22-01 verifies the constraint belonging to `public.agent_bootstrap_audit`, not identically named relations in tenant schemas.
2. Tenant-schema copies created by the per-schema migration process remain intact and are not classified as duplicate database objects.
3. The existing singleton definition remains unchanged: `agent_bootstrap_state.singleton_key` is already a primary key constrained to the value `global`.
4. No production source, migration, table definition, constraint, or runtime behavior changes.
5. `resetTestData()` continues to preserve migration, seed, and configuration tables while clearing transient integration-test data on a best-effort basis.
6. The implementation scope is limited to the two identified integration-test infrastructure files.

## State transitions

No application or database state-transition model changes. The optional cleanup entries only reset transient bootstrap test rows between harness initializations; they do not alter bootstrap lifecycle rules.

## Error taxonomy

Unchanged. No errors are added, removed, remapped, or propagated differently. The existing `resetTestData()` error behavior remains `!void`, with `truncateTableBestEffort` continuing to ignore missing-table `error.ServerError` conditions and propagate other failures.

## External dependencies

- PostgreSQL catalogs: `pg_constraint`, `pg_class`, and `pg_namespace`.
- Existing integration-test PostgreSQL connection through `helpers.TestHarness`.
- Existing `truncateTableBestEffort` helper for optional cleanup.
- Migration `042_oidc16_26_agent_lifecycle_foundations.sql` is read-only context and must not be modified.

The fix must not depend on production OIDC modules, alter migration-runner behavior, or introduce new libraries.

## Files impacted

| File | Change | Impact |
|---|---|---|
| `tests/integration/oidc16_26_agent_lifecycle_foundations_test.zig` | Mandatory `pg_namespace` join and `public` predicate in TC-OIDC-22-01 | Corrects schema scope of the failing catalog assertion |
| `tests/integration/helpers.zig` | Optional bootstrap state/audit cleanup entries in `resetTestData()` | Improves integration-test isolation independently of the failure |

**Callers impacted:** None. Both changes are localized to integration-test infrastructure, and no function signature changes.

## Migration plan

None. Do not add or modify a migration. Migration 042 correctly creates separate schema-local copies under the existing per-schema migration policy.

## Explicit non-goals and constraints

- Do not use truncation of `agent_bootstrap_state` as the TC-OIDC-22-01 fix; row state is irrelevant to this schema-introspection assertion.
- Do not add a migration.
- Do not strengthen or replace the singleton constraint; primary key plus `CHECK (singleton_key = 'global')` already enforces the intended invariant.
- Do not delete constraints from tenant schemas; each tenant schema intentionally owns its own copy.
- Do not modify more than the two listed test-infrastructure files.
- Do not modify production code.

## Risk assessment

**Minimal.** The mandatory change only narrows a test catalog query to its intended schema, and the optional change only expands best-effort test cleanup. Both are test-only changes with no production, migration, API, persistence-contract, or caller impact. The principal verification risk is an accidental OIDC integration-test regression caused by malformed Zig multiline SQL or cleanup ordering; the complete OIDC integration suite detects that risk.

## Verification plan

Run from PowerShell:

```powershell
cd C:\Users\tvolo\dev\ai-dala\R-Co
$env:BPM_TEST_DB_URL='postgres://bpm:bpm@localhost:5434/bpm_test'
zig build test-integration 2>&1 | Tee-Object -FilePath scratch/WF03-gh392-20260801/test-integration-verify.log
```

Pass criteria:

1. `zig build test-integration` exits `0`.
2. TC-OIDC-22-01 passes with exactly one matching public-schema constraint.
3. No OIDC integration test regresses.
4. The verification log is written only under `scratch/WF03-gh392-20260801/`.

## Open questions

None. The diagnosed schema scope, intended public-schema assertion, optional cleanup scope, and two-file maximum are explicit.
