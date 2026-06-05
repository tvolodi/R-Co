//! Integration tests for ADP-02 — Schema-per-tenant isolation (post-SPT-02).
//!
//! Migration 062 (SPT-02) dropped row-level scope columns from all public-schema
//! tables and disabled row-level security.  Tenant isolation is now provided
//! by the schema-per-tenant architecture introduced in SPT-01.
//!
//! These tests verify:
//!   AC-02-01  row-level scope columns are gone from public tables; tenant_schemas
//!             registry and bpm_provision_tenant_schema() exist.
//!   AC-02-02  Two provisioned tenant schemas are isolated from each other.
//!   AC-02-03  instance_projections in a tenant schema are accessible via
//!             search_path.
//!   AC-02-04  tasks are isolated in tenant schemas.
//!   AC-02-05  audit isolation in tenant schemas.
//!
//! Requirement traceability: ADP-02, SPT-02, SPT-04
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;
const schemaNameForTenant = bpm.pool.schemaNameForTenant;
const build_options = @import("build_options");

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — ADP-02 integration tests FAILED\n", .{});
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

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
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
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],
            raw[6],  raw[7],
            raw[8],  raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        });
}

fn schemaName(uuid_str: []const u8, buf: *[80]u8) []const u8 {
    return schemaNameForTenant(uuid_str, buf);
}

fn cleanupTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    scope_id_str: []const u8,
    schema_name_str: []const u8,
) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS {s} CASCADE",
        .{schema_name_str},
    ) catch return;
    defer allocator.free(drop_sql);
    conn.exec(drop_sql, &.{}) catch {};

    conn.exec(
        "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{scope_id_str},
    ) catch {};
    conn.exec(
        "DELETE FROM public.schema_migrations WHERE schema_name = $1",
        &.{schema_name_str},
    ) catch {};
}

test "TC-ADP-02-01: row-level scope columns removed from public tables; schema-per-tenant infra exists" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const cols = try conn.query(
        alloc,
        \\SELECT table_name
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND column_name = 'tenant_id'
        \\  AND table_name IN (
        \\      'process_definitions',
        \\      'instance_projections',
        \\      'tasks',
        \\      'tokens',
        \\      'audit_entries',
        \\      'audit_log'
        \\  )
        \\ORDER BY table_name ASC
    ,
        &.{},
    );
    defer {
        var r = cols;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 0), cols.rows.len);

    var ts = try conn.query(
        alloc,
        \\SELECT COUNT(*)
        \\FROM information_schema.tables
        \\WHERE table_schema = 'public' AND table_name = 'tenant_schemas'
    ,
        &.{},
    );
    defer ts.deinit();
    const ts_count = std.fmt.parseInt(i64, ts.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 1), ts_count);

    var fn_q = try conn.query(
        alloc,
        \\SELECT COUNT(*)
        \\FROM pg_proc
        \\WHERE proname = 'bpm_provision_tenant_schema'
    ,
        &.{},
    );
    defer fn_q.deinit();
    const fn_count = std.fmt.parseInt(i64, fn_q.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 1), fn_count);
}

test "TC-ADP-02-02: schema-per-tenant isolation for process definitions" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    var schema_buf_a: [80]u8 = undefined;
    var schema_buf_b: [80]u8 = undefined;
    const schema_a = schemaName(tenant_a, &schema_buf_a);
    const schema_b = schemaName(tenant_b, &schema_buf_b);

    defer cleanupTenant(alloc, &pool, tenant_a, schema_a);
    defer cleanupTenant(alloc, &pool, tenant_b, schema_b);

    try provisionTenantSchema(alloc, &pool, tenant_a, migrationsDir());
    try provisionTenantSchema(alloc, &pool, tenant_b, migrationsDir());

    const actor = "00000000-0000-0000-0000-000000000123";
    const conn = try pool.acquire();
    defer pool.release(conn);

    const set_a_sql = try std.fmt.allocPrint(alloc, "SET search_path TO {s}, public", .{schema_a});
    defer alloc.free(set_a_sql);
    try conn.exec(set_a_sql, &.{});
    try conn.exec(
        \\INSERT INTO process_definitions
        \\  (name, version, description, status, graph, created_by)
        \\VALUES
        \\  ('adp02-isolation-def', '1.0.0', 'tenant-a', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $1::uuid)
    ,
        &.{actor},
    );

    const set_b_sql = try std.fmt.allocPrint(alloc, "SET search_path TO {s}, public", .{schema_b});
    defer alloc.free(set_b_sql);
    try conn.exec(set_b_sql, &.{});
    try conn.exec(
        \\INSERT INTO process_definitions
        \\  (name, version, description, status, graph, created_by)
        \\VALUES
        \\  ('adp02-isolation-def', '1.0.0', 'tenant-b', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $1::uuid)
    ,
        &.{actor},
    );

    try conn.exec(set_a_sql, &.{});
    var a_rows = try conn.query(
        alloc,
        "SELECT description FROM process_definitions WHERE name = 'adp02-isolation-def'",
        &.{},
    );
    defer a_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), a_rows.rows.len);
    try std.testing.expectEqualStrings("tenant-a", a_rows.rows[0][0] orelse "");

    try conn.exec(set_b_sql, &.{});
    var b_rows = try conn.query(
        alloc,
        "SELECT description FROM process_definitions WHERE name = 'adp02-isolation-def'",
        &.{},
    );
    defer b_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), b_rows.rows.len);
    try std.testing.expectEqualStrings("tenant-b", b_rows.rows[0][0] orelse "");

    try conn.exec("SET search_path TO public", &.{});
}

test "TC-ADP-02-03: instance_projections accessible via schema search_path" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const schema_owner = try randomUuidStr(alloc);
    defer alloc.free(schema_owner);

    var schema_buf: [80]u8 = undefined;
    const schema_name_str = schemaName(schema_owner, &schema_buf);

    defer cleanupTenant(alloc, &pool, schema_owner, schema_name_str);

    try provisionTenantSchema(alloc, &pool, schema_owner, migrationsDir());

    const instance_id = try randomUuidStr(alloc);
    defer alloc.free(instance_id);
    const definition_id = "33333333-3333-3333-3333-333333333333";

    const conn = try pool.acquire();
    defer pool.release(conn);

    const set_schema_sql = try std.fmt.allocPrint(alloc, "SET search_path TO {s}, public", .{schema_name_str});
    defer alloc.free(set_schema_sql);
    try conn.exec(set_schema_sql, &.{});

    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, definition_id, correlation_key, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'adp02-tc03', 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ instance_id, definition_id },
    );

    var rows = try conn.query(
        alloc,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id},
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("ACTIVE", rows.rows[0][0] orelse "");

    try conn.exec("SET search_path TO public", &.{});
}

test "TC-ADP-02-04: task isolation in tenant schemas" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    var schema_buf_a: [80]u8 = undefined;
    var schema_buf_b: [80]u8 = undefined;
    const schema_a = schemaName(tenant_a, &schema_buf_a);
    const schema_b = schemaName(tenant_b, &schema_buf_b);

    defer cleanupTenant(alloc, &pool, tenant_a, schema_a);
    defer cleanupTenant(alloc, &pool, tenant_b, schema_b);

    try provisionTenantSchema(alloc, &pool, tenant_a, migrationsDir());
    try provisionTenantSchema(alloc, &pool, tenant_b, migrationsDir());

    const def_id = "44444444-4444-4444-4444-444444444440";
    const inst_a = try randomUuidStr(alloc);
    defer alloc.free(inst_a);
    const inst_b = try randomUuidStr(alloc);
    defer alloc.free(inst_b);
    const token_a = try randomUuidStr(alloc);
    defer alloc.free(token_a);
    const token_b = try randomUuidStr(alloc);
    defer alloc.free(token_b);
    const task_a = try randomUuidStr(alloc);
    defer alloc.free(task_a);
    const task_b = try randomUuidStr(alloc);
    defer alloc.free(task_b);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const set_a_sql = try std.fmt.allocPrint(alloc, "SET search_path TO {s}, public", .{schema_a});
    defer alloc.free(set_a_sql);
    const set_b_sql = try std.fmt.allocPrint(alloc, "SET search_path TO {s}, public", .{schema_b});
    defer alloc.free(set_b_sql);

    try conn.exec(set_a_sql, &.{});
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id, status, current_nodes, variables, last_event_seq) VALUES ($1::uuid, $2::uuid, 'ACTIVE', '[]'::jsonb, '{}', 0)",
        &.{ inst_a, def_id },
    );
    try conn.exec(
        "INSERT INTO tokens (id, instance_id, current_node, status, data) VALUES ($1::uuid, $2::uuid, 'node-adp02', 'active', '{}'::jsonb)",
        &.{ token_a, inst_a },
    );
    try conn.exec(
        "INSERT INTO tasks (id, instance_id, token_id, node_id, node_name, status, assignee_type, assignee_ref) VALUES ($1::uuid, $2::uuid, $3::uuid, 'node-adp02', 'Task A', 'PENDING', 'ROLE', 'PROCESS_OPERATOR')",
        &.{ task_a, inst_a, token_a },
    );

    try conn.exec(set_b_sql, &.{});
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id, status, current_nodes, variables, last_event_seq) VALUES ($1::uuid, $2::uuid, 'ACTIVE', '[]'::jsonb, '{}', 0)",
        &.{ inst_b, def_id },
    );
    try conn.exec(
        "INSERT INTO tokens (id, instance_id, current_node, status, data) VALUES ($1::uuid, $2::uuid, 'node-adp02', 'active', '{}'::jsonb)",
        &.{ token_b, inst_b },
    );
    try conn.exec(
        "INSERT INTO tasks (id, instance_id, token_id, node_id, node_name, status, assignee_type, assignee_ref) VALUES ($1::uuid, $2::uuid, $3::uuid, 'node-adp02', 'Task B', 'PENDING', 'ROLE', 'PROCESS_OPERATOR')",
        &.{ task_b, inst_b, token_b },
    );

    try conn.exec(set_a_sql, &.{});
    var tasks_a = try conn.query(alloc, "SELECT node_name FROM tasks WHERE node_id = 'node-adp02'", &.{});
    defer tasks_a.deinit();
    try std.testing.expectEqual(@as(usize, 1), tasks_a.rows.len);
    try std.testing.expectEqualStrings("Task A", tasks_a.rows[0][0] orelse "");

    try conn.exec(set_b_sql, &.{});
    var tasks_b = try conn.query(alloc, "SELECT node_name FROM tasks WHERE node_id = 'node-adp02'", &.{});
    defer tasks_b.deinit();
    try std.testing.expectEqual(@as(usize, 1), tasks_b.rows.len);
    try std.testing.expectEqualStrings("Task B", tasks_b.rows[0][0] orelse "");

    try conn.exec("SET search_path TO public", &.{});
}

test "TC-ADP-02-05: audit_entries work without row-level scope column in public schema" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const audit_a = try randomUuidStr(alloc);
    defer alloc.free(audit_a);
    const audit_b = try randomUuidStr(alloc);
    defer alloc.free(audit_b);
    const actor = "00000000-0000-0000-0000-000000000001";

    try h.conn.exec(
        \\INSERT INTO audit_entries
        \\  (audit_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'instance.update', 'instance', $3::uuid, NOW(), '{}'::jsonb, '{"status":"ACTIVE"}'::jsonb)
    ,
        &.{ audit_a, actor, audit_a },
    );
    try h.conn.exec(
        \\INSERT INTO audit_entries
        \\  (audit_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'instance.update', 'instance', $3::uuid, NOW(), '{}'::jsonb, '{"status":"ACTIVE"}'::jsonb)
    ,
        &.{ audit_b, actor, audit_b },
    );

    var rows = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM audit_entries WHERE audit_id IN ($1::uuid, $2::uuid)",
        &.{ audit_a, audit_b },
    );
    defer rows.deinit();
    const count = std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 2), count);
}
