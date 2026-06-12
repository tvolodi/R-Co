# Module: ISS-502 SPT Cutover Transaction

## Module purpose

This module implements the SPT-02 cutover procedure: copy all rows from public-schema business tables into the tenant's dedicated schema, verify row-count and checksum parity, and atomically flip `public.tenants.storage_mode` from `LEGACY_RLS` to `SCHEMA`. The entire operation runs in a single PostgreSQL transaction -- any failure rolls back and leaves the tenant in `LEGACY_RLS` mode (safe state). The procedure is idempotent: re-running on an already-migrated tenant is a no-op.

## Scope and non-goals

- In scope: the Zig-side cutover function with copy, verify, flip steps in a single transaction.
- In scope: idempotency guard (check storage_mode before starting).
- In scope: row-count and checksum verification per table.
- Out of scope: the admin HTTP endpoint that triggers the cutover (existing `src/admin/tenant_migration.zig` may be extended or a new admin route added).
- Out of scope: pg_dump-based export/import (TNT-06 handles that separately).
- Out of scope: RLS removal after cutover (ISS-503).

## Prerequisites

- ISS-501: storage_mode routing is active -- once flipped to SCHEMA, requests are routed to the tenant schema.
- ISS-107: `public.tenants.storage_mode` column exists.
- Tenant schema exists and all per-tenant migrations have been applied (tenant_schemas.migrations_applied_at IS NOT NULL).

## Public interface

### Cutover function

```zig
/// Execute the SPT cutover for a single tenant.
///
/// Steps (all in one transaction):
///   1. BEGIN
///   2. Check storage_mode: if already 'SCHEMA' → COMMIT (idempotent no-op)
///   3. Copy all rows from public business tables → tenant schema
///   4. Verify row count parity per table
///   5. Verify checksum parity per table
///   6. UPDATE public.tenant SET storage_mode = 'SCHEMA'
///   7. COMMIT
///
/// On any failure: ROLLBACK. Tenant stays LEGACY_RLS.
///
/// tables: the list of business tables to copy (see §Business tables below).
/// allocator: for query result strings.
/// pool: connection pool.
/// tenant_id_str: the 36-char UUID of the tenant to migrate.
/// tenant_schema: the target schema name (e.g. "tenant_a1b2c3...").
pub fn executeSptCutover(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id_str: []const u8,
    tenant_schema: []const u8,
    tables: []const []const u8,
) SptCutoverError!CutoverResult;
```

### Result type

```zig
pub const CutoverResult = struct {
    rows_copied: usize,
    tables_verified: usize,
    already_migrated: bool,
};

pub const PerTableVerification = struct {
    table_name: []const u8,
    public_row_count: usize,
    schema_row_count: usize,
    checksum_match: bool,
};
```

## Business tables (tables to copy)

The following tables are copied from `public` to the tenant schema during cutover. These are the tables that were originally RLS-protected and contain per-tenant business data:

| Table | Notes |
|---|---|
| `process_definitions` | |
| `instance_projections` | |
| `events` | |
| `events_archive` | |
| `tasks` | |
| `tokens` | |
| `timers` | |
| `audit_entries` | |
| `audit_log` | |
| `users` | |
| `groups` | |
| `group_members` | |
| `roles` | |
| `user_roles` | |
| `api_tokens` | |
| `webhook_subscriptions` | |
| `webhook_deliveries` | |
| `dead_letter_items` | |
| `instance_sequence` | |
| `event_type_registry` | |
| `event_retention_policies` | |
| `repository_form_schemas` | |
| `schema_migrations` | (per-tenant entries only; GBL- entries stay in public) |

## Transaction design

### Step 1: BEGIN

```sql
BEGIN;
```

### Step 2: Idempotency guard

```sql
SELECT storage_mode FROM public.tenant WHERE id = $1::uuid;
```
If result is `'SCHEMA'`: `COMMIT;` return `CutoverResult{ .already_migrated = true }`.

If tenant not found: `ROLLBACK;` return `SptCutoverError.TenantNotFound`.

### Step 3: Copy rows

For each table in the business tables list:

```sql
INSERT INTO tenant_{slug}.{table} SELECT * FROM public.{table}
 WHERE tenant_id = $1::uuid;
```

The `WHERE tenant_id = $1::uuid` filter ensures only this tenant's rows are copied. This filter works because legacy business tables still have their `tenant_id` column (RLS has not been removed yet -- that is ISS-503).

**Exception for tables without tenant_id:** `schema_migrations` entries for this tenant are copied via:

```sql
INSERT INTO tenant_{slug}.schema_migrations
SELECT * FROM public.schema_migrations
 WHERE schema_name = $1;  -- $1 = tenant schema name
```

### Step 4: Verify row count parity

For each table, compare counts:

```sql
SELECT count(*) FROM public.{table} WHERE tenant_id = $1::uuid;
SELECT count(*) FROM tenant_{slug}.{table};
```

If any pair differs: `ROLLBACK;` return `SptCutoverError.RowCountMismatch` with the table name and counts.

### Step 5: Verify checksum parity

For each table with rows, compute a simple checksum (MD5 of concatenated row text representations) to verify data integrity:

```sql
SELECT md5(string_agg(row_hash::text, '' ORDER BY row_hash))
FROM (
  SELECT md5(CAST(t AS text)) AS row_hash
  FROM public.{table} t
  WHERE tenant_id = $1::uuid
) s;
```

Same query against `tenant_{slug}.{table}`. If checksums differ: `ROLLBACK;` return `SptCutoverError.ChecksumMismatch`.

### Step 6: Flip storage_mode

```sql
UPDATE public.tenant SET storage_mode = 'SCHEMA', updated_at = NOW()
 WHERE id = $1::uuid;
```

### Step 7: COMMIT

```sql
COMMIT;
```

At this point, subsequent requests for this tenant are routed via the SCHEMA path (ISS-501). The tenant's data in the public schema is now orphaned (still present but no longer read or written). Cleanup of orphaned public-schema rows is deferred to ISS-503/RLS removal.

## Error taxonomy

```zig
pub const SptCutoverError = error{
    TenantNotFound,
    AlreadySchemaMode,       // idempotent -- not an error, handled gracefully
    RowCountMismatch,
    ChecksumMismatch,
    CopyFailed,
    FlipFailed,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};
```

## Idempotency contract

- If `storage_mode` is already `'SCHEMA'`: the function returns success immediately (`already_migrated = true`). No rows are copied, no verification is performed.
- If `storage_mode` is `'LEGACY_RLS'` but rows already exist in the tenant schema (from a prior failed cutover): the `INSERT INTO ... SELECT *` will fail with a primary-key or unique-constraint violation, the transaction rolls back, and the tenant stays `LEGACY_RLS`. The operator must clean up the tenant schema before retrying. This is a safe failure mode.
- Re-running after a successful cutover is always a no-op.

## Integration points

### src/admin/tenant_migration.zig

The `executeSptCutover()` function is called from an admin endpoint (or directly from the tenant lifecycle module). The existing `handleExportTenant`/`handleImportTenant` functions in this file are for TNT-06 (cross-server migration) and are separate from SPT-02 (same-server cutover).

### src/db/pool.zig

No changes required. The pool's `applyRequestStorageRouting()` (ISS-501) already handles both `LEGACY_RLS` and `SCHEMA` paths.

### migrations

No new migration required. The `storage_mode` column was added by ISS-107. This module only reads and updates it.

## Dependencies

- ISS-107: `public.tenants.storage_mode` column (RELEASED).
- ISS-501: storage-mode-aware connection routing must be live before cutover can be tested end-to-end.
- Per-tenant migrations must have been applied (tenant_schemas.migrations_applied_at IS NOT NULL) -- the tenant schema tables must exist before rows can be copied into them.

## Test plan considerations

- Seed a tenant with known rows in LEGACY_RLS mode.
- Run cutover, verify all rows copied with correct counts and checksums.
- Verify storage_mode = 'SCHEMA' after cutover.
- Verify subsequent requests route to the tenant schema (ISS-501 test).
- Inject a row-count mismatch (delete a row mid-transaction) and verify rollback.
- Run cutover twice on the same tenant and verify idempotent no-op.
