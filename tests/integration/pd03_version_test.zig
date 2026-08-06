//! Integration tests for PD-03 (Version management — activate).
//!
//! Tests exercise Store.activate() against a real PostgreSQL database.
//! All tests follow DIRECTIVE T-1: no mock DB connections, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//! Every test calls TestHarness.init() to ensure migrations are applied before
//! accessing the Pool / Store.
//!
//! Requirement traceability:
//!   PD-03 → TC-PD-03-01, TC-PD-03-02, TC-PD-03-03, TC-PD-03-04,
//!            TC-PD-03-05, TC-PD-03-06
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const ListOpts = bpm.definition.ListOpts;
const DefinitionError = bpm.definition.DefinitionError;
const DefinitionStatus = bpm.definition.DefinitionStatus;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const Definition = bpm.definition.Definition;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL from the environment.
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

/// Create a Pool pointing to the test database.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Parse a UUID string (with hyphens) into [16]u8.
fn parseUuid(allocator: std.mem.Allocator, s: []const u8) ![16]u8 {
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
    _ = allocator;
    return out;
}

/// Delete all versions of a given process name (best-effort cleanup).
fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &.{name},
    ) catch {};
}

/// Force a specific status on a definition row (for test setup only).
/// Uses name + version to locate the row — never used in production paths.
fn forceStatus(pool: *Pool, name: []const u8, version: []const u8, status: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "UPDATE process_definitions SET status = $1 WHERE name = $2 AND version = $3",
        &.{ status, name, version },
    ) catch {};
}

/// Free heap-allocated fields of a Definition returned by Store methods.
fn freeDefinition(allocator: std.mem.Allocator, def: Definition) void {
    allocator.free(def.name);
    allocator.free(def.version);
    if (def.description) |d| allocator.free(d);
    bpm.definition.freeDefinitionGraph(allocator, def.graph);
}

/// Free all Definitions in a slice and the slice itself.
fn freeDefinitionSlice(allocator: std.mem.Allocator, defs: []Definition) void {
    for (defs) |d| freeDefinition(allocator, d);
    allocator.free(defs);
}

/// Fixed creator UUID used in all tests — no FK constraint on created_by.
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

// ---------------------------------------------------------------------------
// Minimal valid graph reused by multiple tests.
// START → HUMAN_TASK → END
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null },
};

const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null },
};

const minimal_graph = DefinitionGraph{
    .nodes = &minimal_nodes,
    .edges = &minimal_edges,
};

// ---------------------------------------------------------------------------
// TC-PD-03-01: Prior ACTIVE version is atomically deprecated on new activation
// ---------------------------------------------------------------------------

test "TC-PD-03-01: activate V2 when V1 is ACTIVE sets V1 to DEPRECATED atomically" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-03-01 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create V1 (DRAFT).
    const v1 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v1);

    // Activate V1 → should become ACTIVE.
    const v1_active = try def_store.activate(alloc, v1.id);
    defer freeDefinition(alloc, v1_active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, v1_active.status);

    // Create V2 (DRAFT).
    const v2 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "2.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v2);

    // Activate V2 → V2 becomes ACTIVE; V1 must become DEPRECATED atomically.
    const v2_active = try def_store.activate(alloc, v2.id);
    defer freeDefinition(alloc, v2_active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, v2_active.status);

    // Confirm V1 is now DEPRECATED.
    const v1_now = try def_store.getById(alloc, v1.id);
    defer freeDefinition(alloc, v1_now);
    try std.testing.expectEqual(DefinitionStatus.DEPRECATED, v1_now.status);
}

// ---------------------------------------------------------------------------
// TC-PD-03-02: At no point may two versions of the same name simultaneously
//              be ACTIVE
// ---------------------------------------------------------------------------

test "TC-PD-03-02: list(status=ACTIVE) returns exactly one version per name after V2 activation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-03-02 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create and activate V1.
    const v1 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v1);

    const v1_active = try def_store.activate(alloc, v1.id);
    defer freeDefinition(alloc, v1_active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, v1_active.status);

    // Create and activate V2.
    const v2 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "2.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v2);

    const v2_active = try def_store.activate(alloc, v2.id);
    defer freeDefinition(alloc, v2_active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, v2_active.status);

    // list(name=N, status=ACTIVE) MUST return exactly 1 result — the invariant.
    const active_defs = try def_store.list(alloc, ListOpts{
        .name = name,
        .status = DefinitionStatus.ACTIVE,
        .after_created = null,
        .limit = 10,
    });
    defer freeDefinitionSlice(alloc, active_defs);

    try std.testing.expectEqual(@as(usize, 1), active_defs.len);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, active_defs[0].status);
}

// ---------------------------------------------------------------------------
// TC-PD-03-03: First activation of a name — no prior deprecation side-effect
// ---------------------------------------------------------------------------

test "TC-PD-03-03: first activation of a name succeeds with status ACTIVE and no side-effects" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-03-03 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create first-ever version for this name (DRAFT).
    const v1 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v1);

    // Activate — no prior ACTIVE version exists for this name.
    const v1_active = try def_store.activate(alloc, v1.id);
    defer freeDefinition(alloc, v1_active);

    // Must return ACTIVE.
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, v1_active.status);

    // list(name=N) must return exactly one row — no spurious DEPRECATED rows.
    const all_defs = try def_store.list(alloc, ListOpts{
        .name = name,
        .status = null,
        .after_created = null,
        .limit = 10,
    });
    defer freeDefinitionSlice(alloc, all_defs);

    try std.testing.expectEqual(@as(usize, 1), all_defs.len);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, all_defs[0].status);
}

// ---------------------------------------------------------------------------
// TC-PD-03-04: Listing by status=ACTIVE returns at most one version per name
// ---------------------------------------------------------------------------

test "TC-PD-03-04: list filtered by status=ACTIVE returns at most one version per name" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-03-04 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create and activate V1 (will be deprecated when V2 is activated).
    const v1 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v1);

    const v1_active = try def_store.activate(alloc, v1.id);
    defer freeDefinition(alloc, v1_active);

    // Create and activate V2 (V1 becomes DEPRECATED, V2 becomes ACTIVE).
    const v2 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "2.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v2);

    const v2_active = try def_store.activate(alloc, v2.id);
    defer freeDefinition(alloc, v2_active);

    // Filter: name=N, status=ACTIVE → must yield exactly one row (V2).
    const active_defs = try def_store.list(alloc, ListOpts{
        .name = name,
        .status = DefinitionStatus.ACTIVE,
        .after_created = null,
        .limit = 50,
    });
    defer freeDefinitionSlice(alloc, active_defs);

    // At most one ACTIVE version per name (the requirement mandates this).
    try std.testing.expect(active_defs.len <= 1);
    if (active_defs.len == 1) {
        try std.testing.expectEqual(DefinitionStatus.ACTIVE, active_defs[0].status);
        try std.testing.expectEqualStrings("2.0", active_defs[0].version);
    }
}

// ---------------------------------------------------------------------------
// TC-PD-03-05: Activating the already-ACTIVE version returns AlreadyActive
// ---------------------------------------------------------------------------

test "TC-PD-03-05: activating an already-ACTIVE definition returns AlreadyActive" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-03-05 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create and activate V1.
    const v1 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v1);

    const v1_active = try def_store.activate(alloc, v1.id);
    defer freeDefinition(alloc, v1_active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, v1_active.status);

    // Activate again — must return AlreadyActive (HTTP 200 via handler layer).
    _ = def_store.activate(alloc, v1.id) catch |err| {
        try std.testing.expectEqual(DefinitionError.AlreadyActive, err);
    };

    // Invariant still holds: exactly one ACTIVE version.
    const active_defs = try def_store.list(alloc, ListOpts{
        .name = name,
        .status = DefinitionStatus.ACTIVE,
        .after_created = null,
        .limit = 10,
    });
    defer freeDefinitionSlice(alloc, active_defs);

    try std.testing.expectEqual(@as(usize, 1), active_defs.len);
}

// ---------------------------------------------------------------------------
// TC-PD-03-06: Activating a DEPRECATED or ARCHIVED version returns NotDraft
// ---------------------------------------------------------------------------

test "TC-PD-03-06: activating a DEPRECATED definition returns NotDraft" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-03-06 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create and activate V1 (will be deprecated by V2).
    const v1 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v1);

    const v1_active = try def_store.activate(alloc, v1.id);
    defer freeDefinition(alloc, v1_active);

    // Create and activate V2 — V1 becomes DEPRECATED.
    const v2 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "2.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v2);

    const v2_active = try def_store.activate(alloc, v2.id);
    defer freeDefinition(alloc, v2_active);

    // Confirm V1 is DEPRECATED.
    const v1_deprecated = try def_store.getById(alloc, v1.id);
    defer freeDefinition(alloc, v1_deprecated);
    try std.testing.expectEqual(DefinitionStatus.DEPRECATED, v1_deprecated.status);

    // Attempting to re-activate the DEPRECATED V1 must return NotDraft.
    const result = def_store.activate(alloc, v1.id);
    try std.testing.expectError(DefinitionError.NotDraft, result);
}

test "TC-PD-03-06b: activating an ARCHIVED definition returns NotDraft" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-03-06b Process";
    const version = "1.0";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create a DRAFT definition.
    const v1 = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, v1);

    // Force it to ARCHIVED via direct SQL (simulates archive lifecycle step).
    forceStatus(&pool, name, version, "ARCHIVED");

    // Attempting to activate an ARCHIVED definition must return NotDraft.
    const result = def_store.activate(alloc, v1.id);
    try std.testing.expectError(DefinitionError.NotDraft, result);
}
