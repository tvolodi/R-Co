//! Integration tests for PD-08 — Definition snapshot.
//!
//! Tests exercise SnapshotStore.create() and SnapshotStore.getByInstanceId()
//! against a real PostgreSQL database.  All 7 test cases from
//! tests/specs/PD-08.md are implemented here.
//!
//! Requires: BPM_TEST_DB_URL environment variable.
//! Each test calls TestHarness.init() to run migrations, then creates its own
//! Pool for SnapshotStore and DefinitionStore operations.
//!
//! Isolation: each test cleans up its own rows explicitly in the correct FK
//! order (snapshots before definitions) since SnapshotStore transactions are
//! committed independently from TestHarness.
//!
//! Requirement traceability:
//!   PD-08 → TC-PD-08-01, TC-PD-08-02, TC-PD-08-03, TC-PD-08-04,
//!            TC-PD-08-05, TC-PD-08-06, TC-PD-08-07
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
const Definition = bpm.definition.Definition;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const SnapshotError = bpm.snapshot.SnapshotError;
const Snapshot = bpm.snapshot.Snapshot;

// ---------------------------------------------------------------------------
// Fixed test UUIDs (deterministic — no RNG dependency)
// ---------------------------------------------------------------------------

/// Fake "created_by" UUID; no FK constraint on process_definitions.created_by.
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

/// Instance UUID prefix for TC-PD-08-01
const inst_01_str = "00000000-0000-0000-0000-000000000801";
/// Instance UUID for TC-PD-08-02
const inst_02_str = "00000000-0000-0000-0000-000000000802";
/// Instance UUID for TC-PD-08-03
const inst_03_str = "00000000-0000-0000-0000-000000000803";
/// Instance UUID for TC-PD-08-04
const inst_04_str = "00000000-0000-0000-0000-000000000804";
/// Instance UUID for TC-PD-08-05 (no snapshot written)
const inst_05_str = "00000000-0000-0000-0000-000000000805";
/// Instance UUID for TC-PD-08-06
const inst_06_str = "00000000-0000-0000-0000-000000000806";
/// Instance UUIDs A and B for TC-PD-08-07
const inst_07a_str = "00000000-0000-0000-0000-000000000807";
const inst_07b_str = "00000000-0000-0000-0000-000000000808";

/// A definition_id guaranteed not to exist in any test run.
const unknown_def_str = "ffffffff-ffff-ffff-ffff-ffffffffffff";

// ---------------------------------------------------------------------------
// Minimal valid graph: START → HUMAN_TASK → END  (3 nodes, 2 edges)
// HUMAN_TASK requires role attribute per PD-05.
// ---------------------------------------------------------------------------

const g1_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const g1_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const graph_g1 = DefinitionGraph{ .nodes = &g1_nodes, .edges = &g1_edges };

// g2_json — used in SQL UPDATE to simulate a definition graph change.
// Graph G2 has 4 nodes (adds a second HUMAN_TASK), allowing comparison with
// G1's 3 nodes to confirm snapshot independence.
const g2_json =
    \\{"nodes":[{"id":"S","node_type":"START","label":null,"attributes":null},{"id":"T1","node_type":"HUMAN_TASK","label":null,"attributes":"{\"role\":\"tester\"}"},{"id":"T2","node_type":"HUMAN_TASK","label":null,"attributes":"{\"role\":\"reviewer\"}"},{"id":"E","node_type":"END","label":null,"attributes":null}],"edges":[{"id":"e1","source":"S","target":"T1","condition":null,"is_default":false},{"id":"e2","source":"T1","target":"T2","condition":null,"is_default":false},{"id":"e3","source":"T2","target":"E","condition":null,"is_default":false}]}
;

// Graph G3 for TC-PD-08-06: includes EXCLUSIVE_GATEWAY with conditioned edges.
// START → HUMAN_TASK → EXCLUSIVE_GATEWAY → END (two paths)
const g3_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"approver\"}" },
    .{ .id = "GW", .node_type = .EXCLUSIVE_GATEWAY, .label = null, .attributes = null },
    .{ .id = "E1", .node_type = .END, .label = null, .attributes = null },
    .{ .id = "E2", .node_type = .END, .label = "default", .attributes = null },
};
const g3_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "GW", .condition = null, .is_default = false },
    .{ .id = "e3", .source = "GW", .target = "E1", .condition = "approved == true", .is_default = false },
    .{ .id = "e4", .source = "GW", .target = "E2", .condition = null, .is_default = true },
};
const graph_g3 = DefinitionGraph{ .nodes = &g3_nodes, .edges = &g3_edges };

// ---------------------------------------------------------------------------
// Helpers
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

/// Free all allocator-owned memory inside a Snapshot returned by SnapshotStore.
fn freeSnapshot(allocator: std.mem.Allocator, s: Snapshot) void {
    allocator.free(s.definition_name);
    allocator.free(s.definition_ver);
    for (s.graph.nodes) |n| {
        allocator.free(n.id);
        if (n.label) |l| allocator.free(l);
        if (n.attributes) |a| allocator.free(a);
    }
    allocator.free(s.graph.nodes);
    for (s.graph.edges) |e| {
        allocator.free(e.id);
        allocator.free(e.source);
        allocator.free(e.target);
        if (e.condition) |c| allocator.free(c);
    }
    allocator.free(s.graph.edges);
}

/// Free allocator-owned fields of a Definition returned by DefinitionStore.create().
fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

/// Delete snapshot rows by instance_id hex string.  Best-effort; ignores errors.
fn cleanupSnapshot(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    ) catch {};
}

/// Delete definition rows by name prefix.  Best-effort; ignores errors.
/// Must be called AFTER cleanupSnapshot when FK constraints are present.
fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &.{name},
    ) catch {};
}

/// Update process_definitions.graph for a given definition id.
fn updateGraph(pool: *Pool, def_id_hex: []const u8, new_graph_json: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "UPDATE process_definitions SET graph = $1::jsonb WHERE id = $2::uuid",
        &.{ new_graph_json, def_id_hex },
    );
}

// ---------------------------------------------------------------------------
// TC-PD-08-01: Create snapshot — happy path
// ---------------------------------------------------------------------------

test "TC-PD-08-01: SnapshotStore.create — happy path returns Snapshot with matching fields" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-08-01 Process";
    const def_ver = "1.0.0";

    const instance_id = try parseUuid(alloc, inst_01_str);
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = def_ver,
        .description = null,
        .graph = graph_g1,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    const inst_hex = try uuidToHexStr(alloc, instance_id);
    defer alloc.free(inst_hex);

    // Cleanup: snapshots must be deleted before definitions.
    defer cleanupSnapshot(&pool, inst_hex);
    defer cleanupByName(&pool, def_name);

    var snap_store = SnapshotStore{ .pool = &pool };

    const snap = try snap_store.create(alloc, instance_id, def.id);
    defer freeSnapshot(alloc, snap);

    // Verify snapshot fields match the source definition.
    try std.testing.expect(std.mem.eql(u8, &snap.definition_id, &def.id));
    try std.testing.expectEqualStrings(def_name, snap.definition_name);
    try std.testing.expectEqualStrings(def_ver, snap.definition_ver);
    try std.testing.expect(snap.snapshotted_at > 0);
}

// ---------------------------------------------------------------------------
// TC-PD-08-02: Snapshot is independent of subsequent definition update
// ---------------------------------------------------------------------------

test "TC-PD-08-02: SnapshotStore.getByInstanceId — returns original graph after definition update" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-08-02 Process";
    const instance_id = try parseUuid(alloc, inst_02_str);
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Create definition with G1 (3 nodes).
    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = graph_g1,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    const inst_hex = try uuidToHexStr(alloc, instance_id);
    defer alloc.free(inst_hex);
    const def_id_hex = try uuidToHexStr(alloc, def.id);
    defer alloc.free(def_id_hex);

    defer cleanupSnapshot(&pool, inst_hex);
    defer cleanupByName(&pool, def_name);

    var snap_store = SnapshotStore{ .pool = &pool };

    // Create snapshot while the definition has G1 (3 nodes).
    const snap1 = try snap_store.create(alloc, instance_id, def.id);
    defer freeSnapshot(alloc, snap1);
    const original_node_count = snap1.graph.nodes.len; // Should be 3

    // Simulate a definition update: overwrite graph with G2 (4 nodes).
    try updateGraph(&pool, def_id_hex, g2_json);

    // Read the snapshot back — must still reflect G1 (3 nodes).
    const snap2 = try snap_store.getByInstanceId(alloc, instance_id);
    defer freeSnapshot(alloc, snap2);

    try std.testing.expectEqual(original_node_count, snap2.graph.nodes.len);
    // G2 has 4 nodes; confirm the snapshot is NOT reflecting the update.
    try std.testing.expect(snap2.graph.nodes.len != 4);
}

// ---------------------------------------------------------------------------
// TC-PD-08-03: Duplicate instance_id returns SnapshotAlreadyExists
// ---------------------------------------------------------------------------

test "TC-PD-08-03: SnapshotStore.create — duplicate instance_id returns SnapshotAlreadyExists" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-08-03 Process";
    const instance_id = try parseUuid(alloc, inst_03_str);
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = graph_g1,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    const inst_hex = try uuidToHexStr(alloc, instance_id);
    defer alloc.free(inst_hex);

    defer cleanupSnapshot(&pool, inst_hex);
    defer cleanupByName(&pool, def_name);

    var snap_store = SnapshotStore{ .pool = &pool };

    // First create must succeed.
    const snap = try snap_store.create(alloc, instance_id, def.id);
    freeSnapshot(alloc, snap);

    // Second create with the same instance_id must return SnapshotAlreadyExists.
    const result = snap_store.create(alloc, instance_id, def.id);
    try std.testing.expectError(SnapshotError.SnapshotAlreadyExists, result);
}

// ---------------------------------------------------------------------------
// TC-PD-08-04: Unknown definition_id returns DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-08-04: SnapshotStore.create — unknown definition_id returns DefinitionNotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = try parseUuid(alloc, inst_04_str);
    const unknown_def_id = try parseUuid(alloc, unknown_def_str);

    var snap_store = SnapshotStore{ .pool = &pool };

    const result = snap_store.create(alloc, instance_id, unknown_def_id);
    try std.testing.expectError(SnapshotError.DefinitionNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-PD-08-05: getByInstanceId with no snapshot returns DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-08-05: SnapshotStore.getByInstanceId — no snapshot returns DefinitionNotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = try parseUuid(alloc, inst_05_str);

    var snap_store = SnapshotStore{ .pool = &pool };

    // No snapshot has been created for this instance_id.
    const result = snap_store.getByInstanceId(alloc, instance_id);
    try std.testing.expectError(SnapshotError.DefinitionNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-PD-08-06: Snapshot includes all graph fields
// ---------------------------------------------------------------------------

test "TC-PD-08-06: SnapshotStore round-trip preserves node types, edge conditions, and is_default" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-08-06 Process";
    const instance_id = try parseUuid(alloc, inst_06_str);
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // G3 contains EXCLUSIVE_GATEWAY with a conditioned edge and a default edge.
    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = graph_g3,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    const inst_hex = try uuidToHexStr(alloc, instance_id);
    defer alloc.free(inst_hex);

    defer cleanupSnapshot(&pool, inst_hex);
    defer cleanupByName(&pool, def_name);

    var snap_store = SnapshotStore{ .pool = &pool };

    // Create and immediately read back the snapshot.
    const snap_created = try snap_store.create(alloc, instance_id, def.id);
    freeSnapshot(alloc, snap_created);

    const snap = try snap_store.getByInstanceId(alloc, instance_id);
    defer freeSnapshot(alloc, snap);

    // Node count must match (5 nodes in G3).
    try std.testing.expectEqual(@as(usize, g3_nodes.len), snap.graph.nodes.len);

    // Edge count must match (4 edges in G3).
    try std.testing.expectEqual(@as(usize, g3_edges.len), snap.graph.edges.len);

    // Find the conditioned edge (e3: GW → E1) and verify condition + is_default.
    var found_condition = false;
    var found_default = false;
    for (snap.graph.edges) |e| {
        if (e.condition) |cond| {
            if (std.mem.eql(u8, cond, "approved == true")) {
                found_condition = true;
                try std.testing.expect(!e.is_default);
            }
        }
        if (e.is_default) {
            found_default = true;
            try std.testing.expect(e.condition == null);
        }
    }
    try std.testing.expect(found_condition);
    try std.testing.expect(found_default);

    // Verify at least one EXCLUSIVE_GATEWAY node is present.
    var found_gw = false;
    for (snap.graph.nodes) |n| {
        if (n.node_type == .EXCLUSIVE_GATEWAY) found_gw = true;
    }
    try std.testing.expect(found_gw);
}

// ---------------------------------------------------------------------------
// TC-PD-08-07: Two instances from same definition have independent snapshots
// ---------------------------------------------------------------------------

test "TC-PD-08-07: SnapshotStore — two instance snapshots from same definition are independent" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-08-07 Process";
    const instance_id_a = try parseUuid(alloc, inst_07a_str);
    const instance_id_b = try parseUuid(alloc, inst_07b_str);
    const creator = try parseUuid(alloc, creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Create definition with G1 (3 nodes).
    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = graph_g1,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    const inst_a_hex = try uuidToHexStr(alloc, instance_id_a);
    defer alloc.free(inst_a_hex);
    const inst_b_hex = try uuidToHexStr(alloc, instance_id_b);
    defer alloc.free(inst_b_hex);
    const def_id_hex = try uuidToHexStr(alloc, def.id);
    defer alloc.free(def_id_hex);

    defer cleanupSnapshot(&pool, inst_a_hex);
    defer cleanupSnapshot(&pool, inst_b_hex);
    defer cleanupByName(&pool, def_name);

    var snap_store = SnapshotStore{ .pool = &pool };

    // Instance A snapshots G1 (3 nodes).
    const snap_a_create = try snap_store.create(alloc, instance_id_a, def.id);
    freeSnapshot(alloc, snap_a_create);

    // Simulate definition graph update to G2 (4 nodes).
    try updateGraph(&pool, def_id_hex, g2_json);

    // Instance B snapshots the updated G2 (4 nodes).
    const snap_b_create = try snap_store.create(alloc, instance_id_b, def.id);
    freeSnapshot(alloc, snap_b_create);

    // Read both snapshots back and verify independence.
    const snap_a = try snap_store.getByInstanceId(alloc, instance_id_a);
    defer freeSnapshot(alloc, snap_a);

    const snap_b = try snap_store.getByInstanceId(alloc, instance_id_b);
    defer freeSnapshot(alloc, snap_b);

    // Instance A must have G1: 3 nodes.
    try std.testing.expectEqual(@as(usize, 3), snap_a.graph.nodes.len);

    // Instance B must have G2: 4 nodes.
    try std.testing.expectEqual(@as(usize, 4), snap_b.graph.nodes.len);

    // The two snapshots must not have the same node count.
    try std.testing.expect(snap_a.graph.nodes.len != snap_b.graph.nodes.len);
}
