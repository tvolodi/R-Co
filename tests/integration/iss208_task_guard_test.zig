//! Integration tests for ISS-208 — Guard task completion against terminal instances.
//!
//! Tests verify that completeTask returns InstanceNotActive (HTTP 409) when the
//! parent instance is CANCELLED or COMPLETED, and that no events are appended.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   ISS-208 → TC1: cancel instance then complete task → 409 INSTANCE_NOT_ACTIVE, no events
//!   ISS-208 → TC2: complete task on COMPLETED instance → 409 INSTANCE_NOT_ACTIVE
const std = @import("std");
const helpers = @import("helpers.zig");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const InstanceStore = bpm.engine.InstanceStore;
const SnapshotStore = bpm.snapshot.SnapshotStore;
const TaskStore = bpm.tasks.TaskStore;
const Actor = bpm.task_routes.Actor;

// ---------------------------------------------------------------------------

fn getTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping ISS-208 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

// ---------------------------------------------------------------------------
// UUID helper
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// TC1: cancel instance then complete task → 409 INSTANCE_NOT_ACTIVE, no events
// ---------------------------------------------------------------------------

test "ISS-208-TC1: task completion on cancelled instance returns 409 INSTANCE_NOT_ACTIVE" {
    const allocator = std.testing.allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    var h = helpers.TestHarness.init(allocator) catch |err| {
        if (err == error.MissingTestDatabaseUrl) return error.SkipZigTest;
        return err;
    };
    defer h.deinit();

    const tenant_id = "00000000-0000-0000-0000-000000000000";
    const def_id = try randomUuidStr(allocator);
    defer allocator.free(def_id);
    const inst_id = try randomUuidStr(allocator);
    defer allocator.free(inst_id);
    const task_id = try randomUuidStr(allocator);
    defer allocator.free(task_id);

    // Insert process definition.
    try h.conn.exec(
        \\INSERT INTO process_definitions (id, tenant_id, name, status, definition_artifact_hash, version, created_by, created_at, updated_at)
        \\VALUES ($1::uuid, $2::uuid, 'test-def-iss208-tc1', 'ACTIVE', 'hash-208-tc1', 1, $2::uuid, NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ def_id, tenant_id },
    );

    // Insert instance in CANCELLED status.
    try h.conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, tenant_id, definition_id, status, variables, current_nodes, definition_artifact_hash, started_at, updated_at, last_event_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, $3::uuid, 'CANCELLED', '{}', '[]', 'hash-208-tc1', NOW(), NOW(), 1)
        \\ON CONFLICT (instance_id) DO NOTHING
    ,
        &.{ inst_id, tenant_id, def_id },
    );

    const token_id_1 = try randomUuidStr(allocator);
    defer allocator.free(token_id_1);

    // Insert a token (required by tasks.token_id FK).
    try h.conn.exec(
        \\INSERT INTO tokens
        \\  (id, instance_id, current_node, status, created_at, updated_at)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'task-node-1', 'active', NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ token_id_1, inst_id },
    );

    // Insert a PENDING task belonging to the cancelled instance.
    try h.conn.exec(
        \\INSERT INTO tasks
        \\  (id, tenant_id, instance_id, token_id, node_id, node_name, status, assignee_ref, assignee_type, created_at, updated_at)
        \\VALUES
        \\  ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 'task-node-1', 'Task Node 1', 'PENDING', 'test-actor-208-tc1', 'USER', NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ task_id, tenant_id, inst_id, token_id_1 },
    );

    try h.conn.commit();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var snap_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snap_store);
    defer instance_store.deinit();

    var task_store = TaskStore.init(&pool);

    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    const actor = Actor{
        .user_id = "test-actor-208-tc1",
        .is_operator_or_above = true,
        .is_platform_admin = false,
    };

    // ACT: attempt to complete the task on a cancelled instance.
    const result = bpm.task_routes.handleComplete(
        &task_store,
        &instance_store,
        &id_service,
        allocator,
        actor,
        task_id,
        "{\"output_variables\":{}}",
    );
    defer allocator.free(result.body);

    // ASSERT: 409 with INSTANCE_NOT_ACTIVE error code.
    try std.testing.expectEqual(@as(u16, 409), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INSTANCE_NOT_ACTIVE"));

    // Verify no events were appended for this instance.
    var check_conn = try pool.acquire();
    defer pool.release(check_conn);

    const event_row = try check_conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM events WHERE instance_id = $1::uuid",
        &.{inst_id},
    );
    if (event_row) |r| {
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        const count_str = r[0] orelse "0";
        const count = std.fmt.parseInt(u32, count_str, 10) catch 0;
        try std.testing.expectEqual(@as(u32, 0), count);
    }
}

// ---------------------------------------------------------------------------
// TC2: complete task on COMPLETED instance → 409 INSTANCE_NOT_ACTIVE
// ---------------------------------------------------------------------------

test "ISS-208-TC2: task completion on completed instance returns 409 INSTANCE_NOT_ACTIVE" {
    const allocator = std.testing.allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    var h = helpers.TestHarness.init(allocator) catch |err| {
        if (err == error.MissingTestDatabaseUrl) return error.SkipZigTest;
        return err;
    };
    defer h.deinit();

    const tenant_id = "00000000-0000-0000-0000-000000000000";
    const def_id = try randomUuidStr(allocator);
    defer allocator.free(def_id);
    const inst_id = try randomUuidStr(allocator);
    defer allocator.free(inst_id);
    const task_id = try randomUuidStr(allocator);
    defer allocator.free(task_id);

    try h.conn.exec(
        \\INSERT INTO process_definitions (id, tenant_id, name, status, definition_artifact_hash, version, created_by, created_at, updated_at)
        \\VALUES ($1::uuid, $2::uuid, 'test-def-iss208-tc2', 'ACTIVE', 'hash-208-tc2', 1, $2::uuid, NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ def_id, tenant_id },
    );

    // Insert instance in COMPLETED status.
    try h.conn.exec(
        \\INSERT INTO instance_projections
        \\  (instance_id, tenant_id, definition_id, status, variables, current_nodes, definition_artifact_hash, started_at, updated_at, last_event_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, $3::uuid, 'COMPLETED', '{}', '[]', 'hash-208-tc2', NOW(), NOW(), 1)
        \\ON CONFLICT (instance_id) DO NOTHING
    ,
        &.{ inst_id, tenant_id, def_id },
    );

    const token_id_2 = try randomUuidStr(alloc);
    defer alloc.free(token_id_2);

    // Insert a token (required by tasks.token_id FK).
    try h.conn.exec(
        \\INSERT INTO tokens
        \\  (id, instance_id, current_node, status, created_at, updated_at)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'task-node-2', 'active', NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ token_id_2, inst_id },
    );

    try h.conn.exec(
        \\INSERT INTO tasks
        \\  (id, tenant_id, instance_id, token_id, node_id, node_name, status, assignee_ref, assignee_type, created_at, updated_at)
        \\VALUES
        \\  ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 'task-node-2', 'Task Node 2', 'PENDING', 'test-actor-208-tc2', 'USER', NOW(), NOW())
        \\ON CONFLICT (id) DO NOTHING
    ,
        &.{ task_id, tenant_id, inst_id, token_id_2 },
    );

    try h.conn.commit();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var snap_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snap_store);
    defer instance_store.deinit();

    var task_store = TaskStore.init(&pool);

    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    const actor = Actor{
        .user_id = "test-actor-208-tc2",
        .is_operator_or_above = true,
        .is_platform_admin = false,
    };

    const result = bpm.task_routes.handleComplete(
        &task_store,
        &instance_store,
        &id_service,
        allocator,
        actor,
        task_id,
        "{\"output_variables\":{}}",
    );
    defer allocator.free(result.body);

    // ASSERT: 409 with INSTANCE_NOT_ACTIVE.
    try std.testing.expectEqual(@as(u16, 409), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INSTANCE_NOT_ACTIVE"));
}
