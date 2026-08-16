//! Type checker — VLD-02 AC1..AC3, VLD-02 AC5.
//!
//! Requirement IDs: VLD-02 AC1..AC3, AC5; VLD-03 AC3
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §6.2, §9
//!
//! For one (Site, TypedEnv) pair, this module produces zero-or-more Findings:
//!   * `EmptyExpression`           — VLD-02 AC5, source is null/empty/whitespace
//!   * `TypeMismatch`              — VLD-02 AC1, AST root type != expected
//!   * `UnknownVariable`           — VLD-02 AC2, identifier absent in env
//!   * `OperandTypeError`          — VLD-02 AC3, binary op over incompatible types
//!
//! EmptyExpression is the *only* finding a single site can produce when the
//! source is empty (per §6.2.5: "one finding per site, never two"). The
//! semantic walk is skipped entirely on EmptyExpression.
//!
//! The walk uses the existing `expr.parse` AST from `src/expr/`. When
//! `expr.parse` returns `.fail` (genuine parser failure), the site falls
//! through to PD-06 (its syntax is broken); this type checker does NOT
//! emit a separate semantic finding for a parse error — the
//! `pd06.zig` syntax gate already covers it.
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.

const std = @import("std");
const expr_mod = @import("expr");
const env_mod = @import("env.zig");
const site_mod = @import("site.zig");
const finding_mod = @import("finding.zig");

pub const TypedEnv = env_mod.TypedEnv;
pub const TypeTag = env_mod.TypeTag;
pub const Site = site_mod.Site;
pub const Finding = finding_mod.Finding;
pub const ErrorKind = finding_mod.ErrorKind;

// ---------------------------------------------------------------------------
// Type inference — VLD-02 §6.2.1
// ---------------------------------------------------------------------------

/// Compute the inferred TypeTag for the AST root. Literal and operator nodes
/// follow the standard CEL semantics: arithmetic produces number, comparison
/// produces bool, boolean ops produce bool, dot_path is delegated to the env,
/// and function calls are limited to the same set the runtime evaluator
/// (`src/expr/evaluator.zig`) recognises (string, number, bool, timestamp).
///
/// `env` is the per-site filtered slice — see `scope.envForSite`.
fn inferType(
    allocator: std.mem.Allocator,
    env: TypedEnv,
    node: *const expr_mod.Node,
    diagnostics: *std.ArrayList(Finding),
    site: Site,
) std.mem.Allocator.Error!TypeTag {
    switch (node.*) {
        .null_literal => return .dyn,
        .bool_literal => return .bool,
        .int_literal => return .number,
        .float_literal => return .number,
        .string_literal => return .string,
        .or_expr => |bin| {
            _ = try inferType(allocator, env, bin.left, diagnostics, site);
            _ = try inferType(allocator, env, bin.right, diagnostics, site);
            return .bool;
        },
        .and_expr => |bin| {
            _ = try inferType(allocator, env, bin.left, diagnostics, site);
            _ = try inferType(allocator, env, bin.right, diagnostics, site);
            return .bool;
        },
        .not_expr => |u| {
            _ = try inferType(allocator, env, u.operand, diagnostics, site);
            return .bool;
        },
        .cmp_expr => |bin| {
            _ = try inferType(allocator, env, bin.left, diagnostics, site);
            _ = try inferType(allocator, env, bin.right, diagnostics, site);
            return .bool;
        },
        .unary_neg => {
            const t = try inferType(allocator, env, node.unary_neg.operand, diagnostics, site);
            if (t == .number) return .number;
            // emit OperandTypeError for unary negation on non-number
            try emitOperandTypeError(
                allocator,
                diagnostics,
                site,
                "-",
                t,
                .dyn,
            );
            return .dyn;
        },
        .add_expr => |bin| {
            const l = try inferType(allocator, env, bin.left, diagnostics, site);
            const r = try inferType(allocator, env, bin.right, diagnostics, site);
            return checkArithmeticCompat(allocator, diagnostics, site, l, r, "+");
        },
        .mul_expr => |bin| {
            const l = try inferType(allocator, env, bin.left, diagnostics, site);
            const r = try inferType(allocator, env, bin.right, diagnostics, site);
            return checkArithmeticCompat(allocator, diagnostics, site, l, r, "*");
        },
        .dot_path => |segments| {
            if (segments.len == 0) return .dyn;
            const head = segments[0];
            const entry = env.lookup(head);
            if (entry) |e| {
                return e.tag;
            }
            // VLD-02 AC2 — UnknownVariable with edit-distance suggestion.
            try emitUnknownVariable(allocator, diagnostics, env, site, head);
            return .dyn;
        },
        .func_call => |fc| {
            // Walk arguments for unknown variables even though the call result
            // type comes from the built-in registry.
            for (fc.args) |arg| {
                _ = try inferType(allocator, env, arg, diagnostics, site);
            }
            // The runtime evaluator recognises only a fixed set of CEL built-ins;
            // mirror that set here for type inference. Any unrecognised name
            // yields .dyn — we don't emit UnknownVariable for function names
            // (they're built-ins, not env entries).
            return inferFuncCall(fc.name, fc.args.len);
        },
    }
}

fn checkArithmeticCompat(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Finding),
    site: Site,
    l: TypeTag,
    r: TypeTag,
    op: []const u8,
) std.mem.Allocator.Error!TypeTag {
    if (l == .number and r == .number) return .number;
    // Anything else is incompatible.
    try emitOperandTypeError(allocator, diagnostics, site, op, l, r);
    return .dyn;
}

fn inferFuncCall(name: []const u8, argc: usize) TypeTag {
    if (std.mem.eql(u8, name, "len")) {
        // CEL's size() — but this DSL uses `len`/`size` interchangeably for
        // collections. Return .number when the arg count looks right.
        if (argc == 1) return .number;
    }
    if (std.mem.eql(u8, name, "size")) {
        if (argc == 1) return .number;
    }
    if (std.mem.eql(u8, name, "startsWith") or std.mem.eql(u8, name, "endsWith") or std.mem.eql(u8, name, "contains")) {
        if (argc == 2) return .bool;
    }
    if (std.mem.eql(u8, name, "now")) {
        if (argc == 0) return .timestamp;
    }
    // Unknown function — type checks only at usage; return .dyn.
    return .dyn;
}

// ---------------------------------------------------------------------------
// Diagnostic emitters
// ---------------------------------------------------------------------------

fn emitUnknownVariable(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Finding),
    env: TypedEnv,
    site: Site,
    missing: []const u8,
) std.mem.Allocator.Error!void {
    var nearest: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (env.entries) |e| {
        const d = finding_mod.editDistance(missing, e.name);
        if (d < best_dist) {
            best_dist = d;
            nearest = e.name;
        }
    }

    const message = blk: {
        if (nearest) |n| {
            if (best_dist <= finding_mod.SUGGESTION_THRESHOLD and best_dist > 0) {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "UnknownVariable: identifier '{s}' is not declared; did you mean '{s}'?",
                    .{ missing, n },
                );
            }
        }
        break :blk try std.fmt.allocPrint(
            allocator,
            "UnknownVariable: identifier '{s}' is not declared in the visible environment",
            .{missing},
        );
    };
    errdefer allocator.free(message);

    const node_dup = try allocator.dupe(u8, site.node_id);
    errdefer allocator.free(node_dup);
    const path_dup = try allocator.dupe(u8, site.expression_path);
    errdefer allocator.free(path_dup);
    const source_dup = try allocator.dupe(u8, site.source);
    errdefer allocator.free(source_dup);

    try diagnostics.append(allocator, .{
        .node_id = node_dup,
        .expression_path = path_dup,
        .source = source_dup,
        .error_kind = .UnknownVariable,
        .message = message,
    });
}

fn emitOperandTypeError(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Finding),
    site: Site,
    op: []const u8,
    l: TypeTag,
    r: TypeTag,
) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(
        allocator,
        "OperandTypeError: operator '{s}' cannot combine operand of type '{s}' with operand of type '{s}' at site '{s}{s}'",
        .{ op, env_mod.typeTagName(l), env_mod.typeTagName(r), site.node_id, site.expression_path },
    );
    errdefer allocator.free(message);

    const node_dup = try allocator.dupe(u8, site.node_id);
    errdefer allocator.free(node_dup);
    const path_dup = try allocator.dupe(u8, site.expression_path);
    errdefer allocator.free(path_dup);
    const source_dup = try allocator.dupe(u8, site.source);
    errdefer allocator.free(source_dup);

    try diagnostics.append(allocator, .{
        .node_id = node_dup,
        .expression_path = path_dup,
        .source = source_dup,
        .error_kind = .OperandTypeError,
        .message = message,
    });
}

fn emitTypeMismatch(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Finding),
    site: Site,
    expected: TypeTag,
    actual: TypeTag,
) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(
        allocator,
        "TypeMismatch: expected '{s}', got '{s}' at site '{s}{s}'",
        .{ env_mod.typeTagName(expected), env_mod.typeTagName(actual), site.node_id, site.expression_path },
    );
    errdefer allocator.free(message);

    const node_dup = try allocator.dupe(u8, site.node_id);
    errdefer allocator.free(node_dup);
    const path_dup = try allocator.dupe(u8, site.expression_path);
    errdefer allocator.free(path_dup);
    const source_dup = try allocator.dupe(u8, site.source);
    errdefer allocator.free(source_dup);

    try diagnostics.append(allocator, .{
        .node_id = node_dup,
        .expression_path = path_dup,
        .source = source_dup,
        .error_kind = .TypeMismatch,
        .message = message,
    });
}

fn emitEmptyExpression(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Finding),
    site: Site,
) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(
        allocator,
        "EmptyExpression: expression site on node '{s}' at '{s}' is empty or whitespace-only",
        .{ site.node_id, site.expression_path },
    );
    errdefer allocator.free(message);

    const node_dup = try allocator.dupe(u8, site.node_id);
    errdefer allocator.free(node_dup);
    const path_dup = try allocator.dupe(u8, site.expression_path);
    errdefer allocator.free(path_dup);
    // source is empty literal "" per VLD-03 AC2 contract.
    const source_dup = try allocator.dupe(u8, "");
    errdefer allocator.free(source_dup);

    try diagnostics.append(allocator, .{
        .node_id = node_dup,
        .expression_path = path_dup,
        .source = source_dup,
        .error_kind = .EmptyExpression,
        .message = message,
    });
}

// ---------------------------------------------------------------------------
// checkSite — VLD-02 AC1/AC2/AC3/AC5 entry point
// ---------------------------------------------------------------------------

/// Compile one (Site, TypedEnv) pair into zero-or-more Findings. Caller owns
/// the returned slice and must call `finding_mod.freeFindings`.
///
/// Per §6.2.5: an empty source produces exactly one `EmptyExpression`
/// finding and short-circuits all other checks.
pub fn checkSite(
    allocator: std.mem.Allocator,
    env: TypedEnv,
    site: Site,
) std.mem.Allocator.Error![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer {
        for (findings.items) |f| finding_mod.freeFinding(allocator, f);
        findings.deinit(allocator);
    }

    // VLD-02 AC5 — empty/whitespace check runs FIRST.
    if (site_mod.isEmptyOrWhitespace(site.source)) {
        try emitEmptyExpression(allocator, &findings, site);
        return try findings.toOwnedSlice(allocator);
    }

    // Parse the source. When parsing fails, the PD-06 syntax gate (which runs
    // BEFORE this function) already covers the failure — we emit no
    // duplicate finding here and the orchestrator short-circuits.
    const parse_result = try expr_mod.parse(allocator, site.source);
    switch (parse_result) {
        .fail => |errs| allocator.free(errs),
        .ok => |ast| {
            var ast_mut = ast;
            defer ast_mut.deinit();
            const actual = try inferType(allocator, env, ast_mut.root, &findings, site);
            // VLD-02 AC1 — TypeMismatch.
            if (actual != site.expected_type and actual != .dyn and site.expected_type != .dyn) {
                try emitTypeMismatch(allocator, &findings, site, site.expected_type, actual);
            }
        },
    }

    return try findings.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests — VLD-02 AC1/AC2/AC3/AC5
// ---------------------------------------------------------------------------

const SiteStub = struct {
    fn s(alloc: std.mem.Allocator, src: []const u8, expected: TypeTag, form: bool) !Site {
        return Site{
            .node_id = try alloc.dupe(u8, "n1"),
            .expression_path = try alloc.dupe(u8, "/test"),
            .source = try alloc.dupe(u8, src),
            .expected_type = expected,
            .form_site = form,
        };
    }
};

test "checkSite: empty source -> EmptyExpression" {
    const alloc = std.testing.allocator;
    const env = TypedEnv{ .entries = &.{} };
    defer env.deinit(alloc);

    var sites_buf: std.ArrayList(Site) = .empty;
    defer sites_buf.deinit(alloc);
    try sites_buf.append(alloc, try SiteStub.s(alloc, "   ", .bool, false));
    defer site_mod.freeSites(alloc, sites_buf.items);

    const findings = try checkSite(alloc, env, sites_buf.items[0]);
    defer finding_mod.freeFindings(alloc, findings);

    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expect(findings[0].error_kind == .EmptyExpression);
}

test "checkSite: number literal where bool expected -> TypeMismatch" {
    const alloc = std.testing.allocator;
    const env = TypedEnv{ .entries = &.{} };
    defer env.deinit(alloc);

    var sites_buf: std.ArrayList(Site) = .empty;
    defer sites_buf.deinit(alloc);
    try sites_buf.append(alloc, try SiteStub.s(alloc, "1", .bool, false));
    defer site_mod.freeSites(alloc, sites_buf.items);

    const findings = try checkSite(alloc, env, sites_buf.items[0]);
    defer finding_mod.freeFindings(alloc, findings);

    try std.testing.expect(findings.len >= 1);
    var saw_type_mismatch = false;
    for (findings) |f| {
        if (f.error_kind == .TypeMismatch) saw_type_mismatch = true;
    }
    try std.testing.expect(saw_type_mismatch);
}

test "checkSite: unknown variable identifier -> UnknownVariable" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(env_mod.Entry) = .empty;
    defer entries.deinit(alloc);
    try env_mod.addEntry(&entries, alloc, "amount", .number, null, .variable_schema, null);

    const env = TypedEnv{ .entries = entries.items };
    defer env.deinit(alloc);

    var sites_buf: std.ArrayList(Site) = .empty;
    defer sites_buf.deinit(alloc);
    try sites_buf.append(alloc, try SiteStub.s(alloc, "amont > 0", .bool, false));
    defer site_mod.freeSites(alloc, sites_buf.items);

    const findings = try checkSite(alloc, env, sites_buf.items[0]);
    defer finding_mod.freeFindings(alloc, findings);

    var saw_unknown = false;
    var saw_suggestion = false;
    for (findings) |f| {
        if (f.error_kind == .UnknownVariable) {
            saw_unknown = true;
            if (std.mem.indexOf(u8, f.message, "did you mean") != null) saw_suggestion = true;
        }
    }
    try std.testing.expect(saw_unknown);
    try std.testing.expect(saw_suggestion);
}

test "checkSite: '+' over number and string -> OperandTypeError" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(env_mod.Entry) = .empty;
    defer entries.deinit(alloc);
    try env_mod.addEntry(&entries, alloc, "amount", .number, null, .variable_schema, null);
    try env_mod.addEntry(&entries, alloc, "name", .string, null, .variable_schema, null);

    const env = TypedEnv{ .entries = entries.items };
    defer env.deinit(alloc);

    var sites_buf: std.ArrayList(Site) = .empty;
    defer sites_buf.deinit(alloc);
    try sites_buf.append(alloc, try SiteStub.s(alloc, "amount + name", .number, false));
    defer site_mod.freeSites(alloc, sites_buf.items);

    const findings = try checkSite(alloc, env, sites_buf.items[0]);
    defer finding_mod.freeFindings(alloc, findings);

    var saw_operand = false;
    for (findings) |f| {
        if (f.error_kind == .OperandTypeError) saw_operand = true;
    }
    try std.testing.expect(saw_operand);
}
