//! Integration tests for ISS-0068 (SPT-01 onboarding schema provisioning wiring).
//! All tests require a real PostgreSQL database via BPM_TEST_DB_URL.

const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

fn testDbUrl(allocator: std.mem.Allocator) (error{MissingTestDatabaseUrl} || std.mem.Allocator.Error || error{EnvironmentVariableMissing} || error{InvalidWtf8})![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0068 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
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
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0], raw[1], raw[2],  raw[3],
            raw[4], raw[5],
            raw[6], raw[7],
            raw[8], raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        });
}

fn cleanupTenantSchema(pool: *Pool, tenant_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("SELECT public.bpm_drop_tenant_schema($1::uuid)", &.{tenant_id}) catch {};
    conn.exec("DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid", &.{tenant_id}) catch {};
    // ISS-0647 / GH-652 (TC-SPT-01-ISS68-02): provisionTenantSchema() also
    // INSERTs a row into public.tenant (src/db/provisioning.zig ~line 215),
    // but this cleanup used to only remove the tenant_schemas row and the
    // physical schema, leaving the public.tenant row itself orphaned with no
    // matching tenant_schemas row. TC-SPT-01-ISS68-02 runs later in the same
    // binary and asserts every public.tenant row has a matching
    // tenant_schemas row, so it failed on the leftover fixture from THIS
    // test rather than any defect in the code under test. Deleting the
    // tenant row too makes this test's fixture fully self-cleaning.
    conn.exec("DELETE FROM public.tenant WHERE id = $1::uuid", &.{tenant_id}) catch {};
}

test "TC-SPT-01-ISS68-01: provisioning creates tenant_schemas row and physical schema" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);

    var schema_buf: [80]u8 = undefined;
    const schema_name = schemaNameForTenant(tenant_id, &schema_buf);

    defer cleanupTenantSchema(&pool, tenant_id);

    try provisionTenantSchema(alloc, &pool, tenant_id, migrationsDir());

    const conn = try pool.acquire();
    defer pool.release(conn);

    var registry_result = try conn.query(
        alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{tenant_id},
    );
    defer registry_result.deinit();

    try std.testing.expect(registry_result.rows.len > 0);
    const registry_count_raw = registry_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const registry_count = try std.fmt.parseInt(i64, registry_count_raw, 10);
    try std.testing.expect(registry_count > 0);
    try std.testing.expectEqual(@as(i64, 1), registry_count);

    var schema_result = try conn.query(
        alloc,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
        &.{schema_name},
    );
    defer schema_result.deinit();

    try std.testing.expect(schema_result.rows.len > 0);
    const schema_count_raw = schema_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const schema_count = try std.fmt.parseInt(i64, schema_count_raw, 10);
    try std.testing.expectEqual(@as(i64, 1), schema_count);
}

test "TC-SPT-01-ISS68-02: every tenant has a tenant_schemas row and tenant_default exists" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    var tenant_count_result = try h.conn.query(alloc, "SELECT count(*) FROM public.tenant", &.{});
    defer tenant_count_result.deinit();
    try std.testing.expect(tenant_count_result.rows.len > 0);
    const tenant_count_raw = tenant_count_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const tenant_count = try std.fmt.parseInt(i64, tenant_count_raw, 10);

    var matched_count_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM public.tenant t INNER JOIN public.tenant_schemas ts ON ts.tenant_id = t.id",
        &.{},
    );
    defer matched_count_result.deinit();
    try std.testing.expect(matched_count_result.rows.len > 0);
    const matched_count_raw = matched_count_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const matched_count = try std.fmt.parseInt(i64, matched_count_raw, 10);
    try std.testing.expectEqual(tenant_count, matched_count);

    var missing_result = try h.conn.query(
        alloc,
        \\SELECT count(*)
        \\FROM public.tenant t
        \\LEFT JOIN public.tenant_schemas ts ON ts.tenant_id = t.id
        \\WHERE ts.tenant_id IS NULL
    ,
        &.{},
    );
    defer missing_result.deinit();
    try std.testing.expect(missing_result.rows.len > 0);
    const missing_raw = missing_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const missing_count = try std.fmt.parseInt(i64, missing_raw, 10);
    try std.testing.expectEqual(@as(i64, 0), missing_count);

    var tenant_default_result = try h.conn.query(
        alloc,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = 'tenant_default'",
        &.{},
    );
    defer tenant_default_result.deinit();
    try std.testing.expect(tenant_default_result.rows.len > 0);
    const tenant_default_count_raw = tenant_default_result.rows[0][0] orelse return error.TestUnexpectedResult;
    const tenant_default_count = try std.fmt.parseInt(i64, tenant_default_count_raw, 10);
    try std.testing.expectEqual(@as(i64, 1), tenant_default_count);
}

test "TC-SPT-01-ISS68-03: provisionTenantSchema is idempotent for same tenant" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_id = try randomUuidStr(alloc);
    defer alloc.free(tenant_id);

    defer cleanupTenantSchema(&pool, tenant_id);

    try provisionTenantSchema(alloc, &pool, tenant_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, tenant_id, migrationsDir());

    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try conn.query(
        alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{tenant_id},
    );
    defer result.deinit();

    try std.testing.expect(result.rows.len > 0);
    const count_raw = result.rows[0][0] orelse return error.TestUnexpectedResult;
    const count = try std.fmt.parseInt(i64, count_raw, 10);
    try std.testing.expectEqual(@as(i64, 1), count);
}
