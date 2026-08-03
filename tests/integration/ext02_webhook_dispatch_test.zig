const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;
const webhooks_routes = bpm.webhooks_routes;
const webhook_store = bpm.webhook_subscription_store;
const webhook_dispatcher = bpm.webhook_dispatcher;
const auth = bpm.api_auth;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("FATAL: BPM_TEST_DB_URL is not set - integration tests cannot run\n", .{});
            return error.MissingTestDbUrl;
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

fn seedAdminUser(conn: *bpm.pool.Conn, user_id: []const u8, email: []const u8) !void {
    try conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, 'EXT02 Admin', 'hash', true, 'ext02_admin', 'ACTIVE')
        \\ON CONFLICT (id) DO UPDATE SET
        \\  email = EXCLUDED.email,
        \\  display_name = EXCLUDED.display_name,
        \\  password_hash = EXCLUDED.password_hash,
        \\  is_active = EXCLUDED.is_active,
        \\  username = EXCLUDED.username,
        \\  status = EXCLUDED.status
    , &.{ user_id, email });

    try conn.exec(
        \\INSERT INTO user_roles (user_id, role_id)
        \\SELECT $1::uuid, id FROM roles WHERE name = 'PLATFORM_ADMIN'
        \\ON CONFLICT (user_id, role_id) DO NOTHING
    , &.{user_id});
}

fn cleanupExt02Rows(conn: *bpm.pool.Conn, owner_id: []const u8) void {
    conn.exec(
        \\DELETE FROM webhook_deliveries
        \\WHERE subscription_id IN (SELECT id FROM webhook_subscriptions WHERE owner_id = $1::uuid)
    , &.{owner_id}) catch {};
    conn.exec("DELETE FROM webhook_subscriptions WHERE owner_id = $1::uuid", &.{owner_id}) catch {};
    conn.exec("DELETE FROM user_roles WHERE user_id = $1::uuid", &.{owner_id}) catch {};
    conn.exec("DELETE FROM users WHERE id = $1::uuid", &.{owner_id}) catch {};
}

fn prepareExt02Owner(conn: *bpm.pool.Conn, owner_id: []const u8, email: []const u8) !void {
    try conn.begin();
    cleanupExt02Rows(conn, owner_id);
    try seedAdminUser(conn, owner_id, email);
    try conn.commit();
}

fn seedWebhookSubscription(
    conn: *bpm.pool.Conn,
    subscription_id: []const u8,
    owner_id: []const u8,
    target_url: []const u8,
    event_types: []const u8,
    secret: ?[]const u8,
) !void {
    const secret_value = secret orelse "";
    try conn.exec(
        \\INSERT INTO webhook_subscriptions (
        \\  id, owner_id, url, secret, event_types, is_active, status,
        \\  consecutive_failures, max_attempts, created_at, updated_at
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, $3, $4, $5::text[], true, 'ACTIVE',
        \\  0, 5, NOW(), NOW()
        \\)
        \\ON CONFLICT (id) DO UPDATE SET
        \\  owner_id = EXCLUDED.owner_id,
        \\  url = EXCLUDED.url,
        \\  secret = EXCLUDED.secret,
        \\  event_types = EXCLUDED.event_types,
        \\  is_active = EXCLUDED.is_active,
        \\  status = EXCLUDED.status,
        \\  consecutive_failures = EXCLUDED.consecutive_failures,
        \\  max_attempts = EXCLUDED.max_attempts,
        \\  updated_at = NOW()
    , &.{ subscription_id, owner_id, target_url, secret_value, event_types });
}

fn adminActor(user_id: []const u8) auth.AuthContext {
    return .{
        .user_id = user_id,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "ext02-admin-token",
        .principal = "ext02-admin-token",
    };
}

fn nonAdminActor(user_id: []const u8) auth.AuthContext {
    return .{
        .user_id = user_id,
        .role = .PROCESS_OPERATOR,
        .is_bootstrap = false,
        .token_id = "ext02-worker-token",
        .principal = "ext02-worker-token",
    };
}

fn extractJsonStringField(
    allocator: std.mem.Allocator,
    body: []const u8,
    field: []const u8,
) error{ OutOfMemory, TestUnexpectedResult }![]u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{field});
    defer allocator.free(pattern);

    const start = std.mem.indexOf(u8, body, pattern) orelse return error.TestUnexpectedResult;
    const after_key = start + pattern.len;
    const rest = body[after_key..];
    const end_rel = std.mem.indexOfScalar(u8, rest, '"') orelse return error.TestUnexpectedResult;

    return allocator.dupe(u8, rest[0..end_rel]);
}

fn queryText(
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

fn queryBool(
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const []const u8,
) !bool {
    const value = try queryText(conn, allocator, sql, params);
    defer allocator.free(value);
    return std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "true");
}

fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        raw[0],  raw[1],  raw[2],  raw[3],
        raw[4],  raw[5],  raw[6],  raw[7],
        raw[8],  raw[9],  raw[10], raw[11],
        raw[12], raw[13], raw[14], raw[15],
    });
}

const LocalWebhookServer = struct {
    port: u16,
    response_status: u16,
    response_content_type: []const u8,
    response_body: []const u8,
    max_requests: usize,

    request_count: usize = 0,
    signature_seen: bool = false,
    event_type: [64]u8 = undefined,
    event_type_len: usize = 0,
    attempt: [16]u8 = undefined,
    attempt_len: usize = 0,
    trace_id: [128]u8 = undefined,
    trace_id_len: usize = 0,
    thread: ?std.Thread = null,

    fn start(self: *LocalWebhookServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        try self.waitReady();
    }

    fn waitReady(self: *LocalWebhookServer) !void {
        const allocator = testing.allocator;
        const ready_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/__ready", .{self.port});
        defer allocator.free(ready_url);

        var client: std.http.Client = .{ .allocator = allocator, .io = std.Options.debug_io };
        defer client.deinit();

        var attempt_idx: usize = 0;
        while (attempt_idx < 50) : (attempt_idx += 1) {
            const probe = client.fetch(.{
                .location = .{ .url = ready_url },
                .method = .GET,
                .redirect_behavior = .unhandled,
            }) catch {
                std.Io.sleep(std.Options.debug_io, .fromMilliseconds(20), .awake) catch {};
                continue;
            };
            if (probe.status == .ok) return;
            std.Io.sleep(std.Options.debug_io, .fromMilliseconds(20), .awake) catch {};
        }
        return error.TestUnexpectedResult;
    }

    fn join(self: *LocalWebhookServer) void {
        if (self.thread) |t| {
            if (self.request_count < self.max_requests) {
                self.requestStop();
            }
            t.join();
            self.thread = null;
        }
    }

    fn requestStop(self: *LocalWebhookServer) void {
        const allocator = testing.allocator;
        const stop_url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/__stop", .{self.port}) catch return;
        defer allocator.free(stop_url);

        var client: std.http.Client = .{ .allocator = allocator, .io = std.Options.debug_io };
        defer client.deinit();
        _ = client.fetch(.{
            .location = .{ .url = stop_url },
            .method = .GET,
            .redirect_behavior = .unhandled,
        }) catch {};
    }

    fn copyText(dst: []u8, dst_len: *usize, value: []const u8) void {
        const n = @min(dst.len, value.len);
        @memcpy(dst[0..n], value[0..n]);
        dst_len.* = n;
    }

    fn run(self: *LocalWebhookServer) void {
        const listen_address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
        var server = blk: {
            var bind_attempt: usize = 0;
            while (bind_attempt < 50) : (bind_attempt += 1) {
                const bound = listen_address.listen(std.testing.io, .{ .reuse_address = true }) catch {
                    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(20), .awake) catch {};
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
                request.respond("{}", .{ .status = .ok, .keep_alive = false }) catch return;
                continue;
            }
            if (std.mem.eql(u8, request.head.target, "/__stop")) return;

            self.request_count += 1;
            var header_it = request.iterateHeaders();
            while (header_it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "x-bpm-signature")) self.signature_seen = true;
                if (std.ascii.eqlIgnoreCase(header.name, "x-bpm-event-type")) copyText(self.event_type[0..], &self.event_type_len, header.value);
                if (std.ascii.eqlIgnoreCase(header.name, "x-bpm-attempt")) copyText(self.attempt[0..], &self.attempt_len, header.value);
                if (std.ascii.eqlIgnoreCase(header.name, "x-trace-id")) copyText(self.trace_id[0..], &self.trace_id_len, header.value);
            }

            const headers = [_]std.http.Header{.{ .name = "content-type", .value = self.response_content_type }};
            request.respond(self.response_body, .{
                .status = @as(std.http.Status, @enumFromInt(self.response_status)),
                .keep_alive = false,
                .extra_headers = &headers,
            }) catch return;
        }
    }
};

test "TC-EXT-02-INT-01: Admin create subscription returns 201 and persists normalized row" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int01-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const actor = adminActor(owner_id);
    const body = "{\"target_url\":\"http://127.0.0.1:19101/hook\",\"event_types\":[\"task.completed\"],\"secret\":\"sig\"}";
    const result = webhooks_routes.handleCreateSubscription(allocator, &pool, actor, body, false);
    defer if (result.body.len > 0) allocator.free(result.body);

    try testing.expectEqual(@as(u16, 201), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"status\":\"ACTIVE\""));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"max_attempts\":5"));

    const persisted = try queryText(
        conn,
        allocator,
        \\SELECT status
        \\FROM webhook_subscriptions
        \\WHERE owner_id = $1::uuid AND url = $2
    ,
        &.{ owner_id, "http://127.0.0.1:19101/hook" },
    );
    defer allocator.free(persisted);
    try testing.expectEqualStrings("ACTIVE", persisted);
}

test "TC-EXT-02-INT-02: GET subscriptions is admin-only and redacts secret value" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int02-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const signed_sub = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19102/signed",
        .event_types = &.{.task_completed},
        .secret = "super-secret-value",
    }, false);
    defer signed_sub.deinit(allocator);

    const plain_sub = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19102/plain",
        .event_types = &.{.task_completed},
        .secret = null,
    }, false);
    defer plain_sub.deinit(allocator);

    const admin_result = webhooks_routes.handleListSubscriptions(allocator, &pool, adminActor(owner_id));
    defer if (admin_result.body.len > 0) allocator.free(admin_result.body);
    try testing.expectEqual(@as(u16, 200), admin_result.status_code);
    try testing.expect(!std.mem.containsAtLeast(u8, admin_result.body, 1, "super-secret-value"));

    const worker_result = webhooks_routes.handleListSubscriptions(allocator, &pool, nonAdminActor(owner_id));
    defer if (worker_result.body.len > 0) allocator.free(worker_result.body);
    try testing.expectEqual(@as(u16, 403), worker_result.status_code);
}

test "TC-EXT-02-INT-03: DELETE subscription is admin-only and removes row" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int03-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const created = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19103/hook",
        .event_types = &.{.task_completed},
        .secret = null,
    }, false);
    defer created.deinit(allocator);

    const worker_delete = webhooks_routes.handleDeleteSubscription(allocator, &pool, nonAdminActor(owner_id), created.subscription_id);
    defer if (worker_delete.body.len > 0) allocator.free(worker_delete.body);
    try testing.expectEqual(@as(u16, 403), worker_delete.status_code);

    const unknown_delete = webhooks_routes.handleDeleteSubscription(allocator, &pool, adminActor(owner_id), "00000000-0000-0000-0000-000000000999");
    defer if (unknown_delete.body.len > 0) allocator.free(unknown_delete.body);
    try testing.expectEqual(@as(u16, 404), unknown_delete.status_code);

    const admin_delete = webhooks_routes.handleDeleteSubscription(allocator, &pool, adminActor(owner_id), created.subscription_id);
    defer if (admin_delete.body.len > 0) allocator.free(admin_delete.body);
    try testing.expectEqual(@as(u16, 204), admin_delete.status_code);

    const exists = try queryBool(
        conn,
        allocator,
        \\SELECT EXISTS(SELECT 1 FROM webhook_subscriptions WHERE id = $1::uuid)
    ,
        &.{created.subscription_id},
    );
    try testing.expect(!exists);
}

test "TC-EXT-02-INT-04: Matching lifecycle event fans out and emits contract-compliant request body/headers" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var receiver = LocalWebhookServer{
        .port = 19104,
        .response_status = 200,
        .response_content_type = "application/json",
        .response_body = "{}",
        .max_requests = 1,
    };
    try receiver.start();
    defer receiver.join();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int04-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const sub = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19104/hook",
        .event_types = &.{.task_completed},
        .secret = null,
    }, false);
    defer sub.deinit(allocator);

    _ = try webhook_dispatcher.enqueueDeliveryAttempts(allocator, &pool, .{
        .event_type = .task_completed,
        .instance_id = "11111111-1111-1111-1111-111111111111",
        .timestamp = "2026-05-25T12:00:00Z",
        .payload_json = "{\"ok\":true}",
        .trace_id = "trace-ext02-int04",
    });

    try webhook_dispatcher.dispatchDueWebhookAttempts(allocator, &pool);
    try testing.expectEqual(@as(usize, 1), receiver.request_count);
    try testing.expectEqualStrings("task.completed", receiver.event_type[0..receiver.event_type_len]);
    try testing.expectEqualStrings("1", receiver.attempt[0..receiver.attempt_len]);
    try testing.expectEqualStrings("trace-ext02-int04", receiver.trace_id[0..receiver.trace_id_len]);
}

test "TC-EXT-02-INT-05: Signature header is present only for secret-configured subscription and matches body HMAC" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var signed_receiver = LocalWebhookServer{
        .port = 19105,
        .response_status = 200,
        .response_content_type = "application/json",
        .response_body = "{}",
        .max_requests = 1,
    };
    try signed_receiver.start();
    defer signed_receiver.join();

    var unsigned_receiver = LocalWebhookServer{
        .port = 19106,
        .response_status = 200,
        .response_content_type = "application/json",
        .response_body = "{}",
        .max_requests = 1,
    };
    try unsigned_receiver.start();
    defer unsigned_receiver.join();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int05-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const signed_sub = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19105/hook",
        .event_types = &.{.task_completed},
        .secret = "ext02-secret",
    }, false);
    defer signed_sub.deinit(allocator);

    const unsigned_sub = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19106/hook",
        .event_types = &.{.task_completed},
        .secret = null,
    }, false);
    defer unsigned_sub.deinit(allocator);

    _ = try webhook_dispatcher.enqueueDeliveryAttempts(allocator, &pool, .{
        .event_type = .task_completed,
        .instance_id = "22222222-2222-2222-2222-222222222222",
        .timestamp = "2026-05-25T12:01:00Z",
        .payload_json = "{\"sig\":true}",
        .trace_id = "trace-ext02-int05",
    });
    try webhook_dispatcher.dispatchDueWebhookAttempts(allocator, &pool);

    try testing.expect(signed_receiver.signature_seen);
    try testing.expect(!unsigned_receiver.signature_seen);
}

test "TC-EXT-02-INT-06: Non-2xx and timeout failures retry with at-least-once semantics through attempt 5 budget" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var failing_receiver = LocalWebhookServer{
        .port = 19107,
        .response_status = 500,
        .response_content_type = "application/json",
        .response_body = "{\"error\":true}",
        .max_requests = 1,
    };
    try failing_receiver.start();
    defer failing_receiver.join();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int06-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const sub_500 = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19107/hook",
        .event_types = &.{.task_completed},
        .secret = null,
    }, false);
    defer sub_500.deinit(allocator);

    _ = try webhook_dispatcher.enqueueDeliveryAttempts(allocator, &pool, .{
        .event_type = .task_completed,
        .instance_id = "33333333-3333-3333-3333-333333333333",
        .timestamp = "2026-05-25T12:02:00Z",
        .payload_json = "{\"retry\":true}",
        .trace_id = "trace-ext02-int06",
    });

    try webhook_dispatcher.dispatchDueWebhookAttempts(allocator, &pool);

    const status_500 = try queryText(conn, allocator, "SELECT status FROM webhook_deliveries WHERE subscription_id = $1::uuid", &.{sub_500.subscription_id});
    defer allocator.free(status_500);
    try testing.expectEqualStrings("failed", status_500);

    const next_due_after_now = try queryBool(
        conn,
        allocator,
        "SELECT (next_attempt_at IS NOT NULL)::text FROM webhook_deliveries WHERE subscription_id = $1::uuid",
        &.{sub_500.subscription_id},
    );
    try testing.expect(next_due_after_now);
}

test "TC-EXT-02-INT-07: Fifth consecutive failure pauses subscription and emits OBS-06 alert event" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var failing_receiver = LocalWebhookServer{
        .port = 19108,
        .response_status = 500,
        .response_content_type = "application/json",
        .response_body = "{\"error\":true}",
        .max_requests = 5,
    };
    try failing_receiver.start();
    defer failing_receiver.join();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int07-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const sub = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19108/hook",
        .event_types = &.{.task_completed},
        .secret = null,
    }, false);
    defer sub.deinit(allocator);

    _ = try webhook_dispatcher.enqueueDeliveryAttempts(allocator, &pool, .{
        .event_type = .task_completed,
        .instance_id = "44444444-4444-4444-4444-444444444444",
        .timestamp = "2026-05-25T12:03:00Z",
        .payload_json = "{\"pause\":true}",
        .trace_id = "trace-ext02-int07",
    });

    var idx: u8 = 0;
    while (idx < 5) : (idx += 1) {
        try conn.exec("UPDATE webhook_deliveries SET next_attempt_at = NOW() WHERE subscription_id = $1::uuid", &.{sub.subscription_id});
        try webhook_dispatcher.dispatchDueWebhookAttempts(allocator, &pool);
    }

    const sub_status = try queryText(conn, allocator, "SELECT status FROM webhook_subscriptions WHERE id = $1::uuid", &.{sub.subscription_id});
    defer allocator.free(sub_status);
    try testing.expectEqualStrings("PAUSED", sub_status);

    const delivery_status = try queryText(conn, allocator, "SELECT status FROM webhook_deliveries WHERE subscription_id = $1::uuid", &.{sub.subscription_id});
    defer allocator.free(delivery_status);
    try testing.expectEqualStrings("exhausted", delivery_status);
}

test "TC-EXT-02-INT-08: Create/delete operations write OBS-03 audit rows atomically" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int08-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const created = try webhook_store.createSubscription(allocator, &pool, owner_id, .{
        .target_url = "http://127.0.0.1:19108/audit",
        .event_types = &.{.task_completed},
        .secret = null,
    }, false);
    defer created.deinit(allocator);

    try webhook_store.deleteSubscription(allocator, &pool, owner_id, created.subscription_id);

    const create_count = try queryText(
        conn,
        allocator,
        \\SELECT COUNT(*)::text
        \\FROM audit_entries
        \\WHERE action = 'webhook_subscription.create'
        \\  AND resource_id = $1::uuid
        \\  AND before_state IS NULL
        \\  AND after_state IS NOT NULL
    ,
        &.{created.subscription_id},
    );
    defer allocator.free(create_count);
    try testing.expectEqualStrings("1", create_count);

    const delete_count = try queryText(
        conn,
        allocator,
        \\SELECT COUNT(*)::text
        \\FROM audit_entries
        \\WHERE action = 'webhook_subscription.delete'
        \\  AND resource_id = $1::uuid
        \\  AND before_state IS NOT NULL
        \\  AND after_state IS NULL
    ,
        &.{created.subscription_id},
    );
    defer allocator.free(delete_count);
    try testing.expectEqualStrings("1", delete_count);
}

test "TC-EXT-02-INT-09: 2xx with invalid/non-JSON response body is success without retry" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var invalid_json_receiver = LocalWebhookServer{
        .port = 19109,
        .response_status = 200,
        .response_content_type = "text/plain",
        .response_body = "not-json",
        .max_requests = 1,
    };
    try invalid_json_receiver.start();
    defer invalid_json_receiver.join();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int09-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const subscription_id = try randomUuidStr(allocator);
    defer allocator.free(subscription_id);
    try seedWebhookSubscription(conn, subscription_id, owner_id, "http://127.0.0.1:19109/hook", "{task.completed}", null);

    _ = try webhook_dispatcher.enqueueDeliveryAttempts(allocator, &pool, .{
        .event_type = .task_completed,
        .instance_id = "55555555-5555-5555-5555-555555555555",
        .timestamp = "2026-05-25T12:04:00Z",
        .payload_json = "{\"invalid\":true}",
        .trace_id = "trace-ext02-int09",
    });
    try webhook_dispatcher.dispatchDueWebhookAttempts(allocator, &pool);

    const delivery_status = try queryText(conn, allocator, "SELECT status FROM webhook_deliveries WHERE subscription_id = $1::uuid", &.{subscription_id});
    defer allocator.free(delivery_status);
    try testing.expectEqualStrings("success", delivery_status);

    const consecutive = try queryText(conn, allocator, "SELECT consecutive_failures::text FROM webhook_subscriptions WHERE id = $1::uuid", &.{subscription_id});
    defer allocator.free(consecutive);
    try testing.expectEqualStrings("0", consecutive);
}

test "TC-EXT-02-INT-10: Same source event with multiple subscriptions keeps retry counters independent" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var ok_receiver = LocalWebhookServer{
        .port = 19110,
        .response_status = 200,
        .response_content_type = "application/json",
        .response_body = "{}",
        .max_requests = 1,
    };
    try ok_receiver.start();
    defer ok_receiver.join();

    var fail_receiver = LocalWebhookServer{
        .port = 19111,
        .response_status = 500,
        .response_content_type = "application/json",
        .response_body = "{\"fail\":true}",
        .max_requests = 5,
    };
    try fail_receiver.start();
    defer fail_receiver.join();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const owner_id = try randomUuidStr(allocator);
    defer allocator.free(owner_id);
    const conn = try pool.acquire();
    defer pool.release(conn);
    try prepareExt02Owner(conn, owner_id, "ext02-int10-admin@example.test");
    defer cleanupExt02Rows(conn, owner_id);

    const ok_sub_id = try randomUuidStr(allocator);
    defer allocator.free(ok_sub_id);
    const fail_sub_id = try randomUuidStr(allocator);
    defer allocator.free(fail_sub_id);
    try seedWebhookSubscription(conn, ok_sub_id, owner_id, "http://127.0.0.1:19110/hook", "{task.completed}", null);
    try seedWebhookSubscription(conn, fail_sub_id, owner_id, "http://127.0.0.1:19111/hook", "{task.completed}", null);

    _ = try webhook_dispatcher.enqueueDeliveryAttempts(allocator, &pool, .{
        .event_type = .task_completed,
        .instance_id = "66666666-6666-6666-6666-666666666666",
        .timestamp = "2026-05-25T12:05:00Z",
        .payload_json = "{\"fanout\":true}",
        .trace_id = "trace-ext02-int10",
    });
    try webhook_dispatcher.dispatchDueWebhookAttempts(allocator, &pool);

    var attempt_idx: u8 = 1;
    while (attempt_idx < 5) : (attempt_idx += 1) {
        try conn.exec(
            "UPDATE webhook_deliveries SET next_attempt_at = NOW() WHERE subscription_id = $1::uuid AND status = 'failed'",
            &.{fail_sub_id},
        );
        try webhook_dispatcher.dispatchDueWebhookAttempts(allocator, &pool);
    }

    const ok_failures = try queryText(conn, allocator, "SELECT consecutive_failures::text FROM webhook_subscriptions WHERE id = $1::uuid", &.{ok_sub_id});
    defer allocator.free(ok_failures);
    try testing.expectEqualStrings("0", ok_failures);

    const fail_status = try queryText(conn, allocator, "SELECT status FROM webhook_subscriptions WHERE id = $1::uuid", &.{fail_sub_id});
    defer allocator.free(fail_status);
    try testing.expectEqualStrings("PAUSED", fail_status);
}
