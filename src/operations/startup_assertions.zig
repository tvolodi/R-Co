const std = @import("std");
const db_pool = @import("pool");
const obs_logger = @import("../obs/logger.zig");

pub const StartupAssertionError = error{
    PgVersionMismatch,
    PgExtensionMissing,
    PublicSchemaPollution,
    QueryFailed,
};

/// Assert database configuration meets application requirements.
/// Emits a FATAL log line and returns error on any violation.
/// This function MUST be called immediately after Pool.init and before
/// any application logic that depends on database state.
pub fn assertDatabaseConfiguration(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
) StartupAssertionError!void {
    // 1. Check PostgreSQL version (must be >= 14.0, which is 140000 as an integer)
    const version_num = queryVersionNum(allocator, pool) catch |err| {
        const fields = [_]obs_logger.LogField{
            .{ .key = "query", .value = .{ .string = "server_version_num" } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "startup.database", "QUERY_FAILED query=server_version_num", &fields) catch {};
        return StartupAssertionError.QueryFailed;
    };

    const required_min: u32 = 140000; // PostgreSQL 14.0.0
    if (version_num < required_min) {
        const fields = [_]obs_logger.LogField{
            .{ .key = "current", .value = .{ .integer = @as(i64, @intCast(version_num)) } },
            .{ .key = "required_min", .value = .{ .integer = @as(i64, @intCast(required_min)) } },
        };

        // Emit exact FATAL line format for alert routing
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "FATAL startup.database PG_VERSION_MISMATCH current={d} required_min={d}", .{ version_num, required_min }) catch "FATAL startup.database PG_VERSION_MISMATCH";
        obs_logger.log(allocator, .ERROR, "startup.database", msg, &fields) catch {};
        return StartupAssertionError.PgVersionMismatch;
    }

    // 2. Check that pg_trgm extension is installed
    const has_trgm = queryExtensionExists(allocator, pool, "pg_trgm") catch |err| {
        const fields = [_]obs_logger.LogField{
            .{ .key = "query", .value = .{ .string = "pg_extension" } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "startup.database", "QUERY_FAILED query=pg_extension", &fields) catch {};
        return StartupAssertionError.QueryFailed;
    };

    if (!has_trgm) {
        const fields = [_]obs_logger.LogField{
            .{ .key = "extension", .value = .{ .string = "pg_trgm" } },
        };

        // Emit exact FATAL line format for alert routing
        obs_logger.log(allocator, .ERROR, "startup.database", "FATAL startup.database PG_EXTENSION_MISSING extension=pg_trgm", &fields) catch {};
        return StartupAssertionError.PgExtensionMissing;
    }

    // 3. Check that public schema has no unexpected tables
    const table_count = queryPublicTableCount(allocator, pool) catch |err| {
        const fields = [_]obs_logger.LogField{
            .{ .key = "query", .value = .{ .string = "pg_tables" } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "startup.database", "QUERY_FAILED query=pg_tables", &fields) catch {};
        return StartupAssertionError.QueryFailed;
    };

    if (table_count > 0) {
        const fields = [_]obs_logger.LogField{
            .{ .key = "table_count", .value = .{ .integer = @as(i64, @intCast(table_count)) } },
            .{ .key = "expected", .value = .{ .integer = 0 } },
        };

        // Emit exact FATAL line format for alert routing
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "FATAL startup.database PUBLIC_SCHEMA_POLLUTION table_count={d} expected=0", .{table_count}) catch "FATAL startup.database PUBLIC_SCHEMA_POLLUTION";
        obs_logger.log(allocator, .ERROR, "startup.database", msg, &fields) catch {};
        return StartupAssertionError.PublicSchemaPollution;
    }

    // All checks passed
}

/// Query PostgreSQL version as an integer (e.g., 140000 for 14.0.0)
fn queryVersionNum(allocator: std.mem.Allocator, pool: *db_pool.Pool) !u32 {
    var conn = try pool.acquire();
    defer pool.release(conn);

    const query = "SELECT current_setting('server_version_num')::int";
    const params: []const []const u8 = &[_][]const u8{};
    var result = try conn.query(allocator, query, params);
    defer result.deinit();

    if (result.rows.len == 0 or result.rows[0][0] == null) return error.QueryFailed;
    const version_str = result.rows[0][0].?;
    return try std.fmt.parseInt(u32, version_str, 10);
}

/// Check if a PostgreSQL extension is installed
fn queryExtensionExists(allocator: std.mem.Allocator, pool: *db_pool.Pool, extension_name: []const u8) !bool {
    var conn = try pool.acquire();
    defer pool.release(conn);

    const query = "SELECT 1 FROM pg_extension WHERE extname = $1";
    const params = [_][]const u8{extension_name};
    var result = try conn.query(allocator, query, &params);
    defer result.deinit();

    return result.rows.len > 0;
}

/// Count tables in the public schema (excludes system tables)
fn queryPublicTableCount(allocator: std.mem.Allocator, pool: *db_pool.Pool) !u32 {
    var conn = try pool.acquire();
    defer pool.release(conn);

    const query = "SELECT count(*)::int FROM pg_tables WHERE schemaname = 'public'";
    const params: []const []const u8 = &[_][]const u8{};
    var result = try conn.query(allocator, query, params);
    defer result.deinit();

    if (result.rows.len == 0 or result.rows[0][0] == null) return error.QueryFailed;
    const count_str = result.rows[0][0].?;
    return try std.fmt.parseInt(u32, count_str, 10);
}

// Test-only variant that accepts overrides for version, extensions, and public table count.
// Pass non-null values to bypass the corresponding real DB query.
pub fn assertDatabaseConfigurationWithOverrides(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    version_override: ?u32,
    extensions_override: ?[]const []const u8,
    public_table_count_override: ?u32,
) StartupAssertionError!void {
    // 1. Check PostgreSQL version
    const version_num = if (version_override) |v| v else queryVersionNum(allocator, pool) catch |err| {
        const fields = [_]obs_logger.LogField{
            .{ .key = "query", .value = .{ .string = "server_version_num" } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "startup.database", "QUERY_FAILED query=server_version_num", &fields) catch {};
        return StartupAssertionError.QueryFailed;
    };

    const required_min: u32 = 140000;
    if (version_num < required_min) {
        const fields = [_]obs_logger.LogField{
            .{ .key = "current", .value = .{ .integer = @as(i64, @intCast(version_num)) } },
            .{ .key = "required_min", .value = .{ .integer = @as(i64, @intCast(required_min)) } },
        };

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "FATAL startup.database PG_VERSION_MISMATCH current={d} required_min={d}", .{ version_num, required_min }) catch "FATAL startup.database PG_VERSION_MISMATCH";
        obs_logger.log(allocator, .ERROR, "startup.database", msg, &fields) catch {};
        return StartupAssertionError.PgVersionMismatch;
    }

    // 2. Check pg_trgm extension
    const has_trgm = if (extensions_override) |exts| blk: {
        for (exts) |ext| {
            if (std.mem.eql(u8, ext, "pg_trgm")) break :blk true;
        }
        break :blk false;
    } else queryExtensionExists(allocator, pool, "pg_trgm") catch |err| {
        const fields = [_]obs_logger.LogField{
            .{ .key = "query", .value = .{ .string = "pg_extension" } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "startup.database", "QUERY_FAILED query=pg_extension", &fields) catch {};
        return StartupAssertionError.QueryFailed;
    };

    if (!has_trgm) {
        const fields = [_]obs_logger.LogField{
            .{ .key = "extension", .value = .{ .string = "pg_trgm" } },
        };
        obs_logger.log(allocator, .ERROR, "startup.database", "FATAL startup.database PG_EXTENSION_MISSING extension=pg_trgm", &fields) catch {};
        return StartupAssertionError.PgExtensionMissing;
    }

    // 3. Check public schema pollution
    const table_count = if (public_table_count_override) |count| count else queryPublicTableCount(allocator, pool) catch |err| {
        const fields = [_]obs_logger.LogField{
            .{ .key = "query", .value = .{ .string = "pg_tables" } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
        };
        obs_logger.log(allocator, .ERROR, "startup.database", "QUERY_FAILED query=pg_tables", &fields) catch {};
        return StartupAssertionError.QueryFailed;
    };

    if (table_count > 0) {
        const fields = [_]obs_logger.LogField{
            .{ .key = "table_count", .value = .{ .integer = @as(i64, @intCast(table_count)) } },
            .{ .key = "expected", .value = .{ .integer = 0 } },
        };

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "FATAL startup.database PUBLIC_SCHEMA_POLLUTION table_count={d} expected=0", .{table_count}) catch "FATAL startup.database PUBLIC_SCHEMA_POLLUTION";
        obs_logger.log(allocator, .ERROR, "startup.database", msg, &fields) catch {};
        return StartupAssertionError.PublicSchemaPollution;
    }
}
