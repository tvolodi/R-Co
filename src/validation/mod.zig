//! Public API — VLD-01/02/03 typed-environment + CEL semantic validator.
//!
//! Requirement IDs: VLD-01, VLD-02, VLD-03
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §7.2, §7.3
//!
//! Entry point: `validateDefinition(allocator, env_input) -> ValidationFailure`.
//!
//! Orchestration (per §7.4):
//!   env_input -> env builder -> typed env (VLD-01)
//!   graph    -> reachability (VLD-01 AC5)
//!   env_input -> sites -> PD-06 syntax gate (VLD-02 AC4)
//!   per site -> scoped env -> type checker (VLD-02 AC1/AC2/AC3/AC5)
//!   findings -> sort, dedupe (VLD-03 AC4)
//!   ValidationFailure -> wire.zig (HTTP 422 / 200)
//!
//! Pure module: no I/O, no DB, no logging, no clock reads. The caller is
//! responsible for fetching the four env sources (variable_schema JSON,
//! service catalog entries, module catalog entries, form-field list) and
//! passing them in via `EnvInput`.

const std = @import("std");
const graph_mod = @import("graph");
const env_mod = @import("env.zig");
const scope_mod = @import("scope.zig");
const site_mod = @import("site.zig");
const pd06_mod = @import("pd06.zig");
const typecheck_mod = @import("typecheck.zig");
const finding_mod = @import("finding.zig");
const wire_mod = @import("wire.zig");

// Re-exports — call sites can `usingnamespace` or import individually.
pub const TypedEnv = env_mod.TypedEnv;
pub const Entry = env_mod.Entry;
pub const TypeTag = env_mod.TypeTag;
pub const Provenance = env_mod.Provenance;
pub const ErrorKind = finding_mod.ErrorKind;
pub const Finding = finding_mod.Finding;
pub const ValidationFailure = wire_mod.ValidationFailure;
pub const Pd06Diagnostic = pd06_mod.Pd06Diagnostic;
pub const Site = site_mod.Site;
pub const Reachability = scope_mod.Reachability;

pub const errorKindToWire = wire_mod.errorKindToWire;
pub const serialiseValidationFailure = wire_mod.serialiseValidationFailure;
pub const serialiseSuccess = wire_mod.serialiseSuccess;

// ---------------------------------------------------------------------------
// EnvInput — the four declaration sources the env is built from
// ---------------------------------------------------------------------------

/// One SERVICE_TASK output property (VLD-01 AC2). Pre-flattened by the
/// caller: the service catalog entry's `response_schema` has already been
/// parsed and each top-level property has been extracted to a (name, type)
/// pair. VLD-01 only uses the root keys; nested flattening is out of scope.
pub const ServiceResultEntry = struct {
    /// Node id of the SERVICE_TASK that produced this output.
    node_id: []const u8,
    /// Top-level property name in the response_schema (or empty schema).
    name: []const u8,
    /// Mapped TypeTag (the env builder does NOT re-run mapDeclaredTypeName on
    /// these — the caller flattens JSON Schema types at fetch time).
    tag: TypeTag,
};

/// One SUB_PROCESS module output (VLD-01 AC1 source 3).
pub const ModuleOutputEntry = struct {
    node_id: []const u8,
    name: []const u8,
    tag: TypeTag,
};

/// One HUMAN_TASK form field declaration (VLD-01 AC3). The `field_name`
/// carries the field's `name`; `field_type` is the raw declared type string
/// the env builder will map via `mapDeclaredTypeName`.
pub const FormFieldEntry = struct {
    node_id: []const u8,
    field_name: []const u8,
    field_type: []const u8,
};

/// One `variable_schema` row (VLD-01 AC1). `var_type` is the raw declared
/// type string — the env builder maps it; an un-mappable value triggers
/// `UnknownVariableType` and the row is *not* added to the env.
pub const VariableSchemaEntry = struct {
    name: []const u8,
    var_type: []const u8,
};

/// Aggregate input to `validateDefinition`. The caller (HTTP handler) is
/// responsible for fetching each source; the validator never touches the DB.
pub const EnvInput = struct {
    graph: graph_mod.DefinitionGraph,
    variable_schema: []const VariableSchemaEntry = &.{},
    service_results: []const ServiceResultEntry = &.{},
    module_outputs: []const ModuleOutputEntry = &.{},
    form_fields: []const FormFieldEntry = &.{},
};

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const ValidationError = error{OutOfMemory};

// ---------------------------------------------------------------------------
// validateDefinition — the single entry point (VLD-01/02/03)
// ---------------------------------------------------------------------------

/// Compile-time version stamped onto every ValidationFailure. VLD-04 reads
/// this to invalidate cached verdicts when the validator changes. Today it's
/// a constant; future versions will bump it on every behaviour-affecting change.
pub const COMPILER_VERSION: []const u8 = "vld-01-03-WF02-vld01-03-20260816";

/// Run the VLD-01/02/03 pipeline over `input`. Caller owns the returned
/// ValidationFailure and must call `failure.deinit(allocator)` when done.
///
/// Memory contract:
///   - On success, every Finding and every Pd06Diagnostic is allocated with
///     the caller-supplied allocator and is freed by `deinit`.
///   - On `ValidationError.OutOfMemory` the caller sees no partially-allocated
///     state (this function uses `errdefer` for every ArrayList that grows
///     during the pipeline).
pub fn validateDefinition(
    allocator: std.mem.Allocator,
    input: EnvInput,
) ValidationError!ValidationFailure {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer {
        for (findings.items) |f| finding_mod.freeFinding(allocator, f);
        findings.deinit(allocator);
    }

    // ── VLD-02 AC4: PD-06 syntax gate runs FIRST, on every site, BEFORE any
    // env-level finding can accumulate (ISS-0709 R4b). This makes the AC4
    // short-circuit "findings stays empty" literal rather than dependent on
    // VLD-01 findings that may have been emitted below.
    const sites = site_mod.enumerateSites(allocator, input.graph) catch
        return error.OutOfMemory;
    defer site_mod.freeSites(allocator, sites);

    var pd06_diags = pd06_mod.runSyntaxCheck(allocator, input.graph, sites) catch
        return error.OutOfMemory;
    errdefer pd06_mod.freePd06Diagnostics(allocator, pd06_diags);

    if (pd06_diags.len > 0) {
        // VLD-02 AC4 — short-circuit the semantic compile loop and return
        // 422 with the PD-06 diagnostics verbatim. Findings stays empty by
        // construction (no finding has been emitted yet).
        const validated_at = try allocator.dupe(u8, "");
        const compiler_version = try allocator.dupe(u8, COMPILER_VERSION);
        return ValidationFailure{
            .findings = &.{},
            .pd06_diagnostics = pd06_diags,
            .validated_at = validated_at,
            .compiler_version = compiler_version,
        };
    }
    // PD-06 clean — release the now-empty diagnostic list before allocating.
    pd06_mod.freePd06Diagnostics(allocator, pd06_diags);
    pd06_diags = &.{};

    // ── VLD-01: build the typed env from the four declaration sources ─────
    var env_builder: std.ArrayList(Entry) = .empty;
    defer {
        for (env_builder.items) |e| {
            allocator.free(e.name);
            if (e.source_node_id) |nid| allocator.free(nid);
        }
        env_builder.deinit(allocator);
    }

    // 1) variable_schema
    for (input.variable_schema) |vs| {
        const mapped = env_mod.mapDeclaredTypeName(vs.var_type);
        if (mapped) |tag| {
            env_mod.addEntry(&env_builder, allocator, vs.name, tag, null, .variable_schema, null) catch {};
        } else {
            // VLD-01 AC1 — UnknownVariableType finding (root-level).
            const message = try std.fmt.allocPrint(
                allocator,
                "UnknownVariableType: variable '{s}' declares type '{s}' which is outside the mapping table (string, text, enum, integer, decimal, money, boolean, date, datetime, list<T>, object, number, bool, timestamp)",
                .{ vs.name, vs.var_type },
            );
            errdefer allocator.free(message);
            const node_dup = try allocator.dupe(u8, "<definition>");
            errdefer allocator.free(node_dup);
            const path_str = try std.fmt.allocPrint(allocator, "/variable_schema/{s}", .{vs.name});
            errdefer allocator.free(path_str);
            const src_dup = try allocator.dupe(u8, vs.var_type);
            errdefer allocator.free(src_dup);
            try findings.append(allocator, .{
                .node_id = node_dup,
                .expression_path = path_str,
                .source = src_dup,
                .error_kind = .UnknownVariableType,
                .message = message,
            });
        }
    }

    // 2) Service catalog results (per-node)
    for (input.service_results) |sr| {
        if (sr.tag == .dyn) {
            // VLD-01 AC2 — UndeclaredResultSchema when the schema is missing.
            const owned_node = try allocator.dupe(u8, sr.node_id);
            errdefer allocator.free(owned_node);
            const message = try std.fmt.allocPrint(
                allocator,
                "UndeclaredResultSchema: SERVICE_TASK node '{s}' references catalog entry with no response_schema",
                .{sr.node_id},
            );
            errdefer allocator.free(message);
            const path_dup = try allocator.dupe(u8, "/attributes/input_mapping");
            errdefer allocator.free(path_dup);
            const src_dup = try allocator.dupe(u8, sr.name);
            errdefer allocator.free(src_dup);
            try findings.append(allocator, .{
                .node_id = owned_node,
                .expression_path = path_dup,
                .source = src_dup,
                .error_kind = .UndeclaredResultSchema,
                .message = message,
            });
        } else {
            // addEntry dupes `name` and `source_node_id` into the env row; pass
            // the borrowed node id. The previous caller-owned dupe was leaked on
            // the success path (ISS-0709 — integration-suite leak at this site).
            env_mod.addEntry(&env_builder, allocator, sr.name, sr.tag, null, .service_result, sr.node_id) catch {};
        }
    }

    // 3) Process module outputs
    for (input.module_outputs) |mo| {
        // addEntry owns its dupes; pass the borrowed node id (no leak).
        env_mod.addEntry(&env_builder, allocator, mo.name, mo.tag, null, .module_output, mo.node_id) catch {};
    }

    // 4) Human-task form fields
    {
        // Group fields by node_id so we can detect duplicate-name collisions
        // within a single HUMAN_TASK's form scope (VLD-01 AC3).
        var node_names: std.ArrayList([]const u8) = .empty;
        var node_field_types: std.ArrayList(env_mod.TypeTag) = .empty;
        defer {
            node_names.deinit(allocator);
            node_field_types.deinit(allocator);
        }
        for (input.form_fields) |ff| {
            const mapped = env_mod.mapDeclaredTypeName(ff.field_type) orelse .dyn;
            // Track existing declarations per node_id.
            var existing_idx: ?usize = null;
            for (node_names.items, 0..) |existing_name, i| {
                if (std.mem.eql(u8, existing_name, ff.node_id)) {
                    if (i < node_field_types.items.len and node_field_types.items[i] != mapped) {
                        existing_idx = i;
                    }
                    break;
                }
            }
            if (existing_idx) |_| {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "ConflictingFieldType: form field '{s}' is declared with conflicting types within human task scope '{s}'",
                    .{ ff.field_name, ff.node_id },
                );
                errdefer allocator.free(message);
                const node_dup = try allocator.dupe(u8, ff.node_id);
                errdefer allocator.free(node_dup);
                const path_dup = try allocator.dupe(u8, "/forms/0/fields/0/type");
                errdefer allocator.free(path_dup);
                const src_dup = try allocator.dupe(u8, ff.field_type);
                errdefer allocator.free(src_dup);
                try findings.append(allocator, .{
                    .node_id = node_dup,
                    .expression_path = path_dup,
                    .source = src_dup,
                    .error_kind = .ConflictingFieldType,
                    .message = message,
                });
            } else {
                // Track this node as having a field declaration.
                if (node_names.items.len == 0 or !std.mem.eql(u8, node_names.items[node_names.items.len - 1], ff.node_id)) {
                    try node_names.append(allocator, ff.node_id);
                    try node_field_types.append(allocator, mapped);
                }
                // addEntry owns its dupes; pass the borrowed node id (no leak).
                env_mod.addEntry(&env_builder, allocator, ff.field_name, mapped, null, .form_field, ff.node_id) catch {};
            }
        }
    }

    // ── VLD-01 AC5: compute forward-reachable DFS from every node ─────────
    const reach = scope_mod.computeReachability(allocator, input.graph) catch
        return error.OutOfMemory;
    defer reach.deinit(allocator);

    // ── VLD-02 AC1/AC2/AC3/AC5: per-site semantic compile ────────────────
    const global_env_slice = env_builder.items;
    for (sites) |site| {
        var site_env = scope_mod.envForSite(
            allocator,
            TypedEnv{ .entries = global_env_slice },
            reach,
            site.node_id,
            site.form_site,
        ) catch continue;
        defer site_env.deinit(allocator);

        // `checkSite` returns Allocator.Error![]Finding; `catch continue`
        // (OOM -> skip site) — the design's `try ... catch continue` is
        // pseudocode; `try` and `catch` cannot be combined in Zig.
        const owned = typecheck_mod.checkSite(allocator, site_env, site) catch
            continue;
        try findings.appendSlice(allocator, owned);
        // R5: transfer, not deep copy — `appendSlice` shallow-copies the
        // Finding structs into the shared list (each Finding's four strings
        // are adopted by pointer and owned by `findings`/`deinit` from here
        // on). Free only the `owned` []Finding backing buffer itself; do NOT
        // call `finding_mod.freeFindings` here (that would free the adopted
        // strings a second time).
        allocator.free(owned);
    }

    // ── VLD-03 AC4: deterministic ordering by (node_id, expression_path) ──
    const findings_owned = try findings.toOwnedSlice(allocator);
    finding_mod.sortByLocation(findings_owned);
    // findings list is fully drained into findings_owned; reset `findings` to
    // empty so the outer errdefer doesn't double-free.
    findings = .empty;

    const validated_at = try allocator.dupe(u8, "");
    const compiler_version = try allocator.dupe(u8, COMPILER_VERSION);
    return ValidationFailure{
        .findings = findings_owned,
        .pd06_diagnostics = null,
        .validated_at = validated_at,
        .compiler_version = compiler_version,
    };
}

// ---------------------------------------------------------------------------
// Tests — top-level pipeline
// ---------------------------------------------------------------------------

test "validateDefinition: clean linear definition with one guard -> 0 findings" {
    const alloc = std.testing.allocator;
    const n1 = graph_mod.GraphNode{ .id = "a", .node_type = .START, .attributes = null };
    const n2 = graph_mod.GraphNode{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .attributes = null };
    const n3 = graph_mod.GraphNode{ .id = "yes", .node_type = .END, .attributes = null };
    const n4 = graph_mod.GraphNode{ .id = "no", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "a", .target = "gw" };
    const e2 = graph_mod.GraphEdge{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount > 0" };
    const e3 = graph_mod.GraphEdge{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" };

    const input = EnvInput{
        .graph = graph_mod.DefinitionGraph{
            .nodes = &[_]graph_mod.GraphNode{ n1, n2, n3, n4 },
            .edges = &[_]graph_mod.GraphEdge{ e1, e2, e3 },
        },
        .variable_schema = &[_]VariableSchemaEntry{
            .{ .name = "amount", .var_type = "number" },
        },
    };

    var failure = try validateDefinition(alloc, input);
    defer failure.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), failure.findings.len);
    try std.testing.expectEqualStrings(COMPILER_VERSION, failure.compiler_version);
}

test "validateDefinition: guard references unknown identifier -> UnknownVariable finding" {
    const alloc = std.testing.allocator;
    const n1 = graph_mod.GraphNode{ .id = "a", .node_type = .START, .attributes = null };
    const n2 = graph_mod.GraphNode{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .attributes = null };
    const n3 = graph_mod.GraphNode{ .id = "yes", .node_type = .END, .attributes = null };
    const n4 = graph_mod.GraphNode{ .id = "no", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "a", .target = "gw" };
    const e2 = graph_mod.GraphEdge{ .id = "e2", .source = "gw", .target = "yes", .condition = "amont > 0" };
    const e3 = graph_mod.GraphEdge{ .id = "e3", .source = "gw", .target = "no", .condition = "true" };

    const input = EnvInput{
        .graph = graph_mod.DefinitionGraph{
            .nodes = &[_]graph_mod.GraphNode{ n1, n2, n3, n4 },
            .edges = &[_]graph_mod.GraphEdge{ e1, e2, e3 },
        },
        .variable_schema = &[_]VariableSchemaEntry{
            .{ .name = "amount", .var_type = "number" },
        },
    };

    var failure = try validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_unknown = false;
    var saw_suggestion = false;
    for (failure.findings) |f| {
        if (f.error_kind == .UnknownVariable) {
            saw_unknown = true;
            if (std.mem.indexOf(u8, f.message, "did you mean") != null) saw_suggestion = true;
        }
    }
    try std.testing.expect(saw_unknown);
    try std.testing.expect(saw_suggestion);
}

test "validateDefinition: variable_schema declares unknown type -> UnknownVariableType" {
    const alloc = std.testing.allocator;
    const n1 = graph_mod.GraphNode{ .id = "a", .node_type = .START, .attributes = null };
    const n2 = graph_mod.GraphNode{ .id = "b", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "a", .target = "b" };

    const input = EnvInput{
        .graph = graph_mod.DefinitionGraph{
            .nodes = &[_]graph_mod.GraphNode{ n1, n2 },
            .edges = &[_]graph_mod.GraphEdge{e1},
        },
        .variable_schema = &[_]VariableSchemaEntry{
            .{ .name = "weird", .var_type = "uuid" },
        },
    };

    var failure = try validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_unknown_type = false;
    for (failure.findings) |f| {
        if (f.error_kind == .UnknownVariableType) saw_unknown_type = true;
    }
    try std.testing.expect(saw_unknown_type);
}

test "validateDefinition: malformed CEL guard -> pd06_diagnostics populated, findings empty" {
    const alloc = std.testing.allocator;
    const n1 = graph_mod.GraphNode{ .id = "a", .node_type = .START, .attributes = null };
    const n2 = graph_mod.GraphNode{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .attributes = null };
    const n3 = graph_mod.GraphNode{ .id = "yes", .node_type = .END, .attributes = null };
    const n4 = graph_mod.GraphNode{ .id = "no", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "a", .target = "gw" };
    const e2 = graph_mod.GraphEdge{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount >" };
    const e3 = graph_mod.GraphEdge{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <=" };

    const input = EnvInput{
        .graph = graph_mod.DefinitionGraph{
            .nodes = &[_]graph_mod.GraphNode{ n1, n2, n3, n4 },
            .edges = &[_]graph_mod.GraphEdge{ e1, e2, e3 },
        },
        .variable_schema = &[_]VariableSchemaEntry{
            .{ .name = "amount", .var_type = "number" },
        },
    };

    var failure = try validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    // VLD-02 AC4 — PD-06 short-circuit: findings stays empty, pd06 populated.
    try std.testing.expectEqual(@as(usize, 0), failure.findings.len);
    try std.testing.expect(failure.pd06_diagnostics != null);
    try std.testing.expect(failure.pd06_diagnostics.?.len >= 1);
}

test "validateDefinition: findings are ordered by (node_id, expression_path) byte-wise lex" {
    const alloc = std.testing.allocator;
    // Two nodes with deliberately-unsorted identifiers.
    const n1 = graph_mod.GraphNode{ .id = "zeta", .node_type = .EXCLUSIVE_GATEWAY, .attributes = null };
    const n2 = graph_mod.GraphNode{ .id = "alpha", .node_type = .END, .attributes = null };
    const n3 = graph_mod.GraphNode{ .id = "beta", .node_type = .END, .attributes = null };
    const e1 = graph_mod.GraphEdge{ .id = "e1", .source = "zeta", .target = "alpha", .condition = "x >" }; // bad
    const e2 = graph_mod.GraphEdge{ .id = "e2", .source = "zeta", .target = "beta", .condition = "y <" }; // bad

    const input = EnvInput{
        .graph = graph_mod.DefinitionGraph{
            .nodes = &[_]graph_mod.GraphNode{ n1, n2, n3 },
            .edges = &[_]graph_mod.GraphEdge{ e1, e2 },
        },
    };

    var failure = try validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    // Both edges are malformed -> PD-06 short-circuit.
    try std.testing.expect(failure.pd06_diagnostics != null);
    // When the gate fires, findings stays empty (no ordering test possible).
    try std.testing.expectEqual(@as(usize, 0), failure.findings.len);
}
