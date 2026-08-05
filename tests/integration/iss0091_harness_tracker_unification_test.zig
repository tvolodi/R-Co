// tests/integration/iss0091_harness_tracker_unification_test.zig
// Requirements: ISS-504 (regression scope extended by ISS-0091 / GitHub #343)
//
// Regression test for ISS-0091: verifies that TestHarness.init() (the test
// harness's migration bootstrapper) and a direct bpm.migrations.Migrations.
// runForSchema() call (mirroring how tests/integration/iss102_claim_test.zig's
// own makePool() applies migrations, bypassing TestHarness) observe the exact
// same set of applied-migration state in public.schema_migrations for the
// tenant_default schema. Before the ISS-0091 fix, TestHarness maintained its
// own independent, schema-local schema_migrations tracking table, so a
// migration recorded "applied" by one tracker was invisible to the other —
// this test would have failed (or the direct runForSchema() call below would
// have hit the same "already exists" collision the bug report describes) on
// pre-fix code once migration 047's rename lineage (047 -> 072) had occurred
// against a schema initialized only by TestHarness.
//
// BPM_TEST_DB_URL must be set. Tests connect to a real PostgreSQL — no mocks.
// No SkipZigTest on MUST tests.

const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const build_options = @import("build_options");

pub const api_tenant_context = bpm.api_tenant_context;
pub const api_pipeline_context = bpm.api_pipeline_context;

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0091 regression tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// TC-ISS-0091-01: TestHarness.init() and a direct Migrations.runForSchema()
// call against tenant_default agree on applied-migration state.
// ---------------------------------------------------------------------------
test "TC-ISS-0091-01: TestHarness and direct runForSchema agree on tenant_default migration state" {
    const alloc = std.testing.allocator;

    // Step 1: TestHarness.init() applies migrations to tenant_default via the
    // (post-fix) real Migrations.runForSchema() path.
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    var before_result = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM public.schema_migrations WHERE schema_name = 'tenant_default'",
        &.{},
    );
    defer before_result.deinit();
    const before_count: i64 = blk: {
        if (before_result.rows.len > 0) {
            if (before_result.rows[0][0]) |s| break :blk try std.fmt.parseInt(i64, s, 10);
        }
        break :blk 0;
    };
    try std.testing.expect(before_count > 0);

    // Step 2: independently call the real migrator directly against the same
    // schema, mirroring iss102_claim_test.zig's makePool() pattern (this is
    // the exact call path that ISS-0091's bug report describes as the one
    // that used to observe a different, incomplete migration ledger).
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{
        .url = url,
        .pool_size = 2,
    });
    defer pool.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        // force_reconcile=false: this test exercises harness-vs-direct
        // migration-state agreement on a clean baseline. Drift reapply is
        // explicitly out of scope for TC-ISS-0091-01.
        try bpm.migrations.Migrations.runForSchema(
            arena.allocator(),
            &pool,
            build_options.migrations_dir,
            "tenant_default",
            false,
        );
    }

    // Step 3: the direct call must be a no-op (idempotent) against the exact
    // same ledger TestHarness already populated — no new rows, no errors,
    // and critically no "already exists" DDL collision.
    var after_result = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM public.schema_migrations WHERE schema_name = 'tenant_default'",
        &.{},
    );
    defer after_result.deinit();
    const after_count: i64 = blk: {
        if (after_result.rows.len > 0) {
            if (after_result.rows[0][0]) |s| break :blk try std.fmt.parseInt(i64, s, 10);
        }
        break :blk 0;
    };

    try std.testing.expectEqual(before_count, after_count);

    // Step 4: specifically confirm migration 047 (the constraint whose
    // rename lineage triggered the original bug) is recorded exactly once,
    // and is visible to both trackers because there is now only one tracker.
    var mig047_result = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM public.schema_migrations WHERE schema_name = 'tenant_default' AND version = '047_repository_form_schemas.sql'",
        &.{},
    );
    defer mig047_result.deinit();
    if (mig047_result.rows.len > 0) {
        if (mig047_result.rows[0][0]) |s| {
            const n = try std.fmt.parseInt(i64, s, 10);
            try std.testing.expectEqual(@as(i64, 1), n);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0091-02: no schema-local schema_migrations divergence remains — the
// harness no longer creates a second, independent tracker.
// ---------------------------------------------------------------------------
test "TC-ISS-0091-02: schema_migrations resolves to the single canonical table under tenant search_path" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // With search_path = tenant_default,public (set by TestHarness.init()),
    // an unqualified `schema_migrations` reference must resolve to
    // public.schema_migrations (since no tenant-local copy is created
    // anymore) — but that table holds rows for EVERY schema, not just
    // tenant_default, so the unqualified query must be filtered the same way
    // the qualified one below is to be a fair comparison.
    var unqualified_result = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM schema_migrations WHERE schema_name = 'tenant_default'",
        &.{},
    );
    defer unqualified_result.deinit();
    const unqualified_count: i64 = blk: {
        if (unqualified_result.rows.len > 0) {
            if (unqualified_result.rows[0][0]) |s| break :blk try std.fmt.parseInt(i64, s, 10);
        }
        break :blk 0;
    };

    var qualified_result = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM public.schema_migrations WHERE schema_name = 'tenant_default'",
        &.{},
    );
    defer qualified_result.deinit();
    const qualified_count: i64 = blk: {
        if (qualified_result.rows.len > 0) {
            if (qualified_result.rows[0][0]) |s| break :blk try std.fmt.parseInt(i64, s, 10);
        }
        break :blk 0;
    };

    try std.testing.expectEqual(qualified_count, unqualified_count);

    // Confirm no stray schema-local schema_migrations table exists inside
    // tenant_default itself (as opposed to resolving there via search_path).
    var local_table_result = try h.conn.query(
        alloc,
        \\SELECT COUNT(*) FROM pg_tables
        \\WHERE schemaname = 'tenant_default' AND tablename = 'schema_migrations'
    ,
        &.{},
    );
    defer local_table_result.deinit();
    const local_table_count: i64 = blk: {
        if (local_table_result.rows.len > 0) {
            if (local_table_result.rows[0][0]) |s| break :blk try std.fmt.parseInt(i64, s, 10);
        }
        break :blk 0;
    };
    try std.testing.expectEqual(@as(i64, 0), local_table_count);
}
