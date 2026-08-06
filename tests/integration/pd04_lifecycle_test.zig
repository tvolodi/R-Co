//! Integration tests for PD-04 (Definition lifecycle — deprecate and archive).
//!
//! Tests exercise Store.deprecate() and Store.archive() against a real PostgreSQL
//! database. All tests follow DIRECTIVE T-1: no mock DB connections, no stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//! Every test calls TestHarness.init() to ensure migrations are applied before
//! accessing the Pool / Store.
//!
//! Requirement traceability:
//!   PD-04 → TC-PD-04-02, TC-PD-04-03, TC-PD-04-04, TC-PD-04-05,
//!            TC-PD-04-06, TC-PD-04-07, TC-PD-04-08, TC-PD-04-10,
//!            TC-PD-04-11
//!   (TC-PD-04-01 and TC-PD-04-09 are covered by PD-03 tests; TC-PD-04-12 is OUT OF SCOPE)
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
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

/// Free heap-allocated fields of a Definition returned by Store methods.
fn freeDefinition(allocator: std.mem.Allocator, def: Definition) void {
    allocator.free(def.name);
    allocator.free(def.version);
    if (def.description) |d| allocator.free(d);
    bpm.definition.freeDefinitionGraph(allocator, def.graph);
}

/// Fixed creator UUID used in all tests — no FK constraint on created_by.
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

/// Non-existent UUID used in not-found tests — no real row will ever have this id.
const nonexistent_uuid_str = "00000000-0000-4000-8000-000000000000";

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
// TC-PD-04-02: ACTIVE → DEPRECATED via deprecate() — success
// ---------------------------------------------------------------------------

test "TC-PD-04-02: deprecate() on ACTIVE definition returns DEPRECATED" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-04-02 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create a DRAFT definition.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    // Activate → ACTIVE.
    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, active.status);

    // Deprecate → must return DEPRECATED.
    const deprecated = try def_store.deprecate(alloc, draft.id);
    defer freeDefinition(alloc, deprecated);
    try std.testing.expectEqual(DefinitionStatus.DEPRECATED, deprecated.status);

    // Confirm via getById.
    const fetched = try def_store.getById(alloc, draft.id);
    defer freeDefinition(alloc, fetched);
    try std.testing.expectEqual(DefinitionStatus.DEPRECATED, fetched.status);
}

// ---------------------------------------------------------------------------
// TC-PD-04-03: DEPRECATED → ARCHIVED via archive() — success; archived_at set
// ---------------------------------------------------------------------------

test "TC-PD-04-03: archive() on DEPRECATED definition returns ARCHIVED with archived_at set" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-04-03 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create DRAFT → activate → deprecate to reach DEPRECATED state.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, active.status);

    const deprecated = try def_store.deprecate(alloc, draft.id);
    defer freeDefinition(alloc, deprecated);
    try std.testing.expectEqual(DefinitionStatus.DEPRECATED, deprecated.status);

    // Archive → must return ARCHIVED with archived_at != null.
    const archived = try def_store.archive(alloc, draft.id);
    defer freeDefinition(alloc, archived);
    try std.testing.expectEqual(DefinitionStatus.ARCHIVED, archived.status);
    try std.testing.expect(archived.archived_at != null);

    // Confirm via getById.
    const fetched = try def_store.getById(alloc, draft.id);
    defer freeDefinition(alloc, fetched);
    try std.testing.expectEqual(DefinitionStatus.ARCHIVED, fetched.status);
    try std.testing.expect(fetched.archived_at != null);
}

// ---------------------------------------------------------------------------
// TC-PD-04-04: Forbidden: deprecate() on DRAFT → InvalidStatusTransition
// ---------------------------------------------------------------------------

test "TC-PD-04-04: deprecate() on DRAFT definition returns InvalidStatusTransition" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-04-04 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create DRAFT — do NOT activate.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    // deprecate() on a DRAFT must be rejected.
    const result = def_store.deprecate(alloc, draft.id);
    try std.testing.expectError(DefinitionError.InvalidStatusTransition, result);
}

// ---------------------------------------------------------------------------
// TC-PD-04-05: Forbidden: archive() on DRAFT → InvalidStatusTransition
// ---------------------------------------------------------------------------

test "TC-PD-04-05: archive() on DRAFT definition returns InvalidStatusTransition" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-04-05 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create DRAFT — do NOT activate or deprecate.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    // archive() on a DRAFT must be rejected.
    const result = def_store.archive(alloc, draft.id);
    try std.testing.expectError(DefinitionError.InvalidStatusTransition, result);
}

// ---------------------------------------------------------------------------
// TC-PD-04-06: Forbidden: archive() on ACTIVE → InvalidStatusTransition
// ---------------------------------------------------------------------------

test "TC-PD-04-06: archive() on ACTIVE definition returns InvalidStatusTransition" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-04-06 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Create DRAFT then activate — do NOT deprecate.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);
    try std.testing.expectEqual(DefinitionStatus.ACTIVE, active.status);

    // archive() on an ACTIVE definition must be rejected.
    const result = def_store.archive(alloc, draft.id);
    try std.testing.expectError(DefinitionError.InvalidStatusTransition, result);
}

// ---------------------------------------------------------------------------
// TC-PD-04-07: Forbidden: deprecate() on ARCHIVED → InvalidStatusTransition
// ---------------------------------------------------------------------------

test "TC-PD-04-07: deprecate() on ARCHIVED definition returns InvalidStatusTransition" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-04-07 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Build ARCHIVED state: create → activate → deprecate → archive.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    const deprecated = try def_store.deprecate(alloc, draft.id);
    defer freeDefinition(alloc, deprecated);

    const archived = try def_store.archive(alloc, draft.id);
    defer freeDefinition(alloc, archived);
    try std.testing.expectEqual(DefinitionStatus.ARCHIVED, archived.status);

    // deprecate() on ARCHIVED must be rejected (terminal status).
    const result = def_store.deprecate(alloc, draft.id);
    try std.testing.expectError(DefinitionError.InvalidStatusTransition, result);
}

// ---------------------------------------------------------------------------
// TC-PD-04-08: Forbidden: archive() on ARCHIVED → InvalidStatusTransition
// ---------------------------------------------------------------------------

test "TC-PD-04-08: archive() on ARCHIVED definition returns InvalidStatusTransition" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-04-08 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Build ARCHIVED state: create → activate → deprecate → archive.
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    const deprecated = try def_store.deprecate(alloc, draft.id);
    defer freeDefinition(alloc, deprecated);

    const archived = try def_store.archive(alloc, draft.id);
    defer freeDefinition(alloc, archived);
    try std.testing.expectEqual(DefinitionStatus.ARCHIVED, archived.status);

    // archive() on ARCHIVED must be rejected (terminal status).
    const result = def_store.archive(alloc, draft.id);
    try std.testing.expectError(DefinitionError.InvalidStatusTransition, result);
}

// ---------------------------------------------------------------------------
// TC-PD-04-10: deprecate() on non-existent id → DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-04-10: deprecate() on non-existent id returns DefinitionNotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const nonexistent_id = try parseUuid(alloc, nonexistent_uuid_str);

    // deprecate() on a UUID that has no row must return DefinitionNotFound.
    const result = def_store.deprecate(alloc, nonexistent_id);
    try std.testing.expectError(DefinitionError.DefinitionNotFound, result);
}

// ---------------------------------------------------------------------------
// TC-PD-04-11: archive() on non-existent id → DefinitionNotFound
// ---------------------------------------------------------------------------

test "TC-PD-04-11: archive() on non-existent id returns DefinitionNotFound" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const nonexistent_id = try parseUuid(alloc, nonexistent_uuid_str);

    // archive() on a UUID that has no row must return DefinitionNotFound.
    const result = def_store.archive(alloc, nonexistent_id);
    try std.testing.expectError(DefinitionError.DefinitionNotFound, result);
}
