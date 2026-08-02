// tests/integration/iss102_claim_test.zig
// Requirements: ISS-102
//
// Verifies the tasks.claimed_by column and real claim path introduced by
// migration 082 and the ISS-102 code changes in src/tasks/store.zig and
// src/api/routes/tasks.zig.
//
// Test coverage:
//   TC-ISS-102-01  Happy path: claimTask sets claimed_by
//   TC-ISS-102-02  Concurrent double-claim: exactly one wins
//   TC-ISS-102-03  Claim on already-claimed task → ClaimError.AlreadyClaimed
//   TC-ISS-102-04  Claim on non-PENDING task → ClaimError.NotPending
//   TC-ISS-102-05  Complete by claimed_by worker → HTTP 200
//   TC-ISS-102-06  Complete by different worker → HTTP 403
//   TC-ISS-102-07  Complete USER-assigned unclaimed task by that user → HTTP 200
//   TC-ISS-102-08  Complete USER-assigned unclaimed task by different user → HTTP 403
//
// BPM_TEST_DB_URL must be set. Tests connect to a real PostgreSQL — no mocks.
// Per-test UUID fixtures. Defer cleanup. No SkipZigTest on MUST tests.

const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");

// Root-level exports required by TestHarness.init() to set the pool's tenant context.
// Without these, pool connections use search_path=public and cannot find tenant-schema
// tables (process_definitions, tasks, instance_projections).
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

const TaskStore = bpm.tasks.TaskStore;
const ClaimError = bpm.tasks.ClaimError;
const TaskStatus = bpm.tasks.TaskStatus;

const Actor = bpm.task_routes.Actor;

// ---------------------------------------------------------------------------
// Minimal process graph: START → HUMAN_TASK → END
// ---------------------------------------------------------------------------

const test_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Claim Task", .attributes = "{\"role\":\"worker\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const test_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const test_graph = DefinitionGraph{ .nodes = &test_nodes, .edges = &test_edges };

// ---------------------------------------------------------------------------
// Worker UUID constants
// ---------------------------------------------------------------------------

// ISS-0121: worker_a/worker_b moved into each test as `try randomUuidStr(alloc); defer alloc.free(...)`
// ISS-0121: worker_a/worker_b moved into each test as `try randomUuidStr(alloc); defer alloc.free(...)`

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL. Fails with a clear error if absent (DIRECTIVE: no SkipZigTest).
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-102 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (Stage 12 schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 10,
    });
    errdefer pool.deinit();
    // Apply any pending migrations to tenant_default (e.g. 082_iss102_tasks_claimed_by).
    // runForSchema is idempotent: it only applies migrations not already tracked in
    // schema_migrations for (schema_name='tenant_default', version=...).
    // Use an arena allocator so internal allocations from runForSchema are freed
    // immediately after it returns, avoiding std.testing.allocator leak failures.
    const build_opts = @import("build_options");
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        // force_reconcile=false: clean db_test baseline, no drift reapply
        // needed; the regular ledger-driven path is sufficient for this
        // claim-tracking test.
        bpm.migrations.Migrations.runForSchema(
            arena.allocator(),
            &pool,
            build_opts.migrations_dir,
            "tenant_default",
            false,
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
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1 AND version = $2", &.{ name, version }) catch {};
}

fn createActiveDefinition(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    name: []const u8,
    version: []const u8,
) ![16]u8 {
    const creator_hex = try randomUuidStr(allocator);
    defer allocator.free(creator_hex);
    const creator_id = try parseUuid(allocator, creator_hex);
    const created = try def_store.create(allocator, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = test_graph,
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

/// Query the first PENDING task_id for the given instance. Returns a heap-allocated hex string.
fn getFirstTaskIdStr(pool: *Pool, allocator: std.mem.Allocator, instance_id_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var result = try conn.query(
        allocator,
        "SELECT id FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING' LIMIT 1",
        &.{instance_id_hex},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0][0] == null) return error.NoTask;
    return allocator.dupe(u8, result.rows[0][0].?);
}

/// Set claimed_by on a task row directly via SQL (autocommit connection).
fn setTaskClaimedBy(pool: *Pool, task_id_hex: []const u8, claimed_by_hex: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "UPDATE tasks SET claimed_by = $2::uuid WHERE id = $1::uuid",
        &.{ task_id_hex, claimed_by_hex },
    );
}

/// Set assignee_type, assignee_ref, and clear claimed_by on a task row.
fn setTaskUserAssignee(pool: *Pool, task_id_hex: []const u8, assignee_ref_hex: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "UPDATE tasks SET assignee_type = 'USER', assignee_ref = $2, claimed_by = NULL WHERE id = $1::uuid",
        &.{ task_id_hex, assignee_ref_hex },
    );
}

/// Build a TASK_WORKER actor (is_operator_or_above = false).
fn makeWorkerActor(user_id: []const u8) Actor {
    return Actor{
        .user_id = user_id,
        .roles = null,
        .is_operator_or_above = false,
        .is_platform_admin = false,
    };
}

// ---------------------------------------------------------------------------
// TC-ISS-102-01: Happy path — claimTask sets claimed_by
// ---------------------------------------------------------------------------

test "TC-ISS-102-01: happy path — claimTask sets claimed_by" {
    // covers: ISS-102 AC-1
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC01";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);
    const task_id = try parseUuid(alloc, task_id_str);

    var task_store = TaskStore.init(&pool);

    // Act: claim the task as worker_a.
    const claimed = try task_store.claimTask(alloc, task_id, worker_a);
    defer bpm.tasks.freeTask(alloc, claimed);

    // Assert: claimed_by is set to worker_a.
    const cb = claimed.claimed_by orelse {
        std.debug.print("TC-ISS-102-01: claimed_by is null after successful claim\n", .{});
        return error.ClaimedByIsNull;
    };
    const cb_hex = try uuidToHexStr(alloc, cb);
    defer alloc.free(cb_hex);

    try std.testing.expectEqualStrings(worker_a, cb_hex);
    // Status stays PENDING after claim (claim does not transition status).
    try std.testing.expectEqual(TaskStatus.PENDING, claimed.status);
}

// ---------------------------------------------------------------------------
// TC-ISS-102-02: Concurrent double-claim — exactly one wins
// ---------------------------------------------------------------------------

const ClaimCtx = struct {
    task_store: *TaskStore,
    task_id: [16]u8,
    worker_id: []const u8,
    succeeded: bool = false,
    got_already_claimed: bool = false,
};

fn claimWorkerThread(ctx: *ClaimCtx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Set tenant context for this worker thread so pool.acquire() sets
    // search_path = tenant_default,public (threadlocal is per-thread).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");

    var attempts: u32 = 0;
    while (attempts < 1000) : (attempts += 1) {
        const task = ctx.task_store.claimTask(arena.allocator(), ctx.task_id, ctx.worker_id) catch |err| switch (err) {
            ClaimError.AlreadyClaimed => {
                ctx.got_already_claimed = true;
                return;
            },
            ClaimError.PoolExhausted => {
                // Yield and retry — pool was temporarily exhausted.
                _ = arena.reset(.retain_capacity);
                std.Thread.yield() catch {};
                continue;
            },
            else => return, // unexpected error; leave flags false
        };
        bpm.tasks.freeTask(arena.allocator(), task);
        ctx.succeeded = true;
        return;
    }
}

test "TC-ISS-102-02: concurrent double-claim — exactly one wins" {
    // covers: ISS-102 AC-2
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC02";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);
    const task_id = try parseUuid(alloc, task_id_str);

    var task_store = TaskStore.init(&pool);

    // Spawn two threads that both attempt to claim the same task.
    var ctx_a = ClaimCtx{
        .task_store = &task_store,
        .task_id = task_id,
        .worker_id = worker_a,
    };
    var ctx_b = ClaimCtx{
        .task_store = &task_store,
        .task_id = task_id,
        .worker_id = worker_b,
    };

    const thr_a = try std.Thread.spawn(.{}, claimWorkerThread, .{&ctx_a});
    const thr_b = try std.Thread.spawn(.{}, claimWorkerThread, .{&ctx_b});

    thr_a.join();
    thr_b.join();

    // Exactly one must have succeeded; the other must have got AlreadyClaimed.
    const success_count: u32 = @as(u32, if (ctx_a.succeeded) 1 else 0) +
        @as(u32, if (ctx_b.succeeded) 1 else 0);
    const already_claimed_count: u32 = @as(u32, if (ctx_a.got_already_claimed) 1 else 0) +
        @as(u32, if (ctx_b.got_already_claimed) 1 else 0);

    if (success_count != 1) {
        std.debug.print(
            "TC-ISS-102-02: expected 1 success, got {d} (a.succeeded={}, b.succeeded={})\n",
            .{ success_count, ctx_a.succeeded, ctx_b.succeeded },
        );
    }
    if (already_claimed_count != 1) {
        std.debug.print(
            "TC-ISS-102-02: expected 1 AlreadyClaimed, got {d}\n",
            .{already_claimed_count},
        );
    }

    try std.testing.expectEqual(@as(u32, 1), success_count);
    try std.testing.expectEqual(@as(u32, 1), already_claimed_count);

    // Verify DB: claimed_by is non-NULL.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var rows = try conn.query(
            alloc,
            "SELECT claimed_by IS NOT NULL FROM tasks WHERE id = $1::uuid",
            &.{task_id_str},
        );
        defer rows.deinit();
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        const val = rows.rows[0][0] orelse "f";
        try std.testing.expect(std.mem.eql(u8, val, "t") or std.mem.eql(u8, val, "true"));
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-102-03: Claim on already-claimed task returns AlreadyClaimed
// ---------------------------------------------------------------------------

test "TC-ISS-102-03: claim on already-claimed task returns AlreadyClaimed" {
    // covers: ISS-102 AC-3
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC03";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);
    const task_id = try parseUuid(alloc, task_id_str);

    var task_store = TaskStore.init(&pool);

    // Pre-condition: worker_a already holds the task.
    try setTaskClaimedBy(&pool, task_id_str, worker_a);

    // Act: worker_b attempts to claim — must get AlreadyClaimed.
    const result = task_store.claimTask(alloc, task_id, worker_b);
    try std.testing.expectError(error.AlreadyClaimed, result);
}

// ---------------------------------------------------------------------------
// TC-ISS-102-04: Claim on non-PENDING task returns NotPending
// ---------------------------------------------------------------------------

test "TC-ISS-102-04: claim on non-PENDING task returns NotPending" {
    // covers: ISS-102 AC-4
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC04";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);
    const task_id = try parseUuid(alloc, task_id_str);

    var task_store = TaskStore.init(&pool);

    // Force task to COMPLETED via direct SQL.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            "UPDATE tasks SET status = 'COMPLETED' WHERE id = $1::uuid",
            &.{task_id_str},
        );
    }

    // Act: claim a COMPLETED task — must get NotPending.
    const result = task_store.claimTask(alloc, task_id, worker_a);
    try std.testing.expectError(error.NotPending, result);
}

// ---------------------------------------------------------------------------
// TC-ISS-102-05: Complete by claimed_by worker succeeds
// ---------------------------------------------------------------------------

test "TC-ISS-102-05: complete by claimed_by worker succeeds" {
    // covers: ISS-102 AC-5
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC05";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);

    // Set claimed_by = worker_a.
    try setTaskClaimedBy(&pool, task_id_str, worker_a);

    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    // Act: worker_a completes the task.
    const actor = makeWorkerActor(worker_a);
    const result = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &id_service,
        alloc,
        actor,
        task_id_str,
        "{\"output_variables\":{}}",
    );
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"status\":\"ok\""));
}

// ---------------------------------------------------------------------------
// TC-ISS-102-06: Complete by different worker returns 403
// ---------------------------------------------------------------------------

test "TC-ISS-102-06: complete by different worker returns 403" {
    // covers: ISS-102 AC-6
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC06";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);

    // Set claimed_by = worker_a.
    try setTaskClaimedBy(&pool, task_id_str, worker_a);

    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    // Act: worker_b (not the claimer) attempts to complete.
    const actor = makeWorkerActor(worker_b);
    const result = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &id_service,
        alloc,
        actor,
        task_id_str,
        "{\"output_variables\":{}}",
    );
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 403), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "UNAUTHORIZED_COMPLETE"));
}

// ---------------------------------------------------------------------------
// TC-ISS-102-07: Complete USER-assigned unclaimed task by that user succeeds
// ---------------------------------------------------------------------------

test "TC-ISS-102-07: complete USER-assigned unclaimed task by that user succeeds" {
    // covers: ISS-102 AC-7
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC07";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);

    // Set assignee_type = 'USER', assignee_ref = worker_a, claimed_by = NULL.
    try setTaskUserAssignee(&pool, task_id_str, worker_a);

    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    // Act: worker_a (the assignee) completes the unclaimed task.
    const actor = makeWorkerActor(worker_a);
    const result = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &id_service,
        alloc,
        actor,
        task_id_str,
        "{\"output_variables\":{}}",
    );
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "\"status\":\"ok\""));
}

// ---------------------------------------------------------------------------
// TC-ISS-102-08: Complete USER-assigned unclaimed task by different user returns 403
// ---------------------------------------------------------------------------

test "TC-ISS-102-08: complete USER-assigned unclaimed task by different user returns 403" {
    // covers: ISS-102 AC-8
    const worker_a = try randomUuidStr(alloc); defer alloc.free(worker_a);
    const worker_b = try randomUuidStr(alloc); defer alloc.free(worker_b);
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_name = "ISS102-TC08";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    const inst = try inst_store.create(alloc, def_id, null, "{}");
    const inst_id_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_id_hex);
    freeInstance(alloc, inst);
    defer cleanupInstance(&pool, inst_id_hex);

    const task_id_str = try getFirstTaskIdStr(&pool, alloc, inst_id_hex);
    defer alloc.free(task_id_str);

    // Set assignee_type = 'USER', assignee_ref = worker_a, claimed_by = NULL.
    try setTaskUserAssignee(&pool, task_id_str, worker_a);

    var id_registry = bpm.identity_registry.Registry.init(&pool);
    var id_service = bpm.identity_service.Service.init(&id_registry);

    // Act: worker_b (not the assignee) attempts to complete the unclaimed task.
    const actor = makeWorkerActor(worker_b);
    const result = bpm.task_routes.handleComplete(
        &task_store,
        &inst_store,
        &id_service,
        alloc,
        actor,
        task_id_str,
        "{\"output_variables\":{}}",
    );
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 403), result.status_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "UNAUTHORIZED_COMPLETE"));
}
