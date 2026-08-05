//! Integration tests for EXP-401 and EXP-402.
//!
//! EXP-401 coverage in this suite targets definition-validation behavior for
//! compensation/error-boundary metadata.
//!
//! EXP-402 coverage targets restore reconciliation from `instance_waits` with
//! real PostgreSQL state.
//!
//! Requirements:
//! - Real PostgreSQL (`BPM_TEST_DB_URL` required; test fails clearly if absent)
//! - No mocks/stubs
//! - Per-test UUID isolation
const std = @import("std");
const portable_env = @import("env");
const builtin = @import("builtin");
const testing = std.testing;
const bpm = @import("bpm");

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const tenant_context = bpm.api_tenant_context;

/// Fill buf with cryptographically secure random bytes.
/// Replaces std.crypto.random removed in Zig 0.16.
fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS — add a platform branch"),
    }
}

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionError = bpm.definition.DefinitionError;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const Violation = bpm.definition.Violation;

const reconstruction_mod = bpm.reconstruction;

const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";


fn getTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set - EXP-401/402 integration tests require it\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    tenant_context.clear();
    tenant_context.set(DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 8,
    });
}

fn parseUuid(s: []const u8) ![16]u8 {
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

fn freeDefinition(allocator: std.mem.Allocator, d: bpm.definition.Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |stage| allocator.free(stage);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

fn hasCode(violations: []const Violation, code: []const u8) bool {
    for (violations) |v| {
        if (std.mem.eql(u8, v.code, code)) return true;
    }
    return false;
}

/// Per-test-run "created_by" UUID — generated fresh instead of a fixed
/// literal so this fixture follows the per-test-UUID isolation convention
/// (see docs/guides/test_infrastructure_guide.md §9 / ISS-0121).
fn makeCreatorUuid() ![16]u8 {
    var raw: [16]u8 = undefined;
    fillRandom(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return raw;
}

fn makeFixtureUuidString(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    fillRandom(&raw);
    // RFC-4122 variant/version shaping keeps generated IDs UUID-compatible.
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0], raw[1], raw[2], raw[3],
            raw[4], raw[5],
            raw[6], raw[7],
            raw[8], raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        },
    );
}

fn cleanupDefinitionByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

fn mustGraphValidationError(result: anyerror!bpm.definition.Definition, store: *DefinitionStore) !void {
    try testing.expectError(DefinitionError.GraphValidationFailed, result);
    try testing.expect(store.lastViolations().len > 0);
}

// ---------------------------------------------------------------------------
// EXP-401: compensation and error-boundary definition behavior
// ---------------------------------------------------------------------------

test "TC-EXP-401-01: valid compensation handler and error boundary metadata is accepted" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var store = DefinitionStore.init(allocator, &pool);
    defer store.deinit();

    const name = "TC-EXP-401-01";
    defer cleanupDefinitionByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "ACT", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\",\"reversible\":true,\"compensation_handler\":{\"scope_id\":\"ACT\",\"handler_node_id\":\"COMP\",\"reverse_order\":true}}" },
        .{ .id = "COMP", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\"}" },
        .{ .id = "BND", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\",\"error_boundary\":{\"attached_to_node_id\":\"ACT\",\"on_error_event\":\"EXECUTION_ERROR\",\"on_cancel_event\":\"INSTANCE_CANCELLED\"}}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "ACT", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "ACT", .target = "COMP", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "ACT", .target = "BND", .condition = null, .is_default = false },
        .{ .id = "e4", .source = "COMP", .target = "E", .condition = null, .is_default = false },
        .{ .id = "e5", .source = "BND", .target = "E", .condition = null, .is_default = false },
    };

    const created = try store.create(allocator, CreateParams{
        .name = name,
        .version = "1.0.0",
        .description = null,
        .stage = null,
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = try makeCreatorUuid(),
    });
    defer freeDefinition(allocator, created);

    try testing.expectEqual(@as(usize, 0), store.lastViolations().len);
}

test "TC-EXP-401-02: unknown compensation scope is rejected" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var store = DefinitionStore.init(allocator, &pool);
    defer store.deinit();

    const name = "TC-EXP-401-02";
    defer cleanupDefinitionByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "ACT", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\",\"compensation_handler\":{\"scope_id\":\"MISSING_SCOPE\",\"handler_node_id\":\"COMP\",\"reverse_order\":true}}" },
        .{ .id = "COMP", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "ACT", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "ACT", .target = "COMP", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "COMP", .target = "E", .condition = null, .is_default = false },
    };

    const result = store.create(allocator, CreateParams{
        .name = name,
        .version = "1.0.0",
        .description = null,
        .stage = null,
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = try makeCreatorUuid(),
    });

    try mustGraphValidationError(result, &store);
    try testing.expect(hasCode(store.lastViolations(), "COMPENSATION_HANDLER_SCOPE_UNKNOWN"));
}

test "TC-EXP-401-03: reverse_order=false is rejected" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var store = DefinitionStore.init(allocator, &pool);
    defer store.deinit();

    const name = "TC-EXP-401-03";
    defer cleanupDefinitionByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "ACT", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\",\"compensation_handler\":{\"scope_id\":\"ACT\",\"handler_node_id\":\"COMP\",\"reverse_order\":false}}" },
        .{ .id = "COMP", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "ACT", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "ACT", .target = "COMP", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "COMP", .target = "E", .condition = null, .is_default = false },
    };

    const result = store.create(allocator, CreateParams{
        .name = name,
        .version = "1.0.0",
        .description = null,
        .stage = null,
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = try makeCreatorUuid(),
    });

    try mustGraphValidationError(result, &store);
    try testing.expect(hasCode(store.lastViolations(), "COMPENSATION_HANDLER_NOT_REVERSED"));
}

test "TC-EXP-401-04: irreversible node with compensation metadata is rejected" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var store = DefinitionStore.init(allocator, &pool);
    defer store.deinit();

    const name = "TC-EXP-401-04";
    defer cleanupDefinitionByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "ACT", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\",\"reversible\":false,\"compensation_handler\":{\"scope_id\":\"ACT\",\"handler_node_id\":\"COMP\",\"reverse_order\":true}}" },
        .{ .id = "COMP", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "ACT", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "ACT", .target = "COMP", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "COMP", .target = "E", .condition = null, .is_default = false },
    };

    const result = store.create(allocator, CreateParams{
        .name = name,
        .version = "1.0.0",
        .description = null,
        .stage = null,
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = try makeCreatorUuid(),
    });

    try mustGraphValidationError(result, &store);
    try testing.expect(hasCode(store.lastViolations(), "NON_REVERSIBLE_ACTIVITY"));
}

test "TC-EXP-401-05: error boundary requires both on_error_event and on_cancel_event" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var store = DefinitionStore.init(allocator, &pool);
    defer store.deinit();

    const name = "TC-EXP-401-05";
    defer cleanupDefinitionByName(&pool, name);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "ACT", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\"}" },
        .{ .id = "BND", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"ops\",\"error_boundary\":{\"attached_to_node_id\":\"ACT\",\"on_error_event\":\"EXECUTION_ERROR\",\"on_cancel_event\":\"\"}}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "ACT", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "ACT", .target = "BND", .condition = null, .is_default = false },
        .{ .id = "e3", .source = "BND", .target = "E", .condition = null, .is_default = false },
    };

    const result = store.create(allocator, CreateParams{
        .name = name,
        .version = "1.0.0",
        .description = null,
        .stage = null,
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = try makeCreatorUuid(),
    });

    try mustGraphValidationError(result, &store);
    try testing.expect(hasCode(store.lastViolations(), "ERROR_BOUNDARY_EVENTS_MISSING"));
}

// ---------------------------------------------------------------------------
// EXP-402: restore reconciliation from instance_waits descriptors
// ---------------------------------------------------------------------------

test "TC-EXP-402-01: restore reconciliation re-arms live timer and task waits" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const tenant_uuid = try parseUuid(DEFAULT_TENANT_ID);
    const instance_id = try makeFixtureUuidString(allocator);
    defer allocator.free(instance_id);
    const def_id = try makeFixtureUuidString(allocator);
    defer allocator.free(def_id);
    const token_id = try makeFixtureUuidString(allocator);
    defer allocator.free(token_id);
    const task_id = try makeFixtureUuidString(allocator);
    defer allocator.free(task_id);
    const timer_id = try makeFixtureUuidString(allocator);
    defer allocator.free(timer_id);

    conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM tasks WHERE id = $1::uuid", &.{task_id}) catch {};
    conn.exec("DELETE FROM tokens WHERE id = $1::uuid", &.{token_id}) catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        conn.exec("DELETE FROM tasks WHERE id = $1::uuid", &.{task_id}) catch {};
        conn.exec("DELETE FROM tokens WHERE id = $1::uuid", &.{token_id}) catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{timer_id}) catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );

    try conn.exec(
        \\INSERT INTO tokens (id, instance_id, current_node, status)
        \\VALUES ($1::uuid, $2::uuid, 'EXP402_NODE', 'active')
    ,
        &.{ token_id, instance_id },
    );

    try conn.exec(
        \\INSERT INTO tasks (id, instance_id, token_id, node_id, node_name, status)
        \\VALUES ($1::uuid, $2::uuid, $3::uuid, 'EXP402_NODE', 'EXP-402 task', 'PENDING')
    ,
        &.{ task_id, instance_id, token_id },
    );

    try conn.exec(
        \\INSERT INTO timers (id, instance_id, timer_type, step_name, fires_at, action_type, status)
        \\VALUES ($1::uuid, $2::uuid, 'scheduled_transition', 'EXP402_NODE', NOW() + interval '10 minutes', 'auto_transition', 'pending')
    ,
        &.{ timer_id, instance_id },
    );

    try conn.exec(
        \\INSERT INTO instance_waits (instance_id, kind, ref_id, node_id)
        \\VALUES ($1::uuid, 'human_task', $2::uuid, 'EXP402_NODE')
    ,
        &.{ instance_id, task_id },
    );

    try conn.exec(
        \\INSERT INTO instance_waits (instance_id, kind, ref_id, node_id, fire_at)
        \\VALUES ($1::uuid, 'timer', $2::uuid, 'EXP402_NODE', NOW() + interval '10 minutes')
    ,
        &.{ instance_id, timer_id },
    );

    const result = try reconstruction_mod.restoreTenantWithWaitReconciliation(allocator, &pool, tenant_uuid);
    try testing.expectEqual(@as(u32, 1), result.restored_instances);
    try testing.expectEqual(@as(u32, 2), result.rearmed_waits);
    try testing.expectEqual(@as(u32, 0), result.orphaned_instances);

    const rows = try conn.query(
        allocator,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try testing.expectEqual(@as(usize, 1), rows.rows.len);
    try testing.expectEqualStrings("ACTIVE", rows.rows[0][0] orelse "");
}

test "TC-EXP-402-02: unrearmable unresolved wait marks RESTORED_ORPHAN and reason" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const tenant_uuid = try parseUuid(DEFAULT_TENANT_ID);
    const instance_id = try makeFixtureUuidString(allocator);
    defer allocator.free(instance_id);
    const def_id = try makeFixtureUuidString(allocator);
    defer allocator.free(def_id);
    const missing_timer_ref = try makeFixtureUuidString(allocator);
    defer allocator.free(missing_timer_ref);

    conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{missing_timer_ref}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid", &.{missing_timer_ref}) catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );

    // Unresolved wait descriptor with no live timer row.
    try conn.exec(
        \\INSERT INTO instance_waits (instance_id, kind, ref_id, node_id, fire_at)
        \\VALUES ($1::uuid, 'timer', $2::uuid, 'EXP402_ORPHAN_NODE', NOW() - interval '5 minutes')
    ,
        &.{ instance_id, missing_timer_ref },
    );

    const result = try reconstruction_mod.restoreTenantWithWaitReconciliation(allocator, &pool, tenant_uuid);
    try testing.expectEqual(@as(u32, 1), result.restored_instances);
    try testing.expectEqual(@as(u32, 0), result.rearmed_waits);
    try testing.expectEqual(@as(u32, 1), result.orphaned_instances);

    const rows = try conn.query(
        allocator,
        "SELECT status, error_detail::text FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try testing.expectEqual(@as(usize, 1), rows.rows.len);
    try testing.expectEqualStrings("RESTORED_ORPHAN", rows.rows[0][0] orelse "");
    const detail = rows.rows[0][1] orelse "";
    try testing.expect(std.mem.indexOf(u8, detail, "restored_orphan_reason") != null);
}
