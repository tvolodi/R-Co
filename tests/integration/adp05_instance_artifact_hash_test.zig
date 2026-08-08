//! Integration tests for ADP-05 -- instance definition artifact hash behavior.

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
const Definition = bpm.definition.Definition;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const InstanceError = bpm.engine.InstanceError;
const reconstruction_mod = bpm.reconstruction;

// GH-512 retention: adp05 creator_uuid_str module-scope fixture (deterministic)
const creator_uuid_str = "00000000-0000-0000-0000-00000000ad05";

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};

const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .transform = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .transform = null, .is_default = false },
};

const minimal_graph = DefinitionGraph{ .nodes = &minimal_nodes, .edges = &minimal_edges };

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - skipping integration test\n", .{});
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

fn parseUuid(s: []const u8) ![16]u8 {
    var compact: [32]u8 = undefined;
    var idx: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (idx >= compact.len) return error.InvalidUuid;
        compact[idx] = c;
        idx += 1;
    }
    if (idx != compact.len) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, compact[0..]);
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

fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |stage| allocator.free(stage);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

fn freeInstance(allocator: std.mem.Allocator, inst: bpm.engine.Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |value| allocator.free(value);
    }
    allocator.free(row);
}

fn computeSnapshotArtifactHash(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
) ![]u8 {
    const canonical_json = try std.json.Stringify.valueAlloc(allocator, graph, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_json, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)});
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupDefinitionByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

test "TC-ADP-05-01: migration adds nullable definition_artifact_hash on instance projections" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        \\SELECT is_nullable
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name = 'instance_projections'
        \\  AND column_name = 'definition_artifact_hash'
    ,
        &.{},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expectEqualStrings("YES", row[0] orelse return error.TestUnexpectedResult);
}

test "TC-ADP-05-02: create persists NULL hash for compatibility definitions" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-ADP-05-02";
    defer cleanupDefinitionByName(&pool, def_name);

    const created_by = try parseUuid(creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);

    const inst = try instance_store.create(alloc, draft.id, null, "{}");
    defer freeInstance(alloc, inst);

    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT definition_artifact_hash FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_hex},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expect(row[0] == null);
}

test "TC-ADP-05-03: create persists definition artifact hash when definition is repository-backed" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-ADP-05-03";
    defer cleanupDefinitionByName(&pool, def_name);

    const created_by = try parseUuid(creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    const artifact_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const def_hex = try uuidToHexStr(alloc, draft.id);
    defer alloc.free(def_hex);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec(
            "UPDATE process_definitions SET definition_artifact_hash = $2 WHERE id = $1::uuid",
            &.{ def_hex, artifact_hash },
        );
    }

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);

    const inst = try instance_store.create(alloc, draft.id, null, "{}");
    defer freeInstance(alloc, inst);

    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const row = (try conn.queryRow(
        alloc,
        "SELECT definition_artifact_hash FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_hex},
    )) orelse return error.TestUnexpectedResult;
    defer freeRow(alloc, row);

    try testing.expect(row[0] != null);
    try testing.expectEqualStrings(artifact_hash, row[0].?);
}

test "TC-ADP-05-04: create rejects malformed definition artifact hash" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-ADP-05-04";
    defer cleanupDefinitionByName(&pool, def_name);

    const created_by = try parseUuid(creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    const def_hex = try uuidToHexStr(alloc, draft.id);
    defer alloc.free(def_hex);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        try conn.exec(
            "UPDATE process_definitions SET definition_artifact_hash = $2 WHERE id = $1::uuid",
            &.{ def_hex, "not-a-sha256" },
        );
    }

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);

    const result = instance_store.create(alloc, draft.id, null, "{}");
    try testing.expectError(InstanceError.InvalidInput, result);
}

test "TC-ADP-05-05: reconstruction stays compatible with snapshot fallback when hash is absent or mismatched" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-ADP-05-05";
    defer cleanupDefinitionByName(&pool, def_name);

    const created_by = try parseUuid(creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);

    const inst = try instance_store.create(alloc, draft.id, null, "{\"amount\":100}");
    defer freeInstance(alloc, inst);

    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const snapshot = try snapshot_store.getByInstanceId(arena.allocator(), inst.instance_id);
    const source_with_null_hash = try reconstruction_mod.determineReplaySourceForSnapshot(
        arena.allocator(),
        snapshot.graph,
        null,
    );
    try testing.expectEqual(reconstruction_mod.ReplayDefinitionSource.snapshot_fallback, source_with_null_hash);

    const source_with_mismatched_hash = try reconstruction_mod.determineReplaySourceForSnapshot(
        arena.allocator(),
        snapshot.graph,
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
    try testing.expectEqual(reconstruction_mod.ReplayDefinitionSource.snapshot_fallback, source_with_mismatched_hash);
}

test "TC-ADP-05-06: reconstruction selects artifact_repository when hash matches canonical snapshot" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "TC-ADP-05-06";
    defer cleanupDefinitionByName(&pool, def_name);

    const created_by = try parseUuid(creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);

    const inst = try instance_store.create(alloc, draft.id, null, "{\"amount\":100}");
    defer freeInstance(alloc, inst);

    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstance(&pool, inst_hex);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const snapshot = try snapshot_store.getByInstanceId(arena.allocator(), inst.instance_id);
    const canonical_hash = try computeSnapshotArtifactHash(arena.allocator(), snapshot.graph);

    const source_with_matching_hash = try reconstruction_mod.determineReplaySourceForSnapshot(
        arena.allocator(),
        snapshot.graph,
        canonical_hash,
    );
    try testing.expectEqual(reconstruction_mod.ReplayDefinitionSource.artifact_repository, source_with_matching_hash);
}
