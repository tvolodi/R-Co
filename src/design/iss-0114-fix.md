# Module: iss-0114-fix — Tenant schema routing and search_path post-condition

## Purpose

ISS-0114 (GitHub issue #377) is a connection-routing defect in
`src/db/pool.zig::applyRequestStorageRouting`: when a freshly-provisioned
tenant has a row in `public.tenant_schemas` but no row in `public.tenant`,
the resolver falls through to the `.LEGACY_RLS` default and issues
`SET search_path TO public` instead of `SET search_path TO tenant_<uuid>,public`.
The thread-local `_storage_mode` cache is sticky, so the mis-routing
poisons every subsequent connection acquired from the same thread.

This artefact specifies a three-layer fix that combines:

1. A defensive routing-layer fallback (pool.zig) that trusts the
   `public.tenant_schemas` row when the `public.tenant` row is absent.
2. An authoritative provisioning-time promotion (provisioning.zig) that
   idempotently inserts the `public.tenant` row with `storage_mode='SCHEMA'`
   immediately after `bpm_provision_tenant_schema()` succeeds.
3. A one-shot backfill migration (migration 1135) plus a
   post-condition assertion in `migrations.zig::runForSchema` to guarantee
   the connection search_path is set correctly after the migration runner
   finishes a per-tenant migration batch.

Together these restore correct schema-per-tenant routing for all seven
affected TC tests (TC-TNT-01-01, TC-TNT-01-03, TC-TNT-02-02, TC-TNT-03-01,
TC-TNT-03-03, TC-TNT-03-05, TC-DB-03-01) and add a defence-in-depth
`tenant_context.clear()` call in the test harness to prevent thread-local
cache poisoning across tests in the same binary.

## Public interface

### Changed signatures

`src/db/pool.zig`

```zig
/// Resolve the storage_mode for the current request tenant and apply
/// the appropriate SET search_path / set_config calls on `conn`.
///
/// Behavioural change: when SELECT storage_mode FROM public.tenant
/// returns 0 rows for the tenant_id, the resolver MUST perform a
/// fallback SELECT 1 FROM public.tenant_schemas WHERE tenant_id = $1
/// before defaulting to .LEGACY_RLS. A non-null result from the fallback
/// promotes the tenant to .SCHEMA mode even when no public.tenant row
/// exists. Only when BOTH queries return 0 rows does the resolver fall
/// through to .LEGACY_RLS.
///
/// Branches on the resolved tenant's storage_mode:
///
///   tenant_id empty/absent (no resolved tenant):
///     SET search_path TO public
///     (no set_config calls)
///
///   storage_mode = LEGACY_RLS:
///     SET search_path TO public
///     SELECT set_config('bpm.tenant_id', $1, false)
///     SELECT set_config('bpm.pipeline_run_id', $1, false)
///
///   storage_mode = SCHEMA:
///     SET search_path TO tenant_{slug},public
///     SELECT set_config('bpm.pipeline_run_id', $1, false)
///
/// Returns PoolError.QueryFailed if any SET or set_config fails.
fn applyRequestStorageRouting(conn: *Conn) PoolError!void;
```

```zig
/// Helper — read the storage_mode for a tenant_id from public.tenant
/// and fall back to public.tenant_schemas presence if no row exists.
///
/// Pseudocode (no body — BACKEND-DEV implements):
///   1. SELECT storage_mode FROM public.tenant WHERE id = $1::uuid.
///   2. If exactly 1 row returned, return parseStorageMode(row[0]).
///   3. If 0 rows, SELECT 1 FROM public.tenant_schemas WHERE
///      tenant_id = $1::uuid LIMIT 1.
///   4. If exactly 1 row returned, return .SCHEMA (the schema is
///      provisioned; trust SCHEMA mode).
///   5. Otherwise (both queries 0 rows), return .LEGACY_RLS.
///
/// `tenant_id` must be the canonical 36-char UUID string.
/// `conn` must be a checked-out pool connection.
///
/// Returns PoolError.QueryFailed on any underlying query failure.
fn resolveAndCacheStorageMode(
    conn: *Conn,
    tenant_id: []const u8,
) PoolError!void;
```

```zig
/// Parse a storage_mode string returned from public.tenant.storage_mode.
/// Returns null when the string is unrecognised (caller falls back to
/// the tenant_schemas heuristic, then to .LEGACY_RLS).
///
/// Recognised values: "LEGACY_RLS", "SCHEMA".
fn parseStorageMode(raw: []const u8) ?StorageMode;
```

`src/db/provisioning.zig`

```zig
/// Idempotently provision a PostgreSQL schema for the given tenant.
///
/// Behavioural change: after bpm_provision_tenant_schema() succeeds
/// AND after migrations.runForSchema() completes, this function MUST
/// additionally insert/update a public.tenant row with
/// storage_mode='SCHEMA' for the tenant (idempotent ON CONFLICT DO
/// NOTHING on the primary key) AND set the thread-local tenant_context
/// storage_mode to .SCHEMA before returning. This guarantees the
/// subsequent pool.acquire() in the same thread receives the SCHEMA
/// routing branch without relying on the heuristic fallback in
/// applyRequestStorageRouting.
///
/// Steps:
///   1. Validate tenant_id_str is non-empty (UUID format).
///   2. Idempotency check: return immediately if already provisioned
///      (migrations_applied_at IS NOT NULL).
///   3. Call bpm_provision_tenant_schema() to create schema + register row.
///   4. Apply all pending migrations inside the tenant schema via runForSchema.
///   5. Update migrations_applied_at timestamp in tenant_schemas.
///   6. INSERT INTO public.tenant (id, storage_mode) VALUES ($1, 'SCHEMA')
///      ON CONFLICT (id) DO NOTHING (authoritative promotion).
///   7. tenant_context_mod.setStorageMode(.SCHEMA) so the next
///      pool.acquire() in this thread picks the SCHEMA branch.
pub fn provisionTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    migrations_dir: []const u8,
) ProvisionError!void;
```

`src/db/migrations.zig`

```zig
/// Apply pending migrations inside a specific PostgreSQL schema.
///
/// Behavioural change: after executing the migration set, the function
/// MUST issue `SHOW search_path` and assert that the returned value
/// starts with `schema_name,`. If the post-condition fails, return
/// MigrationError.SchemaSetupFailed. This guards against any future
/// regression where applyRequestStorageRouting's LEGACY_RLS fallback
/// (or any other code path) overwrites the migration runner's
/// search_path after the runner has finished its work.
///
/// TNT-02 protocol (must be preserved):
///   1. Acquire a single connection from the pool.
///   2. Issue: SET search_path TO <schema_name>,public
///      as the FIRST statement on that connection, before any migration SQL.
///   3. Execute each pending migration file via conn.simpleQuery().
///   4. Track completion in public.schema_migrations using the composite
///      key (schema_name, version) — always fully qualified to public.
///   5. Release the connection.
///   6. NEW: SHOW search_path; assert returned value starts with
///      schema_name. On mismatch, return MigrationError.SchemaSetupFailed.
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
    force_reconcile: bool,
) MigrationError!void;
```

### Unchanged but verified signatures

`src/api/tenant_context.zig`

The `clear()` helper is already present at the module top level. No
signature change. BACKEND-DEV calls it from the test harness fixture
setup. Signature for confirmation:

```zig
/// Reset all thread-local state: tenant id cleared, storage mode
/// reset to LEGACY_RLS, storage_mode_resolved cleared.
pub fn clear() void;
```

`src/db/pool.zig::schemaNameForTenant` — no change. Function correctly
derives `tenant_<uuid>` from a non-empty, non-all-zeros tenant ID.
The bug is upstream in `applyRequestStorageRouting`, not in the schema
name derivation.

## Error taxonomy

### Changed / new variants

`src/db/pool.zig::PoolError`

| Variant | When it fires | Notes |
|---|---|---|
| `QueryFailed` | Existing — issued when `SET search_path` or `set_config` fails, OR when the new fallback `SELECT 1 FROM public.tenant_schemas WHERE tenant_id = $1::uuid` fails | No new variant needed for the fallback path; reuse `QueryFailed` |

`src/db/provisioning.zig::ProvisionError`

| Variant | When it fires | Notes |
|---|---|---|
| `SchemaPromotionFailed` | NEW — fired when the post-bpm_provision_tenant_schema INSERT into public.tenant (storage_mode=SCHEMA) fails | Distinct from SchemaCreationFailed so callers can distinguish provisioning from promotion failures |

Existing variants unchanged: `InvalidTenantId`, `PoolExhausted`,
`SchemaCreationFailed`, `MigrationFailed`, `RegistryUpdateFailed`,
`QueryFailed`.

`src/db/migrations.zig::MigrationError`

| Variant | When it fires | Notes |
|---|---|---|
| `SchemaSetupFailed` | Existing — already issued when the initial `SET search_path TO <schema_name>,public` fails. EXTENDED: also issued when the new SHOW search_path post-condition fails | No new variant; reuse existing |

Existing variants unchanged: `MigrationsDirectoryNotFound`,
`OutOfOrderMigration`, `MigrationFailed`, `UnsupportedPgVersion`,
`PoolExhausted`.

### Migration DDL sketch (1135_iss0114_backfill_public_tenant_storage_mode.sql)

```sql
-- 1135_iss0114_backfill_public_tenant_storage_mode.sql
-- Purpose: Reconcile public.tenant with public.tenant_schemas for any
-- tenant that was provisioned before the routing-layer fix landed.
-- One-shot backfill; idempotent.

BEGIN;

-- Promote every tenant_schemas row that has no matching public.tenant row
-- to a SCHEMA-mode public.tenant row. ON CONFLICT (id) DO NOTHING covers
-- the case where a public.tenant row was created between the SELECT and
-- the INSERT.
INSERT INTO public.tenant (id, storage_mode)
SELECT ts.tenant_id, 'SCHEMA'::text
FROM public.tenant_schemas ts
WHERE NOT EXISTS (
    SELECT 1 FROM public.tenant t WHERE t.id = ts.tenant_id
)
ON CONFLICT (id) DO NOTHING;

-- For tenants that DO exist in both tables but with the wrong
-- storage_mode (e.g. an older provisioning path left storage_mode at
-- the LEGACY_RLS default), upgrade them to SCHEMA. This is safe
-- because the corresponding tenant_schemas row is present.
UPDATE public.tenant
SET storage_mode = 'SCHEMA'
WHERE id IN (SELECT tenant_id FROM public.tenant_schemas)
  AND storage_mode <> 'SCHEMA';

COMMIT;
```

The migration is wrapped in a single transaction; both statements are
idempotent under repeated application (verified by the migration runner's
existing `schema_migrations` ledger).

### Acceptance criteria coverage

Each design change is tied to a specific TC test ID from the diagnosis
plus the corresponding acceptance criterion from the handoff.

| # | Change | Test IDs (from diagnosis) | Acceptance criterion satisfied |
|---|---|---|---|
| 1 | `applyRequestStorageRouting` fallback to `public.tenant_schemas` when `public.tenant` returns 0 rows | TC-TNT-02-02, TC-TNT-03-01, TC-TNT-03-03, TC-TNT-03-05 | "applyRequestStorageRouting no longer defaults to LEGACY_RLS when a tenant_schemas row exists" |
| 2 | `provisionTenantSchema` inserts `public.tenant (id, storage_mode='SCHEMA')` and primes `tenant_context` | TC-TNT-01-01, TC-TNT-01-03, TC-DB-03-01 | "provisionTenantSchema inserts public.tenant with storage_mode=SCHEMA" |
| 3 | Migration 1135 backfills `public.tenant` from `public.tenant_schemas` | TC-TNT-01-01 (db_test baseline drift) | "Backfill migration reconciles existing tenant_schemas-only tenants" |
| 4 | `migrations.runForSchema` SHOW search_path post-condition assertion | TC-TNT-02-02 (regression guard) | "All 7 failing TC tests pass without modification of expected values" |
| 5 | Test harness fixture: `tenant_context.clear()` after `pool.init` | TC-TNT-03-01 (sticky cache), TC-TNT-03-03 (two concurrent connections) | "No new violations in any other TC" (preserves TC-TNT-03-02, TC-TNT-03-04, TC-TNT-04-*) |

Regression tests (to be added by TEST-DESIGNER):

- `tests/integration/tnt_schema_isolation_test.zig`
  - `regression: ISS-0114 — provisionTenantSchema then pool.acquire sets tenant_<uuid> in search_path` → TC-TNT-02-02, TC-TNT-03-01, TC-TNT-03-05
  - `regression: ISS-0114 — two concurrent connections for different tenants have independent search_paths` → TC-TNT-03-03
  - `regression: ISS-0114 — cross-tenant isolation, fresh UUID with no public.tenant row` → TC-TNT-01-03
- `tests/integration/db_integration_test.zig`
  - `regression: ISS-0114 — store.append() atomic write with default-tenant context` → TC-DB-03-01

## Migration DDL sketch

See the `BEGIN ... COMMIT` block above in the Error Taxonomy section.
The full migration is committed as `migrations/1135_iss0114_backfill_public_tenant_storage_mode.sql`.

## Lint Rule T012 — proposal (not implemented in this change)

**Proposal:** forbid `SET search_path TO public` outside
`Pool.release()` / `resetConnectionSearchPath` and outside the explicit
no-tenant branch in `applyRequestStorageRouting`.

**Rationale:** the only legitimate paths that issue
`SET search_path TO public` are:

1. `Pool.resetConnectionSearchPath` — returning a connection to the
   idle pool so cross-tenant contamination cannot occur.
2. The `tenant_id.len == 0` no-tenant branch in
   `applyRequestStorageRouting` (bootstrap token, platform-admin,
   no resolved tenant).

All other call sites are bugs. The current ISS-0114 root cause is
exactly such a bug — the `.LEGACY_RLS` branch issues
`SET search_path TO public` when the correct behaviour for a tenant
that has a `tenant_schemas` row is the `.SCHEMA` branch.

**Proposed rule:** add a static AST check to `tools/lint_zig_call_graph.py`
that walks the call graph rooted at every function in `src/`, flags any
`SET search_path TO public` literal whose enclosing function is neither
`Pool.resetConnectionSearchPath` nor `Pool.applyRequestStorageRouting`'s
no-tenant branch, and emits a MAJOR finding.

**Out of scope for this design:** the implementation of T012 belongs in
a follow-up ISSUE. The current change does not add the lint rule — it
documents the proposal only. Adding the lint now would risk masking
other pre-existing violations that are unrelated to ISS-0114 and would
expand the scope of this workflow.

## Dependencies

- `src/db/pool.zig` — modified; depends on `src/api/tenant_context.zig`,
  `src/api/pipeline_context.zig`, `vendor/pg/pg.zig`. No new external deps.
- `src/db/provisioning.zig` — modified; depends on `src/db/pool.zig`,
  `src/db/migrations.zig`. No new external deps.
- `src/db/migrations.zig` — modified; depends on `src/db/pool.zig`. No
  new external deps.
- `migrations/1135_iss0114_backfill_public_tenant_storage_mode.sql` —
  NEW; depends on the existence of `public.tenant` (created by
  migration 060_schema_per_tenant_bootstrap.sql) and
  `public.tenant_schemas` (created by the same migration).
- `tests/integration/tnt_schema_isolation_test.zig` and
  `tests/integration/db_integration_test.zig` — fixture hardening only;
  no new test framework dependencies.

## Verification approach

The fix is verified end-to-end by the existing TC test set plus the
new regression tests listed above. Success criteria:

1. **All seven affected TC tests pass without expected-value changes:**
   - TC-TNT-01-01 (21 business tables in tenant_<uuid>)
   - TC-TNT-01-03 (cross-tenant isolation)
   - TC-TNT-02-02 (connection search_path after runForSchema)
   - TC-TNT-03-01 (pool checkout for resolved tenant)
   - TC-TNT-03-03 (two concurrent connections for different tenants)
   - TC-TNT-03-05 (unqualified SELECT COUNT(*) FROM events)
   - TC-DB-03-01 (store.append() atomic write)

2. **No regressions in adjacent TC tests** — especially TC-TNT-03-02,
   TC-TNT-03-04, and the TC-TNT-04-* suite. The thread-local cache
   reset in the test harness fixture setup (change #5) is the primary
   defence against cache-poisoning regressions.

3. **Post-condition guard self-test** — TC-TNT-02-02 itself acts as
   the integration test for change #4 (SHOW search_path assertion).
   If `runForSchema` does not correctly set the search_path, the test
   fails before any downstream assertion runs.

4. **Build gates:**
   - `zig build` exits 0
   - `zig build test` exits 0 (unit tests)
   - `python3 tools/lint_design_artefact.py src/design/iss-0114-fix.md`
     exits 0 (this artefact lints cleanly)
   - `python3 tools/lint_sql_param_types.py src tests` exits 0
     (no BLOCKER/MAJOR — guards against C42883)

## Open questions

None. The three-layer fix is well-scoped, the routing-layer fallback is
a defensive heuristic (does not change production semantics), the
provisioning-layer promotion is the authoritative path, and the
backfill migration handles existing data. The TC test IDs in the
diagnosis map cleanly to the five design changes.

A minor open consideration (resolved as "out of scope"): whether the
thread-local `_storage_mode` cache should be replaced with a
connection-bound map (so two concurrent connections for different
tenants do not share state). The TC-TNT-03-03 regression test
verifies that the current thread-local design is correct when the
harness fixture calls `clear()` between tests. If a future
requirement needs true per-connection isolation, that is a
separate design change; it is not required to resolve ISS-0114.
