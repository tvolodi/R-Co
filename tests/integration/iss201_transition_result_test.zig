//! Integration tests for ISS-201 — TransitionResult atomic persistence.
//!
//! Verifies that when transition() returns a TransitionResult with
//! emitted_events, those events are committed atomically with the trigger
//! event in a single PostgreSQL transaction.
//!
//! DIRECTIVE T-1: real DB only, no mocks/stubs.
//!
//! Run with: zig build test-integration

const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const Definition = bpm.definition.Definition;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping ISS-201 integration tests\n", .{});
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

fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

fn freeInstance(allocator: std.mem.Allocator, inst: bpm.engine.Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM timers WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

fn countInt(pool: *Pool, allocator: std.mem.Allocator, sql: []const u8, params: []const []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(allocator, sql, params);
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return 0;
    const value = if (rows.rows[0].len > 0) rows.rows[0][0] orelse "0" else "0";
    return std.fmt.parseInt(i64, value, 10) catch 0;
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
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

fn createAndActivateDefinition(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    name: []const u8,
    graph: DefinitionGraph,
) ![16]u8 {
    const created_by_uuid_str = try randomUuidStr(allocator);
    defer allocator.free(created_by_uuid_str);
    const created_by = try parseUuid(allocator, created_by_uuid_str);
    const draft = try def_store.create(allocator, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer freeDefinition(allocator, draft);

    const active = try def_store.activate(allocator, draft.id);
    defer freeDefinition(allocator, active);

    return draft.id;
}

// ---------------------------------------------------------------------------
// TC-ISS-201-IT-01: Trigger event + emitted_events committed atomically
//
// Given a definition with START -> TIMER("PT5M") -> END, when an instance is
// created, both the instance_started trigger event AND the timer row (from
// timer_created emitted event) must exist in the database — committed in the
// same transaction.
// ---------------------------------------------------------------------------
test "TC-ISS-201-IT-01: trigger event and emitted_events committed atomically" {
    const allocator = std.heap.page_allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // Per-test UUID: use a unique definition name to avoid collisions.
    const name = "ISS201-IT01";
    cleanupByName(&pool, name);
    defer cleanupByName(&pool, name);

    // Graph: START -> TIMER("PT5M") -> END
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "WAIT_TIMER", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT5M\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "WAIT_TIMER", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "WAIT_TIMER", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def_id = try createAndActivateDefinition(allocator, &def_store, name, graph);

    // Create the instance — trigger is instance_started,
    // emitted event is timer_created (because the token lands on TIMER node).
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);

    // Verify the trigger event (instance_started) was persisted.
    const started_event_count = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'instance_started'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), started_event_count);

    // Verify the timer was created (from timer_created emitted event).
    const pending_timer_count = try countInt(
        &pool,
        allocator,
        "SELECT COUNT(*) FROM timers WHERE instance_id = $1::uuid AND status = 'pending'",
        &.{inst_id_hex},
    );
    try std.testing.expectEqual(@as(i64, 1), pending_timer_count);

    // Verify the timer payload contains the correct node_id.
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT action_config::text FROM timers WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const payload = rows.rows[0][0] orelse "";
    try std.testing.expect(std.mem.indexOf(u8, payload, "WAIT_TIMER") != null);

    // Verify instance state reflects the token on WAIT_TIMER node.
    const proj_rows = try conn.query(
        allocator,
        "SELECT current_nodes::text FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    defer {
        var r = proj_rows;
        r.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), proj_rows.rows.len);
    try std.testing.expect(std.mem.indexOf(u8, proj_rows.rows[0][0] orelse "", "WAIT_TIMER") != null);
}
