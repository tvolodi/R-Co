//! Integration tests for PD-01 (Create definition) and PD-02 (Graph validation).
//!
//! Tests exercise the Store.create() end-to-end path against a real PostgreSQL
//! database.  All graph-validation failures are detected inside Store.create()
//! before any database write occurs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//! Every test calls TestHarness.init() to ensure migrations are applied before
//! accessing the Pool / Store.
//!
//! Requirement traceability:
//!   PD-01 → TC-PD-01-01, TC-PD-01-02, TC-PD-01-03, TC-PD-01-04
//!   PD-02 → TC-PD-02-01, TC-PD-02-02, TC-PD-02-03, TC-PD-02-04, TC-PD-02-05,
//!            TC-PD-02-06, TC-PD-02-07, TC-PD-02-08, TC-PD-02-09, TC-PD-02-10,
//!            TC-PD-02-11
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
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

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

/// Return true if any violation in the slice has the given code.
fn hasCode(violations: []const bpm.definition.Violation, code: []const u8) bool {
    for (violations) |v| {
        if (std.mem.eql(u8, v.code, code)) return true;
    }
    return false;
}

/// Delete test rows from process_definitions by name + version (best-effort cleanup).
fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

/// Fixed creator UUID used in all tests — no FK constraint on created_by.
// GH-512 retention: conventional creator_uuid_str module-scope fixture (no FK constraint, stable identity for created_by column)
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

// ---------------------------------------------------------------------------
// Minimal valid graph reused by multiple tests.
// START → HUMAN_TASK → END
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"test-role\"}" },
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
// TC-PD-01-01: Create valid definition → UUID assigned, status = DRAFT
// ---------------------------------------------------------------------------

test "TC-PD-01-01: create valid definition returns Definition with UUID and status=DRAFT" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-01-01 Process";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = "test definition",
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    // UUID must be non-zero (platform assigned).
    const zero: [16]u8 = std.mem.zeroes([16]u8);
    try std.testing.expect(!std.mem.eql(u8, &def.id, &zero));

    // Status must be DRAFT.
    try std.testing.expectEqual(bpm.definition.DefinitionStatus.DRAFT, def.status);

    // Submitted fields must be echoed back.
    try std.testing.expectEqualStrings(name, def.name);
    try std.testing.expectEqualStrings(version, def.version);
}

// ---------------------------------------------------------------------------
// TC-PD-01-02: Create with same name + version → DuplicateNameVersion
// ---------------------------------------------------------------------------

test "TC-PD-01-02: duplicate name+version returns DuplicateNameVersion" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-01-02 Process";
    const version = "2.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // First create must succeed.
    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    alloc.free(def.name);
    alloc.free(def.version);
    if (def.description) |d| alloc.free(d);
    bpm.definition.freeDefinitionGraph(alloc, def.graph);

    // Second create with the same name + version must fail.
    const err = def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.DuplicateNameVersion, err);
}

// ---------------------------------------------------------------------------
// TC-PD-01-03: Create with invalid graph (no START node) → GraphValidationFailed
// ---------------------------------------------------------------------------

test "TC-PD-01-03: graph with no START node returns GraphValidationFailed + MISSING_START_NODE" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "T", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-01-03 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "MISSING_START_NODE"));
}

// ---------------------------------------------------------------------------
// TC-PD-01-04: Create with description omitted → allowed
// ---------------------------------------------------------------------------

test "TC-PD-01-04: create with description omitted is allowed" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-01-04 Process";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    // Must succeed with status DRAFT.
    try std.testing.expectEqual(bpm.definition.DefinitionStatus.DRAFT, def.status);
}

// ---------------------------------------------------------------------------
// TC-PD-02-01: Valid graph → validation passes
// ---------------------------------------------------------------------------

test "TC-PD-02-01: valid graph passes validation and returns Definition" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-02-01 Process";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = created_by,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    try std.testing.expectEqual(bpm.definition.DefinitionStatus.DRAFT, def.status);
}

// ---------------------------------------------------------------------------
// TC-PD-02-02: Zero START nodes → MISSING_START_NODE
// ---------------------------------------------------------------------------

test "TC-PD-02-02: zero START nodes returns MISSING_START_NODE violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "T", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-02 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "MISSING_START_NODE"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-03: Two START nodes → MULTIPLE_START_NODES
// ---------------------------------------------------------------------------

test "TC-PD-02-03: two START nodes returns MULTIPLE_START_NODES violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S1", .node_type = .START, .label = null },
        .{ .id = "S2", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S1", .target = "E", .condition = null },
        .{ .id = "e2", .source = "S2", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-03 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "MULTIPLE_START_NODES"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-04: No END nodes → MISSING_END_NODE
// ---------------------------------------------------------------------------

test "TC-PD-02-04: no END nodes returns MISSING_END_NODE violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-04 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "MISSING_END_NODE"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-05: Dangling edge → DANGLING_EDGE
// ---------------------------------------------------------------------------

test "TC-PD-02-05: edge referencing non-existent node returns DANGLING_EDGE violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "E", .condition = null },
        .{ .id = "e2", .source = "S", .target = "MISSING", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-05 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "DANGLING_EDGE"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-06: Isolated node → ISOLATED_NODE
// ---------------------------------------------------------------------------

test "TC-PD-02-06: isolated node returns ISOLATED_NODE violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
        .{ .id = "X", .node_type = .HUMAN_TASK, .label = null }, // isolated — no edges
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-06 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "ISOLATED_NODE"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-07: Duplicate node ID → DUPLICATE_NODE_ID
// ---------------------------------------------------------------------------

test "TC-PD-02-07: duplicate node ID returns DUPLICATE_NODE_ID violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null }, // duplicate ID
        .{ .id = "END", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "END", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-07 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "DUPLICATE_NODE_ID"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-08: Non-gateway cycle → CYCLE_WITHOUT_GATEWAY
// ---------------------------------------------------------------------------

test "TC-PD-02-08: non-gateway cycle returns CYCLE_WITHOUT_GATEWAY violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // S → A → B → A (cycle, neither A nor B is a gateway) → E
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "A", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "B", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "A", .condition = null },
        .{ .id = "e2", .source = "A", .target = "B", .condition = null },
        .{ .id = "e3", .source = "B", .target = "A", .condition = null }, // back edge — cycle
        .{ .id = "e4", .source = "B", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-08 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "CYCLE_WITHOUT_GATEWAY"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-09: Cycle through EXCLUSIVE_GATEWAY → passes (permitted)
// ---------------------------------------------------------------------------

test "TC-PD-02-09: cycle through EXCLUSIVE_GATEWAY is permitted" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-02-09 Process";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // S → GW → T → GW (back edge — cycle through gateway, permitted)
    // GW → E (exit path)
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "GW", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"test-role\"}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "GW", .condition = null },
        .{ .id = "e2", .source = "GW", .target = "T", .condition = "repeat == true" },
        .{ .id = "e3", .source = "T", .target = "GW", .condition = null }, // back to gateway
        .{ .id = "e4", .source = "GW", .target = "E", .is_default = true, .condition = null },
    };

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    // Must succeed — no CYCLE_WITHOUT_GATEWAY violation.
    try std.testing.expect(!hasCode(def_store.lastViolations(), "CYCLE_WITHOUT_GATEWAY"));
    try std.testing.expectEqual(bpm.definition.DefinitionStatus.DRAFT, def.status);
}

// ---------------------------------------------------------------------------
// TC-PD-02-10: Node count > 500 → NODE_LIMIT_EXCEEDED
// ---------------------------------------------------------------------------

test "TC-PD-02-10: 501 nodes returns NODE_LIMIT_EXCEEDED violation" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Use an arena so node IDs and the nodes slice are freed together.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const ta = arena.allocator();

    const nodes = try ta.alloc(GraphNode, 501);
    for (0..501) |i| {
        const id = try std.fmt.allocPrint(ta, "N{d:0>7}", .{i});
        nodes[i] = .{ .id = id, .node_type = .HUMAN_TASK, .label = null };
    }
    nodes[0].node_type = .START;
    nodes[500].node_type = .END;

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-10 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = nodes, .edges = &.{} },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "NODE_LIMIT_EXCEEDED"));
}

// ---------------------------------------------------------------------------
// TC-PD-02-11: Multiple violations listed (not just the first)
// ---------------------------------------------------------------------------

test "TC-PD-02-11: graph with multiple structural errors reports all violations" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    // Graph designed to trigger three simultaneous violations:
    //   1. MISSING_START_NODE  — no START node
    //   2. MISSING_END_NODE    — no END node
    //   3. DANGLING_EDGE       — edge references a node that doesn't exist
    const nodes = [_]GraphNode{
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "T", .target = "GHOST", .condition = null }, // GHOST does not exist
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-02-11 Process",
        .version = "1.0.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);

    const violations = def_store.lastViolations();
    // All three violations must be present.
    try std.testing.expect(hasCode(violations, "MISSING_START_NODE"));
    try std.testing.expect(hasCode(violations, "MISSING_END_NODE"));
    try std.testing.expect(hasCode(violations, "DANGLING_EDGE"));
    // At least three violations must be in the list.
    try std.testing.expect(violations.len >= 3);
}
