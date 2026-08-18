//! RFC 8785 canonical JSON serialisation for SBX-02 spec_hash computation.

const std = @import("std");

/// Produce the RFC 8785 canonical JSON serialisation of a parsed JSON value.
/// Object keys are sorted lexicographically by Unicode code point.
/// No insignificant whitespace.
/// Returns a heap-allocated UTF-8 byte slice; caller frees.
pub fn canonicalise(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) error{ OutOfMemory, UnsupportedType }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try serialise(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn serialise(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) error{ OutOfMemory, UnsupportedType }!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |n| {
            const s = std.fmt.allocPrint(allocator, "{d}", .{n}) catch return error.OutOfMemory;
            defer allocator.free(s);
            try out.appendSlice(allocator, s);
        },
        .float => |f| {
            // RFC 8785 §3.2.2.3: use shortest representation, no trailing zeros
            const s = std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory;
            defer allocator.free(s);
            try out.appendSlice(allocator, s);
        },
        .number_string => |ns| {
            // Emit as-is (already canonical number string)
            try out.appendSlice(allocator, ns);
        },
        .string => |s| {
            const escaped = try escapeJsonString(allocator, s);
            defer allocator.free(escaped);
            try out.append(allocator, '"');
            try out.appendSlice(allocator, escaped);
            try out.append(allocator, '"');
        },
        .array => |arr| {
            try out.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(allocator, ',');
                try serialise(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |obj| {
            // Collect and sort keys
            const keys = obj.keys();
            const sorted_keys = try allocator.dupe([]const u8, keys);
            defer allocator.free(sorted_keys);
            std.sort.pdq([]const u8, sorted_keys, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);

            try out.append(allocator, '{');
            for (sorted_keys, 0..) |key, i| {
                if (i > 0) try out.append(allocator, ',');
                const escaped_key = try escapeJsonString(allocator, key);
                defer allocator.free(escaped_key);
                try out.append(allocator, '"');
                try out.appendSlice(allocator, escaped_key);
                try out.appendSlice(allocator, "\":");
                const v = obj.get(key) orelse unreachable;
                try serialise(allocator, out, v);
            }
            try out.append(allocator, '}');
        },
    }
}

fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\x08' => try buf.appendSlice(allocator, "\\b"),
            '\x0c' => try buf.appendSlice(allocator, "\\f"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const hex = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(hex);
                try buf.appendSlice(allocator, hex);
            },
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}
