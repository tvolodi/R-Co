//! PD-06 syntax gate — VLD-02 AC4 (hard gate before semantic compile).
//!
//! Requirement IDs: VLD-02 AC4
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §6.2.4, §7.3
//!
//! The semantic compiler (`typecheck.zig`) only runs after every expression
//! site has cleared the existing PD-06 syntax check (`isValidCelSyntax` in
//! `src/definition/graph.zig`). When any site fails syntax, the validator
//! short-circuits the entire semantic loop and returns a `ValidationFailure`
//! whose `findings` slice is empty and whose `pd06_diagnostics` field carries
//! the verbatim PD-06 violation list (codes + messages) — the same shape
//! `graph.validateEdgeConditions`/`validateEdgeTransforms` already produce.
//!
//! This module is the "wide" PD-06 surface: it aggregates the existing edge
//! checks (PD-06 as-is) PLUS a per-site syntax check across the additional
//! sites enumerated by `site.zig` (transition guards, assignment, timer
//! delay, service-task input mapping, form visible_when, form computed_from).
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.

const std = @import("std");
const graph_mod = @import("graph");
const site_mod = @import("site.zig");

pub const DefinitionGraph = graph_mod.DefinitionGraph;
pub const Violation = graph_mod.Violation;
pub const ValidationResult = graph_mod.ValidationResult;
pub const Site = site_mod.Site;

// ---------------------------------------------------------------------------
// Pd06Diagnostic — verbatim carry-over from graph.validateEdgeConditions
// ---------------------------------------------------------------------------

/// A single PD-06 diagnostic, lifted verbatim from
/// `graph.validateEdgeConditions` / `validateEdgeTransforms`. The wire
/// format is the existing violation shape (`code` + `message`).
pub const Pd06Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    /// Optional node id — populated for the per-site checks below; null
    /// for the graph-level (validateEdgeConditions) checks.
    node_id: ?[]const u8 = null,
    /// Optional expression_path — populated for per-site checks; null for
    /// graph-level checks.
    expression_path: ?[]const u8 = null,
};

pub fn freePd06Diagnostic(allocator: std.mem.Allocator, d: Pd06Diagnostic) void {
    allocator.free(d.message);
    if (d.node_id) |n| allocator.free(n);
    if (d.expression_path) |p| allocator.free(p);
}

pub fn freePd06Diagnostics(allocator: std.mem.Allocator, items: []Pd06Diagnostic) void {
    for (items) |d| freePd06Diagnostic(allocator, d);
    allocator.free(items);
}

// ---------------------------------------------------------------------------
// runSyntaxCheck — aggregate PD-06 across graph + every site
// ---------------------------------------------------------------------------

pub const Pd06Error = error{ OutOfMemory };

/// Run PD-06 syntax check against:
///   1. The graph-level edge conditions and edge transforms (existing
///      `validateEdgeConditions` + `validateEdgeTransforms`).
///   2. The additional per-site expressions enumerated by `site.zig`.
/// Returns the *combined* list. When non-empty, the orchestrator short-circuits
/// the semantic compile loop and returns 422 with these diagnostics carried
/// verbatim.
///
/// `node_id_owned` / `expression_path_owned` are allocator-owned (the
/// caller's `Site` slices are duplicated so the resulting diagnostic is
/// independent of the input graph's lifetime).
pub fn runSyntaxCheck(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
    sites: []Site,
) Pd06Error![]Pd06Diagnostic {
    var diagnostics: std.ArrayList(Pd06Diagnostic) = .empty;
    errdefer {
        for (diagnostics.items) |d| freePd06Diagnostic(allocator, d);
        diagnostics.deinit(allocator);
    }

    // 1) Edge conditions + edge transforms.
    const cond = graph_mod.validateEdgeConditions(allocator, graph) catch
        return try diagnostics.toOwnedSlice(allocator);
    defer {
        for (cond.violations) |v| allocator.free(v.message);
        allocator.free(cond.violations);
    }
    for (cond.violations) |v| {
        try diagnostics.append(allocator, .{
            .code = v.code,
            .message = try allocator.dupe(u8, v.message),
            .node_id = null,
            .expression_path = null,
        });
    }

    const xform = graph_mod.validateEdgeTransforms(allocator, graph) catch
        return try diagnostics.toOwnedSlice(allocator);
    defer {
        for (xform.violations) |v| allocator.free(v.message);
        allocator.free(xform.violations);
    }
    for (xform.violations) |v| {
        try diagnostics.append(allocator, .{
            .code = v.code,
            .message = try allocator.dupe(u8, v.message),
            .node_id = null,
            .expression_path = null,
        });
    }

    // 2) Per-site syntax check across the additional sites.
    for (sites) |s| {
        if (graph_mod.isValidCelSyntax(s.source)) continue;
        // Skip empty/whitespace — VLD-02 AC5 handles those at the typecheck
        // boundary (EmptyExpression is a separate diagnostic category).
        if (site_mod.isEmptyOrWhitespace(s.source)) continue;

        const max_display: usize = 80;
        const display_len = if (s.source.len > max_display) max_display else s.source.len;
        const message = try std.fmt.allocPrint(
            allocator,
            "Node '{s}' at '{s}' has a syntactically invalid CEL expression: '{s}'",
            .{ s.node_id, s.expression_path, s.source[0..display_len] },
        );
        errdefer allocator.free(message);
        const owned_node = try allocator.dupe(u8, s.node_id);
        errdefer allocator.free(owned_node);
        const owned_path = try allocator.dupe(u8, s.expression_path);
        errdefer allocator.free(owned_path);
        try diagnostics.append(allocator, .{
            .code = "CEL_SYNTAX_INVALID",
            .message = message,
            .node_id = owned_node,
            .expression_path = owned_path,
        });
    }

    return try diagnostics.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "runSyntaxCheck: clean graph + empty sites -> no diagnostics" {
    const alloc = std.testing.allocator;
    const n1 = graph_mod.GraphNode{ .id = "a", .node_type = .START, .attributes = null };
    const n2 = graph_mod.GraphNode{ .id = "b", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "a", .target = "b" };

    const sites = try site_mod.enumerateSites(alloc, DefinitionGraph{
        .nodes = &[_]graph_mod.GraphNode{ n1, n2 },
        .edges = &[_]graph_mod.GraphEdge{ e1 },
    });
    defer site_mod.freeSites(alloc, sites);

    const diag = try runSyntaxCheck(alloc, DefinitionGraph{
        .nodes = &[_]graph_mod.GraphNode{ n1, n2 },
        .edges = &[_]graph_mod.GraphEdge{ e1 },
    }, sites);
    defer freePd06Diagnostics(alloc, diag);
    try std.testing.expectEqual(@as(usize, 0), diag.len);
}

test "runSyntaxCheck: malformed per-site expression -> CEL_SYNTAX_INVALID diagnostic" {
    const alloc = std.testing.allocator;
    const attrs = "{\"delay\":\"now( + 60000\"}"; // unbalanced paren
    const n1 = graph_mod.GraphNode{ .id = "t1", .node_type = .TIMER, .attributes = attrs };
    const n2 = graph_mod.GraphNode{ .id = "end", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "t1", .target = "end" };

    const sites = try site_mod.enumerateSites(alloc, DefinitionGraph{
        .nodes = &[_]graph_mod.GraphNode{ n1, n2 },
        .edges = &[_]graph_mod.GraphEdge{ e1 },
    });
    defer site_mod.freeSites(alloc, sites);

    const diag = try runSyntaxCheck(alloc, DefinitionGraph{
        .nodes = &[_]graph_mod.GraphNode{ n1, n2 },
        .edges = &[_]graph_mod.GraphEdge{ e1 },
    }, sites);
    defer freePd06Diagnostics(alloc, diag);

    try std.testing.expect(diag.len >= 1);
    var found = false;
    for (diag) |d| {
        if (std.mem.eql(u8, d.code, "CEL_SYNTAX_INVALID")) {
            found = true;
            try std.testing.expect(d.node_id != null);
            try std.testing.expect(d.expression_path != null);
        }
    }
    try std.testing.expect(found);
}

test "runSyntaxCheck: empty source skipped (VLD-02 AC5 handles those downstream)" {
    const alloc = std.testing.allocator;
    const attrs = "{\"delay\":\"\"}"; // empty
    const n1 = graph_mod.GraphNode{ .id = "t1", .node_type = .TIMER, .attributes = attrs };
    const n2 = graph_mod.GraphNode{ .id = "end", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "t1", .target = "end" };

    const sites = try site_mod.enumerateSites(alloc, DefinitionGraph{
        .nodes = &[_]graph_mod.GraphNode{ n1, n2 },
        .edges = &[_]graph_mod.GraphEdge{ e1 },
    });
    defer site_mod.freeSites(alloc, sites);

    const diag = try runSyntaxCheck(alloc, DefinitionGraph{
        .nodes = &[_]graph_mod.GraphNode{ n1, n2 },
        .edges = &[_]graph_mod.GraphEdge{ e1 },
    }, sites);
    defer freePd06Diagnostics(alloc, diag);

    try std.testing.expectEqual(@as(usize, 0), diag.len);
}
