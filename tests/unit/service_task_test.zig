const std = @import("std");
const bpm = @import("bpm");

const st = bpm.service_task;
const transition_mod = bpm.transition;
const graph_mod = bpm.definition;

fn fakeInstanceId() [16]u8 {
    return [16]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x01 };
}

const CaptureServer = struct {
    port: u16,
    max_requests: usize = 1,
    delay_first_ms: u32 = 0,
    status_code: u16 = 200,
    response_body: []const u8 = "{}",
    location: ?[]const u8 = null,

    request_count: usize = 0,
    followed_count: usize = 0,

    first_trace_id: [128]u8 = undefined,
    first_trace_id_len: usize = 0,
    first_idempotency_key: [256]u8 = undefined,
    first_idempotency_key_len: usize = 0,
    first_custom_header: [128]u8 = undefined,
    first_custom_header_len: usize = 0,

    second_trace_id: [128]u8 = undefined,
    second_trace_id_len: usize = 0,
    second_idempotency_key: [256]u8 = undefined,
    second_idempotency_key_len: usize = 0,

    thread: ?std.Thread = null,

    fn start(self: *CaptureServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn join(self: *CaptureServer) void {
        if (self.thread) |t| t.join();
    }

    fn run(self: *CaptureServer) void {
        const listen_address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
        var server = listen_address.listen(std.testing.io, .{ .reuse_address = true }) catch return;
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
            if (std.mem.eql(u8, request.head.target, "/__stop")) {
                return;
            }

            self.request_count += 1;
            captureRequestHeaders(self, &request);

            if (self.request_count == 1 and self.delay_first_ms > 0) {
                std.Io.sleep(
                    std.Options.debug_io,
                    .fromMilliseconds(@as(i64, self.delay_first_ms)),
                    .awake,
                ) catch {};
            }

            const json_headers = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
            if (self.location) |loc| {
                const redirect_headers = [_]std.http.Header{
                    .{ .name = "location", .value = loc },
                    .{ .name = "content-type", .value = "application/json" },
                };
                request.respond(self.response_body, .{
                    .status = @as(std.http.Status, @enumFromInt(self.status_code)),
                    .keep_alive = false,
                    .extra_headers = &redirect_headers,
                }) catch return;
            } else {
                request.respond(self.response_body, .{
                    .status = @as(std.http.Status, @enumFromInt(self.status_code)),
                    .keep_alive = false,
                    .extra_headers = &json_headers,
                }) catch return;
            }

            if (self.followed_count > self.max_requests) return;
        }
    }
};

fn captureText(buffer: anytype, len: *usize, value: []const u8) void {
    const copy_len = @min(buffer.len, value.len);
    @memcpy(buffer[0..copy_len], value[0..copy_len]);
    len.* = copy_len;
}

fn captureRequestHeaders(server: *CaptureServer, request: anytype) void {
    var header_it = request.iterateHeaders();
    while (header_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-trace-id")) {
            if (server.request_count == 1) captureText(&server.first_trace_id, &server.first_trace_id_len, header.value) else captureText(&server.second_trace_id, &server.second_trace_id_len, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-bpm-idempotency-key")) {
            if (server.request_count == 1) captureText(&server.first_idempotency_key, &server.first_idempotency_key_len, header.value) else captureText(&server.second_idempotency_key, &server.second_idempotency_key_len, header.value);
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-custom")) {
            captureText(&server.first_custom_header, &server.first_custom_header_len, header.value);
        }
    }
}

test "EXT-01: parse SERVICE_TASK config with defaults" {
    const allocator = std.testing.allocator;

    const cfg = try st.parseConfigFromNodeAttributes(
        allocator,
        "svc-1",
        "{\"endpoint\":\"https://api.example.com\"}",
    );
    defer allocator.free(cfg.node_id);
    defer allocator.free(cfg.url_template);
    defer if (cfg.service_id) |v| allocator.free(v);
    if (cfg.headers_json) |h| allocator.free(h);
    if (cfg.body_template_json) |b| allocator.free(b);

    try std.testing.expectEqual(st.ServiceTaskRouteKind.inline_url, cfg.route_kind);
    try std.testing.expect(cfg.service_id == null);
    try std.testing.expectEqual(st.HttpMethod.POST, cfg.method);
    try std.testing.expectEqual(@as(u32, 30000), cfg.timeout_ms);
    try std.testing.expectEqual(@as(u8, 3), cfg.retry_limit);
}

test "EXT-01: parse SERVICE_TASK config accepts url + method" {
    const allocator = std.testing.allocator;

    const cfg = try st.parseConfigFromNodeAttributes(
        allocator,
        "svc-2",
        "{\"url\":\"https://api.example.com\",\"method\":\"PATCH\",\"timeout_ms\":5000,\"retry_limit\":1}",
    );
    defer allocator.free(cfg.node_id);
    defer allocator.free(cfg.url_template);
    defer if (cfg.service_id) |v| allocator.free(v);
    if (cfg.headers_json) |h| allocator.free(h);
    if (cfg.body_template_json) |b| allocator.free(b);

    try std.testing.expectEqual(st.ServiceTaskRouteKind.inline_url, cfg.route_kind);
    try std.testing.expect(cfg.service_id == null);
    try std.testing.expectEqual(st.HttpMethod.PATCH, cfg.method);
    try std.testing.expectEqual(@as(u32, 5000), cfg.timeout_ms);
    try std.testing.expectEqual(@as(u8, 1), cfg.retry_limit);
}

test "ADP-08: parse SERVICE_TASK config resolves service_id via catalog and enforces precedence" {
    const allocator = std.testing.allocator;

    const cfg = try st.parseConfigFromNodeAttributes(
        allocator,
        "svc-adp08-1",
        "{\"service_id\":\"svc.billing\",\"url\":\"https://inline.example.com/ignored\",\"service_catalog\":{\"svc.billing\":{\"endpoint_url\":\"https://catalog.example.com/billing\",\"is_active\":true}},\"capabilities\":[\"service:call:svc.billing\"],\"method\":\"POST\"}",
    );
    defer allocator.free(cfg.node_id);
    defer allocator.free(cfg.url_template);
    defer if (cfg.service_id) |v| allocator.free(v);
    if (cfg.headers_json) |h| allocator.free(h);
    if (cfg.body_template_json) |b| allocator.free(b);

    try std.testing.expectEqual(st.ServiceTaskRouteKind.catalog_service, cfg.route_kind);
    try std.testing.expect(cfg.warning != null);
    try std.testing.expectEqualStrings("svc.billing", cfg.service_id.?);
    try std.testing.expectEqualStrings("https://catalog.example.com/billing", cfg.url_template);
}

test "ADP-08: service_id path accepts wildcard service capability" {
    const allocator = std.testing.allocator;

    const cfg = try st.parseConfigFromNodeAttributes(
        allocator,
        "svc-adp08-1b",
        "{\"service_id\":\"svc.billing\",\"service_catalog\":{\"svc.billing\":{\"endpoint_url\":\"https://catalog.example.com/billing\",\"is_active\":true}},\"capabilities\":[\"service:call:*\"],\"method\":\"POST\"}",
    );
    defer allocator.free(cfg.node_id);
    defer allocator.free(cfg.url_template);
    defer if (cfg.service_id) |v| allocator.free(v);
    if (cfg.headers_json) |h| allocator.free(h);
    if (cfg.body_template_json) |b| allocator.free(b);

    try std.testing.expectEqual(st.ServiceTaskRouteKind.catalog_service, cfg.route_kind);
    try std.testing.expectEqualStrings("svc.billing", cfg.service_id.?);
    try std.testing.expectEqualStrings("https://catalog.example.com/billing", cfg.url_template);
}

test "ADP-08: service_id path without required capability is rejected" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.MissingServiceCapability,
        st.parseConfigFromNodeAttributes(
            allocator,
            "svc-adp08-2",
            "{\"service_id\":\"svc.billing\",\"service_catalog\":{\"svc.billing\":{\"endpoint_url\":\"https://catalog.example.com/billing\",\"is_active\":true}},\"capabilities\":[\"definitions:write\"]}",
        ),
    );
}

test "ADP-08: service_id path with missing catalog entry is rejected deterministically" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.CatalogEntryNotFound,
        st.parseConfigFromNodeAttributes(
            allocator,
            "svc-adp08-3",
            "{\"service_id\":\"svc.billing\",\"service_catalog\":{\"svc.users\":{\"endpoint_url\":\"https://catalog.example.com/users\",\"is_active\":true}},\"capabilities\":[\"service:call:svc.billing\"]}",
        ),
    );
}

test "ADP-08: service_id path with inactive catalog entry is rejected" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.CatalogEntryInactive,
        st.parseConfigFromNodeAttributes(
            allocator,
            "svc-adp08-4",
            "{\"service_id\":\"svc.billing\",\"service_catalog\":{\"svc.billing\":{\"endpoint_url\":\"https://catalog.example.com/billing\",\"is_active\":false}},\"capabilities\":[\"service:call:svc.billing\"]}",
        ),
    );
}

test "ADP-08: service_id path with invalid catalog endpoint shape is rejected" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidConfig,
        st.parseConfigFromNodeAttributes(
            allocator,
            "svc-adp08-5",
            "{\"service_id\":\"svc.billing\",\"service_catalog\":{\"svc.billing\":{\"endpoint_url\":42,\"is_active\":true}},\"capabilities\":[\"service:call:svc.billing\"]}",
        ),
    );
}

test "EXT-01: parse SERVICE_TASK config rejects invalid method" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.InvalidConfig,
        st.parseConfigFromNodeAttributes(
            allocator,
            "svc-3",
            "{\"url\":\"https://api.example.com\",\"method\":\"TRACE\"}",
        ),
    );
}

test "EXT-01: rendered URL cannot be empty" {
    try std.testing.expectError(error.EmptyRenderedUrl, st.validateRenderedUrl(""));
    try std.testing.expectError(error.EmptyRenderedUrl, st.validateRenderedUrl("   \n\t  "));
    try std.testing.expectError(error.InvalidConfig, st.validateRenderedUrl("ftp://example.com"));
    try st.validateRenderedUrl("https://example.com");
}

test "EXT-01: exponential backoff is capped" {
    try std.testing.expectEqual(@as(u32, 500), st.computeServiceTaskBackoffMs(1, 500, 30000));
    try std.testing.expectEqual(@as(u32, 1000), st.computeServiceTaskBackoffMs(2, 500, 30000));
    try std.testing.expectEqual(@as(u32, 2000), st.computeServiceTaskBackoffMs(3, 500, 30000));
    try std.testing.expectEqual(@as(u32, 30000), st.computeServiceTaskBackoffMs(12, 500, 30000));
}

test "EXT-01: classify and retry decisions" {
    try std.testing.expectEqual(@as(?st.ServiceTaskFailureKind, null), st.classifyFailureKind(204));
    try std.testing.expectEqual(st.ServiceTaskFailureKind.http_redirect_3xx, st.classifyFailureKind(302).?);
    try std.testing.expectEqual(st.ServiceTaskFailureKind.rate_limited_429, st.classifyFailureKind(429).?);
    try std.testing.expectEqual(st.ServiceTaskFailureKind.http_non_2xx, st.classifyFailureKind(500).?);

    try std.testing.expect(st.isRetriableFailure(.timeout));
    try std.testing.expect(!st.isRetriableFailure(.invalid_2xx_body));

    try std.testing.expectEqual(st.ServiceTaskDecision.retry, st.decideFailure(.network, 1, 3));
    try std.testing.expectEqual(st.ServiceTaskDecision.terminal_dlq, st.decideFailure(.network, 4, 3));
    try std.testing.expectEqual(st.ServiceTaskDecision.immediate_error, st.decideFailure(.invalid_2xx_body, 1, 3));
}

test "EXT-01: idempotency key is stable for same tuple" {
    const allocator = std.testing.allocator;

    const key_a = try st.buildIdempotencyKey(allocator, fakeInstanceId(), "node-1", "token-1");
    defer allocator.free(key_a);
    const key_b = try st.buildIdempotencyKey(allocator, fakeInstanceId(), "node-1", "token-1");
    defer allocator.free(key_b);

    try std.testing.expectEqualStrings(key_a, key_b);
}

test "TC-EXT-01-U06a: retry_limit=0 forces terminal_dlq on first retriable failure" {
    try std.testing.expectEqual(st.ServiceTaskDecision.terminal_dlq, st.decideFailure(.network, 1, 0));
    try std.testing.expectEqual(st.ServiceTaskDecision.immediate_error, st.decideFailure(.invalid_2xx_body, 1, 0));
}

test "TC-EXT-01-U08a: executeHttpRequest injects trace, idempotency, and configured headers" {
    const allocator = std.testing.allocator;

    var server = CaptureServer{
        .port = 18181,
        .max_requests = 1,
        .status_code = 200,
        .response_body = "{\"ok\":true}",
        .location = null,
    };
    try server.start();
    defer server.join();

    const cfg = st.ServiceTaskConfig{
        .node_id = "svc-1",
        .url_template = "http://127.0.0.1:18181/execute",
        .service_id = null,
        .route_kind = .inline_url,
        .warning = null,
        .method = .POST,
        .headers_json = "{\"X-Custom\":\"alpha\"}",
        .timeout_ms = 5000,
        .retry_limit = 1,
        .body_template_json = "{\"payload\":1}",
    };

    const result = try st.executeHttpRequest(allocator, cfg, "trace-123", "idem-456");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expectEqualStrings("trace-123", server.first_trace_id[0..server.first_trace_id_len]);
    try std.testing.expectEqualStrings("idem-456", server.first_idempotency_key[0..server.first_idempotency_key_len]);
    try std.testing.expectEqualStrings("alpha", server.first_custom_header[0..server.first_custom_header_len]);
}

test "TC-EXT-01-U09: service_task_completed merges response object into instance variables" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const initial = try std.json.parseFromSlice(std.json.Value, a, "{\"existing\":\"old\",\"untouched\":\"keep\"}", .{ .allocate = .alloc_always });
    const output = try std.json.parseFromSlice(std.json.Value, a, "{\"existing\":\"new\",\"merged\":\"yes\"}", .{ .allocate = .alloc_always });

    const nodes = [_]graph_mod.GraphNode{
        .{ .id = "svc", .node_type = .SERVICE_TASK, .label = null, .attributes = null },
        .{ .id = "end", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "svc", .target = "end", .condition = null, .is_default = false },
    };
    const snap = graph_mod.DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    var tokens = [_]transition_mod.Token{.{ .node_id = "svc", .branch_id = "branch-1" }};
    var pending_task_nodes = [_][]const u8{};
    var pending_events = [_]transition_mod.PendingEvent{};
    var cancelled_branch_ids = [_][]const u8{};

    const state = transition_mod.InstanceState{
        .instance_id = fakeInstanceId(),
        .status = .ACTIVE,
        .tokens = tokens[0..],
        .variables = initial.value.object,
        .join_counters = std.json.ObjectMap{},
        .pending_task_nodes = pending_task_nodes[0..],
        .error_detail = null,
        .pending_events = pending_events[0..],
        .cancelled_branch_ids = cancelled_branch_ids[0..],
    };

    const event = transition_mod.TransitionEvent{ .service_task_completed = .{
        .service_task_node_id = "svc",
        .output_variables = output.value.object,
    } };

    const new_state = try transition_mod.transition(a, snap, state, event);
    const serialized = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = new_state.variables }, .{});
    defer a.free(serialized);

    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"existing\":\"new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"merged\":\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\"untouched\":\"keep\"") != null);
    try std.testing.expectEqual(transition_mod.InstanceStatus.COMPLETED, new_state.status);
    try std.testing.expectEqual(@as(usize, 0), new_state.tokens.len);
}

test "TC-EXT-01-U10: invalid 2xx body is terminal when surfaced by runtime" {
    try std.testing.expectEqual(st.ServiceTaskFailureKind.invalid_2xx_body, st.ServiceTaskFailureKind.invalid_2xx_body);
    try std.testing.expectEqual(st.ServiceTaskDecision.immediate_error, st.decideFailure(.invalid_2xx_body, 1, 3));
    try std.testing.expect(!st.isRetriableFailure(.invalid_2xx_body));
}
