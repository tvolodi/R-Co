//! Integration tests for PD-05 (Node types — per-node-type attribute validation).
//!
//! Tests exercise the Store.create() path against a real PostgreSQL database.
//! Attribute violations surfaced by validateNodeAttributes() are tested here via
//! store.lastViolations() — the integration complement to the pure-function unit tests.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//! Every test calls TestHarness.init() to ensure migrations are applied.
//!
//! Directive compliance:
//!   T-1 — real PostgreSQL only; no mocks.
//!
//! Requirement traceability:
//!   PD-05 → TC-PD-05-01, TC-PD-05-02, TC-PD-05-04, TC-PD-05-05,
//!            TC-PD-05-10, TC-PD-05-12, TC-PD-05-19
const std = @import("std");
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

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

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

fn hasCode(violations: []const bpm.definition.Violation, code: []const u8) bool {
    for (violations) |v| {
        if (std.mem.eql(u8, v.code, code)) return true;
    }
    return false;
}

fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &.{name},
    ) catch {};
}

fn freeDefinition(allocator: std.mem.Allocator, def: bpm.definition.Definition) void {
    allocator.free(def.name);
    allocator.free(def.version);
    if (def.description) |d| allocator.free(d);
    bpm.definition.freeDefinitionGraph(allocator, def.graph);
}

const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

// ---------------------------------------------------------------------------
// TC-PD-05-01 (integration): HUMAN_TASK with role present -> creates definition
// ---------------------------------------------------------------------------

test "TC-PD-05-01(integration): HUMAN_TASK with valid role saves with status DRAFT" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-05-01 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"approver\"}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    defer freeDefinition(alloc, def);

    try std.testing.expectEqual(DefinitionStatus.DRAFT, def.status);
}

// ---------------------------------------------------------------------------
// TC-PD-05-02 (integration): HUMAN_TASK with role absent -> GraphValidationFailed
// ---------------------------------------------------------------------------

test "TC-PD-05-02(integration): HUMAN_TASK with role absent returns GraphValidationFailed + HUMAN_TASK_MISSING_ROLE" {
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
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-05-02 Process",
        .version = "1.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "HUMAN_TASK_MISSING_ROLE"));
}

// ---------------------------------------------------------------------------
// TC-PD-05-04 (integration): SERVICE_TASK with valid endpoint + timeout_ms -> creates
// ---------------------------------------------------------------------------

test "TC-PD-05-04(integration): SERVICE_TASK with valid endpoint and timeout_ms saves with status DRAFT" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-05-04 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"endpoint\":\"https://api.example.com\",\"timeout_ms\":60000}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    defer freeDefinition(alloc, def);

    try std.testing.expectEqual(DefinitionStatus.DRAFT, def.status);
}

// ---------------------------------------------------------------------------
// TC-PD-05-05 (integration): SERVICE_TASK missing endpoint -> GraphValidationFailed
// ---------------------------------------------------------------------------

test "TC-PD-05-05(integration): SERVICE_TASK with endpoint absent returns GraphValidationFailed + SERVICE_TASK_MISSING_ENDPOINT" {
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
        .{ .id = "T", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"timeout_ms\":60000}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-05-05 Process",
        .version = "1.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "SERVICE_TASK_MISSING_ENDPOINT"));
}

// ---------------------------------------------------------------------------
// TC-PD-05-10 (integration): TIMER with valid duration_iso8601 -> creates
// ---------------------------------------------------------------------------

test "TC-PD-05-10(integration): TIMER with valid duration_iso8601 saves with status DRAFT" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-05-10 Process";
    defer cleanupByName(&pool, name);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const created_by = try parseUuid(alloc, creator_uuid_str);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .TIMER, .label = null, .attributes = "{\"duration_iso8601\":\"PT5M\"}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    defer freeDefinition(alloc, def);

    try std.testing.expectEqual(DefinitionStatus.DRAFT, def.status);
}

// ---------------------------------------------------------------------------
// TC-PD-05-12 (integration): TIMER with duration_iso8601 absent -> GraphValidationFailed
// ---------------------------------------------------------------------------

test "TC-PD-05-12(integration): TIMER with duration_iso8601 absent returns GraphValidationFailed + TIMER_MISSING_DURATION" {
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
        .{ .id = "T", .node_type = .TIMER, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-05-12 Process",
        .version = "1.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);
    try std.testing.expect(hasCode(def_store.lastViolations(), "TIMER_MISSING_DURATION"));
}

// ---------------------------------------------------------------------------
// TC-PD-05-19 (integration): Multiple violations -> both codes present, no early exit
// ---------------------------------------------------------------------------

test "TC-PD-05-19(integration): HUMAN_TASK missing role AND SERVICE_TASK missing endpoint both reported" {
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
        .{ .id = "HT", .node_type = .HUMAN_TASK, .label = null },
        .{ .id = "ST", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"timeout_ms\":60000}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "HT", .condition = null },
        .{ .id = "e2", .source = "HT", .target = "ST", .condition = null },
        .{ .id = "e3", .source = "ST", .target = "E", .condition = null },
    };

    const err = def_store.create(alloc, CreateParams{
        .name = "TC-PD-05-19 Process",
        .version = "1.0",
        .description = null,
        .graph = .{ .nodes = &nodes, .edges = &edges },
        .created_by = created_by,
    });
    try std.testing.expectError(DefinitionError.GraphValidationFailed, err);

    const violations = def_store.lastViolations();
    try std.testing.expect(hasCode(violations, "HUMAN_TASK_MISSING_ROLE"));
    try std.testing.expect(hasCode(violations, "SERVICE_TASK_MISSING_ENDPOINT"));
    try std.testing.expectEqual(@as(usize, 2), violations.len);
}
