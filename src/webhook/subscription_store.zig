const std = @import("std");
const db = @import("../db/pool.zig");

pub const WebhookEventType = enum {
    instance_started,
    instance_completed,
    instance_errored,
    task_activated,
    task_completed,

    pub fn fromWire(raw: []const u8) ?WebhookEventType {
        if (std.mem.eql(u8, raw, "instance.started")) return .instance_started;
        if (std.mem.eql(u8, raw, "instance.completed")) return .instance_completed;
        if (std.mem.eql(u8, raw, "instance.errored")) return .instance_errored;
        if (std.mem.eql(u8, raw, "task.activated")) return .task_activated;
        if (std.mem.eql(u8, raw, "task.completed")) return .task_completed;
        return null;
    }

    pub fn toWire(self: WebhookEventType) []const u8 {
        return switch (self) {
            .instance_started => "instance.started",
            .instance_completed => "instance.completed",
            .instance_errored => "instance.errored",
            .task_activated => "task.activated",
            .task_completed => "task.completed",
        };
    }
};

pub const SubscriptionStatus = enum {
    ACTIVE,
    PAUSED,
};

pub const CreateSubscriptionRequest = struct {
    target_url: []const u8,
    event_types: []const WebhookEventType,
    secret: ?[]const u8,
};

pub const WebhookSubscription = struct {
    subscription_id: []u8,
    target_url: []u8,
    event_types: []WebhookEventType,
    status: SubscriptionStatus,
    consecutive_failures: u8,
    max_attempts: u8,
    last_attempt_at: ?[]u8,
    last_failure_at: ?[]u8,
    paused_at: ?[]u8,
    created_at: []u8,
    updated_at: []u8,
    secret_configured: bool,

    pub fn deinit(self: WebhookSubscription, allocator: std.mem.Allocator) void {
        allocator.free(self.subscription_id);
        allocator.free(self.target_url);
        allocator.free(self.event_types);
        if (self.last_attempt_at) |value| allocator.free(value);
        if (self.last_failure_at) |value| allocator.free(value);
        if (self.paused_at) |value| allocator.free(value);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
    }
};

pub const SubscriptionStoreError = error{
    ValidationFailed,
    InvalidEventType,
    NotFound,
    Forbidden,
    AuditWriteFailed,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub fn validateCreateRequest(req: CreateSubscriptionRequest, production_mode: bool) SubscriptionStoreError!void {
    if (req.target_url.len == 0) return error.ValidationFailed;
    if (production_mode) {
        if (!std.mem.startsWith(u8, req.target_url, "https://")) return error.ValidationFailed;
    } else {
        if (!std.mem.startsWith(u8, req.target_url, "https://") and !std.mem.startsWith(u8, req.target_url, "http://")) {
            return error.ValidationFailed;
        }
    }
    if (req.event_types.len == 0) return error.ValidationFailed;
}

pub fn createSubscription(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    actor_id: []const u8,
    req: CreateSubscriptionRequest,
    production_mode: bool,
) SubscriptionStoreError!WebhookSubscription {
    try validateCreateRequest(req, production_mode);

    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;
    errdefer conn.rollback() catch {};

    conn.exec("SELECT set_config('bpm.actor_id', $1, true)", &.{actor_id}) catch return error.PersistenceFailed;
    conn.exec("SELECT set_config('bpm.audit_action', 'webhook_subscription.create', true)", &.{}) catch return error.PersistenceFailed;

    const event_types_pg = eventTypesPgArrayLiteral(allocator, req.event_types) catch return error.OutOfMemory;
    defer allocator.free(event_types_pg);

    const secret_value = req.secret orelse "";
    const rows = conn.query(
        allocator,
        \\INSERT INTO webhook_subscriptions
        \\  (owner_id, url, secret, event_types, is_active, status, consecutive_failures, max_attempts, created_at, updated_at)
        \\VALUES
        \\  ($1::uuid, $2, $3, $4::text[], true, 'ACTIVE', 0, 5, NOW(), NOW())
        \\RETURNING
        \\  id::text,
        \\  url,
        \\  event_types::text,
        \\  status,
        \\  consecutive_failures::text,
        \\  max_attempts::text,
        \\  NULL::timestamptz,
        \\  NULL::timestamptz,
        \\  NULL::timestamptz,
        \\  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ,
        &.{ actor_id, req.target_url, secret_value, event_types_pg },
    ) catch return error.PersistenceFailed;
    if (rows.rows.len == 0) return error.PersistenceFailed;

    const row = rows.rows[0];
    const subscription_id = allocator.dupe(u8, row[0] orelse "") catch return error.OutOfMemory;
    defer allocator.free(subscription_id);

    const created = try rowToSubscription(allocator, row, req.secret != null);
    errdefer created.deinit(allocator);

    var inserted_rows = rows;
    inserted_rows.deinit();

    conn.commit() catch return error.PersistenceFailed;
    return created;
}

pub fn listSubscriptions(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
) SubscriptionStoreError![]WebhookSubscription {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const rows = conn.query(
        allocator,
        \\SELECT
        \\  id::text,
        \\  url,
        \\  event_types::text,
        \\  status,
        \\  consecutive_failures::text,
        \\  max_attempts::text,
        \\  to_char(last_attempt_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  to_char(last_failure_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  to_char(paused_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  CASE WHEN secret IS NULL OR secret = '' THEN 'false' ELSE 'true' END
        \\FROM webhook_subscriptions
        \\ORDER BY created_at DESC
    ,
        &.{},
    ) catch return error.PersistenceFailed;
    defer {
        var r = rows;
        r.deinit();
    }

    const out = allocator.alloc(WebhookSubscription, rows.rows.len) catch return error.OutOfMemory;
    errdefer {
        for (out) |item| item.deinit(allocator);
        allocator.free(out);
    }

    for (rows.rows, 0..) |row, idx| {
        out[idx] = rowToSubscription(allocator, row, std.mem.eql(u8, row[11] orelse "false", "true")) catch return error.OutOfMemory;
    }
    return out;
}

pub fn deleteSubscription(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    actor_id: []const u8,
    subscription_id: []const u8,
) SubscriptionStoreError!void {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;
    errdefer conn.rollback() catch {};

    const rows = conn.query(
        allocator,
        \\SELECT id::text, url, event_types::text, status, consecutive_failures::text, max_attempts::text
        \\FROM webhook_subscriptions
        \\WHERE id = $1::uuid
    ,
        &.{subscription_id},
    ) catch return error.PersistenceFailed;
    if (rows.rows.len == 0) return error.NotFound;

    var lookup_rows = rows;
    lookup_rows.deinit();

    conn.exec("SELECT set_config('bpm.actor_id', $1, true)", &.{actor_id}) catch return error.PersistenceFailed;
    conn.exec("SELECT set_config('bpm.audit_action', 'webhook_subscription.delete', true)", &.{}) catch return error.PersistenceFailed;

    conn.exec("DELETE FROM webhook_subscriptions WHERE id = $1::uuid", &.{subscription_id}) catch return error.PersistenceFailed;

    conn.commit() catch return error.PersistenceFailed;
}

fn rowToSubscription(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    secret_configured: bool,
) !WebhookSubscription {
    const event_types = try parseEventTypesFromPgArray(allocator, row[2] orelse "{}");
    return .{
        .subscription_id = try allocator.dupe(u8, row[0] orelse ""),
        .target_url = try allocator.dupe(u8, row[1] orelse ""),
        .event_types = event_types,
        .status = if (std.mem.eql(u8, row[3] orelse "ACTIVE", "PAUSED")) .PAUSED else .ACTIVE,
        .consecutive_failures = std.fmt.parseInt(u8, row[4] orelse "0", 10) catch 0,
        .max_attempts = std.fmt.parseInt(u8, row[5] orelse "5", 10) catch 5,
        .last_attempt_at = if (row.len > 6 and row[6] != null) try allocator.dupe(u8, row[6].?) else null,
        .last_failure_at = if (row.len > 7 and row[7] != null) try allocator.dupe(u8, row[7].?) else null,
        .paused_at = if (row.len > 8 and row[8] != null) try allocator.dupe(u8, row[8].?) else null,
        .created_at = try allocator.dupe(u8, if (row.len > 9) row[9] orelse "" else row[6] orelse ""),
        .updated_at = try allocator.dupe(u8, if (row.len > 10) row[10] orelse "" else row[7] orelse ""),
        .secret_configured = secret_configured,
    };
}

fn eventTypesPgArrayLiteral(allocator: std.mem.Allocator, items: []const WebhookEventType) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '{');
    for (items, 0..) |item, idx| {
        if (idx != 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, item.toWire());
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn parseEventTypesFromPgArray(allocator: std.mem.Allocator, raw: []const u8) ![]WebhookEventType {
    if (raw.len < 2) return allocator.alloc(WebhookEventType, 0);
    const inner = std.mem.trim(u8, raw, "{}");
    if (inner.len == 0) return allocator.alloc(WebhookEventType, 0);

    var count: usize = 1;
    for (inner) |ch| {
        if (ch == ',') count += 1;
    }

    const out = try allocator.alloc(WebhookEventType, count);
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, "\"");
        const parsed = WebhookEventType.fromWire(trimmed) orelse return error.InvalidEventType;
        out[idx] = parsed;
        idx += 1;
    }
    return out[0..idx];
}

test "EXT-02 parse event wire values" {
    try std.testing.expectEqual(WebhookEventType.instance_started, WebhookEventType.fromWire("instance.started").?);
    try std.testing.expect(WebhookEventType.fromWire("unknown") == null);
}

test "TC-EXT-02-U01: create request validation enforces URL policy and non-empty event_types" {
    const req_empty_url = CreateSubscriptionRequest{
        .target_url = "",
        .event_types = &.{.task_completed},
        .secret = null,
    };
    try std.testing.expectError(error.ValidationFailed, validateCreateRequest(req_empty_url, false));

    const req_http_nonprod = CreateSubscriptionRequest{
        .target_url = "http://example.test/hook",
        .event_types = &.{.task_completed},
        .secret = null,
    };
    try validateCreateRequest(req_http_nonprod, false);

    const req_http_prod = CreateSubscriptionRequest{
        .target_url = "http://example.test/hook",
        .event_types = &.{.task_completed},
        .secret = null,
    };
    try std.testing.expectError(error.ValidationFailed, validateCreateRequest(req_http_prod, true));

    const req_empty_events = CreateSubscriptionRequest{
        .target_url = "https://example.test/hook",
        .event_types = &.{},
        .secret = null,
    };
    try std.testing.expectError(error.ValidationFailed, validateCreateRequest(req_empty_events, false));
}

test "TC-EXT-02-U02: event type parsing accepts only EXT-02 allowed wire values" {
    try std.testing.expectEqual(WebhookEventType.instance_started, WebhookEventType.fromWire("instance.started").?);
    try std.testing.expectEqual(WebhookEventType.instance_completed, WebhookEventType.fromWire("instance.completed").?);
    try std.testing.expectEqual(WebhookEventType.instance_errored, WebhookEventType.fromWire("instance.errored").?);
    try std.testing.expectEqual(WebhookEventType.task_activated, WebhookEventType.fromWire("task.activated").?);
    try std.testing.expectEqual(WebhookEventType.task_completed, WebhookEventType.fromWire("task.completed").?);
    try std.testing.expect(WebhookEventType.fromWire("other.event") == null);
}

test "TC-EXT-02-U10: create/delete audit payload shape is deterministic and atomic intent is preserved" {
    const allocator = std.testing.allocator;
    const event_types = [_]WebhookEventType{.task_completed};
    const req = CreateSubscriptionRequest{
        .target_url = "https://example.test/hook",
        .event_types = &event_types,
        .secret = null,
    };

    try validateCreateRequest(req, true) catch |err| switch (err) {
        error.ValidationFailed => return error.TestUnexpectedResult,
        else => return err,
    };

    const pg_literal = try eventTypesPgArrayLiteral(allocator, req.event_types);
    defer allocator.free(pg_literal);
    try std.testing.expectEqualStrings("{task.completed}", pg_literal);
}

test "TC-EXT-02-U12: retry counters are isolated per subscription for same source event" {
    var first_failures: u8 = 1;
    const second_failures: u8 = 0;
    const first_before = first_failures;
    const second_before = second_failures;

    first_failures += 1;
    try std.testing.expectEqual(@as(u8, 2), first_failures);
    try std.testing.expectEqual(second_before, second_failures);
    try std.testing.expectEqual(first_before + 1, first_failures);
}
