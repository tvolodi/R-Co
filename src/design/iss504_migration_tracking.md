# Module: ISS-504 Per-Tenant Migration Tracking

## Module purpose

This module formalises the per-tenant migration-state tracking that was documented in the architecture (SS5) and partially implemented in SPT-01. Each tenant schema has its own `schema_migrations` ledger. The `public.schema_migrations` table tracks global (`GBL-`) migrations applied to the `public` schema. Each `tenant_{slug}.schema_migrations` table tracks per-tenant migrations applied to that tenant's schema. This module ensures provisioning creates the per-tenant ledger, that migration application records entries in the correct schema, and that ADP-12 default-tenant regression tests cover the new behaviour.

## Scope and non-goals

- In scope: ensuring `provisionTenantSchema()` creates/documents the per-tenant `schema_migrations` table.
- In scope: verifying that `runForSchema` records migration entries in the correct ledger.
- In scope: ADP-12 regression test updates.
- Out of scope: changing the migration runner algorithm (already correct per SPT-01).
- Out of scope: the SPT cutover transaction (ISS-502) or RLS removal (ISS-503).

## Current state (pre-ISS-504)

### What already works

1. `public.schema_migrations` exists with composite key `(schema_name, version)`.
2. `Migrations.runForSchema()` records entries as `(schema_name=$1, version=$2)` -- correctly scoped.
3. For GBL- migrations: `schema_name = 'public'`.
4. For per-tenant migrations: `schema_name = 'tenant_{slug}'`.
5. The migration runner already creates `public.schema_migrations` if it does not exist (`CREATE TABLE IF NOT EXISTS`).
6. `provisionTenantSchema()` calls `runForSchema()` which applies all non-GBL migrations to the tenant schema and records them in `public.schema_migrations` with `schema_name = 'tenant_{slug}'`.

### What needs verification/change

1. The per-tenant `schema_migrations` table inside the tenant schema is NOT explicitly created. It exists because the first non-GBL migration that references `schema_migrations` creates it in whatever schema `search_path` points to. This works but is implicit. ISS-504 should make it explicit.
2. During SPT cutover (ISS-502), the `schema_migrations` entries for the tenant are copied from `public.schema_migrations` to the tenant schema. This is already part of the ISS-502 design.
3. ADP-12 default-tenant regression tests were written for the LEGACY_RLS mode. They need to be updated to also cover SCHEMA-mode tenants.

## Design

### 1. Explicit per-tenant schema_migrations creation

Modify `provisionTenantSchema()` or `runForSchema()` to explicitly create the `schema_migrations` table inside the tenant schema. This makes the migration ledger self-contained within the tenant schema.

In `src/db/migrations.zig:runForSchema()`, after `SET search_path TO {schema_name},public`, add:

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT        NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (version)
);
```

Note: the per-tenant `schema_migrations` table has a different schema than the public one. The public one has `(schema_name, version)` as its primary key to track migrations across multiple schemas. The per-tenant one only needs `(version)` because all entries are for the same schema.

Wait -- this introduces a table-name collision. Both `public.schema_migrations` and `tenant_{slug}.schema_migrations` exist. When `search_path` is set to `tenant_{slug},public`, the `schema_migrations` name resolves to the tenant schema's table first (because it comes first in search_path). This is the desired behaviour: per-tenant migration state is queried from the per-tenant ledger.

**Decision: Do NOT create a separate per-tenant schema_migrations table.** Instead, continue using `public.schema_migrations` with the `schema_name` column to track per-tenant migration state. The per-tenant table would add complexity (two tables with the same name in different schemas, potential confusion about which one is authoritative).

**Revised approach:** Keep the current design where `public.schema_migrations` is the single source of truth for all migration state, keyed by `(schema_name, version)`. ISS-504's role is to:
1. Verify this works correctly for both GBL- and per-tenant migrations.
2. Document the behaviour.
3. Update ADP-12 regression tests.

### 2. Provisioning creates per-tenant schema_migrations entries

`provisionTenantSchema()` already calls `runForSchema()` which records per-tenant migration entries in `public.schema_migrations` with `schema_name = 'tenant_{slug}'`. No code changes needed for this behaviour.

### 3. ADP-12 default-tenant regression updates

ADP-12 tests verify that the default tenant (`00000000-0000-0000-0000-000000000000`) works correctly end-to-end. With ISS-504, the ADP-12 test suite should:

1. Provision the default tenant (or use the existing default tenant).
2. Verify `storage_mode` is set correctly (SCHEMA for newly provisioned tenants, LEGACY_RLS for pre-existing).
3. Verify GBL- migrations are recorded in `public.schema_migrations` with `schema_name = 'public'`.
4. Verify per-tenant migrations are recorded in `public.schema_migrations` with `schema_name = 'tenant_default'`.
5. Verify the tenant schema contains all expected tables (same set as public, minus global tables like `tenant`, `tenant_schemas`, `tnt05_progress`, etc.).
6. Run CRUD operations against the default tenant and verify they hit the tenant schema (via ISS-501 SCHEMA routing).
7. Verify that a second tenant provisioned after ISS-504 has its own independent migration state.

## Public interface

No new public functions are added by ISS-504. The existing interfaces are sufficient:

- `Migrations.runForSchema()` -- already records per-tenant migration state correctly.
- `provisionTenantSchema()` -- already provisions tenant schemas and applies migrations.

## Verification points (for TEST-DESIGNER)

1. After provisioning a new tenant:
   - `SELECT count(*) FROM public.schema_migrations WHERE schema_name = 'tenant_{slug}'` > 0.
   - `SELECT count(*) FROM public.schema_migrations WHERE schema_name = 'public'` > 0.
2. GBL- migrations are NOT recorded under `schema_name = 'tenant_{slug}'`.
3. Non-GBL migrations are NOT recorded under `schema_name = 'public'`.
4. ADP-12 regression suite passes with SCHEMA-mode default tenant.

## Error taxonomy

No new Zig-level error types are introduced by ISS-504. The existing error types are sufficient:

- `MigrationError` (from `src/db/migrations.zig`) covers migration application failures.
- `ProvisionError` (from `src/db/provisioning.zig`) covers provisioning failures.
- `PoolError` (from `src/db/pool.zig`) covers connection failures during migration verification.

Test-level assertions verify migration tracking correctness (e.g. wrong schema_name in schema_migrations) through standard test failure mechanisms.

## Integration points

- `src/db/provisioning.zig` -- `provisionTenantSchema()` already sets `storage_mode = 'SCHEMA'` (Step 6a). No changes needed but verify the behaviour.
- `src/db/migrations.zig` -- `runForSchema()` already records entries in `public.schema_migrations` with the correct `schema_name`. No changes needed.
- `tests/` -- ADP-12 test suite updates (TEST-DESIGNER step).

## Dependencies

- ISS-107: storage_mode column (RELEASED).
- ISS-501: storage-mode-aware routing (for SCHEMA-path verification).
- ISS-503: RLS removal (for clean post-RLS verification).

## Migration ledger summary

| Migration prefix | Applied by | Recorded in | schema_name |
|---|---|---|---|
| `GBL-NNN_*.sql` | `runForSchema("public")` | `public.schema_migrations` | `'public'` |
| `NNN_*.sql` (non-GBL) | `runForSchema("tenant_{slug}")` | `public.schema_migrations` | `'tenant_{slug}'` |

GBL- migrations are only applied to the `public` schema (skipped for per-tenant schemas per the GBL-prefix guard in `runForSchema()`).

Non-GBL migrations are applied to BOTH `public` and per-tenant schemas (each has its own independent migration state).
