//! Integration tests for EXT-03 — Plugin interface.
//!
//! Requirement traceability:
//!   EXT-03 -> TC-EXT-03-INT-01 through TC-EXT-03-INT-10

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
const Definition = bpm.definition.Definition;
const Instance = bpm.engine.Instance;
const InstanceStore = bpm.engine.InstanceStore;
const CompleteTaskError = bpm.engine.CompleteTaskError;
const SnapshotStore = bpm.snapshot.SnapshotStore;
const TaskStore = bpm.tasks.TaskStore;
const plugin_interface = bpm.plugin_interface;
const plugin_registry = bpm.plugin_registry;

const valid_service_attrs = "{\"url\":\"http://127.0.0.1:19999/ext03\",\"method\":\"POST\",\"timeout_ms\":1000,\"retry_limit\":1}";

/// Per-test-run "created_by" UUID — generated fresh instead of a fixed
/// literal so this fixture follows the per-test-UUID isolation convention
/// (see docs/guides/test_infrastructure_guide.md §9 / ISS-0121).
fn makeCreatorUuid() [16]u8 {
    var bytes: bpm.uuid.Uuid = undefined;
    bpm.uuid.generateUuidV4BytesInto(&bytes);
    return bytes;
}

const PluginMode = enum {
    complete_empty,
    complete_merge,
    complete_invalid,
    explicit_error,
    panic_caught,
};

var g_plugin_mode: PluginMode = .complete_empty;
var g_handler_invoked: bool = false;
var g_last_node_type: [32]u8 = undefined;
var g_last_node_type_len: usize = 0;
var g_last_node_config: [512]u8 = undefined;
var g_last_node_config_len: usize = 0;
var g_last_instance_vars: [1024]u8 = undefined;
var g_last_instance_vars_len: usize = 0;

fn resetInvocationProbe() void {
    g_handler_invoked = false;
    g_last_node_type_len = 0;
    g_last_node_config_len = 0;
    g_last_instance_vars_len = 0;
}

fn copyText(dst: []u8, dst_len: *usize, src: []const u8) void {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    dst_len.* = n;
}

fn ext03Handler(ctx: plugin_interface.PluginExecutionContext) plugin_interface.PluginHandlerInvocationError!plugin_interface.PluginHandlerOutcome {
    g_handler_invoked = true;
    copyText(g_last_node_type[0..], &g_last_node_type_len, ctx.node_type);
    copyText(g_last_node_config[0..], &g_last_node_config_len, ctx.node_config_json);
    copyText(g_last_instance_vars[0..], &g_last_instance_vars_len, ctx.instance_variables_json);

    return switch (g_plugin_mode) {
        .complete_empty => .{ .COMPLETE = .{ .output_variables_json = null } },
        .complete_merge => .{ .COMPLETE = .{ .output_variables_json = "{\"plugin\":\"ok\",\"existing\":\"new\"}" } },
        .complete_invalid => .{ .COMPLETE = .{ .output_variables_json = "[1,2,3]" } },
        .explicit_error => .{ .ERROR = .{ .reason = "PLUGIN_FAIL_EXT03" } },
        .panic_caught => error.PanicCaught,
    };
}

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
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
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

fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupWorkflow(pool: *Pool, instance_id_hex: []const u8, process_name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM dead_letter_items WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{process_name}) catch {};
}

fn rowText(
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const []const u8,
) ![]u8 {
    const row = (try conn.queryRow(allocator, sql, params)) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return allocator.dupe(u8, row[0] orelse return error.TestUnexpectedResult);
}

fn rowCount(
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const []const u8,
) !usize {
    const value = try rowText(conn, allocator, sql, params);
    defer allocator.free(value);
    return std.fmt.parseInt(usize, value, 10);
}

fn firstTaskId(allocator: std.mem.Allocator, task_store: *TaskStore, instance_id: [16]u8) ![16]u8 {
    const tasks = try task_store.list(allocator, instance_id, null, null, 50, 0);
    defer {
        for (tasks) |t| bpm.tasks.freeTask(allocator, t);
        allocator.free(tasks);
    }
    if (tasks.len == 0) return error.TestUnexpectedResult;
    return tasks[0].task_id;
}

fn createWorkflowFixture(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    inst_store: *InstanceStore,
    task_store: *TaskStore,
    process_name: []const u8,
    service_attrs: []const u8,
    initial_variables: []const u8,
) !struct { def: Definition, active_def: Definition, inst: Instance, inst_id_hex: []u8, task_id: [16]u8 } {
    const created_by = makeCreatorUuid();

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "H", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "X", .node_type = .SERVICE_TASK, .label = null, .attributes = service_attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "H", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "H", .target = "X", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "X", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const def = try def_store.create(allocator, CreateParams{
        .name = process_name,
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    const active_def = try def_store.activate(allocator, def.id);
    const inst = try inst_store.create(allocator, def.id, null, initial_variables);
    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    const task_id = try firstTaskId(allocator, task_store, inst.instance_id);

    return .{
        .def = def,
        .active_def = active_def,
        .inst = inst,
        .inst_id_hex = inst_id_hex,
        .task_id = task_id,
    };
}

fn registerServiceTaskPlugin(allocator: std.mem.Allocator, target_api: plugin_interface.PluginApiVersion) !void {
    _ = allocator;
    try plugin_registry.registerGlobalPluginHandler(std.heap.smp_allocator, .{
        .node_type = "SERVICE_TASK",
        .handler = &ext03Handler,
        .plugin_name = "ext03-integration",
        .plugin_version = "1.0.0",
        .target_api = target_api,
    });
}

fn expectStatus(conn: *bpm.pool.Conn, allocator: std.mem.Allocator, instance_id_hex: []const u8, expected: []const u8) !void {
    const status = try rowText(
        conn,
        allocator,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    defer allocator.free(status);
    try testing.expectEqualStrings(expected, status);
}

test "TC-EXT-03-INT-01: startup plugin receives current instance context at runtime" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();
    resetInvocationProbe();
    g_plugin_mode = .complete_empty;
    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT03-INT-01";
    const fixture = try createWorkflowFixture(allocator, &def_store, &inst_store, &task_store, process_name, valid_service_attrs, "{\"seed\":\"v1\"}");
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");
    try testing.expect(g_handler_invoked);
    try testing.expectEqualStrings("SERVICE_TASK", g_last_node_type[0..g_last_node_type_len]);
    try testing.expectEqualStrings(valid_service_attrs, g_last_node_config[0..g_last_node_config_len]);
    try testing.expect(std.mem.containsAtLeast(u8, g_last_instance_vars[0..g_last_instance_vars_len], 1, "\"seed\":\"v1\""));
}

test "TC-EXT-03-INT-02: COMPLETE outcome keeps execution non-error" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();
    g_plugin_mode = .complete_empty;
    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT03-INT-02";
    const fixture = try createWorkflowFixture(allocator, &def_store, &inst_store, &task_store, process_name, valid_service_attrs, "{}");
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    try expectStatus(conn, allocator, fixture.inst_id_hex, "COMPLETED");
}

test "TC-EXT-03-INT-03: panic-mapped plugin failure transitions instance to ERROR" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();
    g_plugin_mode = .panic_caught;
    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT03-INT-03";
    const fixture = try createWorkflowFixture(allocator, &def_store, &inst_store, &task_store, process_name, valid_service_attrs, "{}");
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    try expectStatus(conn, allocator, fixture.inst_id_hex, "ERROR");

    const reason = try rowText(
        conn,
        allocator,
        "SELECT payload->>'reason' FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR' ORDER BY sequence_number DESC LIMIT 1",
        &.{fixture.inst_id_hex},
    );
    defer allocator.free(reason);
    try testing.expectEqualStrings("PLUGIN_PANIC_CAUGHT", reason);
}

test "TC-EXT-03-INT-04: runtime registration after startup freeze is rejected" {
    const allocator = testing.allocator;
    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();

    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    try testing.expectError(
        error.RegistryLocked,
        plugin_registry.registerGlobalPluginHandler(std.heap.smp_allocator, .{
            .node_type = "HUMAN_TASK",
            .handler = &ext03Handler,
            .plugin_name = "late-reg",
            .plugin_version = "1.0.0",
            .target_api = .{ .major = 1, .minor = 0 },
        }),
    );
}

test "TC-EXT-03-INT-05: incompatible API major version is rejected at startup registration" {
    const allocator = testing.allocator;
    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();

    try testing.expectError(
        error.IncompatibleApiVersion,
        registerServiceTaskPlugin(allocator, .{ .major = 2, .minor = 0 }),
    );
    try testing.expect(plugin_registry.resolveGlobalPluginHandler("SERVICE_TASK") == null);
}

test "TC-EXT-03-INT-06: plugin precedence shadows built-in service task runtime path" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();
    g_plugin_mode = .complete_empty;
    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT03-INT-06";
    // This URL would fail at runtime in the built-in path; plugin shadowing keeps the flow successful.
    const fixture = try createWorkflowFixture(allocator, &def_store, &inst_store, &task_store, process_name, valid_service_attrs, "{}");
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    try expectStatus(conn, allocator, fixture.inst_id_hex, "COMPLETED");
    const errors = try rowCount(conn, allocator, "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR'", &.{fixture.inst_id_hex});
    try testing.expectEqual(@as(usize, 0), errors);
}

test "TC-EXT-03-INT-07: COMPLETE output variables merge through EE-09 success path" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();
    g_plugin_mode = .complete_merge;
    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT03-INT-07";
    const fixture = try createWorkflowFixture(allocator, &def_store, &inst_store, &task_store, process_name, valid_service_attrs, "{\"existing\":\"old\",\"keep\":\"yes\"}");
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    try expectStatus(conn, allocator, fixture.inst_id_hex, "COMPLETED");
    const errors = try rowCount(conn, allocator, "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR'", &.{fixture.inst_id_hex});
    try testing.expectEqual(@as(usize, 0), errors);
}

test "TC-EXT-03-INT-08: invalid COMPLETE output payload transitions to EE-10 ERROR" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();
    g_plugin_mode = .complete_invalid;
    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT03-INT-08";
    const fixture = try createWorkflowFixture(allocator, &def_store, &inst_store, &task_store, process_name, valid_service_attrs, "{}");
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    try expectStatus(conn, allocator, fixture.inst_id_hex, "ERROR");
    const reason = try rowText(
        conn,
        allocator,
        "SELECT payload->>'reason' FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR' ORDER BY sequence_number DESC LIMIT 1",
        &.{fixture.inst_id_hex},
    );
    defer allocator.free(reason);
    try testing.expectEqualStrings("PLUGIN_OUTPUT_INVALID", reason);
}

test "TC-EXT-03-INT-09: explicit ERROR outcome applies EE-10 and blocks follow-up completion" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();
    g_plugin_mode = .explicit_error;
    try registerServiceTaskPlugin(allocator, .{ .major = 1, .minor = 0 });
    plugin_registry.freezeGlobalPluginRegistry();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT03-INT-09";
    const fixture = try createWorkflowFixture(allocator, &def_store, &inst_store, &task_store, process_name, valid_service_attrs, "{}");
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    try testing.expectError(
        CompleteTaskError.TaskAlreadyTerminated,
        inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}"),
    );

    const conn = try pool.acquire();
    defer pool.release(conn);
    try expectStatus(conn, allocator, fixture.inst_id_hex, "ERROR");
    const reason = try rowText(
        conn,
        allocator,
        "SELECT payload->>'reason' FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR' ORDER BY sequence_number DESC LIMIT 1",
        &.{fixture.inst_id_hex},
    );
    defer allocator.free(reason);
    try testing.expectEqualStrings("PLUGIN_FAIL_EXT03", reason);
}

test "TC-EXT-03-INT-10: missing plugin and missing built-in resolve to no handler" {
    plugin_registry.resetGlobalRegistryForTests();
    defer plugin_registry.resetGlobalRegistryForTests();

    const resolved = plugin_registry.resolveGlobalNodeHandlerKind("CUSTOM_NODE", false);
    try testing.expect(resolved == null);
}
