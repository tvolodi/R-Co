//! HTTP connector adapter for the effects subsystem — EXP-301
//!
//! Delivers one HTTP outbound effect using std.http.Client.
//! Injects the Idempotency-Key header using EffectSpec.effect_event_id.
//! No-op on secret_ref (deferred to EXP-501).
const std = @import("std");
const mod = @import("../mod.zig");

pub const EffectSpec = mod.EffectSpec;
pub const HttpEffectSpec = mod.HttpEffectSpec;
pub const EffectDeliveryResult = mod.EffectDeliveryResult;
pub const EffectDeliveryError = mod.EffectDeliveryError;

/// Deliver one HTTP effect. Caller owns response_body memory (via allocator).
/// Returns EffectDeliveryError.TransportError on any TCP/TLS failure.
pub fn deliver(
    allocator: std.mem.Allocator,
    spec: EffectSpec,
    http_spec: HttpEffectSpec,
) EffectDeliveryError!EffectDeliveryResult {
    // TODO(EXP-501): if http_spec.secret_ref != null, resolve secret before use.
    if (http_spec.secret_ref != null) {
        return error.SecretResolutionFailed;
    }

    const method = parseMethod(http_spec.method) orelse .POST;

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Options.debug_io,
    };
    defer client.deinit();

    // Build header list.
    var header_list = std.ArrayList(std.http.Header).empty;
    defer header_list.deinit(allocator);

    header_list.append(allocator, .{ .name = "content-type", .value = "application/json" }) catch return error.OutOfMemory;
    header_list.append(allocator, .{ .name = "Idempotency-Key", .value = spec.effect_event_id }) catch return error.OutOfMemory;

    // Merge caller-supplied headers from headers_json if present.
    if (http_spec.headers_json) |hdr_json| {
        appendParsedHeaders(allocator, &header_list, hdr_json) catch {};
    }

    var response_body = std.ArrayList(u8).empty;
    var response_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &response_body);
    defer response_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = http_spec.url },
        .method = method,
        .payload = http_spec.body_json orelse "{}",
        .response_writer = &response_writer.writer,
        .extra_headers = header_list.items,
    }) catch return error.TransportError;

    const body_slice = try response_body.toOwnedSlice(allocator);

    return EffectDeliveryResult{
        .status_code = @intFromEnum(result.status),
        .response_body = body_slice,
        .idempotency_key_sent = spec.effect_event_id,
    };
}

fn parseMethod(s: []const u8) ?std.http.Method {
    if (std.ascii.eqlIgnoreCase(s, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(s, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(s, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(s, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(s, "DELETE")) return .DELETE;
    return null;
}

fn appendParsedHeaders(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(std.http.Header),
    headers_json: []const u8,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, headers_json, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const v = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        try list.append(allocator, .{ .name = entry.key_ptr.*, .value = v });
    }
}
