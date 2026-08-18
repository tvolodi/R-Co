//! QRY-05 — Entity field grant loader and field stripper.

const std = @import("std");
const db = @import("pool");

pub const FieldGrantSet = struct {
    /// Fields that are restricted and the caller HOLDS the grant for.
    granted_fields: []const []const u8,
    /// Fields that are restricted and the caller LACKS the grant for.
    denied_fields: []const []const u8,
};

pub fn loadFieldGrants(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    user_id: []const u8,
    entity_key: []const u8,
) error{ DbError, OutOfMemory }!FieldGrantSet {
    var rows = conn.query(
        allocator,
        \\SELECT
        \\    efr.field_name,
        \\    (ueg.id IS NOT NULL) AS caller_has_grant
        \\FROM entity_field_restrictions efr
        \\LEFT JOIN user_entity_grants ueg
        \\    ON ueg.user_id = $1::uuid
        \\   AND ueg.entity_key = efr.entity_key
        \\   AND ueg.grant_name = efr.required_grant
        \\WHERE efr.entity_key = $2
    ,
        &.{ user_id, entity_key },
    ) catch return error.DbError;
    defer rows.deinit();

    var granted: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (granted.items) |s| allocator.free(s);
        granted.deinit(allocator);
    }
    var denied: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (denied.items) |s| allocator.free(s);
        denied.deinit(allocator);
    }

    for (rows.rows) |row| {
        const field_name = row[0] orelse continue;
        const has_grant_str = row[1] orelse "f";
        const has_grant = std.mem.eql(u8, has_grant_str, "t") or std.mem.eql(u8, has_grant_str, "true");
        const name_copy = allocator.dupe(u8, field_name) catch return error.OutOfMemory;
        if (has_grant) {
            granted.append(allocator, name_copy) catch {
                allocator.free(name_copy);
                return error.OutOfMemory;
            };
        } else {
            denied.append(allocator, name_copy) catch {
                allocator.free(name_copy);
                return error.OutOfMemory;
            };
        }
    }

    return FieldGrantSet{
        .granted_fields = try granted.toOwnedSlice(allocator),
        .denied_fields = try denied.toOwnedSlice(allocator),
    };
}

pub fn deinitFieldGrantSet(allocator: std.mem.Allocator, gs: *FieldGrantSet) void {
    for (gs.granted_fields) |s| allocator.free(s);
    allocator.free(gs.granted_fields);
    for (gs.denied_fields) |s| allocator.free(s);
    allocator.free(gs.denied_fields);
}

fn appendJsonValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| {
            try buf.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.append(allocator, '"');
        },
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try buf.append(allocator, ',');
                try appendJsonValue(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, entry.key_ptr.*);
                try buf.appendSlice(allocator, "\":");
                try appendJsonValue(allocator, buf, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

/// Strip keys in denied_field_names from a JSON object string.
/// record_id is never stripped.
pub fn stripDeniedFields(
    allocator: std.mem.Allocator,
    row_json: []const u8,
    denied_field_names: []const []const u8,
) error{ OutOfMemory, MalformedJson }![]u8 {
    if (denied_field_names.len == 0) {
        return allocator.dupe(u8, row_json) catch return error.OutOfMemory;
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        row_json,
        .{ .allocate = .alloc_always },
    ) catch return error.MalformedJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.MalformedJson,
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    out.append(allocator, '{') catch return error.OutOfMemory;
    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        // never strip record_id
        if (!std.mem.eql(u8, key, "record_id")) {
            var should_deny = false;
            for (denied_field_names) |denied| {
                if (std.mem.eql(u8, key, denied)) {
                    should_deny = true;
                    break;
                }
            }
            if (should_deny) continue;
        }

        if (!first) out.append(allocator, ',') catch return error.OutOfMemory;
        first = false;

        // write "key":value
        out.append(allocator, '"') catch return error.OutOfMemory;
        out.appendSlice(allocator, key) catch return error.OutOfMemory;
        out.appendSlice(allocator, "\":") catch return error.OutOfMemory;

        appendJsonValue(allocator, &out, entry.value_ptr.*) catch return error.OutOfMemory;
    }
    out.append(allocator, '}') catch return error.OutOfMemory;

    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}
