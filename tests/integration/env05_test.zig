//! Integration tests for ENV-05 — Test tenant lifecycle management.
//!
//! POST /api/v1/admin/tenants/:test_tenant_id/reset  — truncate business data
//! DELETE /api/v1/admin/tenants/:test_tenant_id      — full decommission
//!
//! Tests call handleReset() and handleDelete() directly (domain layer).
//! ENV-05 is a SHOULD-priority requirement.
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test creates its own fixtures with per-test UUIDs and cleans up via defer.
//!
//! Requirement traceability:
//!   ENV-05 → TC-ENV-05-01 .. TC-ENV-05-06

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const tenant_context = bpm.api_tenant_context;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;
const tenant_lifecycle = bpm.tenant_lifecycle_admin;

// Null IDP manager — provider = null, so deleteRealm() is never called
// (safe for tests where idp_realm_id IS NULL in the tenant row).
const null_idp_manager = bpm.identity_provider.manager.Manager{};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — ENV-05 integration tests FAILED (env var required)\n",
                .{},
            );
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],  raw[6],  raw[7],
        raw[8],  raw[9],  raw[10], raw[11],
        raw[12], raw[13], raw[14], raw[15],
    });
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

/// Insert a production tenant row.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertProductionTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'production', NULL)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug },
    );
    _ = allocator;
}

/// Insert a test tenant row.
/// Security: all values bound as parameters — no SQL string interpolation.
fn insertTestTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    slug: []const u8,
    production_tenant_id: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'test', $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    ,
        &[_][]const u8{ tenant_id, slug, slug, production_tenant_id },
    );
    _ = allocator;
}

fn cleanupTenantById(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
}

fn dropTenantSchema(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
) void {
    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);
    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name},
    ) catch return;
    defer allocator.free(drop_sql);

    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(drop_sql, &[_][]const u8{}) catch {};
    conn.exec(
        "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &[_][]const u8{tenant_id},
    ) catch {};
    conn.exec(
        "DELETE FROM public.schema_migrations WHERE schema_name = $1",
        &[_][]const u8{schema_name},
    ) catch {};
}

/// Free a HandlerResult body, handling both heap-allocated and static fallback strings.
fn freeHandlerBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (body.len > 0 and !std.mem.eql(u8, body, static_fallback)) {
        alloc.free(body);
    }
}

// ---------------------------------------------------------------------------
// TC-ENV-05-01
// ---------------------------------------------------------------------------

test "TC-ENV-05-01: handleReset returns HTTP 200 with reset_at and tables_truncated" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    defer dropTenantSchema(alloc, &pool, test_id);
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    tenant_context.clear();

    const result = tenant_lifecycle.handleReset(&pool, alloc, test_id);
    defer freeHandlerBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    // Body must contain "reset_at" and "tables_truncated".
    try testing.expect(std.mem.indexOf(u8, result.body, "reset_at") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "tables_truncated") != null);

    // Body must contain exactly 11 table name entries.
    // Each table name appears once in the tables_truncated array.
    const expected_tables = [_][]const u8{
        "tokens",
        "timers",
        "tasks",
        "dead_letter_items",
        "webhook_subscriptions",
        "audit_entries",
        "audit_log",
        "instance_projections",
        "events_archive",
        "events",
        "process_definitions",
    };
    for (expected_tables) |table_name| {
        try testing.expect(std.mem.indexOf(u8, result.body, table_name) != null);
    }
}

// ---------------------------------------------------------------------------
// TC-ENV-05-02
// ---------------------------------------------------------------------------

test "TC-ENV-05-02: handleReset truncates process_definitions but preserves roles" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    defer dropTenantSchema(alloc, &pool, test_id);
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    // Insert a process definition in the test tenant schema (business table).
    tenant_context.set(test_id);
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const def_id = try randomUuidStr(alloc);
        defer alloc.free(def_id);
        try conn.exec(
            \\INSERT INTO process_definitions
            \\    (id, tenant_id, name, version, description, status, graph, created_by)
            \\VALUES ($1::uuid, bpm_effective_tenant_id(), 'env05-02-def', '1',
            \\        'reset test', 'DRAFT',
            \\        '{"nodes":[],"edges":[]}'::jsonb,
            \\        '00000000-0000-0000-0000-000000000099'::uuid)
            \\ON CONFLICT DO NOTHING
        ,
            &[_][]const u8{def_id},
        );
    }

    // Count roles before reset — roles are seeded by migrations.
    var roles_before: i64 = 0;
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const row = try conn.queryRow(
            alloc,
            "SELECT COUNT(*)::text FROM roles",
            &[_][]const u8{},
        );
        defer if (row) |r| {
            for (r) |col| if (col) |v| alloc.free(v);
            alloc.free(r);
        };
        if (row) |r| {
            roles_before = std.fmt.parseInt(i64, r[0] orelse "0", 10) catch 0;
        }
    }
    tenant_context.clear();

    // Execute reset.
    const result = tenant_lifecycle.handleReset(&pool, alloc, test_id);
    defer freeHandlerBody(alloc, result.body);
    try testing.expectEqual(@as(u16, 200), result.status_code);

    // After reset: process_definitions must be empty.
    tenant_context.set(test_id);
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const row = try conn.queryRow(
            alloc,
            "SELECT COUNT(*)::text FROM process_definitions",
            &[_][]const u8{},
        );
        defer if (row) |r| {
            for (r) |col| if (col) |v| alloc.free(v);
            alloc.free(r);
        };
        try testing.expect(row != null);
        const cnt = try std.fmt.parseInt(i64, row.?[0] orelse "0", 10);
        try testing.expectEqual(@as(i64, 0), cnt);
    }

    // Roles must still be present (preserved across reset).
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const row = try conn.queryRow(
            alloc,
            "SELECT COUNT(*)::text FROM roles",
            &[_][]const u8{},
        );
        defer if (row) |r| {
            for (r) |col| if (col) |v| alloc.free(v);
            alloc.free(r);
        };
        const roles_after_row = row orelse return error.TestUnexpectedResult;
        const roles_after = try std.fmt.parseInt(i64, roles_after_row[0] orelse "0", 10);
        try testing.expectEqual(roles_before, roles_after);
    }
    tenant_context.clear();
}

// ---------------------------------------------------------------------------
// TC-ENV-05-03
// ---------------------------------------------------------------------------

test "TC-ENV-05-03: handleReset on production tenant returns HTTP 422 not_a_test_tenant" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);

    defer cleanupTenantById(&pool, prod_id);
    try insertProductionTenant(alloc, &pool, prod_id, prod_id);

    tenant_context.clear();

    const result = tenant_lifecycle.handleReset(&pool, alloc, prod_id);
    defer freeHandlerBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "not_a_test_tenant") != null);
}

// ---------------------------------------------------------------------------
// TC-ENV-05-04
// ---------------------------------------------------------------------------

test "TC-ENV-05-04: handleReset returns HTTP 409 when test tenant has active process instances" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    defer dropTenantSchema(alloc, &pool, test_id);
    defer dropTenantSchema(alloc, &pool, prod_id);
    defer cleanupTenantById(&pool, prod_id);
    defer cleanupTenantById(&pool, test_id);

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    // Insert an ACTIVE instance in the test tenant schema.
    tenant_context.set(test_id);
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const instance_id = try randomUuidStr(alloc);
        defer alloc.free(instance_id);
        const def_id = try randomUuidStr(alloc);
        defer alloc.free(def_id);
        try conn.exec(
            \\INSERT INTO instance_projections (
            \\  instance_id, definition_id, correlation_key, status,
            \\  current_nodes, variables, error_detail, last_event_seq,
            \\  started_at, completed_at, cancelled_at, updated_at
            \\)
            \\VALUES (
            \\  $1::uuid, $2::uuid, NULL, 'ACTIVE',
            \\  '[]'::jsonb, '{}'::jsonb, NULL, 0,
            \\  NOW(), NULL, NULL, NOW()
            \\)
            \\ON CONFLICT (instance_id) DO UPDATE SET status = 'ACTIVE'
        ,
            &[_][]const u8{ instance_id, def_id },
        );
    }
    tenant_context.clear();

    const result = tenant_lifecycle.handleReset(&pool, alloc, test_id);
    defer freeHandlerBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 409), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "active_instances") != null);
}

// ---------------------------------------------------------------------------
// TC-ENV-05-05
// ---------------------------------------------------------------------------

test "TC-ENV-05-05: handleDelete removes test tenant public rows and returns HTTP 204" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);
    const test_id = try randomUuidStr(alloc);
    defer alloc.free(test_id);

    // Note: cleanup is intentionally NOT deferred for test_id here because
    // handleDelete removes the row itself. If delete fails, the cleanup below handles it.
    defer {
        // Best-effort cleanup in case the test fails before handleDelete runs.
        dropTenantSchema(alloc, &pool, test_id);
        cleanupTenantById(&pool, test_id);
    }
    defer {
        dropTenantSchema(alloc, &pool, prod_id);
        cleanupTenantById(&pool, prod_id);
    }

    try insertProductionTenant(alloc, &pool, prod_id, prod_id);
    try insertTestTenant(alloc, &pool, test_id, test_id, prod_id);
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());

    tenant_context.clear();

    // Delete with null_idp_manager (idp_realm_id IS NULL in the row).
    const result = tenant_lifecycle.handleDelete(&pool, alloc, null_idp_manager, test_id);
    defer freeHandlerBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 204), result.status_code);

    // Verify the public.tenant row no longer exists.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const check_row = try conn.queryRow(
            alloc,
            "SELECT COUNT(*)::text FROM public.tenant WHERE id = $1::uuid",
            &[_][]const u8{test_id},
        );
        defer if (check_row) |r| {
            for (r) |col| if (col) |v| alloc.free(v);
            alloc.free(r);
        };
        try testing.expect(check_row != null);
        const cnt = try std.fmt.parseInt(i64, check_row.?[0] orelse "1", 10);
        try testing.expectEqual(@as(i64, 0), cnt);
    }
}

// ---------------------------------------------------------------------------
// TC-ENV-05-06
// ---------------------------------------------------------------------------

test "TC-ENV-05-06: handleDelete on production tenant returns HTTP 422 production_tenant_delete_forbidden" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const prod_id = try randomUuidStr(alloc);
    defer alloc.free(prod_id);

    defer cleanupTenantById(&pool, prod_id);
    try insertProductionTenant(alloc, &pool, prod_id, prod_id);

    tenant_context.clear();

    const result = tenant_lifecycle.handleDelete(&pool, alloc, null_idp_manager, prod_id);
    defer freeHandlerBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(
        std.mem.indexOf(u8, result.body, "production_tenant_delete_forbidden") != null,
    );
}
