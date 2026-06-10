# Module: tnt-05-07-backfill-export-cleanup

**Covers:** TNT-05, TNT-06, TNT-07
**Stage:** 12 — Backfill, export/import, and RLS cleanup
**Run ID:** WF02-tnt-batch2-20260609
**Depends on:** tnt-01-04-schema-isolation (Batch 1, must be RELEASED before this runs)

**Files modified:**
- `src/db/pool.zig` (TNT-06: db_host routing)
- `src/api/routes/admin.zig` (TNT-06: export/import admin endpoints)

**New files:**
- `migrations/GBL-074_tnt05_backfill_tracking.sql` (TNT-05: tracking tables)
- `migrations/GBL-075_tnt05_backfill_run.sql` (TNT-05: backfill algorithm)
- `migrations/GBL-076_tnt06_db_host_column.sql` (TNT-06: db_host column)
- `migrations/GBL-077_tnt07_rls_cleanup.sql` (TNT-07: RLS and tenant_id removal)
- `src/admin/tenant_migration.zig` (TNT-06: export/import procedures)

---

## Module purpose

Batch 2 of Stage 12 completes the schema-per-tenant migration by:

1. **TNT-05** — Running a one-time backfill that copies all rows from `public`
   business tables (where `tenant_id = T`) into the corresponding tables in
   `tenant_<T_uuid>`. The backfill is idempotent, batched, dependency-ordered,
   and gated behind a migration-window flag.

2. **TNT-06** — Adding a `db_host` column to `public.tenant_schemas` so the
   connection pool can route per-tenant queries to different PostgreSQL servers.
   Adds export and import procedures (pg_dump / pg_restore based) to move a
   tenant schema to a new server within a 10-minute maintenance window.

3. **TNT-07** — Removing all RLS policies, RLS enablement, and `tenant_id`
   columns from the public business tables, plus dropping the
   `bpm_effective_tenant_id()` function. This migration is gated by a pre-flight
   check that verifies every tenant has completed the TNT-05 backfill.

These three requirements are all **Type E — novel / cross-cutting** because they
span the migration runner, connection pool, admin API, and global schema DDL.

---

## TNT-05: Backfill migration design

### Migration files

Two GBL-prefixed migration files handle the backfill:

**GBL-074_tnt05_backfill_tracking.sql** — creates the tracking tables:

```sql
-- GBL-074: TNT-05 backfill tracking tables (idempotent)
CREATE TABLE IF NOT EXISTS tnt05_progress (
    tenant_id    UUID        NOT NULL,
    table_name   TEXT        NOT NULL,
    rows_copied  BIGINT      NOT NULL DEFAULT 0,
    status       TEXT        NOT NULL DEFAULT 'PENDING',
    started_at   TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, table_name),
    CONSTRAINT tnt05_progress_status_check
        CHECK (status IN ('PENDING', 'IN_PROGRESS', 'COMPLETED', 'FAILED'))
);

CREATE TABLE IF NOT EXISTS tnt05_orphans (
    row_id      TEXT        NOT NULL,
    table_name  TEXT        NOT NULL,
    tenant_id   UUID        NOT NULL,
    reason      TEXT        NOT NULL,
    logged_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (table_name, row_id)
);
```

Both tables are created in `public` (no schema prefix required because the
migration runner sets `search_path` to `public` for GBL migrations). They must
be added to `PERMITTED_PUBLIC_TABLES` in `src/bootstrap/audit.zig` before
GBL-074 runs.

**GBL-075_tnt05_backfill_run.sql** — executes the backfill algorithm (see
§ Backfill algorithm below).

### Business table dependency order

Rows must be copied in this dependency order to satisfy foreign key constraints
within each tenant schema (parent before child):

| Order | Table name | Depends on |
|---|---|---|
| 1 | `events` | (none) |
| 2 | `events_archive` | (none) |
| 3 | `instance_sequence` | (none) |
| 4 | `event_type_registry` | (none) |
| 5 | `event_retention_policies` | `event_type_registry` |
| 6 | `process_definitions` | (none) |
| 7 | `instance_projections` | `process_definitions`, `events` |
| 8 | `tasks` | `instance_projections` |
| 9 | `tokens` | `instance_projections` |
| 10 | `timers` | `instance_projections` |
| 11 | `users` | (none) |
| 12 | `groups` | (none) |
| 13 | `group_members` | `users`, `groups` |
| 14 | `roles` | (none) |
| 15 | `user_roles` | `users`, `roles` |
| 16 | `api_tokens` | `users` |
| 17 | `webhook_subscriptions` | (none) |
| 18 | `dead_letter_items` | (none) |
| 19 | `audit_entries` | (none) |
| 20 | `audit_log` | (none) |
| 21 | `repository_form_schemas` | (none) |

This is the full list of 21 business tables from TNT-01. Tables with no FK
dependencies on other business tables are listed first.

### Backfill algorithm (GBL-075 specification)

The algorithm is expressed as PL/pgSQL inside a `DO $$ ... $$` block. Key steps:

**Step 1 — Set migration window flag.**

```sql
UPDATE onboarding_registry
   SET migration_window_active = TRUE;
```

This suppresses ERROR-level audit log entries in `src/bootstrap/audit.zig`
during the copy window.

**Step 2 — For each tenant in `public.tenant` (ordered by `created_at ASC`),
for each business table in the dependency order above:**

a. Skip if `tnt05_progress` already shows `status = 'COMPLETED'` for this
   `(tenant_id, table_name)` pair (idempotency).

b. Set `status = 'IN_PROGRESS'`, `started_at = now()` in `tnt05_progress`.

c. Copy rows in batches of 10,000:

```
LOOP
    INSERT INTO <schema_name>.<table> (<columns_without_tenant_id>)
    SELECT <columns_without_tenant_id>
      FROM public.<table>
     WHERE tenant_id = <tenant_uuid>
       AND ctid > <last_ctid>
     ORDER BY ctid
     LIMIT 10000
    ON CONFLICT DO NOTHING;

    rows_copied += GET DIAGNOSTICS row_count;
    EXIT WHEN row_count < 10000;
END LOOP;
```

The batch cursor uses `ctid` (physical row ID) ordering because it is available
on all heap tables without a dedicated sequence and avoids locking the entire
table. Each batch runs in its own transaction to limit lock duration and WAL
pressure.

The `ON CONFLICT DO NOTHING` clause handles the case where the migration is
re-run after a partial failure: rows already present in the tenant schema are
silently skipped.

d. Update `tnt05_progress` with final `rows_copied`, `status = 'COMPLETED'`,
   `completed_at = now()`.

**Step 3 — Orphan handling.**

After processing all known tenants, scan each business table for rows whose
`tenant_id` is not present in `public.tenant`:

```
INSERT INTO tnt05_orphans (row_id, table_name, tenant_id, reason)
SELECT id::text, '<table_name>', tenant_id,
       'tenant_id not found in public.tenant'
  FROM public.<table>
 WHERE tenant_id NOT IN (SELECT id FROM public.tenant)
ON CONFLICT DO NOTHING;
```

Orphan rows are **not** migrated. They remain in `public.<table>` for manual
review. The orphan log is written to `tnt05_orphans`.

**Step 4 — Default tenant (00000000-...) handling.**

The default tenant UUID (`00000000-0000-0000-0000-000000000000`) is always
present in `public.tenant`. `schemaNameForTenant` maps it to `tenant_default`.
The backfill algorithm treats it identically to other tenants: rows with
`tenant_id = '00000000-0000-0000-0000-000000000000'` are copied to
`tenant_default.<table>`.

**Step 5 — Zero-row tenants.**

If a tenant has zero rows in `public.<table>`, the INSERT selects zero rows and
`GET DIAGNOSTICS` returns 0. `tnt05_progress` records `rows_copied = 0` and
`status = 'COMPLETED'`. This is a no-op and not an error.

**Step 5b — Delete source rows from public (per tenant, per table).**

After `tnt05_progress` records `status = 'COMPLETED'` for a `(tenant_id,
table_name)` pair (Step 2d above), issue a **separate transaction** to remove
the now-migrated rows from `public`:

```
-- New transaction (committed separately from the INSERT batch)
DELETE FROM public.<table>
 WHERE tenant_id = <tenant_uuid>;
```

This step satisfies the TNT-05 acceptance criterion:
`SELECT count(*) FROM public.<table> WHERE tenant_id = T_uuid` must equal 0
after the backfill completes.

Design constraints for this DELETE:

1. **Separate transaction.** The INSERT batch and the COMPLETED status update
   are committed first. The DELETE runs in a new, independent transaction
   opened immediately after.

2. **Scoped strictly to one tenant.** The `WHERE tenant_id = <tenant_uuid>`
   predicate is always present. No DELETE without a tenant filter is ever issued.

3. **Idempotent.** If the DELETE has already run (e.g. after a re-run following
   a partial failure), `DELETE FROM public.<table> WHERE tenant_id = <uuid>`
   finds zero rows and exits without error. `GET DIAGNOSTICS` returns 0 — this
   is not an error condition.

4. **Orphan rows are not deleted.** Rows written to `tnt05_orphans` (whose
   `tenant_id` is not in `public.tenant`) are never touched by Step 5b.
   Step 5b only runs for tenants whose `(tenant_id, table_name)` pair has
   `status = 'COMPLETED'` in `tnt05_progress`.

5. **Order.** Step 5b runs after Step 2d (COMPLETED mark), before advancing
   to the next `(tenant_id, table_name)` pair in the outer loop. The DELETE
   for table N of tenant T happens before the INSERT for table N+1 of tenant T
   begins.

**Step 6 — Clear migration window flag.**

After all tenants complete:

```sql
UPDATE onboarding_registry
   SET migration_window_active = FALSE;
```

### Permitted public table list additions (TNT-05)

Before GBL-074 runs, the following names must be added to `PERMITTED_PUBLIC_TABLES`
in `src/bootstrap/audit.zig`:

- `tnt05_progress`
- `tnt05_orphans`

---

## TNT-06: db_host routing and export/import design

### Migration GBL-076_tnt06_db_host_column.sql

```sql
-- GBL-076: TNT-06 — add db_host routing column to tenant_schemas
ALTER TABLE tenant_schemas
    ADD COLUMN IF NOT EXISTS db_host TEXT DEFAULT NULL;

COMMENT ON COLUMN tenant_schemas.db_host IS
    'Override PostgreSQL host for this tenant. NULL = use BPM_DB_URL host.';
```

This migration is GBL-scoped because `tenant_schemas` is a public routing table.

### Pool routing by db_host (src/db/pool.zig modifications)

#### New pool configuration

The `PoolConfig` struct gains a `base_url` field (the existing `url` renamed to
make it explicit that it is the fallback), and the pool gains the ability to
establish per-tenant connections to remote hosts.

**Modified struct — PoolConfig:**

```zig
pub const PoolConfig = struct {
    /// Primary PostgreSQL DSN from BPM_DB_URL. Used when db_host IS NULL.
    url: []const u8,
    /// Maximum pool size (shared across all servers). Valid range: 2..200.
    pool_size: u8,
};
```

The `url` field is unchanged. Single-server deployments continue to work without
any configuration change.

#### New function — resolveDbHostForTenant

```zig
/// Look up db_host for the current tenant from public.tenant_schemas.
/// Returns null if the tenant_schemas row has db_host = NULL or if no row
/// exists for this tenant (falls back to single-server behaviour).
///
/// conn — a connection already checked out from the pool (caller owns it).
/// allocator — for the returned host string (caller must free).
/// tenant_id — the resolved tenant UUID string.
///
/// Returns PoolError.QueryFailed on DB error.
pub fn resolveDbHostForTenant(
    conn: *Conn,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
) PoolError!?[]const u8;
```

This function issues a parameterised query against `public.tenant_schemas`
using `$1` for the tenant UUID. It does NOT use `std.fmt.allocPrint` for
query construction.

#### Modified function — applyRequestTenantContext (TNT-06 addition)

The existing `applyRequestTenantContext` function sets `search_path` and
`set_config`. For TNT-06, if `db_host IS NOT NULL` for the tenant, the pool
must establish (or reuse) a connection to that host instead of the default.

The connection struct gains an optional `_remote_host` field:

```zig
pub const Conn = struct {
    _pool_idx:     usize,
    _is_valid:     bool,
    _url:          []const u8,
    _remote_host:  ?[]const u8,  // NEW — TNT-06; null = local BPM_DB_URL host
    _io:           std.Io,
    _pg:           pg.Conn,
    // ... existing methods unchanged ...
};
```

When `applyRequestTenantContext` is called and the tenant has a non-null
`db_host`, the pool redirects by:

1. Calling `resolveDbHostForTenant` on a local connection to look up `db_host`.
2. If `db_host` differs from the current connection's host:
   - Close the current `_pg` connection.
   - Build a new DSN from `BPM_DB_URL` with the `host=` component replaced by
     `db_host`. No other DSN components change (port, user, password, dbname
     remain from the original `BPM_DB_URL`).
   - Open a new `pg.Conn` to the target host.
   - Set `conn._remote_host = db_host`.
3. Apply `SET search_path` and `set_config` on the new connection.
4. On failure to connect to the remote host: return `PoolError.ConnectionFailed`.

Single-server fallback: if `tenant_schemas.db_host IS NULL` or the tenant has
no row in `tenant_schemas`, `resolveDbHostForTenant` returns `null` and the
pool uses the existing `BPM_DB_URL` connection unchanged.

#### DSN host substitution

The function that rewrites the DSN host is:

```zig
/// Build a new DSN string by replacing the host component of base_url
/// with new_host. Port, user, password, dbname, and all other parameters
/// are preserved unchanged.
///
/// allocator — caller must free the returned string.
/// base_url  — PostgreSQL DSN in postgres://user:pass@host:port/dbname form.
/// new_host  — replacement hostname (validated: alphanumeric + . + - only).
///
/// Returns PoolError.ConnectionFailed if base_url cannot be parsed or
/// new_host contains unsafe characters.
fn buildTenantDsn(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    new_host: []const u8,
) PoolError![]const u8;
```

`new_host` is validated against the pattern `[a-zA-Z0-9._-]+` before use. No
user-supplied string is interpolated into SQL; `new_host` goes into the DSN
connection string, not a query.

### Tenant write-pause: MIGRATING status

The `public.tenant.status` column gains a new allowed value `'MIGRATING'`. The
existing CHECK constraint on `tenant.status` must be updated:

```
CONSTRAINT tenant_status_check CHECK (status IN ('ACTIVE', 'INACTIVE', 'MIGRATING'))
```

This constraint update is included in GBL-076.

When `tenant.status = 'MIGRATING'`, the API middleware layer must:

- For write requests (POST, PUT, PATCH, DELETE): return HTTP 503 with a
  `Retry-After: 60` header and body:
  ```json
  {"type":"about:blank","title":"Tenant Migration In Progress",
   "status":503,"detail":"Tenant is being migrated. Reads continue; writes resume after migration."}
  ```
- For read requests (GET, HEAD): allow through normally.

The middleware check is added to `src/api/middleware/auth.zig` (or a new
`src/api/middleware/tenant_status.zig` if keeping auth.zig narrow is preferred —
BACKEND-DEV decides).

### Admin API endpoints (src/admin/tenant_migration.zig)

Two new admin-only endpoints:

**POST /api/v1/admin/tenants/{tenant_id}/export**

```zig
/// Trigger an export of tenant_<uuid> schema to a dump file.
///
/// Requires admin JWT with scope admin:tenant:write.
/// Sets tenant.status = 'MIGRATING' for the final sync phase only.
///
/// Request body (JSON):
///   { "destination_path": "/exports/tenant-<uuid>-<timestamp>.dump" }
///
/// Response 202 Accepted:
///   { "export_id": "<uuid>", "status": "in_progress",
///     "tenant_id": "<uuid>", "destination_path": "..." }
///
/// Response 409 Conflict: tenant is already MIGRATING
/// Response 404: tenant not found
pub fn handleExportTenant(ctx: *RequestContext) !void;
```

**POST /api/v1/admin/tenants/{tenant_id}/import**

```zig
/// Complete the import: record db_host in tenant_schemas, verify operational.
///
/// Requires admin JWT with scope admin:tenant:write.
/// Caller has already restored the dump on the target server (pg_restore step).
/// This endpoint updates routing and verifies connectivity.
///
/// Request body (JSON):
///   { "db_host": "s2.example.com",
///     "verify_query": "SELECT 1" }   // optional smoke-test query
///
/// Response 200 OK:
///   { "tenant_id": "<uuid>", "db_host": "s2.example.com",
///     "status": "ACTIVE", "verified": true }
///
/// Response 400: db_host fails validation
/// Response 404: tenant not found
/// Response 502: smoke-test query failed on target server
pub fn handleImportTenant(ctx: *RequestContext) !void;
```

### Export procedure (operator workflow, not code)

The export procedure is a documented operational workflow backed by the API:

1. **Initial dump** (while tenant is ACTIVE, writes continue):
   `pg_dump --schema=tenant_<uuid> --format=custom --no-acl --no-owner -f /tmp/<uuid>.dump <BPM_DB_URL>`

2. **Final sync** — call `POST /api/v1/admin/tenants/{id}/export` to set
   `tenant.status = 'MIGRATING'` and take a second incremental or full dump
   capturing any writes since step 1. The dump file path is specified in the
   request body.

3. **Restore on S2**:
   `pg_restore --schema=tenant_<uuid> --no-acl --no-owner -d <S2_DB_URL> /tmp/<uuid>-final.dump`

4. **Update routing** — call `POST /api/v1/admin/tenants/{id}/import` with
   `db_host = S2_host`. The endpoint updates `tenant_schemas.db_host = S2_host`
   and resets `tenant.status = 'ACTIVE'`.

5. **Verify** — the endpoint performs a smoke-test query on S2 using the new
   routing before returning 200.

6. **Drop old schema on S1** (separate operator action):
   `DROP SCHEMA tenant_<uuid> CASCADE` — executed manually after confirming S2
   is authoritative.

The 10-minute SLA covers steps 2 through 4. Step 1 (background dump) happens
outside the maintenance window.

### Failure rollback

If step 3 (pg_restore) fails partially:
- The import endpoint (step 4) is never called.
- `tenant_schemas.db_host` remains NULL.
- `tenant.status` is reset to `ACTIVE` by the export endpoint's cleanup path
  (the endpoint registers a cleanup function that runs on timeout or explicit
  cancel).
- Partial dump on S2 is cleaned up by the operator.

---

## TNT-07: RLS cleanup migration design

### Migration GBL-077_tnt07_rls_cleanup.sql

This migration runs as a GBL-scoped migration (operates on `public` tables).

#### Pre-flight check function

The migration begins with a pre-flight check expressed as a PL/pgSQL function
(defined inline in the DO block, not persisted):

```
-- Pre-flight logic (pseudocode for specification; not implementation code):
FOR each row T in public.tenant:
    IF NOT EXISTS (
        SELECT 1 FROM public.tenant_schemas
         WHERE tenant_id = T.id
           AND migrations_applied_at IS NOT NULL
    ) THEN
        unready_tenants += T.id
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.tnt05_progress
         WHERE tenant_id = T.id
           AND status = 'COMPLETED'
           -- at least one row with COMPLETED status for this tenant
    ) THEN
        unready_tenants += T.id
    END IF;

IF unready_tenants IS NOT EMPTY THEN
    RAISE EXCEPTION 'TNT-07 pre-flight failed. Unready tenants: %', unready_tenants
END IF;
```

The pre-flight check must find at least one `tnt05_progress` row with
`status = 'COMPLETED'` for each tenant. A tenant with zero business tables
(all zero-row tables) still has progress rows (they are written as
`rows_copied = 0, status = 'COMPLETED'` — see TNT-05 §Step 2d above).

If the pre-flight check raises an exception: **no DDL changes are made**.
The migration runner propagates the exception and leaves all tables unchanged.

#### DDL list (executed only after pre-flight passes)

For each of the 21 business tables that had RLS enabled by migration 028 (events,
events_archive, process_definitions, instance_projections, tasks, tokens,
audit_entries, audit_log — the subset that received RLS in mig 027/028) and
any other table with `tenant_id` added in subsequent migrations:

**RLS removal sequence per table (all guarded with IF EXISTS):**

```
DISABLE ROW LEVEL SECURITY on <table>
DROP POLICY IF EXISTS <table>_tenant_policy ON <table>
ALTER TABLE <table> DROP COLUMN IF EXISTS tenant_id
```

The exact tables with RLS policies from migration 028 are:
`process_definitions`, `instance_projections`, `tasks`, `tokens`,
`audit_entries`, `audit_log`.

Additional tables with `tenant_id` column only (no RLS — added by migration 027):
`events`, `events_archive`.

Tables with `tenant_id` added in other migrations and present in the tenant
schema only (not in public after GBL-073): none — GBL-073 dropped them already.

**Drop the bpm_effective_tenant_id function:**

```
DROP FUNCTION IF EXISTS bpm_effective_tenant_id()
```

Note: if any trigger or view still references this function, `DROP FUNCTION`
will fail with a dependency error. The migration aborts and lists the dependent
objects. The operator must manually clean up the dependent objects before
re-running. This is the edge case specified in TNT-07: "DROP FUNCTION fails with
a dependency error; migration aborts and lists the dependent objects."

**Drop constraint change for MIGRATING status (if not done in GBL-076):**

GBL-077 does not need to touch the `tenant_status_check` constraint — that is
handled in GBL-076 (db_host column migration). GBL-077 focuses exclusively on
RLS removal.

#### Idempotency

All DDL statements use idempotent forms:
- `DISABLE ROW LEVEL SECURITY` is idempotent (safe to call on a table where RLS
  is already disabled).
- `DROP POLICY IF EXISTS` is idempotent.
- `ALTER TABLE ... DROP COLUMN IF EXISTS` is idempotent.
- `DROP FUNCTION IF EXISTS` is idempotent.

Running GBL-077 twice produces no error.

---

## Public interface

### src/db/pool.zig — new and modified functions

```zig
/// NEW — TNT-06
/// Look up db_host for the current tenant from public.tenant_schemas.
/// Returns null when db_host IS NULL or no tenant_schemas row exists.
pub fn resolveDbHostForTenant(
    conn: *Conn,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
) PoolError!?[]const u8;

/// NEW — TNT-06
/// Build a new DSN by replacing the host component of base_url with new_host.
/// Validates new_host against [a-zA-Z0-9._-]+ before substitution.
fn buildTenantDsn(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    new_host: []const u8,
) PoolError![]const u8;

/// MODIFIED — TNT-06
/// Pool.acquire: now calls resolveDbHostForTenant and opens a remote
/// connection if db_host IS NOT NULL and differs from the pool's default host.
pub fn acquire(self: *Pool) PoolError!*Conn;

/// MODIFIED — TNT-06
/// Pool.release: resets search_path (existing TNT-03 behaviour) and closes
/// any remote connection opened for the tenant (returns it to the idle pool
/// only if the connection is to the default host; otherwise closes it).
pub fn release(self: *Pool, conn: *Conn) void;
```

### src/admin/tenant_migration.zig — new functions

```zig
/// TNT-06: Handle POST /api/v1/admin/tenants/{tenant_id}/export
/// Sets MIGRATING status, triggers pg_dump, returns export metadata.
pub fn handleExportTenant(ctx: *RequestContext) !void;

/// TNT-06: Handle POST /api/v1/admin/tenants/{tenant_id}/import
/// Updates tenant_schemas.db_host, resets status to ACTIVE, verifies S2.
pub fn handleImportTenant(ctx: *RequestContext) !void;

pub const TenantMigrationError = error{
    TenantNotFound,
    TenantAlreadyMigrating,
    RemoteConnectionFailed,
    DumpFailed,
    InvalidDbHost,
    PoolExhausted,
    PersistenceFailed,
};
```

---

## Error taxonomy

### PoolError additions (TNT-06)

| Error variant | Trigger | Behaviour |
|---|---|---|
| `PoolError.ConnectionFailed` | Remote host connection refused or auth failed | `acquire()` returns error; no connection returned |
| `PoolError.QueryFailed` | `resolveDbHostForTenant` SELECT fails | `acquire()` returns error |

No new `PoolError` variants are required. The existing `ConnectionFailed` and
`QueryFailed` variants cover all TNT-06 failure modes in the pool.

### TenantMigrationError (TNT-06 admin API)

| Error variant | HTTP status | Description |
|---|---|---|
| `TenantNotFound` | 404 | No row in `public.tenant` for the given UUID |
| `TenantAlreadyMigrating` | 409 | `tenant.status = 'MIGRATING'` already set |
| `RemoteConnectionFailed` | 502 | Cannot connect to `db_host` for smoke test |
| `DumpFailed` | 500 | `pg_dump` subprocess returned non-zero |
| `InvalidDbHost` | 400 | `db_host` fails the `[a-zA-Z0-9._-]+` validation |
| `PoolExhausted` | 503 | No pool connection available for admin query |
| `PersistenceFailed` | 500 | UPDATE to `tenant_schemas` failed |

### TNT-07 pre-flight abort

The pre-flight check uses `RAISE EXCEPTION` inside the migration's DO block.
This causes the migration runner (`src/db/migrations.zig` — `Migrations.run`)
to receive a `MigrationError.MigrationFailed` error, which it propagates to the
caller. The exception message includes the list of unready tenant IDs.

---

## Key invariants

1. **Backfill idempotency.** Every INSERT in GBL-075 uses `ON CONFLICT DO NOTHING`.
   Every DELETE in Step 5b is scoped to `WHERE tenant_id = <uuid>` and is safe
   to re-run (deleting zero rows is not an error). Re-running the migration after
   a partial failure produces the same final state as a successful first run.

2. **Migration window flag.** `onboarding_registry.migration_window_active` is set
   to `TRUE` at the start of GBL-075 and reset to `FALSE` at completion. This
   suppresses audit ERROR entries (degrades to WARN) during the copy window, per
   the TNT-04 audit contract.

3. **TNT-07 gate.** GBL-077 makes zero DDL changes if the pre-flight check fails.
   The migration runner sees `MigrationError.MigrationFailed` and does not record
   the migration as applied in `public.schema_migrations`. Re-running after fixing
   the blocking tenants is safe.

4. **Single-server fallback.** When `tenant_schemas.db_host IS NULL`, `pool.zig`
   behaves identically to the pre-TNT-06 state. No configuration change is needed
   for single-server deployments.

5. **bpm_effective_tenant_id backward compatibility.** The `set_config` calls in
   `applyRequestTenantContext` (added in TNT-03 for backward compatibility with
   RLS) must remain until GBL-077 drops the RLS policies. BACKEND-DEV must remove
   those `set_config` calls from pool.zig only after GBL-077 has been applied in
   the test environment.

6. **db_host host-only substitution.** `buildTenantDsn` replaces only the `host=`
   component of the DSN. Port, user, password, and database name are preserved
   from `BPM_DB_URL`. This ensures the same schema and credentials work on the
   target server (standard pg_dump / pg_restore assumption).

7. **Orphan rows.** Rows whose `tenant_id` is not in `public.tenant` are written
   to `tnt05_orphans` and left in the source `public` table. They are not migrated
   and not deleted by TNT-05. Cleanup of orphan rows requires a separate manual
   step after human review of `tnt05_orphans`.

---

## Dependencies on existing modules

| Module | Dependency type | Notes |
|---|---|---|
| `src/db/pool.zig` | Modified | TNT-06: add `_remote_host` field, `resolveDbHostForTenant`, `buildTenantDsn`; modify `acquire`/`release` |
| `src/bootstrap/audit.zig` | Modified | Add `tnt05_progress`, `tnt05_orphans` to `PERMITTED_PUBLIC_TABLES` |
| `src/admin/tenant_migration.zig` | New file | Export/import admin handlers |
| `src/api/routes/admin.zig` | Modified | Register new export/import routes |
| `src/api/middleware/auth.zig` or new middleware | Modified | Check `tenant.status = 'MIGRATING'` for write requests |
| `migrations/GBL-074_tnt05_backfill_tracking.sql` | New migration | `tnt05_progress`, `tnt05_orphans` tables |
| `migrations/GBL-075_tnt05_backfill_run.sql` | New migration | Backfill algorithm |
| `migrations/GBL-076_tnt06_db_host_column.sql` | New migration | `db_host` column + MIGRATING status |
| `migrations/GBL-077_tnt07_rls_cleanup.sql` | New migration | Pre-flight check + RLS/tenant_id removal |
| `public.onboarding_registry` | Read/write | Migration window flag; must have `migration_window_active` column (from mig 071) |
| `public.tenant` | Read/write | TNT-06 MIGRATING status; TNT-05 tenant enumeration |
| `public.tenant_schemas` | Modified | TNT-06 `db_host` column |
| `public.tnt05_progress` | New table | Per-tenant per-table backfill progress |
| `public.tnt05_orphans` | New table | Orphan row log for manual review |

---

## Open questions

None. All design decisions are resolved from the requirement files, the existing
Batch 1 design (tnt-01-04-schema-isolation.md), and the current migration state
(highest migration is GBL-073).
