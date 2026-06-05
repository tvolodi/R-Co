# Module: spt-01-schema-per-tenant-provisioning

**Requirement ID:** SPT-01  
**Run ID:** WF02-spt-01  
**Stage:** Schema-Per-Tenant Migration — Provisioning Infrastructure Layer  
**Scope:** New infrastructure only. Data migration and tenant_id column removal are NOT in scope for SPT-01. Those are addressed in later runs (SPT-02 and SPT-03 respectively).

---

## 1. Overview

The BPM Platform currently isolates tenant data using `tenant_id UUID NOT NULL` columns on every table, combined with RLS policies enforced via `bpm_effective_tenant_id()` reading the `bpm.tenant_id` session setting. The architectural target is **schema-per-tenant**: each tenant gets its own PostgreSQL schema, providing stronger isolation, simpler queries, and the ability to evolve tenant schemas independently.

SPT-01 lays the infrastructure foundation:

- Establishes the schema naming convention.
- Introduces `public.tenant_schemas` as a registry of provisioned tenant schemas.
- Adds `bpm_provision_tenant_schema(p_tenant_id UUID)` — a PL/pgSQL function that creates the schema and registers it idempotently.
- Extends `src/db/migrations.zig` with `runForSchema` to apply migrations inside a named schema.
- Extends `src/db/pool.zig` to derive the schema name from the request tenant ID and set `search_path` on every connection checkout (in addition to the existing `set_config` call, which must remain for backward compatibility during this transition).
- Introduces `src/db/provisioning.zig` — the Zig-side orchestrator that drives schema creation and migration application as an idempotent unit.
- Adds SQL migration `060_schema_per_tenant_bootstrap.sql` with all required DDL.

---

## 2. Schema Naming Convention

### Rule

A tenant's schema name is derived deterministically from its UUID:

```
schema_name = "tenant_" + replace(tenant_id::text, "-", "")
```

Example: UUID `550e8400-e29b-41d4-a716-446655440000` → schema name `tenant_550e8400e29b41d4a716446655440000`.

### Special Cases

| Input | Resulting Schema Name |
|---|---|
| UUID `00000000-0000-0000-0000-000000000000` (the default/system tenant) | `tenant_default` |
| Empty string `""` (no tenant on the request, treated as system/default) | `tenant_default` |
| Any other valid UUID | `tenant_` + 32 hex characters (hyphens stripped) |

The string `tenant_default` is a reserved schema name. No UUID other than the all-zeros UUID may map to it.

### Rationale

- Stripping hyphens avoids quoting requirements in SQL identifiers; the result is a valid unquoted PostgreSQL identifier.
- The default UUID → `tenant_default` convention provides a human-readable label for the system tenant and matches the existing `tenant_id = '00000000-...'` convention already in the codebase.
- Schema names are UUID-derived (not user-supplied), so they are safe to interpolate into `SET search_path` statements (see §5 — Safety Note).

---

## 3. SQL Migration: 060_schema_per_tenant_bootstrap.sql

### 3.1 Full DDL Specification

This migration is idempotent throughout (all `CREATE ... IF NOT EXISTS`, `ALTER ... IF NOT EXISTS`, `DROP ... IF EXISTS` patterns).

**Table: public.tenant_schemas**

```sql
CREATE TABLE IF NOT EXISTS public.tenant_schemas (
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID        NOT NULL,
    schema_name          TEXT        NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    migrations_applied_at TIMESTAMPTZ,
    CONSTRAINT uq_tenant_schemas_tenant_id  UNIQUE (tenant_id),
    CONSTRAINT uq_tenant_schemas_schema_name UNIQUE (schema_name)
);

CREATE INDEX IF NOT EXISTS idx_tenant_schemas_tenant_id
    ON public.tenant_schemas (tenant_id);
```

**Alter: public.schema_migrations**

The existing `schema_migrations` table (bootstrap-created by `migrations.zig`) currently has `version TEXT PRIMARY KEY`. SPT-01 adds a `schema_name` column so that the same migration file version can be independently tracked per tenant schema.

```sql
ALTER TABLE public.schema_migrations
    ADD COLUMN IF NOT EXISTS schema_name TEXT NOT NULL DEFAULT 'public';
```

After adding the column, the existing `PRIMARY KEY (version)` uniqueness constraint must be replaced with a composite key:

```sql
-- Drop old primary key or unique constraint on version alone (if it exists).
-- Idempotent: no-op if the named constraint does not exist.
ALTER TABLE public.schema_migrations
    DROP CONSTRAINT IF EXISTS schema_migrations_pkey;

ALTER TABLE public.schema_migrations
    DROP CONSTRAINT IF EXISTS schema_migrations_version_key;

-- Add new composite primary key.
-- Because we cannot conditionally add a primary key, guard with a DO block.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = 'public'
          AND table_name   = 'schema_migrations'
          AND constraint_type = 'PRIMARY KEY'
    ) THEN
        ALTER TABLE public.schema_migrations
            ADD PRIMARY KEY (schema_name, version);
    END IF;
END;
$$;
```

**Function: public.bpm_provision_tenant_schema**

```sql
CREATE OR REPLACE FUNCTION public.bpm_provision_tenant_schema(
    p_tenant_id UUID
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema_name TEXT;
BEGIN
    -- Derive schema name from UUID.
    IF p_tenant_id = '00000000-0000-0000-0000-000000000000'::UUID THEN
        v_schema_name := 'tenant_default';
    ELSE
        v_schema_name := 'tenant_' || replace(p_tenant_id::text, '-', '');
    END IF;

    -- Serialise concurrent provisioning attempts for the same schema.
    PERFORM pg_advisory_xact_lock(hashtext(v_schema_name));

    -- Create schema idempotently.
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema_name);

    -- Register in tenant_schemas; silently skip if already present.
    INSERT INTO public.tenant_schemas (tenant_id, schema_name)
    VALUES (p_tenant_id, v_schema_name)
    ON CONFLICT DO NOTHING;
END;
$$;
```

**Note on migration runner invocation:** `bpm_provision_tenant_schema` intentionally does NOT call the migration runner. Applying schema-scoped migrations requires a Zig-managed connection with `search_path` set, and the migration runner is written in Zig (not SQL). The caller (`provisioning.zig`) is responsible for calling `migrations.runForSchema` after this function returns.

---

## 4. PL/pgSQL Function Design — bpm_provision_tenant_schema

### Purpose

Atomically create the tenant's PostgreSQL schema and register it in `public.tenant_schemas`, with concurrency protection via an advisory transaction lock.

### Concurrency Safety

`pg_advisory_xact_lock(hashtext(v_schema_name))` acquires an exclusive session-level advisory lock that is automatically released at transaction end. Two concurrent calls for the same schema will serialize: the second will find `CREATE SCHEMA IF NOT EXISTS` a no-op and `INSERT ... ON CONFLICT DO NOTHING` a no-op, then return cleanly.

### Idempotency

- `CREATE SCHEMA IF NOT EXISTS` is a PostgreSQL built-in no-op when the schema already exists.
- `INSERT INTO public.tenant_schemas ... ON CONFLICT DO NOTHING` is a no-op when the `tenant_id` unique constraint fires.

The function is therefore fully idempotent and safe to call multiple times for the same tenant.

### What the Function Does NOT Do

- It does not apply migrations to the new schema (Zig does that via `runForSchema`).
- It does not create any tables inside the tenant schema.
- It does not set `search_path` for the caller's connection.
- It does not modify `migrations_applied_at` (that is updated by `provisionTenantSchema` in Zig after `runForSchema` completes).

---

## 5. Migration Runner Extension — src/db/migrations.zig

### New Public Function

```zig
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
) MigrationError!void
```

### Behaviour

1. Acquire a connection from `pool`. Return `MigrationError.PoolExhausted` if none available.
2. Verify PostgreSQL >= 15; return `MigrationError.UnsupportedPgVersion` otherwise.
3. Execute `SET search_path TO <schema_name>, public` on the acquired connection before touching any migration files. The `schema_name` value is UUID-derived (safe to interpolate — see Safety Note below).
4. Ensure `public.schema_migrations` exists (same idempotent `CREATE TABLE IF NOT EXISTS` as today's `run()`).
5. Open `migrations_dir`, collect `*.sql` files, sort lexicographically (identical algorithm to existing `run()`).
6. Query `public.schema_migrations WHERE schema_name = $1` to determine which versions have already been applied for this specific schema.
7. For each pending migration in sorted order:
   - Out-of-order check: if a higher-numbered version is already recorded for this `schema_name`, return `MigrationError.OutOfOrderMigration`.
   - `BEGIN`; execute SQL file content; `INSERT INTO public.schema_migrations (schema_name, version) VALUES ($1, $2)`; `COMMIT`. On any error: `ROLLBACK`; return `MigrationError.MigrationFailed`.
8. Release the connection on return (defer).

### Safety Note on schema_name Interpolation

`schema_name` is always derived from a UUID (via `schemaNameForTenant`) or is the literal string `"public"`. It is never taken from user-supplied HTTP request data. The resulting string matches the pattern `^tenant_[0-9a-f]{32}$` or is exactly `"tenant_default"` or `"public"`. Interpolating it into `SET search_path TO <schema_name>, public` is therefore safe — it cannot contain SQL metacharacters.

### Updated run() Function

The existing `Migrations.run(allocator, pool, migrations_dir)` function continues working unchanged from the caller's perspective. Its implementation should be re-expressed as a thin wrapper:

```zig
pub fn run(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
) MigrationError!void {
    return runForSchema(allocator, pool, migrations_dir, "public");
}
```

This preserves full backward compatibility: all existing callers of `Migrations.run()` continue working without modification.

### Extended Error Set

The existing `MigrationError` error set does not require new variants for SPT-01. The full set after this change:

```zig
pub const MigrationError = error{
    /// migrations_dir path does not exist or is not readable.
    MigrationsDirectoryNotFound,
    /// A migration M > current N is already applied for this schema —
    /// applying N+1 before N would create an out-of-order sequence.
    OutOfOrderMigration,
    /// SQL execution failed; the migration transaction was rolled back.
    MigrationFailed,
    /// PostgreSQL major version < 15; fatal.
    UnsupportedPgVersion,
    /// Cannot acquire pool connection to run migrations.
    PoolExhausted,
};
```

---

## 6. DB Pool Connection Checkout — src/db/pool.zig

### New Helper Function

```zig
fn schemaNameForTenant(tenant_id: []const u8) []const u8
```

**Behaviour:**

- If `tenant_id` is an empty string → return `"tenant_default"`.
- If `tenant_id` equals `"00000000-0000-0000-0000-000000000000"` → return `"tenant_default"`.
- Otherwise: strip all `-` characters from `tenant_id`, prepend `"tenant_"`, return the result.

**Implementation notes:**

- This function is called on the hot path (every connection checkout), so it must be allocation-free. The result should be written into a fixed-size stack buffer. The maximum output length is `len("tenant_") + 32 = 39` bytes, well within stack limits.
- The function does not validate that the input is a valid UUID. Callers are expected to have already validated the tenant ID at the API boundary.
- Return type is `[]const u8` pointing into the stack buffer. The caller (i.e., `applyRequestTenantContext`) must consume it before the frame returns.

### Modified applyRequestTenantContext()

The existing `applyRequestTenantContext(conn)` function sets `bpm.tenant_id` via `set_config`. After SPT-01, it must also execute `SET search_path TO <schema_name>, public` using the derived schema name.

**Revised behaviour (both statements required during SPT-01 transition):**

1. Derive `schema_name` by calling `schemaNameForTenant(tenant_id)`.
2. Execute `SELECT set_config('bpm.tenant_id', $1, false)` — unchanged from current implementation. This preserves backward compatibility with all RLS policies that read `bpm_effective_tenant_id()`.
3. Execute `SELECT set_config('bpm.pipeline_run_id', $1, false)` — unchanged.
4. Execute `SET search_path TO <schema_name>, public` using the derived schema name. Because `schema_name` is UUID-derived and matches a safe identifier pattern, string interpolation is acceptable here (safe identifier — see §5 Safety Note). Use `std.fmt.bufPrint` to construct the statement into a stack buffer before calling `conn.exec`.

**Backward compatibility guarantee:** Both session variables are set on every connection checkout throughout the SPT-01 transition period. Existing code that reads `bpm.tenant_id` (RLS policies, `bpm_effective_tenant_id()`, audit triggers) continues working without modification. SPT-03 will remove the `set_config` calls and drop RLS policies; that is outside SPT-01 scope.

---

## 7. New Source File: src/db/provisioning.zig

### Purpose

Provides the Zig-side orchestration of schema creation and migration application. This is the single entry point for tenant provisioning in the Zig codebase.

### Public Interface

```zig
pub fn provisionTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    migrations_dir: []const u8,
) ProvisionError!void
```

### ProvisionError Error Set

```zig
pub const ProvisionError = error{
    /// The tenant_id_str is not a valid UUID string.
    InvalidTenantId,
    /// Database connection could not be acquired from the pool.
    PoolExhausted,
    /// The SQL call to bpm_provision_tenant_schema() failed.
    SchemaCreationFailed,
    /// migrations.runForSchema() failed — see MigrationError for sub-cause.
    MigrationFailed,
    /// Could not update migrations_applied_at in tenant_schemas.
    RegistryUpdateFailed,
    /// A lower-level DB query failed unexpectedly.
    QueryFailed,
};
```

### Behaviour (Step-by-Step)

1. **Validate input:** verify that `tenant_id_str` is non-empty. Return `ProvisionError.InvalidTenantId` if empty.

2. **Idempotency check:** acquire a connection from `pool`. Execute:
   ```sql
   SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1
   ```
   with `tenant_id_str` as the parameter. If count > 0, the schema is already provisioned and its migrations were already applied — release the connection and return immediately (no-op). This is the fast path for the common case where a tenant's schema is already fully set up.

3. **Release the connection** used for the idempotency check (before calling the SQL function, so the connection is back in the pool for the SQL call).

4. **Derive schema name:** call `pool_mod.schemaNameForTenant(tenant_id_str)` to get the schema name string.

5. **Call SQL provisioning function:** acquire a connection, execute:
   ```sql
   SELECT bpm_provision_tenant_schema($1)
   ```
   with `tenant_id_str` as the UUID parameter. On any pool or query error, return `ProvisionError.SchemaCreationFailed`. Release the connection.

6. **Apply migrations:** call `migrations.runForSchema(allocator, pool, migrations_dir, schema_name)`. Map any `MigrationError` variant to `ProvisionError.MigrationFailed`.

7. **Update registry timestamp:** acquire a connection, execute:
   ```sql
   UPDATE public.tenant_schemas
      SET migrations_applied_at = NOW()
    WHERE tenant_id = $1
   ```
   On any error, return `ProvisionError.RegistryUpdateFailed`. Release the connection.

8. Return `void` (success).

### Idempotency Guarantee

If called a second time for the same `tenant_id_str`:
- Step 2 returns count > 0 and the function returns immediately.
- No schemas are created, no migrations are re-run, no timestamps are overwritten.

If called concurrently for the same `tenant_id_str`:
- Both calls pass step 2 (count = 0 race).
- Both call `bpm_provision_tenant_schema` — the advisory lock inside the SQL function serializes them. The second call finds schema and row already present, exits cleanly.
- Both call `runForSchema` — the migration runner skips already-applied versions (idempotent by design).
- The `UPDATE ... SET migrations_applied_at` of the second caller is a benign overwrite.

---

## 8. Public Zig Function Signatures (Summary)

### src/db/migrations.zig

```zig
// Existing — re-expressed as wrapper; signature unchanged:
pub fn run(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
) MigrationError!void

// New:
pub fn runForSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    migrations_dir: []const u8,
    schema_name: []const u8,
) MigrationError!void

pub const MigrationError = error{
    MigrationsDirectoryNotFound,
    OutOfOrderMigration,
    MigrationFailed,
    UnsupportedPgVersion,
    PoolExhausted,
};
```

### src/db/pool.zig (additions)

```zig
// New private helper (not exported):
fn schemaNameForTenant(tenant_id: []const u8) []const u8

// Modified (same signature; extended behaviour):
fn applyRequestTenantContext(conn: *Conn) PoolError!void
```

`PoolError` is unchanged:

```zig
pub const PoolError = error{
    ExhaustedPool,
    ConnectionFailed,
    StaleConnection,
    InvalidPoolSize,
    UnsupportedPgVersion,
    QueryFailed,
};
```

### src/db/provisioning.zig (new file)

```zig
pub fn provisionTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    migrations_dir: []const u8,
) ProvisionError!void

pub const ProvisionError = error{
    InvalidTenantId,
    PoolExhausted,
    SchemaCreationFailed,
    MigrationFailed,
    RegistryUpdateFailed,
    QueryFailed,
};
```

---

## 9. Dependency Map

The following existing files will be modified by SPT-01 implementation:

| File | Nature of Change |
|---|---|
| `src/db/migrations.zig` | Add `runForSchema()`. Re-implement `run()` as a wrapper calling `runForSchema("public")`. Update `schema_migrations` INSERT to include `schema_name`. Update SELECT to filter by `schema_name`. |
| `src/db/pool.zig` | Add private `schemaNameForTenant()` helper. Extend `applyRequestTenantContext()` to additionally execute `SET search_path TO <schema_name>, public`. |

The following files will be created:

| File | Description |
|---|---|
| `src/db/provisioning.zig` | New Zig module: `provisionTenantSchema` orchestrator. |
| `migrations/060_schema_per_tenant_bootstrap.sql` | DDL: `public.tenant_schemas`, `schema_migrations` schema_name column, `bpm_provision_tenant_schema()` function. |

No other source files require modification in SPT-01. The RLS policies, `bpm_effective_tenant_id()`, and all tenant_id columns are untouched until SPT-03.

---

## 10. Error Taxonomy

Full classification of provisioning failures:

| Error | Source | Severity | Recovery |
|---|---|---|---|
| `ProvisionError.InvalidTenantId` | Empty `tenant_id_str` passed to `provisionTenantSchema` | Caller bug | Fix caller; do not retry |
| `ProvisionError.PoolExhausted` | No connections available | Transient | Retry with backoff |
| `ProvisionError.SchemaCreationFailed` | `bpm_provision_tenant_schema()` SQL call failed (e.g., permission error, pg_advisory_xact_lock timeout, unexpected constraint violation) | Infrastructure | Check PostgreSQL logs; may require admin intervention |
| `ProvisionError.MigrationFailed` | `migrations.runForSchema()` returned any `MigrationError` | Likely SQL syntax or constraint violation in a migration file | Inspect migration file; fix and retry |
| `ProvisionError.RegistryUpdateFailed` | `UPDATE tenant_schemas SET migrations_applied_at` failed | Unlikely; transient | Retry; if persistent, check DB health |
| `ProvisionError.QueryFailed` | Any other unexpected DB query failure | Infrastructure | Check DB connectivity |
| `MigrationError.MigrationsDirectoryNotFound` | `migrations_dir` path invalid | Configuration | Fix `migrations_dir` value at startup |
| `MigrationError.OutOfOrderMigration` | A higher-version migration is already applied for the schema | Deployment error | Manual DBA intervention to inspect `schema_migrations` |
| `MigrationError.MigrationFailed` | SQL execution failed inside migration file | SQL error | Inspect migration file and PostgreSQL error detail |
| `MigrationError.PoolExhausted` | Pool exhausted during migration application | Transient | Retry with backoff |

---

## 11. Backward Compatibility Guarantee

During the SPT-01 transition period, the platform MUST remain fully backward compatible with all code that relies on the current RLS-based tenant isolation model. The following guarantees are required and must be verifiable by inspection of the implementation:

### Dual Session Variable Setting (Hard Requirement)

On every connection checkout via `Pool.acquire()`, `applyRequestTenantContext()` MUST execute both:

1. `SELECT set_config('bpm.tenant_id', <tenant_id>, false)` — preserves the RLS-based isolation path.
2. `SET search_path TO <schema_name>, public` — enables the new schema-based isolation path.

Neither call may be omitted during the SPT-01 transition. SPT-03 will remove call (1) and disable RLS policies; that is outside the scope of SPT-01.

### RLS Policy Continuity

- `bpm_effective_tenant_id()` continues to read `bpm.tenant_id` from the session setting. All existing RLS policies on `process_definitions`, `instance_projections`, `tasks`, `tokens`, `audit_entries`, and `audit_log` remain in effect unchanged.
- No RLS policies are added, modified, or dropped by migration 060.
- No `tenant_id` columns are altered or removed by migration 060.

### schema_migrations Table Compatibility

The existing `schema_migrations` table bootstrap in `migrations.zig` creates the table with `version TEXT PRIMARY KEY`. Migration 060 alters this table (adds `schema_name` column, replaces primary key). The idempotent DO block guards prevent errors if migration 060 is applied to a database where the table has already been altered. The `run()` function's inline bootstrap DDL (`CREATE TABLE IF NOT EXISTS schema_migrations ...`) continues to succeed as a no-op after migration 060 runs because the table already exists.

### Module Isolation

Any module that obtains a connection via `Pool.acquire()` automatically receives `search_path` isolation without any code changes. This includes all existing domain modules: `event_store/store.zig`, `definition/registry.zig`, `engine/transition.zig` callers, `tasks/manager.zig`, `scheduler/scheduler.zig`, `identity/registry.zig`, `obs/audit.zig`, etc.

---

## 12. Key Invariants

These properties must hold at all times after SPT-01 is applied:

1. Every row in `public.tenant_schemas` has a corresponding PostgreSQL schema of the same `schema_name`.
2. `schema_name` in `public.tenant_schemas` is always derivable from `tenant_id` using the naming convention in §2. No schema name is stored that cannot be reproduced from the UUID.
3. The `bpm_provision_tenant_schema()` function is the sole point of schema creation and `tenant_schemas` row insertion. Nothing else creates tenant schemas directly.
4. `migrations_applied_at IS NOT NULL` in `tenant_schemas` implies that `runForSchema` completed successfully for that schema at some point. `migrations_applied_at IS NULL` means the schema was created but migration application has not yet completed (partial provisioning; retry is safe).
5. `public.schema_migrations` is the single source of truth for which migration files have been applied to which schema. Querying `WHERE schema_name = $1` yields the full migration history for that tenant's schema.
6. `SET search_path TO <schema_name>, public` ensures that unqualified table references in SQL queries resolve to the tenant's schema first, falling back to `public` for shared infrastructure tables (e.g., `tenant_schemas`, `schema_migrations`).

---

## 13. Open Questions

None. All design decisions are determined by the SPT-01 scope statement and the existing codebase conventions.
