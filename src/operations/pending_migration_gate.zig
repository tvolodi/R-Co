//! MIG-06 AC5 — boot-time refusal check for outstanding platform migrations.
//!
//! Design artefact: src/design/mig-04-mig-05-mig-06-resume-idempotency-admin-surface.md
//! Depends on: platform.platform_migrations (MIG-01,
//! migrations/1144_platform_migrations_control_table.sql)
//!
//! Follows src/operations/startup_assertions.zig's established shape
//! exactly: own typed error{...} set (mirroring StartupAssertionError's
//! two-tier query-failure-vs-check-failure split), the same
//! `FATAL <component> <CODE> key=value` log-line convention (so the same
//! alert-routing regex that already matches PG_VERSION_MISMATCH /
//! PG_EXTENSION_MISSING / PUBLIC_SCHEMA_POLLUTION also matches this new
//! gate), and the same "call from runApiServer, exit EX_CONFIG (78) on
//! failure, before the server accepts any connection" contract.
const std = @import("std");
const db_pool = @import("pool");
const obs_logger = @import("../obs/logger.zig");

pub const PendingMigrationError = error{
    /// One or more platform.platform_migrations rows are still 'pending' at
    /// boot. The caller (main.zig) exits EX_CONFIG (78) before the server
    /// accepts traffic — MIG-06 AC5.
    OutstandingPendingMigrations,
    /// The pending-row query itself failed (distinct from finding pending
    /// rows) — same two-tier error shape startup_assertions.zig's existing
    /// checks already use.
    QueryFailed,
};

/// Query platform.platform_migrations for any row still 'pending'. If one or
/// more exist, emit a FATAL log line naming the migration_id(s) and return
/// error.OutstandingPendingMigrations. This function MUST be called after
/// Pool.init and before the server accepts any connection — see
/// src/main.zig::runApiServer, immediately after
/// startup_assertions.assertDatabaseConfiguration.
pub fn assertNoOutstandingMigrations(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
) PendingMigrationError!void {
    const migration_ids = queryOutstandingMigrationIds(allocator, pool) catch |err| {
        const fields = [_]obs_logger.LogField{
            .{ .key = "query", .value = .{ .string = "platform_migrations_pending" } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "startup.platform_migrations", "QUERY_FAILED query=platform_migrations_pending", &fields) catch {};
        return PendingMigrationError.QueryFailed;
    };
    defer {
        for (migration_ids) |m| allocator.free(m);
        allocator.free(migration_ids);
    }

    if (migration_ids.len == 0) return;

    const joined = std.mem.join(allocator, ",", migration_ids) catch "unknown";
    defer if (!std.mem.eql(u8, joined, "unknown")) allocator.free(joined);

    const fields = [_]obs_logger.LogField{
        .{ .key = "migration_ids", .value = .{ .string = joined } },
    };

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "FATAL startup.platform_migrations OUTSTANDING_PENDING_MIGRATIONS migration_ids={s}",
        .{joined},
    ) catch "FATAL startup.platform_migrations OUTSTANDING_PENDING_MIGRATIONS";
    obs_logger.log(allocator, .ERROR, "startup.platform_migrations", msg, &fields) catch {};
    return PendingMigrationError.OutstandingPendingMigrations;
}

/// Returns the distinct migration_id values with at least one 'pending' row.
/// Caller owns the returned slice and every string inside it.
fn queryOutstandingMigrationIds(allocator: std.mem.Allocator, pool: *db_pool.Pool) ![][]const u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try conn.query(
        allocator,
        "SELECT DISTINCT migration_id FROM platform.platform_migrations WHERE status = 'pending'",
        &.{},
    );
    defer result.deinit();

    var out = try allocator.alloc([]const u8, result.rows.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |m| allocator.free(m);

    for (result.rows, 0..) |row, i| {
        const migration_id = row[0] orelse return error.QueryFailed;
        out[i] = try allocator.dupe(u8, migration_id);
        filled += 1;
    }

    return out;
}
