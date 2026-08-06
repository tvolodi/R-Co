//! Integration tests for EE-03/EE-04 — Tasks HTTP route handlers.
//!
//! Tests exercise handleGetById and handleComplete against a real PostgreSQL
//! database.  All tests follow DIRECTIVE T-1: no mock DB connections, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   EE-04 / API-04 → TC-EE-04-01 through TC-EE-04-05
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const Instance = bpm.engine.Instance;

const TaskStore = bpm.tasks.TaskStore;
const Actor = bpm.task_routes.Actor;

// ---------------------------------------------------------------------------
// Fixed test UUIDs and constants
// ---------------------------------------------------------------------------

const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

// ---------------------------------------------------------------------------
// Minimal valid graph: START → HUMAN_TASK → END
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = "My Task", .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const minimal_graph = DefinitionGraph{ .nodes = &minimal_nodes, .edges = &minimal_edges };

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
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

fn parseUuid(_: std.mem.Allocator, s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

fn createActiveDefinition(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    name: []const u8,
    version: []const u8,
) ![16]u8 {
    const creator_id = try parseUuid(allocator, creator_uuid_str);
    const created = try def_store.create(allocator, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = creator_id,
    });
    const def_id = created.id;
    allocator.free(created.name);
    allocator.free(created.version);
    if (created.description) |d| allocator.free(d);
    if (created.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, created.graph);
    const activated = try def_store.activate(allocator, def_id);
    allocator.free(activated.name);
    allocator.free(activated.version);
    if (activated.description) |d| allocator.free(d);
    if (activated.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, activated.graph);
    return def_id;
}

/// Query the first PENDING task_id for the instance as a caller-owned hex string.
fn getFirstTaskIdStr(pool: *Pool, allocator: std.mem.Allocator, instance_id_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        allocator,
        "SELECT id FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING' LIMIT 1",
        &.{instance_id_hex},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0][0] == null) return error.NoTask;
    return allocator.dupe(u8, result.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-EE-04-01: handleGetById returns 200 for an existing task
// ---------------------------------------------------------------------------

test "TC-EE-04-01: handleGetById returns 200 with task JSON for existing task" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-04-01 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);

    var task_store = TaskStore.init(&pool);

    const result = bpm.task_routes.handleGetById(&task_store, alloc, task_id_str);
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"task_id\""));
}

// ---------------------------------------------------------------------------
// TC-EE-04-02: handleGetById with unknown UUID returns 404
// ---------------------------------------------------------------------------

test "TC-EE-04-02: handleGetById with unknown task_id returns 404" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var task_store = TaskStore.init(&pool);

    const result = bpm.task_routes.handleGetById(
        &task_store,
        alloc,
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
    );
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 404), result.status_code);
}

// ---------------------------------------------------------------------------
// TC-EE-04-03: handleGetById with invalid UUID string returns 422
// ---------------------------------------------------------------------------

test "TC-EE-04-03: handleGetById with invalid UUID string returns 422" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var task_store = TaskStore.init(&pool);

    const result = bpm.task_routes.handleGetById(&task_store, alloc, "not-a-uuid");
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// TC-EE-04-04: handleComplete returns 200 for a valid pending task
// ---------------------------------------------------------------------------

test "TC-EE-04-04: handleComplete returns 200 with status=ok for PENDING task" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-04-04 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);

    var task_store = TaskStore.init(&pool);
    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    const actor = Actor{
        .user_id = "00000000-0000-0000-0000-000000000099",
        .is_operator_or_above = true,
        .is_platform_admin = false,
    };

    const result = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &id_service,
        alloc,
        actor,
        task_id_str,
        "{\"output_variables\":{}}",
    );
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"status\":\"ok\""));
}

// ---------------------------------------------------------------------------
// TC-EE-04-05: handleComplete on already-completed task returns 409
// ---------------------------------------------------------------------------

test "TC-EE-04-05: handleComplete on already-completed task returns 409" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-EE-04-05 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);

    var task_store = TaskStore.init(&pool);
    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    const actor = Actor{
        .user_id = "00000000-0000-0000-0000-000000000099",
        .is_operator_or_above = true,
        .is_platform_admin = false,
    };

    // First complete — must succeed.
    {
        const r1 = bpm.task_routes.handleComplete(
            &task_store,
            &inst_store,
            &id_service,
            alloc,
            actor,
            task_id_str,
            "{\"output_variables\":{}}",
        );
        alloc.free(r1.body);
        try std.testing.expectEqual(@as(u16, 200), r1.status_code);
    }

    // Second complete — must return 409.
    const r2 = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &id_service,
        alloc,
        actor,
        task_id_str,
        "{\"output_variables\":{}}",
    );
    defer alloc.free(r2.body);

    try std.testing.expectEqual(@as(u16, 409), r2.status_code);
}
