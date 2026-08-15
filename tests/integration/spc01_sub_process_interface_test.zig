//! Integration tests for SPC-01 / SPC-02 — SUB_PROCESS `interface` contract.
//!
//! SPC-01: when a SUB_PROCESS node declares an `interface`, activation copies a
//!         filtered subset of the parent variable map into the child initial map
//!         (validated against per-entry JSON Schemas), and child completion merges
//!         a filtered subset of the child's final variables back into the parent.
//!         Missing required inputs, input schema violations, missing required
//!         outputs, and output schema violations transition the parent to ERROR
//!         per EE-10 with a structured reason. A node that omits `interface`
//!         behaves exactly as EXT-05 (full copy / full merge).
//! SPC-02: definition-time validation of every `json_schema` under inputs/outputs.
//!         A malformed schema rejects the definition create/update (HTTP 422 via
//!         `GraphValidationFailed` + violation codes); a well-formed interface is
//!         persisted as part of the node's attributes.
//!
//! These are the integration complements to the pure-function unit tests in
//! `src/definition/sub_process_interface.zig`, `src/tools/json_schema.zig`, and
//! `tests/unit/graph_node_attributes_test.zig`. They run the real engine
//! (`InstanceStore.completeTask` -> SUB_PROCESS activation/completion gates) and
//! the real store (`DefinitionStore.create`) against real PostgreSQL (DIRECTIVE T-1).
//!
//! Fixture isolation (INV-TI-2): every test derives its definition names from a
//! runtime-generated UUID, cleans up definitions and instances unconditionally via
//! `defer`, and shares no fixture state across test blocks.
//!
//! Design artefact: src/design/spc-01-sub-process-interface-contract.md
//! Specs: tests/specs/SPC-01.md, tests/specs/SPC-02.md
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
const DefinitionError = bpm.definition.DefinitionError;
const CompleteTaskError = bpm.engine.CompleteTaskError;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const TaskStore = bpm.tasks.TaskStore;

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

/// Generate a hyphenated UUID v4 string via the platform CSPRNG.
/// Caller owns the returned slice. Used to derive per-test definition names so
/// fixtures never collide across runs (INV-TI-2).
fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    bpm.uuid.generateUuidV4BytesInto(&bytes);
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
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

fn freeCreatedInstance(allocator: std.mem.Allocator, inst: bpm.engine.Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM subprocess_links WHERE child_instance_id = $1::uuid OR parent_instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM tokens WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn queryPendingTaskId(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![16]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT id FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING' ORDER BY created_at ASC LIMIT 1",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return parseUuid(allocator, rows.rows[0][0] orelse "");
}

fn queryChildInstanceIdHex(allocator: std.mem.Allocator, pool: *Pool, parent_instance_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT child_instance_id FROM subprocess_links WHERE parent_instance_id = $1::uuid ORDER BY created_at DESC LIMIT 1",
        &.{parent_instance_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "");
}

fn querySubprocessLinkCount(allocator: std.mem.Allocator, pool: *Pool, parent_instance_hex: []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT COUNT(*) FROM subprocess_links WHERE parent_instance_id = $1::uuid",
        &.{parent_instance_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0] orelse "0", 10) catch 0;
}

fn queryStatus(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "");
}

fn queryVariablesText(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT variables::text FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "{}");
}

fn queryLatestEventPayloadByType(
    allocator: std.mem.Allocator,
    pool: *Pool,
    instance_id_hex: []const u8,
    event_type: []const u8,
) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        allocator,
        "SELECT payload::text FROM events WHERE instance_id = $1::uuid AND event_type = $2 ORDER BY sequence_number DESC LIMIT 1",
        &.{ instance_id_hex, event_type },
    );
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "{}");
}

fn hasJsonKey(text: []const u8, key: []const u8) bool {
    // Cheap presence check: `"key":` (with optional whitespace after the colon).
    return std.mem.indexOf(u8, text, key) != null;
}

/// True iff `needle` appears in `text` as a JSON object key (quoted).
fn hasJsonKeyQuoted(text: []const u8, key: []const u8) bool {
    const quoted = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return false;
    defer std.heap.page_allocator.free(quoted);
    return std.mem.indexOf(u8, text, quoted) != null;
}

/// Create a child definition (START → HUMAN_TASK → END) and a parent definition
/// (START → HUMAN_TASK → SUB_PROCESS → END), activating both. The SUB_PROCESS
/// node's `attributes` are built from `child_id_hex` and the optional
/// `interface_json` (`null` → no `interface` attribute; EXT-05 semantics).
/// Returns the active definitions. Caller frees both.
fn setupParentChildDefinitions(
    alloc: std.mem.Allocator,
    def_store: *DefinitionStore,
    parent_name: []const u8,
    child_name: []const u8,
    interface_json: ?[]const u8,
) !struct { parent: Definition, child: Definition } {
    const created_by = std.mem.zeroes([16]u8);

    const child_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "CT", .node_type = .HUMAN_TASK, .label = "Child Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const child_edges = [_]GraphEdge{
        .{ .id = "ce1", .source = "S", .target = "CT", .condition = null, .is_default = false },
        .{ .id = "ce2", .source = "CT", .target = "E", .condition = null, .is_default = false },
    };

    const child_draft = try def_store.create(alloc, CreateParams{
        .name = child_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &child_nodes, .edges = &child_edges },
        .created_by = created_by,
    });
    const child_active = try def_store.activate(alloc, child_draft.id);
    freeDefinition(alloc, child_draft);

    const child_id_hex = try uuidToHexStr(alloc, child_active.id);
    defer alloc.free(child_id_hex);

    const parent_attrs = if (interface_json) |ij|
        try std.fmt.allocPrint(alloc, "{{\"child_definition_id\":\"{s}\",\"interface\":{s}}}", .{ child_id_hex, ij })
    else
        try std.fmt.allocPrint(alloc, "{{\"child_definition_id\":\"{s}\"}}", .{child_id_hex});
    defer alloc.free(parent_attrs);

    const parent_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "PT", .node_type = .HUMAN_TASK, .label = "Parent Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
        .{ .id = "SP", .node_type = .SUB_PROCESS, .label = "Sub", .attributes = parent_attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const parent_edges = [_]GraphEdge{
        .{ .id = "pe1", .source = "S", .target = "PT", .condition = null, .is_default = false },
        .{ .id = "pe2", .source = "PT", .target = "SP", .condition = null, .is_default = false },
        .{ .id = "pe3", .source = "SP", .target = "E", .condition = null, .is_default = false },
    };

    const parent_draft = try def_store.create(alloc, CreateParams{
        .name = parent_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &parent_nodes, .edges = &parent_edges },
        .created_by = created_by,
    });
    const parent_active = try def_store.activate(alloc, parent_draft.id);
    freeDefinition(alloc, parent_draft);

    return .{ .parent = parent_active, .child = child_active };
}

fn hasCode(violations: []const bpm.definition.Violation, code: []const u8) bool {
    for (violations) |v| {
        if (std.mem.eql(u8, v.code, code)) return true;
    }
    return false;
}

/// Find the first violation message matching `code`.
fn violationMessage(violations: []const bpm.definition.Violation, code: []const u8) ?[]const u8 {
    for (violations) |v| {
        if (std.mem.eql(u8, v.code, code)) return v.message;
    }
    return null;
}

// ---------------------------------------------------------------------------
// SPC-01 — runtime activation gate
// ---------------------------------------------------------------------------

test "SPC-01 AC1: declared inputs are filtered into the child initial map (only named vars visible)" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-01 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-01 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface =
        \\{"inputs":[{"name":"customer_id","json_schema":{"type":"string"},"required":true},{"name":"amount","json_schema":{"type":"number"},"required":false}],"outputs":[]}
    ;
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"customer_id\":\"c1\",\"amount\":42,\"secret\":\"hidden\"}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const child_vars = try queryVariablesText(alloc, &pool, child_hex);
    defer alloc.free(child_vars);

    // Only the named inputs are visible to the child; `secret` must NOT be.
    try std.testing.expect(hasJsonKeyQuoted(child_vars, "customer_id"));
    try std.testing.expect(hasJsonKeyQuoted(child_vars, "amount"));
    try std.testing.expect(!hasJsonKeyQuoted(child_vars, "secret"));
}

test "SPC-01 AC2: missing required input -> parent ERROR, no child created" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-02 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-02 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface =
        \\{"inputs":[{"name":"customer_id","json_schema":{"type":"string"},"required":true}],"outputs":[]}
    ;
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // Parent map lacks the required `customer_id` input.
    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"other\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    const result = inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");
    try std.testing.expectError(CompleteTaskError.InstanceInError, result);

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("ERROR", parent_status);

    // No child instance was created.
    const link_count = try querySubprocessLinkCount(alloc, &pool, parent_hex);
    try std.testing.expectEqual(@as(i64, 0), link_count);

    const payload = try queryLatestEventPayloadByType(alloc, &pool, parent_hex, "EXECUTION_ERROR");
    defer alloc.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "SUB_PROCESS_MISSING_REQUIRED_INPUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "customer_id") != null);
}

test "SPC-01 AC3: input schema violation -> parent ERROR, no orphaned child" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-03 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-03 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface =
        \\{"inputs":[{"name":"amount","json_schema":{"type":"number"},"required":true}],"outputs":[]}
    ;
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // Input present but failing its declared schema (`amount` must be a number).
    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"amount\":\"not-a-number\"}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    const result = inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");
    try std.testing.expectError(CompleteTaskError.InstanceInError, result);

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("ERROR", parent_status);

    // No orphaned child instance.
    const link_count = try querySubprocessLinkCount(alloc, &pool, parent_hex);
    try std.testing.expectEqual(@as(i64, 0), link_count);

    const payload = try queryLatestEventPayloadByType(alloc, &pool, parent_hex, "EXECUTION_ERROR");
    defer alloc.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "SUB_PROCESS_INPUT_SCHEMA_VIOLATION") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "amount") != null);
}

test "SPC-01 edge: empty inputs -> child starts with an empty initial map" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-06 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-06 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface = "{\"inputs\":[],\"outputs\":[]}";
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    // Parent has variables, but `interface.inputs == []` -> child starts empty.
    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"a\":1,\"b\":2}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const child_vars = try queryVariablesText(alloc, &pool, child_hex);
    defer alloc.free(child_vars);

    try std.testing.expect(!hasJsonKeyQuoted(child_vars, "a"));
    try std.testing.expect(!hasJsonKeyQuoted(child_vars, "b"));
    try std.testing.expect(std.mem.indexOf(u8, child_vars, "{}") != null);
}

// ---------------------------------------------------------------------------
// SPC-01 — runtime completion gate
// ---------------------------------------------------------------------------

test "SPC-01 AC4: only declared outputs merged back; unlisted child vars discarded" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-04 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-04 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface =
        \\{"inputs":[],"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    ;
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    const child_task_id = try queryPendingTaskId(alloc, &pool, child_hex);
    _ = try inst_store.completeTask(alloc, &task_store, child_task_id, "{\"order_id\":\"o1\",\"internal\":\"discard-me\"}");

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("COMPLETED", parent_status);

    const vars_text = try queryVariablesText(alloc, &pool, parent_hex);
    defer alloc.free(vars_text);

    // `order_id` merged per EE-09; `internal` discarded — never merged.
    try std.testing.expect(hasJsonKeyQuoted(vars_text, "order_id"));
    try std.testing.expect(!hasJsonKeyQuoted(vars_text, "internal"));
}

test "SPC-01 AC5: missing required output -> parent ERROR, merge not applied" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-05 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-05 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface =
        \\{"inputs":[],"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    ;
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    // Child completes WITHOUT the required `order_id` output.
    const child_task_id = try queryPendingTaskId(alloc, &pool, child_hex);
    _ = try inst_store.completeTask(alloc, &task_store, child_task_id, "{\"something_else\":1}");

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("ERROR", parent_status);

    // No partial merge: the undeclared variable must NOT reach the parent.
    const vars_text = try queryVariablesText(alloc, &pool, parent_hex);
    defer alloc.free(vars_text);
    try std.testing.expect(!hasJsonKeyQuoted(vars_text, "something_else"));
    try std.testing.expect(!hasJsonKeyQuoted(vars_text, "order_id"));

    const payload = try queryLatestEventPayloadByType(alloc, &pool, parent_hex, "EXECUTION_ERROR");
    defer alloc.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "SUB_PROCESS_MISSING_REQUIRED_OUTPUT") != null);
}

test "SPC-01 edge: output schema violation -> parent ERROR, no partial merge" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-08 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-08 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface =
        \\{"inputs":[],"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    ;
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    // Output present but failing its declared schema (`order_id` must be a string).
    const child_task_id = try queryPendingTaskId(alloc, &pool, child_hex);
    _ = try inst_store.completeTask(alloc, &task_store, child_task_id, "{\"order_id\":12345}");

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("ERROR", parent_status);

    // No partial merge: the failing value must NOT reach the parent.
    const vars_text = try queryVariablesText(alloc, &pool, parent_hex);
    defer alloc.free(vars_text);
    try std.testing.expect(!hasJsonKeyQuoted(vars_text, "order_id"));

    const payload = try queryLatestEventPayloadByType(alloc, &pool, parent_hex, "EXECUTION_ERROR");
    defer alloc.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION") != null);
}

// ---------------------------------------------------------------------------
// SPC-01 AC6 — no interface → EXT-05 unchanged (full copy / full merge)
// ---------------------------------------------------------------------------

test "SPC-01 AC6: no interface -> EXT-05 unchanged (full map copy and merge)" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-07 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-01-07 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    // No `interface` attribute → EXT-05 legacy semantics.
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, null);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{\"x\":1,\"parent_only\":true}");
    defer freeCreatedInstance(alloc, parent_instance);

    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstance(&pool, parent_hex);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstance(&pool, child_hex);

    // Full copy-out: the child sees the ENTIRE parent map (EXT-05).
    const child_vars = try queryVariablesText(alloc, &pool, child_hex);
    defer alloc.free(child_vars);
    try std.testing.expect(hasJsonKeyQuoted(child_vars, "x"));
    try std.testing.expect(hasJsonKeyQuoted(child_vars, "parent_only"));

    // Full merge-back: every child variable reaches the parent (EXT-05).
    const child_task_id = try queryPendingTaskId(alloc, &pool, child_hex);
    _ = try inst_store.completeTask(alloc, &task_store, child_task_id, "{\"x\":2,\"child_only\":true}");

    const parent_status = try queryStatus(alloc, &pool, parent_hex);
    defer alloc.free(parent_status);
    try std.testing.expectEqualStrings("COMPLETED", parent_status);

    const vars_text = try queryVariablesText(alloc, &pool, parent_hex);
    defer alloc.free(vars_text);
    try std.testing.expect(hasJsonKeyQuoted(vars_text, "child_only"));
    try std.testing.expect(hasJsonKeyQuoted(vars_text, "x"));
}

// ---------------------------------------------------------------------------
// SPC-02 — definition-time validation (HTTP 422 via GraphValidationFailed)
// ---------------------------------------------------------------------------

test "SPC-02 AC1: definition create with malformed json_schema -> 422 violation naming node" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-02-01 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-02-01 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    // Well-formed child definition (referenced by the parent's child_definition_id).
    const created_by = std.mem.zeroes([16]u8);
    const child_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "CT", .node_type = .HUMAN_TASK, .label = "Child Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const child_edges = [_]GraphEdge{
        .{ .id = "ce1", .source = "S", .target = "CT", .condition = null, .is_default = false },
        .{ .id = "ce2", .source = "CT", .target = "E", .condition = null, .is_default = false },
    };
    const child_draft = try def_store.create(alloc, CreateParams{
        .name = child_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &child_nodes, .edges = &child_edges },
        .created_by = created_by,
    });
    const child_active = try def_store.activate(alloc, child_draft.id);
    freeDefinition(alloc, child_draft);
    defer freeDefinition(alloc, child_active);

    const child_id_hex = try uuidToHexStr(alloc, child_active.id);
    defer alloc.free(child_id_hex);

    // Malformed json_schema: `type` must be a string, not a number (SPC-02 AC1).
    const bad_iface = "{\"inputs\":[{\"name\":\"amount\",\"json_schema\":{\"type\":42},\"required\":true}],\"outputs\":[]}";
    const parent_attrs = try std.fmt.allocPrint(alloc, "{{\"child_definition_id\":\"{s}\",\"interface\":{s}}}", .{ child_id_hex, bad_iface });
    defer alloc.free(parent_attrs);

    const parent_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "PT", .node_type = .HUMAN_TASK, .label = "Parent Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
        .{ .id = "SUB01", .node_type = .SUB_PROCESS, .label = "Sub", .attributes = parent_attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const parent_edges = [_]GraphEdge{
        .{ .id = "pe1", .source = "S", .target = "PT", .condition = null, .is_default = false },
        .{ .id = "pe2", .source = "PT", .target = "SUB01", .condition = null, .is_default = false },
        .{ .id = "pe3", .source = "SUB01", .target = "E", .condition = null, .is_default = false },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = parent_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &parent_nodes, .edges = &parent_edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);

    // The violation list names the offending schema code AND the node id.
    const violations = def_store.lastViolations();
    try std.testing.expect(hasCode(violations, "SUB_PROCESS_INTERFACE_SCHEMA_INVALID"));
    const msg = violationMessage(violations, "SUB_PROCESS_INTERFACE_SCHEMA_INVALID") orelse "";
    try std.testing.expect(std.mem.indexOf(u8, msg, "SUB01") != null);
}

test "SPC-02 AC2: well-formed interface -> create succeeds and interface persisted in node attributes" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const suffix = try randomUuidStr(alloc);
    defer alloc.free(suffix);
    const parent_name = try std.fmt.allocPrint(alloc, "TC-SPC-02-02 Parent {s}", .{suffix});
    defer alloc.free(parent_name);
    const child_name = try std.fmt.allocPrint(alloc, "TC-SPC-02-02 Child {s}", .{suffix});
    defer alloc.free(child_name);
    defer cleanupByName(&pool, parent_name);
    defer cleanupByName(&pool, child_name);

    const iface =
        \\{"inputs":[{"name":"customer_id","json_schema":{"type":"string"},"required":true}],"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    ;
    const defs = try setupParentChildDefinitions(alloc, &def_store, parent_name, child_name, iface);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    // Re-fetch the parent definition and verify the interface was persisted
    // as part of the SUB_PROCESS node's attributes (SPC-02 AC2).
    const fetched = try def_store.getById(alloc, defs.parent.id);
    defer freeDefinition(alloc, fetched);

    var found_interface = false;
    for (fetched.graph.nodes) |node| {
        if (!std.mem.eql(u8, node.id, "SP")) continue;
        const attrs = node.attributes orelse continue;
        try std.testing.expect(std.mem.indexOf(u8, attrs, "child_definition_id") != null);
        try std.testing.expect(std.mem.indexOf(u8, attrs, "interface") != null);
        try std.testing.expect(std.mem.indexOf(u8, attrs, "customer_id") != null);
        try std.testing.expect(std.mem.indexOf(u8, attrs, "order_id") != null);
        found_interface = true;
    }
    try std.testing.expect(found_interface);
}
