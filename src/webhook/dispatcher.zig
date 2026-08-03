const std = @import("std");
const db = @import("pool");
const sub_store = @import("subscription_store.zig");
const signing = @import("signing.zig");
const alerts = @import("../obs/alerts.zig");
const secrets = @import("../secrets/mod.zig");

pub const WebhookEnvelope = struct {
    event_type: sub_store.WebhookEventType,
    instance_id: []const u8,
    timestamp: []const u8,
    payload_json: []const u8,
    trace_id: []const u8,
};

pub const DispatchError = error{
    PoolExhausted,
    InvalidSubscription,
    RetryStateWriteFailed,
    PauseTransitionFailed,
    AlertEmitFailed,
    DeliveryHttpNon2xx,
    DeliveryTransportError,
    OutOfMemory,
    PersistenceFailed,
};

// ---------------------------------------------------------------------------
// ISS-205: Back-off ladder constants
// ---------------------------------------------------------------------------
// attempt 1 → 5 000 ms
// attempt 2 → 30 000 ms  (30s)
// attempt 3 → 120 000 ms (2 min)
// attempt 4 → 600 000 ms (10 min)
// attempt 5 → 1 800 000 ms (30 min)
pub const OUTBOX_BACKOFF_MS = [_]u32{ 5_000, 30_000, 120_000, 600_000, 1_800_000 };
pub const OUTBOX_MAX_ATTEMPTS: u8 = 5;

// ---------------------------------------------------------------------------
// ISS-205: insertWebhookDeliveriesInTx — transactional outbox insert
// ---------------------------------------------------------------------------
// Must be called INSIDE an open transaction on `conn`. Inserts one
// webhook_deliveries row per matching active subscription, with
// next_attempt_at = NOW() + 5 seconds (first backoff slot).
//
// Security: all values bound as $N parameters; no SQL string interpolation.

pub const OutboxInsertError = error{
    PersistenceFailed,
    OutOfMemory,
};

pub fn insertWebhookDeliveriesInTx(
    allocator: std.mem.Allocator,
    conn: anytype, // *db.Conn (open transaction from caller)
    event_type: sub_store.WebhookEventType,
    instance_id: []const u8,
    event_id: []const u8,
    trace_id: []const u8,
    payload_json: []const u8,
) OutboxInsertError!u32 {
    const event_type_str = event_type.toWire();

    const subs = conn.query(
        allocator,
        \\SELECT id::text
        \\FROM webhook_subscriptions
        \\WHERE status = 'ACTIVE'
        \\  AND is_active = true
        \\  AND (event_types IS NULL OR array_length(event_types, 1) = 0 OR $1 = ANY(event_types))
    ,
        &.{event_type_str},
    ) catch return error.PersistenceFailed;
    defer {
        var r = subs;
        r.deinit();
    }

    var inserted: u32 = 0;
    for (subs.rows) |row| {
        const subscription_id = row[0] orelse continue;
        conn.exec(
            \\INSERT INTO webhook_deliveries
            \\  (subscription_id, event_id, status, attempt_count, max_attempts,
            \\   next_attempt_at, event_type, instance_id, payload_json, trace_id,
            \\   created_at, updated_at)
            \\VALUES
            \\  ($1::uuid, NULLIF($2, '')::uuid, 'PENDING', 0, 5,
            \\   NOW() + '5 seconds'::interval,
            \\   $3, NULLIF($4, '')::uuid, $5::jsonb, $6,
            \\   NOW(), NOW())
        ,
            &.{ subscription_id, event_id, event_type_str, instance_id, payload_json, trace_id },
        ) catch return error.PersistenceFailed;
        inserted += 1;
    }

    return inserted;
}

// ---------------------------------------------------------------------------
// ISS-205: sweepOrphanedDeliveries — startup sweep to drain orphans
// ---------------------------------------------------------------------------
// Runs at process startup (before entering the periodic poll loop) to drain
// any webhook_deliveries rows that were left pending by a prior crashed process.
// Uses FOR UPDATE SKIP LOCKED so concurrent workers don't double-process.

pub fn sweepOrphanedDeliveries(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
) DispatchError!void {
    return dispatchDueWebhookAttempts(allocator, pool);
}

pub fn computeRetryDelayMs(attempt: u8, base_ms: u32, cap_ms: u32) u32 {
    if (base_ms == 0) return 0;
    if (attempt <= 1) return @min(base_ms, cap_ms);

    var delay = @as(u64, base_ms);
    var idx: u8 = 1;
    while (idx < attempt) : (idx += 1) {
        delay *= 2;
        if (delay >= cap_ms) break;
    }
    return @intCast(@min(delay, @as(u64, cap_ms)));
}

pub fn shouldPauseAfterFailure(next_attempt: u8, max_attempts: u8) bool {
    return next_attempt >= max_attempts;
}

pub fn enqueueDeliveryAttempts(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    envelope: WebhookEnvelope,
) DispatchError!u32 {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;
    errdefer conn.rollback() catch {};

    const payload = buildDispatchBodyJson(allocator, envelope) catch return error.OutOfMemory;
    defer allocator.free(payload);

    const event_type = envelope.event_type.toWire();
    const subs = conn.query(
        allocator,
        \\SELECT id::text
        \\FROM webhook_subscriptions
        \\WHERE status = 'ACTIVE'
        \\  AND is_active = true
        \\  AND (event_types IS NULL OR array_length(event_types, 1) = 0 OR $1 = ANY(event_types))
    ,
        &.{event_type},
    ) catch return error.PersistenceFailed;
    defer {
        var r = subs;
        r.deinit();
    }

    var inserted: u32 = 0;
    for (subs.rows) |row| {
        const subscription_id = row[0] orelse continue;
        conn.exec(
            \\INSERT INTO webhook_deliveries
            \\  (subscription_id, status, attempt_count, max_attempts, next_attempt_at, event_type, instance_id, payload_json, trace_id, created_at, updated_at)
            \\VALUES
            \\  ($1::uuid, 'PENDING', 0, 5, NOW(), $2, NULLIF($3, '')::uuid, $4::jsonb, $5, NOW(), NOW())
        ,
            &.{ subscription_id, event_type, envelope.instance_id, payload, envelope.trace_id },
        ) catch return error.PersistenceFailed;
        inserted += 1;
    }

    conn.commit() catch return error.PersistenceFailed;
    return inserted;
}

pub fn dispatchDueWebhookAttempts(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
) DispatchError!void {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const due = conn.query(
        allocator,
        \\SELECT
        \\  d.id::text,
        \\  d.subscription_id::text,
        \\  COALESCE(d.payload_json::text, '{}'),
        \\  COALESCE(d.trace_id, ''),
        \\  COALESCE(d.event_type, ''),
        \\  d.attempt_count::text,
        \\  d.max_attempts::text,
        \\  s.url,
        \\  COALESCE(s.secret_ref, '')
        \\FROM webhook_deliveries d
        \\JOIN webhook_subscriptions s ON s.id = d.subscription_id
        \\WHERE d.status IN ('PENDING', 'FAILED')
        \\  AND d.next_attempt_at <= NOW()
        \\  AND s.status = 'ACTIVE'
        \\ORDER BY d.next_attempt_at ASC
        \\LIMIT 50
        \\FOR UPDATE OF d SKIP LOCKED
    ,
        &.{},
    ) catch return error.PersistenceFailed;
    defer {
        var r = due;
        r.deinit();
    }

    for (due.rows) |row| {
        try dispatchOne(allocator, pool, row);
    }
}

pub fn dispatchDueWebhookAttemptsForTrace(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    trace_id: []const u8,
) DispatchError!void {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const due = conn.query(
        allocator,
        \\SELECT
        \\  d.id::text,
        \\  d.subscription_id::text,
        \\  COALESCE(d.payload_json::text, '{}'),
        \\  COALESCE(d.trace_id, ''),
        \\  COALESCE(d.event_type, ''),
        \\  d.attempt_count::text,
        \\  d.max_attempts::text,
        \\  s.url,
        \\  COALESCE(s.secret_ref, '')
        \\FROM webhook_deliveries d
        \\JOIN webhook_subscriptions s ON s.id = d.subscription_id
        \\WHERE d.status IN ('PENDING', 'FAILED')
        \\  AND d.next_attempt_at <= NOW()
        \\  AND s.status = 'ACTIVE'
        \\  AND d.trace_id = $1
        \\ORDER BY d.next_attempt_at ASC
        \\LIMIT 50
    ,
        &.{trace_id},
    ) catch return error.PersistenceFailed;
    defer {
        var r = due;
        r.deinit();
    }

    for (due.rows) |row| {
        try dispatchOne(allocator, pool, row);
    }
}

pub fn dispatchDueWebhookAttemptsForSubscription(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    subscription_id: []const u8,
) DispatchError!void {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const due = conn.query(
        allocator,
        \\SELECT
        \\  d.id::text,
        \\  d.subscription_id::text,
        \\  COALESCE(d.payload_json::text, '{}'),
        \\  COALESCE(d.trace_id, ''),
        \\  COALESCE(d.event_type, ''),
        \\  d.attempt_count::text,
        \\  d.max_attempts::text,
        \\  s.url,
        \\  COALESCE(s.secret_ref, '')
        \\FROM webhook_deliveries d
        \\JOIN webhook_subscriptions s ON s.id = d.subscription_id
        \\WHERE d.status IN ('PENDING', 'FAILED')
        \\  AND d.next_attempt_at <= NOW()
        \\  AND s.status = 'ACTIVE'
        \\  AND d.subscription_id = $1::uuid
        \\ORDER BY d.next_attempt_at ASC
        \\LIMIT 50
    ,
        &.{subscription_id},
    ) catch return error.PersistenceFailed;
    defer {
        var r = due;
        r.deinit();
    }

    for (due.rows) |row| {
        try dispatchOne(allocator, pool, row);
    }
}

fn dispatchOne(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    row: []?[]u8,
) DispatchError!void {
    const delivery_id = row[0] orelse return error.InvalidSubscription;
    const subscription_id = row[1] orelse return error.InvalidSubscription;
    const payload = row[2] orelse "{}";
    const trace_id = row[3] orelse "";
    const event_type = row[4] orelse "";
    const prev_attempt = std.fmt.parseInt(u8, row[5] orelse "0", 10) catch 0;
    const max_attempts = std.fmt.parseInt(u8, row[6] orelse "5", 10) catch 5;
    const url = row[7] orelse return error.InvalidSubscription;
    const secret_ref = row[8] orelse "";

    var resolved_secret: ?[]u8 = null;
    defer if (resolved_secret) |value| {
        std.crypto.secureZero(u8, value);
        allocator.free(value);
    };

    const next_attempt: u8 = prev_attempt + 1;
    const send_result = blk: {
        var secret_value: []const u8 = "";
        if (secret_ref.len > 0) {
            resolved_secret = resolveWebhookSecret(allocator, pool, secret_ref) catch break :blk null;
            secret_value = resolved_secret.?;
        }
        break :blk sendWebhook(
            allocator,
            url,
            payload,
            event_type,
            delivery_id,
            next_attempt,
            trace_id,
            secret_value,
        ) catch null;
    };

    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;
    errdefer conn.rollback() catch {};

    if (send_result) |status_code| {
        if (status_code >= 200 and status_code < 300) {
            const status_txt = std.fmt.allocPrint(allocator, "{d}", .{status_code}) catch return error.OutOfMemory;
            defer allocator.free(status_txt);
            const next_attempt_txt = std.fmt.allocPrint(allocator, "{d}", .{next_attempt}) catch return error.OutOfMemory;
            defer allocator.free(next_attempt_txt);
            conn.exec(
                \\UPDATE webhook_deliveries
                \\SET status = 'DELIVERED',
                \\    attempt_count = $2::int,
                \\    last_attempt_at = NOW(),
                \\    delivered_at = NOW(),
                \\    last_http_status = $3::int,
                \\    last_error = NULL,
                \\    updated_at = NOW()
                \\WHERE id = $1::uuid
            ,
                &.{ delivery_id, next_attempt_txt, status_txt },
            ) catch return error.RetryStateWriteFailed;

            conn.exec(
                \\UPDATE webhook_subscriptions
                \\SET consecutive_failures = 0,
                \\    last_attempt_at = NOW(),
                \\    updated_at = NOW()
                \\WHERE id = $1::uuid
            ,
                &.{subscription_id},
            ) catch return error.RetryStateWriteFailed;

            conn.commit() catch return error.PersistenceFailed;
            return;
        }
    }

    // Failure path: non-2xx or transport error.
    const should_pause = shouldPauseAfterFailure(next_attempt, max_attempts);
    const next_attempt_txt = std.fmt.allocPrint(allocator, "{d}", .{next_attempt}) catch return error.OutOfMemory;
    defer allocator.free(next_attempt_txt);

    if (should_pause) {
        conn.exec(
            \\UPDATE webhook_deliveries
            \\SET status = 'FAILED',
            \\    attempt_count = $2::int,
            \\    last_attempt_at = NOW(),
            \\    last_error = 'delivery_failed',
            \\    updated_at = NOW()
            \\WHERE id = $1::uuid
        ,
            &.{ delivery_id, next_attempt_txt },
        ) catch return error.RetryStateWriteFailed;

        conn.exec(
            \\UPDATE webhook_subscriptions
            \\SET consecutive_failures = consecutive_failures + 1,
            \\    status = 'PAUSED',
            \\    paused_at = NOW(),
            \\    last_attempt_at = NOW(),
            \\    last_failure_at = NOW(),
            \\    updated_at = NOW()
            \\WHERE id = $1::uuid
        ,
            &.{subscription_id},
        ) catch return error.PauseTransitionFailed;
    } else {
        // ISS-205: use the prescribed back-off ladder (5s, 30s, 2m, 10m, 30m).
        const ladder_idx = if (next_attempt > 0 and next_attempt <= OUTBOX_BACKOFF_MS.len)
            next_attempt - 1
        else
            OUTBOX_BACKOFF_MS.len - 1;
        const delay_ms = OUTBOX_BACKOFF_MS[ladder_idx];
        const delay_txt = std.fmt.allocPrint(allocator, "{d}", .{delay_ms}) catch return error.OutOfMemory;
        defer allocator.free(delay_txt);

        conn.exec(
            \\UPDATE webhook_deliveries
            \\SET status = 'FAILED',
            \\    attempt_count = $2::int,
            \\    last_attempt_at = NOW(),
            \\    last_error = 'delivery_failed',
            \\    next_attempt_at = NOW() + ($3::text || ' milliseconds')::interval,
            \\    updated_at = NOW()
            \\WHERE id = $1::uuid
        ,
            &.{ delivery_id, next_attempt_txt, delay_txt },
        ) catch return error.RetryStateWriteFailed;

        conn.exec(
            \\UPDATE webhook_subscriptions
            \\SET consecutive_failures = consecutive_failures + 1,
            \\    last_attempt_at = NOW(),
            \\    last_failure_at = NOW(),
            \\    updated_at = NOW()
            \\WHERE id = $1::uuid
        ,
            &.{subscription_id},
        ) catch return error.RetryStateWriteFailed;
    }

    conn.commit() catch return error.PersistenceFailed;

    if (should_pause) {
        emitWebhookSubscriptionPausedAlert(allocator, subscription_id, url) catch return error.AlertEmitFailed;
    }
}

fn emitWebhookSubscriptionPausedAlert(
    allocator: std.mem.Allocator,
    subscription_id: []const u8,
    target_url: []const u8,
) !void {
    var cfg = alerts.loadAlertingConfigFromEnv(allocator) catch return;
    defer cfg.deinit(allocator);
    if (!cfg.enabled) return;

    const event = try alerts.buildWebhookSubscriptionPausedEvent(
        allocator,
        "webhook-dispatcher",
        "",
        subscription_id,
        target_url,
        5,
        "delivery failed 5 consecutive attempts",
        currentMicrosecondTimestamp(),
    );
    defer event.deinit(allocator);

    const adapter = alerts.DeliveryAdapter{
        .context = null,
        .postFn = sendAlertHook,
    };
    for (cfg.hooks) |hook| {
        if (!hook.enabled) continue;
        _ = alerts.dispatchAlertEvent(allocator, adapter, event, hook) catch {};
    }
}

fn sendAlertHook(_: ?*anyopaque, request: alerts.DeliveryRequest) alerts.SendError!u16 {
    var client: std.http.Client = .{
        .allocator = std.heap.smp_allocator,
        .io = std.Options.debug_io,
    };
    defer client.deinit();

    var response_body = std.ArrayList(u8).empty;
    var response_writer = std.Io.Writer.Allocating.fromArrayList(std.heap.smp_allocator, &response_body);
    defer response_writer.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-bpm-correlation-id", .value = request.correlation_id },
        .{ .name = "x-bpm-alert-id", .value = request.alert_id },
    };

    const result = client.fetch(.{
        .location = .{ .url = request.url },
        .method = .POST,
        .payload = request.payload_json,
        .response_writer = &response_writer.writer,
        .extra_headers = &headers,
    }) catch return error.Transport;

    return @intFromEnum(result.status);
}

fn resolveWebhookSecret(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    secret_ref: []const u8,
) ![]u8 {
    var secret_store = try secrets.Store.init(allocator, pool, .{
        .wrapping_key_ref = "local:master",
        .wrapping_key_version = "v1",
        .master_key_hex = "0000000000000000000000000000000000000000000000000000000000000000",
    });
    const resolved = try secret_store.resolveSecret(allocator, .{
        .tenant_id = "default",
        .secret_ref = secret_ref,
        .consumer = .webhook_dispatcher,
    });
    defer resolved.deinit(allocator);
    return allocator.dupe(u8, resolved.value);
}

fn sendWebhook(
    allocator: std.mem.Allocator,
    url: []const u8,
    payload_json: []const u8,
    event_type: []const u8,
    delivery_id: []const u8,
    attempt: u8,
    trace_id: []const u8,
    secret: []const u8,
) !u16 {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Options.debug_io,
    };
    defer client.deinit();

    const attempt_txt = try std.fmt.allocPrint(allocator, "{d}", .{attempt});
    defer allocator.free(attempt_txt);

    var header_list: std.ArrayList(std.http.Header) = .empty;
    defer header_list.deinit(allocator);
    try header_list.append(allocator, .{ .name = "content-type", .value = "application/json" });
    try header_list.append(allocator, .{ .name = "x-bpm-event-type", .value = event_type });
    try header_list.append(allocator, .{ .name = "x-bpm-delivery-id", .value = delivery_id });
    try header_list.append(allocator, .{ .name = "x-bpm-attempt", .value = attempt_txt });
    try header_list.append(allocator, .{ .name = "x-trace-id", .value = trace_id });

    var signature_header_value: ?[]u8 = null;
    defer if (signature_header_value) |v| allocator.free(v);
    if (secret.len > 0) {
        signature_header_value = try signing.buildSignatureHeader(allocator, secret, payload_json);
        try header_list.append(allocator, .{ .name = "x-bpm-signature", .value = signature_header_value.? });
    }

    var response_body = std.ArrayList(u8).empty;
    var response_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &response_body);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload_json,
        .response_writer = &response_writer.writer,
        .extra_headers = header_list.items,
    }) catch return error.Transport;
    return @intFromEnum(result.status);
}

fn buildDispatchBodyJson(allocator: std.mem.Allocator, envelope: WebhookEnvelope) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const event_json = try std.json.Stringify.valueAlloc(allocator, .{ .string = envelope.event_type.toWire() }, .{});
    defer allocator.free(event_json);
    const instance_json = try std.json.Stringify.valueAlloc(allocator, .{ .string = envelope.instance_id }, .{});
    defer allocator.free(instance_json);
    const ts_json = try std.json.Stringify.valueAlloc(allocator, .{ .string = envelope.timestamp }, .{});
    defer allocator.free(ts_json);

    try out.appendSlice(allocator, "{");
    try out.appendSlice(allocator, "\"event_type\":");
    try out.appendSlice(allocator, event_json);
    try out.appendSlice(allocator, ",\"instance_id\":");
    try out.appendSlice(allocator, instance_json);
    try out.appendSlice(allocator, ",\"timestamp\":");
    try out.appendSlice(allocator, ts_json);
    try out.appendSlice(allocator, ",\"payload\":");
    try out.appendSlice(allocator, envelope.payload_json);
    try out.appendSlice(allocator, "}");

    return out.toOwnedSlice(allocator);
}

fn currentMicrosecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    }

    var ts: std.posix.timespec = undefined;
    std.posix.clock_gettime(std.posix.CLOCK.REALTIME, &ts) catch return 0;
    return ts.tv_sec * 1_000_000 + @divTrunc(ts.tv_nsec, 1_000);
}

test "EXT-02 retry backoff is exponential and capped" {
    try std.testing.expectEqual(@as(u32, 1000), computeRetryDelayMs(1, 1000, 30000));
    try std.testing.expectEqual(@as(u32, 2000), computeRetryDelayMs(2, 1000, 30000));
    try std.testing.expectEqual(@as(u32, 4000), computeRetryDelayMs(3, 1000, 30000));
    try std.testing.expectEqual(@as(u32, 30000), computeRetryDelayMs(10, 1000, 30000));
}

const CaptureServer = struct {
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

    fn start(self: *CaptureServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        try self.waitReady();
    }

    fn waitReady(self: *CaptureServer) !void {
        const allocator = std.testing.allocator;
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

    fn join(self: *CaptureServer) void {
        if (self.thread) |t| {
            self.requestStop();
            t.join();
            self.thread = null;
        }
    }

    fn requestStop(self: *CaptureServer) void {
        const allocator = std.testing.allocator;
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

    fn run(self: *CaptureServer) void {
        const listen_address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
        var server = blk: {
            var bind_attempt: usize = 0;
            while (bind_attempt < 250) : (bind_attempt += 1) {
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

test "TC-EXT-02-U04 and TC-EXT-02-U05: dispatch body and headers are deterministic" {
    const allocator = std.testing.allocator;
    var server = CaptureServer{
        .port = 19201,
        .response_status = 204,
        .response_content_type = "application/json",
        .response_body = "{}",
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const body = try buildDispatchBodyJson(allocator, .{
        .event_type = .task_completed,
        .instance_id = "instance-123",
        .timestamp = "2026-05-25T12:00:00Z",
        .payload_json = "{\"payload\":true}",
        .trace_id = "trace-123",
    });
    defer allocator.free(body);
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"event_type\":\"task.completed\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"instance_id\":\"instance-123\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"timestamp\":\"2026-05-25T12:00:00Z\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, body, 1, "\"payload\":{\"payload\":true}"));

    const status = try sendWebhook(
        allocator,
        "http://127.0.0.1:19201/hook",
        "{\"payload\":true}",
        "task.completed",
        "delivery-123",
        3,
        "trace-123",
        "",
    );
    try std.testing.expectEqual(@as(u16, 204), status);
    try std.testing.expectEqualStrings("task.completed", server.event_type[0..server.event_type_len]);
    try std.testing.expectEqualStrings("3", server.attempt[0..server.attempt_len]);
    try std.testing.expectEqualStrings("trace-123", server.trace_id[0..server.trace_id_len]);
}

test "TC-EXT-02-U07: signature header is omitted when no secret is configured" {
    const allocator = std.testing.allocator;
    var unsigned_server = CaptureServer{
        .port = 19202,
        .response_status = 200,
        .response_content_type = "application/json",
        .response_body = "{}",
        .max_requests = 1,
    };
    try unsigned_server.start();
    defer unsigned_server.join();

    _ = try sendWebhook(
        allocator,
        "http://127.0.0.1:19202/hook",
        "{\"payload\":true}",
        "task.completed",
        "delivery-456",
        1,
        "trace-456",
        "",
    );
    try std.testing.expect(!unsigned_server.signature_seen);

    var signed_server = CaptureServer{
        .port = 19203,
        .response_status = 200,
        .response_content_type = "application/json",
        .response_body = "{}",
        .max_requests = 1,
    };
    try signed_server.start();
    defer signed_server.join();

    _ = try sendWebhook(
        allocator,
        "http://127.0.0.1:19203/hook",
        "{\"payload\":true}",
        "task.completed",
        "delivery-457",
        1,
        "trace-457",
        "secret-key",
    );
    try std.testing.expect(signed_server.signature_seen);
}

test "TC-EXT-02-U09: failure classification triggers pause at terminal attempt budget" {
    try std.testing.expect(!shouldPauseAfterFailure(1, 5));
    try std.testing.expect(!shouldPauseAfterFailure(4, 5));
    try std.testing.expect(shouldPauseAfterFailure(5, 5));
}

test "TC-EXT-02-U11: HTTP 2xx with invalid response body is still treated as success" {
    const allocator = std.testing.allocator;
    var server = CaptureServer{
        .port = 19204,
        .response_status = 200,
        .response_content_type = "text/plain",
        .response_body = "not-json",
        .max_requests = 1,
    };
    try server.start();
    defer server.join();

    const status = try sendWebhook(
        allocator,
        "http://127.0.0.1:19204/hook",
        "{\"payload\":true}",
        "task.completed",
        "delivery-999",
        1,
        "trace-999",
        "",
    );
    try std.testing.expectEqual(@as(u16, 200), status);
}
