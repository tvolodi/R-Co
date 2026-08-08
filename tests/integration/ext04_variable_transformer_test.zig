//! Integration tests for EXT-04 — Variable transformer.
//!
//! Scope in this module is activation-time validation behavior (PD-02 path).
//! Runtime transform ordering and EE-10 mapping are covered by deterministic
//! unit tests in tests/unit/test_engine_ee05.zig.
//!
//! Requirement traceability:
//!   EXT-04 → TC-EXT-04-INT-01
const std = @import("std");

const portable_env = @import("env");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const Definition = bpm.definition.Definition;
const DefinitionError = bpm.definition.DefinitionError;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

// GH-512 retention: conventional creator_uuid_str module-scope fixture (no FK constraint, stable identity for created_by column)
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping EXT-04 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
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

fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

fn hasCode(violations: []const bpm.definition.Violation, code: []const u8) bool {
    for (violations) |v| {
        if (std.mem.eql(u8, v.code, code)) return true;
    }
    return false;
}

test "TC-EXT-04-INT-01: activation-time revalidation rejects invalid transform syntax" {
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .transform = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = try parseUuid(creator_uuid_str);
    const def = try def_store.create(allocator, CreateParams{
        .name = "EXT04-INT-TC01",
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        allocator.free(def.name);
        allocator.free(def.version);
        bpm.definition.freeDefinitionGraph(allocator, def.graph);
    }
    defer cleanup: {
        const conn = pool.acquire() catch break :cleanup;
        defer pool.release(conn);
        conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{"EXT04-INT-TC01"}) catch {};
    }

    const def_id_hex = try uuidToHexStr(allocator, def.id);
    defer allocator.free(def_id_hex);

    const invalid_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const invalid_edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .transform = "variables.(", .is_default = false },
    };
    const invalid_graph = DefinitionGraph{ .nodes = &invalid_nodes, .edges = &invalid_edges };
    const invalid_graph_json = try std.json.Stringify.valueAlloc(allocator, invalid_graph, .{});
    defer allocator.free(invalid_graph_json);

    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE process_definitions SET graph = $1::jsonb WHERE id = $2::uuid",
            &.{ invalid_graph_json, def_id_hex },
        );
    }

    const activate_result = def_store.activate(allocator, def.id);
    try std.testing.expectError(DefinitionError.GraphValidationFailed, activate_result);
    try std.testing.expect(hasCode(def_store.lastViolations(), "EDGE_INVALID_TRANSFORM_CEL"));

    {
        const valid_graph_json = try std.json.Stringify.valueAlloc(allocator, graph, .{});
        defer allocator.free(valid_graph_json);

        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE process_definitions SET graph = $1::jsonb WHERE id = $2::uuid",
            &.{ valid_graph_json, def_id_hex },
        );
    }
}
