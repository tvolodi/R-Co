//! Integration tests for SPT-04 — Test suite update and ADP-12 regression.
//!
//! Verifies the SPT-04 acceptance criteria:
//!   AC-1: No tenant_id columns exist in public core tables.
//!   AC-2: Full integration suite passes (verified by zig build test-integration exit 0).
//!   AC-3: ADP-12 regression scenarios pass against the tenant_default schema.
//!   AC-4: Per-test schema provisioning is cleaned up (no leakage).
//!   AC-5: zig build test exits 0.
//!
//! Tests TC-SPT-04-01 through TC-SPT-04-05 are covered by
//! tests/integration/adp02_tenant_scope_test.zig (already IMPLEMENTED).
//! This file contains the SPT-04-specific ADP-12 regression anchor tests.
//!
//! Requirement: SPT-04
//! Requires: BPM_TEST_DB_URL set to a real PostgreSQL instance.

const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// Kept for @hasDecl guard compatibility.
const root = @import("root");

// ---------------------------------------------------------------------------
// TC-SPT-04-01: No tenant_id column in any public core table (SPT-04 AC-1)
// ---------------------------------------------------------------------------
test "TC-SPT-04-01: no tenant_id column in public core tables after SPT-02 migrations" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Tables that should NOT have tenant_id after migration 062.
    const tables = [_][]const u8{
        "process_definitions",
        "instance_projections",
        "tasks",
        "tokens",
        "audit_entries",
        "audit_log",
        "users",
        "groups",
        "tenant_hostnames",
        "events",
        "events_archive",
    };

    for (tables) |table_name| {
        var result = try h.conn.query(alloc,
            \\SELECT count(*)::text
            \\FROM information_schema.columns
            \\WHERE table_schema = 'public'
            \\  AND table_name = $1
            \\  AND column_name = 'tenant_id'
        , &.{table_name});
        defer result.deinit();

        try std.testing.expect(result.rows.len > 0);
        const count = try std.fmt.parseInt(i64, result.rows[0][0] orelse "0", 10);
        if (count != 0) {
            std.debug.print(
                "TC-SPT-04-01 FAIL: public.{s} still has a tenant_id column\n",
                .{table_name},
            );
        }
        try std.testing.expectEqual(@as(i64, 0), count);
    }
}

// ---------------------------------------------------------------------------
// TC-SPT-04-02: Schema cleanup — provisioned schemas are rolled back by
// TestHarness.deinit() with no leakage to subsequent tests. (SPT-04 AC-4)
// ---------------------------------------------------------------------------
test "TC-SPT-04-02: per-test tenant schema cleanup — no schema leakage" {
    const alloc = std.testing.allocator;

    // Use a valid UUID (all-hex characters only).
    const test_uuid = "dddddddd-dddd-4ddd-addd-dddddddd04dd";
    var buf: [80]u8 = undefined;
    const expected_schema = schemaNameForTenant(test_uuid, &buf);

    // Check schema does NOT exist before the test.
    {
        var h_pre = try TestHarness.init(alloc);
        defer h_pre.deinit();
        var pre = try h_pre.conn.query(
            alloc,
            "SELECT count(*)::text FROM information_schema.schemata WHERE schema_name = $1",
            &.{expected_schema},
        );
        defer pre.deinit();
        // If it already exists (leftover from a failed prior run), clean up.
        const pre_count = try std.fmt.parseInt(i64, pre.rows[0][0] orelse "0", 10);
        if (pre_count > 0) {
            var drop_buf: [128]u8 = undefined;
            const drop_sql = std.fmt.bufPrint(
                &drop_buf,
                "DROP SCHEMA IF EXISTS {s} CASCADE",
                .{expected_schema},
            ) catch unreachable;
            h_pre.conn.exec(drop_sql, &.{}) catch {};
            h_pre.conn.exec(
                "DELETE FROM public.tenant_schemas WHERE schema_name = $1",
                &.{expected_schema},
            ) catch {};
        }
    }

    // Provision inside a TestHarness transaction.
    {
        var h = try TestHarness.init(alloc);
        defer h.deinit(); // rolls back → provisioned schema is removed

        try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{test_uuid});

        // Confirm schema exists within the transaction.
        var within = try h.conn.query(
            alloc,
            "SELECT count(*)::text FROM information_schema.schemata WHERE schema_name = $1",
            &.{expected_schema},
        );
        defer within.deinit();
        const within_count = try std.fmt.parseInt(i64, within.rows[0][0] orelse "0", 10);
        try std.testing.expectEqual(@as(i64, 1), within_count);

        // h.deinit() rolls back here.
    }

    // Confirm schema was rolled back.
    var h_post = try TestHarness.init(alloc);
    defer h_post.deinit();
    var post = try h_post.conn.query(
        alloc,
        "SELECT count(*)::text FROM information_schema.schemata WHERE schema_name = $1",
        &.{expected_schema},
    );
    defer post.deinit();
    const post_count = try std.fmt.parseInt(i64, post.rows[0][0] orelse "0", 10);
    if (post_count != 0) {
        std.debug.print(
            "TC-SPT-04-02 FAIL: schema '{s}' still exists after TestHarness rollback\n",
            .{expected_schema},
        );
    }
    try std.testing.expectEqual(@as(i64, 0), post_count);
}

// ---------------------------------------------------------------------------
// TC-SPT-04-03: ADP-12 regression — tenant_default schema exists and
// bpm_provision_tenant_schema is idempotent for the default UUID. (SPT-04 AC-3)
// ---------------------------------------------------------------------------
test "TC-SPT-04-03: ADP-12 regression — tenant_default schema accessible and idempotent" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const default_uuid = "00000000-0000-0000-0000-000000000000";

    // Idempotent provisioning of the default tenant — must not fail or duplicate.
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{default_uuid});
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{default_uuid});

    // Verify tenant_schemas has exactly one row for the default UUID.
    var reg = try h.conn.query(
        alloc,
        "SELECT count(*)::text FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{default_uuid},
    );
    defer reg.deinit();
    try std.testing.expect(reg.rows.len > 0);
    const reg_count = try std.fmt.parseInt(i64, reg.rows[0][0] orelse "0", 10);
    try std.testing.expectEqual(@as(i64, 1), reg_count);

    // Verify the tenant_default schema exists in pg_namespace.
    var ns = try h.conn.query(
        alloc,
        "SELECT count(*)::text FROM information_schema.schemata WHERE schema_name = 'tenant_default'",
        &.{},
    );
    defer ns.deinit();
    try std.testing.expect(ns.rows.len > 0);
    const ns_count = try std.fmt.parseInt(i64, ns.rows[0][0] orelse "0", 10);
    if (ns_count != 1) {
        std.debug.print(
            "TC-SPT-04-03 FAIL: tenant_default schema count = {} (expected 1)\n",
            .{ns_count},
        );
    }
    try std.testing.expectEqual(@as(i64, 1), ns_count);
}
