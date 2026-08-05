const std = @import("std");
const db = @import("pool");
const logger = @import("logger.zig");
const env = @import("env");

pub const AlertType = enum {
    instance_error_stuck,
    dlq_depth_threshold,
    scheduler_lag_threshold,
    webhook_subscription_paused,
};

pub const RetryPolicy = struct {
    max_attempts: u8 = 3,
    base_backoff_ms: u32 = 1000,
    max_backoff_ms: u32 = 30_000,
    multiplier: f32 = 2.0,
};

pub const AlertHookConfig = struct {
    hook_id: []const u8,
    enabled: bool,
    destination_url: []const u8,
    timeout_ms: u32,
    auth_secret_ref: ?[]const u8,
    retry_policy: RetryPolicy,
};

pub const AlertThresholds = struct {
    error_stuck_minutes: u32,
    dlq_depth_threshold: u32,
    scheduler_lag_ms: u32,
};

pub const ErrorInstanceSnapshot = struct {
    instance_id: []const u8,
    definition_id: []const u8,
    error_reason: []const u8,
    error_since_us: i64,
};

pub const AlertEvaluationInput = struct {
    now_us: i64,
    hook_id: []const u8,
    trace_id: []const u8,
    thresholds: AlertThresholds,
    error_instances: []const ErrorInstanceSnapshot,
    dlq_depth: u64,
    scheduler_lag_ms: u64,
    scheduler_poll_interval_ms: u64,
};

pub const AlertSource = union(enum) {
    instance_error_stuck: struct {
        instance_id: []const u8,
        definition_id: []const u8,
        error_reason: []const u8,
        error_since_us: i64,
        error_duration_minutes: i64,
    },
    dlq_depth_threshold: struct {
        threshold: u64,
        previous_depth: u64,
        current_depth: u64,
    },
    scheduler_lag_threshold: struct {
        threshold_ms: u64,
        previous_lag_ms: u64,
        current_lag_ms: u64,
        configured_poll_interval_ms: u64,
    },
    webhook_subscription_paused: struct {
        subscription_id: []const u8,
        target_url: []const u8,
        failure_count: u32,
        paused_at_us: i64,
        pause_reason: []const u8,
    },
};

pub const AlertEvent = struct {
    hook_id: []u8,
    trigger_key: []u8,
    trace_id: []u8,
    correlation_id: []u8,
    payload_json: []u8,
    alert_type: AlertType,
    occurred_at_us: i64,

    pub fn deinit(self: AlertEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.hook_id);
        allocator.free(self.trigger_key);
        allocator.free(self.trace_id);
        allocator.free(self.correlation_id);
        allocator.free(self.payload_json);
    }
};

pub const AlertStateStore = struct {
    allocator: std.mem.Allocator,
    threshold_states: std.StringHashMap(ThresholdState),

    pub fn init(allocator: std.mem.Allocator) AlertStateStore {
        return .{
            .allocator = allocator,
            .threshold_states = std.StringHashMap(ThresholdState).init(allocator),
        };
    }

    pub fn deinit(self: *AlertStateStore) void {
        var it = self.threshold_states.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.threshold_states.deinit();
    }

    fn getOrCreate(self: *AlertStateStore, trigger_key: []const u8) AlertError!*ThresholdState {
        if (self.threshold_states.getPtr(trigger_key)) |state| return state;

        const key_copy = self.allocator.dupe(u8, trigger_key) catch return error.OutOfMemory;
        self.threshold_states.put(key_copy, .{}) catch {
            self.allocator.free(key_copy);
            return error.OutOfMemory;
        };
        return self.threshold_states.getPtr(key_copy).?;
    }
};

const ThresholdState = struct {
    armed: bool = true,
    has_last_value: bool = false,
    last_value: u64 = 0,
};

pub const AlertingConfig = struct {
    enabled: bool,
    poll_interval_ms: u32,
    thresholds: AlertThresholds,
    hooks: []AlertHookConfig,

    pub fn deinit(self: AlertingConfig, allocator: std.mem.Allocator) void {
        for (self.hooks) |hook| {
            allocator.free(hook.hook_id);
            allocator.free(hook.destination_url);
            if (hook.auth_secret_ref) |secret_ref| allocator.free(secret_ref);
        }
        allocator.free(self.hooks);
    }
};

pub const AlertError = error{
    InvalidConfig,
    StateReadFailed,
    StateWriteFailed,
    PayloadBuildFailed,
    DeliveryFailed,
    DeliveryTimeout,
    TerminalDeliveryFailure,
    OutOfMemory,
};

pub const SendError = error{ Timeout, Transport };

pub const DeliveryRequest = struct {
    url: []const u8,
    timeout_ms: u32,
    payload_json: []const u8,
    correlation_id: []const u8,
    alert_id: []const u8,
};

pub const DeliveryAdapter = struct {
    context: ?*anyopaque,
    postFn: *const fn (context: ?*anyopaque, request: DeliveryRequest) SendError!u16,
};

pub fn computeSchedulerLagMs(configured_poll_interval_ms: u64, actual_poll_interval_ms: u64) u64 {
    if (actual_poll_interval_ms <= configured_poll_interval_ms) return 0;
    return actual_poll_interval_ms - configured_poll_interval_ms;
}

pub fn readDlqDepth(allocator: std.mem.Allocator, pool: *db.Pool) AlertError!u64 {
    const conn = pool.acquire() catch return error.StateReadFailed;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        "SELECT COUNT(*)::text FROM dead_letter_items WHERE status IN ('pending', 'retrying')",
        &.{},
    ) catch return error.StateReadFailed;
    if (row == null) return 0;

    const owned = row.?;
    defer {
        for (owned) |col| {
            if (col) |value| allocator.free(value);
        }
        allocator.free(owned);
    }

    return std.fmt.parseInt(u64, owned[0] orelse "0", 10) catch error.StateReadFailed;
}

pub fn loadAlertingConfigFromEnv(allocator: std.mem.Allocator) AlertError!AlertingConfig {
    const enabled = try readBoolEnv(allocator, "BPM_OBS_ALERTING_ENABLED", false);
    const poll_interval_ms = try readU32Env(allocator, "BPM_OBS_ALERT_POLL_INTERVAL_MS", 5000);

    const thresholds = AlertThresholds{
        .error_stuck_minutes = try readU32Env(allocator, "BPM_OBS_ALERT_ERROR_STUCK_MINUTES", 10),
        .dlq_depth_threshold = try readU32Env(allocator, "BPM_OBS_ALERT_DLQ_DEPTH_THRESHOLD", 100),
        .scheduler_lag_ms = try readU32Env(allocator, "BPM_OBS_ALERT_SCHEDULER_LAG_MS", 15_000),
    };

    if (!enabled) {
        return .{
            .enabled = false,
            .poll_interval_ms = poll_interval_ms,
            .thresholds = thresholds,
            .hooks = try allocator.alloc(AlertHookConfig, 0),
        };
    }

    const destination_url = (try getEnvAlloc(allocator, "BPM_OBS_ALERT_HOOK_URL")) orelse return error.InvalidConfig;
    if (!std.mem.startsWith(u8, destination_url, "http://") and !std.mem.startsWith(u8, destination_url, "https://")) {
        allocator.free(destination_url);
        return error.InvalidConfig;
    }

    const hook_id = (try getEnvAlloc(allocator, "BPM_OBS_ALERT_HOOK_ID")) orelse try allocator.dupe(u8, "ops-primary");
    const secret_ref = try getEnvAlloc(allocator, "BPM_OBS_ALERT_HOOK_SECRET_REF");
    const timeout_ms = try readU32Env(allocator, "BPM_OBS_ALERT_HOOK_TIMEOUT_MS", 5000);

    const hooks = try allocator.alloc(AlertHookConfig, 1);
    hooks[0] = .{
        .hook_id = hook_id,
        .enabled = true,
        .destination_url = destination_url,
        .timeout_ms = timeout_ms,
        .auth_secret_ref = secret_ref,
        .retry_policy = .{},
    };

    return .{
        .enabled = true,
        .poll_interval_ms = poll_interval_ms,
        .thresholds = thresholds,
        .hooks = hooks,
    };
}

pub fn evaluateAlertRules(
    allocator: std.mem.Allocator,
    input: AlertEvaluationInput,
    state: *AlertStateStore,
) AlertError![]AlertEvent {
    var events: std.ArrayList(AlertEvent) = .empty;
    errdefer {
        for (events.items) |event| event.deinit(allocator);
        events.deinit(allocator);
    }

    var seen_error_keys: std.ArrayList([]u8) = .empty;
    defer {
        for (seen_error_keys.items) |key| allocator.free(key);
        seen_error_keys.deinit(allocator);
    }

    for (input.error_instances) |instance| {
        const trigger_key = std.fmt.allocPrint(allocator, "instance:{s}:error_stuck", .{instance.instance_id}) catch return error.OutOfMemory;
        errdefer allocator.free(trigger_key);

        try seen_error_keys.append(allocator, try allocator.dupe(u8, trigger_key));

        const state_entry = try state.getOrCreate(trigger_key);
        const duration_minutes = @divFloor(input.now_us - instance.error_since_us, 60 * 1_000_000);
        const threshold_minutes = @as(i64, @intCast(input.thresholds.error_stuck_minutes));
        if (duration_minutes > threshold_minutes and state_entry.armed) {
            state_entry.armed = false;
            const correlation_id = try makeCorrelationId(allocator, .instance_error_stuck, trigger_key, input.now_us);
            const payload = try buildAlertPayload(
                allocator,
                .{
                    .hook_id = input.hook_id,
                    .correlation_id = correlation_id,
                    .alert_type = .instance_error_stuck,
                    .occurred_at_us = input.now_us,
                    .trace_id = input.trace_id,
                    .trigger_key = trigger_key,
                },
                .{ .instance_error_stuck = .{
                    .instance_id = instance.instance_id,
                    .definition_id = instance.definition_id,
                    .error_reason = instance.error_reason,
                    .error_since_us = instance.error_since_us,
                    .error_duration_minutes = duration_minutes,
                } },
            );

            try events.append(allocator, .{
                .hook_id = try allocator.dupe(u8, input.hook_id),
                .trigger_key = trigger_key,
                .trace_id = try allocator.dupe(u8, input.trace_id),
                .correlation_id = correlation_id,
                .payload_json = payload,
                .alert_type = .instance_error_stuck,
                .occurred_at_us = input.now_us,
            });
        } else {
            if (duration_minutes <= threshold_minutes) state_entry.armed = true;
            allocator.free(trigger_key);
        }
    }

    var state_it = state.threshold_states.iterator();
    while (state_it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, "instance:")) continue;
        if (!std.mem.endsWith(u8, key, ":error_stuck")) continue;
        if (!containsOwnedKey(seen_error_keys.items, key)) {
            entry.value_ptr.armed = true;
        }
    }

    const maybe_dlq_event = try evaluateThresholdCrossing(
        allocator,
        state,
        input,
        "dlq:depth",
        input.dlq_depth,
        input.thresholds.dlq_depth_threshold,
        .dlq_depth_threshold,
    );
    if (maybe_dlq_event) |event| try events.append(allocator, event);

    const maybe_lag_event = try evaluateThresholdCrossing(
        allocator,
        state,
        input,
        "scheduler:lag",
        input.scheduler_lag_ms,
        input.thresholds.scheduler_lag_ms,
        .scheduler_lag_threshold,
    );
    if (maybe_lag_event) |event| try events.append(allocator, event);

    return events.toOwnedSlice(allocator);
}

pub fn buildWebhookSubscriptionPausedEvent(
    allocator: std.mem.Allocator,
    hook_id: []const u8,
    trace_id: []const u8,
    subscription_id: []const u8,
    target_url: []const u8,
    failure_count: u32,
    pause_reason: []const u8,
    occurred_at_us: i64,
) AlertError!AlertEvent {
    const trigger_key = std.fmt.allocPrint(allocator, "webhook:{s}:paused", .{subscription_id}) catch return error.OutOfMemory;
    errdefer allocator.free(trigger_key);

    const correlation_id = try makeCorrelationId(allocator, .webhook_subscription_paused, trigger_key, occurred_at_us);
    errdefer allocator.free(correlation_id);

    const payload = try buildAlertPayload(
        allocator,
        .{
            .hook_id = hook_id,
            .trigger_key = trigger_key,
            .correlation_id = correlation_id,
            .alert_type = .webhook_subscription_paused,
            .occurred_at_us = occurred_at_us,
            .trace_id = trace_id,
        },
        .{ .webhook_subscription_paused = .{
            .subscription_id = subscription_id,
            .target_url = target_url,
            .failure_count = failure_count,
            .paused_at_us = occurred_at_us,
            .pause_reason = pause_reason,
        } },
    );

    return .{
        .hook_id = try allocator.dupe(u8, hook_id),
        .trigger_key = trigger_key,
        .trace_id = try allocator.dupe(u8, trace_id),
        .correlation_id = correlation_id,
        .payload_json = payload,
        .alert_type = .webhook_subscription_paused,
        .occurred_at_us = occurred_at_us,
    };
}

fn evaluateThresholdCrossing(
    allocator: std.mem.Allocator,
    state: *AlertStateStore,
    input: AlertEvaluationInput,
    trigger_key: []const u8,
    current_value: u64,
    threshold_value: u32,
    alert_type: AlertType,
) AlertError!?AlertEvent {
    const state_entry = try state.getOrCreate(trigger_key);
    const previous_value = if (state_entry.has_last_value) state_entry.last_value else current_value;

    const below_threshold = current_value < threshold_value;
    const crossed_up = state_entry.has_last_value and previous_value < threshold_value and current_value >= threshold_value;

    state_entry.has_last_value = true;
    state_entry.last_value = current_value;

    if (below_threshold) {
        state_entry.armed = true;
        return null;
    }

    if (!crossed_up or !state_entry.armed) return null;
    state_entry.armed = false;

    const owned_trigger_key = try allocator.dupe(u8, trigger_key);
    errdefer allocator.free(owned_trigger_key);

    const correlation_id = try makeCorrelationId(allocator, alert_type, trigger_key, input.now_us);
    errdefer allocator.free(correlation_id);

    const payload = switch (alert_type) {
        .dlq_depth_threshold => try buildAlertPayload(
            allocator,
            .{
                .hook_id = input.hook_id,
                .correlation_id = correlation_id,
                .alert_type = .dlq_depth_threshold,
                .occurred_at_us = input.now_us,
                .trace_id = input.trace_id,
                .trigger_key = trigger_key,
            },
            .{ .dlq_depth_threshold = .{
                .threshold = threshold_value,
                .previous_depth = previous_value,
                .current_depth = current_value,
            } },
        ),
        .scheduler_lag_threshold => try buildAlertPayload(
            allocator,
            .{
                .hook_id = input.hook_id,
                .correlation_id = correlation_id,
                .alert_type = .scheduler_lag_threshold,
                .occurred_at_us = input.now_us,
                .trace_id = input.trace_id,
                .trigger_key = trigger_key,
            },
            .{ .scheduler_lag_threshold = .{
                .threshold_ms = threshold_value,
                .previous_lag_ms = previous_value,
                .current_lag_ms = current_value,
                .configured_poll_interval_ms = input.scheduler_poll_interval_ms,
            } },
        ),
        else => return null,
    };

    return .{
        .hook_id = try allocator.dupe(u8, input.hook_id),
        .trigger_key = owned_trigger_key,
        .trace_id = try allocator.dupe(u8, input.trace_id),
        .correlation_id = correlation_id,
        .payload_json = payload,
        .alert_type = alert_type,
        .occurred_at_us = input.now_us,
    };
}

const AlertPayloadEnvelope = struct {
    hook_id: []const u8,
    trigger_key: []const u8,
    correlation_id: []const u8,
    alert_type: AlertType,
    occurred_at_us: i64,
    trace_id: []const u8,
};

pub fn buildAlertPayload(
    allocator: std.mem.Allocator,
    envelope: AlertPayloadEnvelope,
    source: AlertSource,
) AlertError![]u8 {
    const occurred_at = try formatIso8601FromUs(allocator, envelope.occurred_at_us);
    defer allocator.free(occurred_at);

    const alert_id = try deriveAlertId(allocator, envelope.correlation_id);
    defer allocator.free(alert_id);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{");
    try appendJsonStringField(allocator, &out, true, "schema_version", "1.0");
    try appendJsonStringField(allocator, &out, false, "alert_id", alert_id);
    try appendJsonStringField(allocator, &out, false, "alert_type", alertTypeToString(envelope.alert_type));
    try appendJsonStringField(allocator, &out, false, "hook_id", envelope.hook_id);
    try appendJsonStringField(allocator, &out, false, "correlation_id", envelope.correlation_id);
    try appendJsonStringField(allocator, &out, false, "occurred_at", occurred_at);
    try appendJsonStringField(allocator, &out, false, "source_component", "obs.alerts.poller");
    try appendJsonStringField(allocator, &out, false, "trace_id", envelope.trace_id);

    switch (source) {
        .instance_error_stuck => |value| {
            const error_since = try formatIso8601FromUs(allocator, value.error_since_us);
            defer allocator.free(error_since);

            try appendJsonStringField(allocator, &out, false, "instance_id", value.instance_id);
            try appendJsonStringField(allocator, &out, false, "definition_id", value.definition_id);
            try appendJsonStringField(allocator, &out, false, "error_reason", value.error_reason);
            try appendJsonStringField(allocator, &out, false, "error_since", error_since);
            try appendJsonIntField(allocator, &out, false, "error_duration_minutes", value.error_duration_minutes);
            try appendJsonStringField(allocator, &out, false, "status", "ERROR");
        },
        .dlq_depth_threshold => |value| {
            try appendJsonIntField(allocator, &out, false, "threshold", value.threshold);
            try appendJsonIntField(allocator, &out, false, "current_depth", value.current_depth);
            try appendJsonIntField(allocator, &out, false, "previous_depth", value.previous_depth);
            try appendJsonStringField(allocator, &out, false, "crossing_direction", "upward");
        },
        .scheduler_lag_threshold => |value| {
            try appendJsonIntField(allocator, &out, false, "threshold_ms", value.threshold_ms);
            try appendJsonIntField(allocator, &out, false, "current_lag_ms", value.current_lag_ms);
            try appendJsonIntField(allocator, &out, false, "previous_lag_ms", value.previous_lag_ms);
            try appendJsonIntField(allocator, &out, false, "configured_poll_interval_ms", value.configured_poll_interval_ms);
        },
        .webhook_subscription_paused => |value| {
            const paused_at = try formatIso8601FromUs(allocator, value.paused_at_us);
            defer allocator.free(paused_at);
            try appendJsonStringField(allocator, &out, false, "subscription_id", value.subscription_id);
            try appendJsonStringField(allocator, &out, false, "target_url", value.target_url);
            try appendJsonIntField(allocator, &out, false, "failure_count", value.failure_count);
            try appendJsonStringField(allocator, &out, false, "paused_at", paused_at);
            try appendJsonStringField(allocator, &out, false, "pause_reason", value.pause_reason);
        },
    }

    try out.appendSlice(allocator, "}");
    return out.toOwnedSlice(allocator);
}

pub fn dispatchAlertEvent(
    allocator: std.mem.Allocator,
    adapter: DeliveryAdapter,
    event: AlertEvent,
    hook: AlertHookConfig,
) AlertError!void {
    const attempts = @min(@max(hook.retry_policy.max_attempts, 1), 3);
    const alert_id = try deriveAlertId(allocator, event.correlation_id);
    defer allocator.free(alert_id);

    var attempt: u8 = 1;
    var last_error: []const u8 = "none";

    while (attempt <= attempts) : (attempt += 1) {
        const status = adapter.postFn(adapter.context, .{
            .url = hook.destination_url,
            .timeout_ms = hook.timeout_ms,
            .payload_json = event.payload_json,
            .correlation_id = event.correlation_id,
            .alert_id = alert_id,
        }) catch |err| {
            last_error = switch (err) {
                error.Timeout => "timeout",
                else => "transport_error",
            };

            if (attempt < attempts) {
                sleepMs(computeBackoffMs(hook.retry_policy, attempt));
                continue;
            }

            emitTerminalFailureLog(allocator, event, hook, attempt, last_error);
            return if (err == error.Timeout) error.DeliveryTimeout else error.TerminalDeliveryFailure;
        };

        if (status >= 200 and status < 300) return;

        last_error = "non_2xx";
        if (attempt < attempts) {
            sleepMs(computeBackoffMs(hook.retry_policy, attempt));
            continue;
        }

        emitTerminalFailureLog(allocator, event, hook, attempt, last_error);
        return error.TerminalDeliveryFailure;
    }
}

fn emitTerminalFailureLog(
    allocator: std.mem.Allocator,
    event: AlertEvent,
    hook: AlertHookConfig,
    attempt_count: u8,
    last_error: []const u8,
) void {
    const fields = [_]logger.LogField{
        .{ .key = "trace_id", .value = .{ .string = event.trace_id } },
        .{ .key = "correlation_id", .value = .{ .string = event.correlation_id } },
        .{ .key = "alert_type", .value = .{ .string = alertTypeToString(event.alert_type) } },
        .{ .key = "destination_url", .value = .{ .string = hook.destination_url } },
        .{ .key = "attempt_count", .value = .{ .integer = attempt_count } },
        .{ .key = "last_error", .value = .{ .string = last_error } },
    };

    const trace = logger.TraceContext{ .trace_id = event.trace_id, .source = .background };
    logger.logWithTrace(
        allocator,
        .ERROR,
        "obs.alerts.dispatcher",
        trace,
        "alert webhook delivery exhausted retries",
        &fields,
    ) catch {};
}

pub fn persistThresholdState(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    trigger_key: []const u8,
    armed: bool,
    last_sample_value: u64,
) AlertError!void {
    const conn = pool.acquire() catch return error.StateWriteFailed;
    defer pool.release(conn);

    const last_value_text = std.fmt.allocPrint(allocator, "{d}", .{last_sample_value}) catch return error.OutOfMemory;
    defer allocator.free(last_value_text);

    conn.exec(
        "INSERT INTO obs_alert_trigger_state (trigger_key, is_armed, last_sample_value, updated_at) VALUES ($1, $2::boolean, $3::bigint, NOW()) ON CONFLICT (trigger_key) DO UPDATE SET is_armed = EXCLUDED.is_armed, last_sample_value = EXCLUDED.last_sample_value, updated_at = NOW()",
        &.{ trigger_key, if (armed) "true" else "false", last_value_text },
    ) catch return error.StateWriteFailed;
}

fn computeBackoffMs(policy: RetryPolicy, attempt: u8) u32 {
    var delay: f64 = @floatFromInt(policy.base_backoff_ms);
    var i: u8 = 1;
    while (i < attempt) : (i += 1) {
        delay *= policy.multiplier;
    }
    const clamped = @min(@as(u64, @intFromFloat(delay)), @as(u64, policy.max_backoff_ms));
    return @intCast(clamped);
}

fn sleepMs(delay_ms: u32) void {
    if (delay_ms == 0) return;
    std.Io.sleep(
        std.Options.debug_io,
        .fromMilliseconds(@as(i64, delay_ms)),
        .awake,
    ) catch {};
}

fn containsOwnedKey(values: []const []u8, target: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, target)) return true;
    }
    return false;
}

fn makeCorrelationId(
    allocator: std.mem.Allocator,
    alert_type: AlertType,
    trigger_key: []const u8,
    occurred_at_us: i64,
) AlertError![]u8 {
    const occurred_at_ms = @divFloor(occurred_at_us, 1000);
    return std.fmt.allocPrint(
        allocator,
        "obs06:{s}:{s}:{d}",
        .{ alertTypeToString(alert_type), trigger_key, occurred_at_ms },
    ) catch error.OutOfMemory;
}

fn deriveAlertId(allocator: std.mem.Allocator, correlation_id: []const u8) AlertError![]u8 {
    var hasher = std.hash.Fnv1a_128.init();
    hasher.update(correlation_id);
    const hash = hasher.final();

    var bytes: [16]u8 = undefined;
    std.mem.copyForwards(u8, &bytes, std.mem.asBytes(&hash)[0..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15],
        },
    ) catch error.OutOfMemory;
}

fn appendJsonStringField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: bool,
    key: []const u8,
    value: []const u8,
) AlertError!void {
    if (!first) try out.append(allocator, ',');
    const key_json = std.json.Stringify.valueAlloc(allocator, .{ .string = key }, .{}) catch return error.PayloadBuildFailed;
    defer allocator.free(key_json);
    const value_json = std.json.Stringify.valueAlloc(allocator, .{ .string = value }, .{}) catch return error.PayloadBuildFailed;
    defer allocator.free(value_json);
    try out.appendSlice(allocator, key_json);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, value_json);
}

fn appendJsonIntField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    first: bool,
    key: []const u8,
    value: anytype,
) AlertError!void {
    if (!first) try out.append(allocator, ',');
    const key_json = std.json.Stringify.valueAlloc(allocator, .{ .string = key }, .{}) catch return error.PayloadBuildFailed;
    defer allocator.free(key_json);
    const value_text = std.fmt.allocPrint(allocator, "{d}", .{value}) catch return error.OutOfMemory;
    defer allocator.free(value_text);
    try out.appendSlice(allocator, key_json);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, value_text);
}

fn alertTypeToString(alert_type: AlertType) []const u8 {
    return switch (alert_type) {
        .instance_error_stuck => "instance_error_stuck",
        .dlq_depth_threshold => "dlq_depth_threshold",
        .scheduler_lag_threshold => "scheduler_lag_threshold",
        .webhook_subscription_paused => "webhook_subscription_paused",
    };
}

fn formatIso8601FromUs(allocator: std.mem.Allocator, epoch_us: i64) AlertError![]u8 {
    const seconds = @divFloor(epoch_us, 1_000_000);
    const micros: u32 = @intCast(@mod(epoch_us, 1_000_000));
    const day_seconds: u32 = @intCast(@mod(seconds, 86_400));
    const days = @divFloor(seconds, 86_400);
    const civil = civilFromDays(days);

    const hour = @divFloor(day_seconds, 3600);
    const minute = @divFloor(day_seconds % 3600, 60);
    const second = day_seconds % 60;

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z",
        .{ civil.year, civil.month, civil.day, hour, minute, second, micros },
    ) catch error.OutOfMemory;
}

const CivilDate = struct {
    year: i32,
    month: u32,
    day: u32,
};

fn civilFromDays(days_since_unix_epoch: i64) CivilDate {
    const z = days_since_unix_epoch + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    var year: i32 = @intCast(yoe + era * 400);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month_i64: i64 = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    const month: u32 = @intCast(month_i64);
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn readBoolEnv(allocator: std.mem.Allocator, name: []const u8, default_value: bool) AlertError!bool {
    const maybe = try getEnvAlloc(allocator, name);
    if (maybe == null) return default_value;
    defer allocator.free(maybe.?);
    if (std.ascii.eqlIgnoreCase(maybe.?, "1") or std.ascii.eqlIgnoreCase(maybe.?, "true")) return true;
    if (std.ascii.eqlIgnoreCase(maybe.?, "0") or std.ascii.eqlIgnoreCase(maybe.?, "false")) return false;
    return error.InvalidConfig;
}

fn readU32Env(allocator: std.mem.Allocator, name: []const u8, default_value: u32) AlertError!u32 {
    const maybe = try getEnvAlloc(allocator, name);
    if (maybe == null) return default_value;
    defer allocator.free(maybe.?);
    return std.fmt.parseInt(u32, maybe.?, 10) catch error.InvalidConfig;
}

fn getEnvAlloc(allocator: std.mem.Allocator, name: []const u8) AlertError!?[]const u8 {
    const environ = env.globalEnviron();
    return environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => error.OutOfMemory,
    };
}

test "OBS-06 one-shot/re-arm semantics for DLQ depth crossing" {
    var state = AlertStateStore.init(std.testing.allocator);
    defer state.deinit();

    const base_input = AlertEvaluationInput{
        .now_us = 1_717_000_000_000_000,
        .hook_id = "ops-primary",
        .trace_id = "",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = &.{},
        .dlq_depth = 80,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    };

    const initial = try evaluateAlertRules(std.testing.allocator, base_input, &state);
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 0), initial.len);

    const crossed = try evaluateAlertRules(std.testing.allocator, .{
        .now_us = base_input.now_us + 1_000_000,
        .hook_id = base_input.hook_id,
        .trace_id = "",
        .thresholds = base_input.thresholds,
        .error_instances = &.{},
        .dlq_depth = 120,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (crossed) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(crossed);
    }
    try std.testing.expectEqual(@as(usize, 1), crossed.len);
    try std.testing.expectEqual(AlertType.dlq_depth_threshold, crossed[0].alert_type);

    const still_above = try evaluateAlertRules(std.testing.allocator, .{
        .now_us = base_input.now_us + 2_000_000,
        .hook_id = base_input.hook_id,
        .trace_id = "",
        .thresholds = base_input.thresholds,
        .error_instances = &.{},
        .dlq_depth = 140,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer std.testing.allocator.free(still_above);
    try std.testing.expectEqual(@as(usize, 0), still_above.len);

    const rearm = try evaluateAlertRules(std.testing.allocator, .{
        .now_us = base_input.now_us + 3_000_000,
        .hook_id = base_input.hook_id,
        .trace_id = "",
        .thresholds = base_input.thresholds,
        .error_instances = &.{},
        .dlq_depth = 10,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer std.testing.allocator.free(rearm);
    try std.testing.expectEqual(@as(usize, 0), rearm.len);

    const crossed_again = try evaluateAlertRules(std.testing.allocator, .{
        .now_us = base_input.now_us + 4_000_000,
        .hook_id = base_input.hook_id,
        .trace_id = "",
        .thresholds = base_input.thresholds,
        .error_instances = &.{},
        .dlq_depth = 101,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (crossed_again) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(crossed_again);
    }
    try std.testing.expectEqual(@as(usize, 1), crossed_again.len);
}

test "OBS-06 multiple ERROR instances emit one alert per instance" {
    var state = AlertStateStore.init(std.testing.allocator);
    defer state.deinit();

    const now_us: i64 = 1_717_000_000_000_000;
    const snapshots = [_]ErrorInstanceSnapshot{
        .{ .instance_id = "11111111-1111-1111-1111-111111111111", .definition_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", .error_reason = "timeout", .error_since_us = now_us - (11 * 60 * 1_000_000) },
        .{ .instance_id = "22222222-2222-2222-2222-222222222222", .definition_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", .error_reason = "validation", .error_since_us = now_us - (20 * 60 * 1_000_000) },
    };

    const events = try evaluateAlertRules(std.testing.allocator, .{
        .now_us = now_us,
        .hook_id = "ops-primary",
        .trace_id = "",
        .thresholds = .{ .error_stuck_minutes = 10, .dlq_depth_threshold = 100, .scheduler_lag_ms = 5000 },
        .error_instances = snapshots[0..],
        .dlq_depth = 0,
        .scheduler_lag_ms = 0,
        .scheduler_poll_interval_ms = 5000,
    }, &state);
    defer {
        for (events) |event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(AlertType.instance_error_stuck, events[0].alert_type);
    try std.testing.expectEqual(AlertType.instance_error_stuck, events[1].alert_type);
}

test "OBS-06 deterministic correlation id and payload envelope" {
    const correlation = try makeCorrelationId(
        std.testing.allocator,
        .dlq_depth_threshold,
        "dlq:depth",
        1_717_000_000_000_000,
    );
    defer std.testing.allocator.free(correlation);
    try std.testing.expectEqualStrings("obs06:dlq_depth_threshold:dlq:depth:1717000000000", correlation);

    const payload = try buildAlertPayload(
        std.testing.allocator,
        .{
            .hook_id = "ops-primary",
            .trigger_key = "dlq:depth",
            .correlation_id = correlation,
            .alert_type = .dlq_depth_threshold,
            .occurred_at_us = 1_717_000_000_000_000,
            .trace_id = "",
        },
        .{ .dlq_depth_threshold = .{
            .threshold = 100,
            .previous_depth = 50,
            .current_depth = 120,
        } },
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema_version\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"alert_type\":\"dlq_depth_threshold\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"hook_id\":\"ops-primary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"correlation_id\":\"obs06:dlq_depth_threshold:dlq:depth:1717000000000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"current_depth\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"previous_depth\":50") != null);
}

test "OBS-06 retry backoff is bounded and exponential" {
    const policy = RetryPolicy{ .max_attempts = 3, .base_backoff_ms = 1000, .multiplier = 2.0, .max_backoff_ms = 30_000 };
    try std.testing.expectEqual(@as(u32, 1000), computeBackoffMs(policy, 1));
    try std.testing.expectEqual(@as(u32, 2000), computeBackoffMs(policy, 2));
    try std.testing.expectEqual(@as(u32, 4000), computeBackoffMs(policy, 3));
}
