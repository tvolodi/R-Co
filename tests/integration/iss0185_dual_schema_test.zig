//! ISS-0185 / GitHub tvolodi/R-Co#518 — regression tests for the
//! dual-schema table duplication cleanup.
//!
//! Background:
//!   45 table names existed in BOTH `public` and `tenant_default` schemas
//!   of a freshly migrated database because source migrations defaulted
//!   to `.all_schemas` scope regardless of whether a table's canonical
//!   home is public (GLOBAL_REGISTRY) or the tenant schema (PER_TENANT).
//!   When later GBL-only ALTERs added columns to the public copy alone,
//!   the tenant_default shadow drifted silently (the recurring
//!   ISS-0089/0126/0144/0150 symptom).
//!
//!   After this fix:
//!     - GBL-134 drops 24 GLOBAL_REGISTRY shadow copies from tenant
//!       schemas
//!     - GBL-135 drops 12 PER_TENANT shadow copies from public
//!     - 9 HYBRID tables (artifact_*, oidc_migration_*, repository_artifacts,
//!       tenant, tenant_hostnames, event_type_registry_producers) are
//!       legitimately present in both schemas and are NOT touched
//!     - tools/lint_dual_schema_table_names.py enforces this state on
//!       every future migration run
//!
//! Test infrastructure: per-test UUIDs, BPM_TEST_DB_URL gate, real
//! PostgreSQL. DIRECTIVE T-1 — no mocks, no stubs, no error.SkipZigTest.
const std = @import("std");
const portable_env = @import("env");
const builtin = @import("builtin");
const helpers = @import("helpers.zig");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS — add a platform branch"),
    }
}

fn requireTestDatabaseUrl(allocator: std.mem.Allocator) !void {
    const env = portable_env.globalEnviron();
    const url = env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0185 integration tests (test infrastructure unavailable)\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
    allocator.free(url);
}

/// Read information_schema.tables and count rows matching the given
/// schema+name predicate. Returns -1 on connection error.
fn countTablesMatching(
    harness: *helpers.TestHarness,
    allocator: std.mem.Allocator,
    schema: []const u8,
    table_name: []const u8,
) !i64 {
    const sql = try std.fmt.allocPrint(
        allocator,
        "SELECT count(*)::bigint FROM information_schema.tables WHERE table_schema = '{s}' AND table_name = '{s}'",
        .{ schema, table_name },
    );
    defer allocator.free(sql);

    var result = try harness.conn.query(allocator, sql, &.{});
    defer result.deinit();

    if (result.rows.len == 0) return -1;
    const cell = result.rows[0][0] orelse return -1;
    return std.fmt.parseInt(i64, cell, 10) catch -1;
}

// ---------------------------------------------------------------------------
// TC-ISS-0185-01 — GLOBAL shadow dropped from tenant_default
// ---------------------------------------------------------------------------

test "TC-ISS-0185-01: GLOBAL tables exist in public but not in tenant_default" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var harness = try helpers.TestHarness.init(allocator);
    defer harness.deinit();

    // Spot-check: pick three representative GLOBAL_REGISTRY tables
    // (one from agent/idp/oidc families). Each MUST be present in
    // public and absent from tenant_default.
    const checks = [_][]const u8{
        "agent_bootstrap_audit",
        "idp_operation_ledger",
        "realm_deletion_tracker",
    };

    for (checks) |name| {
        const pub_count = try countTablesMatching(&harness, allocator, "public", name);
        const ten_count = try countTablesMatching(&harness, allocator, "tenant_default", name);

        try std.testing.expectEqual(@as(i64, 1), pub_count);
        try std.testing.expectEqual(@as(i64, 0), ten_count);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0185-02 — PER_TENANT shadow dropped from public
// ---------------------------------------------------------------------------

test "TC-ISS-0185-02: PER_TENANT tables exist in tenant_default but not in public" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var harness = try helpers.TestHarness.init(allocator);
    defer harness.deinit();

    // Spot-check: pick three representative PER_TENANT tables.
    // Each MUST be present in tenant_default and absent from public.
    const checks = [_][]const u8{
        "group_roles",
        "webhook_deliveries",
        "subprocess_links",
    };

    for (checks) |name| {
        const pub_count = try countTablesMatching(&harness, allocator, "public", name);
        const ten_count = try countTablesMatching(&harness, allocator, "tenant_default", name);

        try std.testing.expectEqual(@as(i64, 0), pub_count);
        try std.testing.expectEqual(@as(i64, 1), ten_count);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0185-03 — HYBRID tables still exist in both schemas
// ---------------------------------------------------------------------------

test "TC-ISS-0185-03: HYBRID tables remain in both public and tenant_default" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var harness = try helpers.TestHarness.init(allocator);
    defer harness.deinit();

    // 9 HYBRID table names must remain in BOTH schemas (verified by
    // tools/lint_dual_schema_table_names.py allow-list).
    const hybrids = [_][]const u8{
        "artifact_activation_history",
        "artifact_activations",
        "artifact_versions",
        "event_type_registry_producers",
        "oidc_migration_item",
        "oidc_migration_job",
        "repository_artifacts",
        "tenant",
        "tenant_hostnames",
    };

    for (hybrids) |name| {
        const pub_count = try countTablesMatching(&harness, allocator, "public", name);
        const ten_count = try countTablesMatching(&harness, allocator, "tenant_default", name);

        try std.testing.expectEqual(@as(i64, 1), pub_count);
        try std.testing.expectEqual(@as(i64, 1), ten_count);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0185-04 — total duplicate count is exactly 9 (the HYBRID set)
// ---------------------------------------------------------------------------

test "TC-ISS-0185-04: post-fix duplicate count matches HYBRID allow-list (9)" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var harness = try helpers.TestHarness.init(allocator);
    defer harness.deinit();

    const sql =
        "SELECT count(*)::bigint FROM ( " ++
        "  SELECT table_name FROM information_schema.tables " ++
        "  WHERE table_schema='public' AND table_type='BASE TABLE' " ++
        "  INTERSECT " ++
        "  SELECT table_name FROM information_schema.tables " ++
        "  WHERE table_schema='tenant_default' AND table_type='BASE TABLE' " ++
        ") sub";
    var result = try harness.conn.query(allocator, sql, &.{});
    defer result.deinit();

    var dupe_count: i64 = -1;
    if (result.rows.len > 0) {
        const cell = result.rows[0][0] orelse "-1";
        dupe_count = std.fmt.parseInt(i64, cell, 10) catch -1;
    }

    try std.testing.expectEqual(@as(i64, 9), dupe_count);
}

// ---------------------------------------------------------------------------
// TC-ISS-0185-05 — schema_migrations records GBL-134 and GBL-135 as applied
// ---------------------------------------------------------------------------

test "TC-ISS-0185-05: schema_migrations ledger records GBL-134 and GBL-135" {
    const allocator = std.testing.allocator;
    try requireTestDatabaseUrl(allocator);

    var harness = try helpers.TestHarness.init(allocator);
    defer harness.deinit();

    for ([_][]const u8{
        "GBL-134_iss0185_drop_global_registry_shadows",
        "GBL-135_iss0185_drop_per_tenant_shadows",
    }) |prefix| {
        const sql = try std.fmt.allocPrint(
            allocator,
            "SELECT count(*)::bigint FROM public.schema_migrations WHERE version LIKE '{s}%'",
            .{prefix},
        );
        defer allocator.free(sql);

        var result = try harness.conn.query(allocator, sql, &.{});
        defer result.deinit();

        var n: i64 = 0;
        if (result.rows.len > 0) {
            const cell = result.rows[0][0] orelse "0";
            n = std.fmt.parseInt(i64, cell, 10) catch 0;
        }
        try std.testing.expectEqual(@as(i64, 1), n);
    }
}