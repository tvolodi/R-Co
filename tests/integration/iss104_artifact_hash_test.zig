//! Integration tests for ISS-104 — instance artifact hash behavior.
//!
//! Requirements: ISS-104
//!
//! Verifies that the `instances.artifact_hash` column is correctly populated
//! when instances are started. Tests cover:
//!   TC-ISS-104-INT-01: Schema validation (column exists, nullable)
//!   TC-ISS-104-INT-02: Repo-backed instance persists artifact hash
//!   TC-ISS-104-INT-03: Non-repo instance has NULL artifact_hash
//!   TC-ISS-104-INT-04: Reproducibility query resolves instance to hash
//!
//! BPM_TEST_DB_URL must be set. Tests use real PostgreSQL, no mocks.
//! Per-test UUID fixtures. Defer cleanup blocks. No SkipZigTest on MUST tests.

const std = @import("std");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");

// Root-level exports required by TestHarness.init()
pub const api_tenant_context = bpm.api_tenant_context;
pub const api_pipeline_context = bpm.api_pipeline_context;

pub fn setTestTenantContext() void {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
}

const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const Instance = bpm.engine.Instance;

// ─────────────────────────────────────────────────────────────────────────────
// Minimal process graph: START → END
// ─────────────────────────────────────────────────────────────────────────────

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};

const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "E", .condition = null, .is_default = false },
};

const minimal_graph = DefinitionGraph{
    .nodes = &minimal_nodes,
    .edges = &minimal_edges,
};

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Read BPM_TEST_DB_URL. Fails with a clear error if absent (DIRECTIVE: no SkipZigTest).
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-104 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 10,
    });
    errdefer pool.deinit();

    // Apply pending migrations to tenant_default.
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
            std.debug.print("makePool: runForSchema failed: {}\n", .{err});
        };
    }

    return pool;
}

fn parseUuid(_: std.mem.Allocator, s: []const u8) ![16]u8 {
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

fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupDefinition(pool: *Pool, def_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE id = $1::uuid", &.{def_id_hex}) catch {};
}

fn createActiveDefinition(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    name: []const u8,
    version: []const u8,
) ![16]u8 {
    const creator_id = try parseUuid(allocator, "00000000-0000-0000-0000-000000iss104");
    const created = try def_store.create(allocator, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = creator_id,
    });
    const def_id = created.id;
    allocator.free(created.name);
    allocator.free(created.version);
    if (created.description) |d| allocator.free(d);
    if (created.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, created.graph);

    const activated = try def_store.activate(allocator, def_id);
    allocator.free(activated.name);
    allocator.free(activated.version);
    if (activated.description) |d| allocator.free(d);
    if (activated.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, activated.graph);

    return def_id;
}

/// Set the definition_artifact_hash directly via SQL.
fn setDefinitionArtifactHash(
    pool: *Pool,
    def_id_hex: []const u8,
    hash: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "UPDATE process_definitions SET definition_artifact_hash = $2 WHERE id = $1::uuid",
        &.{ def_id_hex, hash },
    );
}

/// Query the artifact_hash for a given instance. Returns null if not set or if instance doesn't exist.
fn getInstanceArtifactHash(
    pool: *Pool,
    allocator: std.mem.Allocator,
    instance_id_hex: []const u8,
) !?[]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        allocator,
        "SELECT artifact_hash FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    defer result.deinit();

    if (result.rows.len == 0) {
        return null;
    }

    if (result.rows[0][0]) |hash_value| {
        return allocator.dupe(u8, hash_value);
    }

    return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-104-INT-01: Migration adds nullable artifact_hash column
// ─────────────────────────────────────────────────────────────────────────────

test "TC-ISS-104-INT-01: migration adds nullable artifact_hash column" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Query schema metadata for instance_projections.artifact_hash
    var result = try conn.query(
        alloc,
        \\SELECT column_name, data_type, is_nullable
        \\  FROM information_schema.columns
        \\  WHERE table_name = 'instance_projections'
        \\    AND column_name = 'artifact_hash'
        \\    AND table_schema = 'tenant_default',
        &.{},
    );
    defer result.deinit();

    // Assert: column exists
    try testing.expect(result.rows.len > 0);

    const column_name = result.rows[0][0];
    const data_type = result.rows[0][1];
    const is_nullable = result.rows[0][2];

    try testing.expectEqualStrings("artifact_hash", column_name orelse "");
    try testing.expectEqualStrings("text", data_type orelse "");
    try testing.expectEqualStrings("YES", is_nullable orelse "");
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-104-INT-02: Repo-backed instance persists artifact hash
// ─────────────────────────────────────────────────────────────────────────────

test "TC-ISS-104-INT-02: repo-backed instance persists artifact hash" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Create an active definition
    const def_name = "ISS104-TC02";
    const def_version = "1.0.0";
    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);
    const def_id_hex = try uuidToHexStr(alloc, def_id);
    defer alloc.free(def_id_hex);
    defer cleanupDefinition(&pool, def_id_hex);

    // Set a known artifact hash on the definition
    const test_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try setDefinitionArtifactHash(&pool, def_id_hex, test_hash);

    // Start an instance from this repo-backed definition
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    // Query the instance and verify artifact_hash is set
    const stored_hash = try getInstanceArtifactHash(&pool, alloc, inst_id_hex);
    defer if (stored_hash) |h_ptr| alloc.free(h_ptr);

    try testing.expect(stored_hash != null);
    try testing.expectEqualStrings(test_hash, stored_hash.?);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-104-INT-03: Non-repo instance has NULL artifact_hash
// ─────────────────────────────────────────────────────────────────────────────

test "TC-ISS-104-INT-03: non-repo instance has NULL artifact_hash" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Create an active definition with no artifact hash (non-repo-backed)
    const def_name = "ISS104-TC03";
    const def_version = "1.0.0";
    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);
    const def_id_hex = try uuidToHexStr(alloc, def_id);
    defer alloc.free(def_id_hex);
    defer cleanupDefinition(&pool, def_id_hex);

    // Do NOT set a definition_artifact_hash, so it remains NULL

    // Start an instance from this non-repo definition
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    // Query the instance and verify artifact_hash is NULL
    const stored_hash = try getInstanceArtifactHash(&pool, alloc, inst_id_hex);
    defer if (stored_hash) |h_ptr| alloc.free(h_ptr);

    try testing.expect(stored_hash == null);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-104-INT-04: Reproducibility query resolves instance to artifact
// ─────────────────────────────────────────────────────────────────────────────

test "TC-ISS-104-INT-04: reproducibility query resolves instance to artifact" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Create an active definition with a known artifact hash
    const def_name = "ISS104-TC04";
    const def_version = "1.0.0";
    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);
    const def_id_hex = try uuidToHexStr(alloc, def_id);
    defer alloc.free(def_id_hex);
    defer cleanupDefinition(&pool, def_id_hex);

    // Set a test artifact hash
    const test_hash = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
    try setDefinitionArtifactHash(&pool, def_id_hex, test_hash);

    // Start an instance
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    // Execute reproducibility query
    const conn = try pool.acquire();
    defer pool.release(conn);

    var result = try conn.query(
        alloc,
        "SELECT artifact_hash FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_id_hex},
    );
    defer result.deinit();

    // Assert: query returns exactly one row with the artifact hash
    try testing.expect(result.rows.len == 1);
    const retrieved_hash = result.rows[0][0];
    try testing.expect(retrieved_hash != null);
    try testing.expectEqualStrings(test_hash, retrieved_hash.?);
}
