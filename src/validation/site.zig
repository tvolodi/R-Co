//! Site enumeration — walk every expression site in a definition (VLD-02 §6.2, §7.3).
//!
//! Requirement IDs: VLD-02 AC1..AC5
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §4.2, §6.2.1, §7.3
//!
//! An "expression site" is the pair (graph-node-id, JSON-Pointer inside the
//! node attribute) plus the source slice and the *expected* result TypeTag.
//! The walker enumerates the six categories enumerated in the design:
//!
//!   1. Transition guards (PD-06 EXCLUSIVE_GATEWAY edge.condition)
//!      expected = bool
//!   2. Human-task assignment expression (PD-05 attributes.assignment)
//!      expected = string
//!   3. Timer delay expression (PD-05 attributes.delay)
//!      expected = timestamp
//!   4. Service-task input mapping (PD-05 attributes.input_mapping / value)
//!      expected = the corresponding input schema type (or .dyn for unknown)
//!   5. Form visible_when (PD-05 forms[i].fields[j].visible_when)
//!      expected = bool
//!   6. Form computed_from (PD-05 forms[i].fields[j].computed_from)
//!      expected = the field's declared type
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.

const std = @import("std");
const graph_mod = @import("graph");
const env_mod = @import("env.zig");

pub const DefinitionGraph = graph_mod.DefinitionGraph;
pub const GraphNode = graph_mod.GraphNode;
pub const GraphEdge = graph_mod.GraphEdge;
pub const NodeType = graph_mod.NodeType;
pub const TypeTag = env_mod.TypeTag;

/// One enumerated expression site. The walker owns every string slice; the
/// orchestrator is responsible for `freeSite` after the compile loop.
pub const Site = struct {
    node_id: []const u8,
    /// JSON-Pointer-like path inside the node attribute. Always non-empty.
    expression_path: []const u8,
    /// The literal CEL source slice (empty string allowed — VLD-02 AC5).
    source: []const u8,
    /// Per-site expected TypeTag (VLD-02 §6.2.1 table).
    expected_type: TypeTag,
    /// True only for form `visible_when` / `computed_from` sites on a
    /// HUMAN_TASK — enables the form-field scope rule in `scope.envForSite`.
    form_site: bool = false,
};

pub fn freeSite(allocator: std.mem.Allocator, s: Site) void {
    allocator.free(s.node_id);
    allocator.free(s.expression_path);
    allocator.free(s.source);
}

/// Free every Site's strings AND the backing slice. `items` must be an owned
/// slice — the result of `enumerateSites`' `toOwnedSlice` — never a live
/// ArrayList's `.items`.
///
/// Ownership contract:
///   - `enumerateSites(allocator, graph)` returns an *owned* `[]Site`: the
///     backing buffer is produced by `ArrayList.toOwnedSlice(allocator)`, and
///     every per-`Site` string (`node_id`, `expression_path`, `source`) is
///     allocator-owned (each is `allocator.dupe`'d or `allocPrint`'d by the
///     walker).
///   - `freeSite(allocator, s)` frees one `Site`'s three strings only. The
///     struct itself lives inside the caller-owned backing slice — `freeSite`
///     must NOT free the struct storage.
pub fn freeSites(allocator: std.mem.Allocator, items: []Site) void {
    for (items) |s| freeSite(allocator, s);
    allocator.free(items); // R1: free the toOwnedSlice backing
}

// ---------------------------------------------------------------------------
// Walker — public entry point
// ---------------------------------------------------------------------------

pub fn enumerateSites(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
) std.mem.Allocator.Error![]Site {
    var sites: std.ArrayList(Site) = .empty;
    errdefer {
        for (sites.items) |s| freeSite(allocator, s);
        sites.deinit(allocator);
    }

    for (graph.nodes) |node| {
        switch (node.node_type) {
            .EXCLUSIVE_GATEWAY => try enumerateGatewayEdges(allocator, graph, node, &sites),
            .HUMAN_TASK => try enumerateHumanTaskAttributes(allocator, node, &sites),
            .SERVICE_TASK => try enumerateServiceTaskAttributes(allocator, node, &sites),
            .TIMER => try enumerateTimerAttributes(allocator, node, &sites),
            else => {},
        }
    }

    return try sites.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Per-node-type enumeration
// ---------------------------------------------------------------------------

fn enumerateGatewayEdges(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
    gw: GraphNode,
    out: *std.ArrayList(Site),
) std.mem.Allocator.Error!void {
    var i: usize = 0;
    for (graph.edges) |edge| {
        if (!std.mem.eql(u8, edge.source, gw.id)) {
            i += 1;
            continue;
        }
        // Only edges leaving an EXCLUSIVE_GATEWAY carry a CEL guard (PD-06).
        const cond = edge.condition orelse {
            i += 1;
            continue;
        };
        const path = try std.fmt.allocPrint(allocator, "/edges/{d}/condition", .{i});
        errdefer allocator.free(path);
        const owned_source = try allocator.dupe(u8, cond);
        errdefer allocator.free(owned_source);
        // node_id is owned — caller will free it via freeSite. GraphNode.id is
        // typically a string literal in test fixtures, so we must dupe it here.
        const owned_node_id = try allocator.dupe(u8, gw.id);
        errdefer allocator.free(owned_node_id);
        try out.append(allocator, .{
            .node_id = owned_node_id,
            .expression_path = path,
            .source = owned_source,
            .expected_type = .bool,
            .form_site = false,
        });
        i += 1;
    }
}

fn enumerateHumanTaskAttributes(
    allocator: std.mem.Allocator,
    node: GraphNode,
    out: *std.ArrayList(Site),
) std.mem.Allocator.Error!void {
    const raw = node.attributes orelse return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const obj = parsed.value.object;

    // `assignment` expression (string value carrying a CEL role reference).
    if (obj.get("assignment")) |v| {
        if (v == .string and v.string.len > 0) {
            try pushAttributeSite(allocator, node.id, "/attributes/assignment", v.string, .string, false, out);
        }
    }

    // Forms
    if (obj.get("forms")) |forms_val| {
        if (forms_val == .array) {
            var fi: usize = 0;
            for (forms_val.array.items) |form_val| {
                if (form_val == .object) {
                    if (form_val.object.get("fields")) |fields_val| {
                        if (fields_val == .array) {
                            var fldi: usize = 0;
                            for (fields_val.array.items) |field_val| {
                                if (field_val == .object) {
                                    if (field_val.object.get("visible_when")) |vw| {
                                        if (vw == .string and vw.string.len > 0) {
                                            const path = try std.fmt.allocPrint(allocator, "/forms/{d}/fields/{d}/visible_when", .{ fi, fldi });
                                            errdefer allocator.free(path);
                                            const src = try allocator.dupe(u8, vw.string);
                                            errdefer allocator.free(src);
                                            const owned_node_id = try allocator.dupe(u8, node.id);
                                            errdefer allocator.free(owned_node_id);
                                            try out.append(allocator, .{
                                                .node_id = owned_node_id,
                                                .expression_path = path,
                                                .source = src,
                                                .expected_type = .bool,
                                                .form_site = true,
                                            });
                                        }
                                    }
                                    if (field_val.object.get("computed_from")) |cf| {
                                        if (cf == .string and cf.string.len > 0) {
                                            const path = try std.fmt.allocPrint(allocator, "/forms/{d}/fields/{d}/computed_from", .{ fi, fldi });
                                            errdefer allocator.free(path);
                                            const src = try allocator.dupe(u8, cf.string);
                                            errdefer allocator.free(src);
                                            // expected_type is the field's
                                            // declared type — fall back to
                                            // .dyn when the field is
                                            // un-mappable.
                                            const declared = field_val.object.get("type");
                                            const declared_name: []const u8 = if (declared) |d| d.string else "";
                                            const expected = env_mod.mapDeclaredTypeName(declared_name) orelse .dyn;
                                            const owned_node_id = try allocator.dupe(u8, node.id);
                                            errdefer allocator.free(owned_node_id);
                                            try out.append(allocator, .{
                                                .node_id = owned_node_id,
                                                .expression_path = path,
                                                .source = src,
                                                .expected_type = expected,
                                                .form_site = true,
                                            });
                                        }
                                    }
                                }
                                fldi += 1;
                            }
                        }
                    }
                }
                fi += 1;
            }
        }
    }
}

fn enumerateServiceTaskAttributes(
    allocator: std.mem.Allocator,
    node: GraphNode,
    out: *std.ArrayList(Site),
) std.mem.Allocator.Error!void {
    const raw = node.attributes orelse return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const obj = parsed.value.object;

    // `input_mapping` is a JSON object whose VALUES may be CEL expressions.
    if (obj.get("input_mapping")) |im_val| {
        if (im_val == .object) {
            for (im_val.object.keys(), im_val.object.values()) |key, val| {
                if (val == .string and val.string.len > 0) {
                    const path = try std.fmt.allocPrint(allocator, "/attributes/input_mapping/{s}", .{key});
                    errdefer allocator.free(path);
                    const src = try allocator.dupe(u8, val.string);
                    errdefer allocator.free(src);
                    const owned_node_id = try allocator.dupe(u8, node.id);
                    errdefer allocator.free(owned_node_id);
                    try out.append(allocator, .{
                        .node_id = owned_node_id,
                        .expression_path = path,
                        .source = src,
                        .expected_type = .dyn, // request_schema type lookup is VLD-04's concern
                        .form_site = false,
                    });
                }
            }
        }
    }
}

fn enumerateTimerAttributes(
    allocator: std.mem.Allocator,
    node: GraphNode,
    out: *std.ArrayList(Site),
) std.mem.Allocator.Error!void {
    const raw = node.attributes orelse return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const obj = parsed.value.object;
    if (obj.get("delay")) |v| {
        if (v == .string and v.string.len > 0) {
            try pushAttributeSite(allocator, node.id, "/attributes/delay", v.string, .timestamp, false, out);
        }
    }
}

fn pushAttributeSite(
    allocator: std.mem.Allocator,
    node_id: []const u8,
    path: []const u8,
    source: []const u8,
    expected: TypeTag,
    form_site: bool,
    out: *std.ArrayList(Site),
) std.mem.Allocator.Error!void {
    const owned_node_id = try allocator.dupe(u8, node_id);
    errdefer allocator.free(owned_node_id);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);
    try out.append(allocator, .{
        .node_id = owned_node_id,
        .expression_path = owned_path,
        .source = owned_source,
        .expected_type = expected,
        .form_site = form_site,
    });
}

// ---------------------------------------------------------------------------
// Helpers — empty-or-whitespace check (VLD-02 AC5)
// ---------------------------------------------------------------------------

/// Returns true when `s` is null or contains only whitespace.
pub fn isEmptyOrWhitespace(s: ?[]const u8) bool {
    const src = s orelse return true;
    for (src) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isEmptyOrWhitespace: null/empty/whitespace-only -> true" {
    try std.testing.expect(isEmptyOrWhitespace(null));
    try std.testing.expect(isEmptyOrWhitespace(""));
    try std.testing.expect(isEmptyOrWhitespace("   "));
    try std.testing.expect(isEmptyOrWhitespace("\t\n\r "));
}

test "isEmptyOrWhitespace: non-whitespace -> false" {
    try std.testing.expect(!isEmptyOrWhitespace("x"));
    try std.testing.expect(!isEmptyOrWhitespace(" x "));
    try std.testing.expect(!isEmptyOrWhitespace("a + b"));
}

test "enumerateSites: gateway edge condition -> one Site per edge" {
    const alloc = std.testing.allocator;
    const n1 = GraphNode{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .attributes = null };
    const n2 = GraphNode{ .id = "yes", .node_type = .END, .attributes = null };
    const n3 = GraphNode{ .id = "no", .node_type = .END, .attributes = null };
    const e1 = GraphEdge{ .id = "e1", .source = "gw", .target = "yes", .condition = "x > 0" };
    const e2 = GraphEdge{ .id = "e2", .source = "gw", .target = "no", .condition = "x <= 0" };

    const sites = try enumerateSites(alloc, DefinitionGraph{
        .nodes = &[_]GraphNode{ n1, n2, n3 },
        .edges = &[_]GraphEdge{ e1, e2 },
    });
    defer freeSites(alloc, sites);

    try std.testing.expectEqual(@as(usize, 2), sites.len);
    try std.testing.expect(std.mem.eql(u8, sites[0].node_id, "gw"));
    try std.testing.expectEqual(TypeTag.bool, sites[0].expected_type);
    try std.testing.expect(std.mem.eql(u8, sites[1].expression_path, "/edges/1/condition"));
}

test "enumerateSites: timer delay -> Site with expected_type timestamp" {
    const alloc = std.testing.allocator;
    const n1 = GraphNode{ .id = "t1", .node_type = .TIMER, .attributes = "{\"delay\":\"now() + 60000\"}" };

    const sites = try enumerateSites(alloc, DefinitionGraph{
        .nodes = &[_]GraphNode{n1},
        .edges = &[_]GraphEdge{},
    });
    defer freeSites(alloc, sites);

    try std.testing.expectEqual(@as(usize, 1), sites.len);
    try std.testing.expectEqual(TypeTag.timestamp, sites[0].expected_type);
}

test "enumerateSites: form visible_when and computed_from -> form_site=true" {
    const alloc = std.testing.allocator;
    const attrs =
        \\{"forms":[{"fields":[{"visible_when":"x > 0","computed_from":"y + 1","type":"integer"}]}]}
    ;
    const n1 = GraphNode{ .id = "task", .node_type = .HUMAN_TASK, .attributes = attrs };

    const sites = try enumerateSites(alloc, DefinitionGraph{
        .nodes = &[_]GraphNode{n1},
        .edges = &[_]GraphEdge{},
    });
    defer freeSites(alloc, sites);

    // Two sites: visible_when (bool) and computed_from (number).
    try std.testing.expectEqual(@as(usize, 2), sites.len);
    var saw_visibility = false;
    var saw_computed = false;
    for (sites) |s| {
        if (!s.form_site) continue;
        if (std.mem.eql(u8, s.expression_path, "/forms/0/fields/0/visible_when")) {
            try std.testing.expectEqual(TypeTag.bool, s.expected_type);
            saw_visibility = true;
        }
        if (std.mem.eql(u8, s.expression_path, "/forms/0/fields/0/computed_from")) {
            try std.testing.expectEqual(TypeTag.number, s.expected_type);
            saw_computed = true;
        }
    }
    try std.testing.expect(saw_visibility);
    try std.testing.expect(saw_computed);
}
