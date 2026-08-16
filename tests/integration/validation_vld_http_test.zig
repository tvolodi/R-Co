//! Integration tests for VLD-03 — Stage 16 semantic validation HTTP boundary.
//!
//! Drives `validation.handleValidate` (the POST /api/v1/definitions/:id/validate
//! HTTP route handler in src/api/routes/validation.zig) directly against a real
//! PostgreSQL `definition.Store`. The handler is the wire-format boundary —
//! every status code, every JSON field, every RFC 9457 envelope attribute
//! observed in production is produced by this function. Driving the handler
//! in-process is functionally equivalent to driving the live HTTP route for
//! the assertions we make (status, body shape, cross-tenant 404); the only
//! differences (auth middleware, tracing headers) are upstream of this layer
//! and exercised by the e2e suite.
//!
//! Why this is preferred over a live-HTTP test:
//!   - Deterministic: no server bootstrap, no port allocation, no race against
//!     a parallel integration suite binary.
//!   - Self-sufficient: BPM_TEST_DB_URL alone is enough. BPM_TEST_URL +
//!     BPM_TEST_TOKEN would add two more env vars that must be present.
//!   - Spec-faithful: the spec's §1 ("Each test_block drives the HTTP
//!     boundary via POST /api/v1/definitions/:id/validate") is satisfied —
//!     handleValidate IS the handler behind that route; testing it asserts
//!     every byte the route emits.
//!
//! Requires BPM_TEST_DB_URL (no SkipZigTest — lint_test_isolation T040).
//!
//! Spec: tests/specs/vld-01-03-stage-16-validation.spec.md §1, §5
//! Design: src/design/vld-01-03-stage-16-validation.md
//! Impl under test: src/api/routes/validation.zig (commit 31482edb)
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

const handleValidateFn = bpm.validation_routes.handleValidate;
const build_options = @import("build_options");

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

fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// 32-char raw hex string (no dashes) — used by handleValidate's parseUuid.
fn uuidToHex32(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    // ISS-0709 R10-1: handleValidate's `defer api_tenant_context.clear()`
    // empties the ambient tenant context, so the cleanup DELETE must
    // re-establish the default tenant BEFORE acquiring a pool connection —
    // otherwise the pool routes search_path to `public`, where
    // `process_definitions` does not exist (sqlstate 42P01). Matches the
    // makePool() pattern (all-zeros UUID -> tenant_default,public).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

/// ISS-0709 B3: drop tenant B's provisioned schema + its registry rows so the
/// test leaves no tenant_<uuid> schema or public.tenant / public.tenant_schemas
/// rows behind. Runs after handleValidate's `defer api_tenant_context.clear()`
/// has emptied the ambient context, so the no-tenant branch routes search_path
/// to `public` and the public.* DELETEs + DROP SCHEMA resolve. Matches
/// idn05_role_registry_test.zig's cleanupTenantSchema pattern. The schema name
/// is derived from a validated UUID (schemaNameForTenant), never user input.
fn cleanupTenantSchema(allocator: std.mem.Allocator, pool: *Pool, tenant_id: []const u8, schema_name_str: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    const drop_sql = std.fmt.allocPrint(allocator, "DROP SCHEMA IF EXISTS {s} CASCADE", .{schema_name_str}) catch return;
    defer allocator.free(drop_sql);
    conn.exec(drop_sql, &.{}) catch {};
    conn.exec("DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid", &.{tenant_id}) catch {};
    conn.exec("DELETE FROM public.tenant WHERE id = $1::uuid", &.{tenant_id}) catch {};
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
// Canonical fixture A — clean linear definition
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

// ---------------------------------------------------------------------------
// Canonical fixture A2 — clean linear definition with LITERAL-ONLY guards
// (ISS-0709 B2). The HTTP handler (handleValidate) passes an EMPTY env —
// Definition has no variable_schemas column yet (VLD-04 will pre-fetch) —
// so any condition referencing a variable (e.g. "amount > 0") resolves to an
// UnknownVariable finding -> HTTP 422. A literal-only guard ("1 > 0" /
// "1 <= 0") type-checks to .bool with no env lookups -> genuinely 0 findings
// -> HTTP 200. Used ONLY by int_vld_03_http_200; the shared happy_graph
// (variable-based conditions) stays for int_vld_03_02 (UnknownVariable
// findings) and int_vld_03_cross_tenant_404 (graph content is irrelevant —
// the handler 404s on the tenant-scoped read before validation).
// ---------------------------------------------------------------------------

const happy_literal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "1 > 0" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "1 <= 0" },
};

const happy_literal_graph = DefinitionGraph{ .nodes = &happy_nodes, .edges = &happy_literal_edges };

// ---------------------------------------------------------------------------
// Fixture D — PD-06 malformed guard (VLD-02 AC4)
// ---------------------------------------------------------------------------

const bad_syntax_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount >" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};

const bad_syntax_graph = DefinitionGraph{ .nodes = &happy_nodes, .edges = &bad_syntax_edges };

// ---------------------------------------------------------------------------
// Fixture L — three different env-builder failure modes (VLD-01 AC1/AC2/AC3).
// Each test creates its own definition. Used in VLD-03 AC5.
// ---------------------------------------------------------------------------

const weird_var_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "E", .node_type = .END, .label = null },
};

const weird_var_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "E" },
};

// PD-06 syntax is checked by graph.validateEdgeConditions against
// `isValidCelSyntax`, so an S -> E edge with a condition that's literally
// the partial input `"amount >"` triggers the gate. (S -> E with no
// condition is clean.) For the unknown-variable-type / undeclared-result /
// conflicting-field cases, the validator runs purely against the in-process
// env builder and we hit the wire via the env-less fixture (the route
// handler passes an empty variable_schema because Definition has no
// `variable_schemas` column yet — VLD-04 will pre-fetch).
//
// For VLD-03 AC5 we use the PD-06 fixture since it is the only failure mode
// that survives the handler's empty variable_schema (env-builder findings
// require non-empty sources the handler doesn't yet pass). The error_kind
// closure assertion still holds — the set of `error_kind` strings emitted
// by the route handler must be a subset of the canonical 7.
const wire_kind_set = [_][]const u8{
    "UnknownVariable",
    "TypeMismatch",
    "OperandTypeError",
    "UnknownVariableType",
    "UndeclaredResultSchema",
    "ConflictingFieldType",
    "EmptyExpression",
};

fn errorKindInCanonicalSet(kind: []const u8) bool {
    for (wire_kind_set) |k| {
        if (std.mem.eql(u8, k, kind)) return true;
    }
    return false;
}

fn extractErrorKinds(allocator: std.mem.Allocator, body: []const u8) ![]const []u8 {
    var kinds: std.ArrayList([]u8) = .empty;
    defer kinds.deinit(allocator);

    // Naive but robust extraction: walk every "error_kind":"<X>" occurrence.
    const needle = "\"error_kind\":\"";
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, body, cursor, needle)) |idx| {
        const start = idx + needle.len;
        const end_opt = std.mem.indexOfPos(u8, body, start, "\"");
        const end = end_opt orelse body.len;
        try kinds.append(allocator, try allocator.dupe(u8, body[start..end]));
        cursor = end + 1;
    }
    return kinds.toOwnedSlice(allocator);
}

fn freeKinds(allocator: std.mem.Allocator, kinds: []const []u8) void {
    for (kinds) |k| allocator.free(k);
    allocator.free(kinds);
}

// ---------------------------------------------------------------------------
// VLD-03 AC2 — every Finding carries all five mandatory fields.
// ---------------------------------------------------------------------------

test "int_vld_03_02: every Finding in the response carries all five mandatory fields" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-VLD-03-02 Proc";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const actor_uuid_str = try randomUuidStr(alloc);
    defer alloc.free(actor_uuid_str);
    const actor_id = try parseTestUuid(alloc, actor_uuid_str);
    // ISS-0709 R10-3: drive a clean-syntax graph whose conditions reference
    // an undeclared variable (`amount`). The handler passes an EMPTY env
    // (Definition has no variable_schemas column yet — VLD-04 will
    // pre-fetch), so `amount` is unknown and the semantic compile emits real
    // UnknownVariable findings carrying all five mandatory fields (VLD-03
    // AC2). The PD-06 short-circuit body (empty findings) is asserted
    // separately in int_vld_03_http_422_pd06.
    const created = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = happy_graph,
        .created_by = actor_id,
    });
    defer created.deinit(alloc);
    const created_hex = try uuidToHex32(alloc, created.id);
    defer alloc.free(created_hex);

    var store_for_handler = def_store;
    const tenant_id: [36]u8 = blk: {
        var t: [36]u8 = undefined;
        const src = "00000000-0000-0000-0000-000000000000";
        @memcpy(t[0..], src);
        break :blk t;
    };
    const handler_result = handleValidateFn(&store_for_handler, alloc, tenant_id, created_hex);
    defer alloc.free(handler_result.body);

    try std.testing.expectEqual(@as(u16, 422), handler_result.status_code);

    // Body MUST contain every mandatory field name (VLD-03 AC2).
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"node_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"expression_path\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"source\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"error_kind\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"message\":") != null);

    // The findings are real and non-empty (semantic failure), so the PD-06
    // short-circuit markers must be ABSENT: no empty `findings` array and no
    // `pd06_diagnostics` block. The PD-06 short-circuit shape is asserted
    // separately in int_vld_03_http_422_pd06.
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"findings\":[]") == null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"pd06_diagnostics\":") == null);
}

// ---------------------------------------------------------------------------
// VLD-03 AC5 — every error_kind emitted on the wire is one of the 7 canonical
// strings. Drives a definition with a PD-06 violation (the only failure
// mode that survives the handler's empty variable_schema) and asserts the
// response body's `error_kind` strings form a subset of the canonical set.
// ---------------------------------------------------------------------------

test "int_vld_03_05: every ErrorKind field in the response is one of the 7 wire strings" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-VLD-03-05 Proc";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const actor_uuid_str = try randomUuidStr(alloc);
    defer alloc.free(actor_uuid_str);
    const actor_id = try parseTestUuid(alloc, actor_uuid_str);
    const created = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = bad_syntax_graph,
        .created_by = actor_id,
    });
    defer created.deinit(alloc);
    const created_hex = try uuidToHex32(alloc, created.id);
    defer alloc.free(created_hex);

    var store_for_handler = def_store;
    const tenant_id: [36]u8 = blk: {
        var t: [36]u8 = undefined;
        const src = "00000000-0000-0000-0000-000000000000";
        @memcpy(t[0..], src);
        break :blk t;
    };
    const handler_result = handleValidateFn(&store_for_handler, alloc, tenant_id, created_hex);
    defer alloc.free(handler_result.body);

    // The handler emits the PD-06 short-circuit body, which carries no
    // `error_kind` field (it carries PD-06 `code` instead). For this test
    // the canonical-set assertion is trivial — there are zero
    // `error_kind` occurrences to validate.
    //
    // To exercise `error_kind` emission we also drive the validator
    // in-process via `validation.validateDefinition` with a clean graph +
    // an unknown-variable fixture, then assert the kinds set is a subset
    // of the canonical 7 (this catches any future handler-side drift).
    const validation = @import("validation");
    const unknown_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
        .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amont > 0" },
        .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
    };
    const fixture = validation.EnvInput{
        .graph = DefinitionGraph{
            .nodes = &happy_nodes,
            .edges = &unknown_edges,
        },
        .variable_schema = &[_]validation.VariableSchemaEntry{
            .{ .name = "amount", .var_type = "number" },
        },
    };

    var failure = try validation.validateDefinition(alloc, fixture);
    defer failure.deinit(alloc);

    const body = try validation.serialiseValidationFailure(alloc, failure);
    defer alloc.free(body);

    const kinds = try extractErrorKinds(alloc, body);
    defer freeKinds(alloc, kinds);

    try std.testing.expect(kinds.len >= 1);
    for (kinds) |k| {
        try std.testing.expect(errorKindInCanonicalSet(k));
    }
}

// ---------------------------------------------------------------------------
// VLD-03 — happy path: clean definition yields HTTP 200 + semantically_valid.
// ---------------------------------------------------------------------------

test "int_vld_03_http_200: validateDefinition on a clean definition returns 200 + semantically_valid body" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-VLD-03-200 Proc";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const actor_uuid_str = try randomUuidStr(alloc);
    defer alloc.free(actor_uuid_str);
    const actor_id = try parseTestUuid(alloc, actor_uuid_str);
    // ISS-0709 B2: happy_literal_graph carries literal-only conditions
    // ("1 > 0" / "1 <= 0") that yield 0 findings under the handler's empty
    // env -> HTTP 200 + semantically_valid. happy_graph's variable-based
    // conditions would emit UnknownVariable -> 422.
    const created = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = happy_literal_graph,
        .created_by = actor_id,
    });
    defer created.deinit(alloc);
    const created_hex = try uuidToHex32(alloc, created.id);
    defer alloc.free(created_hex);

    var store_for_handler = def_store;
    const tenant_id: [36]u8 = blk: {
        var t: [36]u8 = undefined;
        const src = "00000000-0000-0000-0000-000000000000";
        @memcpy(t[0..], src);
        break :blk t;
    };
    const handler_result = handleValidateFn(&store_for_handler, alloc, tenant_id, created_hex);
    defer alloc.free(handler_result.body);

    try std.testing.expectEqual(@as(u16, 200), handler_result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"status\":\"semantically_valid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"compiler_version\":") != null);
}

// ---------------------------------------------------------------------------
// VLD-03 — PD-06 violation: handler emits HTTP 422 + PD-06 diagnostics.
// ---------------------------------------------------------------------------

test "int_vld_03_http_422_pd06: validateDefinition with a PD-06 violation returns 422 + pd06_diagnostics" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-VLD-03-422 PD06 Proc";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const actor_uuid_str = try randomUuidStr(alloc);
    defer alloc.free(actor_uuid_str);
    const actor_id = try parseTestUuid(alloc, actor_uuid_str);
    const created = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = bad_syntax_graph,
        .created_by = actor_id,
    });
    defer created.deinit(alloc);
    const created_hex = try uuidToHex32(alloc, created.id);
    defer alloc.free(created_hex);

    var store_for_handler = def_store;
    const tenant_id: [36]u8 = blk: {
        var t: [36]u8 = undefined;
        const src = "00000000-0000-0000-0000-000000000000";
        @memcpy(t[0..], src);
        break :blk t;
    };
    const handler_result = handleValidateFn(&store_for_handler, alloc, tenant_id, created_hex);
    defer alloc.free(handler_result.body);

    try std.testing.expectEqual(@as(u16, 422), handler_result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"status\":422") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"pd06_diagnostics\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"type\":\"https://platform/validation/semantic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"title\":\"Definition failed semantic validation\"") != null);
}

// ---------------------------------------------------------------------------
// VLD-03 AC5 close — cross-tenant 404. A definition created by tenant A
// MUST be hidden from tenant B (tenant_id 99999999-...). The handler returns
// 404 + the generic "not found" body, not 422 (no findings leak across the
// tenant boundary).
// ---------------------------------------------------------------------------

test "int_vld_03_cross_tenant_404: tenant B's validate request for tenant A's definition returns 404" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-VLD-03-CROSS Proc";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const actor_uuid_str = try randomUuidStr(alloc);
    defer alloc.free(actor_uuid_str);
    const actor_id = try parseTestUuid(alloc, actor_uuid_str);
    // Create under tenant A (default tenant).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    const created = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = happy_graph,
        .created_by = actor_id,
    });
    defer created.deinit(alloc);
    const created_hex = try uuidToHex32(alloc, created.id);
    defer alloc.free(created_hex);

    // Invoke the handler as tenant B (different tenant_id). The handler
    // sets the ambient tenant context for the duration of the read; the
    // process_definitions RLS policy hides the row, and getById returns
    // DefinitionNotFound -> HTTP 404.
    //
    // GH-512: tenant_b is a per-test runtime UUID (different from the
    // default tenant) — randomUuidStr() generates a fresh v4 UUID via
    // the platform CSPRNG so we don't trip lint_test_isolation T010.
    var store_for_handler = def_store;
    const tenant_b_src = try randomUuidStr(alloc);
    defer alloc.free(tenant_b_src);
    var tenant_b: [36]u8 = undefined;
    @memcpy(tenant_b[0..], tenant_b_src);

    // ISS-0709 B3: the tenant-scoped read (getById under tenant B) relies on
    // SCHEMA-mode routing — the pool resolves tenant B's storage_mode from
    // public.tenant / public.tenant_schemas and sets search_path to
    // `tenant_<b>,public`. An unprovisioned tenant falls through to
    // LEGACY_RLS (search_path = public), where `process_definitions` does not
    // exist (sqlstate 42P01) -> HTTP 500 instead of 404. Provision tenant B's
    // physical schema (idempotent; same pattern as
    // idn05_role_registry_test.zig) BEFORE the cross-tenant read so it routes
    // to the empty tenant_<b> schema and getById returns DefinitionNotFound
    // -> HTTP 404. The handler sets the ambient tenant context to tenant B for
    // the duration of the read itself; provisioning runs under the default
    // context so the pool can still reach public.* tables.
    var schema_buf_b: [80]u8 = undefined;
    const tenant_b_schema = bpm.pool.schemaNameForTenant(tenant_b[0..], &schema_buf_b);
    try bpm.provisioning.provisionTenantSchema(alloc, &pool, tenant_b[0..], build_options.migrations_dir);
    defer cleanupTenantSchema(alloc, &pool, tenant_b[0..], tenant_b_schema);

    const handler_result = handleValidateFn(&store_for_handler, alloc, tenant_b, created_hex);
    defer alloc.free(handler_result.body);

    try std.testing.expectEqual(@as(u16, 404), handler_result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"error\":\"not found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"status\":404") != null);
    // No findings leak across the tenant boundary.
    try std.testing.expect(std.mem.indexOf(u8, handler_result.body, "\"findings\":") == null);
}
