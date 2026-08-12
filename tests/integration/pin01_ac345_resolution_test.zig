//! Integration tests for PIN-01, SCOPED to AC3 (VariableSchemaViolation), AC4
//! (UnresolvedPinOverride), AC5 (deterministic pinned_versions[] ordering) —
//! per this batch's explicit scoping (src/design/pin-01-dependency-version-
//! resolution.md Scoping note; ISS-0672 / GH-306 tracks AC1/AC2). See
//! tests/specs/PIN-01.md for the full scoping table.
//!
//! Traces to, does not duplicate, tests/integration/
//! pin01_service_catalog_tenant_scope_test.zig (3 cases, REWORK 1 tenant-
//! isolation coverage of resolveServiceCatalogRef()).
//!
//! BPM_TEST_DB_URL must be set; connects to a real PostgreSQL (DIRECTIVE T-1).
const std = @import("std");
const portable_env = @import("env");
const pg = @import("pg");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");

pub const api_tenant_context = bpm.api_tenant_context;

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const PinResolver = bpm.pin_resolver.PinResolver;
const ResolutionInput = bpm.pin_resolver.ResolutionInput;
const ResolutionError = bpm.pin_resolver.ResolutionError;
const PinnedVersion = bpm.pin_resolver.PinnedVersion;
const PinKind = bpm.pin_resolver.PinKind;
const PinSource = bpm.pin_resolver.PinSource;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;

// ---------------------------------------------------------------------------
// Helpers (mirrors pin01_service_catalog_tenant_scope_test.zig's conventions)
// ---------------------------------------------------------------------------

fn randomId(buf: *[8]u8) []const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    helpers.fillRandom(buf);
    for (buf) |*b| b.* = chars[@as(usize, b.*) % chars.len];
    return buf;
}

fn parseUuid36(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    var buf: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= 32) return error.InvalidUuid;
        buf[j] = c;
        j += 1;
    }
    if (j != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

fn testPool(alloc: std.mem.Allocator) !Pool {
    const env = portable_env.globalEnviron();
    const url = env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping pin01 AC3/AC4/AC5 test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
    defer alloc.free(url);
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
}

fn freePinnedVersions(alloc: std.mem.Allocator, pins: []PinnedVersion) void {
    for (pins) |p| {
        alloc.free(p.ref);
        alloc.free(p.resolved_id);
        alloc.free(p.version);
    }
    alloc.free(pins);
}

fn emptyGraph() DefinitionGraph {
    return DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
}

fn oneServiceTaskGraph(allocator: std.mem.Allocator, service_id: []const u8) !DefinitionGraph {
    const attrs = try std.fmt.allocPrint(allocator, "{{\"service_id\":\"{s}\"}}", .{service_id});
    const nodes = try allocator.alloc(GraphNode, 1);
    nodes[0] = GraphNode{
        .id = try allocator.dupe(u8, "svc-task-1"),
        .node_type = .SERVICE_TASK,
        .label = null,
        .attributes = attrs,
    };
    return DefinitionGraph{ .nodes = nodes, .edges = &.{} };
}

fn freeOneServiceTaskGraph(allocator: std.mem.Allocator, graph: DefinitionGraph) void {
    allocator.free(graph.nodes[0].id);
    if (graph.nodes[0].attributes) |a| allocator.free(a);
    allocator.free(graph.nodes);
}

fn insertGlobalServiceViaPool(pool: *Pool, svc_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'global', NULL)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{svc_id},
    );
}

fn deleteServiceCatalogEntry(pool: *Pool, svc_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.service_catalog WHERE service_id = $1", &.{svc_id}) catch {};
}

/// Read the degenerate "version" resolveServiceCatalogRef() would compute for
/// svc_id right now (the updated_at-derived text) — needed to build a VALID
/// pin_overrides entry in TC-PIN-01-03.
fn readCurrentServiceVersion(alloc: std.mem.Allocator, pool: *Pool, svc_id: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        alloc,
        "SELECT (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint FROM public.service_catalog WHERE service_id = $1",
        &.{svc_id},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0].len == 0 or rows.rows[0][0] == null) return error.NotFound;
    return alloc.dupe(u8, rows.rows[0][0].?);
}

/// Create a real process_definitions row (variable_schemas.definition_id has
/// an FK to it) and register a "count: integer >= 0" variable_schemas row.
fn setupDefinitionWithSchema(alloc: std.mem.Allocator, pool: *Pool, name: []const u8) !bpm.definition.Definition {
    var def_store = DefinitionStore.init(alloc, pool);
    defer def_store.deinit();

    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]bpm.definition.GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    const active = try def_store.activate(alloc, draft.id);
    draft.deinit(alloc);

    const def_id_hex = try helpers.uuidBytesToString(alloc, active.id);
    defer alloc.free(def_id_hex);

    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO variable_schemas (definition_id, variable_key, json_schema) VALUES ($1::uuid, $2, $3)",
        &.{ def_id_hex, "count", "{\"type\": \"integer\", \"minimum\": 0}" },
    );

    return active;
}

fn cleanupDefinition(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

// ---------------------------------------------------------------------------
// TC-PIN-01-01 / TC-PIN-01-02: VariableSchemaViolation (AC3)
// ---------------------------------------------------------------------------

// KNOWN FAILING against current code — ISS-0679 / GH-721 (filed during this
// same handoff): PinResolver.validateVariableSchema() passes a single
// FIELD's JSON-serialised scalar value (e.g. "5") to
// registry.validatePayloadAgainstSchema(), whose isJsonObject() guard
// requires a whole JSON OBJECT payload. Every scalar-valued variable is
// therefore reported as a violation regardless of whether it actually
// conforms — this test's conforming payload ({"count":5} against
// {"type":"integer","minimum":0}) still returns VariableSchemaViolation. Real
// fail-first signal for AC3's accepting half. Do NOT silence/skip; fix
// ISS-0679 instead. (TC-PIN-01-02, -03, -04 below also leak memory on this
// same error path — see ISS-0680 / GH-722, filed separately.)
test "TC-PIN-01-01: resolve accepts initial_variables conforming to the registered variable_schema" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const name = try std.fmt.allocPrint(alloc, "TC-PIN-01-01-{s}", .{randomId(&id_buf)});
    defer alloc.free(name);

    const active = try setupDefinitionWithSchema(alloc, &pool, name);
    defer active.deinit(alloc);
    defer cleanupDefinition(&pool, name);

    var resolver = PinResolver.init(&pool);
    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    @memcpy(&def_id_bytes, &active.id);

    const pins = try resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = std.mem.zeroes([16]u8),
        .graph = emptyGraph(),
        .initial_variables = "{\"count\":5}",
        .pin_overrides = null,
    });
    defer freePinnedVersions(alloc, pins);

    var found_vs = false;
    for (pins) |p| {
        if (p.kind == .variable_schema) found_vs = true;
    }
    try std.testing.expect(found_vs);
}

test "TC-PIN-01-02: resolve rejects initial_variables violating the registered variable_schema" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const name = try std.fmt.allocPrint(alloc, "TC-PIN-01-02-{s}", .{randomId(&id_buf)});
    defer alloc.free(name);

    const active = try setupDefinitionWithSchema(alloc, &pool, name);
    defer active.deinit(alloc);
    defer cleanupDefinition(&pool, name);

    var resolver = PinResolver.init(&pool);
    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    @memcpy(&def_id_bytes, &active.id);

    const result = resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = std.mem.zeroes([16]u8),
        .graph = emptyGraph(),
        .initial_variables = "{\"count\":-5}",
        .pin_overrides = null,
    });
    try std.testing.expectError(ResolutionError.VariableSchemaViolation, result);
}

// ---------------------------------------------------------------------------
// TC-PIN-01-03 / TC-PIN-01-04: pin_overrides (AC4)
// ---------------------------------------------------------------------------

test "TC-PIN-01-03: resolve applies a valid pin_overrides entry, source becomes override" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin01ac4-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    const current_version = try readCurrentServiceVersion(alloc, &pool, svc_id);
    defer alloc.free(current_version);

    var resolver = PinResolver.init(&pool);
    const graph = try oneServiceTaskGraph(alloc, svc_id);
    defer freeOneServiceTaskGraph(alloc, graph);

    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    helpers.fillRandom(&def_id_bytes);

    const overrides_json = try std.fmt.allocPrint(
        alloc,
        "[{{\"kind\":\"catalog_entry\",\"ref\":\"{s}\",\"version\":\"{s}\"}}]",
        .{ svc_id, current_version },
    );
    defer alloc.free(overrides_json);

    const pins = try resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = std.mem.zeroes([16]u8),
        .graph = graph,
        .initial_variables = "{}",
        .pin_overrides = overrides_json,
    });
    defer freePinnedVersions(alloc, pins);

    var found_override = false;
    for (pins) |p| {
        if (p.kind == .catalog_entry) {
            try std.testing.expectEqual(PinSource.override, p.source);
            found_override = true;
        }
    }
    try std.testing.expect(found_override);
}

test "TC-PIN-01-04: resolve rejects a pin_overrides entry naming a nonexistent version" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin01ac4b-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var resolver = PinResolver.init(&pool);
    const graph = try oneServiceTaskGraph(alloc, svc_id);
    defer freeOneServiceTaskGraph(alloc, graph);

    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    helpers.fillRandom(&def_id_bytes);

    const overrides_json = try std.fmt.allocPrint(
        alloc,
        "[{{\"kind\":\"catalog_entry\",\"ref\":\"{s}\",\"version\":\"definitely-not-a-real-version\"}}]",
        .{svc_id},
    );
    defer alloc.free(overrides_json);

    const result = resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = std.mem.zeroes([16]u8),
        .graph = graph,
        .initial_variables = "{}",
        .pin_overrides = overrides_json,
    });
    try std.testing.expectError(ResolutionError.UnresolvedPinOverride, result);
}

// ---------------------------------------------------------------------------
// TC-PIN-01-05 / TC-PIN-01-06: deterministic ordering (AC5)
// ---------------------------------------------------------------------------

test "TC-PIN-01-05: resolve produces byte-identical pinned_versions[] across two calls" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin01ac5-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var resolver = PinResolver.init(&pool);
    const graph = try oneServiceTaskGraph(alloc, svc_id);
    defer freeOneServiceTaskGraph(alloc, graph);

    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    helpers.fillRandom(&def_id_bytes);

    const pins1 = try resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = std.mem.zeroes([16]u8),
        .graph = graph,
        .initial_variables = "{}",
        .pin_overrides = null,
    });
    defer freePinnedVersions(alloc, pins1);

    const pins2 = try resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = std.mem.zeroes([16]u8),
        .graph = graph,
        .initial_variables = "{}",
        .pin_overrides = null,
    });
    defer freePinnedVersions(alloc, pins2);

    try std.testing.expectEqual(pins1.len, pins2.len);
    try std.testing.expect(pins1.len == 2); // catalog_entry + variable_schema

    // Ordering: catalog_entry (enum value 0) sorts before variable_schema (1).
    try std.testing.expectEqual(PinKind.catalog_entry, pins1[0].kind);
    try std.testing.expectEqual(PinKind.variable_schema, pins1[1].kind);

    // Byte-identical across both calls, field by field.
    for (pins1, pins2) |p1, p2| {
        try std.testing.expectEqual(p1.kind, p2.kind);
        try std.testing.expectEqualStrings(p1.ref, p2.ref);
        try std.testing.expectEqualStrings(p1.resolved_id, p2.resolved_id);
        try std.testing.expectEqualStrings(p1.version, p2.version);
        try std.testing.expectEqual(p1.source, p2.source);
    }
}

test "TC-PIN-01-06: resolve with zero catalog/module references returns exactly one variable_schema entry" {
    const alloc = std.testing.allocator;
    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try testPool(alloc);
    defer pool.deinit();

    var resolver = PinResolver.init(&pool);
    const conn = try pool.acquire();
    defer pool.release(conn);

    var def_id_bytes: [16]u8 = undefined;
    helpers.fillRandom(&def_id_bytes);

    const pins = try resolver.resolve(alloc, conn, ResolutionInput{
        .definition_id = def_id_bytes,
        .tenant_id = std.mem.zeroes([16]u8),
        .graph = emptyGraph(),
        .initial_variables = "{}",
        .pin_overrides = null,
    });
    defer freePinnedVersions(alloc, pins);

    try std.testing.expectEqual(@as(usize, 1), pins.len);
    try std.testing.expectEqual(PinKind.variable_schema, pins[0].kind);
}
