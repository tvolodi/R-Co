//! Integration tests for EE-12 — Concurrent Instance Safety.
//!
//! Exercises InstanceStore.completeTask() under concurrent load using a real
//! PostgreSQL database.  The pool implementation returns ExhaustedPool
//! immediately (non-blocking acquire), so threads retry with backoff.
//!
//! Requires: BPM_TEST_DB_URL environment variable.
//!
//! Isolation: each test creates its own process_definition, instances, tokens,
//! and tasks; cleans up in FK order on completion.
//!
//! Requirement traceability:
//!   EE-12 → TC-EE-12-01 (concurrent distinct instances)
//!   EE-12 → TC-EE-12-02 / TC-EE-12-04 (same-instance contention + error code)

const std = @import("std");

const portable_env = @import("env");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

// Root-level exports required by TestHarness.init() to set the pool's tenant context.
// Without these, pool connections use search_path=public and cannot find tenant-schema
// tables (process_definitions, instance_projections, tasks, etc.) — see
// GBL-073 (legacy public business tables dropped) and Stage 12 schema isolation.
pub const api_tenant_context = bpm.api_tenant_context;
pub const api_pipeline_context = bpm.api_pipeline_context;

const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const Definition = bpm.definition.Definition;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const CompleteTaskError = bpm.engine.CompleteTaskError;
const Instance = bpm.engine.Instance;

const TaskStore = bpm.tasks.TaskStore;

// ---------------------------------------------------------------------------
// Minimal graph: START → HUMAN_TASK "T" → END
// ---------------------------------------------------------------------------

const test_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"user\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const test_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const test_graph = DefinitionGraph{
    .nodes = &test_nodes,
    .edges = &test_edges,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping EE-12 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8, pool_size: u32) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (Stage 12 schema
    // isolation) on the main thread's connections.
    bpm.api_tenant_context.set(DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = @intCast(pool_size),
    });
}

/// Parse a 36-char UUID string (with hyphens) into [16]u8.
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

/// Render [16]u8 as lowercase UUID hex with hyphens (36 chars).
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

/// Free heap-allocated fields of a Definition.
fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

/// Free heap-allocated fields of an Instance.
fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

/// Delete all rows for one instance (FK order). Best-effort.
fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    // Cascade from instance_projections to tokens (tokens.instance_id FK ON DELETE CASCADE).
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

/// Delete process_definitions row by name. Best-effort.
fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

// ---------------------------------------------------------------------------
// setupInstanceWithTask
//
// Creates a process instance via InstanceStore.create() and then inserts a
// token + PENDING task via raw SQL so that completeTask() can be called.
//
// Returns task_id as [16]u8.  inst_id_hex_out is filled with a heap-allocated
// 36-char UUID hex string (caller frees with `allocator`).
// ---------------------------------------------------------------------------

fn setupInstanceWithTask(
    allocator: std.mem.Allocator,
    pool: *Pool,
    inst_store: *InstanceStore,
    def_id: [16]u8,
    inst_id_hex_out: *[]u8,
) ![16]u8 {
    // Create the instance (inserts instance_projections + snapshot rows).
    const inst = try inst_store.create(allocator, def_id, null, "{}");
    defer freeInstance(allocator, inst);

    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    inst_id_hex_out.* = inst_id_hex;

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Insert token row; let PostgreSQL generate the UUID via DEFAULT gen_random_uuid().
    const tok_rows = try conn.query(
        allocator,
        "INSERT INTO tokens (instance_id, current_node, status) VALUES ($1::uuid, 'T', 'active') RETURNING id",
        &.{inst_id_hex},
    );
    defer {
        var r = tok_rows;
        r.deinit();
    }
    if (tok_rows.rows.len == 0) return error.TokenInsertFailed;
    const tok_hex = (tok_rows.rows[0][0]) orelse return error.TokenInsertFailed;

    // Place token at node "T" in current_nodes projection.
    const current_nodes_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"node_id\":\"T\",\"branch_id\":\"{s}\"}}]",
        .{tok_hex},
    );
    defer allocator.free(current_nodes_json);
    try conn.exec(
        "UPDATE instance_projections SET current_nodes = $2::jsonb WHERE instance_id = $1::uuid",
        &.{ inst_id_hex, current_nodes_json },
    );

    // Insert PENDING task and capture its generated UUID.
    const task_rows = try conn.query(
        allocator,
        "INSERT INTO tasks (instance_id, token_id, node_id, node_name, status) VALUES ($1::uuid, $2::uuid, 'T', 'T', 'PENDING') RETURNING id",
        &.{ inst_id_hex, tok_hex },
    );
    defer {
        var r = task_rows;
        r.deinit();
    }
    if (task_rows.rows.len == 0) return error.TaskInsertFailed;
    const task_id_str = (task_rows.rows[0][0]) orelse return error.TaskInsertFailed;
    return parseUuid(allocator, task_id_str);
}

// ---------------------------------------------------------------------------
// TC-EE-12-01  &  TC-EE-12-03
// ---------------------------------------------------------------------------

const NUM_INSTANCES: usize = 100;

/// Per-thread context for TC-EE-12-01.
const CompletionCtx = struct {
    inst_store: *InstanceStore,
    task_store: *TaskStore,
    task_id: [16]u8,
    /// Set to true by the thread on success; remains false on any error.
    succeeded: bool = false,
};

/// Thread function for TC-EE-12-01.
/// Retries on PoolExhausted (non-blocking acquire returns immediately).
fn completionThread(ctx: *CompletionCtx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Set tenant context for this worker thread so pool.acquire() sets
    // search_path = tenant_default,public (threadlocal is per-thread).
    bpm.api_tenant_context.set(DEFAULT_TENANT_ID);

    var attempts: u32 = 0;
    while (attempts < 10_000) : (attempts += 1) {
        _ = ctx.inst_store.completeTask(
            arena.allocator(),
            ctx.task_store,
            ctx.task_id,
            "{}",
        ) catch |err| switch (err) {
            error.PoolExhausted => {
                // Pool is full; yield and retry.
                _ = arena.reset(.retain_capacity);
                std.Thread.yield() catch {};
                continue;
            },
            else => return, // genuine failure — leave succeeded = false
        };
        ctx.succeeded = true;
        return;
    }
}

test "TC-EE-12-01/03: 100 concurrent task completions on distinct instances all succeed" {
    const allocator = std.testing.allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    // Pool sized to NUM_INSTANCES so every thread can acquire without
    // PoolExhausted: each completeTask holds at most 1 connection at a time.
    var pool = try makePool(allocator, url, NUM_INSTANCES);
    defer pool.deinit();

    // ── Create and activate a definition ────────────────────────────────
    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();

    const creator_id = try parseUuid(allocator, "00000000-0000-0000-0000-000000000099");
    const draft = try def_store.create(allocator, CreateParams{
        .name = "ee12-concurrent-test",
        .version = "1.0",
        .description = null,
        .graph = test_graph,
        .created_by = creator_id,
    });
    defer freeDefinition(allocator, draft);
    defer cleanupByName(&pool, "ee12-concurrent-test");

    const active_def = try def_store.activate(allocator, draft.id);
    defer freeDefinition(allocator, active_def);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    // ── Set up NUM_INSTANCES instances with tasks ────────────────────────
    var ctxs: [NUM_INSTANCES]CompletionCtx = undefined;
    var inst_hexes: [NUM_INSTANCES][]u8 = undefined;

    for (&ctxs, &inst_hexes, 0..) |*ctx, *hex, i| {
        _ = i;
        const task_id = try setupInstanceWithTask(
            allocator,
            &pool,
            &inst_store,
            draft.id,
            hex,
        );
        ctx.* = CompletionCtx{
            .inst_store = &inst_store,
            .task_store = &task_store,
            .task_id = task_id,
        };
    }

    // Clean up all instances on exit regardless of test result.
    defer for (inst_hexes) |hex| {
        cleanupInstance(&pool, hex);
        allocator.free(hex);
    };

    // ── Spawn NUM_INSTANCES threads ──────────────────────────────────────
    var threads: [NUM_INSTANCES]std.Thread = undefined;
    for (&threads, &ctxs) |*thr, *ctx| {
        thr.* = try std.Thread.spawn(.{}, completionThread, .{ctx});
    }

    // ── Join all threads ─────────────────────────────────────────────────
    for (&threads) |thr| {
        thr.join();
    }

    // ── Assert all succeeded ─────────────────────────────────────────────
    for (&ctxs, 0..) |*ctx, i| {
        if (!ctx.succeeded) {
            std.debug.print("TC-EE-12-01: thread {} did NOT succeed\n", .{i});
        }
        try std.testing.expect(ctx.succeeded);
    }
}

// ---------------------------------------------------------------------------
// TC-EE-12-02  &  TC-EE-12-04
// ---------------------------------------------------------------------------

/// Context for the contention-check worker thread.
const ContentionCtx = struct {
    inst_store: *InstanceStore,
    task_store: *TaskStore,
    task_id: [16]u8,
    /// Filled by the worker thread: the error it received (null = success).
    err: ?CompleteTaskError = null,
    done: bool = false,
};

/// Worker thread for TC-EE-12-02.
fn contentionThread(ctx: *ContentionCtx) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Set tenant context for this worker thread so pool.acquire() sets
    // search_path = tenant_default,public (threadlocal is per-thread).
    bpm.api_tenant_context.set(DEFAULT_TENANT_ID);

    _ = ctx.inst_store.completeTask(
        arena.allocator(),
        ctx.task_store,
        ctx.task_id,
        "{}",
    ) catch |err| {
        ctx.err = err;
        ctx.done = true;
        return;
    };
    ctx.err = null;
    ctx.done = true;
}

test "TC-EE-12-02/04: same-instance contention returns ConcurrentModification then succeeds" {
    const allocator = std.testing.allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    // 5 connections: main holds 1 for the lock, worker needs at most 2.
    var pool = try makePool(allocator, url, 5);
    defer pool.deinit();

    // ── Create and activate a definition ────────────────────────────────
    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();

    const creator_id = try parseUuid(allocator, "00000000-0000-0000-0000-000000000099");
    const draft = try def_store.create(allocator, CreateParams{
        .name = "ee12-contention-test",
        .version = "1.0",
        .description = null,
        .graph = test_graph,
        .created_by = creator_id,
    });
    defer freeDefinition(allocator, draft);
    defer cleanupByName(&pool, "ee12-contention-test");

    const active_def = try def_store.activate(allocator, draft.id);
    defer freeDefinition(allocator, active_def);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();
    var task_store = TaskStore.init(&pool);

    // ── Create one instance with a PENDING task ─────────────────────────
    var inst_id_hex: []u8 = undefined;
    const task_id = try setupInstanceWithTask(
        allocator,
        &pool,
        &inst_store,
        draft.id,
        &inst_id_hex,
    );
    defer {
        cleanupInstance(&pool, inst_id_hex);
        allocator.free(inst_id_hex);
    }

    // ── Main thread holds FOR UPDATE NOWAIT lock ────────────────────────
    // Simulate the state inside completeTask() step-f before it commits.
    const lock_conn = try pool.acquire();

    var lock_arena = std.heap.ArenaAllocator.init(allocator);
    defer lock_arena.deinit();

    try lock_conn.begin();
    {
        const lock_rows = try lock_conn.query(
            lock_arena.allocator(),
            "SELECT instance_id FROM instance_projections WHERE instance_id = $1::uuid FOR UPDATE NOWAIT",
            &.{inst_id_hex},
        );
        var lr = lock_rows;
        lr.deinit();
    }

    // ── Spawn worker thread ─────────────────────────────────────────────
    var wctx = ContentionCtx{
        .inst_store = &inst_store,
        .task_store = &task_store,
        .task_id = task_id,
    };
    const worker = try std.Thread.spawn(.{}, contentionThread, .{&wctx});
    worker.join();

    // TC-EE-12-02 / TC-EE-12-04: worker must receive ConcurrentModification.
    try std.testing.expect(wctx.done);
    try std.testing.expectEqual(CompleteTaskError.ConcurrentModification, wctx.err.?);

    // ── Release the lock ────────────────────────────────────────────────
    try lock_conn.rollback();
    pool.release(lock_conn);

    // ── Main thread completes the task successfully ─────────────────────
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try inst_store.completeTask(arena.allocator(), &task_store, task_id, "{}");

    // Verify instance is COMPLETED.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            arena.allocator(),
            "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        try std.testing.expect(rows.rows.len > 0);
        const status = (rows.rows[0][0]) orelse "";
        try std.testing.expectEqualStrings("COMPLETED", status);
    }
}
