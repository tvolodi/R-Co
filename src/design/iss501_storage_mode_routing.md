# Module: ISS-501 Storage Mode Routing

## Module purpose

This module extends the tenant-context resolution chain to read `public.tenants.storage_mode` once per request and pin the database `search_path` and session configuration accordingly. During SPT (schema-per-tenant) coexistence, each tenant has exactly one authoritative storage path: `LEGACY_RLS` (existing public-schema + RLS) or `SCHEMA` (dedicated tenant schema). The routing decision is made once at request start and never changes within a single request lifecycle.

## Scope and non-goals

- In scope: reading `storage_mode` during tenant context resolution, pinning `search_path` and session variables for the request duration.
- In scope: error handling for invalid or unknown `storage_mode` values.
- In scope: backward compatibility -- requests without a resolved tenant continue to use the public-schema-only path.
- Out of scope: the SPT cutover transaction itself (ISS-502), RLS removal (ISS-503), per-tenant migration tracking (ISS-504).

## Prerequisites

- ISS-107: `public.tenants.storage_mode` column exists with `CHECK (storage_mode IN ('LEGACY_RLS','SCHEMA'))` and index `idx_tenant_storage_mode`.
- Existing `tenant_context` module provides thread-local `tenant_id`.
- Existing `pool.zig:applyRequestTenantContext()` performs `SET search_path` + `set_config('bpm.tenant_id', ...)` on every acquired connection.

## Public interface

### Tenant context extension

```zig
pub const StorageMode = enum {
    LEGACY_RLS,
    SCHEMA,
};

pub const ResolvedStorageMode = struct {
    mode: StorageMode,
    schema_name: []const u8,  // e.g. "public" or "tenant_a1b2c3..."
};
```

### Storage mode resolution

```zig
/// Resolve storage_mode for a tenant from public.tenants.
/// Must be called AFTER the connection is acquired (needs DB access).
/// Returns LEGACY_RLS for default/empty tenant_id (no-tenant path).
/// Returns error.StorageModeUnknown if the column value is not a recognised mode.
pub fn resolveStorageMode(
    allocator: std.mem.Allocator,
    conn: *Conn,
    tenant_id: []const u8,
) StorageModeError!StorageMode;
```

### Connection routing (replaces applyRequestTenantContext)

```zig
/// Apply storage-mode-aware search_path and session configuration.
/// Called by Pool.acquire() after acquiring a connection.
/// Pins routing once per request; never mixes LEGACY_RLS and SCHEMA paths.
fn applyRequestStorageRouting(conn: *Conn) PoolError!void;
```

## Deterministic routing rules

### No-tenant path (tenant_id empty / default UUID)

1. `SET search_path TO public`
2. No `set_config` calls (no tenant context to propagate).
3. No storage_mode lookup needed.

### LEGACY_RLS path

1. `SET search_path TO public`
2. `SELECT set_config('bpm.tenant_id', $1, false)` -- enables RLS predicates on public tables.
3. `SELECT set_config('bpm.pipeline_run_id', $1, false)` -- if present.

### SCHEMA path

1. `SET search_path TO tenant_{slug},public`
2. No `set_config('bpm.tenant_id', ...)` call -- RLS is inactive in the tenant schema.
3. `SELECT set_config('bpm.pipeline_run_id', $1, false)` -- if present.

### Invariants

- A single request uses exactly one routing path. There is no fallback or retry that switches modes mid-request.
- `storage_mode` is read once from `public.tenants` at the start of the first connection acquisition for a request. The mode is cached in the tenant context for subsequent connection acquisitions in the same request.
- Unknown/invalid storage_mode values (not in the CHECK constraint) produce an error that fails the request with HTTP 500.

## Error taxonomy

```zig
pub const StorageModeError = error{
    /// The storage_mode column value is not a recognised mode.
    /// Should not occur in normal operation (CHECK constraint prevents it),
    /// but handled defensively.
    StorageModeUnknown,
    /// Database query for storage_mode failed.
    StorageModeLookupFailed,
};
```

## Integration points

### pool.zig changes

- `applyRequestTenantContext()` is renamed to `applyRequestStorageRouting()` and refactored to branch on resolved `StorageMode`.
- The storage_mode resolution happens inside `applyRequestStorageRouting()`, which queries `public.tenants` for the mode.
- On the no-tenant path (empty tenant_id), skip the DB lookup entirely.

### tenant_context.zig changes

- Add `threadlocal var _storage_mode: StorageMode = .LEGACY_RLS` and accessors `getStorageMode()` / `setStorageMode()`.
- The mode is set during the first `applyRequestStorageRouting()` call and reused for subsequent connection acquisitions.

### auth.zig changes

- After `tenant_context.set(resolved_tenant.tenant_id[0..])`, the storage mode is not yet resolved (no DB connection available at auth time). It is resolved lazily on first connection acquisition.
- No signature changes required in `AuthContext`.

### resetConnectionSearchPath

- Renamed to `resetConnectionSearchPath` and resets to `SET search_path TO public` regardless of the request's storage mode. This is a release-time operation (connection returning to pool), not request-time.

## Dependencies

- ISS-107: `public.tenants.storage_mode` column (RELEASED).

## Related artefacts

- `src/api/tenant_context.zig` -- thread-local tenant ID and (new) storage mode.
- `src/db/pool.zig` -- connection acquisition, `applyRequestStorageRouting()`, `resetConnectionSearchPath()`.
- `src/api/middleware/auth.zig` -- tenant context resolution triggers storage mode lookup indirectly via pool.
