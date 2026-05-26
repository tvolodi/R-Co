const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const default_tenant = "00000000-0000-0000-0000-000000000000";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set -- skipping integration test\n", .{});
            return error.SkipZigTest;
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

test "TC-ADP-02-01: migration provisions tenant columns, tenant indexes, and tenant policies" {
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
        \\SELECT table_name, is_nullable, column_default
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

    try std.testing.expectEqual(@as(usize, 6), cols.rows.len);

    for (cols.rows) |row| {
        const nullable = row[1] orelse "";
        const default_expr = row[2] orelse "";
        try std.testing.expectEqualStrings("NO", nullable);
        const has_fn = std.mem.indexOf(u8, default_expr, "bpm_effective_tenant_id") != null;
        const has_default_uuid = std.mem.indexOf(u8, default_expr, default_tenant) != null;
        try std.testing.expect(has_fn or has_default_uuid);
    }

    const idx = try conn.query(
        alloc,
        \\SELECT indexname
        \\FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND indexname IN (
        \\      'uq_definition_tenant_version',
        \\      'uq_active_definition_tenant',
        \\      'uq_instance_tenant_correlation',
        \\      'idx_def_tenant_name_status',
        \\      'idx_proj_tenant_status',
        \\      'idx_task_tenant_pending_assignee',
        \\      'idx_token_tenant_active',
        \\      'idx_audit_entries_tenant_time',
        \\      'idx_audit_log_tenant_time'
        \\  )
    ,
        &.{},
    );
    defer {
        var r = idx;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 9), idx.rows.len);

    const policies = try conn.query(
        alloc,
        \\SELECT tablename
        \\FROM pg_policies
        \\WHERE schemaname = 'public'
        \\  AND tablename IN (
        \\      'process_definitions',
        \\      'instance_projections',
        \\      'tasks',
        \\      'tokens',
        \\      'audit_entries',
        \\      'audit_log'
        \\  )
    ,
        &.{},
    );
    defer {
        var r = policies;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 6), policies.rows.len);
}

test "TC-ADP-02-02: definition uniqueness is tenant-partitioned and reads are tenant-scoped" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const name = "adp02-tenant-iso-def";
    const version = "1.0.0";
    const actor = "00000000-0000-0000-0000-000000000123";
    const tenant_a = default_tenant;
    const tenant_b = "22222222-2222-2222-2222-222222222222";

    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a}) catch {};
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b}) catch {};
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    try conn.exec(
        \\INSERT INTO process_definitions
        \\  (tenant_id, name, version, description, status, graph, created_by)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1, $2, '', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $3::uuid)
    ,
        &.{ name, version, actor },
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    try conn.exec(
        \\INSERT INTO process_definitions
        \\  (tenant_id, name, version, description, status, graph, created_by)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1, $2, '', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $3::uuid)
    ,
        &.{ name, version, actor },
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    var a_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    );
    defer a_rows.deinit();
    const a_count = std.fmt.parseInt(i64, a_rows.rows[0][0] orelse "0", 10) catch 0;

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    var b_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    );
    defer b_rows.deinit();
    const b_count = std.fmt.parseInt(i64, b_rows.rows[0][0] orelse "0", 10) catch 0;

    try std.testing.expectEqual(@as(i64, 1), a_count);
    try std.testing.expectEqual(@as(i64, 1), b_count);

    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a}) catch {};
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b}) catch {};
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{}) catch {};
}

test "TC-ADP-02-03: instance persistence is tenant-scoped with default-tenant fallback" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const tenant_a = default_tenant;
    const tenant_b = "22222222-2222-2222-2222-222222222222";

    const definition_id = "33333333-3333-3333-3333-333333333333";
    const instance_a = "33333333-3333-3333-3333-333333333334";
    const instance_b = "33333333-3333-3333-3333-333333333335";
    const instance_default = "33333333-3333-3333-3333-333333333336";
    const corr = "adp02-instance-corr";

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    conn.exec("DELETE FROM instance_projections WHERE instance_id IN ($1::uuid, $2::uuid, $3::uuid)", &.{ instance_a, instance_b, instance_default }) catch {};
    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (tenant_id, instance_id, definition_id, correlation_key, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, $3, 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ instance_a, definition_id, corr },
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_b}) catch {};
    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (tenant_id, instance_id, definition_id, correlation_key, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, $3, 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ instance_b, definition_id, corr },
    );

    // Legacy/default flow: no explicit tenant claim resolves to default tenant.
    try conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{});
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_default}) catch {};
    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, definition_id, correlation_key, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'adp02-instance-default', 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ instance_default, definition_id },
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    var a_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM instance_projections WHERE correlation_key = $1",
        &.{corr},
    );
    defer a_rows.deinit();
    const a_count = std.fmt.parseInt(i64, a_rows.rows[0][0] orelse "0", 10) catch 0;

    var default_rows = try conn.query(
        alloc,
        "SELECT tenant_id::text FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_default},
    );
    defer default_rows.deinit();
    const default_tenant_value = default_rows.rows[0][0] orelse "";

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    var b_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM instance_projections WHERE correlation_key = $1",
        &.{corr},
    );
    defer b_rows.deinit();
    const b_count = std.fmt.parseInt(i64, b_rows.rows[0][0] orelse "0", 10) catch 0;

    try std.testing.expectEqual(@as(i64, 1), a_count);
    try std.testing.expectEqual(@as(i64, 1), b_count);
    try std.testing.expectEqualStrings(default_tenant, default_tenant_value);

    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id IN ($1::uuid, $2::uuid, $3::uuid)", &.{ instance_a, instance_b, instance_default }) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id IN ($1::uuid, $2::uuid, $3::uuid)", &.{ instance_a, instance_b, instance_default }) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{}) catch {};
}

test "TC-ADP-02-04: task and transition persistence are isolated across tenants" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const tenant_a = default_tenant;
    const tenant_b = "22222222-2222-2222-2222-222222222222";

    const def_id = "44444444-4444-4444-4444-444444444440";
    const inst_a = "44444444-4444-4444-4444-444444444441";
    const inst_b = "44444444-4444-4444-4444-444444444442";
    const token_a = "44444444-4444-4444-4444-444444444443";
    const token_b = "44444444-4444-4444-4444-444444444444";
    const task_a = "44444444-4444-4444-4444-444444444445";
    const task_b = "44444444-4444-4444-4444-444444444446";

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    conn.exec("DELETE FROM tasks WHERE id IN ($1::uuid, $2::uuid)", &.{ task_a, task_b }) catch {};
    conn.exec("DELETE FROM tokens WHERE id IN ($1::uuid, $2::uuid)", &.{ token_a, token_b }) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id IN ($1::uuid, $2::uuid)", &.{ inst_a, inst_b }) catch {};

    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (tenant_id, instance_id, definition_id, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ inst_a, def_id },
    );
    try conn.exec(
        \\INSERT INTO tokens
        \\  (tenant_id, id, instance_id, current_node, status, data)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, 'node-adp02', 'active', '{}'::jsonb)
    ,
        &.{ token_a, inst_a },
    );
    try conn.exec(
        \\INSERT INTO tasks
        \\  (tenant_id, id, instance_id, token_id, node_id, node_name, status, assignee_type, assignee_ref)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, $3::uuid, 'node-adp02', 'Tenant Scoped Task', 'PENDING', 'ROLE', 'PROCESS_OPERATOR')
    ,
        &.{ task_a, inst_a, token_a },
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    try conn.exec(
        \\INSERT INTO instance_projections
        \\  (tenant_id, instance_id, definition_id, status, current_nodes, variables, last_event_seq)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, 'ACTIVE', '[]'::jsonb, '{}'::jsonb, 0)
    ,
        &.{ inst_b, def_id },
    );
    try conn.exec(
        \\INSERT INTO tokens
        \\  (tenant_id, id, instance_id, current_node, status, data)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, 'node-adp02', 'active', '{}'::jsonb)
    ,
        &.{ token_b, inst_b },
    );
    try conn.exec(
        \\INSERT INTO tasks
        \\  (tenant_id, id, instance_id, token_id, node_id, node_name, status, assignee_type, assignee_ref)
        \\VALUES
        \\  (bpm_effective_tenant_id(), $1::uuid, $2::uuid, $3::uuid, 'node-adp02', 'Tenant Scoped Task', 'PENDING', 'ROLE', 'PROCESS_OPERATOR')
    ,
        &.{ task_b, inst_b, token_b },
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    var token_rows_a = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM tokens WHERE current_node = 'node-adp02'",
        &.{},
    );
    defer token_rows_a.deinit();
    const token_count_a = std.fmt.parseInt(i64, token_rows_a.rows[0][0] orelse "0", 10) catch 0;

    var task_rows_a = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM tasks WHERE node_id = 'node-adp02'",
        &.{},
    );
    defer task_rows_a.deinit();
    const task_count_a = std.fmt.parseInt(i64, task_rows_a.rows[0][0] orelse "0", 10) catch 0;

    var hidden_b_from_a = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM tasks WHERE id = $1::uuid",
        &.{task_b},
    );
    defer hidden_b_from_a.deinit();
    const hidden_b_count = std.fmt.parseInt(i64, hidden_b_from_a.rows[0][0] orelse "0", 10) catch 0;

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    var token_rows_b = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM tokens WHERE current_node = 'node-adp02'",
        &.{},
    );
    defer token_rows_b.deinit();
    const token_count_b = std.fmt.parseInt(i64, token_rows_b.rows[0][0] orelse "0", 10) catch 0;

    var task_rows_b = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM tasks WHERE node_id = 'node-adp02'",
        &.{},
    );
    defer task_rows_b.deinit();
    const task_count_b = std.fmt.parseInt(i64, task_rows_b.rows[0][0] orelse "0", 10) catch 0;

    try std.testing.expectEqual(@as(i64, 1), token_count_a);
    try std.testing.expectEqual(@as(i64, 1), task_count_a);
    try std.testing.expectEqual(@as(i64, 0), hidden_b_count);
    try std.testing.expectEqual(@as(i64, 1), token_count_b);
    try std.testing.expectEqual(@as(i64, 1), task_count_b);

    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a}) catch {};
    conn.exec("DELETE FROM tasks WHERE id IN ($1::uuid, $2::uuid)", &.{ task_a, task_b }) catch {};
    conn.exec("DELETE FROM tokens WHERE id IN ($1::uuid, $2::uuid)", &.{ token_a, token_b }) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id IN ($1::uuid, $2::uuid)", &.{ inst_a, inst_b }) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b}) catch {};
    conn.exec("DELETE FROM tasks WHERE id IN ($1::uuid, $2::uuid)", &.{ task_a, task_b }) catch {};
    conn.exec("DELETE FROM tokens WHERE id IN ($1::uuid, $2::uuid)", &.{ token_a, token_b }) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id IN ($1::uuid, $2::uuid)", &.{ inst_a, inst_b }) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{}) catch {};
}

test "TC-ADP-02-05: audit persistence is tenant-scoped for audit_entries and audit_log" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const tenant_a = default_tenant;
    const tenant_b = "22222222-2222-2222-2222-222222222222";
    const audit_target_a = "55555555-5555-5555-5555-555555555551";
    const audit_target_b = "55555555-5555-5555-5555-555555555552";

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    try conn.exec(
        \\INSERT INTO audit_entries
        \\  (tenant_id, actor_id, action, resource_type, resource_id, before_state, after_state)
        \\VALUES
        \\  (bpm_effective_tenant_id(), NULL, 'instance.update', 'instance', $1::uuid, '{}'::jsonb, '{"status":"ACTIVE"}'::jsonb)
    ,
        &.{audit_target_a},
    );
    try conn.exec(
        \\INSERT INTO audit_log
        \\  (tenant_id, actor_id, actor_email, action, entity_type, entity_id, entity_name, detail)
        \\VALUES
        \\  (bpm_effective_tenant_id(), NULL, 'system@local', 'INSTANCE_START', 'instance', $1::uuid, 'adp02-a', '{}'::jsonb)
    ,
        &.{audit_target_a},
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    try conn.exec(
        \\INSERT INTO audit_entries
        \\  (tenant_id, actor_id, action, resource_type, resource_id, before_state, after_state)
        \\VALUES
        \\  (bpm_effective_tenant_id(), NULL, 'instance.update', 'instance', $1::uuid, '{}'::jsonb, '{"status":"ACTIVE"}'::jsonb)
    ,
        &.{audit_target_b},
    );
    try conn.exec(
        \\INSERT INTO audit_log
        \\  (tenant_id, actor_id, actor_email, action, entity_type, entity_id, entity_name, detail)
        \\VALUES
        \\  (bpm_effective_tenant_id(), NULL, 'system@local', 'INSTANCE_START', 'instance', $1::uuid, 'adp02-b', '{}'::jsonb)
    ,
        &.{audit_target_b},
    );

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
    var entry_rows_a = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM audit_entries WHERE action = 'instance.update'",
        &.{},
    );
    defer entry_rows_a.deinit();
    const entry_count_a = std.fmt.parseInt(i64, entry_rows_a.rows[0][0] orelse "0", 10) catch 0;

    var log_rows_a = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM audit_log WHERE action = 'INSTANCE_START'",
        &.{},
    );
    defer log_rows_a.deinit();
    const log_count_a = std.fmt.parseInt(i64, log_rows_a.rows[0][0] orelse "0", 10) catch 0;

    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
    var entry_rows_b = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM audit_entries WHERE action = 'instance.update'",
        &.{},
    );
    defer entry_rows_b.deinit();
    const entry_count_b = std.fmt.parseInt(i64, entry_rows_b.rows[0][0] orelse "0", 10) catch 0;

    var log_rows_b = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM audit_log WHERE action = 'INSTANCE_START'",
        &.{},
    );
    defer log_rows_b.deinit();
    const log_count_b = std.fmt.parseInt(i64, log_rows_b.rows[0][0] orelse "0", 10) catch 0;

    try std.testing.expectEqual(@as(i64, 1), entry_count_a);
    try std.testing.expectEqual(@as(i64, 1), log_count_a);
    try std.testing.expectEqual(@as(i64, 1), entry_count_b);
    try std.testing.expectEqual(@as(i64, 1), log_count_b);

    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a}) catch {};
    conn.exec("DELETE FROM audit_entries WHERE resource_id IN ($1::uuid, $2::uuid)", &.{ audit_target_a, audit_target_b }) catch {};
    conn.exec("DELETE FROM audit_log WHERE entity_id IN ($1::uuid, $2::uuid)", &.{ audit_target_a, audit_target_b }) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b}) catch {};
    conn.exec("DELETE FROM audit_entries WHERE resource_id IN ($1::uuid, $2::uuid)", &.{ audit_target_a, audit_target_b }) catch {};
    conn.exec("DELETE FROM audit_log WHERE entity_id IN ($1::uuid, $2::uuid)", &.{ audit_target_a, audit_target_b }) catch {};
    conn.exec("SELECT set_config('bpm.tenant_id', '', false)", &.{}) catch {};
}
