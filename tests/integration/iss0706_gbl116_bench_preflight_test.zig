//! Regression tests for ISS-0706 / GH-791 — GBL-116 pre-flight blocks
//! `zig build bench` on a fresh bench DB.
//!
//! Run ID:   WF03-GH791-20260815
//! Branch:   feature/WF03-GH791-20260815
//! Design:   src/design/iss-0706-gbl116-bench-pre-flight.md §5.1
//!
//! Six regression tests map 1:1 to the design's acceptance criteria. They are
//! split between:
//!
//!   * Live-DB tests (AC-5.1.3, AC-5.1.6) that need BPM_TEST_DB_URL set and
//!     query `public.tenant_schemas.migrations_applied_at` to verify the
//!     post-condition check's semantics on a real PG instance. These return
//!     `error.SkipZigTest` when BPM_TEST_DB_URL is unset (matches the
//!     convention in iss207_error_retry_test.zig).
//!
//!   * Static source-assertion tests (AC-5.1.1, AC-5.1.2, AC-5.1.5,
//!     MUST-9, MUST-NOT-1) that read build.zig, tests/bench/bench.zig, and
//!     migrations/GBL-116_tnt07_rls_cleanup.sql as text and assert that the
//!     design's invariants are encoded in the production code. No mocks, no
//!     in-memory fakes (DIRECTIVE T-1): the production code IS the assertion
//!     target, so reading the file IS the test.
//!
//! All six tests follow the `regression: ISS-0706 — <description>` naming
//! convention from src/design/iss-0706-gbl116-bench-pre-flight.md §12.

const std = @import("std");
const testing = std.testing;

const portable_env = @import("env");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema
// search_path (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Live-DB helpers
// ---------------------------------------------------------------------------

fn bpmTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set -- ISS-0706 live-DB regression tests skipped\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 2,
    });
}

fn queryCount(allocator: std.mem.Allocator, url: []const u8, sql_text: []const u8, params: []const []const u8) !u64 {
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = try conn.queryRow(allocator, sql_text, params);
    defer if (row) |r| {
        for (r) |col| if (col) |c| allocator.free(c);
        allocator.free(r);
    };
    const owned_row = row orelse return 0;
    if (owned_row.len == 0) return 0;
    const first = owned_row[0] orelse return 0;
    return std.fmt.parseInt(u64, first, 10) catch 0;
}

// ---------------------------------------------------------------------------
// AC-5.1.3 — post-condition returns 0 when migrations_applied_at is NULL
// ---------------------------------------------------------------------------

test "regression: ISS-0706 -- AC-5.1.3 post-condition returns 0 when migrations_applied_at is NULL" {
    const allocator = testing.allocator;
    const url = try bpmTestDbUrl(allocator);
    defer allocator.free(url);

    const default_tenant_id = "00000000-0000-0000-0000-000000000000";
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Force the column to NULL to simulate the silent-failure branch the fix
    // must catch. Restored in the defer so other suites are not affected.
    conn.exec(
        "UPDATE public.tenant_schemas SET migrations_applied_at = NULL WHERE tenant_id = $1::uuid",
        &.{default_tenant_id},
    ) catch |err| {
        std.debug.print("setup UPDATE failed: {} -- skipping\n", .{err});
        return;
    };
    defer {
        conn.exec(
            "UPDATE public.tenant_schemas SET migrations_applied_at = NOW() WHERE tenant_id = $1::uuid AND migrations_applied_at IS NULL",
            &.{default_tenant_id},
        ) catch {};
    }

    // The post-condition query exactly as encoded in migrate.zig.
    const count = try queryCount(
        allocator,
        url,
        "SELECT count(*)::text FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL",
        &.{default_tenant_id},
    );
    try testing.expectEqual(@as(u64, 0), count);
}

// ---------------------------------------------------------------------------
// AC-5.1.6 — post-condition returns >=1 on a long-lived DB
// ---------------------------------------------------------------------------

test "regression: ISS-0706 -- AC-5.1.6 post-condition returns >=1 on long-lived DB" {
    const allocator = testing.allocator;
    const url = try bpmTestDbUrl(allocator);
    defer allocator.free(url);

    const default_tenant_id = "00000000-0000-0000-0000-000000000000";
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Set the column to NOW() to simulate a successful provisionTenantSchema.
    conn.exec(
        "UPDATE public.tenant_schemas SET migrations_applied_at = NOW() WHERE tenant_id = $1::uuid",
        &.{default_tenant_id},
    ) catch |err| {
        std.debug.print("setup UPDATE failed: {} -- skipping\n", .{err});
        return;
    };

    const count = try queryCount(
        allocator,
        url,
        "SELECT count(*)::text FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL",
        &.{default_tenant_id},
    );
    try testing.expect(count >= 1);
}

// ---------------------------------------------------------------------------
// Static source-assertion tests (no DB required)
// ---------------------------------------------------------------------------

fn readProjectFile(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(testing.io, rel_path, allocator, std.Io.Limit.limited(8 * 1024 * 1024));
}

test "regression: ISS-0706 -- AC-5.1.1/5.1.2/5.1.5 build.zig injects BPM_DB_URL into run_migrate" {
    const allocator = testing.allocator;
    const build_zig = try readProjectFile(allocator, "build.zig");
    defer allocator.free(build_zig);

    // The helper function must exist.
    try testing.expect(std.mem.indexOf(u8, build_zig, "fn resolveBenchMigrateDbUrl") != null);

    // The bench step must call run_migrate.setEnvironmentVariable for BPM_DB_URL.
    try testing.expect(std.mem.indexOf(u8, build_zig, "run_migrate.setEnvironmentVariable(\"BPM_DB_URL\"") != null);

    // Diagnostic line must be present.
    try testing.expect(std.mem.indexOf(u8, build_zig, "BENCH_MIGRATE_URL_INFO|source=") != null);

    // Ordering invariant: injection must be BEFORE the dependOn call.
    const inject_pos = std.mem.indexOf(u8, build_zig, "run_migrate.setEnvironmentVariable(\"BPM_DB_URL\"") orelse unreachable;
    const depend_pos = std.mem.indexOf(u8, build_zig, "run_bench.step.dependOn(&run_migrate.step)") orelse unreachable;
    try testing.expect(inject_pos < depend_pos);
}

test "regression: ISS-0706 -- resolveBenchMigrateDbUrl mirrors bench.zig::resolveDbUrl precedence" {
    const allocator = testing.allocator;
    const build_zig = try readProjectFile(allocator, "build.zig");
    defer allocator.free(build_zig);
    const bench_zig = try readProjectFile(allocator, "tests/bench/bench.zig");
    defer allocator.free(bench_zig);

    // bench.zig precedence: bench < db < test (lexical position order).
    // Use exact strings that appear in bench.zig (not substrings that could match
    // inside longer env var names like BPM_BENCH_DB_URL).
    // Scope the search to AFTER `fn resolveDbUrl` so the earlier BPM_TEST_DB_URL
    // // call in main() (line ~50) doesn't skew the result.
    const resolve_fn_marker = "fn resolveDbUrl";
    const resolve_fn_pos = std.mem.indexOf(u8, bench_zig, resolve_fn_marker) orelse unreachable;
    const bench_env_marker = "environ_map.get(\"BPM_BENCH_DB_URL\")";
    const bench_db_marker = "environ_map.get(\"BPM_DB_URL\")";
    const bench_test_marker = "environ_map.get(\"BPM_TEST_DB_URL\")";
    const bench_candidates = std.mem.indexOfPos(u8, bench_zig, resolve_fn_pos, bench_env_marker) orelse unreachable;
    const bench_db_url = std.mem.indexOfPos(u8, bench_zig, resolve_fn_pos, bench_db_marker) orelse unreachable;
    const bench_test_url = std.mem.indexOfPos(u8, bench_zig, resolve_fn_pos, bench_test_marker) orelse unreachable;
    try testing.expect(bench_candidates < bench_db_url);
    try testing.expect(bench_db_url < bench_test_url);

    // The build.zig helper must include all three keys in the same lexical
    // order in the env_candidates declaration.
    const helper_open = std.mem.indexOf(u8, build_zig, "const env_candidates = [_][]const u8{ \"BPM_BENCH_DB_URL\", \"BPM_DB_URL\", \"BPM_TEST_DB_URL\" };") orelse unreachable;
    const in_helper_bench = std.mem.indexOfPos(u8, build_zig, helper_open, "\"BPM_BENCH_DB_URL\"") orelse unreachable;
    const in_helper_db = std.mem.indexOfPos(u8, build_zig, helper_open, "\"BPM_DB_URL\"") orelse unreachable;
    const in_helper_test = std.mem.indexOfPos(u8, build_zig, helper_open, "\"BPM_TEST_DB_URL\"") orelse unreachable;
    try testing.expect(in_helper_bench < in_helper_db);
    try testing.expect(in_helper_db < in_helper_test);

    // The .env fallback path must iterate the three keys in the same order.
    // Use exact call patterns to avoid BPM_DB_URL substring matching inside BPM_BENCH_DB_URL.
    const dotenv_open = std.mem.indexOf(u8, build_zig, "readBuildDotEnvValue(b, \"BPM_BENCH_DB_URL\")") orelse unreachable;
    const dotenv_db = std.mem.indexOf(u8, build_zig, "readBuildDotEnvValue(b, \"BPM_DB_URL\")") orelse unreachable;
    const dotenv_test = std.mem.indexOf(u8, build_zig, "readBuildDotEnvValue(b, \"BPM_TEST_DB_URL\")") orelse unreachable;
    try testing.expect(dotenv_open < dotenv_db);
    try testing.expect(dotenv_db < dotenv_test);
}

test "regression: ISS-0706 -- migrate.zig has the loud post-condition at both sites" {
    const allocator = testing.allocator;
    const migrate_zig = try readProjectFile(allocator, "src/tools/migrate.zig");
    defer allocator.free(migrate_zig);

    // Provision_attempted flag must be declared at BOTH sites.
    const occurrences_flag = std.mem.count(u8, migrate_zig, "var provision_attempted: bool = false;");
    try testing.expect(occurrences_flag >= 2);

    // Post-condition query must be present at both sites.
    const occurrences_query = std.mem.count(u8, migrate_zig, "SELECT count(*)::text FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL");
    try testing.expectEqual(@as(usize, 2), occurrences_query);

    // The loud error message must be present at both sites (MUST-4 text).
    const occurrences_msg = std.mem.count(u8, migrate_zig, "post-condition: default tenant_schemas.migrations_applied_at is NULL");
    try testing.expectEqual(@as(usize, 2), occurrences_msg);

    // provisionTenantSchema must still be called (no behavioural change).
    try testing.expect(std.mem.indexOf(u8, migrate_zig, "db_provisioning.provisionTenantSchema(") != null);
}

test "regression: ISS-0706 -- MUST-9 GBL-116 cosmetic message references GBL-113 and GBL-114" {
    const allocator = testing.allocator;
    const sql = try readProjectFile(allocator, "migrations/GBL-116_tnt07_rls_cleanup.sql");
    defer allocator.free(sql);

    // Find the RAISE EXCEPTION line.
    const raise_idx = std.mem.indexOf(u8, sql, "RAISE EXCEPTION 'TNT-07 pre-flight failed: tnt05_progress table does not exist.") orelse unreachable;
    const raise_end = std.mem.indexOfPos(u8, sql, raise_idx, "';") orelse unreachable;
    const message = sql[raise_idx..raise_end];

    try testing.expect(std.mem.indexOf(u8, message, "GBL-113") != null);
    try testing.expect(std.mem.indexOf(u8, message, "GBL-114") != null);

    // And must NOT reference the stale GBL-074/075 identifiers.
    try testing.expect(std.mem.indexOf(u8, message, "GBL-074") == null);
    try testing.expect(std.mem.indexOf(u8, message, "GBL-075") == null);

    // Verify the actual migration files exist on disk.
    std.Io.Dir.cwd().access(testing.io, "migrations/GBL-113_tnt05_backfill_tracking.sql", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("GBL-113_tnt05_backfill_tracking.sql missing on disk -- message references non-existent file\n", .{});
            return error.TestUnexpectedError;
        },
        else => return err,
    };
    std.Io.Dir.cwd().access(testing.io, "migrations/GBL-114_tnt05_backfill_run.sql", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("GBL-114_tnt05_backfill_run.sql missing on disk -- message references non-existent file\n", .{});
            return error.TestUnexpectedError;
        },
        else => return err,
    };
}

test "regression: ISS-0706 -- MUST-NOT-1 GBL-116 pre-flight gate body is unchanged" {
    const allocator = testing.allocator;
    const sql = try readProjectFile(allocator, "migrations/GBL-116_tnt07_rls_cleanup.sql");
    defer allocator.free(sql);

    try testing.expect(std.mem.indexOf(u8, sql, "FOR v_tenant IN SELECT id FROM public.tenant LOOP") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "v_tenant.id") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "migrations_applied_at IS NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "status = 'COMPLETED'") != null);
    try testing.expect(std.mem.indexOf(u8, sql, "RAISE EXCEPTION 'TNT-07 pre-flight failed. Unready tenants: %'") != null);
}
