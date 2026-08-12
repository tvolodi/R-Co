//! Integration tests for PIN-02 (pin set recorded in INSTANCE_STARTED) — FULL
//! scope, all 5 acceptance criteria. Asserts the raw events.payload JSON
//! directly (no schema-validation gate exists on InstanceStore.create()'s
//! hand-rolled INSERT — see the design doc's Open questions §2 and
//! tests/specs/PIN-02.md's Implementation note).
//!
//! BPM_TEST_DB_URL must be set; connects to a real PostgreSQL (DIRECTIVE T-1).
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const InstanceStore = bpm.engine.InstanceStore;
const Instance = bpm.engine.Instance;
const InstanceError = bpm.engine.InstanceError;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const SnapshotStore = bpm.snapshot.SnapshotStore;

pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const service_task_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "H", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "H", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e3", .source = "T", .target = "E", .condition = null, .is_default = false },
};

/// START -> HUMAN_TASK -> SERVICE_TASK -> END. The HUMAN_TASK precedes the
/// SERVICE_TASK deliberately (mirrors tests/integration/ext01_service_task_test.zig's
/// fixture shape): PIN-01/PIN-02 only need the SERVICE_TASK node to exist in
/// the definition graph for enumeration/resolution at instance START — they
/// do not need it to actually EXECUTE. Placing it directly after START would
/// make transition() reach and execute it synchronously during create()
/// itself (attempting a real HTTP call to the fixture's placeholder
/// endpoint_url), which is unrelated to what PIN-01/PIN-02 are testing here.
fn serviceTaskGraph(svc_id: []const u8, nodes_buf: *[4]GraphNode, attrs_buf: []u8) DefinitionGraph {
    // Graph validator (src/definition/graph.zig checkServiceTask()) requires
    // timeout_ms (1..300000) and a service:call:<service_id> (or wildcard)
    // capability whenever service_id is used — mirrors the fixture shape
    // tests/integration/ext01_service_task_test.zig already uses.
    const attrs = std.fmt.bufPrint(
        attrs_buf,
        "{{\"service_id\":\"{s}\",\"capabilities\":[\"service:call:{s}\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}}",
        .{ svc_id, svc_id },
    ) catch unreachable;
    nodes_buf[0] = .{ .id = "S", .node_type = .START, .label = null, .attributes = null };
    nodes_buf[1] = .{ .id = "H", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" };
    nodes_buf[2] = .{ .id = "T", .node_type = .SERVICE_TASK, .label = null, .attributes = attrs };
    nodes_buf[3] = .{ .id = "E", .node_type = .END, .label = null, .attributes = null };
    return DefinitionGraph{ .nodes = nodes_buf, .edges = &service_task_edges };
}

const no_service_task_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const no_service_task_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const no_service_task_graph = DefinitionGraph{ .nodes = &no_service_task_nodes, .edges = &no_service_task_edges };

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping PIN-02 test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
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

fn randomId(buf: *[8]u8) []const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    helpers.fillRandom(buf);
    for (buf) |*b| b.* = chars[@as(usize, b.*) % chars.len];
    return buf;
}

fn insertGlobalServiceViaPool(pool: *Pool, svc_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'global', NULL)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{svc_id},
    );
}

fn deleteServiceCatalogEntry(pool: *Pool, svc_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.service_catalog WHERE service_id = $1", &.{svc_id}) catch {};
}

fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstanceAll(pool: *Pool, inst_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM instance_state_snapshots WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
}

fn cleanupDefinitionByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

/// Read the raw INSTANCE_STARTED payload JSON text for instance_id directly
/// from `events` — the record of record, per PIN-02 AC3. Returns owned text.
fn readInstanceStartedPayload(alloc: std.mem.Allocator, pool: *Pool, inst_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        alloc,
        "SELECT payload::text FROM events WHERE instance_id = $1::uuid AND event_type = 'instance_started'",
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0].len == 0 or rows.rows[0][0] == null) return error.NoInstanceStartedRow;
    return alloc.dupe(u8, rows.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-PIN-02-01: one entry per enumerated reference plus variable_schema
// ---------------------------------------------------------------------------

test "TC-PIN-02-01: INSTANCE_STARTED payload carries one catalog_entry pin plus one variable_schema pin" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin02-01-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-02-01 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    var nodes_buf: [4]GraphNode = undefined;
    var attrs_buf: [192]u8 = undefined;
    const graph = serviceTaskGraph(svc_id, &nodes_buf, &attrs_buf);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    const payload_text = try readInstanceStartedPayload(alloc, &pool, inst_hex);
    defer alloc.free(payload_text);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload_text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const pv = obj.get("pinned_versions") orelse return error.MissingPinnedVersions;
    try std.testing.expect(pv == .array);
    try std.testing.expectEqual(@as(usize, 2), pv.array.items.len);

    var found_catalog = false;
    var found_vs = false;
    for (pv.array.items) |item| {
        const kind = item.object.get("kind").?.string;
        if (std.mem.eql(u8, kind, "catalog_entry")) found_catalog = true;
        if (std.mem.eql(u8, kind, "variable_schema")) found_vs = true;
    }
    try std.testing.expect(found_catalog);
    try std.testing.expect(found_vs);
}

// ---------------------------------------------------------------------------
// TC-PIN-02-02: resolution failure writes no instance row
// ---------------------------------------------------------------------------

test "TC-PIN-02-02: PIN-01 resolution failure leaves no instance row (all-or-nothing)" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-02-02 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    // A service_id guaranteed to name no catalog entry at all.
    var id_buf: [8]u8 = undefined;
    const nonexistent_svc = try std.fmt.allocPrint(alloc, "svc-pin02-02-absent-{s}", .{randomId(&id_buf)});
    defer alloc.free(nonexistent_svc);

    var nodes_buf: [4]GraphNode = undefined;
    var attrs_buf: [192]u8 = undefined;
    const graph = serviceTaskGraph(nonexistent_svc, &nodes_buf, &attrs_buf);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const result = inst_store.create(alloc, active_def.id, null, "{}");
    try std.testing.expectError(InstanceError.UnresolvedCatalogRef, result);

    // No instance_projections row exists for this definition.
    const conn = try pool.acquire();
    defer pool.release(conn);
    const def_id_hex = try uuidToHexStr(alloc, active_def.id);
    defer alloc.free(def_id_hex);
    var rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM instance_projections WHERE definition_id = $1::uuid",
        &.{def_id_hex},
    );
    defer rows.deinit();
    const cnt = std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 0), cnt);
}

// ---------------------------------------------------------------------------
// TC-PIN-02-03: effective pin set read from the event log
// ---------------------------------------------------------------------------

test "TC-PIN-02-03: effective pin set is read directly from events, no side table" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-02-03 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = no_service_task_graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // The ONLY read this test performs to obtain the pin set is a direct
    // `events` query — by construction, this is the proof PIN-02 AC3
    // requires: no pin-specific side table exists to read from instead.
    const payload_text = try readInstanceStartedPayload(alloc, &pool, inst_hex);
    defer alloc.free(payload_text);
    try std.testing.expect(std.mem.indexOf(u8, payload_text, "pinned_versions") != null);
}

// ---------------------------------------------------------------------------
// TC-PIN-02-04: zero references -> exactly the variable_schema entry
// ---------------------------------------------------------------------------

test "TC-PIN-02-04: zero service-catalog/module references produces exactly the variable_schema entry" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-02-04 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = no_service_task_graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    const payload_text = try readInstanceStartedPayload(alloc, &pool, inst_hex);
    defer alloc.free(payload_text);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload_text, .{});
    defer parsed.deinit();
    const pv = parsed.value.object.get("pinned_versions") orelse return error.MissingPinnedVersions;
    try std.testing.expectEqual(@as(usize, 1), pv.array.items.len);
    try std.testing.expectEqualStrings("variable_schema", pv.array.items[0].object.get("kind").?.string);
}

// ---------------------------------------------------------------------------
// TC-PIN-02-05: every entry records a legal source value
// ---------------------------------------------------------------------------

test "TC-PIN-02-05: every pinned_versions entry records a legal source value" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin02-05-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-02-05 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    var nodes_buf: [4]GraphNode = undefined;
    var attrs_buf: [192]u8 = undefined;
    const graph = serviceTaskGraph(svc_id, &nodes_buf, &attrs_buf);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    const payload_text = try readInstanceStartedPayload(alloc, &pool, inst_hex);
    defer alloc.free(payload_text);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload_text, .{});
    defer parsed.deinit();
    const pv = parsed.value.object.get("pinned_versions") orelse return error.MissingPinnedVersions;
    try std.testing.expect(pv.array.items.len >= 1);

    for (pv.array.items) |item| {
        const source = item.object.get("source").?.string;
        const legal = std.mem.eql(u8, source, "resolved") or
            std.mem.eql(u8, source, "override") or
            std.mem.eql(u8, source, "inherited");
        try std.testing.expect(legal);
    }
}
