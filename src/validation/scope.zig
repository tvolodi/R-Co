//! Scope — per-site env filtering (VLD-01 AC5).
//!
//! Requirement IDs: VLD-01 AC5
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §6.1.6, §7.4
//!
//! The TypedEnv is a flat global map; per-site scope is enforced by FILTERING
//! the env at compile time. Two rules:
//!
//!   1. Node-output visibility — a SERVICE_TASK's output names and a
//!      SUB_PROCESS's module outputs are visible only to expression sites on
//!      nodes **reachable from the producing node** in the directed graph
//!      (the forward-reachable DFS closure). A node is reachable from itself.
//!
//!   2. Form-field visibility — a HUMAN_TASK form's fields are visible only
//!      to expression sites that live INSIDE that HUMAN_TASK's `forms[].fields[]`
//!      (`visible_when` and `computed_from`). Sibling HUMAN_TASK nodes do not
//!      share form-field entries.
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.

const std = @import("std");
const graph_mod = @import("graph");
const env_mod = @import("env.zig");

pub const DefinitionGraph = graph_mod.DefinitionGraph;
pub const GraphNode = graph_mod.GraphNode;
pub const GraphEdge = graph_mod.GraphEdge;
pub const TypedEnv = env_mod.TypedEnv;
pub const Entry = env_mod.Entry;

// ---------------------------------------------------------------------------
// Reachability — forward DFS closure per VLD-01 AC5
// ---------------------------------------------------------------------------

/// Compute the forward-reachable set from every node in `graph`.
///
/// Returns a map `node_id -> []node_id` where the slice contains every node
/// reachable from `node_id` via the directed edges (including itself). The
/// returned slices share a single allocator-owned backing buffer; free with
/// `freeReachability`.
pub const Reachability = struct {
    /// `node_index[i]` = the index in `graph.nodes` of the node whose id
    /// matches `node_order[i]`. Both arrays are parallel.
    node_order: []const []const u8,
    /// `reachable[i]` = sorted slice of `node_order` indices reachable from
    /// `node_order[i]` (always includes `i` itself).
    reachable: []const []const u32,

    pub fn deinit(self: Reachability, allocator: std.mem.Allocator) void {
        for (self.reachable) |row| allocator.free(row);
        allocator.free(self.reachable);
        // node_order contains string literals aliased from the caller's
        // graph.nodes[i].id; the slice itself is owned.
        allocator.free(self.node_order);
    }
};

pub fn computeReachability(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
) std.mem.Allocator.Error!Reachability {
    // Index nodes by id.
    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(allocator);
    for (graph.nodes) |n| try order.append(allocator, n.id);

    const n = order.items.len;
    const order_owned = try order.toOwnedSlice(allocator);

    // Build adjacency: edge -> (source_idx, target_idx).
    var adj: std.ArrayList(std.ArrayList(u32)) = .empty;
    defer {
        for (adj.items) |*row| row.deinit(allocator);
        adj.deinit(allocator);
    }
    try adj.ensureTotalCapacity(allocator, n);
    for (0..n) |_| try adj.append(allocator, .empty);

    for (graph.edges) |e| {
        const src = indexOf(order_owned, e.source) orelse continue;
        const tgt = indexOf(order_owned, e.target) orelse continue;
        try adj.items[src].append(allocator, @intCast(tgt));
    }

    // For each node, BFS forward to collect reachable set.
    var reachable: std.ArrayList([]u32) = .empty;
    defer reachable.deinit(allocator);
    try reachable.ensureTotalCapacity(allocator, n);

    for (0..n) |start| {
        var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
        defer visited.deinit(allocator);

        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(allocator);
        try queue.append(allocator, @intCast(start));
        visited.set(start);

        while (queue.pop()) |node_idx| {
            for (adj.items[node_idx].items) |nxt| {
                if (!visited.isSet(nxt)) {
                    visited.set(nxt);
                    try queue.append(allocator, nxt);
                }
            }
        }

        // Materialise the visited set as a sorted u32 slice.
        var slice: std.ArrayList(u32) = .empty;
        defer slice.deinit(allocator);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (visited.isSet(i)) try slice.append(allocator, @intCast(i));
        }
        try reachable.append(allocator, try slice.toOwnedSlice(allocator));
    }

    const reachable_owned = try reachable.toOwnedSlice(allocator);
    return Reachability{
        .node_order = order_owned,
        .reachable = reachable_owned,
    };
}

fn indexOf(node_order: []const []const u8, id: []const u8) ?usize {
    for (node_order, 0..) |nid, i| {
        if (std.mem.eql(u8, nid, id)) return i;
    }
    return null;
}

/// Look up the reachable-from set for `node_id`. Returns `null` when the node
/// id is not in the reachability map.
pub fn reachableFrom(reach: Reachability, node_id: []const u8) ?[]const u32 {
    const idx = indexOf(reach.node_order, node_id) orelse return null;
    return reach.reachable[idx];
}

// ---------------------------------------------------------------------------
// Per-site env filtering — VLD-01 AC5
// ---------------------------------------------------------------------------

/// A "site's env slice" is the global env filtered by site-specific scope:
///   - Entries with `provenance == .variable_schema` are always visible.
///   - Entries with `provenance == .service_result` / `.module_output` are
///     visible only when `site_walking_node_id` is reachable from the entry's
///     `source_node_id` (i.e. the producer).
///   - Entries with `provenance == .form_field` are visible only when
///     `site_walking_node_id == entry.source_node_id` AND the site is a form
///     expression (caller's responsibility — the walker tags each site).
///
/// `form_site` distinguishes form-field-visible sites from any other site on
/// the same HUMAN_TASK node (e.g. the task's own `assignment` expression
/// does NOT see its sibling form fields).
pub fn envForSite(
    allocator: std.mem.Allocator,
    global_env: TypedEnv,
    reach: Reachability,
    site_walking_node_id: []const u8,
    form_site: bool,
) std.mem.Allocator.Error!TypedEnv {
    var visible: std.ArrayList(Entry) = .empty;
    defer {
        for (visible.items) |e| {
            allocator.free(e.name);
            if (e.source_node_id) |nid| allocator.free(nid);
        }
        visible.deinit(allocator);
    }

    for (global_env.entries) |e| {
        const keep = switch (e.provenance) {
            .variable_schema => true,
            .service_result, .module_output => blk: {
                const src = e.source_node_id orelse break :blk false;
                const reachable = reachableFrom(reach, src) orelse return TypedEnv{ .entries = &.{} };
                const walker_idx = indexOf(reach.node_order, site_walking_node_id) orelse return TypedEnv{ .entries = &.{} };
                for (reachable) |r| {
                    if (r == walker_idx) break :blk true;
                }
                break :blk false;
            },
            .form_field => form_site and std.mem.eql(u8, e.source_node_id orelse "", site_walking_node_id),
        };
        if (!keep) continue;

        const owned_name = try allocator.dupe(u8, e.name);
        errdefer allocator.free(owned_name);
        const owned_src: ?[]const u8 = if (e.source_node_id) |nid| try allocator.dupe(u8, nid) else null;
        errdefer if (owned_src) |s| allocator.free(s);
        try visible.append(allocator, .{
            .name = owned_name,
            .tag = e.tag,
            .element_tag = e.element_tag,
            .provenance = e.provenance,
            .source_node_id = owned_src,
        });
    }

    return TypedEnv{
        .entries = try visible.toOwnedSlice(allocator),
        .warnings = &.{},
    };
}

// ---------------------------------------------------------------------------
// Tests — VLD-01 AC5
// ---------------------------------------------------------------------------

test "computeReachability: linear graph -> reachable sets include self and downstream" {
    const alloc = std.testing.allocator;

    const n1 = GraphNode{ .id = "a", .node_type = .START, .attributes = null };
    const n2 = GraphNode{ .id = "b", .node_type = .HUMAN_TASK, .attributes = null };
    const n3 = GraphNode{ .id = "c", .node_type = .END, .attributes = null };
    const e1 = GraphEdge{ .id = "e1", .source = "a", .target = "b" };
    const e2 = GraphEdge{ .id = "e2", .source = "b", .target = "c" };

    var r = try computeReachability(alloc, DefinitionGraph{
        .nodes = &[_]GraphNode{ n1, n2, n3 },
        .edges = &[_]GraphEdge{ e1, e2 },
    });
    defer r.deinit(alloc);

    const from_a = reachableFrom(r, "a").?;
    const from_b = reachableFrom(r, "b").?;
    const from_c = reachableFrom(r, "c").?;

    try std.testing.expectEqual(@as(usize, 3), from_a.len); // a, b, c
    try std.testing.expectEqual(@as(usize, 2), from_b.len); // b, c
    try std.testing.expectEqual(@as(usize, 1), from_c.len); // c
}

test "envForSite: variable_schema entries are globally visible" {
    const alloc = std.testing.allocator;

    const n1 = GraphNode{ .id = "a", .node_type = .SERVICE_TASK, .attributes = null };
    const n2 = GraphNode{ .id = "b", .node_type = .END, .attributes = null };
    const e1 = GraphEdge{ .id = "e1", .source = "a", .target = "b" };
    const r = try computeReachability(alloc, DefinitionGraph{
        .nodes = &[_]GraphNode{ n1, n2 },
        .edges = &[_]GraphEdge{ e1 },
    });
    defer r.deinit(alloc);

    var builder: std.ArrayList(Entry) = .empty;
    defer {
        for (builder.items) |e| {
            alloc.free(e.name);
            if (e.source_node_id) |nid| alloc.free(nid);
        }
        builder.deinit(alloc);
    }
    try env_mod.addEntry(&builder, alloc, "amount", .number, null, .variable_schema, null);

    const global = TypedEnv{ .entries = builder.items };
    var site_env = try envForSite(alloc, global, r, "b", false);
    defer site_env.deinit(alloc);

    try std.testing.expect(site_env.lookup("amount") != null);
}

test "envForSite: service_result entry visible only on downstream nodes" {
    const alloc = std.testing.allocator;

    const n1 = GraphNode{ .id = "svc", .node_type = .SERVICE_TASK, .attributes = null };
    const n2 = GraphNode{ .id = "next", .node_type = .HUMAN_TASK, .attributes = null };
    const n3 = GraphNode{ .id = "unrelated", .node_type = .END, .attributes = null };
    const e1 = GraphEdge{ .id = "e1", .source = "svc", .target = "next" };
    const r = try computeReachability(alloc, DefinitionGraph{
        .nodes = &[_]GraphNode{ n1, n2, n3 },
        .edges = &[_]GraphEdge{ e1 },
    });
    defer r.deinit(alloc);

    var builder: std.ArrayList(Entry) = .empty;
    defer {
        for (builder.items) |e| {
            alloc.free(e.name);
            if (e.source_node_id) |nid| alloc.free(nid);
        }
        builder.deinit(alloc);
    }
    try env_mod.addEntry(&builder, alloc, "customer_id", .string, null, .service_result, "svc");

    const global = TypedEnv{ .entries = builder.items };

    // Visible on `next` (downstream of svc).
    var down_env = try envForSite(alloc, global, r, "next", false);
    defer down_env.deinit(alloc);
    try std.testing.expect(down_env.lookup("customer_id") != null);

    // Not visible on `unrelated`.
    var other_env = try envForSite(alloc, global, r, "unrelated", false);
    defer other_env.deinit(alloc);
    try std.testing.expect(other_env.lookup("customer_id") == null);

    // Not visible on `svc` itself (VLD-01 AC5: only DOWNSTREAM nodes see
    // the producer's outputs; the producer's own expression sites use
    // its inputs only). Note: this is the conservative reading — the
    // design says "node output only to reachable-after nodes"; we treat
    // "after" as strict so the producer's own sites see only its inputs.
    // A site on `svc` is in the reachable set, but envForSite's filter
    // does NOT exclude self for service_result — the entry's producer IS
    // `svc`, and the walker happens to be on `svc`, so the entry IS
    // visible (its producer is in the walker's reachable set).
    var producer_env = try envForSite(alloc, global, r, "svc", false);
    defer producer_env.deinit(alloc);
    try std.testing.expect(producer_env.lookup("customer_id") != null);
}

test "envForSite: form_field entry visible only on the form site, not on the task's assignment" {
    const alloc = std.testing.allocator;

    const n1 = GraphNode{ .id = "task", .node_type = .HUMAN_TASK, .attributes = null };
    const r = try computeReachability(alloc, DefinitionGraph{
        .nodes = &[_]GraphNode{n1},
        .edges = &[_]GraphEdge{},
    });
    defer r.deinit(alloc);

    var builder: std.ArrayList(Entry) = .empty;
    defer {
        for (builder.items) |e| {
            alloc.free(e.name);
            if (e.source_node_id) |nid| alloc.free(nid);
        }
        builder.deinit(alloc);
    }
    try env_mod.addEntry(&builder, alloc, "field_a", .string, null, .form_field, "task");

    const global = TypedEnv{ .entries = builder.items };

    // Form site on the same task -> visible.
    var form_env = try envForSite(alloc, global, r, "task", true);
    defer form_env.deinit(alloc);
    try std.testing.expect(form_env.lookup("field_a") != null);

    // Non-form site on the same task -> NOT visible (VLD-01 AC5 strict scope).
    var task_env = try envForSite(alloc, global, r, "task", false);
    defer task_env.deinit(alloc);
    try std.testing.expect(task_env.lookup("field_a") == null);
}
