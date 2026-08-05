//! Integration tests for EXT-01 — Service task node type.
//!
//! These tests exercise the real database-backed instance workflow and a
//! deterministic local HTTP test server. Each scenario completes the human
//! task that precedes the SERVICE_TASK node, allowing the engine to execute
//! the service task path exactly as it does in production.
//!
//! DIRECTIVE T-1: all backend tests use the real PostgreSQL database.
//!
//! Requirement traceability:
//!   EXT-01 → TC-EXT-01-INT-01 through TC-EXT-01-INT-07
//!
//! Run with: zig build test-integration

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;

/// Per-test-run "created_by" UUID — generated fresh instead of a fixed
/// literal so this fixture follows the per-test-UUID isolation convention
/// (see docs/guides/test_infrastructure_guide.md §9 / ISS-0121).
fn makeCreatorUuid() [16]u8 {
    var bytes: bpm.uuid.Uuid = undefined;
    bpm.uuid.generateUuidV4BytesInto(&bytes);
    return bytes;
}

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const Definition = bpm.definition.Definition;
const Instance = bpm.engine.Instance;
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

fn rowCount(
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const []const u8,
) !usize {
    const row = (try conn.queryRow(allocator, sql, params)) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return std.fmt.parseInt(usize, row[0] orelse "0", 10);
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

fn expectJsonStringField(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    key: []const u8,
    expected_value: []const u8,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    const value = parsed.value.object.get(key) orelse return error.TestUnexpectedResult;
    try testing.expect(value == .string);
    try testing.expectEqualStrings(expected_value, value.string);
}

fn expectJsonMissingField(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    key: []const u8,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get(key) == null);
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

const RequestCapture = struct {
    trace_id: [128]u8 = undefined,
    trace_id_len: usize = 0,
    idempotency_key: [256]u8 = undefined,
    idempotency_key_len: usize = 0,
    custom_header: [128]u8 = undefined,
    custom_header_len: usize = 0,
};

const ServerScenario = enum {
    object_merge,
    invalid_body,
    timeout_retry,
    redirect,
    rate_limit,
    failure_loop,
};

const LocalHttpServer = struct {
    port: u16,
    scenario: ServerScenario,
    max_requests: usize,
    delay_first_ms: u32 = 0,

    request_count: usize = 0,
    followed_count: usize = 0,
    captures: [4]RequestCapture = .{ .{}, .{}, .{}, .{} },
    thread: ?std.Thread = null,

    fn start(self: *LocalHttpServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        try self.waitUntilReady();
    }

    fn waitUntilReady(self: *LocalHttpServer) !void {
        const allocator = std.testing.allocator;
        const ready_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/__ready", .{self.port});
        defer allocator.free(ready_url);

        var client: std.http.Client = .{
            .allocator = allocator,
            .io = std.Options.debug_io,
        };
        defer client.deinit();

        var attempt: usize = 0;
        while (attempt < 50) : (attempt += 1) {
            const probe = client.fetch(.{
                .location = .{ .url = ready_url },
                .method = .GET,
                .redirect_behavior = .unhandled,
            }) catch {
                std.Io.sleep(
                    std.Options.debug_io,
                    .fromMilliseconds(20),
                    .awake,
                ) catch {};
                continue;
            };

            if (probe.status == .ok) return;
            std.Io.sleep(
                std.Options.debug_io,
                .fromMilliseconds(20),
                .awake,
            ) catch {};
        }

        return error.TestUnexpectedResult;
    }

    fn join(self: *LocalHttpServer) void {
        if (self.thread) |t| {
            if (self.request_count < self.max_requests) {
                self.requestStop();
            }
            t.join();
            self.thread = null;
        }
    }

    fn requestStop(self: *LocalHttpServer) void {
        const allocator = std.testing.allocator;
        const stop_url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/__stop", .{self.port}) catch return;
        defer allocator.free(stop_url);

        var client: std.http.Client = .{
            .allocator = allocator,
            .io = std.Options.debug_io,
        };
        defer client.deinit();

        _ = client.fetch(.{
            .location = .{ .url = stop_url },
            .method = .GET,
            .redirect_behavior = .unhandled,
        }) catch {};
    }

    fn copyText(buffer: []u8, len: *usize, value: []const u8) void {
        const copy_len = @min(buffer.len, value.len);
        @memcpy(buffer[0..copy_len], value[0..copy_len]);
        len.* = copy_len;
    }

    fn captureHeaders(self: *LocalHttpServer, request: anytype) void {
        var header_it = request.iterateHeaders();
        while (header_it.next()) |header| {
            const slot = if (self.request_count == 1) &self.captures[0] else &self.captures[1];
            if (std.ascii.eqlIgnoreCase(header.name, "x-trace-id")) {
                copyText(slot.trace_id[0..], &slot.trace_id_len, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-bpm-idempotency-key")) {
                copyText(slot.idempotency_key[0..], &slot.idempotency_key_len, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "x-custom")) {
                copyText(slot.custom_header[0..], &slot.custom_header_len, header.value);
            }
        }
    }

    fn run(self: *LocalHttpServer) void {
        const listen_address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
        var server = blk: {
            var bind_attempt: usize = 0;
            while (bind_attempt < 50) : (bind_attempt += 1) {
                const bound = listen_address.listen(std.testing.io, .{ .reuse_address = true }) catch {
                    std.Io.sleep(
                        std.Options.debug_io,
                        .fromMilliseconds(20),
                        .awake,
                    ) catch {};
                    continue;
                };
                break :blk bound;
            }
            return;
        };
        defer server.deinit(std.testing.io);

        while (self.request_count < self.max_requests) {
            var stream = server.accept(std.testing.io) catch return;
            defer stream.close(std.testing.io);

            var recv_buffer: [4096]u8 = undefined;
            var send_buffer: [4096]u8 = undefined;
            var connection_reader = stream.reader(std.testing.io, &recv_buffer);
            var connection_writer = stream.writer(std.testing.io, &send_buffer);
            var http_server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

            var request = http_server.receiveHead() catch return;
            if (std.mem.eql(u8, request.head.target, "/__ready")) {
                request.respond("{}", .{
                    .status = .ok,
                    .keep_alive = false,
                }) catch return;
                continue;
            }
            if (std.mem.eql(u8, request.head.target, "/__stop")) {
                return;
            }
            if (std.mem.eql(u8, request.head.target, "/followed")) {
                self.followed_count += 1;
            }

            self.request_count += 1;
            self.captureHeaders(&request);

            if (self.request_count == 1 and self.delay_first_ms > 0) {
                std.Io.sleep(
                    std.Options.debug_io,
                    .fromMilliseconds(@as(i64, self.delay_first_ms)),
                    .awake,
                ) catch {};
            }

            const json_headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
            switch (self.scenario) {
                .object_merge => request.respond("{\"merged\":\"yes\",\"existing\":\"new\"}", .{
                    .status = .ok,
                    .keep_alive = false,
                    .extra_headers = &json_headers,
                }) catch return,
                .invalid_body => request.respond("[1,2,3]", .{
                    .status = .ok,
                    .keep_alive = false,
                    .extra_headers = &json_headers,
                }) catch return,
                .timeout_retry => request.respond("{\"ok\":true}", .{
                    .status = if (self.request_count == 1) @as(std.http.Status, @enumFromInt(500)) else .ok,
                    .keep_alive = false,
                    .extra_headers = &json_headers,
                }) catch return,
                .redirect => {
                    var location_buf: [64]u8 = undefined;
                    const location_value = std.fmt.bufPrint(&location_buf, "http://127.0.0.1:{d}/followed", .{self.port}) catch return;
                    const redirect_headers = [_]std.http.Header{
                        .{ .name = "location", .value = location_value },
                        .{ .name = "content-type", .value = "application/json" },
                    };
                    request.respond("{\"redirect\":true}", .{
                        .status = @as(std.http.Status, @enumFromInt(302)),
                        .keep_alive = false,
                        .extra_headers = &redirect_headers,
                    }) catch return;
                },
                .rate_limit => {
                    if (self.request_count == 1) {
                        request.respond("{\"retry\":true}", .{
                            .status = @as(std.http.Status, @enumFromInt(429)),
                            .keep_alive = false,
                            .extra_headers = &json_headers,
                        }) catch return;
                    } else {
                        request.respond("{\"retry\":false}", .{
                            .status = .ok,
                            .keep_alive = false,
                            .extra_headers = &json_headers,
                        }) catch return;
                    }
                },
                .failure_loop => request.respond("{\"fail\":true}", .{
                    .status = @as(std.http.Status, @enumFromInt(500)),
                    .keep_alive = false,
                    .extra_headers = &json_headers,
                }) catch return,
            }
        }
    }
};

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

    // Keep graph node/edge buffers alive for the full create() call.
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

// ---------------------------------------------------------------------------
// TC-EXT-01-INT-01: empty rendered URL rejects activation and transitions ERROR
// ---------------------------------------------------------------------------

test "TC-EXT-01-INT-01: empty rendered URL rejects activation and transitions instance to ERROR" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    const process_name = "EXT01-INT-01";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"url\":\"   \",\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("ERROR", status);

    const error_count = try rowCount(conn, allocator, "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR'", &.{fixture.inst_id_hex});
    try testing.expectEqual(@as(usize, 1), error_count);
}

// ---------------------------------------------------------------------------
// TC-EXT-01-INT-02: 2xx JSON object response merges variables and headers
// ---------------------------------------------------------------------------

test "TC-EXT-01-INT-02: 2xx JSON object response merges variables and preserves outbound headers" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18182,
        .scenario = .object_merge,
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const process_name = "EXT01-INT-02";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"url\":\"http://127.0.0.1:18182/merge\",\"method\":\"POST\",\"headers\":{\"X-Custom\":\"alpha\"},\"timeout_ms\":5000,\"retry_limit\":1}",
        "{\"existing\":\"old\",\"untouched\":\"keep\"}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("COMPLETED", status);

    const vars_json = try rowText(conn, allocator, "SELECT variables FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(vars_json);
    try expectJsonStringField(allocator, vars_json, "existing", "new");
    try expectJsonStringField(allocator, vars_json, "merged", "yes");
    try expectJsonStringField(allocator, vars_json, "untouched", "keep");

    try testing.expectEqual(@as(usize, 1), server.request_count);
    try testing.expectEqual(@as(usize, 0), server.followed_count);
    try testing.expectEqualStrings(fixture.inst_id_hex, server.captures[0].trace_id[0..server.captures[0].trace_id_len]);
    try testing.expectEqualStrings("alpha", server.captures[0].custom_header[0..server.captures[0].custom_header_len]);
}

// ---------------------------------------------------------------------------
// TC-EXT-01-INT-03: invalid 2xx body transitions to ERROR without merge
// ---------------------------------------------------------------------------

test "TC-EXT-01-INT-03: 2xx non-object body transitions to ERROR without merge" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18183,
        .scenario = .invalid_body,
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const process_name = "EXT01-INT-03";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"url\":\"http://127.0.0.1:18183/invalid\",\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{\"existing\":\"old\"}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("ERROR", status);

    const vars_json = try rowText(conn, allocator, "SELECT variables FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(vars_json);
    try expectJsonStringField(allocator, vars_json, "existing", "old");
    try expectJsonMissingField(allocator, vars_json, "merged");

    const error_count = try rowCount(conn, allocator, "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR'", &.{fixture.inst_id_hex});
    try testing.expectEqual(@as(usize, 1), error_count);
}

// ---------------------------------------------------------------------------
// TC-EXT-01-INT-04: retriable failure triggers retry and preserves headers
// ---------------------------------------------------------------------------

test "TC-EXT-01-INT-04: retriable first-attempt failure triggers retry and preserves outbound headers across attempts" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18184,
        .scenario = .timeout_retry,
        .max_requests = 2,
    };
    try server.start();
    defer server.join();

    const process_name = "EXT01-INT-04";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"url\":\"http://127.0.0.1:18184/slow\",\"method\":\"POST\",\"timeout_ms\":1,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    try testing.expectEqual(@as(usize, 2), server.request_count);
    try testing.expectEqualStrings(server.captures[0].trace_id[0..server.captures[0].trace_id_len], server.captures[1].trace_id[0..server.captures[1].trace_id_len]);
    try testing.expectEqualStrings(server.captures[0].idempotency_key[0..server.captures[0].idempotency_key_len], server.captures[1].idempotency_key[0..server.captures[1].idempotency_key_len]);
}

// ---------------------------------------------------------------------------
// TC-EXT-01-INT-05: redirect responses are not auto-followed
// ---------------------------------------------------------------------------

test "TC-EXT-01-INT-05: redirect responses are not auto-followed and count as failures" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18185,
        .scenario = .redirect,
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const process_name = "EXT01-INT-05";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"url\":\"http://127.0.0.1:18185/redirect\",\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("ERROR", status);
    try testing.expectEqual(@as(usize, 1), server.request_count);
    try testing.expectEqual(@as(usize, 0), server.followed_count);
}

// ---------------------------------------------------------------------------
// TC-EXT-01-INT-06: HTTP 429 is treated as a retriable failure
// ---------------------------------------------------------------------------

test "TC-EXT-01-INT-06: HTTP 429 is treated as a retriable failure" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18186,
        .scenario = .rate_limit,
        .max_requests = 2,
    };
    try server.start();
    defer server.join();

    const process_name = "EXT01-INT-06";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"url\":\"http://127.0.0.1:18186/rate-limit\",\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    try testing.expectEqual(@as(usize, 2), server.request_count);
    try testing.expectEqualStrings(server.captures[0].trace_id[0..server.captures[0].trace_id_len], server.captures[1].trace_id[0..server.captures[1].trace_id_len]);
    try testing.expectEqualStrings(server.captures[0].idempotency_key[0..server.captures[0].idempotency_key_len], server.captures[1].idempotency_key[0..server.captures[1].idempotency_key_len]);
}

// ---------------------------------------------------------------------------
// TC-EXT-01-INT-07: exhausted retries move failure to DLQ and ERROR atomically
// ---------------------------------------------------------------------------

test "TC-EXT-01-INT-07: exhausted retries move the failure to OBS-05 DLQ and ERROR" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18187,
        .scenario = .failure_loop,
        .max_requests = 2,
    };
    try server.start();
    defer server.join();

    const process_name = "EXT01-INT-07";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"url\":\"http://127.0.0.1:18187/failure\",\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("ERROR", status);

    const dlq_count = try rowCount(conn, allocator, "SELECT COUNT(*) FROM dead_letter_items WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    try testing.expectEqual(@as(usize, 1), dlq_count);

    const error_count = try rowCount(conn, allocator, "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR'", &.{fixture.inst_id_hex});
    try testing.expectEqual(@as(usize, 1), error_count);
}

// ---------------------------------------------------------------------------
// TC-ADP-08-INT-01: service_id catalog route executes with capability check
// ---------------------------------------------------------------------------

test "TC-ADP-08-INT-01: service_id uses catalog endpoint and ignores inline url when both are present" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18188,
        .scenario = .object_merge,
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const process_name = "ADP08-INT-01";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"service_id\":\"svc.orders\",\"url\":\"http://127.0.0.1:19999/inline-ignored\",\"service_catalog\":{\"svc.orders\":{\"endpoint_url\":\"http://127.0.0.1:18188/catalog\",\"is_active\":true}},\"capabilities\":[\"service:call:svc.orders\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("COMPLETED", status);

    try testing.expectEqual(@as(usize, 1), server.request_count);
}

// ---------------------------------------------------------------------------
// TC-ADP-08-INT-02: missing required service capability blocks execution
// ---------------------------------------------------------------------------

test "TC-ADP-08-INT-02: service_id without service:call capability is rejected at definition validation" {
    const allocator = testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    _ = SnapshotStore;
    _ = InstanceStore;
    _ = TaskStore;

    const created_by = makeCreatorUuid();
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "H", .node_type = .HUMAN_TASK, .label = "Approve", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "X", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc.orders\",\"service_catalog\":{\"svc.orders\":{\"endpoint_url\":\"http://127.0.0.1:18189/catalog\",\"is_active\":true}},\"capabilities\":[\"definitions:write\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "H", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "H", .target = "X", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "X", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    try testing.expectError(
        bpm.definition.DefinitionError.GraphValidationFailed,
        def_store.create(allocator, CreateParams{
            .name = "ADP08-INT-02-invalid-capability",
            .version = "1.0",
            .description = null,
            .stage = null,
            .created_by = created_by,
            .graph = graph,
        }),
    );
}

// ---------------------------------------------------------------------------
// TC-ADP-08-INT-03: missing catalog entry fails deterministically
// ---------------------------------------------------------------------------

test "TC-ADP-08-INT-03: missing catalog entry transitions to ERROR before HTTP call" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18190,
        .scenario = .object_merge,
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const process_name = "ADP08-INT-03";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"service_id\":\"svc.orders\",\"service_catalog\":{\"svc.users\":{\"endpoint_url\":\"http://127.0.0.1:18190/catalog\",\"is_active\":true}},\"capabilities\":[\"service:call:svc.orders\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("ERROR", status);

    try testing.expectEqual(@as(usize, 0), server.request_count);
}

// ---------------------------------------------------------------------------
// TC-ADP-08-INT-04: inactive catalog entry fails deterministically
// ---------------------------------------------------------------------------

test "TC-ADP-08-INT-04: inactive catalog entry transitions to ERROR before HTTP call" {
    const allocator = testing.allocator;
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
    var task_store = TaskStore.init(&pool);

    var server = LocalHttpServer{
        .port = 18191,
        .scenario = .object_merge,
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const process_name = "ADP08-INT-04";
    const fixture = try createWorkflowFixture(
        allocator,
        &def_store,
        &inst_store,
        &task_store,
        process_name,
        "{\"service_id\":\"svc.orders\",\"service_catalog\":{\"svc.orders\":{\"endpoint_url\":\"http://127.0.0.1:18191/catalog\",\"is_active\":false}},\"capabilities\":[\"service:call:svc.orders\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}",
        "{}",
    );
    defer cleanupWorkflow(&pool, fixture.inst_id_hex, process_name);
    defer allocator.free(fixture.inst_id_hex);
    defer freeInstance(allocator, fixture.inst);
    defer freeDefinition(allocator, fixture.active_def);
    defer freeDefinition(allocator, fixture.def);

    _ = try inst_store.completeTask(allocator, &task_store, fixture.task_id, "{}");

    const conn = try pool.acquire();
    defer pool.release(conn);
    const status = try rowText(conn, allocator, "SELECT status FROM instance_projections WHERE instance_id = $1::uuid", &.{fixture.inst_id_hex});
    defer allocator.free(status);
    try testing.expectEqualStrings("ERROR", status);

    try testing.expectEqual(@as(usize, 0), server.request_count);
}
