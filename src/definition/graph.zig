//! Graph structure validator — PD-02
//!
//! Pure module: no I/O, no DB calls, no logging, no clock reads.
//! The caller supplies an std.mem.Allocator used only for the returned
//! violations slice and the message strings within it.  All intermediate
//! computation uses fixed-size stack arrays bounded by MAX_NODES/MAX_EDGES.
//!
//! Design artefact: src/design/definition.md
const std = @import("std");

// ---------------------------------------------------------------------------
// Limits  (CHK-07, CHK-08)
// ---------------------------------------------------------------------------

/// Maximum node count per definition (CHK-07).
pub const MAX_NODES: usize = 500;
/// Maximum edge count per definition (CHK-08).
pub const MAX_EDGES: usize = 2000;

// ---------------------------------------------------------------------------
// Shared types  (also imported by store.zig)
// ---------------------------------------------------------------------------

/// Raw 16-byte UUID v4 representation.
pub const Uuid = [16]u8;

/// Every node type supported by the BPM graph model (PD-05).
pub const NodeType = enum {
    START,
    END,
    HUMAN_TASK,
    SERVICE_TASK,
    EXCLUSIVE_GATEWAY,
    PARALLEL_GATEWAY,
    TIMER,
    SUB_PROCESS,
};

/// Allowed values for `process_definitions.status` (PD-04).
pub const DefinitionStatus = enum {
    DRAFT,
    ACTIVE,
    DEPRECATED,
    ARCHIVED,
};

/// Single node in the definition graph.
pub const GraphNode = struct {
    /// Non-empty, unique within the definition.
    id: []const u8,
    node_type: NodeType,
    /// Display label — optional.
    label: ?[]const u8,
    /// JSON object string of type-specific attributes (PD-05). Null for node
    /// types with no required attributes (START, END, gateways).
    attributes: ?[]const u8 = null,
};

/// Directed edge connecting two nodes.
pub const GraphEdge = struct {
    /// Non-empty, unique within the definition.
    id: []const u8,
    /// Refers to an existing GraphNode.id.
    source: []const u8,
    /// Refers to an existing GraphNode.id.
    target: []const u8,
    /// CEL condition expression for EXCLUSIVE_GATEWAY routing (PD-06).
    /// MUST be present (non-null, non-empty) on every non-default outgoing
    /// edge from an EXCLUSIVE_GATEWAY. MUST be null on all other edges.
    condition: ?[]const u8,
    /// Optional CEL transform expression evaluated when traversing this edge (EXT-04).
    /// Null or empty/whitespace-only value is treated as a no-op transform.
    transform: ?[]const u8 = null,
    /// When true, this edge is the default (fallback) route from an
    /// EXCLUSIVE_GATEWAY. MUST NOT coexist with a non-null condition.
    /// At most one outgoing edge per EXCLUSIVE_GATEWAY may be default.
    is_default: bool = false,
};

/// Serialised form of the `graph` JSONB column: `{"nodes": [...], "edges": [...]}`.
pub const DefinitionGraph = struct {
    nodes: []const GraphNode,
    edges: []const GraphEdge,
};

/// In-memory representation of one row in `process_definitions`.
pub const Definition = struct {
    id: Uuid,
    name: []const u8,
    version: []const u8,
    description: ?[]const u8,
    status: DefinitionStatus,
    graph: DefinitionGraph,
    created_by: Uuid,
    /// UTC epoch microseconds (from TIMESTAMPTZ).
    created_at: i64,
    /// UTC epoch microseconds (from TIMESTAMPTZ).
    updated_at: i64,
    /// Null until definition enters ARCHIVED status.
    archived_at: ?i64,
    /// Optional process stage label (PD-07 ?stage= filter support). Null when unset.
    stage: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Validation types
// ---------------------------------------------------------------------------

pub const GraphError = error{
    /// Allocation of the violations slice or a message string failed.
    OutOfMemory,
};

/// A single structural violation found during graph validation (PD-02).
pub const Violation = struct {
    /// Short machine-readable code — one of the CHK-XX codes in the design.
    code: []const u8,
    /// Human-readable message. Names the offending node/edge ID where applicable.
    /// Allocated with the caller-supplied allocator; caller owns it.
    message: []const u8,
};

/// Validation outcome.  If `valid == false`, `violations` is non-empty.
/// The `violations` slice and every `.message` string within it are owned
/// by the caller (allocated with `allocator`).
pub const ValidationResult = struct {
    valid: bool,
    violations: []Violation,
};

// ---------------------------------------------------------------------------
// validateGraph  — public entry point
// ---------------------------------------------------------------------------

/// Validate the graph structure per PD-02.
///
/// ALL eight checks are executed and ALL violations are collected before
/// returning.  The function never exits early after the first failure.
///
/// Memory contract:
///   - The returned `ValidationResult.violations` slice is allocated with
///     `allocator`.
///   - Every `Violation.message` string is also allocated with `allocator`.
///   - On success the caller frees both with:
///       for (result.violations) |v| allocator.free(v.message);
///       allocator.free(result.violations);
///   - On GraphError.OutOfMemory nothing has been allocated.
pub fn validateGraph(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
) GraphError!ValidationResult {
    var violations: std.ArrayList(Violation) = .empty;
    // On any error exit: free all already-allocated message strings, then the
    // ArrayList backing buffer.
    errdefer {
        for (violations.items) |v| allocator.free(v.message);
        violations.deinit(allocator);
    }

    const n = graph.nodes.len;
    const e = graph.edges.len;

    // ── CHK-07: node count ≤ 500 ─────────────────────────────────────────
    if (n > MAX_NODES) {
        try addViolation(
            allocator,
            &violations,
            "NODE_LIMIT_EXCEEDED",
            "Node count {d} exceeds the maximum of {d}",
            .{ n, MAX_NODES },
        );
    }

    // ── CHK-08: edge count ≤ 2,000 ────────────────────────────────────────
    if (e > MAX_EDGES) {
        try addViolation(
            allocator,
            &violations,
            "EDGE_LIMIT_EXCEEDED",
            "Edge count {d} exceeds the maximum of {d}",
            .{ e, MAX_EDGES },
        );
    }

    // Clamp to safe bounds for all subsequent array indexing.
    // Violations for exceeding limits have already been recorded above.
    const n_safe = if (n > MAX_NODES) MAX_NODES else n;
    const e_safe = if (e > MAX_EDGES) MAX_EDGES else e;
    const nodes = graph.nodes[0..n_safe];
    const edges = graph.edges[0..e_safe];

    // ── CHK-05: no duplicate node IDs ────────────────────────────────────
    for (nodes, 0..) |node, i| {
        for (nodes[0..i]) |prev| {
            if (std.mem.eql(u8, node.id, prev.id)) {
                try addViolation(
                    allocator,
                    &violations,
                    "DUPLICATE_NODE_ID",
                    "Duplicate node ID '{s}'",
                    .{node.id},
                );
                break; // report each duplicated ID once per occurrence
            }
        }
    }

    // ── CHK-01: exactly one START node ───────────────────────────────────
    var start_count: usize = 0;
    for (nodes) |node| {
        if (node.node_type == .START) start_count += 1;
    }
    if (start_count == 0) {
        try addViolation(
            allocator,
            &violations,
            "MISSING_START_NODE",
            "No START node found in the definition graph",
            .{},
        );
    } else if (start_count > 1) {
        try addViolation(
            allocator,
            &violations,
            "MULTIPLE_START_NODES",
            "Found {d} START nodes; exactly one is required",
            .{start_count},
        );
    }

    // ── CHK-02: at least one END node ─────────────────────────────────────
    var end_count: usize = 0;
    for (nodes) |node| {
        if (node.node_type == .END) end_count += 1;
    }
    if (end_count == 0) {
        try addViolation(
            allocator,
            &violations,
            "MISSING_END_NODE",
            "No END node found in the definition graph",
            .{},
        );
    }

    // ── CHK-03: no dangling edges ─────────────────────────────────────────
    for (edges) |edge| {
        if (!nodeExists(nodes, edge.source)) {
            try addViolation(
                allocator,
                &violations,
                "DANGLING_EDGE",
                "Edge '{s}' has dangling source reference: node '{s}' does not exist",
                .{ edge.id, edge.source },
            );
        }
        if (!nodeExists(nodes, edge.target)) {
            try addViolation(
                allocator,
                &violations,
                "DANGLING_EDGE",
                "Edge '{s}' has dangling target reference: node '{s}' does not exist",
                .{ edge.id, edge.target },
            );
        }
    }

    // ── CHK-04: no isolated nodes ─────────────────────────────────────────
    // Build per-node edge presence flags from edges with valid endpoints.
    var has_incoming = [_]bool{false}**MAX_NODES;
    var has_outgoing = [_]bool{false}**MAX_NODES;
    for (edges) |edge| {
        if (nodeIndex(nodes, edge.source)) |si| has_outgoing[si] = true;
        if (nodeIndex(nodes, edge.target)) |ti| has_incoming[ti] = true;
    }
    for (nodes, 0..) |node, i| {
        const isolated = switch (node.node_type) {
            .START => !has_outgoing[i], // START needs ≥1 outgoing
            .END => !has_incoming[i], // END   needs ≥1 incoming
            else => !has_incoming[i] or !has_outgoing[i], // all others need both
        };
        if (isolated) {
            try addViolation(
                allocator,
                &violations,
                "ISOLATED_NODE",
                "Node '{s}' is isolated (insufficient incoming or outgoing edges for its type)",
                .{node.id},
            );
        }
    }

    // ── CHK-06: no cycles not through gateway nodes (DFS) ─────────────────
    // Build compact parallel arrays of (from_idx, to_idx) for edges whose
    // both endpoints exist in the node list.
    var adj_from = [_]u16{0}**MAX_EDGES;
    var adj_to = [_]u16{0}**MAX_EDGES;
    var adj_count: usize = 0;
    for (edges) |edge| {
        const si = nodeIndex(nodes, edge.source) orelse continue;
        const ti = nodeIndex(nodes, edge.target) orelse continue;
        adj_from[adj_count] = @as(u16, @intCast(si));
        adj_to[adj_count] = @as(u16, @intCast(ti));
        adj_count += 1;
    }

    var is_gateway = [_]bool{false}**MAX_NODES;
    for (nodes, 0..) |node, i| {
        if (node.node_type == .EXCLUSIVE_GATEWAY or
            node.node_type == .PARALLEL_GATEWAY)
        {
            is_gateway[i] = true;
        }
    }

    var visited = [_]bool{false}**MAX_NODES;
    var on_stack = [_]bool{false}**MAX_NODES;

    for (0..n_safe) |i| {
        if (!visited[i]) {
            try dfsVisit(
                @as(u16, @intCast(i)),
                adj_from[0..adj_count],
                adj_to[0..adj_count],
                nodes,
                &is_gateway,
                &visited,
                &on_stack,
                allocator,
                &violations,
            );
        }
    }

    // Transfer ownership of the violations slice to the caller.
    const owned = try violations.toOwnedSlice(allocator);
    return ValidationResult{
        .valid = owned.len == 0,
        .violations = owned,
    };
}

// ---------------------------------------------------------------------------
// DFS helper for CHK-06
// ---------------------------------------------------------------------------

/// Recursive DFS visit.  Detects back edges to nodes that are neither the
/// current edge's source nor target a gateway (CHK-06).
///
/// `visited`  — set to true on first entry to a node (never cleared).
/// `on_stack` — set true on entry, false on exit; tracks the recursion path.
fn dfsVisit(
    node_idx: u16,
    adj_from: []const u16,
    adj_to: []const u16,
    nodes: []const GraphNode,
    is_gateway: *const [MAX_NODES]bool,
    visited: *[MAX_NODES]bool,
    on_stack: *[MAX_NODES]bool,
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
) GraphError!void {
    visited[node_idx] = true;
    on_stack[node_idx] = true;

    for (0..adj_from.len) |e| {
        if (adj_from[e] != node_idx) continue;
        const t = adj_to[e];

        if (on_stack[t]) {
            // Back edge → cycle.  Permitted only when at least one endpoint
            // is a gateway (EXCLUSIVE_GATEWAY or PARALLEL_GATEWAY).
            if (!is_gateway[node_idx] and !is_gateway[t]) {
                try addViolation(
                    allocator,
                    violations,
                    "CYCLE_WITHOUT_GATEWAY",
                    "Cycle detected: edge from node '{s}' to node '{s}' " ++
                        "creates a cycle not passing through a gateway node",
                    .{ nodes[node_idx].id, nodes[t].id },
                );
            }
        } else if (!visited[t]) {
            try dfsVisit(
                t,
                adj_from,
                adj_to,
                nodes,
                is_gateway,
                visited,
                on_stack,
                allocator,
                violations,
            );
        }
    }

    on_stack[node_idx] = false;
}

// ---------------------------------------------------------------------------
// Violation builder helper
// ---------------------------------------------------------------------------

/// Allocate a formatted message and append a Violation to the list.
///
/// If violations.append fails (OOM), frees the allocated message before
/// propagating the error — ensuring no leak on the error path.
fn addViolation(
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    code: []const u8,
    comptime fmt_str: []const u8,
    args: anytype,
) GraphError!void {
    const msg = try std.fmt.allocPrint(allocator, fmt_str, args);
    errdefer allocator.free(msg);
    try violations.append(allocator, .{ .code = code, .message = msg });
}

// ---------------------------------------------------------------------------
// Node lookup helpers
// ---------------------------------------------------------------------------

fn nodeExists(nodes: []const GraphNode, id: []const u8) bool {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.id, id)) return true;
    }
    return false;
}

fn nodeIndex(nodes: []const GraphNode, id: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, id)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// validateNodeAttributes — PD-05 per-node-type attribute validation
// ---------------------------------------------------------------------------

/// Validate per-node-type mandatory attributes for all nodes in the graph.
///
/// Called after validateGraph() succeeds in the Store.create() path.
/// Same memory contract as validateGraph(): the caller supplies an allocator
/// used only for the output violations slice and message strings.
///
/// ALL nodes are checked; ALL violations are collected before returning.
/// Pure function: no I/O, no DB calls, no logging.
pub fn validateNodeAttributes(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
) GraphError!ValidationResult {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer {
        for (violations.items) |v| allocator.free(v.message);
        violations.deinit(allocator);
    }

    for (graph.nodes) |node| {
        switch (node.node_type) {
            .HUMAN_TASK => try checkHumanTask(allocator, &violations, node),
            .SERVICE_TASK => try checkServiceTask(allocator, &violations, node),
            .TIMER => try checkTimer(allocator, &violations, node),
            .SUB_PROCESS => try checkSubProcess(allocator, &violations, node),
            .START, .END, .EXCLUSIVE_GATEWAY, .PARALLEL_GATEWAY => {},
        }
    }

    const owned = try violations.toOwnedSlice(allocator);
    return ValidationResult{
        .valid = owned.len == 0,
        .violations = owned,
    };
}

fn checkHumanTask(
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    node: GraphNode,
) GraphError!void {
    const raw = node.attributes orelse "";
    if (raw.len == 0) {
        try addViolation(allocator, violations, "HUMAN_TASK_MISSING_ROLE", "Node '{s}' (HUMAN_TASK) is missing required attribute 'role'", .{node.id});
        return;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        try addViolation(allocator, violations, "HUMAN_TASK_MISSING_ROLE", "Node '{s}' (HUMAN_TASK) is missing required attribute 'role'", .{node.id});
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try addViolation(allocator, violations, "HUMAN_TASK_MISSING_ROLE", "Node '{s}' (HUMAN_TASK) is missing required attribute 'role'", .{node.id});
            return;
        },
    };

    const role_ok: bool = blk: {
        const v = obj.get("role") orelse break :blk false;
        break :blk switch (v) {
            .string => |s| s.len > 0,
            else => false,
        };
    };
    if (!role_ok) {
        try addViolation(allocator, violations, "HUMAN_TASK_MISSING_ROLE", "Node '{s}' (HUMAN_TASK) is missing required attribute 'role'", .{node.id});
    }
}

fn checkServiceTask(
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    node: GraphNode,
) GraphError!void {
    const raw = node.attributes orelse "";
    if (raw.len == 0) {
        try addViolation(allocator, violations, "SERVICE_TASK_MISSING_ENDPOINT", "Node '{s}' (SERVICE_TASK) is missing required attribute 'endpoint'", .{node.id});
        try addViolation(allocator, violations, "SERVICE_TASK_MISSING_TIMEOUT", "Node '{s}' (SERVICE_TASK) is missing required attribute 'timeout_ms'", .{node.id});
        return;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        try addViolation(allocator, violations, "SERVICE_TASK_MISSING_ENDPOINT", "Node '{s}' (SERVICE_TASK) is missing required attribute 'endpoint'", .{node.id});
        try addViolation(allocator, violations, "SERVICE_TASK_MISSING_TIMEOUT", "Node '{s}' (SERVICE_TASK) is missing required attribute 'timeout_ms'", .{node.id});
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try addViolation(allocator, violations, "SERVICE_TASK_MISSING_ENDPOINT", "Node '{s}' (SERVICE_TASK) is missing required attribute 'endpoint'", .{node.id});
            try addViolation(allocator, violations, "SERVICE_TASK_MISSING_TIMEOUT", "Node '{s}' (SERVICE_TASK) is missing required attribute 'timeout_ms'", .{node.id});
            return;
        },
    };

    const service_id = switch (obj.get("service_id") orelse .null) {
        .string => |s| std.mem.trim(u8, s, " \t\r\n"),
        .null => null,
        else => blk: {
            try addViolation(allocator, violations, "SERVICE_TASK_INVALID_SERVICE_ID", "Node '{s}' (SERVICE_TASK) attribute 'service_id' must be a non-empty string", .{node.id});
            break :blk null;
        },
    };
    const has_service_id = service_id != null and service_id.?.len > 0;
    if (obj.get("service_id") != null and !has_service_id) {
        try addViolation(allocator, violations, "SERVICE_TASK_INVALID_SERVICE_ID", "Node '{s}' (SERVICE_TASK) attribute 'service_id' must be a non-empty string", .{node.id});
    }

    // EXT-01 / ADP-08 compatibility:
    // - legacy nodes may use `endpoint` or `url`
    // - ADP-08 nodes may use `service_id`
    // At least one route selector must be present and non-empty.
    const endpoint_ok: bool = blk: {
        if (has_service_id) break :blk true;
        if (obj.get("endpoint")) |v| {
            if (switch (v) {
                .string => |s| s.len > 0,
                else => false,
            }) break :blk true;
        }
        if (obj.get("url")) |v| {
            if (switch (v) {
                .string => |s| s.len > 0,
                else => false,
            }) break :blk true;
        }
        break :blk false;
    };
    if (!endpoint_ok) {
        try addViolation(allocator, violations, "SERVICE_TASK_MISSING_ENDPOINT", "Node '{s}' (SERVICE_TASK) is missing required attribute 'endpoint'", .{node.id});
    }

    if (has_service_id) {
        if (!hasServiceCapability(allocator, obj, service_id.?)) {
            try addViolation(
                allocator,
                violations,
                "SERVICE_TASK_MISSING_SERVICE_CAPABILITY",
                "Node '{s}' (SERVICE_TASK) requires capability 'service:call:<service_id>' or wildcard 'service:call:*' when service_id is used",
                .{node.id},
            );
        }
    }

    // timeout_ms is optional in EXT-01 (default 30000).
    // If provided, it must be integer in [1, 300000].
    const timeout_entry = obj.get("timeout_ms");
    if (timeout_entry != null) {
        const timeout_ms: i64 = switch (timeout_entry.?) {
            .integer => |n| n,
            else => 0,
        };
        if (timeout_ms < 1 or timeout_ms > 300_000) {
            try addViolation(allocator, violations, "SERVICE_TASK_INVALID_TIMEOUT", "Node '{s}' (SERVICE_TASK) attribute 'timeout_ms' must be 1..300000, got {d}", .{ node.id, timeout_ms });
        }
    }

    // method is optional (runtime default), but if present must be one of the
    // explicitly supported verbs.
    if (obj.get("method")) |method_entry| {
        const method_ok = switch (method_entry) {
            .string => |s| std.mem.eql(u8, s, "GET") or std.mem.eql(u8, s, "POST") or std.mem.eql(u8, s, "PUT") or std.mem.eql(u8, s, "PATCH") or std.mem.eql(u8, s, "DELETE"),
            else => false,
        };
        if (!method_ok) {
            try addViolation(allocator, violations, "SERVICE_TASK_INVALID_METHOD", "Node '{s}' (SERVICE_TASK) attribute 'method' must be one of GET|POST|PUT|PATCH|DELETE", .{node.id});
        }
    }

    // retry_limit is optional (runtime default), but if present must fit u8 and
    // cannot be negative.
    if (obj.get("retry_limit")) |retry_entry| {
        const retry_ok = switch (retry_entry) {
            .integer => |n| n >= 0 and n <= 255,
            else => false,
        };
        if (!retry_ok) {
            try addViolation(allocator, violations, "SERVICE_TASK_INVALID_RETRY_LIMIT", "Node '{s}' (SERVICE_TASK) attribute 'retry_limit' must be an integer in 0..255", .{node.id});
        }
    }

    // headers is optional. If present, it must be an object containing only
    // non-empty string keys and non-empty string values.
    if (obj.get("headers")) |headers_entry| {
        switch (headers_entry) {
            .object => |headers_obj| {
                var it = headers_obj.iterator();
                while (it.next()) |entry| {
                    if (entry.key_ptr.*.len == 0) {
                        try addViolation(allocator, violations, "SERVICE_TASK_INVALID_HEADERS", "Node '{s}' (SERVICE_TASK) attribute 'headers' contains an empty header name", .{node.id});
                        break;
                    }
                    const value_ok = switch (entry.value_ptr.*) {
                        .string => |s| s.len > 0,
                        else => false,
                    };
                    if (!value_ok) {
                        try addViolation(allocator, violations, "SERVICE_TASK_INVALID_HEADERS", "Node '{s}' (SERVICE_TASK) attribute 'headers' must contain non-empty string values", .{node.id});
                        break;
                    }
                }
            },
            else => {
                try addViolation(allocator, violations, "SERVICE_TASK_INVALID_HEADERS", "Node '{s}' (SERVICE_TASK) attribute 'headers' must be an object", .{node.id});
            },
        }
    }
}

fn hasServiceCapability(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    service_id: []const u8,
) bool {
    const caps_entry = obj.get("capabilities") orelse return false;
    const caps = switch (caps_entry) {
        .array => |arr| arr,
        else => return false,
    };

    const expected = std.fmt.allocPrint(allocator, "service:call:{s}", .{service_id}) catch return false;
    defer allocator.free(expected);

    for (caps.items) |cap| {
        const cap_text = switch (cap) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, cap_text, expected) or std.mem.eql(u8, cap_text, "service:call:*")) {
            return true;
        }
    }

    return false;
}

fn checkTimer(
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    node: GraphNode,
) GraphError!void {
    const raw = node.attributes orelse "";
    if (raw.len == 0) {
        try addViolation(allocator, violations, "TIMER_MISSING_DURATION", "Node '{s}' (TIMER) is missing required attribute 'duration_iso8601'", .{node.id});
        return;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        try addViolation(allocator, violations, "TIMER_MISSING_DURATION", "Node '{s}' (TIMER) is missing required attribute 'duration_iso8601'", .{node.id});
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try addViolation(allocator, violations, "TIMER_MISSING_DURATION", "Node '{s}' (TIMER) is missing required attribute 'duration_iso8601'", .{node.id});
            return;
        },
    };

    const duration: ?[]const u8 = blk: {
        const v = obj.get("duration_iso8601") orelse break :blk null;
        break :blk switch (v) {
            .string => |s| s,
            else => null,
        };
    };

    if (duration == null or duration.?.len == 0) {
        try addViolation(allocator, violations, "TIMER_MISSING_DURATION", "Node '{s}' (TIMER) is missing required attribute 'duration_iso8601'", .{node.id});
    } else if (!isValidIso8601Duration(duration.?)) {
        try addViolation(allocator, violations, "TIMER_INVALID_DURATION", "Node '{s}' (TIMER) attribute 'duration_iso8601' is not a valid ISO 8601 duration: '{s}'", .{ node.id, duration.? });
    }
}

fn checkSubProcess(
    allocator: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    node: GraphNode,
) GraphError!void {
    const raw = node.attributes orelse "";
    if (raw.len == 0) {
        try addViolation(
            allocator,
            violations,
            "SUB_PROCESS_MISSING_CHILD_DEFINITION_ID",
            "Node '{s}' (SUB_PROCESS) is missing required attribute 'child_definition_id'",
            .{node.id},
        );
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        try addViolation(
            allocator,
            violations,
            "SUB_PROCESS_MISSING_CHILD_DEFINITION_ID",
            "Node '{s}' (SUB_PROCESS) is missing required attribute 'child_definition_id'",
            .{node.id},
        );
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            try addViolation(
                allocator,
                violations,
                "SUB_PROCESS_MISSING_CHILD_DEFINITION_ID",
                "Node '{s}' (SUB_PROCESS) is missing required attribute 'child_definition_id'",
                .{node.id},
            );
            return;
        },
    };

    const child_ok: bool = blk: {
        const v = obj.get("child_definition_id") orelse break :blk false;
        break :blk switch (v) {
            .string => |s| s.len > 0,
            else => false,
        };
    };

    if (!child_ok) {
        try addViolation(
            allocator,
            violations,
            "SUB_PROCESS_MISSING_CHILD_DEFINITION_ID",
            "Node '{s}' (SUB_PROCESS) is missing required attribute 'child_definition_id'",
            .{node.id},
        );
    }
}

/// Returns true iff s is a syntactically valid ISO 8601 duration.
///
/// Pattern: P[nY][nM][nW][nD][T[nH][nM][nS]]
/// Rules:
///   - Must start with 'P'.
///   - At least one numeric component designator must appear.
///   - Each component is a non-negative integer followed by a designator letter.
///   - 'T' separates date and time sections; time designators (H, M, S) must
///     follow 'T'.
///   - P0D (zero duration) is explicitly permitted.
///   - Fractional values are rejected.
fn isValidIso8601Duration(s: []const u8) bool {
    if (s.len < 2) return false;
    if (s[0] != 'P') return false;

    var i: usize = 1;
    var found_date: bool = false;
    var found_time: bool = false;
    var in_time: bool = false;

    while (i < s.len) {
        if (s[i] == 'T') {
            if (in_time) return false; // duplicate T
            in_time = true;
            i += 1;
            continue;
        }
        // Expect one or more decimal digits.
        const digit_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        if (i == digit_start) return false; // no digits before designator
        if (i >= s.len) return false; // no designator after digits
        const designator = s[i];
        i += 1;
        if (!in_time) {
            switch (designator) {
                'Y', 'M', 'W', 'D' => found_date = true,
                else => return false,
            }
        } else {
            switch (designator) {
                'H', 'M', 'S' => found_time = true,
                else => return false,
            }
        }
    }
    // T with no following time components is invalid.
    if (in_time and !found_time) return false;
    // At least one component must be present.
    return found_date or found_time;
}

// ---------------------------------------------------------------------------
// isValidCelSyntax — PD-06 minimal CEL structural check
// ---------------------------------------------------------------------------

/// Minimal CEL syntax check: catches obviously malformed expressions.
/// Does NOT perform full CEL grammar parsing — validates structural integrity only.
/// Pure function: no allocations, no I/O.
/// Returns false for:
///   - empty or whitespace-only strings
///   - unbalanced parentheses or brackets
///   - unmatched string delimiters (single or double quotes)
fn isValidCelSyntax(expr: []const u8) bool {
    var has_non_ws = false;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_single_quote = false;
    var in_double_quote = false;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const c = expr[i];
        if (!std.ascii.isWhitespace(c)) has_non_ws = true;
        // Handle escape sequences inside strings.
        if ((in_single_quote or in_double_quote) and c == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (in_double_quote) {
            if (c == '"') in_double_quote = false;
            continue;
        }
        if (in_single_quote) {
            if (c == '\'') in_single_quote = false;
            continue;
        }
        switch (c) {
            '"' => in_double_quote = true,
            '\'' => in_single_quote = true,
            '(' => paren_depth += 1,
            ')' => {
                paren_depth -= 1;
                if (paren_depth < 0) return false;
            },
            '[' => bracket_depth += 1,
            ']' => {
                bracket_depth -= 1;
                if (bracket_depth < 0) return false;
            },
            else => {},
        }
    }
    if (in_single_quote or in_double_quote) return false;
    if (paren_depth != 0 or bracket_depth != 0) return false;
    return has_non_ws;
}

// ---------------------------------------------------------------------------
// validateEdgeConditions — PD-06 edge condition validation
// ---------------------------------------------------------------------------

/// Validate PD-06 edge condition rules for all edges in the graph.
///
/// Called after validateNodeAttributes() in the Store.create() path.
/// Same memory contract as validateGraph() and validateNodeAttributes():
///   - The returned violations slice and every .message string are allocated
///     with the caller-supplied allocator.
///   - On GraphError.OutOfMemory nothing has been allocated.
///
/// ALL six CHK-EC checks are exhaustive — all violations are collected before
/// returning.  Pure function: no I/O, no DB calls, no clock reads.
pub fn validateEdgeConditions(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
) GraphError!ValidationResult {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer {
        for (violations.items) |v| allocator.free(v.message);
        violations.deinit(allocator);
    }

    const n_safe = if (graph.nodes.len > MAX_NODES) MAX_NODES else graph.nodes.len;
    const e_safe = if (graph.edges.len > MAX_EDGES) MAX_EDGES else graph.edges.len;
    const nodes = graph.nodes[0..n_safe];
    const edges = graph.edges[0..e_safe];

    // ── CHK-EC-05 pre-scan: count is_default=true edges per EXCLUSIVE_GATEWAY ──
    // Stack-allocated parallel arrays bounded by MAX_NODES.
    var gw_ids: [MAX_NODES][]const u8 = undefined;
    var gw_counts = [_]usize{0}**MAX_NODES;
    var gw_len: usize = 0;

    for (edges) |edge| {
        if (!edge.is_default) continue;
        const src_idx = nodeIndex(nodes, edge.source) orelse continue;
        if (nodes[src_idx].node_type != .EXCLUSIVE_GATEWAY) continue;
        var found = false;
        for (0..gw_len) |gi| {
            if (std.mem.eql(u8, gw_ids[gi], edge.source)) {
                gw_counts[gi] += 1;
                found = true;
                break;
            }
        }
        if (!found and gw_len < MAX_NODES) {
            gw_ids[gw_len] = edge.source;
            gw_counts[gw_len] = 1;
            gw_len += 1;
        }
    }

    // ── Per-edge checks ────────────────────────────────────────────────────
    for (edges) |edge| {
        const src_idx = nodeIndex(nodes, edge.source);
        const is_exclusive = if (src_idx) |si|
            nodes[si].node_type == .EXCLUSIVE_GATEWAY
        else
            false;

        if (!is_exclusive) {
            // CHK-EC-01: condition must be null on non-EXCLUSIVE_GATEWAY edges.
            if (edge.condition != null) {
                try addViolation(
                    allocator,
                    &violations,
                    "EDGE_CONDITION_NOT_ALLOWED",
                    "Edge '{s}' has a condition expression but its source node '{s}' is not an EXCLUSIVE_GATEWAY",
                    .{ edge.id, edge.source },
                );
            }
            // CHK-EC-02: is_default must be false on non-EXCLUSIVE_GATEWAY edges.
            if (edge.is_default) {
                try addViolation(
                    allocator,
                    &violations,
                    "EDGE_DEFAULT_NOT_ALLOWED",
                    "Edge '{s}' has is_default=true but its source node '{s}' is not an EXCLUSIVE_GATEWAY",
                    .{ edge.id, edge.source },
                );
            }
        } else {
            // CHK-EC-04: default edge from EXCLUSIVE_GATEWAY must not carry a condition.
            if (edge.is_default) {
                const cond_len = if (edge.condition) |c| c.len else 0;
                if (cond_len > 0) {
                    try addViolation(
                        allocator,
                        &violations,
                        "EDGE_DEFAULT_HAS_CONDITION",
                        "Edge '{s}' is the default outgoing edge but also carries a condition expression",
                        .{edge.id},
                    );
                }
            }

            // CHK-EC-03: non-default edge from EXCLUSIVE_GATEWAY must have a non-empty condition.
            if (!edge.is_default) {
                const cond_len = if (edge.condition) |c| c.len else 0;
                if (cond_len == 0) {
                    try addViolation(
                        allocator,
                        &violations,
                        "EDGE_MISSING_CONDITION",
                        "Edge '{s}' leaves EXCLUSIVE_GATEWAY '{s}' without a condition expression (and is not the default edge)",
                        .{ edge.id, edge.source },
                    );
                }
            }

            // CHK-EC-06: condition (if non-empty) must be syntactically valid CEL.
            if (edge.condition) |cond| {
                if (cond.len > 0 and !isValidCelSyntax(cond)) {
                    const max_display: usize = 80;
                    const display_len = if (cond.len > max_display) max_display else cond.len;
                    try addViolation(
                        allocator,
                        &violations,
                        "EDGE_INVALID_CEL",
                        "Edge '{s}' has a syntactically invalid CEL expression: '{s}'",
                        .{ edge.id, cond[0..display_len] },
                    );
                }
            }
        }
    }

    // ── CHK-EC-05 (post-loop): gateways with >1 default outgoing edge ─────
    for (0..gw_len) |gi| {
        if (gw_counts[gi] > 1) {
            try addViolation(
                allocator,
                &violations,
                "EDGE_MULTIPLE_DEFAULTS",
                "EXCLUSIVE_GATEWAY '{s}' has {d} default outgoing edges; at most one is permitted",
                .{ gw_ids[gi], gw_counts[gi] },
            );
        }
    }

    const owned = try violations.toOwnedSlice(allocator);
    return ValidationResult{
        .valid = owned.len == 0,
        .violations = owned,
    };
}

/// Validate EXT-04 edge transform expressions.
///
/// Rules:
/// - null transform is allowed (no-op)
/// - empty or whitespace-only transform is allowed (normalized no-op)
/// - non-empty transform must pass the same minimal CEL structural check used
///   for PD-06 condition validation
pub fn validateEdgeTransforms(
    allocator: std.mem.Allocator,
    graph: DefinitionGraph,
) GraphError!ValidationResult {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer {
        for (violations.items) |v| allocator.free(v.message);
        violations.deinit(allocator);
    }

    const e_safe = if (graph.edges.len > MAX_EDGES) MAX_EDGES else graph.edges.len;
    const edges = graph.edges[0..e_safe];

    for (edges) |edge| {
        const raw_transform = edge.transform orelse continue;
        const transform_expr = std.mem.trim(u8, raw_transform, " \t\r\n");
        if (transform_expr.len == 0) continue;

        if (!isValidCelSyntax(transform_expr)) {
            const max_display: usize = 80;
            const display_len = if (transform_expr.len > max_display) max_display else transform_expr.len;
            try addViolation(
                allocator,
                &violations,
                "EDGE_INVALID_TRANSFORM_CEL",
                "Edge '{s}' has a syntactically invalid transform CEL expression: '{s}'",
                .{ edge.id, transform_expr[0..display_len] },
            );
        }
    }

    const owned = try violations.toOwnedSlice(allocator);
    return ValidationResult{
        .valid = owned.len == 0,
        .violations = owned,
    };
}
