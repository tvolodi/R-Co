//! TNT-04: Public schema audit — startup check for unexpected tables in public.
//!
//! Queries information_schema.tables for all BASE TABLE and VIEW entries in
//! the public schema and compares against the compile-time permitted list.
//! Unexpected tables are logged at ERROR (or WARN during a migration window).
//! A clean result is logged at INFO.
//!
//! The audit is non-fatal: the server always continues regardless of outcome.
//!
//! Design artefact: src/design/tnt-01-04-schema-isolation.md
const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;
const PoolError = pool_mod.PoolError;
const obs_logger = @import("../obs/logger.zig");

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const AuditError = error{
    /// No connection available at startup audit time.
    PoolExhausted,
    /// information_schema.tables query failed.
    QueryFailed,
};

// ---------------------------------------------------------------------------
// Permitted public table list (TNT-04)
//
// This is the canonical compile-time source of truth.  Any new table that
// must be created in public requires an update here AND in
// docs/requirements/TNT-04.md (per TNT-04 acceptance criterion).
// ---------------------------------------------------------------------------

pub const PERMITTED_PUBLIC_TABLES: []const []const u8 = &.{
    "tenant",
    "tenant_schemas",
    "tenant_hostnames",
    "tenant_realm_binding",
    "schema_migrations",
    "onboarding_registry",
    "service_catalog",
    "repository_artifacts",
    "repository_activations",
    "process_module_catalog",
    "process_module_catalog_share",
    "alerting_state",
    // TNT-05: backfill progress tracking tables (GBL-074)
    "tnt05_progress",
    "tnt05_orphans",
};

// ---------------------------------------------------------------------------
// auditPublicSchema
// ---------------------------------------------------------------------------

/// TNT-04: Query information_schema.tables for public-schema BASE TABLE and
/// VIEW entries; compare against PERMITTED_PUBLIC_TABLES.
///
/// For each unexpected table:
///   - If migration_window_active = TRUE in onboarding_registry: log WARN.
///   - Otherwise: log ERROR.
///
/// If no unexpected tables found: log INFO "public schema audit: CLEAN".
///
/// The audit does NOT hard-stop the server regardless of outcome (TNT-04:
/// "continues, no hard stop, to allow zero-downtime migration windows").
///
/// Call site: src/main.zig — after Pool.init() and Migrations.run() complete,
/// before the HTTP server accept loop.
pub fn auditPublicSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
) AuditError!void {
    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return AuditError.PoolExhausted,
        else => return AuditError.QueryFailed,
    };
    defer pool.release(conn);

    // Check migration_window_active flag first (single round trip, minimises
    // DB traffic per the design decision in tnt-01-04-schema-isolation.md).
    const migration_window_active = blk: {
        const flag_result = conn.query(
            allocator,
            "SELECT migration_window_active FROM public.onboarding_registry LIMIT 1",
            &.{},
        ) catch break :blk false;
        defer {
            var r = flag_result;
            r.deinit();
        }
        if (flag_result.rows.len > 0) {
            const row = flag_result.rows[0];
            if (row.len > 0) {
                if (row[0]) |val| {
                    // PostgreSQL returns boolean as "t" or "f".
                    break :blk std.mem.eql(u8, val, "t") or std.mem.eql(u8, val, "true");
                }
            }
        }
        break :blk false;
    };

    // Query all BASE TABLE and VIEW entries in the public schema.
    const result = conn.query(
        allocator,
        \\SELECT table_name
        \\FROM information_schema.tables
        \\WHERE table_schema = 'public'
        \\  AND table_type IN ('BASE TABLE', 'VIEW')
        \\ORDER BY table_name
    ,
        &.{},
    ) catch return AuditError.QueryFailed;
    defer {
        var r = result;
        r.deinit();
    }

    var found_unexpected = false;
    for (result.rows) |row| {
        if (row.len == 0) continue;
        const table_name = row[0] orelse continue;

        // Check if this table is in the permitted list.
        var permitted = false;
        for (PERMITTED_PUBLIC_TABLES) |allowed| {
            if (std.mem.eql(u8, table_name, allowed)) {
                permitted = true;
                break;
            }
        }
        if (permitted) continue;

        // Unexpected table found.
        found_unexpected = true;
        if (migration_window_active) {
            const fields = [_]obs_logger.LogField{
                .{ .key = "table_name", .value = .{ .string = table_name } },
                .{ .key = "migration_window_active", .value = .{ .boolean = true } },
            };
            obs_logger.log(allocator, .WARN, "bootstrap.audit", "public schema audit: unexpected table (migration window active)", &fields) catch {};
        } else {
            const fields = [_]obs_logger.LogField{
                .{ .key = "table_name", .value = .{ .string = table_name } },
            };
            obs_logger.log(allocator, .ERROR, "bootstrap.audit", "public schema audit: unexpected table", &fields) catch {};
        }
    }

    if (!found_unexpected) {
        obs_logger.log(allocator, .INFO, "bootstrap.audit", "public schema audit: CLEAN", &.{}) catch {};
    }
}
