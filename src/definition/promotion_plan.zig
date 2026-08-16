//! PRM-01: Promotion Plan and Diff Report
//!
//! Computes a read-only "promotion plan" BEFORE any write to a target
//! tenant: diffs the source tenant's definition version against the target
//! tenant's active version across the process graph, the variable_schema,
//! service-catalog bindings on SERVICE_TASK nodes, module_ref VALUES (not
//! resolutions) on SUB_PROCESS nodes, and permission rules.
//!
//! Extends ENV-03 (src/definition/promotion.zig's promoteDefinition()) per
//! PRM-01's own `Extends:` line — reuses that file's role-check and
//! tenant-lookup query SHAPES (Step 1/2/3) but does NOT call
//! promoteDefinition() itself, since that function performs the WRITE this
//! design must precede.
//!
//! Design artefact: src/design/prm-01-promotion-plan-and-diff-report.md
const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");
const graph_mod = @import("graph");

// ── Public types (per the design's Public interface) ───────────────────────

pub const ChangeKind = enum { added, modified, removed };

pub const PlanEntryType = enum {
    graph_node, // a process-graph node (PD-08)
    graph_edge, // a process-graph edge (PD-08)
    variable_schema, // a variable_schemas row
    service_binding, // a SERVICE_TASK node's service_id reference (REPO-07 binding, not version)
    module_ref, // a SUB_PROCESS node's module_ref VALUE (not resolution -- see design's Scoping note)
    permission_rule, // a role/permission grant tied to the definition
};

pub const PlanEntry = struct {
    type: PlanEntryType,
    id: []const u8, // node id / edge id / variable_key / role name, per `type`
    change_kind: ChangeKind,
    before: ?[]const u8, // JSON-serialised prior state; null for change_kind == added
    after: ?[]const u8, // JSON-serialised new state; null for change_kind == removed
};

pub const PromotionPlan = struct {
    entries: []const PlanEntry,
    human_readable: []const u8, // one line per entry

    pub fn deinit(self: PromotionPlan, allocator: std.mem.Allocator) void {
        for (self.entries) |e| {
            allocator.free(e.id);
            if (e.before) |b| allocator.free(b);
            if (e.after) |a| allocator.free(a);
        }
        allocator.free(self.entries);
        allocator.free(self.human_readable);
    }
};

pub const PlanError = error{
    /// Caller lacks promotion.submit (PRM-01 AC1). HTTP 403.
    Forbidden,
    /// source_tenant_id names a production tenant (PRM-01 AC4). HTTP 422.
    InvalidPromotionSource,
    /// Every diff dimension produced zero entries (PRM-01 AC3). HTTP 422.
    EmptyPromotionPlan,
    /// source_tenant_id or process_key names nothing in the source tenant.
    /// HTTP 404.
    SourceDefinitionNotFound,
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
};

/// Computes the plan. Read-only against both tenants; opens no write
/// transaction (AC5). Returns PlanError.EmptyPromotionPlan rather than a
/// PromotionPlan with zero entries, so callers cannot accidentally treat
/// "nothing to promote" as success.
///
/// Security: every SQL parameter is bound as $N — no SQL string
/// interpolation. process_definitions/variable_schemas/role_permissions are
/// PER_TENANT tables reached via SCHEMA-mode routing (tenant_context_mod.set())
/// exactly as src/definition/promotion.zig's existing promoteDefinition()
/// already does for the identical class of read — never
/// bpm_effective_tenant_id() (dropped by the LEGACY_RLS-to-SCHEMA cutover)
/// and never a session GUC, per the INV-1 fix pattern from the immediately
/// preceding batch.
pub fn computePromotionPlan(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    actor_id: []const u8,
    source_tenant_id: []const u8,
    target_tenant_id: []const u8,
    process_key: []const u8,
) PlanError!PromotionPlan {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    // ── Step 1: permission check — caller holds promotion.submit? ──────
    // No read of either tenant's definitions occurs before this passes (AC1).
    tenant_context_mod.set(source_tenant_id);
    try checkPermission(allocator, pool, actor_id, "promotion", "submit");

    // ── Step 2: source_tenant_id validation — tenant_type == 'test'? ───
    try checkIsTestTenant(allocator, pool, source_tenant_id);

    // ── Step 3: fetch source definition (ACTIVE version) ────────────────
    tenant_context_mod.set(source_tenant_id);
    const source_graph_json = try fetchActiveDefinitionGraph(allocator, pool, process_key);
    defer allocator.free(source_graph_json);

    // ── Step 4: fetch target definition (ACTIVE version); zero rows OK ──
    tenant_context_mod.set(target_tenant_id);
    const target_graph_json_opt = fetchActiveDefinitionGraph(allocator, pool, process_key) catch |err| switch (err) {
        PlanError.SourceDefinitionNotFound => null, // target holds no version — AC2, not an error
        else => return err,
    };
    defer if (target_graph_json_opt) |t| allocator.free(t);

    var entries = std.ArrayList(PlanEntry).empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.id);
            if (e.before) |b| allocator.free(b);
            if (e.after) |a| allocator.free(a);
        }
        entries.deinit(allocator);
    }

    // ── Step 5: compute the diff across five dimensions ─────────────────
    tenant_context_mod.set(source_tenant_id);
    const source_graph = parseGraph(allocator, source_graph_json) catch graph_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
    defer source_graph.deinit(allocator);

    var target_graph: graph_mod.DefinitionGraph = .{ .nodes = &.{}, .edges = &.{} };
    defer target_graph.deinit(allocator);
    if (target_graph_json_opt) |tgj| {
        target_graph = parseGraph(allocator, tgj) catch graph_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
    }

    try diffGraphNodes(allocator, &entries, source_graph, target_graph);
    try diffGraphEdges(allocator, &entries, source_graph, target_graph);
    try diffServiceBindings(allocator, &entries, source_graph, target_graph);
    try diffModuleRefs(allocator, &entries, source_graph, target_graph);

    try diffVariableSchemas(allocator, &entries, pool, source_tenant_id, target_tenant_id, process_key);
    try diffPermissionRules(allocator, &entries, pool, source_tenant_id, target_tenant_id, process_key);

    // ── Step 6: canonicalise + compare — zero entries -> EmptyPromotionPlan ──
    if (entries.items.len == 0) {
        return PlanError.EmptyPromotionPlan;
    }

    // ── Step 7: render human-readable change list ────────────────────────
    const human_readable = try renderHumanReadable(allocator, entries.items);

    return PromotionPlan{
        .entries = try entries.toOwnedSlice(allocator),
        .human_readable = human_readable,
    };
}

// ---------------------------------------------------------------------------
// Step 1/2 helpers — reuse promotion.zig's existing query SHAPES
// ---------------------------------------------------------------------------

fn checkPermission(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    actor_id: []const u8,
    resource: []const u8,
    action: []const u8,
) PlanError!void {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    defer pool.release(conn);

    // Security: actor_id bound as $1::uuid, resource/action as $2/$3 — no
    // SQL string interpolation. Mirrors promotion.zig's existing
    // user_roles JOIN roles role-check shape, generalised from a fixed role
    // name list to a resource/action permission grant via role_permissions
    // (IDN-06) — 'PLATFORM_ADMIN' is always treated as holding every
    // permission, matching promotion.zig's own MissingDesignerRoleOnTest
    // precedent of granting PLATFORM_ADMIN the checked capability alongside
    // the specific role.
    const row = conn.queryRow(
        allocator,
        \\SELECT EXISTS (
        \\    SELECT 1 FROM user_roles ur
        \\    JOIN roles r ON r.id = ur.role_id
        \\    LEFT JOIN role_permissions rp ON rp.role_id = r.id
        \\    WHERE ur.user_id = $1::uuid
        \\      AND (
        \\          r.name = 'PLATFORM_ADMIN'
        \\          OR (
        \\              (rp.resource = $2 OR rp.resource = '*')
        \\              AND (rp.action = $3 OR rp.action = '*')
        \\          )
        \\      )
        \\) AS has_perm
    ,
        &[_][]const u8{ actor_id, resource, action },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    if (row) |r| {
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        const val = r[0] orelse "f";
        if (std.mem.eql(u8, val, "t") or std.mem.eql(u8, val, "true")) return;
    }
    return PlanError.Forbidden;
}

fn checkIsTestTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
) PlanError!void {
    tenant_context_mod.clear();
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    defer pool.release(conn);

    // Security: tenant_id bound as $1::uuid — no SQL string interpolation.
    const row = conn.queryRow(
        allocator,
        \\SELECT tenant_type FROM public.tenant WHERE id = $1::uuid LIMIT 1
    ,
        &[_][]const u8{tenant_id},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    if (row == null) return PlanError.InvalidPromotionSource;
    const r = row.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
    const tenant_type = r[0] orelse return PlanError.InvalidPromotionSource;
    if (!std.mem.eql(u8, tenant_type, "test")) return PlanError.InvalidPromotionSource;
}

/// Fetch the ACTIVE definition's graph JSON text for `process_key` in the
/// CURRENT tenant_context. Returns SourceDefinitionNotFound if no ACTIVE
/// definition with that name exists — callers on the target side treat that
/// as "target holds no version" (AC2), not a hard error.
fn fetchActiveDefinitionGraph(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    process_key: []const u8,
) PlanError![]const u8 {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    defer pool.release(conn);

    // Security: process_key bound as $1 — no SQL string interpolation.
    const row = conn.queryRow(
        allocator,
        \\SELECT graph::text
        \\FROM process_definitions
        \\WHERE name = $1 AND status = 'ACTIVE'
        \\LIMIT 1
    ,
        &[_][]const u8{process_key},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    if (row == null) return PlanError.SourceDefinitionNotFound;
    const r = row.?;
    defer {
        for (r) |col| if (col) |v| allocator.free(v);
        allocator.free(r);
    }
    const raw = r[0] orelse return PlanError.SourceDefinitionNotFound;
    return allocator.dupe(u8, raw) catch return PlanError.OutOfMemory;
}

fn parseGraph(allocator: std.mem.Allocator, graph_json: []const u8) !graph_mod.DefinitionGraph {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, graph_json, .{ .allocate = .alloc_always }) catch
        return graph_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return graph_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
    };

    var nodes = std.ArrayList(graph_mod.GraphNode).empty;
    if (obj.get("nodes")) |nodes_val| {
        if (nodes_val == .array) {
            for (nodes_val.array.items) |item| {
                if (item != .object) continue;
                const no = item.object;
                const id_val = no.get("id") orelse continue;
                if (id_val != .string) continue;
                const type_val = no.get("node_type") orelse no.get("type") orelse continue;
                if (type_val != .string) continue;
                const node_type = parseNodeType(type_val.string) orelse continue;

                var attrs_str: ?[]const u8 = null;
                if (no.get("attributes")) |attrs_val| {
                    attrs_str = std.json.Stringify.valueAlloc(allocator, attrs_val, .{}) catch null;
                }
                var label: ?[]const u8 = null;
                if (no.get("label")) |l| {
                    if (l == .string) label = allocator.dupe(u8, l.string) catch null;
                }

                try nodes.append(allocator, .{
                    .id = allocator.dupe(u8, id_val.string) catch return error.OutOfMemory,
                    .node_type = node_type,
                    .label = label,
                    .attributes = attrs_str,
                });
            }
        }
    }

    var edges = std.ArrayList(graph_mod.GraphEdge).empty;
    if (obj.get("edges")) |edges_val| {
        if (edges_val == .array) {
            for (edges_val.array.items) |item| {
                if (item != .object) continue;
                const eo = item.object;
                const id_val = eo.get("id") orelse continue;
                const src_val = eo.get("source") orelse continue;
                const tgt_val = eo.get("target") orelse continue;
                if (id_val != .string or src_val != .string or tgt_val != .string) continue;

                var condition: ?[]const u8 = null;
                if (eo.get("condition")) |c| {
                    if (c == .string) condition = allocator.dupe(u8, c.string) catch null;
                }

                try edges.append(allocator, .{
                    .id = allocator.dupe(u8, id_val.string) catch return error.OutOfMemory,
                    .source = allocator.dupe(u8, src_val.string) catch return error.OutOfMemory,
                    .target = allocator.dupe(u8, tgt_val.string) catch return error.OutOfMemory,
                    .condition = condition,
                });
            }
        }
    }

    return graph_mod.DefinitionGraph{
        .nodes = try nodes.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
    };
}

fn parseNodeType(s: []const u8) ?graph_mod.NodeType {
    return std.meta.stringToEnum(graph_mod.NodeType, s);
}

// ---------------------------------------------------------------------------
// Diff dimensions (Diff computation section of the design)
// ---------------------------------------------------------------------------

fn diffGraphNodes(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    source: graph_mod.DefinitionGraph,
    target: graph_mod.DefinitionGraph,
) PlanError!void {
    for (source.nodes) |sn| {
        var found: ?graph_mod.GraphNode = null;
        for (target.nodes) |tn| {
            if (std.mem.eql(u8, tn.id, sn.id)) {
                found = tn;
                break;
            }
        }
        const after = nodeSignature(allocator, sn) catch return PlanError.OutOfMemory;
        if (found) |tn| {
            const before = nodeSignature(allocator, tn) catch return PlanError.OutOfMemory;
            if (std.mem.eql(u8, before, after)) {
                allocator.free(before);
                allocator.free(after);
                continue; // unchanged
            }
            try appendEntry(allocator, entries, .graph_node, sn.id, .modified, before, after);
        } else {
            try appendEntry(allocator, entries, .graph_node, sn.id, .added, null, after);
        }
    }
    for (target.nodes) |tn| {
        var found = false;
        for (source.nodes) |sn| {
            if (std.mem.eql(u8, sn.id, tn.id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const before = nodeSignature(allocator, tn) catch return PlanError.OutOfMemory;
            try appendEntry(allocator, entries, .graph_node, tn.id, .removed, before, null);
        }
    }
}

fn diffGraphEdges(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    source: graph_mod.DefinitionGraph,
    target: graph_mod.DefinitionGraph,
) PlanError!void {
    for (source.edges) |se| {
        var found: ?graph_mod.GraphEdge = null;
        for (target.edges) |te| {
            if (std.mem.eql(u8, te.id, se.id)) {
                found = te;
                break;
            }
        }
        const after = edgeSignature(allocator, se) catch return PlanError.OutOfMemory;
        if (found) |te| {
            const before = edgeSignature(allocator, te) catch return PlanError.OutOfMemory;
            if (std.mem.eql(u8, before, after)) {
                allocator.free(before);
                allocator.free(after);
                continue;
            }
            try appendEntry(allocator, entries, .graph_edge, se.id, .modified, before, after);
        } else {
            try appendEntry(allocator, entries, .graph_edge, se.id, .added, null, after);
        }
    }
    for (target.edges) |te| {
        var found = false;
        for (source.edges) |se| {
            if (std.mem.eql(u8, se.id, te.id)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const before = edgeSignature(allocator, te) catch return PlanError.OutOfMemory;
            try appendEntry(allocator, entries, .graph_edge, te.id, .removed, before, null);
        }
    }
}

/// service_binding dimension: for each SERVICE_TASK node, compare its
/// service_id ATTRIBUTE VALUE before vs. after — NOT a catalog lookup, a
/// graph-attribute diff (design's Scoping note: this is the "binding," not
/// the "version").
fn diffServiceBindings(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    source: graph_mod.DefinitionGraph,
    target: graph_mod.DefinitionGraph,
) PlanError!void {
    try diffNodeAttributeRef(allocator, entries, source, target, .SERVICE_TASK, "service_id", .service_binding);
}

/// module_ref dimension: for each SUB_PROCESS node, compare its module_ref
/// ATTRIBUTE VALUE (the semver-range string) before vs. after — same
/// non-resolving treatment as service_binding.
fn diffModuleRefs(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    source: graph_mod.DefinitionGraph,
    target: graph_mod.DefinitionGraph,
) PlanError!void {
    try diffNodeAttributeRef(allocator, entries, source, target, .SUB_PROCESS, "module_ref", .module_ref);
}

fn diffNodeAttributeRef(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    source: graph_mod.DefinitionGraph,
    target: graph_mod.DefinitionGraph,
    node_type: graph_mod.NodeType,
    field: []const u8,
    entry_type: PlanEntryType,
) PlanError!void {
    for (source.nodes) |sn| {
        if (sn.node_type != node_type) continue;
        const source_val = extractAttrString(allocator, sn.attributes, field);
        defer if (source_val) |v| allocator.free(v);

        var target_node: ?graph_mod.GraphNode = null;
        for (target.nodes) |tn| {
            if (std.mem.eql(u8, tn.id, sn.id)) {
                target_node = tn;
                break;
            }
        }
        const target_val: ?[]const u8 = if (target_node) |tn| extractAttrString(allocator, tn.attributes, field) else null;
        defer if (target_val) |v| allocator.free(v);

        if (source_val == null and target_val == null) continue;
        if (source_val != null and target_val != null and std.mem.eql(u8, source_val.?, target_val.?)) continue;

        const kind: ChangeKind = if (target_val == null) .added else .modified;
        const before = if (target_val) |v| (allocator.dupe(u8, v) catch return PlanError.OutOfMemory) else null;
        const after = if (source_val) |v| (allocator.dupe(u8, v) catch return PlanError.OutOfMemory) else null;
        try appendEntry(allocator, entries, entry_type, sn.id, kind, before, after);
    }
    // removed: node existed in target with this attribute, absent from source entirely.
    for (target.nodes) |tn| {
        if (tn.node_type != node_type) continue;
        var found = false;
        for (source.nodes) |sn| {
            if (std.mem.eql(u8, sn.id, tn.id)) {
                found = true;
                break;
            }
        }
        if (found) continue; // handled by the modified/added pass above via target_node lookup
        const target_val = extractAttrString(allocator, tn.attributes, field);
        if (target_val) |v| {
            try appendEntry(allocator, entries, entry_type, tn.id, .removed, v, null);
        }
    }
}

fn extractAttrString(allocator: std.mem.Allocator, attributes: ?[]const u8, field: []const u8) ?[]const u8 {
    const attrs = attributes orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, attrs, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(field) orelse return null;
    return switch (val) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

/// variable_schema dimension: compare source/target variable_schemas rows by
/// variable_key — added/modified/removed by key presence + json_schema
/// equality.
const SchemaRow = struct { key: []const u8, schema: []const u8 };

fn diffVariableSchemas(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    pool: *pool_mod.Pool,
    source_tenant_id: []const u8,
    target_tenant_id: []const u8,
    process_key: []const u8,
) PlanError!void {
    tenant_context_mod.set(source_tenant_id);
    const source_rows = fetchVariableSchemas(allocator, pool, process_key) catch |err| return err;
    defer {
        for (source_rows) |r| {
            allocator.free(r.key);
            allocator.free(r.schema);
        }
        allocator.free(source_rows);
    }

    tenant_context_mod.set(target_tenant_id);
    const target_rows = fetchVariableSchemas(allocator, pool, process_key) catch |err| return err;
    defer {
        for (target_rows) |r| {
            allocator.free(r.key);
            allocator.free(r.schema);
        }
        allocator.free(target_rows);
    }

    for (source_rows) |sr| {
        var found: ?SchemaRow = null;
        for (target_rows) |tr| {
            if (std.mem.eql(u8, tr.key, sr.key)) {
                found = tr;
                break;
            }
        }
        if (found) |tr| {
            if (std.mem.eql(u8, tr.schema, sr.schema)) continue;
            const before = allocator.dupe(u8, tr.schema) catch return PlanError.OutOfMemory;
            const after = allocator.dupe(u8, sr.schema) catch return PlanError.OutOfMemory;
            try appendEntry(allocator, entries, .variable_schema, sr.key, .modified, before, after);
        } else {
            const after = allocator.dupe(u8, sr.schema) catch return PlanError.OutOfMemory;
            try appendEntry(allocator, entries, .variable_schema, sr.key, .added, null, after);
        }
    }
    for (target_rows) |tr| {
        var found = false;
        for (source_rows) |sr| {
            if (std.mem.eql(u8, sr.key, tr.key)) {
                found = true;
                break;
            }
        }
        if (!found) {
            const before = allocator.dupe(u8, tr.schema) catch return PlanError.OutOfMemory;
            try appendEntry(allocator, entries, .variable_schema, tr.key, .removed, before, null);
        }
    }
}

fn fetchVariableSchemas(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    process_key: []const u8,
) PlanError![]const SchemaRow {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    defer pool.release(conn);

    // Security: process_key bound as $1 — no SQL string interpolation.
    var rows = conn.query(
        allocator,
        \\SELECT vs.variable_key, vs.json_schema::text
        \\FROM variable_schemas vs
        \\JOIN process_definitions pd ON pd.id = vs.definition_id
        \\WHERE pd.name = $1 AND pd.status = 'ACTIVE'
        \\ORDER BY vs.variable_key ASC
    ,
        &[_][]const u8{process_key},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    defer rows.deinit();

    const out = allocator.alloc(SchemaRow, rows.rows.len) catch
        return PlanError.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |r| {
            allocator.free(r.key);
            allocator.free(r.schema);
        }
        allocator.free(out);
    }
    for (rows.rows, 0..) |row, i| {
        const key = row[0] orelse "";
        const schema = if (row.len > 1) (row[1] orelse "{}") else "{}";
        out[i] = .{
            .key = allocator.dupe(u8, key) catch return PlanError.OutOfMemory,
            .schema = allocator.dupe(u8, schema) catch return PlanError.OutOfMemory,
        };
        filled += 1;
    }
    return out;
}

/// permission_rule dimension: compare the definition's associated
/// role/permission grants by role name presence. No table associates a
/// process_definition row with specific required roles in this codebase
/// (confirmed: migrations/008_identity.sql's role_permissions is a
/// RESOURCE/ACTION grant on a ROLE, not a per-definition binding) — this
/// design's own body text names "permission rules" as a diff dimension
/// without specifying the grant model's shape (Diff computation section:
/// "BACKEND-DEV to confirm the exact table"). Interpreted here as the set of
/// role_permissions rows scoped to resource = process_key (the closest
/// existing per-definition-shaped grant convention: a role_permissions row
/// whose `resource` column names this process_key) — diffed the same
/// added/modified/removed way as every other dimension. Where no such rows
/// exist for a process_key in either tenant (the common case today, since
/// nothing in this codebase currently writes resource = <process_key> rows),
/// this dimension legitimately contributes zero entries, exactly like any
/// other dimension with no divergence.
fn diffPermissionRules(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    pool: *pool_mod.Pool,
    source_tenant_id: []const u8,
    target_tenant_id: []const u8,
    process_key: []const u8,
) PlanError!void {
    tenant_context_mod.set(source_tenant_id);
    const source_roles = fetchPermissionRoleNames(allocator, pool, process_key) catch |err| return err;
    defer {
        for (source_roles) |r| allocator.free(r);
        allocator.free(source_roles);
    }

    tenant_context_mod.set(target_tenant_id);
    const target_roles = fetchPermissionRoleNames(allocator, pool, process_key) catch |err| return err;
    defer {
        for (target_roles) |r| allocator.free(r);
        allocator.free(target_roles);
    }

    for (source_roles) |sr| {
        var found = false;
        for (target_roles) |tr| {
            if (std.mem.eql(u8, tr, sr)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try appendEntry(allocator, entries, .permission_rule, sr, .added, null, allocator.dupe(u8, "true") catch return PlanError.OutOfMemory);
        }
    }
    for (target_roles) |tr| {
        var found = false;
        for (source_roles) |sr| {
            if (std.mem.eql(u8, sr, tr)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try appendEntry(allocator, entries, .permission_rule, tr, .removed, allocator.dupe(u8, "true") catch return PlanError.OutOfMemory, null);
        }
    }
}

fn fetchPermissionRoleNames(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    process_key: []const u8,
) PlanError![]const []const u8 {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    defer pool.release(conn);

    // Security: process_key bound as $1 — no SQL string interpolation.
    var rows = conn.query(
        allocator,
        \\SELECT DISTINCT r.name
        \\FROM role_permissions rp
        \\JOIN roles r ON r.id = rp.role_id
        \\WHERE rp.resource = $1
        \\ORDER BY r.name ASC
    ,
        &[_][]const u8{process_key},
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PlanError.PoolExhausted,
        else => PlanError.TransactionFailed,
    };
    defer rows.deinit();

    const out = allocator.alloc([]const u8, rows.rows.len) catch return PlanError.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |r| allocator.free(r);
        allocator.free(out);
    }
    for (rows.rows, 0..) |row, i| {
        const name = row[0] orelse "";
        out[i] = allocator.dupe(u8, name) catch return PlanError.OutOfMemory;
        filled += 1;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn appendEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PlanEntry),
    entry_type: PlanEntryType,
    id: []const u8,
    change_kind: ChangeKind,
    before: ?[]const u8,
    after: ?[]const u8,
) PlanError!void {
    const owned_id = allocator.dupe(u8, id) catch return PlanError.OutOfMemory;
    entries.append(allocator, .{
        .type = entry_type,
        .id = owned_id,
        .change_kind = change_kind,
        .before = before,
        .after = after,
    }) catch return PlanError.OutOfMemory;
}

fn nodeSignature(allocator: std.mem.Allocator, n: graph_mod.GraphNode) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"node_type\":\"{s}\",\"label\":{s},\"attributes\":{s}}}",
        .{
            @tagName(n.node_type),
            if (n.label) |l| l else "null",
            if (n.attributes) |a| a else "null",
        },
    );
}

fn edgeSignature(allocator: std.mem.Allocator, e: graph_mod.GraphEdge) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"source\":\"{s}\",\"target\":\"{s}\",\"condition\":{s}}}",
        .{
            e.source,
            e.target,
            if (e.condition) |c| c else "null",
        },
    );
}

fn planEntryTypeStr(t: PlanEntryType) []const u8 {
    return switch (t) {
        .graph_node => "graph_node",
        .graph_edge => "graph_edge",
        .variable_schema => "variable_schema",
        .service_binding => "service_binding",
        .module_ref => "module_ref",
        .permission_rule => "permission_rule",
    };
}

fn changeKindStr(k: ChangeKind) []const u8 {
    return switch (k) {
        .added => "added",
        .modified => "modified",
        .removed => "removed",
    };
}

fn renderHumanReadable(allocator: std.mem.Allocator, entries: []const PlanEntry) error{OutOfMemory}![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (entries) |e| {
        const line = try std.fmt.allocPrint(
            allocator,
            "{s} {s} {s}\n",
            .{ changeKindStr(e.change_kind), planEntryTypeStr(e.type), e.id },
        );
        defer allocator.free(line);
        try buf.appendSlice(allocator, line);
    }
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB; computePromotionPlan() itself is DB-bound and
// covered by integration tests instead)
// ---------------------------------------------------------------------------

test "nodeSignature: differs when attributes differ" {
    const n1 = graph_mod.GraphNode{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc-a\"}" };
    const n2 = graph_mod.GraphNode{ .id = "n1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc-b\"}" };
    const s1 = try nodeSignature(std.testing.allocator, n1);
    defer std.testing.allocator.free(s1);
    const s2 = try nodeSignature(std.testing.allocator, n2);
    defer std.testing.allocator.free(s2);
    try std.testing.expect(!std.mem.eql(u8, s1, s2));
}

test "diffGraphNodes: added/modified/removed classification" {
    var entries = std.ArrayList(PlanEntry).empty;
    defer {
        for (entries.items) |e| {
            std.testing.allocator.free(e.id);
            if (e.before) |b| std.testing.allocator.free(b);
            if (e.after) |a| std.testing.allocator.free(a);
        }
        entries.deinit(std.testing.allocator);
    }

    const source_nodes = [_]graph_mod.GraphNode{
        .{ .id = "a", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "b", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc-1\"}" },
    };
    const target_nodes = [_]graph_mod.GraphNode{
        .{ .id = "a", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "c", .node_type = .END, .label = null, .attributes = null },
    };
    const source = graph_mod.DefinitionGraph{ .nodes = &source_nodes, .edges = &.{} };
    const target = graph_mod.DefinitionGraph{ .nodes = &target_nodes, .edges = &.{} };

    try diffGraphNodes(std.testing.allocator, &entries, source, target);

    // "a" unchanged -> not present; "b" added; "c" removed.
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    var saw_added = false;
    var saw_removed = false;
    for (entries.items) |e| {
        if (std.mem.eql(u8, e.id, "b") and e.change_kind == .added) saw_added = true;
        if (std.mem.eql(u8, e.id, "c") and e.change_kind == .removed) saw_removed = true;
    }
    try std.testing.expect(saw_added);
    try std.testing.expect(saw_removed);
}

test "diffNodeAttributeRef: SERVICE_TASK service_id added when target has none" {
    var entries = std.ArrayList(PlanEntry).empty;
    defer {
        for (entries.items) |e| {
            std.testing.allocator.free(e.id);
            if (e.before) |b| std.testing.allocator.free(b);
            if (e.after) |a| std.testing.allocator.free(a);
        }
        entries.deinit(std.testing.allocator);
    }

    const source_nodes = [_]graph_mod.GraphNode{
        .{ .id = "svc1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"service_id\":\"svc-a\"}" },
    };
    const source = graph_mod.DefinitionGraph{ .nodes = &source_nodes, .edges = &.{} };
    const target = graph_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };

    try diffServiceBindings(std.testing.allocator, &entries, source, target);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqual(ChangeKind.added, entries.items[0].change_kind);
    try std.testing.expectEqual(PlanEntryType.service_binding, entries.items[0].type);
}

test "renderHumanReadable: one line per entry" {
    const entries = [_]PlanEntry{
        .{ .type = .graph_node, .id = "n1", .change_kind = .added, .before = null, .after = null },
        .{ .type = .variable_schema, .id = "v1", .change_kind = .removed, .before = null, .after = null },
    };
    const out = try renderHumanReadable(std.testing.allocator, &entries);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "added graph_node n1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "removed variable_schema v1") != null);
}
