const std = @import("std");
const Uuid = @import("../definition/graph.zig").Uuid;

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
};

pub const ServiceTaskConfig = struct {
    node_id: []const u8,
    url_template: []const u8,
    method: HttpMethod,
    headers_json: ?[]const u8,
    timeout_ms: u32,
    retry_limit: u8,
    body_template_json: ?[]const u8,
};

pub const ServiceTaskFailureKind = enum {
    timeout,
    network,
    http_non_2xx,
    http_redirect_3xx,
    rate_limited_429,
    invalid_2xx_body,
    request_build_error,
};

pub const ServiceTaskDecision = enum {
    retry,
    terminal_dlq,
    immediate_error,
};

pub const ServiceTaskExecutionError = error{
    InvalidConfig,
    EmptyRenderedUrl,
    OutOfMemory,
};

pub const HttpExecutionResult = struct {
    status_code: u16,
    body: []u8,

    pub fn deinit(self: HttpExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub fn parseConfigFromNodeAttributes(
    allocator: std.mem.Allocator,
    node_id: []const u8,
    attributes_json: []const u8,
) ServiceTaskExecutionError!ServiceTaskConfig {
    if (attributes_json.len == 0) return error.InvalidConfig;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, attributes_json, .{}) catch return error.InvalidConfig;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    const url_template_raw = blk: {
        if (obj.get("url")) |entry| {
            const s = switch (entry) {
                .string => |v| v,
                else => return error.InvalidConfig,
            };
            if (s.len == 0) return error.InvalidConfig;
            break :blk s;
        }
        if (obj.get("endpoint")) |entry| {
            const s = switch (entry) {
                .string => |v| v,
                else => return error.InvalidConfig,
            };
            if (s.len == 0) return error.InvalidConfig;
            break :blk s;
        }
        return error.InvalidConfig;
    };

    const method = blk: {
        if (obj.get("method")) |entry| {
            const raw = switch (entry) {
                .string => |s| s,
                else => return error.InvalidConfig,
            };
            break :blk parseHttpMethod(raw) orelse return error.InvalidConfig;
        }
        break :blk .POST;
    };

    const timeout_ms: u32 = blk: {
        if (obj.get("timeout_ms")) |entry| {
            const n: i64 = switch (entry) {
                .integer => |v| v,
                else => return error.InvalidConfig,
            };
            if (n < 1 or n > 300_000) return error.InvalidConfig;
            break :blk @intCast(n);
        }
        break :blk 30_000;
    };

    const retry_limit: u8 = blk: {
        if (obj.get("retry_limit")) |entry| {
            const n: i64 = switch (entry) {
                .integer => |v| v,
                else => return error.InvalidConfig,
            };
            if (n < 0 or n > 255) return error.InvalidConfig;
            break :blk @intCast(n);
        }
        break :blk 3;
    };

    var headers_json: ?[]const u8 = null;
    if (obj.get("headers")) |entry| {
        switch (entry) {
            .object => {
                headers_json = try std.json.Stringify.valueAlloc(allocator, entry, .{});
            },
            else => return error.InvalidConfig,
        }
    }
    errdefer if (headers_json) |h| allocator.free(h);

    var body_template_json: ?[]const u8 = null;
    if (obj.get("body_template")) |entry| {
        body_template_json = try std.json.Stringify.valueAlloc(allocator, entry, .{});
    }
    errdefer if (body_template_json) |b| allocator.free(b);

    const out_node_id = try allocator.dupe(u8, node_id);
    errdefer allocator.free(out_node_id);
    const out_url_template = try allocator.dupe(u8, url_template_raw);
    errdefer allocator.free(out_url_template);

    return ServiceTaskConfig{
        .node_id = out_node_id,
        .url_template = out_url_template,
        .method = method,
        .headers_json = headers_json,
        .timeout_ms = timeout_ms,
        .retry_limit = retry_limit,
        .body_template_json = body_template_json,
    };
}

pub fn validateRenderedUrl(rendered_url: []const u8) ServiceTaskExecutionError!void {
    if (std.mem.trim(u8, rendered_url, " \t\r\n").len == 0) return error.EmptyRenderedUrl;
    if (!std.mem.startsWith(u8, rendered_url, "http://") and !std.mem.startsWith(u8, rendered_url, "https://")) {
        return error.InvalidConfig;
    }
}

pub fn computeServiceTaskBackoffMs(attempt_index: u8, base_ms: u32, cap_ms: u32) u32 {
    if (base_ms == 0) return 0;
    if (attempt_index <= 1) return @min(base_ms, cap_ms);

    var factor: u64 = 1;
    var i: u8 = 1;
    while (i < attempt_index) : (i += 1) {
        factor = factor * 2;
        if (factor > std.math.maxInt(u32)) break;
    }

    const raw: u64 = @as(u64, base_ms) * factor;
    const capped: u64 = @min(raw, @as(u64, cap_ms));
    return @intCast(capped);
}

pub fn classifyFailureKind(status_code: u16) ?ServiceTaskFailureKind {
    if (status_code >= 200 and status_code <= 299) return null;
    if (status_code >= 300 and status_code <= 399) return .http_redirect_3xx;
    if (status_code == 429) return .rate_limited_429;
    return .http_non_2xx;
}

pub fn isRetriableFailure(kind: ServiceTaskFailureKind) bool {
    return switch (kind) {
        .timeout, .network, .http_non_2xx, .rate_limited_429 => true,
        .http_redirect_3xx => false,
        .invalid_2xx_body, .request_build_error => false,
    };
}

pub fn decideFailure(kind: ServiceTaskFailureKind, attempt_index: u8, retry_limit: u8) ServiceTaskDecision {
    if (!isRetriableFailure(kind)) return .immediate_error;
    if (attempt_index <= retry_limit) return .retry;
    return .terminal_dlq;
}

pub fn buildIdempotencyKey(
    allocator: std.mem.Allocator,
    instance_id: Uuid,
    node_id: []const u8,
    token_id: []const u8,
) ![]u8 {
    const instance_hex = try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        instance_id[0], instance_id[1], instance_id[2], instance_id[3],
        instance_id[4], instance_id[5], instance_id[6], instance_id[7],
        instance_id[8], instance_id[9], instance_id[10], instance_id[11],
        instance_id[12], instance_id[13], instance_id[14], instance_id[15],
    });
    defer allocator.free(instance_hex);

    return std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ instance_hex, node_id, token_id });
}

fn parseHttpMethod(raw: []const u8) ?HttpMethod {
    if (std.mem.eql(u8, raw, "GET")) return .GET;
    if (std.mem.eql(u8, raw, "POST")) return .POST;
    if (std.mem.eql(u8, raw, "PUT")) return .PUT;
    if (std.mem.eql(u8, raw, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, raw, "DELETE")) return .DELETE;
    return null;
}

pub fn executeHttpRequest(
    allocator: std.mem.Allocator,
    cfg: ServiceTaskConfig,
    trace_id: []const u8,
    idempotency_key: []const u8,
) !HttpExecutionResult {
    try validateRenderedUrl(cfg.url_template);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Options.debug_io,
    };
    defer client.deinit();

    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(allocator);

    // Keep configured header name/value storage alive for the full request.
    var owned_header_storage = std.ArrayList([]const u8).empty;
    defer {
        for (owned_header_storage.items) |part| allocator.free(part);
        owned_header_storage.deinit(allocator);
    }

    try extra_headers.append(allocator, .{ .name = "x-trace-id", .value = trace_id });
    try extra_headers.append(allocator, .{ .name = "x-bpm-idempotency-key", .value = idempotency_key });
    try appendConfiguredHeaders(allocator, cfg.headers_json, &extra_headers, &owned_header_storage);

    var response_body = std.ArrayList(u8).empty;
    var response_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &response_body);
    defer response_writer.deinit();

    const method = switch (cfg.method) {
        .GET => std.http.Method.GET,
        .POST => std.http.Method.POST,
        .PUT => std.http.Method.PUT,
        .PATCH => std.http.Method.PATCH,
        .DELETE => std.http.Method.DELETE,
    };

    // Zig std HTTP client requires a non-null payload for methods that can
    // carry request bodies.
    const payload = switch (cfg.method) {
        .GET, .DELETE => null,
        else => cfg.body_template_json orelse "{}",
    };

    const result = try client.fetch(.{
        .location = .{ .url = cfg.url_template },
        .method = method,
        .payload = payload,
        .redirect_behavior = .unhandled,
        .response_writer = &response_writer.writer,
        .extra_headers = extra_headers.items,
    });

    var body_list = response_writer.toArrayList();
    return HttpExecutionResult{
        .status_code = @intFromEnum(result.status),
        .body = try body_list.toOwnedSlice(allocator),
    };
}

fn appendConfiguredHeaders(
    allocator: std.mem.Allocator,
    headers_json: ?[]const u8,
    out: *std.ArrayList(std.http.Header),
    owned_storage: *std.ArrayList([]const u8),
) !void {
    const raw = headers_json orelse return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const header_name = entry.key_ptr.*;
        if (header_name.len == 0) continue;

        const header_value = switch (entry.value_ptr.*) {
            .string => |value| value,
            else => continue,
        };
        if (header_value.len == 0) continue;

        const owned_name = try allocator.dupe(u8, header_name);
        errdefer allocator.free(owned_name);
        const owned_value = try allocator.dupe(u8, header_value);
        errdefer allocator.free(owned_value);

        try owned_storage.append(allocator, owned_name);
        try owned_storage.append(allocator, owned_value);
        try out.append(allocator, .{ .name = owned_name, .value = owned_value });
    }
}
