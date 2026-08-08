//! Integration tests for API-03 — Instance management (GET endpoints).
//!
//! Covers InstanceStore.getById() and InstanceStore.listInstances() against a
//! real PostgreSQL database.  Handler-level input-validation tests (UUID parse,
//! status filter, page_size, cursor decode) live in tests/unit/api03_handler_test.zig
//! because they do not require a DB connection.
//!
//! Tests follow DIRECTIVE T-1: real PostgreSQL, no mocks or stubs.
//! Each test creates its own rows and cleans them up explicitly.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   API-03 → TC-API-03-01 (getById ACTIVE)
//!            TC-API-03-02 (getById unknown UUID → InstanceNotFound)
//!            TC-API-03-04 (getById COMPLETED)
//!            TC-API-03-05 (getById CANCELLED)
//!            TC-API-03-06 (getById variables)
//!            TC-API-03-07 (listInstances sort order)
//!            TC-API-03-08 (listInstances empty result)
//!            TC-API-03-15 (listInstances status filter)
//!            TC-API-03-16 (listInstances definition_id filter)
//!            TC-API-03-17 (listInstances cursor pagination)
//!            TC-API-03-18 (listInstances combined filters)
//!            TC-API-03-20 (getById null correlation_key)

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
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
const InstanceStatus = bpm.engine.InstanceStatus;
const GetByIdError = bpm.engine.GetByIdError;
const ListParams = bpm.engine.ListParams;
const Instance = bpm.engine.Instance;

const EventRegistry = bpm.registry.Registry;
const EventRegisterParams = bpm.registry.RegisterParams;
const AppendParams = bpm.store.AppendParams;
const EventStore = bpm.store.Store;
const handleHistory = bpm.instance_routes.handleHistory;
const HistoryParams = bpm.instance_routes.HistoryParams;

// ---------------------------------------------------------------------------
// Fixed test UUIDs and constants
// ---------------------------------------------------------------------------

/// Fake "created_by" UUID; no FK constraint on process_definitions.created_by.
// GH-512 retention: conventional creator_uuid_str module-scope fixture (no FK constraint, stable identity for created_by column)
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";
/// UUID guaranteed absent from any real test run.
// GH-512 retention: conventional not-found UUID sentinel (used to assert 404 response paths)
const nonexistent_uuid_str = "ffffffff-ffff-ffff-ffff-ffffffffffff";
/// Valid UUID used as actor_id for cancelInstance (must be valid UUID for events.actor_id column).
// GH-512 retention: platform-admin user_id (system actor); preserve identity for RBAC/role-guard assertions
const cancel_actor_uuid = "00000000-0000-0000-0000-000000000001";

// ---------------------------------------------------------------------------
// Minimal valid graph: START → HUMAN_TASK → END
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
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

/// Read BPM_TEST_DB_URL; return error.SkipZigTest if missing.
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

/// Create a Pool pointing to the test database.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Parse a UUID hex string (36 chars with hyphens) into [16]u8.
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

/// Render [16]u8 UUID as lowercase hex with hyphens (36 chars).
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

/// Create a definition and activate it; returns the definition UUID.
/// Caller must call cleanupDefinition() on exit.
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

/// Delete an instance and all its child rows in FK order.
fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

/// Delete a process_definition by name + version (best-effort).
fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

/// Free the allocator-owned fields of an Instance returned by InstanceStore.create().
fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

// ---------------------------------------------------------------------------
// TC-API-03-01: getById — ACTIVE instance returns InstanceWithTasks
// ---------------------------------------------------------------------------

test "TC-API-03-01: getById returns ACTIVE instance with tasks and non-null started_at" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-01 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const data = try instance_store.getById(alloc, inst_id);
    defer {
        if (data.correlation_key) |ck| alloc.free(ck);
        alloc.free(data.variables);
        if (data.error_detail) |ed| alloc.free(ed);
        for (data.tasks) |t| bpm.tasks.freeTask(alloc, t);
        alloc.free(data.tasks);
    }

    try testing.expectEqual(InstanceStatus.ACTIVE, data.status);
    try testing.expect(data.started_at > 0);
    try testing.expect(data.completed_at == null);
    try testing.expect(data.cancelled_at == null);
    // One PENDING task must exist (placed on HUMAN_TASK node after START fires).
    try testing.expect(data.tasks.len >= 1);
}

// ---------------------------------------------------------------------------
// TC-API-03-02: getById — unknown UUID returns InstanceNotFound
// ---------------------------------------------------------------------------

test "TC-API-03-02: getById with unknown UUID returns InstanceNotFound" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const unknown_id = try parseUuid(alloc, nonexistent_uuid_str);
    const result = instance_store.getById(alloc, unknown_id);
    try testing.expectError(GetByIdError.InstanceNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-API-03-04: getById — COMPLETED instance has completed_at set and empty tasks
// ---------------------------------------------------------------------------

test "TC-API-03-04: getById returns COMPLETED instance with completed_at and empty tasks" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-04 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    // Directly mark as COMPLETED with a timestamp and clear PENDING tasks.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\UPDATE instance_projections
            \\SET status = 'COMPLETED',
            \\    completed_at = NOW(),
            \\    current_nodes = '[]'
            \\WHERE instance_id = $1::uuid
        ,
            &.{inst_id_hex},
        );
        try conn.exec(
            "UPDATE tasks SET status = 'COMPLETED' WHERE instance_id = $1::uuid AND status = 'PENDING'",
            &.{inst_id_hex},
        );
    }

    const data = try instance_store.getById(alloc, inst_id);
    defer {
        if (data.correlation_key) |ck| alloc.free(ck);
        alloc.free(data.variables);
        if (data.error_detail) |ed| alloc.free(ed);
        for (data.tasks) |t| bpm.tasks.freeTask(alloc, t);
        alloc.free(data.tasks);
    }

    try testing.expectEqual(InstanceStatus.COMPLETED, data.status);
    try testing.expect(data.completed_at != null);
    try testing.expect(data.cancelled_at == null);
    try testing.expectEqual(@as(usize, 0), data.tasks.len);
}

// ---------------------------------------------------------------------------
// TC-API-03-05: getById — CANCELLED instance returns status=CANCELLED
// ---------------------------------------------------------------------------

test "TC-API-03-05: getById returns CANCELLED instance with cancelled_at non-null" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-05 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    var task_store = bpm.tasks.TaskStore.init(&pool);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    // Cancel via the EE-08 path.
    try instance_store.cancelInstance(alloc, &task_store, inst_id, cancel_actor_uuid);

    const data = try instance_store.getById(alloc, inst_id);
    defer {
        if (data.correlation_key) |ck| alloc.free(ck);
        alloc.free(data.variables);
        if (data.error_detail) |ed| alloc.free(ed);
        for (data.tasks) |t| bpm.tasks.freeTask(alloc, t);
        alloc.free(data.tasks);
    }

    // Acceptance criterion: CANCELLED instance returns status=CANCELLED, not HTTP 409.
    try testing.expectEqual(InstanceStatus.CANCELLED, data.status);
    try testing.expect(data.cancelled_at != null);
    try testing.expect(data.completed_at == null);
    try testing.expectEqual(@as(usize, 0), data.tasks.len);
}

// ---------------------------------------------------------------------------
// TC-API-03-06: getById — variables field is a parseable JSON object
// ---------------------------------------------------------------------------

test "TC-API-03-06: getById returns variables as a parseable JSON string" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-06 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    const inst = try instance_store.create(alloc, def_id, null, "{\"amount\":500,\"approved\":false}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const data = try instance_store.getById(alloc, inst_id);
    defer {
        if (data.correlation_key) |ck| alloc.free(ck);
        alloc.free(data.variables);
        if (data.error_detail) |ed| alloc.free(ed);
        for (data.tasks) |t| bpm.tasks.freeTask(alloc, t);
        alloc.free(data.tasks);
    }

    // variables must be a parseable JSON object containing the "amount" key.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, data.variables, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("amount") != null);
}

// ---------------------------------------------------------------------------
// TC-API-03-07: listInstances — results are sorted started_at DESC
// ---------------------------------------------------------------------------

test "TC-API-03-07: listInstances returns instances in started_at DESC order" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-07 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    // Create three instances in sequence.
    var instance_ids: [3][16]u8 = undefined;
    for (0..3) |i| {
        const inst = try instance_store.create(alloc, def_id, null, "{}");
        instance_ids[i] = inst.instance_id;
        freeInstance(alloc, inst);
    }
    defer {
        for (instance_ids) |id| {
            const hex = uuidToHexStr(alloc, id) catch continue;
            defer alloc.free(hex);
            cleanupInstance(&pool, hex);
        }
    }

    const rows = try instance_store.listInstances(alloc, ListParams{
        .status = null,
        .definition_id = def_id,
        .cursor_started_at = null,
        .cursor_instance_id = null,
        .page_size = 50,
    });
    defer {
        for (rows) |row| {
            if (row.correlation_key) |ck| alloc.free(ck);
        }
        alloc.free(rows);
    }

    // At least 3 rows for this definition.
    try testing.expect(rows.len >= 3);

    // Each started_at must be >= the next (DESC ordering).
    for (0..rows.len - 1) |i| {
        try testing.expect(rows[i].started_at >= rows[i + 1].started_at);
    }
}

// ---------------------------------------------------------------------------
// TC-API-03-08: listInstances — no matching rows returns empty slice (HTTP 200)
// ---------------------------------------------------------------------------

test "TC-API-03-08: listInstances with no matching definition_id returns empty slice" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    // Use a definition_id that has never been used — guarantees zero rows.
    const never_used_def_id = try parseUuid(alloc, nonexistent_uuid_str);

    const rows = try instance_store.listInstances(alloc, ListParams{
        .status = null,
        .definition_id = never_used_def_id,
        .cursor_started_at = null,
        .cursor_instance_id = null,
        .page_size = 50,
    });
    defer alloc.free(rows);

    try testing.expectEqual(@as(usize, 0), rows.len);
}

// ---------------------------------------------------------------------------
// TC-API-03-15: listInstances — status filter returns only matching instances
// ---------------------------------------------------------------------------

test "TC-API-03-15: listInstances with status=ACTIVE returns only ACTIVE instances" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-15 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    var task_store = bpm.tasks.TaskStore.init(&pool);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    // Create two ACTIVE instances and one that will be cancelled.
    const inst_a = try instance_store.create(alloc, def_id, null, "{}");
    const id_a = inst_a.instance_id;
    freeInstance(alloc, inst_a);

    const inst_b = try instance_store.create(alloc, def_id, null, "{}");
    const id_b = inst_b.instance_id;
    freeInstance(alloc, inst_b);

    const inst_c = try instance_store.create(alloc, def_id, null, "{}");
    const id_c = inst_c.instance_id;
    freeInstance(alloc, inst_c);
    try instance_store.cancelInstance(alloc, &task_store, id_c, cancel_actor_uuid);

    const hex_a = try uuidToHexStr(alloc, id_a);
    defer alloc.free(hex_a);
    const hex_b = try uuidToHexStr(alloc, id_b);
    defer alloc.free(hex_b);
    const hex_c = try uuidToHexStr(alloc, id_c);
    defer alloc.free(hex_c);
    defer cleanupInstance(&pool, hex_a);
    defer cleanupInstance(&pool, hex_b);
    defer cleanupInstance(&pool, hex_c);

    const rows = try instance_store.listInstances(alloc, ListParams{
        .status = "ACTIVE",
        .definition_id = def_id,
        .cursor_started_at = null,
        .cursor_instance_id = null,
        .page_size = 50,
    });
    defer {
        for (rows) |row| {
            if (row.correlation_key) |ck| alloc.free(ck);
        }
        alloc.free(rows);
    }

    // Exactly 2 ACTIVE instances (A and B); C is CANCELLED.
    try testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| {
        try testing.expectEqual(bpm.engine.InstanceStatus.ACTIVE, row.status);
    }
}

// ---------------------------------------------------------------------------
// TC-API-03-16: listInstances — definition_id filter returns only matching instances
// ---------------------------------------------------------------------------

test "TC-API-03-16: listInstances with definition_id filter returns only matching instances" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name_a = "TC-API-03-16 Proc A";
    const def_name_b = "TC-API-03-16 Proc B";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name_a, def_version);
    defer cleanupDefinition(&pool, def_name_b, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id_a = try createActiveDefinition(alloc, &def_store, def_name_a, def_version);
    const def_id_b = try createActiveDefinition(alloc, &def_store, def_name_b, def_version);

    // Two instances for definition A, one for definition B.
    const inst_a1 = try instance_store.create(alloc, def_id_a, null, "{}");
    const id_a1 = inst_a1.instance_id;
    freeInstance(alloc, inst_a1);

    const inst_a2 = try instance_store.create(alloc, def_id_a, null, "{}");
    const id_a2 = inst_a2.instance_id;
    freeInstance(alloc, inst_a2);

    const inst_b1 = try instance_store.create(alloc, def_id_b, null, "{}");
    const id_b1 = inst_b1.instance_id;
    freeInstance(alloc, inst_b1);

    const hex_a1 = try uuidToHexStr(alloc, id_a1);
    defer alloc.free(hex_a1);
    const hex_a2 = try uuidToHexStr(alloc, id_a2);
    defer alloc.free(hex_a2);
    const hex_b1 = try uuidToHexStr(alloc, id_b1);
    defer alloc.free(hex_b1);
    defer cleanupInstance(&pool, hex_a1);
    defer cleanupInstance(&pool, hex_a2);
    defer cleanupInstance(&pool, hex_b1);

    const rows = try instance_store.listInstances(alloc, ListParams{
        .status = null,
        .definition_id = def_id_a,
        .cursor_started_at = null,
        .cursor_instance_id = null,
        .page_size = 50,
    });
    defer {
        for (rows) |row| {
            if (row.correlation_key) |ck| alloc.free(ck);
        }
        alloc.free(rows);
    }

    // Exactly 2 rows — both belong to definition A.
    try testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| {
        try testing.expect(std.mem.eql(u8, &row.definition_id, &def_id_a));
    }
}

// ---------------------------------------------------------------------------
// TC-API-03-17: listInstances — cursor-based pagination yields non-overlapping pages
// ---------------------------------------------------------------------------

test "TC-API-03-17: listInstances cursor pagination produces non-overlapping pages" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-17 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    // Create exactly 3 instances.
    var instance_ids: [3][16]u8 = undefined;
    for (0..3) |i| {
        const inst = try instance_store.create(alloc, def_id, null, "{}");
        instance_ids[i] = inst.instance_id;
        freeInstance(alloc, inst);
    }
    defer {
        for (instance_ids) |id| {
            const hex = uuidToHexStr(alloc, id) catch continue;
            defer alloc.free(hex);
            cleanupInstance(&pool, hex);
        }
    }

    // Page 1: page_size = 2. The store returns up to page_size+1 rows to signal has_next.
    const page1_rows = try instance_store.listInstances(alloc, ListParams{
        .status = null,
        .definition_id = def_id,
        .cursor_started_at = null,
        .cursor_instance_id = null,
        .page_size = 2,
    });
    defer {
        for (page1_rows) |row| {
            if (row.correlation_key) |ck| alloc.free(ck);
        }
        alloc.free(page1_rows);
    }

    // The store must return 3 rows (page_size+1) to indicate has_next.
    try testing.expect(page1_rows.len >= 3);

    // Build cursor from the second item (the last displayed item on page 1).
    const last_on_page1 = page1_rows[1];
    const cursor_id_hex = try uuidToHexStr(alloc, last_on_page1.instance_id);
    defer alloc.free(cursor_id_hex);

    // Page 2: seek past the last item on page 1.
    const page2_rows = try instance_store.listInstances(alloc, ListParams{
        .status = null,
        .definition_id = def_id,
        .cursor_started_at = last_on_page1.started_at,
        .cursor_instance_id = cursor_id_hex,
        .page_size = 2,
    });
    defer {
        for (page2_rows) |row| {
            if (row.correlation_key) |ck| alloc.free(ck);
        }
        alloc.free(page2_rows);
    }

    // Page 2 must have at least the third instance.
    try testing.expect(page2_rows.len >= 1);

    // No instance_id should appear in both pages (non-overlapping).
    for (page1_rows[0..2]) |r1| {
        for (page2_rows) |r2| {
            try testing.expect(!std.mem.eql(u8, &r1.instance_id, &r2.instance_id));
        }
    }
}

// ---------------------------------------------------------------------------
// TC-API-03-18: listInstances — combined status + definition_id filter
// ---------------------------------------------------------------------------

test "TC-API-03-18: listInstances with combined status=ACTIVE and definition_id filter returns one row" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name_x = "TC-API-03-18 Proc X";
    const def_name_y = "TC-API-03-18 Proc Y";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name_x, def_version);
    defer cleanupDefinition(&pool, def_name_y, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    var task_store = bpm.tasks.TaskStore.init(&pool);

    const def_id_x = try createActiveDefinition(alloc, &def_store, def_name_x, def_version);
    const def_id_y = try createActiveDefinition(alloc, &def_store, def_name_y, def_version);

    // Instance A: def X, stays ACTIVE.
    const inst_a = try instance_store.create(alloc, def_id_x, null, "{}");
    const id_a = inst_a.instance_id;
    freeInstance(alloc, inst_a);

    // Instance B: def X, gets CANCELLED.
    const inst_b = try instance_store.create(alloc, def_id_x, null, "{}");
    const id_b = inst_b.instance_id;
    freeInstance(alloc, inst_b);
    try instance_store.cancelInstance(alloc, &task_store, id_b, cancel_actor_uuid);

    // Instance C: def Y, ACTIVE (must NOT appear in results filtered by def X).
    const inst_c = try instance_store.create(alloc, def_id_y, null, "{}");
    const id_c = inst_c.instance_id;
    freeInstance(alloc, inst_c);

    const hex_a = try uuidToHexStr(alloc, id_a);
    defer alloc.free(hex_a);
    const hex_b = try uuidToHexStr(alloc, id_b);
    defer alloc.free(hex_b);
    const hex_c = try uuidToHexStr(alloc, id_c);
    defer alloc.free(hex_c);
    defer cleanupInstance(&pool, hex_a);
    defer cleanupInstance(&pool, hex_b);
    defer cleanupInstance(&pool, hex_c);

    // Query: ACTIVE instances of definition X only → expect exactly Instance A.
    const rows = try instance_store.listInstances(alloc, ListParams{
        .status = "ACTIVE",
        .definition_id = def_id_x,
        .cursor_started_at = null,
        .cursor_instance_id = null,
        .page_size = 50,
    });
    defer {
        for (rows) |row| {
            if (row.correlation_key) |ck| alloc.free(ck);
        }
        alloc.free(rows);
    }

    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expect(std.mem.eql(u8, &rows[0].instance_id, &id_a));
    try testing.expectEqual(bpm.engine.InstanceStatus.ACTIVE, rows[0].status);
}

// ---------------------------------------------------------------------------
// TC-API-03-20: getById — correlation_key is null when not supplied at create time
// ---------------------------------------------------------------------------

test "TC-API-03-20: getById returns null correlation_key when not set at create time" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-03-20 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    // Create with no correlation_key.
    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const data = try instance_store.getById(alloc, inst_id);
    defer {
        if (data.correlation_key) |ck| alloc.free(ck);
        alloc.free(data.variables);
        if (data.error_detail) |ed| alloc.free(ed);
        for (data.tasks) |t| bpm.tasks.freeTask(alloc, t);
        alloc.free(data.tasks);
    }

    try testing.expect(data.correlation_key == null);
}

// ---------------------------------------------------------------------------
// TC-API-05-01: handleHistory returns 200 with events for an instance
// ---------------------------------------------------------------------------

test "TC-API-05-01: handleHistory returns 200 with event items for instance with appended event" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-05-01 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    // Register an event type and append one event.
    var ev_registry = EventRegistry.init(alloc, &pool);
    defer ev_registry.deinit();
    _ = ev_registry.registerType(alloc, EventRegisterParams{
        .name = "API05_TEST_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var ev_store = EventStore.init(alloc, &pool, &ev_registry);
    defer ev_store.deinit();

// GH-512 retention: conventional creator_uuid_str module-scope fixture (no FK constraint, stable identity for created_by column)
    const actor_uuid = try parseUuid(alloc, "00000000-0000-0000-0000-000000000099");
    _ = try ev_store.append(alloc, AppendParams{
        .instance_id = inst_id,
        .event_type = "API05_TEST_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "api05-01-idem-01",
        .metadata = null,
    });

    const result = handleHistory(&ev_store, alloc, inst_id_hex, HistoryParams{});
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"items\""));
}

// ---------------------------------------------------------------------------
// TC-API-05-02: handleHistory with nonexistent instance UUID returns 404
// ---------------------------------------------------------------------------

test "TC-API-05-02: handleHistory with nonexistent instance UUID returns 404" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var ev_registry = EventRegistry.init(alloc, &pool);
    defer ev_registry.deinit();

    var ev_store = EventStore.init(alloc, &pool, &ev_registry);
    defer ev_store.deinit();

    const result = handleHistory(
        &ev_store,
        alloc,
// GH-512 retention: conventional not-found UUID sentinel (used to assert 404 response paths)
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
        HistoryParams{},
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 404), result.status_code);
}

// ---------------------------------------------------------------------------
// TC-API-05-03: handleHistory with invalid UUID string returns 422
// ---------------------------------------------------------------------------

test "TC-API-05-03: handleHistory with invalid instance_id string returns 422" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var ev_registry = EventRegistry.init(alloc, &pool);
    defer ev_registry.deinit();

    var ev_store = EventStore.init(alloc, &pool, &ev_registry);
    defer ev_store.deinit();

    const result = handleHistory(&ev_store, alloc, "bad-uuid", HistoryParams{});
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// TC-API-05-04: handleHistory with existing instance and no events returns 200
// ---------------------------------------------------------------------------

test "TC-API-05-04: handleHistory returns 200 with empty items for instance with no appended events" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-05-04 Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    var ev_registry = EventRegistry.init(alloc, &pool);
    defer ev_registry.deinit();

    var ev_store = EventStore.init(alloc, &pool, &ev_registry);
    defer ev_store.deinit();

    const result = handleHistory(&ev_store, alloc, inst_id_hex, HistoryParams{});
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"items\""));
}
