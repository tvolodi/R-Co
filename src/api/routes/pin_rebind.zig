//! PIN-05: HTTP handler for instance pin rebind.
//!
//! POST /api/v1/instances/:id/rebind-pins

const std = @import("std");
const pool_mod = @import("pool");
const pin_rebind_mod = @import("../../engine/pin_rebind.zig");
const pin_resolver_mod = @import("../../engine/pin_resolver.zig");

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8, message: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"{s}\",\"message\":\"{s}\"}}",
        .{ code, message },
    ) catch "{\"error\":\"internal_error\"}";
    return .{ .status_code = status, .body = body };
}

/// POST /api/v1/instances/:id/rebind-pins
///
/// Request body (application/json):
///   {
///     "entries": [ {"kind": "catalog_entry", "ref": "svc-a", "version": "200"}, ... ],
///     "reason": "<non-empty string>"
///   }
///
/// Success — HTTP 200:
///   { "instance_id": "<UUID>", "changes": [ {kind, ref, prior_version, new_version}, ... ] }
///
/// Error codes:
///   400  MALFORMED_JSON
///   404  INSTANCE_NOT_FOUND
///   409  INSTANCE_NOT_REBINDABLE   (PIN-05 AC3)
///   409  CONCURRENT_MODIFICATION
///   422  INVALID_INSTANCE_ID
///   422  UNKNOWN_PIN_REF           (PIN-05 AC2 — none of the entries applied)
///   422  INVALID_INPUT             (PIN-05 AC4 — missing reason / malformed entries)
///   500  INTERNAL_ERROR
///   503  SERVICE_UNAVAILABLE
pub fn handleRebindPins(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    actor_id: []const u8,
    instance_id_str: []const u8,
    body: []const u8,
) HandlerResult {
    const instance_id = parseUuid(instance_id_str) catch
        return errorResult(allocator, 422, "INVALID_INSTANCE_ID", "instance_id is not a valid UUID");

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const pa = parse_arena.allocator();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        pa,
        body,
        .{ .allocate = .alloc_always },
    ) catch return errorResult(allocator, 400, "MALFORMED_JSON", "Request body is not valid JSON");

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "MALFORMED_JSON", "Request body must be a JSON object"),
    };

    const reason: []const u8 = blk: {
        const r = obj.get("reason") orelse
            return errorResult(allocator, 422, "INVALID_INPUT", "reason is required");
        break :blk switch (r) {
            .string => |s| s,
            else => return errorResult(allocator, 422, "INVALID_INPUT", "reason must be a string"),
        };
    };

    const entries_val = obj.get("entries") orelse
        return errorResult(allocator, 422, "INVALID_INPUT", "entries is required");
    const entries_arr = switch (entries_val) {
        .array => |arr| arr,
        else => return errorResult(allocator, 422, "INVALID_INPUT", "entries must be an array"),
    };
    if (entries_arr.items.len == 0) {
        return errorResult(allocator, 422, "INVALID_INPUT", "entries must not be empty");
    }

    var entries = std.ArrayList(pin_rebind_mod.RebindEntry).empty;
    for (entries_arr.items) |item| {
        const eo = switch (item) {
            .object => |o| o,
            else => return errorResult(allocator, 422, "INVALID_INPUT", "each entry must be a JSON object"),
        };
        const kind_str: []const u8 = switch (eo.get("kind") orelse
            return errorResult(allocator, 422, "INVALID_INPUT", "entry.kind is required")) {
            .string => |s| s,
            else => return errorResult(allocator, 422, "INVALID_INPUT", "entry.kind must be a string"),
        };
        const kind = parsePinKind(kind_str) orelse
            return errorResult(allocator, 422, "INVALID_INPUT", "entry.kind must be one of catalog_entry, variable_schema, module");
        const ref: []const u8 = switch (eo.get("ref") orelse
            return errorResult(allocator, 422, "INVALID_INPUT", "entry.ref is required")) {
            .string => |s| s,
            else => return errorResult(allocator, 422, "INVALID_INPUT", "entry.ref must be a string"),
        };
        const version: []const u8 = switch (eo.get("version") orelse
            return errorResult(allocator, 422, "INVALID_INPUT", "entry.version is required")) {
            .string => |s| s,
            else => return errorResult(allocator, 422, "INVALID_INPUT", "entry.version must be a string"),
        };

        entries.append(pa, .{ .kind = kind, .ref = ref, .version = version }) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory");
    }

    const changes = pin_rebind_mod.rebindPins(allocator, pool, .{
        .instance_id = instance_id,
        .entries = entries.items,
        .reason = reason,
        .actor_id = actor_id,
    }) catch |err| switch (err) {
        pin_rebind_mod.RebindError.UnknownPinRef => return errorResult(allocator, 422, "UNKNOWN_PIN_REF", "A requested entry is not present in the instance's current effective pin set"),
        pin_rebind_mod.RebindError.InstanceNotRebindable => return errorResult(allocator, 409, "INSTANCE_NOT_REBINDABLE", "Instance is in a terminal state and cannot be rebound"),
        pin_rebind_mod.RebindError.InstanceNotFound => return errorResult(allocator, 404, "INSTANCE_NOT_FOUND", "Instance not found"),
        pin_rebind_mod.RebindError.InvalidInput => return errorResult(allocator, 422, "INVALID_INPUT", "Request body failed validation"),
        pin_rebind_mod.RebindError.ConcurrentModification => return errorResult(allocator, 409, "CONCURRENT_MODIFICATION", "Instance is locked by another transaction"),
        pin_rebind_mod.RebindError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        pin_rebind_mod.RebindError.TransactionFailed, pin_rebind_mod.RebindError.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
    };
    defer pin_rebind_mod.freeRebindChanges(allocator, changes);

    const inst_id_hex = uuidToHex(allocator, instance_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Failed to format instance ID");
    defer allocator.free(inst_id_hex);

    var buf = std.ArrayList(u8).empty;
    buf.appendSlice(allocator, "{\"instance_id\":\"") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, inst_id_hex) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    buf.appendSlice(allocator, "\",\"changes\":[") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    for (changes, 0..) |c, i| {
        if (i > 0) buf.append(allocator, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const entry = std.fmt.allocPrint(
            allocator,
            "{{\"kind\":\"{s}\",\"ref\":\"{s}\",\"prior_version\":\"{s}\",\"new_version\":\"{s}\"}}",
            .{ pinKindStr(c.kind), c.ref, c.prior_version, c.new_version },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        defer allocator.free(entry);
        buf.appendSlice(allocator, entry) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    buf.appendSlice(allocator, "]}") catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const out_body = buf.toOwnedSlice(allocator) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    return .{ .status_code = 200, .body = out_body };
}

fn parsePinKind(s: []const u8) ?pin_resolver_mod.PinKind {
    if (std.mem.eql(u8, s, "catalog_entry")) return .catalog_entry;
    if (std.mem.eql(u8, s, "variable_schema")) return .variable_schema;
    if (std.mem.eql(u8, s, "module")) return .module;
    return null;
}

fn pinKindStr(kind: pin_resolver_mod.PinKind) []const u8 {
    return switch (kind) {
        .catalog_entry => "catalog_entry",
        .variable_schema => "variable_schema",
        .module => "module",
    };
}

fn uuidToHex(allocator: std.mem.Allocator, uuid: pin_rebind_mod.Uuid) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

fn parseUuid(hex: []const u8) error{InvalidUuid}![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidUuid}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidUuid,
    };
}
