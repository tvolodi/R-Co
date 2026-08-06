//! Integration tests for OBS-04 timeline endpoint behavior.
//!
//! These tests execute against a real PostgreSQL database and validate the
//! backend contract implemented by `instance_routes.handleTimeline`.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const instance_routes = bpm.instance_routes;
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const Registry = bpm.registry.Registry;
const EventStore = bpm.store.Store;

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
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

fn freeRouteBody(allocator: std.mem.Allocator, body: []const u8) void {
    const static_fallback = "{\"error\":\"internal_error\"}";
    if (!std.mem.eql(u8, body, static_fallback)) allocator.free(body);
}

fn cleanupInstance(pool: *Pool, instance_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM events_archive WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
}

fn cleanupUser(pool: *Pool, user_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM user_roles WHERE user_id = $1::uuid", &.{user_id}) catch {};
    conn.exec("DELETE FROM user_groups WHERE user_id = $1::uuid", &.{user_id}) catch {};
    conn.exec("DELETE FROM api_tokens WHERE user_id = $1::uuid", &.{user_id}) catch {};
    conn.exec("DELETE FROM users WHERE id = $1::uuid", &.{user_id}) catch {};
}

fn seedInstanceProjection(
    conn: *bpm.pool.Conn,
    instance_id: []const u8,
    definition_id: []const u8,
    status: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, correlation_key, status,
        \\  current_nodes, variables, error_detail, last_event_seq,
        \\  started_at, completed_at, cancelled_at, updated_at
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, NULL, $3,
        \\  '[]'::jsonb, '{}'::jsonb, NULL, 0,
        \\  NOW() - INTERVAL '1 day',
        \\  CASE WHEN $3 = 'COMPLETED' THEN NOW() - INTERVAL '1 hour' ELSE NULL END,
        \\  CASE WHEN $3 = 'CANCELLED' THEN NOW() - INTERVAL '30 minutes' ELSE NULL END,
        \\  NOW()
        \\)
    ,
        &.{ instance_id, definition_id, status },
    );
}

fn seedInstanceProjectionWithTenant(
    conn: *bpm.pool.Conn,
    instance_id: []const u8,
    definition_id: []const u8,
    tenant_id: []const u8,
    status: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO instance_projections (
        \\  instance_id, tenant_id, definition_id, correlation_key, status,
        \\  current_nodes, variables, error_detail, last_event_seq,
        \\  started_at, completed_at, cancelled_at, updated_at
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, $3::uuid, NULL, $4,
        \\  '[]'::jsonb, '{}'::jsonb, NULL, 0,
        \\  NOW() - INTERVAL '1 day',
        \\  CASE WHEN $4 = 'COMPLETED' THEN NOW() - INTERVAL '1 hour' ELSE NULL END,
        \\  CASE WHEN $4 = 'CANCELLED' THEN NOW() - INTERVAL '30 minutes' ELSE NULL END,
        \\  NOW()
        \\)
    ,
        &.{ instance_id, tenant_id, definition_id, status },
    );
}

fn insertUser(
    conn: *bpm.pool.Conn,
    user_id: []const u8,
    username: []const u8,
    email: []const u8,
    display_name: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, $3, 'hash', true, $4, 'ACTIVE')
    ,
        &.{ user_id, email, display_name, username },
    );
}

fn insertEvent(
    conn: *bpm.pool.Conn,
    event_id: []const u8,
    instance_id: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    metadata_json: []const u8,
    actor_id: []const u8,
    created_at_iso: []const u8,
    sequence_number: i64,
    idempotency_key: []const u8,
) !void {
    const seq_s = try std.fmt.allocPrint(testing.allocator, "{d}", .{sequence_number});
    defer testing.allocator.free(seq_s);

    try conn.exec(
        \\INSERT INTO events (
        \\  event_id, instance_id, event_type, payload, metadata,
        \\  actor_id, created_at, sequence_number, idempotency_key
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, $3, $4::jsonb, $5::jsonb,
        \\  $6::uuid, $7::timestamptz, $8::bigint, $9
        \\)
    ,
        &.{ event_id, instance_id, event_type, payload_json, metadata_json, actor_id, created_at_iso, seq_s, idempotency_key },
    );
}

fn insertArchivedEvent(
    conn: *bpm.pool.Conn,
    event_id: []const u8,
    instance_id: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    metadata_json: []const u8,
    actor_id: []const u8,
    created_at_iso: []const u8,
    sequence_number: i64,
    idempotency_key: []const u8,
    global_seq: i64,
) !void {
    const seq_s = try std.fmt.allocPrint(testing.allocator, "{d}", .{sequence_number});
    defer testing.allocator.free(seq_s);
    const global_seq_s = try std.fmt.allocPrint(testing.allocator, "{d}", .{global_seq});
    defer testing.allocator.free(global_seq_s);

    try conn.exec(
        \\INSERT INTO events_archive (
        \\  event_id, instance_id, event_type, payload, metadata,
        \\  actor_id, created_at, sequence_number, idempotency_key, global_seq
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, $3, $4::jsonb, $5::jsonb,
        \\  $6::uuid, $7::timestamptz, $8::bigint, $9, $10::bigint
        \\)
    ,
        &.{ event_id, instance_id, event_type, payload_json, metadata_json, actor_id, created_at_iso, seq_s, idempotency_key, global_seq_s },
    );
}

fn extractJsonStringField(
    allocator: std.mem.Allocator,
    body: []const u8,
    field: []const u8,
) !?[]u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{field});
    defer allocator.free(pattern);

    const start = std.mem.indexOf(u8, body, pattern) orelse return null;
    const after = start + pattern.len;
    const end_rel = std.mem.indexOfScalarPos(u8, body, after, '"') orelse return error.TestUnexpectedResult;
    return try allocator.dupe(u8, body[after..end_rel]);
}

fn fillRandom(buf: []u8) void {
    const builtin = @import("builtin");
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS"),
    }
}

fn randomUuidString() [36]u8 {
    var bytes = [_]u8{0} ** 16;
    fillRandom(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var out = [_]u8{0} ** 36;
    var out_idx = @as(usize, 0);
    for (bytes, 0..) |b, idx| {
        if (idx == 4 or idx == 6 or idx == 8 or idx == 10) {
            out[out_idx] = '-';
            out_idx += 1;
        }
        out[out_idx] = hex[@as(usize, @intCast((b >> 4) & 0x0f))];
        out[out_idx + 1] = hex[@as(usize, @intCast(b & 0x0f))];
        out_idx += 2;
    }
    return out;
}

test "TC-OBS-04-INT-01: unknown instance returns HTTP 404" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const missing_instance_id = randomUuidString();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = EventStore.init(alloc, &pool, &registry);

    const result = instance_routes.handleTimeline(
        &store,
        alloc,
        missing_instance_id[0..],
        .{ .cursor = null, .page_size = 50 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 404), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "INSTANCE_NOT_FOUND"));
}

test "TC-OBS-04-INT-02: cancelled instance includes archived+live full history in ascending order" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = randomUuidString();
    const definition_id = randomUuidString();
    const known_user_id = randomUuidString();
    const missing_user_id = randomUuidString();
    const system_actor_id = randomUuidString();
    const archived_event_1 = randomUuidString();
    const archived_event_2 = randomUuidString();
    const live_event_3 = randomUuidString();
    const live_event_4 = randomUuidString();

    cleanupInstance(&pool, instance_id[0..]);
    defer cleanupInstance(&pool, instance_id[0..]);
    cleanupUser(&pool, known_user_id[0..]);
    defer cleanupUser(&pool, known_user_id[0..]);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try seedInstanceProjection(conn, instance_id[0..], definition_id[0..], "CANCELLED");
    try insertUser(conn, known_user_id[0..], "obs04_user", "obs04@example.test", "Alice Kim");

    try insertArchivedEvent(
        conn,
        archived_event_1[0..],
        instance_id[0..],
        "INSTANCE_STARTED",
        "{}",
        "{}",
        known_user_id[0..],
        "2026-05-25T10:00:00Z",
        1,
        "obs04-int2-arch-1",
        1001,
    );
    try insertArchivedEvent(
        conn,
        archived_event_2[0..],
        instance_id[0..],
        "TASK_ACTIVATED",
        "{\"node_id\":\"task_review\"}",
        "{\"token_description\":\"Deploy Token\"}",
        missing_user_id[0..],
        "2026-05-25T10:02:00Z",
        2,
        "obs04-int2-arch-2",
        1002,
    );
    try insertEvent(
        conn,
        live_event_3[0..],
        instance_id[0..],
        "TASK_COMPLETED",
        "{\"node_id\":\"task_review\"}",
        "{}",
        system_actor_id[0..],
        "2026-05-25T10:03:00Z",
        3,
        "obs04-int2-live-3",
    );
    try insertEvent(
        conn,
        live_event_4[0..],
        instance_id[0..],
        "INSTANCE_CANCELLED",
        "{}",
        "{}",
        known_user_id[0..],
        "2026-05-25T10:04:00Z",
        4,
        "obs04-int2-live-4",
    );

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = EventStore.init(alloc, &pool, &registry);

    const result = instance_routes.handleTimeline(
        &store,
        alloc,
        instance_id[0..],
        .{ .cursor = null, .page_size = 50 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"count\":4"));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"event_type\":\"INSTANCE_CANCELLED\""));

    const idx1 = std.mem.indexOf(u8, result.body, archived_event_1[0..]) orelse return error.TestUnexpectedResult;
    const idx2 = std.mem.indexOf(u8, result.body, archived_event_2[0..]) orelse return error.TestUnexpectedResult;
    const idx3 = std.mem.indexOf(u8, result.body, live_event_3[0..]) orelse return error.TestUnexpectedResult;
    const idx4 = std.mem.indexOf(u8, result.body, live_event_4[0..]) orelse return error.TestUnexpectedResult;
    try testing.expect(idx1 < idx2 and idx2 < idx3 and idx3 < idx4);

    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"Alice Kim\""));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"Deploy Token\""));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"system\""));
}

test "TC-OBS-04-INT-03: cursor pagination returns deterministic continuation without duplicates" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = randomUuidString();
    const definition_id = randomUuidString();
    const actor_id = randomUuidString();
    const event_1 = randomUuidString();
    const event_2 = randomUuidString();
    const event_3 = randomUuidString();

    cleanupInstance(&pool, instance_id[0..]);
    defer cleanupInstance(&pool, instance_id[0..]);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try seedInstanceProjection(conn, instance_id[0..], definition_id[0..], "ACTIVE");
    try insertEvent(conn, event_1[0..], instance_id[0..], "INSTANCE_STARTED", "{}", "{}", actor_id[0..], "2026-05-25T12:00:00Z", 1, "obs04-int3-1");
    try insertEvent(conn, event_2[0..], instance_id[0..], "TASK_ACTIVATED", "{}", "{}", actor_id[0..], "2026-05-25T12:01:00Z", 2, "obs04-int3-2");
    try insertEvent(conn, event_3[0..], instance_id[0..], "TASK_COMPLETED", "{}", "{}", actor_id[0..], "2026-05-25T12:02:00Z", 3, "obs04-int3-3");

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = EventStore.init(alloc, &pool, &registry);

    const first = instance_routes.handleTimeline(
        &store,
        alloc,
        instance_id[0..],
        .{ .cursor = null, .page_size = 2 },
    );
    defer freeRouteBody(alloc, first.body);

    try testing.expectEqual(@as(u16, 200), first.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, first.body, 1, "\"count\":2"));
    const next_cursor = (try extractJsonStringField(alloc, first.body, "next_cursor")) orelse return error.TestUnexpectedResult;
    defer alloc.free(next_cursor);
    try testing.expect(next_cursor.len > 0);

    const second = instance_routes.handleTimeline(
        &store,
        alloc,
        instance_id[0..],
        .{ .cursor = next_cursor, .page_size = 2 },
    );
    defer freeRouteBody(alloc, second.body);

    try testing.expectEqual(@as(u16, 200), second.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, second.body, 1, "\"count\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, second.body, 1, event_3[0..]));
    try testing.expect(!std.mem.containsAtLeast(u8, second.body, 1, event_1[0..]));
    try testing.expect(!std.mem.containsAtLeast(u8, second.body, 1, event_2[0..]));
    try testing.expect(std.mem.containsAtLeast(u8, second.body, 1, "\"next_cursor\":null"));
}

test "TC-OBS-04-INT-04: actor display-name fallback order user -> token_description -> system" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = randomUuidString();
    const definition_id = randomUuidString();
    const known_user_id = randomUuidString();
    const unknown_user_id = randomUuidString();
    const system_user_id = randomUuidString();
    const event_1 = randomUuidString();
    const event_2 = randomUuidString();
    const event_3 = randomUuidString();

    cleanupInstance(&pool, instance_id[0..]);
    defer cleanupInstance(&pool, instance_id[0..]);
    cleanupUser(&pool, known_user_id[0..]);
    defer cleanupUser(&pool, known_user_id[0..]);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try seedInstanceProjection(conn, instance_id[0..], definition_id[0..], "ACTIVE");
    try insertUser(conn, known_user_id[0..], "obs04_user2", "obs04-user2@example.test", "Operator Ada");

    try insertEvent(conn, event_1[0..], instance_id[0..], "INSTANCE_STARTED", "{}", "{}", known_user_id[0..], "2026-05-25T14:00:00Z", 1, "obs04-int4-1");
    try insertEvent(conn, event_2[0..], instance_id[0..], "TASK_ACTIVATED", "{}", "{\"token_description\":\"Automation Token\"}", unknown_user_id[0..], "2026-05-25T14:01:00Z", 2, "obs04-int4-2");
    try insertEvent(conn, event_3[0..], instance_id[0..], "TASK_COMPLETED", "{}", "{}", system_user_id[0..], "2026-05-25T14:02:00Z", 3, "obs04-int4-3");

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = EventStore.init(alloc, &pool, &registry);

    const result = instance_routes.handleTimeline(
        &store,
        alloc,
        instance_id[0..],
        .{ .cursor = null, .page_size = 50 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"Operator Ada\""));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"Automation Token\""));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"system\""));
}

test "TC-OBS-04-INT-05: timeline resolves tenant from instance projection when query tenant is default" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = randomUuidString();
    const definition_id = randomUuidString();
    const non_default_tenant = randomUuidString();
    const actor_id = randomUuidString();
    const event_id = randomUuidString();

    cleanupInstance(&pool, instance_id[0..]);
    defer cleanupInstance(&pool, instance_id[0..]);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try seedInstanceProjectionWithTenant(conn, instance_id[0..], definition_id[0..], non_default_tenant[0..], "ACTIVE");
    try insertEvent(
        conn,
        event_id[0..],
        instance_id[0..],
        "INSTANCE_STARTED",
        "{}",
        "{}",
        actor_id[0..],
        "2026-05-30T04:00:00Z",
        1,
        "obs04-int5-live-1",
    );
    try conn.exec(
        "UPDATE events SET tenant_id = $1::uuid WHERE event_id = $2::uuid",
        &.{ non_default_tenant[0..], event_id[0..] },
    );

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = EventStore.init(alloc, &pool, &registry);

    const result = instance_routes.handleTimeline(
        &store,
        alloc,
        instance_id[0..],
        .{ .cursor = null, .page_size = 50 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"count\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, event_id[0..]));
}
