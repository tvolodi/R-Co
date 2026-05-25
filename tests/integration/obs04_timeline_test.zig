//! Integration tests for OBS-04 timeline endpoint behavior.
//!
//! These tests execute against a real PostgreSQL database and validate the
//! backend contract implemented by `instance_routes.handleTimeline`.

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const instance_routes = bpm.instance_routes;
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const Registry = bpm.registry.Registry;
const EventStore = bpm.store.Store;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
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

test "TC-OBS-04-INT-01: unknown instance returns HTTP 404" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = EventStore.init(alloc, &pool, &registry);

    const result = instance_routes.handleTimeline(
        &store,
        alloc,
        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
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

    const instance_id = "11111111-1111-1111-1111-111111111111";
    const definition_id = "22222222-2222-2222-2222-222222222222";
    const known_user_id = "33333333-3333-3333-3333-333333333333";
    const missing_user_id = "44444444-4444-4444-4444-444444444444";
    const system_actor_id = "55555555-5555-5555-5555-555555555555";

    cleanupInstance(&pool, instance_id);
    defer cleanupInstance(&pool, instance_id);
    cleanupUser(&pool, known_user_id);
    defer cleanupUser(&pool, known_user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try seedInstanceProjection(conn, instance_id, definition_id, "CANCELLED");
    try insertUser(conn, known_user_id, "obs04_user", "obs04@example.test", "Alice Kim");

    try insertArchivedEvent(
        conn,
        "aaaaaaaa-0000-0000-0000-000000000001",
        instance_id,
        "INSTANCE_STARTED",
        "{}",
        "{}",
        known_user_id,
        "2026-05-25T10:00:00Z",
        1,
        "obs04-int2-arch-1",
        1001,
    );
    try insertArchivedEvent(
        conn,
        "aaaaaaaa-0000-0000-0000-000000000002",
        instance_id,
        "TASK_ACTIVATED",
        "{\"node_id\":\"task_review\"}",
        "{\"token_description\":\"Deploy Token\"}",
        missing_user_id,
        "2026-05-25T10:02:00Z",
        2,
        "obs04-int2-arch-2",
        1002,
    );
    try insertEvent(
        conn,
        "aaaaaaaa-0000-0000-0000-000000000003",
        instance_id,
        "TASK_COMPLETED",
        "{\"node_id\":\"task_review\"}",
        "{}",
        system_actor_id,
        "2026-05-25T10:03:00Z",
        3,
        "obs04-int2-live-3",
    );
    try insertEvent(
        conn,
        "aaaaaaaa-0000-0000-0000-000000000004",
        instance_id,
        "INSTANCE_CANCELLED",
        "{}",
        "{}",
        known_user_id,
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
        instance_id,
        .{ .cursor = null, .page_size = 50 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"count\":4"));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"event_type\":\"INSTANCE_CANCELLED\""));

    const idx1 = std.mem.indexOf(u8, result.body, "aaaaaaaa-0000-0000-0000-000000000001") orelse return error.TestUnexpectedResult;
    const idx2 = std.mem.indexOf(u8, result.body, "aaaaaaaa-0000-0000-0000-000000000002") orelse return error.TestUnexpectedResult;
    const idx3 = std.mem.indexOf(u8, result.body, "aaaaaaaa-0000-0000-0000-000000000003") orelse return error.TestUnexpectedResult;
    const idx4 = std.mem.indexOf(u8, result.body, "aaaaaaaa-0000-0000-0000-000000000004") orelse return error.TestUnexpectedResult;
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

    const instance_id = "66666666-6666-6666-6666-666666666666";
    const definition_id = "77777777-7777-7777-7777-777777777777";
    const actor_id = "88888888-8888-8888-8888-888888888888";

    cleanupInstance(&pool, instance_id);
    defer cleanupInstance(&pool, instance_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try seedInstanceProjection(conn, instance_id, definition_id, "ACTIVE");
    try insertEvent(conn, "bbbbbbbb-0000-0000-0000-000000000001", instance_id, "INSTANCE_STARTED", "{}", "{}", actor_id, "2026-05-25T12:00:00Z", 1, "obs04-int3-1");
    try insertEvent(conn, "bbbbbbbb-0000-0000-0000-000000000002", instance_id, "TASK_ACTIVATED", "{}", "{}", actor_id, "2026-05-25T12:01:00Z", 2, "obs04-int3-2");
    try insertEvent(conn, "bbbbbbbb-0000-0000-0000-000000000003", instance_id, "TASK_COMPLETED", "{}", "{}", actor_id, "2026-05-25T12:02:00Z", 3, "obs04-int3-3");

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = EventStore.init(alloc, &pool, &registry);

    const first = instance_routes.handleTimeline(
        &store,
        alloc,
        instance_id,
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
        instance_id,
        .{ .cursor = next_cursor, .page_size = 2 },
    );
    defer freeRouteBody(alloc, second.body);

    try testing.expectEqual(@as(u16, 200), second.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, second.body, 1, "\"count\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, second.body, 1, "bbbbbbbb-0000-0000-0000-000000000003"));
    try testing.expect(!std.mem.containsAtLeast(u8, second.body, 1, "bbbbbbbb-0000-0000-0000-000000000001"));
    try testing.expect(!std.mem.containsAtLeast(u8, second.body, 1, "bbbbbbbb-0000-0000-0000-000000000002"));
    try testing.expect(std.mem.containsAtLeast(u8, second.body, 1, "\"next_cursor\":null"));
}

test "TC-OBS-04-INT-04: actor display-name fallback order user -> token_description -> system" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = "99999999-9999-9999-9999-999999999999";
    const definition_id = "abababab-abab-abab-abab-abababababab";
    const known_user_id = "cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd";
    const unknown_user_id = "dededede-dede-dede-dede-dededededede";
    const system_user_id = "efefefef-efef-efef-efef-efefefefefef";

    cleanupInstance(&pool, instance_id);
    defer cleanupInstance(&pool, instance_id);
    cleanupUser(&pool, known_user_id);
    defer cleanupUser(&pool, known_user_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    try seedInstanceProjection(conn, instance_id, definition_id, "ACTIVE");
    try insertUser(conn, known_user_id, "obs04_user2", "obs04-user2@example.test", "Operator Ada");

    try insertEvent(conn, "cccccccc-0000-0000-0000-000000000001", instance_id, "INSTANCE_STARTED", "{}", "{}", known_user_id, "2026-05-25T14:00:00Z", 1, "obs04-int4-1");
    try insertEvent(conn, "cccccccc-0000-0000-0000-000000000002", instance_id, "TASK_ACTIVATED", "{}", "{\"token_description\":\"Automation Token\"}", unknown_user_id, "2026-05-25T14:01:00Z", 2, "obs04-int4-2");
    try insertEvent(conn, "cccccccc-0000-0000-0000-000000000003", instance_id, "TASK_COMPLETED", "{}", "{}", system_user_id, "2026-05-25T14:02:00Z", 3, "obs04-int4-3");

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = EventStore.init(alloc, &pool, &registry);

    const result = instance_routes.handleTimeline(
        &store,
        alloc,
        instance_id,
        .{ .cursor = null, .page_size = 50 },
    );
    defer freeRouteBody(alloc, result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"Operator Ada\""));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"Automation Token\""));
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"actor_display_name\":\"system\""));
}
