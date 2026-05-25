//! Integration tests for API-09 — Request tracing (HTTP-level).
//!
//! These tests verify that the trace middleware works end-to-end at the
//! HTTP boundary: response headers, log output, and error bodies carry the
//! correct trace ID.
//!
//! Requires:
//!   BPM_TEST_URL   — base URL of a running BPM Platform server
//!                    (e.g. "http://localhost:8080")
//!   BPM_TEST_TOKEN — a valid Bearer token for authenticated requests
//!
//! If either environment variable is absent the entire test file skips
//! gracefully via SkipZigTest (matching the pattern used by TestHarness).
//!
//! Requirement traceability:
//!   API-09 → TC-API-09-INT-01  (X-Trace-Id header on 200)
//!            TC-API-09-INT-02  (caller-supplied header propagated)
//!            TC-API-09-INT-03  (trace ID in log output)
//!            TC-API-09-INT-04  (trace ID in error body)
//!            TC-API-09-INT-05  (trace ID on 401)
//!            TC-API-09-INT-06  (non-UUID trace ID propagated)
//!
//! Run with: zig build test-integration

const std = @import("std");
const testing = std.testing;

// ── Shared helpers ────────────────────────────────────────────────────────────

/// Read BPM_TEST_URL from the environment; skip if absent.
fn testServerUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SkipZigTest,
    };
}

/// Read BPM_TEST_TOKEN from the environment; skip if absent.
fn testAuthToken(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_TOKEN") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SkipZigTest,
    };
}

/// Read BPM_TEST_LOG_FILE from the environment; skip if absent.
fn testLogFilePath(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_LOG_FILE") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SkipZigTest,
    };
}

/// Result of a single HTTP request: status code, the X-Trace-Id response
/// header (if present), and the response body (may be empty).
const HttpResult = struct {
    status: u16,
    trace_id_header: ?[]u8,
    body: []u8,

    fn deinit(self: *HttpResult, allocator: std.mem.Allocator) void {
        if (self.trace_id_header) |h| allocator.free(h);
        allocator.free(self.body);
    }
};

/// Send a GET request to `url`.
///
/// `extra_headers` is a slice of name-value pairs to append to the request.
/// Returns an `HttpResult` owned by the caller.
fn get(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !HttpResult {
    var client: std.http.Client = .{ .io = std.testing.io, .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(.GET, uri, .{
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const status: u16 = @intFromEnum(response.head.status);

    // Capture the X-Trace-Id response header (must do BEFORE calling reader()).
    var trace_id_header: ?[]u8 = null;
    {
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-trace-id")) {
                trace_id_header = try allocator.dupe(u8, header.value);
                break;
            }
        }
    }
    errdefer if (trace_id_header) |h| allocator.free(h);

    // Read body.  After reader() the Head string pointers are invalidated.
    var transfer_buffer: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);
    const body = try body_reader.readAlloc(allocator, 4 * 1024 * 1024);

    return HttpResult{
        .status = status,
        .trace_id_header = trace_id_header,
        .body = body,
    };
}

/// Build an "Authorization: Bearer <token>" header value.
fn bearerHeader(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
}

fn findLogLineContaining(haystack: []const u8, needle: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOf(u8, haystack, needle) orelse return null;
    const line_start = blk: {
        const prev_newline = std.mem.lastIndexOfScalar(u8, haystack[0..idx], '\n') orelse break :blk 0;
        break :blk prev_newline + 1;
    };
    const suffix = haystack[idx..];
    const line_end = idx + (std.mem.indexOfScalar(u8, suffix, '\n') orelse suffix.len);
    return haystack[line_start..line_end];
}

// ── TC-API-09-INT-01 ──────────────────────────────────────────────────────────

test "TC-API-09-INT-01: X-Trace-Id response header present on 200" {
    const alloc = testing.allocator;

    const base_url = try testServerUrl(alloc);
    defer alloc.free(base_url);
    const token = try testAuthToken(alloc);
    defer alloc.free(token);

    const auth_value = try bearerHeader(alloc, token);
    defer alloc.free(auth_value);

    const url = try std.fmt.allocPrint(alloc, "{s}/api/v1/definitions", .{base_url});
    defer alloc.free(url);

    const headers: []const std.http.Header = &.{
        .{ .name = "Authorization", .value = auth_value },
    };

    var result = try get(alloc, url, headers);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), result.status);
    try testing.expect(result.trace_id_header != null);

    const tid = result.trace_id_header.?;
    // Must be exactly UUID_V4_LEN (36) characters long.
    try testing.expectEqual(@as(usize, 36), tid.len);
    // Dash positions
    try testing.expectEqual('-', tid[8]);
    try testing.expectEqual('-', tid[13]);
    try testing.expectEqual('-', tid[18]);
    try testing.expectEqual('-', tid[23]);
    // Version nibble
    try testing.expectEqual('4', tid[14]);
    // Variant nibble
    const variant = tid[19];
    try testing.expect(variant == '8' or variant == '9' or
        variant == 'a' or variant == 'b');
}

// ── TC-API-09-INT-02 ──────────────────────────────────────────────────────────

test "TC-API-09-INT-02: caller-supplied X-Trace-Id is echoed back unchanged" {
    const alloc = testing.allocator;

    const base_url = try testServerUrl(alloc);
    defer alloc.free(base_url);
    const token = try testAuthToken(alloc);
    defer alloc.free(token);

    const auth_value = try bearerHeader(alloc, token);
    defer alloc.free(auth_value);

    const url = try std.fmt.allocPrint(alloc, "{s}/api/v1/definitions", .{base_url});
    defer alloc.free(url);

    const custom_trace = "my-custom-trace-99";
    const headers: []const std.http.Header = &.{
        .{ .name = "Authorization", .value = auth_value },
        .{ .name = "X-Trace-Id", .value = custom_trace },
    };

    var result = try get(alloc, url, headers);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), result.status);
    try testing.expect(result.trace_id_header != null);
    try testing.expectEqualStrings(custom_trace, result.trace_id_header.?);
}

// ── TC-API-09-INT-03 ──────────────────────────────────────────────────────────

test "TC-API-09-INT-03: trace ID appears in structured log output" {
    // This test requires BPM_TEST_LOG_FILE to point to the server's log output.
    // Without a log capture file the test must be skipped.
    const alloc = testing.allocator;

    const base_url = try testServerUrl(alloc);
    defer alloc.free(base_url);
    const token = try testAuthToken(alloc);
    defer alloc.free(token);

    // Check for log file path.
    const log_file_path = try testLogFilePath(alloc);
    defer alloc.free(log_file_path);

    const auth_value = try bearerHeader(alloc, token);
    defer alloc.free(auth_value);

    const custom_trace = "log-test-trace-id-42";
    const url = try std.fmt.allocPrint(alloc, "{s}/api/v1/definitions", .{base_url});
    defer alloc.free(url);

    const headers: []const std.http.Header = &.{
        .{ .name = "Authorization", .value = auth_value },
        .{ .name = "X-Trace-Id", .value = custom_trace },
    };

    var result = try get(alloc, url, headers);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), result.status);

    // Read the log file and search for the trace ID.
    const log_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        log_file_path,
        alloc,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer alloc.free(log_bytes);

    // OBS-01 structured log format contains "trace_id":"<value>"
    const needle = "\"trace_id\":\"" ++ custom_trace ++ "\"";
    try testing.expect(std.mem.indexOf(u8, log_bytes, needle) != null);
}

test "TC-OBS-01-INT-01: health live request emits structured log with propagated trace id" {
    const alloc = testing.allocator;

    const base_url = try testServerUrl(alloc);
    defer alloc.free(base_url);
    // Keep harness preconditions aligned with the rest of this HTTP integration suite.
    // The request remains unauthenticated; token presence only gates environment readiness.
    const token = try testAuthToken(alloc);
    defer alloc.free(token);
    const log_file_path = try testLogFilePath(alloc);
    defer alloc.free(log_file_path);

    const url = try std.fmt.allocPrint(alloc, "{s}/health/live", .{base_url});
    defer alloc.free(url);

    const custom_trace = "obs01-health-trace-77";
    const headers: []const std.http.Header = &.{
        .{ .name = "X-Trace-Id", .value = custom_trace },
    };

    var result = try get(alloc, url, headers);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), result.status);
    try testing.expect(result.trace_id_header != null);
    try testing.expectEqualStrings(custom_trace, result.trace_id_header.?);

    const log_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        log_file_path,
        alloc,
        std.Io.Limit.limited(16 * 1024 * 1024),
    );
    defer alloc.free(log_bytes);

    const trace_needle = "\"trace_id\":\"" ++ custom_trace ++ "\"";
    const line = findLogLineContaining(log_bytes, trace_needle) orelse return error.TestUnexpectedResult;

    try testing.expect(std.mem.indexOf(u8, line, "\"timestamp\":") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"level\":\"INFO\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, trace_needle) != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"component\":\"api.health\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"message\":\"health live request completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"endpoint\":\"/health/live\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"status_code\":200") != null);
    try testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
}

// ── TC-API-09-INT-04 ──────────────────────────────────────────────────────────

test "TC-API-09-INT-04: trace ID appears in error response body for 404" {
    const alloc = testing.allocator;

    const base_url = try testServerUrl(alloc);
    defer alloc.free(base_url);
    const token = try testAuthToken(alloc);
    defer alloc.free(token);

    const auth_value = try bearerHeader(alloc, token);
    defer alloc.free(auth_value);

    // Use a well-formed but nonexistent UUID as the definition ID.
    const url = try std.fmt.allocPrint(
        alloc,
        "{s}/api/v1/definitions/ffffffff-ffff-ffff-ffff-ffffffffffff",
        .{base_url},
    );
    defer alloc.free(url);

    const headers: []const std.http.Header = &.{
        .{ .name = "Authorization", .value = auth_value },
    };

    var result = try get(alloc, url, headers);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(u16, 404), result.status);
    try testing.expect(result.trace_id_header != null);

    // The response body must contain "trace_id":"<header value>"
    const tid = result.trace_id_header.?;
    const expected_needle = try std.fmt.allocPrint(alloc, "\"trace_id\":\"{s}\"", .{tid});
    defer alloc.free(expected_needle);

    try testing.expect(std.mem.indexOf(u8, result.body, expected_needle) != null);
}

// ── TC-API-09-INT-05 ──────────────────────────────────────────────────────────

test "TC-API-09-INT-05: trace ID assigned and returned even on HTTP 401" {
    const alloc = testing.allocator;

    const base_url = try testServerUrl(alloc);
    defer alloc.free(base_url);
    const token = try testAuthToken(alloc);
    defer alloc.free(token);

    // No Authorization header — deliberately unauthenticated.
    const url = try std.fmt.allocPrint(alloc, "{s}/api/v1/definitions", .{base_url});
    defer alloc.free(url);

    var result = try get(alloc, url, &.{});
    defer result.deinit(alloc);

    try testing.expectEqual(@as(u16, 401), result.status);

    // X-Trace-Id must be present and non-empty even for 401 responses.
    try testing.expect(result.trace_id_header != null);
    try testing.expect(result.trace_id_header.?.len > 0);
}

// ── TC-API-09-INT-06 ──────────────────────────────────────────────────────────

test "TC-API-09-INT-06: non-UUID X-Trace-Id propagated unchanged" {
    const alloc = testing.allocator;

    const base_url = try testServerUrl(alloc);
    defer alloc.free(base_url);
    const token = try testAuthToken(alloc);
    defer alloc.free(token);

    const auth_value = try bearerHeader(alloc, token);
    defer alloc.free(auth_value);

    const url = try std.fmt.allocPrint(alloc, "{s}/api/v1/definitions", .{base_url});
    defer alloc.free(url);

    // Value that is clearly not a UUID v4.
    const non_uuid = "totally-not-a-uuid!@#";
    const headers: []const std.http.Header = &.{
        .{ .name = "Authorization", .value = auth_value },
        .{ .name = "X-Trace-Id", .value = non_uuid },
    };

    var result = try get(alloc, url, headers);
    defer result.deinit(alloc);

    try testing.expectEqual(@as(u16, 200), result.status);
    try testing.expect(result.trace_id_header != null);
    try testing.expectEqualStrings(non_uuid, result.trace_id_header.?);
}
