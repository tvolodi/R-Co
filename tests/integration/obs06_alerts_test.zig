const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;
const obs_alerts = bpm.obs_alerts;

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
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

fn cleanupDlqBySourceRef(conn: *bpm.pool.Conn, source_ref: []const u8) void {
    conn.exec("DELETE FROM dead_letter_queue WHERE source_ref = $1", &.{source_ref}) catch {};
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

fn insertDlqRow(
    conn: *bpm.pool.Conn,
    id: []const u8,
    source_ref: []const u8,
    status: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO dead_letter_queue (
        \\  id, entry_type, instance_id, reason, error_detail,
        \\  retry_count, max_retries, status,
        \\  created_at, updated_at,
        \\  item_type, retry_limit,
        \\  original_payload, error_chain, processor_metadata,
        \\  first_failed_at, last_failed_at, source_ref
        \\)
        \\VALUES (
        \\  $1::uuid,
        \\  'timer_failed',
        \\  NULL,
        \\  'retry limit exhausted',
        \\  '{"code":"FAILED"}'::jsonb,
        \\  3,
        \\  3,
        \\  $3,
        \\  NOW(),
        \\  NOW(),
        \\  'TIMER',
        \\  3,
        \\  '{"payload":"value"}'::jsonb,
        \\  '[{"code":"FAILED","message":"x"}]'::jsonb,
        \\  '{"source_module":"obs06.test"}'::jsonb,
        \\  NOW(),
        \\  NOW(),
        \\  $2
        \\)
        \\ON CONFLICT (id) DO UPDATE SET
        \\  status = EXCLUDED.status,
        \\  source_ref = EXCLUDED.source_ref,
        \\  updated_at = NOW()
    ,
        &.{ id, source_ref, status },
    );
}

test "TC-OBS-06-INT-01: ERROR-duration emits per-instance alerts with one-shot and re-arm" {
    var state = obs_alerts.AlertStateStore.init(testing.allocator);
    defer state.deinit();

    const now_us: i64 = 1_717_000_000_000_000;
    const snapshots = [_]obs_alerts.ErrorInstanceSnapshot{
        .{ .instance_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", .definition_id = "11111111-1111-1111-1111-111111111111", .error_reason = "timeout", .error_since_us = now_us - (11 * 60 * 1_000_000) },
        .{ .instance_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", .definition_id = "22222222-2222-2222-2222-222222222222", .error_reason = "validation", .error_since_us = now_us - (20 * 60 * 1_000_000) },
    };

    const first = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = now_us,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-1",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = snapshots[0..],
        .dlq_depth = 0,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (first) |event| event.deinit(testing.allocator);
        testing.allocator.free(first);
    }

    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expect(first[0].alert_type == .instance_error_stuck);
    try testing.expect(first[1].alert_type == .instance_error_stuck);
    var saw_timeout_instance = false;
    var saw_timeout_correlation = false;
    for (first) |event| {
        if (std.mem.indexOf(u8, event.payload_json, "\"string\":\"instance_id\"}:{\"string\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\"") != null and
            std.mem.indexOf(u8, event.payload_json, "\"string\":\"error_reason\"}:{\"string\":\"timeout\"") != null)
        {
            saw_timeout_instance = true;
        }
        if (std.mem.indexOf(u8, event.correlation_id, "obs06:instance_error_stuck:instance:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa:error_stuck:") != null) {
            saw_timeout_correlation = true;
        }
    }
    try testing.expect(saw_timeout_instance);
    try testing.expect(saw_timeout_correlation);

    const duplicate_poll = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = now_us + 1_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-1",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = snapshots[0..],
        .dlq_depth = 0,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer testing.allocator.free(duplicate_poll);
    try testing.expectEqual(@as(usize, 0), duplicate_poll.len);

    const recovered = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = now_us + 2_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-1",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = &.{},
        .dlq_depth = 0,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer testing.allocator.free(recovered);
    try testing.expectEqual(@as(usize, 0), recovered.len);

    const returned_error = [_]obs_alerts.ErrorInstanceSnapshot{
        .{ .instance_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", .definition_id = "11111111-1111-1111-1111-111111111111", .error_reason = "timeout", .error_since_us = (now_us + 3_000_000) - (11 * 60 * 1_000_000) },
    };

    const refired = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = now_us + 3_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-1",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = returned_error[0..],
        .dlq_depth = 0,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (refired) |event| event.deinit(testing.allocator);
        testing.allocator.free(refired);
    }
    try testing.expectEqual(@as(usize, 1), refired.len);
    try testing.expect(refired[0].alert_type == .instance_error_stuck);
}

test "TC-OBS-06-INT-02: DLQ and scheduler lag crossing one-shot and re-arm semantics" {
    var state = obs_alerts.AlertStateStore.init(testing.allocator);
    defer state.deinit();

    const base: i64 = 1_717_000_100_000_000;
    const thresholds = obs_alerts.AlertThresholds{
        .error_stuck_minutes = 10,
        .dlq_depth_threshold = 100,
        .scheduler_lag_ms = 5000,
    };

    const initial = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = base,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-2",
        .thresholds = thresholds,
        .error_instances = &.{},
        .dlq_depth = 80,
        .scheduler_lag_ms = 4000,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer testing.allocator.free(initial);
    try testing.expectEqual(@as(usize, 0), initial.len);

    const crossed_up = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = base + 1_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-2",
        .thresholds = thresholds,
        .error_instances = &.{},
        .dlq_depth = 120,
        .scheduler_lag_ms = 6000,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (crossed_up) |event| event.deinit(testing.allocator);
        testing.allocator.free(crossed_up);
    }
    try testing.expectEqual(@as(usize, 2), crossed_up.len);

    const stay_above = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = base + 2_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-2",
        .thresholds = thresholds,
        .error_instances = &.{},
        .dlq_depth = 150,
        .scheduler_lag_ms = 9000,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer testing.allocator.free(stay_above);
    try testing.expectEqual(@as(usize, 0), stay_above.len);

    const recovered = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = base + 3_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-2",
        .thresholds = thresholds,
        .error_instances = &.{},
        .dlq_depth = 10,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer testing.allocator.free(recovered);
    try testing.expectEqual(@as(usize, 0), recovered.len);

    const crossed_again = try obs_alerts.evaluateAlertRules(testing.allocator, .{
        .now_us = base + 4_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-2",
        .thresholds = thresholds,
        .error_instances = &.{},
        .dlq_depth = 101,
        .scheduler_lag_ms = 5001,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (crossed_again) |event| event.deinit(testing.allocator);
        testing.allocator.free(crossed_again);
    }
    try testing.expectEqual(@as(usize, 2), crossed_again.len);
}

const DispatchMode = enum { status_500, timeout };

const DispatchContext = struct {
    mode: DispatchMode,
    attempts: u8 = 0,
    request_ids: [3][]const u8 = .{ "", "", "" },
    request_corrs: [3][]const u8 = .{ "", "", "" },
};

fn postAlwaysFails(context: ?*anyopaque, request: obs_alerts.DeliveryRequest) obs_alerts.SendError!u16 {
    const ctx: *DispatchContext = @ptrCast(@alignCast(context.?));
    const idx = ctx.attempts;
    if (idx < 3) {
        ctx.request_ids[idx] = request.alert_id;
        ctx.request_corrs[idx] = request.correlation_id;
    }
    ctx.attempts += 1;

    return switch (ctx.mode) {
        .status_500 => 500,
        .timeout => error.Timeout,
    };
}

fn makeOwnedEvent(allocator: std.mem.Allocator, correlation_id: []const u8) !obs_alerts.AlertEvent {
    return .{
        .hook_id = try allocator.dupe(u8, "ops-primary"),
        .trigger_key = try allocator.dupe(u8, "dlq:depth"),
        .trace_id = try allocator.dupe(u8, "trace-obs06-3"),
        .correlation_id = try allocator.dupe(u8, correlation_id),
        .payload_json = try allocator.dupe(u8, "{\"alert_type\":\"dlq_depth_threshold\"}"),
        .alert_type = .dlq_depth_threshold,
        .occurred_at_us = 1_717_000_200_000_000,
    };
}

test "TC-OBS-06-INT-03: dispatcher retries max 3 and terminates on repeated non-2xx" {
    const allocator = testing.allocator;
    var event = try makeOwnedEvent(allocator, "obs06:dlq_depth_threshold:dlq:depth:1717000200000");
    defer event.deinit(allocator);

    var ctx = DispatchContext{ .mode = .status_500 };
    const hook = obs_alerts.AlertHookConfig{
        .hook_id = "ops-primary",
        .enabled = true,
        .destination_url = "https://alerts.example.test/hook",
        .timeout_ms = 100,
        .auth_secret_ref = null,
        .retry_policy = .{ .max_attempts = 3, .base_backoff_ms = 0, .max_backoff_ms = 0, .multiplier = 2.0 },
    };

    const result = obs_alerts.dispatchAlertEvent(allocator, .{
        .context = &ctx,
        .postFn = postAlwaysFails,
    }, event, hook);

    try testing.expectError(error.TerminalDeliveryFailure, result);
    try testing.expectEqual(@as(u8, 3), ctx.attempts);
    try testing.expectEqualStrings(ctx.request_corrs[0], ctx.request_corrs[1]);
    try testing.expectEqualStrings(ctx.request_corrs[1], ctx.request_corrs[2]);
    try testing.expectEqualStrings(ctx.request_ids[0], ctx.request_ids[1]);
    try testing.expectEqualStrings(ctx.request_ids[1], ctx.request_ids[2]);
}

test "TC-OBS-06-INT-04: deterministic correlation and payload envelope fields" {
    const allocator = testing.allocator;
    var state = obs_alerts.AlertStateStore.init(allocator);
    defer state.deinit();

    const first = try obs_alerts.evaluateAlertRules(allocator, .{
        .now_us = 1_717_000_300_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-4",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = &.{},
        .dlq_depth = 50,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer allocator.free(first);

    const crossed = try obs_alerts.evaluateAlertRules(allocator, .{
        .now_us = 1_717_000_301_000_000,
        .hook_id = "ops-primary",
        .trace_id = "trace-obs06-4",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = &.{},
        .dlq_depth = 150,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (crossed) |event| event.deinit(allocator);
        allocator.free(crossed);
    }

    try testing.expectEqual(@as(usize, 1), crossed.len);
    try testing.expectEqualStrings("obs06:dlq_depth_threshold:dlq:depth:1717000301000", crossed[0].correlation_id);
    try testing.expect(std.mem.indexOf(u8, crossed[0].payload_json, "\"string\":\"alert_type\"}:{\"string\":\"dlq_depth_threshold\"") != null);
    try testing.expect(std.mem.indexOf(u8, crossed[0].payload_json, "\"string\":\"hook_id\"}:{\"string\":\"ops-primary\"") != null);
    try testing.expect(std.mem.indexOf(u8, crossed[0].payload_json, "\"string\":\"trace_id\"}:{\"string\":\"trace-obs06-4\"") != null);
}

test "TC-OBS-06-INT-05: DLQ depth query and trigger-state persistence are DB-visible" {
    const allocator = testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    cleanupDlqBySourceRef(conn, "obs06-depth-pending");
    cleanupDlqBySourceRef(conn, "obs06-depth-retrying");
    cleanupDlqBySourceRef(conn, "obs06-depth-discarded");
    defer cleanupDlqBySourceRef(conn, "obs06-depth-pending");
    defer cleanupDlqBySourceRef(conn, "obs06-depth-retrying");
    defer cleanupDlqBySourceRef(conn, "obs06-depth-discarded");

    const baseline_depth = try obs_alerts.readDlqDepth(allocator, &pool);

    try insertDlqRow(conn, "a1111111-1111-1111-1111-111111111111", "obs06-depth-pending", "pending");
    try insertDlqRow(conn, "b2222222-2222-2222-2222-222222222222", "obs06-depth-retrying", "retrying");
    try insertDlqRow(conn, "c3333333-3333-3333-3333-333333333333", "obs06-depth-discarded", "discarded");

    const depth = try obs_alerts.readDlqDepth(allocator, &pool);
    try testing.expectEqual(baseline_depth + 2, depth);

    try obs_alerts.persistThresholdState(allocator, &pool, "dlq:depth", false, 120);
    try obs_alerts.persistThresholdState(allocator, &pool, "dlq:depth", true, 5);

    const armed_text = try rowText(
        conn,
        allocator,
        "SELECT is_armed::text FROM obs_alert_trigger_state WHERE trigger_key = $1",
        &.{"dlq:depth"},
    );
    defer allocator.free(armed_text);

    const last_value_text = try rowText(
        conn,
        allocator,
        "SELECT last_sample_value::text FROM obs_alert_trigger_state WHERE trigger_key = $1",
        &.{"dlq:depth"},
    );
    defer allocator.free(last_value_text);

    try testing.expectEqualStrings("true", armed_text);
    try testing.expectEqualStrings("5", last_value_text);
}
