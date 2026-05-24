//! Structured JSON logger for the BPM Platform (OBS-01).
//!
//! Emits single-line JSON objects to stdout with the required field set:
//! timestamp, level, trace_id, component, and message.

const std = @import("std");
const builtin = @import("builtin");
const trace_context = @import("../api/trace_context.zig");
const trace_middleware = @import("../api/middleware/trace.zig");

pub const LogLevel = enum(u8) {
    DEBUG,
    INFO,
    WARN,
    ERROR,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .DEBUG => "DEBUG",
            .INFO => "INFO",
            .WARN => "WARN",
            .ERROR => "ERROR",
        };
    }
};

pub const Level = LogLevel;

pub const LoggerConfig = struct {
    level: LogLevel,
    component: []const u8,
};

pub const LogValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null: void,
};

pub const LogField = struct {
    key: []const u8,
    value: LogValue,
};

pub const TraceSource = enum {
    request,
    background,
    none,
};

pub const TraceContext = struct {
    trace_id: []const u8,
    source: TraceSource,
};

pub const LogEntry = struct {
    timestamp: []const u8,
    level: LogLevel,
    trace_id: []const u8,
    component: []const u8,
    message: []const u8,
    fields: []const LogField,
};

pub const BackgroundTraceScope = struct {
    trace_id: [trace_middleware.UUID_V4_LEN]u8,
    component: []const u8,
};

pub const LoggerError = error{
    InvalidLogLevel,
    ReservedField,
    JsonSerialisationFailed,
    StdoutWriteFailed,
    OutOfMemory,
};

const reserved_keys = [_][]const u8{ "timestamp", "level", "trace_id", "component", "message" };
const sensitive_exact_keys = [_][]const u8{
    "authorization",
    "password",
    "password_hash",
    "token",
    "access_token",
    "refresh_token",
    "bootstrap_token",
    "api_token",
    "secret",
    "client_secret",
    "credential",
    "credentials",
    "set-cookie",
    "cookie",
};
const sensitive_suffixes = [_][]const u8{ "_token", "_secret", "_password", "_credential" };

var current_level: LogLevel = .INFO;

pub fn parseLogLevel(raw: []const u8) LoggerError!LogLevel {
    if (std.mem.eql(u8, raw, "DEBUG")) return .DEBUG;
    if (std.mem.eql(u8, raw, "INFO")) return .INFO;
    if (std.mem.eql(u8, raw, "WARN")) return .WARN;
    if (std.mem.eql(u8, raw, "ERROR")) return .ERROR;
    return error.InvalidLogLevel;
}

pub fn init(config: LoggerConfig) LoggerError!void {
    _ = config.component;
    current_level = config.level;
}

pub fn log(
    allocator: std.mem.Allocator,
    level: LogLevel,
    component: []const u8,
    message: []const u8,
    fields: []const LogField,
) LoggerError!void {
    return logWithTrace(allocator, level, component, currentTraceContext(), message, fields);
}

pub fn logWithTrace(
    allocator: std.mem.Allocator,
    level: LogLevel,
    component: []const u8,
    trace: TraceContext,
    message: []const u8,
    fields: []const LogField,
) LoggerError!void {
    if (builtin.is_test) return;
    if (!isEnabled(level)) return;

    const line = try buildLogLine(allocator, level, component, trace.trace_id, message, fields);
    defer allocator.free(line);

    std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line) catch return error.StdoutWriteFailed;
}

pub fn beginBackgroundTrace(component: []const u8) BackgroundTraceScope {
    var scope = BackgroundTraceScope{
        .trace_id = undefined,
        .component = component,
    };
    trace_middleware.generateUuidV4(&scope.trace_id);
    return scope;
}

pub fn currentTraceContext() TraceContext {
    const active_trace_id = trace_context.get();
    if (active_trace_id.len == 0) {
        return .{ .trace_id = "", .source = .none };
    }
    return .{ .trace_id = active_trace_id, .source = .request };
}

pub fn redactFields(
    allocator: std.mem.Allocator,
    fields: []const LogField,
) LoggerError![]LogField {
    const redacted = try allocator.alloc(LogField, fields.len);
    for (fields, 0..) |field, index| {
        redacted[index] = .{
            .key = field.key,
            .value = redactValue(field.key, field.value),
        };
    }
    return redacted;
}

fn isEnabled(level: LogLevel) bool {
    return @intFromEnum(level) >= @intFromEnum(current_level);
}

fn buildLogLine(
    allocator: std.mem.Allocator,
    level: LogLevel,
    component: []const u8,
    trace_id: []const u8,
    message: []const u8,
    fields: []const LogField,
) LoggerError![]u8 {
    try validateFieldKeys(fields);

    const timestamp = try currentTimestampIso8601(allocator);
    defer allocator.free(timestamp);

    const redacted_fields = try redactFields(allocator, fields);
    defer allocator.free(redacted_fields);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '{');
    try appendStringField(allocator, &out, "timestamp", timestamp, true);
    try appendStringField(allocator, &out, "level", level.toString(), false);
    try appendStringField(allocator, &out, "trace_id", trace_id, false);
    try appendStringField(allocator, &out, "component", component, false);
    try appendStringField(allocator, &out, "message", message, false);

    for (redacted_fields) |field| {
        try appendValueField(allocator, &out, field.key, field.value);
    }

    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

fn validateFieldKeys(fields: []const LogField) LoggerError!void {
    for (fields) |field| {
        for (reserved_keys) |reserved| {
            if (std.mem.eql(u8, field.key, reserved)) return error.ReservedField;
        }
    }
}

fn redactValue(key: []const u8, value: LogValue) LogValue {
    if (!isSensitiveKey(key)) return value;
    return .{ .string = "[REDACTED]" };
}

fn isSensitiveKey(key: []const u8) bool {
    for (sensitive_exact_keys) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
    }

    for (sensitive_suffixes) |suffix| {
        if (endsWithIgnoreCase(key, suffix)) return true;
    }

    return false;
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

fn appendStringField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: []const u8,
    first: bool,
) LoggerError!void {
    if (!first) try out.append(allocator, ',');
    try appendJsonString(allocator, out, key);
    try out.append(allocator, ':');
    try appendJsonString(allocator, out, value);
}

fn appendValueField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    key: []const u8,
    value: LogValue,
) LoggerError!void {
    try out.append(allocator, ',');
    try appendJsonString(allocator, out, key);
    try out.append(allocator, ':');

    switch (value) {
        .string => |string_value| try appendJsonString(allocator, out, string_value),
        .integer => |integer_value| {
            const encoded = std.fmt.allocPrint(allocator, "{d}", .{integer_value}) catch return error.OutOfMemory;
            defer allocator.free(encoded);
            try out.appendSlice(allocator, encoded);
        },
        .float => |float_value| {
            const encoded = std.fmt.allocPrint(allocator, "{d}", .{float_value}) catch return error.OutOfMemory;
            defer allocator.free(encoded);
            try out.appendSlice(allocator, encoded);
        },
        .boolean => |boolean_value| try out.appendSlice(allocator, if (boolean_value) "true" else "false"),
        .null => try out.appendSlice(allocator, "null"),
    }
}

fn appendJsonString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) LoggerError!void {
    const encoded = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{}) catch return error.OutOfMemory;
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn currentTimestampIso8601(allocator: std.mem.Allocator) LoggerError![]u8 {
    const timestamp_us = currentMicrosecondTimestamp();
    const seconds = @divFloor(timestamp_us, 1_000_000);
    const micros: u32 = @intCast(@mod(timestamp_us, 1_000_000));
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
    ) catch return error.OutOfMemory;
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

fn currentMicrosecondTimestamp() i64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    }

    const posix = std.posix;
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(.REALTIME, &ts);
    const sec_us: i64 = ts.sec * 1_000_000;
    const nsec_us: i64 = @divTrunc(ts.nsec, 1000);
    return sec_us + nsec_us;
}

const testing = std.testing;

test "OBS-01 parseLogLevel accepts valid values" {
    try testing.expectEqual(LogLevel.DEBUG, try parseLogLevel("DEBUG"));
    try testing.expectEqual(LogLevel.INFO, try parseLogLevel("INFO"));
    try testing.expectEqual(LogLevel.WARN, try parseLogLevel("WARN"));
    try testing.expectEqual(LogLevel.ERROR, try parseLogLevel("ERROR"));
}

test "OBS-01 parseLogLevel rejects invalid values" {
    try testing.expectError(error.InvalidLogLevel, parseLogLevel("debug"));
    try testing.expectError(error.InvalidLogLevel, parseLogLevel("TRACE"));
    try testing.expectError(error.InvalidLogLevel, parseLogLevel(""));
}

test "OBS-01 currentTraceContext returns request trace when active" {
    trace_context.set("trace-from-request");
    defer trace_context.clear();

    const trace = currentTraceContext();
    try testing.expectEqual(TraceSource.request, trace.source);
    try testing.expectEqualStrings("trace-from-request", trace.trace_id);
}

test "OBS-01 currentTraceContext falls back to empty trace when inactive" {
    trace_context.clear();

    const trace = currentTraceContext();
    try testing.expectEqual(TraceSource.none, trace.source);
    try testing.expectEqualStrings("", trace.trace_id);
}

test "OBS-01 beginBackgroundTrace generates UUID trace id" {
    const scope = beginBackgroundTrace("scheduler.poller");
    try testing.expectEqual(@as(usize, trace_middleware.UUID_V4_LEN), scope.trace_id.len);
    try testing.expectEqual('-', scope.trace_id[8]);
    try testing.expectEqual('-', scope.trace_id[13]);
    try testing.expectEqual('-', scope.trace_id[18]);
    try testing.expectEqual('-', scope.trace_id[23]);
}

test "OBS-01 buildLogLine emits required fields and request trace" {
    trace_context.set("obs-request-trace");
    defer trace_context.clear();

    const fields = [_]LogField{
        .{ .key = "path", .value = .{ .string = "/health/live" } },
        .{ .key = "status_code", .value = .{ .integer = 200 } },
    };

    const line = try buildLogLine(testing.allocator, .INFO, "api.health", currentTraceContext().trace_id, "health live request completed", &fields);
    defer testing.allocator.free(line);

    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try testing.expect(std.mem.indexOf(u8, line, "\"timestamp\":") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"level\":\"INFO\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"trace_id\":\"obs-request-trace\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"component\":\"api.health\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"message\":\"health live request completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"status_code\":200") != null);
}

test "OBS-01 buildLogLine keeps serialized output on one line" {
    const line = try buildLogLine(testing.allocator, .INFO, "main", "", "startup configuration validated", &.{});
    defer testing.allocator.free(line);

    try testing.expect(std.mem.endsWith(u8, line, "}\n"));
    try testing.expect(std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') == null);
    try testing.expect(std.mem.indexOf(u8, line, "\"trace_id\":\"\"") != null);
}

test "OBS-01 buildLogLine includes generated background trace id" {
    const scope = beginBackgroundTrace("scheduler.poller");
    const line = try buildLogLine(
        testing.allocator,
        .DEBUG,
        scope.component,
        scope.trace_id[0..],
        "timer poll cycle started",
        &.{.{ .key = "poll_cycle", .value = .{ .integer = 1 } }},
    );
    defer testing.allocator.free(line);

    try testing.expect(std.mem.indexOf(u8, line, scope.trace_id[0..]) != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"component\":\"scheduler.poller\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"poll_cycle\":1") != null);
}

test "OBS-01 redactFields redacts exact and suffix sensitive keys" {
    const fields = [_]LogField{
        .{ .key = "Authorization", .value = .{ .string = "Bearer abc" } },
        .{ .key = "session_token", .value = .{ .string = "secret-token" } },
        .{ .key = "username", .value = .{ .string = "alice" } },
    };

    const redacted = try redactFields(testing.allocator, &fields);
    defer testing.allocator.free(redacted);

    try testing.expectEqualStrings("[REDACTED]", redacted[0].value.string);
    try testing.expectEqualStrings("[REDACTED]", redacted[1].value.string);
    try testing.expectEqualStrings("alice", redacted[2].value.string);
}

test "OBS-01 buildLogLine redacts sensitive values in emitted JSON" {
    const fields = [_]LogField{
        .{ .key = "password", .value = .{ .string = "hunter2" } },
        .{ .key = "client_secret", .value = .{ .string = "super-secret" } },
        .{ .key = "username", .value = .{ .string = "alice" } },
    };

    const line = try buildLogLine(testing.allocator, .WARN, "identity.registry", "", "credential check failed", &fields);
    defer testing.allocator.free(line);

    try testing.expect(std.mem.indexOf(u8, line, "\"password\":\"[REDACTED]\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"client_secret\":\"[REDACTED]\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"username\":\"alice\"") != null);
}

test "OBS-01 reserved field names are rejected" {
    const fields = [_]LogField{
        .{ .key = "message", .value = .{ .string = "bad" } },
    };

    try testing.expectError(error.ReservedField, buildLogLine(testing.allocator, .INFO, "api.health", "", "bad", &fields));
}
