//! Integration tests for EE-01 — Start Instance.
//!
//! Tests exercise InstanceStore.create() against a real PostgreSQL database.
//! All tests follow DIRECTIVE T-1: no mock DB connections, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//! Every test calls TestHarness.init() to ensure migrations are applied before
//! accessing the Pool / Store.
//!
//! Isolation: each test cleans up its own rows explicitly in FK order
//! (instance_definition_snapshots → instance_projections → process_definitions)
//! because InstanceStore.create() commits its own transactions independently
//! from the TestHarness rollback transaction.
//!
//! Requirement traceability:
//!   EE-01 → TC-EE-01-01 through TC-EE-01-12
const std = @import("std");
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
const Definition = bpm.definition.Definition;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const InstanceError = bpm.engine.InstanceError;
const Instance = bpm.engine.Instance;
const InstanceStatus = bpm.engine.InstanceStatus;

// ---------------------------------------------------------------------------
// Fixed test UUIDs
// ---------------------------------------------------------------------------

/// Fake "created_by" UUID; no FK constraint on process_definitions.created_by.
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";
/// Definition_id guaranteed absent from any real test run.
const nonexistent_uuid_str = "00000000-0000-4000-8000-000000000000";

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
// Helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL; return error.SkipZigTest if missing.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
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

/// Free heap-allocated fields of an Instance returned by InstanceStore.create().
fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

/// Free heap-allocated fields of a Definition returned by DefinitionStore methods.
fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
}

/// Delete instance_definition_snapshots and instance_projections rows for one instance.
/// Must run before cleanupByName (FK order: snapshots → projections → definitions).
fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    ) catch {};
    conn.exec(
        "DELETE FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    ) catch {};
}

/// Delete all process_definitions rows with the given name. Best-effort.
fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &.{name},
    ) catch {};
}

// ---------------------------------------------------------------------------
// TC-EE-01-01: Successfully start instance with initial_variables → ACTIVE
// ---------------------------------------------------------------------------

test "TC-EE-01-01: start instance with initial_variables returns ACTIVE instance" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-01 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);

    // cleanupByName registered first → executes last (after instance rows removed).
    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, draft.id, null, "{\"amount\":100}");

    // Defers (LIFO): freeInstance → cleanupInstance → alloc.free(inst_hex) → cleanupByName.
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex); // runs 3rd (after cleanupInstance uses it)
    defer cleanupInstance(&pool, inst_hex); // runs 2nd
    defer freeInstance(alloc, inst); // runs 1st

    try std.testing.expectEqual(InstanceStatus.ACTIVE, inst.status);

    // instance_id must be non-zero.
    var all_zero = true;
    for (inst.instance_id) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

// ---------------------------------------------------------------------------
// TC-EE-01-02: Start with correlation_key — stored correctly
// ---------------------------------------------------------------------------

test "TC-EE-01-02: start instance with correlation_key stores it in Instance" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-02 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);

    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const ck = "order-42";
    const inst = try inst_store.create(alloc, draft.id, ck, "{}");

    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    try std.testing.expect(inst.correlation_key != null);
    try std.testing.expectEqualStrings(ck, inst.correlation_key.?);
    try std.testing.expectEqual(InstanceStatus.ACTIVE, inst.status);
}

// ---------------------------------------------------------------------------
// TC-EE-01-03: Non-existent definition_id → DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-EE-01-03: non-existent definition_id returns DefinitionNotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const absent_id = try parseUuid(alloc, nonexistent_uuid_str);

    const result = inst_store.create(alloc, absent_id, null, "{}");
    try std.testing.expectError(InstanceError.DefinitionNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-EE-01-04: DRAFT definition → DefinitionNotActive
// ---------------------------------------------------------------------------

test "TC-EE-01-04: DRAFT definition returns DefinitionNotActive" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-04 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create definition but do NOT activate — it remains DRAFT.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);
    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const result = inst_store.create(alloc, draft.id, null, "{}");
    try std.testing.expectError(InstanceError.DefinitionNotActive, result);
}

// ---------------------------------------------------------------------------
// TC-EE-01-05: DEPRECATED definition → DefinitionNotActive
// ---------------------------------------------------------------------------

test "TC-EE-01-05: DEPRECATED definition returns DefinitionNotActive" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-05 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create → activate → deprecate.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);

    const deprecated = try def_store.deprecate(alloc, draft.id);
    defer freeDefinition(alloc, deprecated);
    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const result = inst_store.create(alloc, draft.id, null, "{}");
    try std.testing.expectError(InstanceError.DefinitionNotActive, result);
}

// ---------------------------------------------------------------------------
// TC-EE-01-06: Duplicate correlation_key same definition → DuplicateCorrelationKey
// ---------------------------------------------------------------------------

test "TC-EE-01-06: duplicate correlation_key same definition returns DuplicateCorrelationKey" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-06 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);

    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const ck = "ck-ee01-06";

    // First call succeeds.
    const inst1 = try inst_store.create(alloc, draft.id, ck, "{}");
    const inst1_hex = try uuidToHexStr(alloc, inst1.instance_id);
    defer alloc.free(inst1_hex);
    defer cleanupInstance(&pool, inst1_hex);
    defer freeInstance(alloc, inst1);

    // Second call with identical correlation_key must fail.
    const result = inst_store.create(alloc, draft.id, ck, "{}");
    try std.testing.expectError(InstanceError.DuplicateCorrelationKey, result);
}

// ---------------------------------------------------------------------------
// TC-EE-01-07: Same correlation_key different definition → 201 both times
// ---------------------------------------------------------------------------

test "TC-EE-01-07: same correlation_key on different definitions succeeds for both" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name_a = "TC-EE-01-07-A Process";
    const name_b = "TC-EE-01-07-B Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Definition A.
    const draft_a = try def_store.create(alloc, CreateParams{
        .name = name_a,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft_a);
    const active_a = try def_store.activate(alloc, draft_a.id);
    defer freeDefinition(alloc, active_a);
    defer cleanupByName(&pool, name_a);

    // Definition B.
    const draft_b = try def_store.create(alloc, CreateParams{
        .name = name_b,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft_b);
    const active_b = try def_store.activate(alloc, draft_b.id);
    defer freeDefinition(alloc, active_b);
    defer cleanupByName(&pool, name_b);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const ck = "ck-ee01-07";

    // Instance for definition A.
    const inst_a = try inst_store.create(alloc, draft_a.id, ck, "{}");
    const inst_a_hex = try uuidToHexStr(alloc, inst_a.instance_id);
    defer alloc.free(inst_a_hex);
    defer cleanupInstance(&pool, inst_a_hex);
    defer freeInstance(alloc, inst_a);

    // Instance for definition B with the same correlation_key — must NOT conflict.
    const inst_b = try inst_store.create(alloc, draft_b.id, ck, "{}");
    const inst_b_hex = try uuidToHexStr(alloc, inst_b.instance_id);
    defer alloc.free(inst_b_hex);
    defer cleanupInstance(&pool, inst_b_hex);
    defer freeInstance(alloc, inst_b);

    try std.testing.expectEqual(InstanceStatus.ACTIVE, inst_a.status);
    try std.testing.expectEqual(InstanceStatus.ACTIVE, inst_b.status);

    // The two instances must have distinct IDs.
    try std.testing.expect(!std.mem.eql(u8, &inst_a.instance_id, &inst_b.instance_id));
}

// ---------------------------------------------------------------------------
// TC-EE-01-08: null initial_variables → InvalidInput
// ---------------------------------------------------------------------------

test "TC-EE-01-08: null initial_variables string returns InvalidInput" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // "null" is valid JSON but not a JSON object — validation at step (a).
    const absent_id = try parseUuid(alloc, nonexistent_uuid_str);
    const result = inst_store.create(alloc, absent_id, null, "null");
    try std.testing.expectError(InstanceError.InvalidInput, result);
}

// ---------------------------------------------------------------------------
// TC-EE-01-09: initial_variables is array → InvalidInput
// ---------------------------------------------------------------------------

test "TC-EE-01-09: array initial_variables returns InvalidInput" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // "[]" is valid JSON but a JSON array, not an object — validation at step (a).
    const absent_id = try parseUuid(alloc, nonexistent_uuid_str);
    const result = inst_store.create(alloc, absent_id, null, "[]");
    try std.testing.expectError(InstanceError.InvalidInput, result);
}

// ---------------------------------------------------------------------------
// TC-EE-01-10: initial_variables = {} empty object → success
// ---------------------------------------------------------------------------

test "TC-EE-01-10: empty object initial_variables is valid and returns ACTIVE instance" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-10 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);

    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, draft.id, null, "{}");

    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    try std.testing.expectEqual(InstanceStatus.ACTIVE, inst.status);
}

// ---------------------------------------------------------------------------
// TC-EE-01-11: No correlation_key — multiple instances allowed
// ---------------------------------------------------------------------------

test "TC-EE-01-11: two instances with no correlation_key both succeed with distinct IDs" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-11 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);

    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // First instance — no correlation_key.
    const inst1 = try inst_store.create(alloc, draft.id, null, "{}");
    const inst1_hex = try uuidToHexStr(alloc, inst1.instance_id);
    defer alloc.free(inst1_hex);
    defer cleanupInstance(&pool, inst1_hex);
    defer freeInstance(alloc, inst1);

    // Second instance — same definition, no correlation_key. Must also succeed.
    const inst2 = try inst_store.create(alloc, draft.id, null, "{}");
    const inst2_hex = try uuidToHexStr(alloc, inst2.instance_id);
    defer alloc.free(inst2_hex);
    defer cleanupInstance(&pool, inst2_hex);
    defer freeInstance(alloc, inst2);

    try std.testing.expectEqual(InstanceStatus.ACTIVE, inst1.status);
    try std.testing.expectEqual(InstanceStatus.ACTIVE, inst2.status);
    try std.testing.expect(!std.mem.eql(u8, &inst1.instance_id, &inst2.instance_id));
}

// ---------------------------------------------------------------------------
// TC-EE-01-12: Verify definition snapshot stored in instance_definition_snapshots
// ---------------------------------------------------------------------------

test "TC-EE-01-12: successful create stores a snapshot row in instance_definition_snapshots" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-EE-01-12 Process";
    const created_by = try parseUuid(alloc, creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active_def = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active_def);

    defer cleanupByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, draft.id, null, "{\"verified\":true}");

    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // Verify that instance_definition_snapshots contains exactly one row
    // with instance_id matching the newly created instance.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const snap_rows = try conn.query(
        alloc,
        "SELECT 1 FROM instance_definition_snapshots WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer {
        var r = snap_rows;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), snap_rows.rows.len);
}
