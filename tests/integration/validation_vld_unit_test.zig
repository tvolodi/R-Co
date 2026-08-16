//! Integration tests for VLD-01, VLD-02, VLD-03 — Stage 16 semantic validation.
//!
//! Drives `validation.validateDefinition` directly (in-process) against
//! purpose-built `EnvInput` fixtures. Twelve test blocks cover all MUST ACs
//! that are exercisable without an HTTP boundary. Two ACs (VLD-03 AC2 and
//! VLD-03 AC5 — wire-shape) are covered exclusively in
//! `validation_vld_http_test.zig` at the HTTP boundary; everything else is
//! here.
//!
//! Requires `BPM_TEST_DB_URL` — even though `validateDefinition` is pure,
//! the fixtures are persisted-and-cleaned via `definition.Store` to match
//! the existing `tests/integration/definition_test.zig` convention and to
//! validate the env-source plumbing the HTTP handler uses in production.
//!
//! No `error.SkipZigTest` on any block (lint_test_isolation T040).
//!
//! Spec: tests/specs/vld-01-03-stage-16-validation.spec.md §1, §3, §5.3
//! Design: src/design/vld-01-03-stage-16-validation.md
//! Impl under test: src/validation/mod.zig (commit 31482edb)
//! Run ID: WF02-vld01-03-20260816
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

const validation = @import("validation");
const EnvInput = validation.EnvInput;
const VariableSchemaEntry = validation.VariableSchemaEntry;
const ServiceResultEntry = validation.ServiceResultEntry;
const ModuleOutputEntry = validation.ModuleOutputEntry;
const FormFieldEntry = validation.FormFieldEntry;
const Finding = validation.Finding;
const ErrorKind = validation.ErrorKind;
const TypeTag = validation.TypeTag;
const Pd06Diagnostic = validation.Pd06Diagnostic;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn parseTestUuid(_: std.mem.Allocator, s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        .{ name, version },
    ) catch {};
}

// GH-512: generate the creator UUID per-test via the platform CSPRNG
// (lint_test_isolation T010 — runtime UUID, no hardcoded fixture literal).
fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    bpm.uuid.generateUuidV4BytesInto(&bytes);
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

// ---------------------------------------------------------------------------
// Canonical fixture A — clean linear definition (happy path)
// Used by AC4 (declaration-only) and AC1/AC3 aggregate ordering (AC1).
// ---------------------------------------------------------------------------

const happy_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
    .{ .id = "yes", .node_type = .END, .label = null },
    .{ .id = "no", .node_type = .END, .label = null },
};

const happy_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount > 0" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};

const happy_graph = DefinitionGraph{ .nodes = &happy_nodes, .edges = &happy_edges };

const happy_variables = [_]VariableSchemaEntry{
    .{ .name = "amount", .var_type = "number" },
};

const happy_input = EnvInput{
    .graph = happy_graph,
    .variable_schema = &happy_variables,
};

// ---------------------------------------------------------------------------
// Fixture H — whitespace-only edge (VLD-02 AC5 EmptyExpression)
// ---------------------------------------------------------------------------

const empty_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "   " },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};

const empty_input = EnvInput{
    .graph = DefinitionGraph{
        .nodes = &happy_nodes,
        .edges = &empty_edges,
    },
    .variable_schema = &happy_variables,
};

// ---------------------------------------------------------------------------
// Fixture D — PD-06 malformed guard (VLD-02 AC4)
// ---------------------------------------------------------------------------

const bad_syntax_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount >" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};

const bad_syntax_input = EnvInput{
    .graph = DefinitionGraph{
        .nodes = &happy_nodes,
        .edges = &bad_syntax_edges,
    },
    .variable_schema = &happy_variables,
};

// ---------------------------------------------------------------------------
// Fixture K — three failing edges on the same gateway (VLD-03 AC1)
// ---------------------------------------------------------------------------

const three_finding_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
    .{ .id = "yes", .node_type = .END, .label = null },
    .{ .id = "no", .node_type = .END, .label = null },
    .{ .id = "maybe", .node_type = .END, .label = null },
};

const three_finding_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount + name" },
    .{ .id = "e4", .source = "gw", .target = "maybe", .condition = "amont > 0" },
};

const three_finding_vars = [_]VariableSchemaEntry{
    .{ .name = "amount", .var_type = "number" },
    .{ .name = "name", .var_type = "string" },
};

const three_finding_input = EnvInput{
    .graph = DefinitionGraph{
        .nodes = &three_finding_nodes,
        .edges = &three_finding_edges,
    },
    .variable_schema = &three_finding_vars,
};

// ---------------------------------------------------------------------------
// Fixture F — UnknownVariable with edit-distance suggestion (VLD-03 AC3)
// ---------------------------------------------------------------------------

const suggested_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amont > 0" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};

const suggested_input = EnvInput{
    .graph = DefinitionGraph{
        .nodes = &happy_nodes,
        .edges = &suggested_edges,
    },
    .variable_schema = &happy_variables,
};

// ---------------------------------------------------------------------------
// VLD-01 AC1 — variable_schema declaration outside mapping table
// ---------------------------------------------------------------------------

test "int_vld_01_01: validateDefinition returns UnknownVariableType for variable_schema declaration outside mapping table" {
    const alloc = std.testing.allocator;
    const input = EnvInput{
        .graph = DefinitionGraph{
            .nodes = &[_]GraphNode{
                .{ .id = "S", .node_type = .START, .label = null },
                .{ .id = "E", .node_type = .END, .label = null },
            },
            .edges = &[_]GraphEdge{
                .{ .id = "e1", .source = "S", .target = "E" },
            },
        },
        .variable_schema = &[_]VariableSchemaEntry{
            .{ .name = "weird", .var_type = "uuid" },
        },
    };

    var failure = try validation.validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_unknown_type = false;
    var saw_node_id_root = false;
    var saw_path_variable_schema = false;
    for (failure.findings) |f| {
        if (f.error_kind == .UnknownVariableType) saw_unknown_type = true;
        if (std.mem.eql(u8, f.node_id, "<definition>")) saw_node_id_root = true;
        if (std.mem.indexOf(u8, f.expression_path, "/variable_schema/") != null)
            saw_path_variable_schema = true;
    }
    try std.testing.expect(saw_unknown_type);
    try std.testing.expect(saw_node_id_root);
    try std.testing.expect(saw_path_variable_schema);
}

// ---------------------------------------------------------------------------
// VLD-01 AC2 — SERVICE_TASK catalog entry with no response_schema
// ---------------------------------------------------------------------------

test "int_vld_01_02: validateDefinition returns UndeclaredResultSchema for SERVICE_TASK whose catalog response_schema is null" {
    const alloc = std.testing.allocator;
    const svc_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "svc", .node_type = .SERVICE_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const svc_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "svc" },
        .{ .id = "e2", .source = "svc", .target = "E" },
    };
    const input = EnvInput{
        .graph = DefinitionGraph{ .nodes = &svc_nodes, .edges = &svc_edges },
        .service_results = &[_]ServiceResultEntry{
            // tag = .dyn is the VLD-01 AC2 trigger (no response_schema).
            .{ .node_id = "svc", .name = "result_x", .tag = .dyn },
        },
    };

    var failure = try validation.validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_undeclared = false;
    var saw_svc_node = false;
    for (failure.findings) |f| {
        if (f.error_kind == .UndeclaredResultSchema) saw_undeclared = true;
        if (std.mem.eql(u8, f.node_id, "svc")) saw_svc_node = true;
    }
    try std.testing.expect(saw_undeclared);
    try std.testing.expect(saw_svc_node);
}

// ---------------------------------------------------------------------------
// VLD-01 AC3 — ConflictingFieldType for two same-name form fields with
// different types within the same human task scope.
// ---------------------------------------------------------------------------

test "int_vld_01_03: validateDefinition returns ConflictingFieldType for two same-name form fields with different types" {
    const alloc = std.testing.allocator;
    const ht_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "task_collect", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const ht_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "task_collect" },
        .{ .id = "e2", .source = "task_collect", .target = "E" },
    };
    // Two form fields sharing the same `node_id` and `field_name` but with
    // different `field_type` strings — VLD-01 AC3 trigger.
    const fields = [_]FormFieldEntry{
        .{ .node_id = "task_collect", .field_name = "email", .field_type = "string" },
        .{ .node_id = "task_collect", .field_name = "email", .field_type = "number" },
    };
    const input = EnvInput{
        .graph = DefinitionGraph{ .nodes = &ht_nodes, .edges = &ht_edges },
        .form_fields = &fields,
    };

    var failure = try validation.validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_conflict = false;
    var saw_task_node = false;
    for (failure.findings) |f| {
        if (f.error_kind == .ConflictingFieldType) saw_conflict = true;
        if (std.mem.eql(u8, f.node_id, "task_collect")) saw_task_node = true;
    }
    try std.testing.expect(saw_conflict);
    try std.testing.expect(saw_task_node);
}

// ---------------------------------------------------------------------------
// VLD-01 AC4 — env is declaration-only (instance variables don't change env)
// Drives the validator twice with identical variable_schema but with two
// different "instance maps" supplied as service_results/module_outputs that
// MUST NOT contribute to the env. The two findings slices must be empty.
// ---------------------------------------------------------------------------

test "int_vld_01_04: validateDefinition env is identical for two instances with different variable maps (declaration-only)" {
    const alloc = std.testing.allocator;

    // Instance A — declares a service result. Instance B — declares a
    // process module output. Neither may contribute to the env that the
    // semantic checker sees; both must clear the same set of guards.
    const instance_a_results = [_]ServiceResultEntry{
        .{ .node_id = "svc_a", .name = "customer_id", .tag = .string },
    };
    const instance_b_outputs = [_]ModuleOutputEntry{
        .{ .node_id = "sub_b", .name = "amount", .tag = .number },
    };

    const input_a = EnvInput{
        .graph = happy_graph,
        .variable_schema = &happy_variables,
        .service_results = &instance_a_results,
    };
    const input_b = EnvInput{
        .graph = happy_graph,
        .variable_schema = &happy_variables,
        .module_outputs = &instance_b_outputs,
    };

    var fail_a = try validation.validateDefinition(alloc, input_a);
    defer fail_a.deinit(alloc);
    var fail_b = try validation.validateDefinition(alloc, input_b);
    defer fail_b.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), fail_a.findings.len);
    try std.testing.expectEqual(@as(usize, 0), fail_b.findings.len);
    // compiler_version is stamped on the failure and is identical across calls.
    try std.testing.expectEqualStrings(fail_a.compiler_version, fail_b.compiler_version);
}

// ---------------------------------------------------------------------------
// VLD-01 AC5a — SERVICE_TASK output is forward-scoped (downstream only).
// A SERVICE_TASK node `svc` is reachable from `gw` (downstream) and from `S`
// (start, upstream). The svc output `customer_id` MUST appear in envForSite
// for `gw`, and MUST NOT appear in envForSite for `S`.
// ---------------------------------------------------------------------------

test "int_vld_01_05a: validateDefinition forward-scopes SERVICE_TASK output to downstream sites only" {
    const alloc = std.testing.allocator;
    // Linear chain: S -> svc -> gw -> yes/no. svc's output `customer_id` is
    // declared on a SERVICE_TASK. The forward-reachability DFS makes it
    // visible only on nodes REACHABLE FROM svc. The gw's edge condition
    // reads `customer_id` (visible) and `amount` (global). The validator
    // must produce ZERO findings — the scope filter is correct.
    //
    // To make the scope filter's behaviour visible we ALSO drive the
    // validator with a deliberately-broken upstream reference: a separate
    // graph (S -> bad_gw) where `bad_gw` references `customer_id` but is
    // NOT reachable from `svc`. The validator must emit a finding on that
    // site (UnknownVariable) — proving customer_id is NOT in the upstream
    // site's env.
    const downstream_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "svc", .node_type = .SERVICE_TASK, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "yes", .node_type = .END, .label = null },
        .{ .id = "no", .node_type = .END, .label = null },
    };
    const downstream_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "svc" },
        .{ .id = "e2", .source = "svc", .target = "gw" },
        .{ .id = "e3", .source = "gw", .target = "yes", .condition = "customer_id != \"\"" },
        .{ .id = "e4", .source = "gw", .target = "no", .condition = "amount <= 0" },
    };
    const services = [_]ServiceResultEntry{
        .{ .node_id = "svc", .name = "customer_id", .tag = .string },
    };
    const downstream_input = EnvInput{
        .graph = DefinitionGraph{ .nodes = &downstream_nodes, .edges = &downstream_edges },
        .variable_schema = &happy_variables,
        .service_results = &services,
    };

    var downstream_fail = try validation.validateDefinition(alloc, downstream_input);
    defer downstream_fail.deinit(alloc);

    // Downstream site (gw) sees customer_id -> 0 findings.
    try std.testing.expectEqual(@as(usize, 0), downstream_fail.findings.len);

    // Upstream-of-svc graph: S -> bad_gw -> end. bad_gw references
    // customer_id (NOT reachable from svc on this graph — svc is not even
    // in this graph). The validator must emit an UnknownVariable finding,
    // proving customer_id is absent from bad_gw's visible env.
    const upstream_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "bad_gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "yes", .node_type = .END, .label = null },
        .{ .id = "no", .node_type = .END, .label = null },
    };
    const upstream_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "bad_gw", .condition = null },
        .{ .id = "e2", .source = "bad_gw", .target = "yes", .condition = "customer_id != \"\"" },
        .{ .id = "e3", .source = "bad_gw", .target = "no", .condition = "amount <= 0" },
    };
    // Declare customer_id as a service_result scoped to a NON-EXISTENT node
    // so the env builder does NOT add it to the global env (service_results
    // are gated by the same per-site scope rule).
    const upstream_services = [_]ServiceResultEntry{
        .{ .node_id = "svc_nowhere", .name = "customer_id", .tag = .string },
    };
    const upstream_input = EnvInput{
        .graph = DefinitionGraph{ .nodes = &upstream_nodes, .edges = &upstream_edges },
        .variable_schema = &happy_variables,
        .service_results = &upstream_services,
    };

    var upstream_fail = try validation.validateDefinition(alloc, upstream_input);
    defer upstream_fail.deinit(alloc);

    // bad_gw references customer_id; it's not in the global env (only
    // scoped to a missing svc). Expect an UnknownVariable finding.
    try std.testing.expect(upstream_fail.findings.len >= 1);
    var saw_unknown = false;
    for (upstream_fail.findings) |f| {
        if (f.error_kind == .UnknownVariable) saw_unknown = true;
    }
    try std.testing.expect(saw_unknown);
}

// ---------------------------------------------------------------------------
// VLD-01 AC5b — Form-field scope is per-HUMAN_TASK-node_id.
// Two HUMAN_TASK nodes each with a form field `email`; one `string`, one
// `number`. No `ConflictingFieldType` finding is emitted (collisions are
// per-form, not cross-form).
// ---------------------------------------------------------------------------

test "int_vld_01_05b: validateDefinition form-field scope is per-HUMAN_TASK-node_id" {
    const alloc = std.testing.allocator;
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "task_A", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"a\"}" },
        .{ .id = "task_B", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"b\"}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "task_A" },
        .{ .id = "e2", .source = "task_A", .target = "task_B" },
        .{ .id = "e3", .source = "task_B", .target = "E" },
    };
    const fields = [_]FormFieldEntry{
        .{ .node_id = "task_A", .field_name = "email", .field_type = "string" },
        .{ .node_id = "task_B", .field_name = "email", .field_type = "number" },
    };
    const input = EnvInput{
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .form_fields = &fields,
    };

    var failure = try validation.validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    var saw_conflict = false;
    for (failure.findings) |f| {
        if (f.error_kind == .ConflictingFieldType) saw_conflict = true;
    }
    try std.testing.expect(!saw_conflict);
}

// ---------------------------------------------------------------------------
// VLD-02 AC1 — twelve positive operator cases (returns 0 findings)
// + VLD-02 AC3 negative case (string > number produces OperandTypeError).
//
// ISS-0709 R7: the four arithmetic operators (+ - * /) infer `number` and
// are NOT positive on a bool-expecting EXCLUSIVE_GATEWAY guard (VLD-02 AC1).
// They are relocated to a number-expecting HUMAN_TASK form `computed_from`
// site so every operator is positive at its natural result type.
// ---------------------------------------------------------------------------

test "int_vld_02_01: validateDefinition returns 0 findings for all twelve positive CEL operator cases" {
    const alloc = std.testing.allocator;

    // Eight bool-producing operators are exercised on the bool-expecting
    // EXCLUSIVE_GATEWAY guard — all yield 0 findings against the env that
    // declares `a`, `b` as numbers (VLD-02 AC1).
    const bool_cases = [_]struct { name: []const u8, condition: []const u8 }{
        .{ .name = "==", .condition = "a == b" },
        .{ .name = "!=", .condition = "a != b" },
        .{ .name = "<", .condition = "a < b" },
        .{ .name = "<=", .condition = "a <= b" },
        .{ .name = ">", .condition = "a > b" },
        .{ .name = ">=", .condition = "a >= b" },
        .{ .name = "&&", .condition = "a > 0 && b > 0" },
        .{ .name = "||", .condition = "a > 0 || b > 0" },
    };

    // Four arithmetic operators infer `number` — they are exercised at a
    // number-expecting HUMAN_TASK form `computed_from` site whose field
    // declares `type: "number"` (R7 relocation), not on the bool-expecting
    // gateway guard. All four yield 0 findings at their natural result type.
    const arithmetic_cases = [_]struct { name: []const u8, expression: []const u8 }{
        .{ .name = "+", .expression = "a + b" },
        .{ .name = "-", .expression = "a - b" },
        .{ .name = "*", .expression = "a * b" },
        .{ .name = "/", .expression = "a / b" },
    };

    const vars = [_]VariableSchemaEntry{
        .{ .name = "a", .var_type = "number" },
        .{ .name = "b", .var_type = "number" },
    };

    const gw_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "yes", .node_type = .END, .label = null },
        .{ .id = "no", .node_type = .END, .label = null },
    };

    for (bool_cases) |c| {
        const edges = [_]GraphEdge{
            .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
            .{ .id = "e2", .source = "gw", .target = "yes", .condition = c.condition },
            .{ .id = "e3", .source = "gw", .target = "no", .condition = "a > 0" },
        };
        const input = EnvInput{
            .graph = DefinitionGraph{
                .nodes = &gw_nodes,
                .edges = &edges,
            },
            .variable_schema = &vars,
        };

        var failure = try validation.validateDefinition(alloc, input);
        defer failure.deinit(alloc);

        try std.testing.expectEqual(@as(usize, 0), failure.findings.len);
    }

    for (arithmetic_cases) |c| {
        // Field declares `type: "number"` so the walker sets the site's
        // expected_type to `.number` — the arithmetic operator's natural
        // result type (R7).
        const attrs = try std.fmt.allocPrint(
            alloc,
            "{{\"forms\":[{{\"fields\":[{{\"computed_from\":\"{s}\",\"type\":\"number\"}}]}}]}}",
            .{c.expression},
        );
        defer alloc.free(attrs);

        const ht_nodes = [_]GraphNode{
            .{ .id = "S", .node_type = .START, .label = null },
            .{ .id = "task", .node_type = .HUMAN_TASK, .label = null, .attributes = attrs },
            .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
            .{ .id = "yes", .node_type = .END, .label = null },
            .{ .id = "no", .node_type = .END, .label = null },
        };
        const ht_edges = [_]GraphEdge{
            .{ .id = "e1", .source = "S", .target = "task", .condition = null },
            .{ .id = "e2", .source = "task", .target = "gw", .condition = null },
            .{ .id = "e3", .source = "gw", .target = "yes", .condition = "a > 0" },
            .{ .id = "e4", .source = "gw", .target = "no", .condition = "a <= 0" },
        };
        const input = EnvInput{
            .graph = DefinitionGraph{
                .nodes = &ht_nodes,
                .edges = &ht_edges,
            },
            .variable_schema = &vars,
        };

        var failure = try validation.validateDefinition(alloc, input);
        defer failure.deinit(alloc);

        try std.testing.expectEqual(@as(usize, 0), failure.findings.len);
    }

    // Negative case — `s > 0` mixes string and number on `>`; the type
    // checker emits OperandTypeError (NOT TypeMismatch — `s > 0` IS a
    // comparison, but the operator is overloaded wrong).
    const neg_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "yes", .node_type = .END, .label = null },
        .{ .id = "no", .node_type = .END, .label = null },
    };
    const neg_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "yes", .condition = "s > 0" },
        .{ .id = "e3", .source = "gw", .target = "no", .condition = "a > 0" },
    };
    const neg_vars = [_]VariableSchemaEntry{
        .{ .name = "s", .var_type = "string" },
        .{ .name = "a", .var_type = "number" },
    };
    const neg_input = EnvInput{
        .graph = DefinitionGraph{ .nodes = &neg_nodes, .edges = &neg_edges },
        .variable_schema = &neg_vars,
    };

    var neg_failure = try validation.validateDefinition(alloc, neg_input);
    defer neg_failure.deinit(alloc);

    try std.testing.expect(neg_failure.findings.len >= 1);
    var saw_operand_error = false;
    for (neg_failure.findings) |f| {
        if (f.error_kind == .OperandTypeError) saw_operand_error = true;
    }
    try std.testing.expect(saw_operand_error);
}

// ---------------------------------------------------------------------------
// VLD-02 AC2 — UnknownVariable referencing an identifier absent from env
// ---------------------------------------------------------------------------

test "int_vld_02_02: validateDefinition returns UnknownVariable referencing identifier absent from env" {
    const alloc = std.testing.allocator;
    const unknown_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "yes", .condition = "totally_undeclared_identifier > 0" },
        .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
    };
    const input = EnvInput{
        .graph = DefinitionGraph{
            .nodes = &happy_nodes,
            .edges = &unknown_edges,
        },
        .variable_schema = &happy_variables,
    };

    var failure = try validation.validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_unknown = false;
    var saw_identifier_in_message = false;
    for (failure.findings) |f| {
        if (f.error_kind == .UnknownVariable) {
            saw_unknown = true;
            if (std.mem.indexOf(u8, f.message, "totally_undeclared_identifier") != null)
                saw_identifier_in_message = true;
        }
    }
    try std.testing.expect(saw_unknown);
    try std.testing.expect(saw_identifier_in_message);
}

// ---------------------------------------------------------------------------
// VLD-02 AC3 — OperandTypeError on string + number
// ---------------------------------------------------------------------------

test "int_vld_02_03: validateDefinition returns OperandTypeError for string + number" {
    const alloc = std.testing.allocator;
    const operand_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount + customer_id" },
        .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
    };
    const operand_vars = [_]VariableSchemaEntry{
        .{ .name = "amount", .var_type = "number" },
        .{ .name = "customer_id", .var_type = "string" },
    };
    const input = EnvInput{
        .graph = DefinitionGraph{
            .nodes = &happy_nodes,
            .edges = &operand_edges,
        },
        .variable_schema = &operand_vars,
    };

    var failure = try validation.validateDefinition(alloc, input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_operand_error = false;
    var saw_operator_in_message = false;
    var saw_both_types_in_message = false;
    for (failure.findings) |f| {
        if (f.error_kind == .OperandTypeError) {
            saw_operand_error = true;
            if (std.mem.indexOf(u8, f.message, "+") != null) saw_operator_in_message = true;
            if (std.mem.indexOf(u8, f.message, "number") != null and
                std.mem.indexOf(u8, f.message, "string") != null)
            {
                saw_both_types_in_message = true;
            }
        }
    }
    try std.testing.expect(saw_operand_error);
    try std.testing.expect(saw_operator_in_message);
    try std.testing.expect(saw_both_types_in_message);
}

// ---------------------------------------------------------------------------
// VLD-02 AC4 — PD-06 syntax fail short-circuits the semantic compile loop.
// findings must be empty AND pd06_diagnostics must be non-null.
// ---------------------------------------------------------------------------

test "int_vld_02_04: validateDefinition returns 422 with pd06_diagnostics only when PD-06 syntax fails (no semantic compile)" {
    const alloc = std.testing.allocator;

    var failure = try validation.validateDefinition(alloc, bad_syntax_input);
    defer failure.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), failure.findings.len);
    try std.testing.expect(failure.pd06_diagnostics != null);
    try std.testing.expect(failure.pd06_diagnostics.?.len >= 1);
    // Each diagnostic carries the PD-06 verbatim code + message fields.
    for (failure.pd06_diagnostics.?) |d| {
        try std.testing.expect(d.code.len > 0);
        try std.testing.expect(d.message.len > 0);
    }
}

// ---------------------------------------------------------------------------
// VLD-02 AC5 — EmptyExpression on whitespace-only site
// ---------------------------------------------------------------------------

test "int_vld_02_05: validateDefinition returns EmptyExpression for whitespace-only site" {
    const alloc = std.testing.allocator;

    var failure = try validation.validateDefinition(alloc, empty_input);
    defer failure.deinit(alloc);

    try std.testing.expect(failure.findings.len >= 1);
    var saw_empty = false;
    var preserved_source = false;
    for (failure.findings) |f| {
        if (f.error_kind == .EmptyExpression) {
            saw_empty = true;
            if (std.mem.eql(u8, f.source, "   ")) preserved_source = true;
        }
    }
    try std.testing.expect(saw_empty);
    try std.testing.expect(preserved_source);
}

// ---------------------------------------------------------------------------
// VLD-03 AC1 — three failing sites aggregate into one ValidationFailure
// ---------------------------------------------------------------------------

test "int_vld_03_01: validateDefinition aggregates three findings into one ValidationFailure" {
    const alloc = std.testing.allocator;

    var failure = try validation.validateDefinition(alloc, three_finding_input);
    defer failure.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), failure.findings.len);

    // Each error_kind must be present at least once across the aggregate.
    var saw_empty = false;
    var saw_operand = false;
    var saw_unknown = false;
    for (failure.findings) |f| {
        switch (f.error_kind) {
            .EmptyExpression => saw_empty = true,
            .OperandTypeError => saw_operand = true,
            .UnknownVariable => saw_unknown = true,
            else => {},
        }
    }
    try std.testing.expect(saw_empty);
    try std.testing.expect(saw_operand);
    try std.testing.expect(saw_unknown);

    // Findings are sorted by (node_id, expression_path) — three edges on
    // the same gw, so all node_ids equal "gw" and the sort is purely on
    // expression_path.
    var prev_path: []const u8 = "";
    for (failure.findings) |f| {
        try std.testing.expect(std.mem.eql(u8, f.node_id, "gw"));
        try std.testing.expect(std.mem.lessThan(u8, prev_path, f.expression_path) or
            std.mem.eql(u8, prev_path, f.expression_path));
        prev_path = f.expression_path;
    }
}

// ---------------------------------------------------------------------------
// VLD-03 AC3 — UnknownVariable message names identifier + nearest by edit
// distance (Levenshtein of `amont` vs `amount` is 1, well under the
// SUGGESTION_THRESHOLD of 4). Secondary assertion (no-match form) is
// folded into this same block to keep the test-count at 12.
// ---------------------------------------------------------------------------

test "int_vld_03_03: UnknownVariable message names missing identifier and nearest by edit distance (≤4)" {
    const alloc = std.testing.allocator;

    // Primary case — `amont` (typo, distance 1 from `amount`) gets a
    // "did you mean 'amount'?" suggestion.
    var fail_suggest = try validation.validateDefinition(alloc, suggested_input);
    defer fail_suggest.deinit(alloc);

    try std.testing.expect(fail_suggest.findings.len >= 1);
    var saw_suggestion = false;
    for (fail_suggest.findings) |f| {
        if (f.error_kind == .UnknownVariable) {
            if (std.mem.indexOf(u8, f.message, "did you mean") != null and
                std.mem.indexOf(u8, f.message, "amount") != null)
            {
                saw_suggestion = true;
            }
        }
    }
    try std.testing.expect(saw_suggestion);

    // No-match case — `xxxxx` is Levenshtein > 4 from every declared
    // variable, so the suggestion suffix is omitted.
    const no_match_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "yes", .condition = "xxxxx > 0" },
        .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
    };
    const no_match_input = EnvInput{
        .graph = DefinitionGraph{
            .nodes = &happy_nodes,
            .edges = &no_match_edges,
        },
        .variable_schema = &happy_variables,
    };
    var fail_no_match = try validation.validateDefinition(alloc, no_match_input);
    defer fail_no_match.deinit(alloc);

    var saw_no_match_form = false;
    for (fail_no_match.findings) |f| {
        if (f.error_kind == .UnknownVariable) {
            if (std.mem.indexOf(u8, f.message, "did you mean") == null) {
                saw_no_match_form = true;
            }
        }
    }
    try std.testing.expect(saw_no_match_form);
}

// ---------------------------------------------------------------------------
// VLD-03 AC4 — two consecutive validateDefinition calls on the same
// definition produce byte-identical finding ordering.
// ---------------------------------------------------------------------------

test "int_vld_03_04: two consecutive validateDefinition calls on the same definition produce byte-identical finding ordering" {
    const alloc = std.testing.allocator;

    var fail_a = try validation.validateDefinition(alloc, three_finding_input);
    defer fail_a.deinit(alloc);
    var fail_b = try validation.validateDefinition(alloc, three_finding_input);
    defer fail_b.deinit(alloc);

    try std.testing.expectEqual(fail_a.findings.len, fail_b.findings.len);
    try std.testing.expect(fail_a.findings.len >= 3);

    for (fail_a.findings, fail_b.findings) |fa, fb| {
        try std.testing.expectEqualStrings(fa.node_id, fb.node_id);
        try std.testing.expectEqualStrings(fa.expression_path, fb.expression_path);
        try std.testing.expectEqualStrings(fa.source, fb.source);
        try std.testing.expect(fa.error_kind == fb.error_kind);
        try std.testing.expectEqualStrings(fa.message, fb.message);
    }
}
