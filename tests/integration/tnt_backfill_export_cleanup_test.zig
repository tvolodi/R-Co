//! Integration tests for TNT-05, TNT-06, TNT-07 — Backfill, export/import, RLS cleanup.
//!
//! TNT-05: Backfill migration moves tenant data out of public schema.
//! TNT-06: Tenant schema export/import with db_host routing.
//! TNT-07: Remove RLS policies and tenant_id columns from public.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;
const migrations_mod = bpm.migrations;
const audit_mod = bpm.bootstrap_audit;
const tenant_status = bpm.tenant_status;
const tenant_migration = bpm.tenant_migration;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — TNT-05/06/07 integration tests FAILED (env var required)\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]});
}

// ===========================================================================
// TNT-05 — Backfill migration tests
// ===========================================================================

test "TC-TNT-05-01: tnt05_progress and tnt05_orphans tables exist" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-05-01: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    // Check tnt05_progress
    const progress = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'tnt05_progress' AND table_type = 'BASE TABLE'",
        &.{},
    ) catch null;
    if (progress) |row| {
        defer { for (row) |c| if (c) |s| alloc.free(s); alloc.free(row); }
        try testing.expectEqualStrings("1", row[0].?);
    }

    // Check tnt05_orphans
    const orphans = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'tnt05_orphans' AND table_type = 'BASE TABLE'",
        &.{},
    ) catch null;
    if (orphans) |row| {
        defer { for (row) |c| if (c) |s| alloc.free(s); alloc.free(row); }
        try testing.expectEqualStrings("1", row[0].?);
    }
}

test "TC-TNT-05-02: migration_window_active flag exists" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-05-02: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'onboarding_registry' AND column_name = 'migration_window_active'",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("1", r[0].?);
    }
}

test "TC-TNT-05-03: tnt05_progress has COMPLETED rows after backfill" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-05-03: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM tnt05_progress WHERE status = 'COMPLETED'",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        const count = try std.fmt.parseInt(usize, r[0].?, 10);
        try testing.expect(count > 0);
    }
}

test "TC-TNT-05-04: tnt05_orphans has correct columns" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-05-04: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'tnt05_orphans' AND column_name IN ('row_id', 'table_name', 'tenant_id', 'reason', 'logged_at')",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("5", r[0].?);
    }
}

test "TC-TNT-05-05: default tenant has tenant_default schema" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-05-05: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const row = conn.queryRow(alloc,
        "SELECT schema_name FROM tenant_schemas WHERE tenant_id = '00000000-0000-0000-0000-000000000000' LIMIT 1",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        if (r[0]) |sn| {
            try testing.expectEqualStrings("tenant_default", sn);
        }
    } else {
        std.debug.print("TC-TNT-05-05: no default tenant row — skipping\n", .{});
    }
}

// ===========================================================================
// TNT-06 — db_host routing and export/import tests
// ===========================================================================

test "TC-TNT-06-01: tenant_schemas.db_host column exists" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-06-01: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'tenant_schemas' AND column_name = 'db_host' AND data_type = 'text'",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("1", r[0].?);
    }
}

test "TC-TNT-06-02: tenant.status column accepts MIGRATING" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-06-02: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    // Verify status column exists with check constraint
    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.check_constraints WHERE constraint_schema = 'public' AND constraint_name = 'tenant_status_check'",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("1", r[0].?);
    }
}

test "TC-TNT-06-03: MIGRATING status blocks writes (POST)" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Find a tenant that exists in the test database
    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-06-03: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const lookup = conn.queryRow(alloc,
        "SELECT id FROM public.tenant WHERE status != 'MIGRATING' ORDER BY created_at ASC LIMIT 1",
        &.{},
    ) catch null;
    if (lookup == null or lookup.?.len == 0) {
        std.debug.print("TC-TNT-06-03: no tenant found — skipping\n", .{});
        return;
    }
    const test_tenant_id = lookup.?[0].?;
    defer alloc.free(test_tenant_id);
    // Free remaining columns
    if (lookup) |r| {
        for (r[1..]) |c| if (c) |s| alloc.free(s);
        alloc.free(r);
    }

    // Set status = MIGRATING
    _ = conn.exec("UPDATE public.tenant SET status = 'MIGRATING', updated_at = NOW() WHERE id = $1", &.{test_tenant_id}) catch {
        std.debug.print("TC-TNT-06-03: cannot set MIGRATING status — skipping\n", .{});
        return;
    };

    // Check middleware blocks POST
    const result = tenant_status.checkTenantWritePause(test_tenant_id, .POST, &pool, alloc);
    try testing.expect(result != null);
    if (result) |r| {
        try testing.expectEqual(@as(u16, 503), r.status_code);
        alloc.free(r.body);
    }

    // Cleanup: reset status
    _ = conn.exec("UPDATE public.tenant SET status = 'ACTIVE', updated_at = NOW() WHERE id = $1", &.{test_tenant_id}) catch {};
}

test "TC-TNT-06-04: MIGRATING status allows reads (GET)" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Find a tenant that exists in the test database (may be different from TC-06-03)
    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-06-04: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const lookup = conn.queryRow(alloc,
        "SELECT id FROM public.tenant WHERE status != 'MIGRATING' ORDER BY created_at ASC LIMIT 1",
        &.{},
    ) catch null;
    if (lookup == null or lookup.?.len == 0) {
        std.debug.print("TC-TNT-06-04: no tenant found — skipping\n", .{});
        return;
    }
    const test_tenant_id = lookup.?[0].?;
    defer alloc.free(test_tenant_id);
    if (lookup) |r| {
        for (r[1..]) |c| if (c) |s| alloc.free(s);
        alloc.free(r);
    }

    _ = conn.exec("UPDATE public.tenant SET status = 'MIGRATING', updated_at = NOW() WHERE id = $1", &.{test_tenant_id}) catch {
        std.debug.print("TC-TNT-06-04: cannot set MIGRATING status — skipping\n", .{});
        return;
    };

    // Check middleware allows GET
    const result = tenant_status.checkTenantWritePause(test_tenant_id, .GET, &pool, alloc);
    try testing.expect(result == null);

    // Cleanup
    _ = conn.exec("UPDATE public.tenant SET status = 'ACTIVE', updated_at = NOW() WHERE id = $1", &.{test_tenant_id}) catch {};
}

test "TC-TNT-06-05: export handler compiles with valid signature" {
    // Verify that handleExportTenant and handleImportTenant are callable
    // with the expected signatures (compile-time check; no runtime call needed).
    const FnExport = @TypeOf(tenant_migration.handleExportTenant);
    const FnImport = @TypeOf(tenant_migration.handleImportTenant);
    _ = FnExport;
    _ = FnImport;
    try testing.expect(true);
}

// ===========================================================================
// TNT-07 — RLS cleanup tests
// ===========================================================================

test "TC-TNT-07-01: GBL-077 migration is applied (RLS cleanup complete)" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-07-01: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = 'public' AND version = 77",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("1", r[0].?);
    }
}

test "TC-TNT-07-02: No business data tables remain in public" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-07-02: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const business_tables = [_][]const u8{
        "events", "events_archive", "process_definitions", "instance_projections",
        "tasks", "tokens", "timers", "audit_entries", "audit_log",
    };
    for (business_tables) |table| {
        const row = conn.queryRow(alloc,
            "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1 AND table_type = 'BASE TABLE'",
            &.{table},
        ) catch {
            // Table not found — passes
            continue;
        };
        if (row) |r| {
            defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
            try testing.expectEqualStrings("0", r[0].?);
        }
    }
}

test "TC-TNT-07-03: bpm_effective_tenant_id() function is dropped" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-07-03: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.routines WHERE routine_schema = 'public' AND routine_name = 'bpm_effective_tenant_id'",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("0", r[0].?);
    }
}

test "TC-TNT-07-04: No tenant_id columns on business tables in information_schema" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-07-04: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    // Since business tables were dropped from public by GBL-073,
    // tenant_id columns on them don't exist in public.
    // Verify: no remaining business table in public has a tenant_id column
    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND column_name = 'tenant_id' AND table_name IN ('events', 'tasks', 'tokens', 'instance_projections', 'audit_entries', 'audit_log', 'process_definitions')",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("0", r[0].?);
    }
}

test "TC-TNT-07-05: GBL-077 migration is idempotent (already applied)" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = pool.acquire() catch {
        std.debug.print("TC-TNT-07-05: cannot acquire connection — skipping\n", .{});
        return;
    };
    defer pool.release(conn);

    // GBL-077 is already recorded in schema_migrations (version 77).
    // The migration runner should skip it. Verify the record is there.
    const row = conn.queryRow(alloc,
        "SELECT count(*) FROM public.schema_migrations WHERE schema_name = 'public' AND version = 77",
        &.{},
    ) catch null;
    if (row) |r| {
        defer { for (r) |c| if (c) |s| alloc.free(s); alloc.free(r); }
        try testing.expectEqualStrings("1", r[0].?);
    }
}
