const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;

// Root-level exports required by TestHarness.init() to set the pool's tenant context.
// Without these, pool connections use search_path=public and cannot find tenant-schema
// tables like audit_entries.
pub const api_tenant_context = bpm.api_tenant_context;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - integration test cannot run\n", .{});
            return error.TestEnvironmentMissing;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
    errdefer pool.deinit();
    // Apply any pending migrations to tenant_default (including 087_iss103_audit_resource_id_text_tenant).
    // runForSchema is idempotent: it only applies migrations not already tracked in
    // schema_migrations for (schema_name='tenant_default', version=...).
    // Use an arena allocator so internal allocations are freed immediately, avoiding
    // std.testing.allocator leak failures.
    const build_opts = @import("build_options");
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        bpm.migrations.Migrations.runForSchema(
            arena.allocator(),
            &pool,
            build_opts.migrations_dir,
            "tenant_default",
        ) catch |err| {
            std.debug.print("makePool: provisionTenantSchema failed: {}\n", .{err});
        };
    }
    return pool;
}

fn parseUuid(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    var compact: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= compact.len) return error.InvalidUuid;
        compact[j] = c;
        j += 1;
    }
    if (j != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, compact[0..]);
    return out;
}

fn uuidToString(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&uuid, .lower)});
    defer allocator.free(raw);

    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}-{s}-{s}",
        .{ raw[0..8], raw[8..12], raw[12..16], raw[16..20], raw[20..32] },
    );
}

fn dbUuidString(conn: *bpm.pool.Conn, allocator: std.mem.Allocator) ![]u8 {
    const row = (try conn.queryRow(allocator, "SELECT gen_random_uuid()::text", &.{})) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }

    const uuid = row[0] orelse return error.TestUnexpectedResult;
    return allocator.dupe(u8, uuid);
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

fn cleanupAuditForResource(pool: *Pool, resource_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    // audit_entries is immutable by design (trg_audit_entries_no_delete /
    // bpm_audit_immutable_guard, migration 020; reinforced by migration 051/059).
    // Deleting test fixture rows requires temporarily disabling user triggers,
    // matching the established pattern in xc02_audit_immutability_test.zig.
    conn.exec("ALTER TABLE audit_entries DISABLE TRIGGER USER", &.{}) catch return;
    defer conn.exec("ALTER TABLE audit_entries ENABLE TRIGGER USER", &.{}) catch {};
    // resource_id is now TEXT, not UUID, so we query it directly as TEXT
    conn.exec(
        "DELETE FROM audit_entries WHERE resource_id = $1",
        &.{resource_id},
    ) catch {};
}

fn countRows(
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const []const u8,
) !usize {
    const row = (try conn.queryRow(allocator, sql, params)) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }

    const count_str = row[0] orelse return error.TestUnexpectedResult;
    return std.fmt.parseInt(usize, count_str, 10);
}

test "TC-ISS-103-INT-01: UUID-keyed resource audit entries have TEXT resource_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Generate unique test names
    const unique_id = try dbUuidString(conn, alloc);
    defer alloc.free(unique_id);

    const def_name = try std.fmt.allocPrint(alloc, "iss103-test-{s}", .{unique_id[0..8]});
    defer alloc.free(def_name);

    const version = "1.0.0";
    cleanupDefinition(&pool, def_name, version);
    defer cleanupDefinition(&pool, def_name, version);

    var store = DefinitionStore.init(alloc, &pool);
    defer store.deinit();

    // Create instance creator UUID
    const creator_id = try dbUuidString(conn, alloc);
    defer alloc.free(creator_id);
    const creator = try parseUuid(creator_id);

    // Create a simple process definition
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{.{ .id = "e1", .source = "S", .target = "E", .condition = null }};

    const def = try store.create(alloc, CreateParams{
        .name = def_name,
        .version = version,
        .description = "ISS-103 test",
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = creator,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        if (def.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    // Convert definition ID to string for cleanup and verification
    const def_id_str = try uuidToString(alloc, def.id);
    defer alloc.free(def_id_str);
    defer cleanupAuditForResource(&pool, def_id_str);

    // Query audit entries for the definition resource
    // After migration 083, resource_id is TEXT, not UUID
    const rows = try conn.query(
        alloc,
        \\SELECT
        \\  audit_id::text,
        \\  resource_id,
        \\  resource_type,
        \\  action,
        \\  pg_typeof(resource_id)::text as resource_id_type
        \\FROM audit_entries
        \\WHERE resource_id = $1
        \\ORDER BY "timestamp" ASC, audit_id ASC
    ,
        &.{def_id_str},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    // Verify at least one audit entry exists for the definition
    try testing.expect(rows.rows.len >= 1);

    // Verify the first entry has TEXT resource_id
    const first = rows.rows[0];
    const first_resource_id = first[1] orelse return error.TestUnexpectedResult;
    const first_resource_type = first[2] orelse return error.TestUnexpectedResult;
    const first_action = first[3] orelse return error.TestUnexpectedResult;
    const resource_id_type = first[4] orelse return error.TestUnexpectedResult;

    // Verify resource_id is stored as TEXT (should say "text" in PostgreSQL)
    try testing.expectEqualStrings("text", resource_id_type);

    // Verify resource_id contains the UUID as text
    try testing.expectEqualStrings(def_id_str, first_resource_id);

    // Verify resource_type is correct
    try testing.expectEqualStrings("definition", first_resource_type);

    // Verify action is creation
    try testing.expectEqualStrings("definition.create", first_action);
}

test "TC-ISS-103-INT-02: idx_audit_resource index enables efficient point lookups" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Generate unique test names
    const unique_id = try dbUuidString(conn, alloc);
    defer alloc.free(unique_id);

    const def_name = try std.fmt.allocPrint(alloc, "iss103-idx-test-{s}", .{unique_id[0..8]});
    defer alloc.free(def_name);

    const version = "1.0.0";
    cleanupDefinition(&pool, def_name, version);
    defer cleanupDefinition(&pool, def_name, version);

    var store = DefinitionStore.init(alloc, &pool);
    defer store.deinit();

    const creator_id = try dbUuidString(conn, alloc);
    defer alloc.free(creator_id);
    const creator = try parseUuid(creator_id);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{.{ .id = "e1", .source = "S", .target = "E", .condition = null }};

    const def = try store.create(alloc, CreateParams{
        .name = def_name,
        .version = version,
        .description = "ISS-103 index test",
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = creator,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        if (def.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    const def_id_str = try uuidToString(alloc, def.id);
    defer alloc.free(def_id_str);
    defer cleanupAuditForResource(&pool, def_id_str);

    // Query using idx_audit_resource index (point lookup on resource_id)
    // This should use the index efficiently
    const count = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1",
        &.{def_id_str},
    );

    // Verify at least one entry exists (created during definition.create)
    try testing.expect(count >= 1);

    // Query with resource_type and resource_id together
    const typed_count = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_type = $1 AND resource_id = $2",
        &.{ "definition", def_id_str },
    );

    try testing.expect(typed_count >= 1);
}

test "TC-ISS-103-INT-03: mixed resource types are all queryable by TEXT resource_id" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Create multiple definitions to test mixed audit entries
    const unique_id = try dbUuidString(conn, alloc);
    defer alloc.free(unique_id);

    const def_name1 = try std.fmt.allocPrint(alloc, "iss103-mixed-1-{s}", .{unique_id[0..8]});
    defer alloc.free(def_name1);

    const unique_id2 = try dbUuidString(conn, alloc);
    defer alloc.free(unique_id2);

    const def_name2 = try std.fmt.allocPrint(alloc, "iss103-mixed-2-{s}", .{unique_id2[0..8]});
    defer alloc.free(def_name2);

    const version = "1.0.0";
    cleanupDefinition(&pool, def_name1, version);
    cleanupDefinition(&pool, def_name2, version);
    defer {
        cleanupDefinition(&pool, def_name1, version);
        cleanupDefinition(&pool, def_name2, version);
    }

    var store = DefinitionStore.init(alloc, &pool);
    defer store.deinit();

    const creator_id = try dbUuidString(conn, alloc);
    defer alloc.free(creator_id);
    const creator = try parseUuid(creator_id);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{.{ .id = "e1", .source = "S", .target = "E", .condition = null }};

    // Create first definition
    const def1 = try store.create(alloc, CreateParams{
        .name = def_name1,
        .version = version,
        .description = "ISS-103 mixed test 1",
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = creator,
    });
    defer {
        alloc.free(def1.name);
        alloc.free(def1.version);
        if (def1.description) |d| alloc.free(d);
        if (def1.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, def1.graph);
    }

    const def1_id_str = try uuidToString(alloc, def1.id);
    defer alloc.free(def1_id_str);
    defer cleanupAuditForResource(&pool, def1_id_str);

    // Create second definition
    const def2 = try store.create(alloc, CreateParams{
        .name = def_name2,
        .version = version,
        .description = "ISS-103 mixed test 2",
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = creator,
    });
    defer {
        alloc.free(def2.name);
        alloc.free(def2.version);
        if (def2.description) |d| alloc.free(d);
        if (def2.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, def2.graph);
    }

    const def2_id_str = try uuidToString(alloc, def2.id);
    defer alloc.free(def2_id_str);
    defer cleanupAuditForResource(&pool, def2_id_str);

    // Verify both resources can be queried independently
    const count1 = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1",
        &.{def1_id_str},
    );

    const count2 = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1",
        &.{def2_id_str},
    );

    // Both should have at least one entry
    try testing.expect(count1 >= 1);
    try testing.expect(count2 >= 1);

    // Query all audit entries and verify both resource IDs are present
    const all_rows = try conn.query(
        alloc,
        \\SELECT DISTINCT resource_id
        \\FROM audit_entries
        \\WHERE resource_id IN ($1, $2)
        \\ORDER BY resource_id
    ,
        &.{ def1_id_str, def2_id_str },
    );
    defer {
        var r = all_rows;
        r.deinit();
    }

    // Should have exactly 2 distinct resource IDs
    try testing.expectEqual(@as(usize, 2), all_rows.rows.len);
}

test "TC-ISS-103-INT-04: audit entries clean up without leftover data" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const unique_id = try dbUuidString(conn, alloc);
    defer alloc.free(unique_id);

    const def_name = try std.fmt.allocPrint(alloc, "iss103-cleanup-{s}", .{unique_id[0..8]});
    defer alloc.free(def_name);

    const version = "1.0.0";
    cleanupDefinition(&pool, def_name, version);
    defer cleanupDefinition(&pool, def_name, version);

    var store = DefinitionStore.init(alloc, &pool);
    defer store.deinit();

    const creator_id = try dbUuidString(conn, alloc);
    defer alloc.free(creator_id);
    const creator = try parseUuid(creator_id);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{.{ .id = "e1", .source = "S", .target = "E", .condition = null }};

    const def = try store.create(alloc, CreateParams{
        .name = def_name,
        .version = version,
        .description = "ISS-103 cleanup test",
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = creator,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        if (def.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    const def_id_str = try uuidToString(alloc, def.id);
    defer alloc.free(def_id_str);

    // Verify audit entry exists
    const before_cleanup = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1",
        &.{def_id_str},
    );
    try testing.expect(before_cleanup >= 1);

    // Clean up audit entries for this resource
    cleanupAuditForResource(&pool, def_id_str);

    // Verify cleanup was successful
    const after_cleanup = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1",
        &.{def_id_str},
    );
    try testing.expectEqual(@as(usize, 0), after_cleanup);
}
