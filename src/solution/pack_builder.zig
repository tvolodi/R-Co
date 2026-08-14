//! Pack builder — dependency-closure walker for SOL-01 export.
//!
//! Walks a serialised DefinitionGraph JSON to collect SERVICE_TASK service_ids
//! and HUMAN_TASK ROLE assignee names.  Pure: no I/O, no DB calls.
const std = @import("std");

// ---------------------------------------------------------------------------
// Graph walker
// ---------------------------------------------------------------------------

/// Walk the nodes array inside a graph JSON string, collecting service_ids
/// from SERVICE_TASK nodes and role names from HUMAN_TASK nodes that have
/// assignee_type = "ROLE".
///
/// All returned strings are allocated with `allocator`; caller owns them.
/// Errors during JSON parsing of individual node attributes are silently
/// skipped so a malformed attribute does not abort the entire export.
pub fn collectGraphDeps(
    allocator: std.mem.Allocator,
    graph_json: []const u8,
    service_ids_out: *std.ArrayList([]const u8),
    role_names_out: *std.ArrayList([]const u8),
) error{OutOfMemory}!void {
    if (graph_json.len == 0) return;

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        graph_json,
        .{ .allocate = .alloc_if_needed },
    ) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const nodes_val = obj.get("nodes") orelse return;
    const nodes = switch (nodes_val) {
        .array => |a| a,
        else => return,
    };

    for (nodes.items) |node_val| {
        const node = switch (node_val) {
            .object => |o| o,
            else => continue,
        };

        const node_type_val = node.get("node_type") orelse continue;
        const node_type = switch (node_type_val) {
            .string => |s| s,
            else => continue,
        };

        const attrs_val = node.get("attributes") orelse continue;
        const attrs_json = switch (attrs_val) {
            .string => |s| s,
            else => continue,
        };
        if (attrs_json.len == 0) continue;

        var attrs_parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            attrs_json,
            .{ .allocate = .alloc_if_needed },
        ) catch continue;
        defer attrs_parsed.deinit();

        const attrs = switch (attrs_parsed.value) {
            .object => |o| o,
            else => continue,
        };

        if (std.mem.eql(u8, node_type, "SERVICE_TASK")) {
            const sid_val = attrs.get("service_id") orelse continue;
            const sid = switch (sid_val) {
                .string => |s| s,
                else => continue,
            };
            if (sid.len == 0) continue;
            const owned = try allocator.dupe(u8, sid);
            try service_ids_out.append(allocator, owned);
        } else if (std.mem.eql(u8, node_type, "HUMAN_TASK")) {
            const atype_val = attrs.get("assignee_type") orelse continue;
            const atype = switch (atype_val) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, atype, "ROLE")) continue;
            const rname_val = attrs.get("role_name") orelse continue;
            const rname = switch (rname_val) {
                .string => |s| s,
                else => continue,
            };
            if (rname.len == 0) continue;
            const owned = try allocator.dupe(u8, rname);
            try role_names_out.append(allocator, owned);
        }
    }
}

// ---------------------------------------------------------------------------
// Dedup + sort helper
// ---------------------------------------------------------------------------

/// Return a deduplicated, alphabetically sorted copy of the input slice.
/// Caller owns the returned slice and every string in it.
/// Input strings are NOT freed.
pub fn dedupSorted(
    allocator: std.mem.Allocator,
    items: []const []const u8,
) error{OutOfMemory}![]const []const u8 {
    if (items.len == 0) return &.{};

    // Sort a working copy then dedup.
    const work = try allocator.alloc([]const u8, items.len);
    defer allocator.free(work);
    @memcpy(work, items);

    std.sort.pdq([]const u8, work, {}, lessThanStr);

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    var prev: ?[]const u8 = null;
    for (work) |s| {
        if (prev) |p| {
            if (std.mem.eql(u8, p, s)) continue;
        }
        const dup = try allocator.dupe(u8, s);
        try out.append(allocator, dup);
        prev = s;
    }

    return out.toOwnedSlice(allocator);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
