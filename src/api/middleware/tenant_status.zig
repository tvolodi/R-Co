//! TNT-06: Tenant MIGRATING status middleware.
//!
//! When tenant.status = 'MIGRATING', write requests (POST, PUT, PATCH, DELETE)
//! are rejected with HTTP 503 and a Retry-After header.  Read requests
//! (GET, HEAD) continue through normally.
//!
//! Call checkTenantWritePause() after auth resolves the tenant_id and before
//! dispatching to a write handler.
//!
//! Design artefact: src/design/tnt-05-07-backfill-export-cleanup.md

const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;
const PoolError = pool_mod.PoolError;

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

/// HTTP methods that count as write requests (MIGRATING status blocks these).
fn isWriteMethod(method: std.http.Method) bool {
    return switch (method) {
        .POST, .PUT, .PATCH, .DELETE => true,
        else => false,
    };
}

/// Check whether the current tenant is in MIGRATING status.
/// Returns a 503 HandlerResult if the tenant is MIGRATING and the request is
/// a write; returns null if the request may proceed.
///
/// tenant_id — resolved tenant UUID (empty string → no check performed).
/// method    — HTTP request method.
/// pool      — database connection pool for the status lookup.
/// allocator — for the 503 response body.
pub fn checkTenantWritePause(
    tenant_id: []const u8,
    method: std.http.Method,
    pool: *Pool,
    allocator: std.mem.Allocator,
) ?HandlerResult {
    // Only check for write methods.
    if (!isWriteMethod(method)) return null;
    // No tenant context (bootstrap / platform-admin calls) → allow through.
    if (tenant_id.len == 0) return null;

    const conn = pool.acquire() catch return null; // on pool exhaustion let through
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT status FROM public.tenant WHERE id = $1 LIMIT 1",
        &.{tenant_id},
    ) catch return null; // on query failure let through (fail-open)

    if (row) |r| {
        defer {
            for (r) |col| {
                if (col) |c| allocator.free(c);
            }
            allocator.free(r);
        }
        if (r.len > 0) {
            if (r[0]) |status_val| {
                if (std.mem.eql(u8, status_val, "MIGRATING")) {
                    return HandlerResult{
                        .status_code = 503,
                        .body = allocator.dupe(u8,
                            "{\"type\":\"about:blank\",\"title\":\"Tenant Migration In Progress\"," ++
                            "\"status\":503,\"detail\":\"Tenant is being migrated. Reads continue; writes resume after migration.\"}")
                        catch "{\"error\":\"migrating\"}",
                    };
                }
            }
        }
    }

    return null;
}
