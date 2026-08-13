//! PRM-06 §3: sandbox fixture loader.
//!
//! Inserts a fixed list of fixture rows into the sandbox schema's allowlisted
//! tables, after TRUNCATE-ing each distinct table. The allowlist is the
//! SQL-injection boundary: `table_name` values are checked against a
//! hardcoded set, never string-interpolated into DDL.
//!
//! Design artefact: src/design/prm-batch1-promotion-assertion-rerun.md

const std = @import("std");
const pool_mod = @import("pool");

pub const FixtureRow = struct {
    table_name: []const u8,
    row_json: []const u8,
};

pub const FixtureLoadError = error{
    /// table_name not in the allowlist. Hard SQL-injection boundary.
    InvalidTableName,
    InsertFailed,
    PoolExhausted,
    OutOfMemory,
};

/// Hardcoded allowlist of fixture target tables. Tables are written
/// unqualified (search_path resolves them to the sandbox schema). Backends
/// that need additional tables for entity-subsystem fixtures should extend
/// this list as a follow-up (per Open question OQ-2 in the design).
const ALLOWLIST: []const []const u8 = &.{
    "process_definitions",
    "variable_schemas",
    "instances",
};

/// Load fixtures into the sandbox schema:
///   1. Validate every distinct table_name against ALLOWLIST.
///   2. TRUNCATE each distinct table (CASCADE; bare-name resolves to the
///      sandbox schema because the caller has SET search_path).
///   3. INSERT each row via jsonb_populate_record bound as $1.
///
/// On any error the function returns and leaves the sandbox in whatever
/// state it reached; the defer in the assertion re-run pipeline still
/// releases the sandbox.
pub fn loadFixturesOnly(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    sandbox_schema: []const u8,
    fixtures: []const FixtureRow,
) FixtureLoadError!void {
    if (fixtures.len == 0) return;

    const conn = pool.acquire() catch |err| {
        return switch (err) {
            pool_mod.PoolError.ExhaustedPool => FixtureLoadError.PoolExhausted,
            else => FixtureLoadError.InsertFailed,
        };
    };
    defer pool.release(conn);

    // Snapshot search_path and switch to the sandbox schema for the
    // duration of the load. The original search_path is restored on
    // return; the next caller (the assertion replay) is responsible for
    // re-establishing its own search_path.
    const set_stmt = std.fmt.allocPrint(allocator, "SET search_path TO {s}, public", .{sandbox_schema}) catch
        return FixtureLoadError.OutOfMemory;
    defer allocator.free(set_stmt);
    conn.simpleQuery(set_stmt) catch return FixtureLoadError.InsertFailed;
    defer conn.simpleQuery("SET search_path TO public") catch {};

    // Distinct table_name list (preserve insertion order; first-seen wins).
    var distinct = std.ArrayList([]const u8).empty;
    defer distinct.deinit(allocator);
    for (fixtures) |f| {
        var seen = false;
        for (distinct.items) |t| {
            if (std.mem.eql(u8, t, f.table_name)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            distinct.append(allocator, f.table_name) catch return FixtureLoadError.OutOfMemory;
        }
    }

    // Validate every table_name against the allowlist.
    for (distinct.items) |t| {
        var allowed = false;
        for (ALLOWLIST) |a| {
            if (std.mem.eql(u8, a, t)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return FixtureLoadError.InvalidTableName;
    }

    // TRUNCATE each distinct table.
    for (distinct.items) |t| {
        const stmt = std.fmt.allocPrint(allocator, "TRUNCATE {s} CASCADE", .{t}) catch
            return FixtureLoadError.OutOfMemory;
        defer allocator.free(stmt);
        conn.simpleQuery(stmt) catch return FixtureLoadError.InsertFailed;
    }

    // INSERT each row.
    for (fixtures) |f| {
        const stmt = std.fmt.allocPrint(
            allocator,
            "INSERT INTO {s} SELECT * FROM jsonb_populate_record(NULL::{s}, $1::jsonb)",
            .{ f.table_name, f.table_name },
        ) catch return FixtureLoadError.OutOfMemory;
        defer allocator.free(stmt);

        conn.queryRow(allocator, stmt, &[_][]const u8{f.row_json}) catch |err| {
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => FixtureLoadError.PoolExhausted,
                else => FixtureLoadError.InsertFailed,
            };
        };
    }
}
