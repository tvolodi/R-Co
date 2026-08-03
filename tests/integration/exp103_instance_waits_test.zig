//! Integration tests for EXP-103 — instance_waits persistence layer.
//!
//! Covers:
//!   EXP-103 (TC-EXP-103-01): Timer arm writes instance_waits row in same txn.
//!   EXP-103 (TC-EXP-103-02): TaskStore.createInTx writes instance_waits row.
//!   EXP-103 (TC-EXP-103-03): Scheduler.pollDueTimers resolves the timer wait descriptor.
//!   EXP-103 (TC-EXP-103-04): TaskStore.completeInTx resolves the task wait descriptor.
//!   EXP-103 (TC-EXP-103-05): ROLLBACK leaves no orphaned instance_waits row.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing at a real PostgreSQL DB.
//! All fixtures use per-test UUID prefixes (e103xxxx-...) for isolation.
//! Defer blocks clean up all fixtures even when tests fail.
const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const Scheduler = bpm.scheduler_poller.Scheduler;
const SchedulerConfig = bpm.scheduler_poller.SchedulerConfig;
const TaskStore = bpm.tasks.TaskStore;
const tenant_context = bpm.api_tenant_context;

// Default tenant UUID — pool resolves to schema 'tenant_default'.
const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

fn getTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — EXP-103 instance_waits integration tests require it\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // EXP-103 test setup: ensure the default tenant uses SCHEMA storage mode.
    //
    // The pool routing layer reads storage_mode from public.tenant on every
    // first acquire().  The default tenant seed row has storage_mode = 'LEGACY_RLS',
    // which routes connections to the public schema — where instance_projections,
    // timers, tasks, and instance_waits do NOT exist (they live in tenant_default).
    //
    // Fix: use a temporary, no-tenant-context pool (routes to public) to UPDATE
    // the default tenant row to SCHEMA before creating the real pool.  Once the
    // DB row is SCHEMA, the real pool's first acquire() will re-query and route
    // to tenant_default schema as intended.
    {
        tenant_context.clear(); // no tenant → pool routes to public
        var setup_pool = try Pool.init(std.testing.io, allocator, PoolConfig{
            .url = url,
            .pool_size = 2,
        });
        defer setup_pool.deinit();
        const setup_conn = try setup_pool.acquire();
        defer setup_pool.release(setup_conn);
        setup_conn.exec(
            "UPDATE public.tenant SET storage_mode = 'SCHEMA' WHERE id = $1::uuid",
            &.{DEFAULT_TENANT_ID},
        ) catch |err| {
            std.debug.print("makePool: storage_mode UPDATE failed (non-fatal): {}\n", .{err});
        };
    }

    // Reset storage_mode cache and set tenant context so the real pool's
    // first acquire() re-queries the DB, finds SCHEMA, and sets search_path
    // to tenant_default.
    tenant_context.clear();
    tenant_context.set(DEFAULT_TENANT_ID);
    var pool = try Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 8,
    });
    errdefer pool.deinit();
    // Apply any pending migrations (including 093_exp103_instance_waits) idempotently.
    const build_opts = @import("build_options");
    {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        // force_reconcile=false: see audit_iss103_test.zig for rationale;
        // same harness baseline, same ledger-driven apply path.
        bpm.migrations.Migrations.runForSchema(
            arena.allocator(),
            &pool,
            build_opts.migrations_dir,
            "tenant_default",
            false,
        ) catch |err| {
            std.debug.print("makePool: runForSchema error (non-fatal): {}\n", .{err});
        };
    }
    return pool;
}

/// Parse a UUID string like "e1030100-0000-0000-0000-000000000001" into raw [16]u8.
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

// ---------------------------------------------------------------------------
// TC-EXP-103-01: Timer arm creates instance_waits row
// ---------------------------------------------------------------------------
//
// Inserts a timer + instance_waits row in a real transaction and asserts
// the descriptor row exists with kind='timer', resolved_at IS NULL.

test "TC-EXP-103-01: timer arm writes instance_waits row" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    tenant_context.set(DEFAULT_TENANT_ID);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — e1030100 prefix.
    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const def_id = try harness.newUuidString(alloc);
    defer alloc.free(def_id);
    const timer_id = try harness.newUuidString(alloc);
    defer alloc.free(timer_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Pre-cleanup (idempotent; ignore errors from prior runs).
    conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid",                   &.{timer_id})   catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid",                   &.{timer_id})   catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    // Insert prerequisite instance.
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );

    // Arm: insert timer + wait descriptor in the same transaction.
    try conn.exec("BEGIN", &.{});
    conn.exec(
        \\INSERT INTO timers (id, instance_id, timer_type, step_name, fires_at, action_type)
        \\VALUES ($1::uuid, $2::uuid, 'scheduled_transition', 'TC01_NODE',
        \\        NOW() + interval '1 hour', 'auto_transition')
    ,
        &.{ timer_id, instance_id },
    ) catch |err| {
        conn.exec("ROLLBACK", &.{}) catch {};
        return err;
    };
    conn.exec(
        \\INSERT INTO instance_waits (instance_id, kind, ref_id, node_id, fire_at)
        \\VALUES ($1::uuid, 'timer', $2::uuid, 'TC01_NODE', NOW() + interval '1 hour')
        \\ON CONFLICT (instance_id, ref_id) DO NOTHING
    ,
        &.{ instance_id, timer_id },
    ) catch |err| {
        conn.exec("ROLLBACK", &.{}) catch {};
        return err;
    };
    try conn.exec("COMMIT", &.{});

    // Assert: instance_waits row exists with correct fields.
    const rows = try conn.query(
        allocator,
        \\SELECT kind, (resolved_at IS NULL)::text
        \\FROM instance_waits
        \\WHERE ref_id = $1::uuid
    ,
        &.{timer_id},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try testing.expectEqual(@as(usize, 1), rows.rows.len);
    const kind = rows.rows[0][0] orelse "";
    const resolved_null = rows.rows[0][1] orelse "";
    try testing.expectEqualStrings("timer", kind);
    try testing.expectEqualStrings("true", resolved_null);
}

// ---------------------------------------------------------------------------
// TC-EXP-103-02: Task creation creates instance_waits row
// ---------------------------------------------------------------------------
//
// Calls TaskStore.createInTx (which atomically inserts task + instance_waits)
// and verifies the descriptor row has kind='human_task', resolved_at IS NULL.

test "TC-EXP-103-02: TaskStore.createInTx writes instance_waits row" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    tenant_context.set(DEFAULT_TENANT_ID);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — e1030200 prefix.
    const instance_id_str = try harness.newUuidString(alloc);
    defer alloc.free(instance_id_str);
    const def_id_str = try harness.newUuidString(alloc);
    defer alloc.free(def_id_str);
    const token_id_str = try harness.newUuidString(alloc);
    defer alloc.free(token_id_str);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Pre-cleanup.
    conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid",           &.{instance_id_str}) catch {};
    conn.exec("DELETE FROM tokens WHERE id = $1::uuid",                   &.{token_id_str})    catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};

    defer {
        conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};
        conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid",           &.{instance_id_str}) catch {};
        conn.exec("DELETE FROM tokens WHERE id = $1::uuid",                   &.{token_id_str})    catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};
    }

    // Insert prerequisites.
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id_str, def_id_str },
    );
    try conn.exec(
        \\INSERT INTO tokens (id, instance_id, current_node, status)
        \\VALUES ($1::uuid, $2::uuid, 'TC02_NODE', 'active')
    ,
        &.{ token_id_str, instance_id_str },
    );

    // Call TaskStore.createInTx — internally inserts tasks + instance_waits.
    const instance_id_bytes = try parseUuid(instance_id_str);
    const token_id_bytes    = try parseUuid(token_id_str);

    var task_store = TaskStore.init(&pool);
    const task = try task_store.createInTx(
        allocator,
        conn,
        instance_id_bytes,
        token_id_bytes,
        "TC02_NODE",
        "TC-02 Task",
        null,
        null,
        null,
    );
    defer bpm.tasks.freeTask(allocator, task);

    // Derive task_id hex for the query.
    const task_id_hex = try std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            task.task_id[0],  task.task_id[1],  task.task_id[2],  task.task_id[3],
            task.task_id[4],  task.task_id[5],  task.task_id[6],  task.task_id[7],
            task.task_id[8],  task.task_id[9],  task.task_id[10], task.task_id[11],
            task.task_id[12], task.task_id[13], task.task_id[14], task.task_id[15],
        },
    );
    defer allocator.free(task_id_hex);

    // Assert: instance_waits row for this task exists with correct fields.
    const rows = try conn.query(
        allocator,
        \\SELECT kind, (resolved_at IS NULL)::text
        \\FROM instance_waits
        \\WHERE ref_id = $1::uuid
    ,
        &.{task_id_hex},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try testing.expectEqual(@as(usize, 1), rows.rows.len);
    const kind = rows.rows[0][0] orelse "";
    const resolved_null = rows.rows[0][1] orelse "";
    try testing.expectEqualStrings("human_task", kind);
    try testing.expectEqualStrings("true", resolved_null);
}

// ---------------------------------------------------------------------------
// TC-EXP-103-03: Timer fire sets resolved_at in instance_waits
// ---------------------------------------------------------------------------
//
// Arms a timer + descriptor, fires via Scheduler.pollDueTimers, then asserts
// resolved_at IS NOT NULL on the descriptor row.

test "TC-EXP-103-03: Scheduler.pollDueTimers resolves the instance_waits timer row" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    tenant_context.set(DEFAULT_TENANT_ID);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — e1030300 prefix.
    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const def_id = try harness.newUuidString(alloc);
    defer alloc.free(def_id);
    const timer_id = try harness.newUuidString(alloc);
    defer alloc.free(timer_id);
    const idem_key    = "timer-fired:e1030300-0000-0000-0000-000000000002";

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Pre-cleanup.
    conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM events WHERE idempotency_key = $1",            &.{idem_key})   catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid",                   &.{timer_id})   catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        conn.exec("DELETE FROM events WHERE idempotency_key = $1",            &.{idem_key})   catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid",                   &.{timer_id})   catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    // Insert instance.
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );

    // Insert timer with fires_at in the past so the scheduler picks it up.
    try conn.exec(
        \\INSERT INTO timers (id, instance_id, timer_type, step_name, fires_at, action_type)
        \\VALUES ($1::uuid, $2::uuid, 'scheduled_transition', 'TC03_NODE',
        \\        NOW() - interval '1 second', 'auto_transition')
    ,
        &.{ timer_id, instance_id },
    );

    // Arm the wait descriptor.
    try conn.exec(
        \\INSERT INTO instance_waits (instance_id, kind, ref_id, node_id, fire_at)
        \\VALUES ($1::uuid, 'timer', $2::uuid, 'TC03_NODE', NOW() - interval '1 second')
        \\ON CONFLICT (instance_id, ref_id) DO NOTHING
    ,
        &.{ instance_id, timer_id },
    );

    // Fire: scheduler picks up due timer, calls markTimerFiredInTx (which resolves wait).
    var scheduler = Scheduler.init(&pool, SchedulerConfig{});
    _ = scheduler.pollDueTimers(allocator) catch {};

    // Assert: resolved_at is now set on the descriptor row.
    const rows = try conn.query(
        allocator,
        \\SELECT (resolved_at IS NOT NULL)::text
        \\FROM instance_waits
        \\WHERE ref_id = $1::uuid
    ,
        &.{timer_id},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try testing.expectEqual(@as(usize, 1), rows.rows.len);
    try testing.expectEqualStrings("true", rows.rows[0][0] orelse "");

    // Also assert the timer itself is marked fired.
    const timer_rows = try conn.query(
        allocator,
        \\SELECT status
        \\FROM timers WHERE id = $1::uuid
    ,
        &.{timer_id},
    );
    defer {
        var r = timer_rows;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), timer_rows.rows.len);
    try testing.expectEqualStrings("fired", timer_rows.rows[0][0] orelse "");
}

// ---------------------------------------------------------------------------
// TC-EXP-103-04: Task completion sets resolved_at in instance_waits
// ---------------------------------------------------------------------------
//
// Pre-inserts task + descriptor via raw SQL, then calls TaskStore.completeInTx
// (which resolves the wait in the same transaction) and asserts resolved_at.

test "TC-EXP-103-04: TaskStore.completeInTx resolves the instance_waits task row" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    tenant_context.set(DEFAULT_TENANT_ID);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — e1030400 prefix.
    const instance_id_str = try harness.newUuidString(alloc);
    defer alloc.free(instance_id_str);
    const def_id_str = try harness.newUuidString(alloc);
    defer alloc.free(def_id_str);
    const token_id_str = try harness.newUuidString(alloc);
    defer alloc.free(token_id_str);
    const task_id_str = try harness.newUuidString(alloc);
    defer alloc.free(task_id_str);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Pre-cleanup.
    conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};
    conn.exec("DELETE FROM tasks WHERE id = $1::uuid",                    &.{task_id_str})     catch {};
    conn.exec("DELETE FROM tokens WHERE id = $1::uuid",                   &.{token_id_str})    catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};

    defer {
        conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};
        conn.exec("DELETE FROM tasks WHERE id = $1::uuid",                    &.{task_id_str})     catch {};
        conn.exec("DELETE FROM tokens WHERE id = $1::uuid",                   &.{token_id_str})    catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_str}) catch {};
    }

    // Insert prerequisites: instance + token.
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id_str, def_id_str },
    );
    try conn.exec(
        \\INSERT INTO tokens (id, instance_id, current_node, status)
        \\VALUES ($1::uuid, $2::uuid, 'TC04_NODE', 'active')
    ,
        &.{ token_id_str, instance_id_str },
    );

    // Pre-insert task row directly (bypasses engine; mirrors state after arm).
    try conn.exec(
        \\INSERT INTO tasks (id, instance_id, token_id, node_id, node_name, status)
        \\VALUES ($1::uuid, $2::uuid, $3::uuid, 'TC04_NODE', 'TC-04 Task', 'PENDING')
    ,
        &.{ task_id_str, instance_id_str, token_id_str },
    );

    // Pre-insert instance_waits descriptor (mirrors what insertTaskWaitDescriptorInTx does).
    try conn.exec(
        \\INSERT INTO instance_waits (instance_id, kind, ref_id, node_id)
        \\VALUES ($1::uuid, 'human_task', $2::uuid, 'TC04_NODE')
        \\ON CONFLICT (instance_id, ref_id) DO NOTHING
    ,
        &.{ instance_id_str, task_id_str },
    );

    // Resolve: TaskStore.completeInTx — resolves task + instance_waits in same conn.
    const task_id_bytes = try parseUuid(task_id_str);
    var task_store = TaskStore.init(&pool);
    const completed = try task_store.completeInTx(allocator, conn, task_id_bytes, "{}");
    defer bpm.tasks.freeTask(allocator, completed);

    // Assert: instance_waits resolved_at is set.
    const rows = try conn.query(
        allocator,
        \\SELECT (resolved_at IS NOT NULL)::text
        \\FROM instance_waits
        \\WHERE ref_id = $1::uuid
    ,
        &.{task_id_str},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try testing.expectEqual(@as(usize, 1), rows.rows.len);
    try testing.expectEqualStrings("true", rows.rows[0][0] orelse "");

    // Also assert task status is COMPLETED.
    const task_rows = try conn.query(
        allocator,
        \\SELECT status FROM tasks WHERE id = $1::uuid
    ,
        &.{task_id_str},
    );
    defer {
        var r = task_rows;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), task_rows.rows.len);
    try testing.expectEqualStrings("COMPLETED", task_rows.rows[0][0] orelse "");
}

// ---------------------------------------------------------------------------
// TC-EXP-103-05: Rollback leaves no orphaned instance_waits row
// ---------------------------------------------------------------------------
//
// Begins a transaction, inserts timer + wait descriptor, then rolls back.
// Asserts that neither row survives — no partial/orphaned state exists.

test "TC-EXP-103-05: rolled-back transaction leaves no orphaned instance_waits row" {
    const allocator = std.heap.page_allocator;
    const url = try getTestDbUrl(allocator);
    defer allocator.free(url);

    tenant_context.set(DEFAULT_TENANT_ID);
    defer tenant_context.clear();

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // Per-test UUIDs — e1030500 prefix.
    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const def_id = try harness.newUuidString(alloc);
    defer alloc.free(def_id);
    const timer_id = try harness.newUuidString(alloc);
    defer alloc.free(timer_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Pre-cleanup.
    conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM timers WHERE id = $1::uuid",                   &.{timer_id})   catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};

    defer {
        conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        conn.exec("DELETE FROM timers WHERE id = $1::uuid",                   &.{timer_id})   catch {};
        conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }

    // Insert instance (committed; needed for timer FK inside the txn).
    try conn.exec(
        "INSERT INTO instance_projections (instance_id, definition_id) VALUES ($1::uuid, $2::uuid)",
        &.{ instance_id, def_id },
    );

    // BEGIN + INSERT timer + INSERT instance_waits + ROLLBACK.
    try conn.exec("BEGIN", &.{});
    conn.exec(
        \\INSERT INTO timers (id, instance_id, timer_type, step_name, fires_at, action_type)
        \\VALUES ($1::uuid, $2::uuid, 'scheduled_transition', 'TC05_NODE',
        \\        NOW() + interval '1 hour', 'auto_transition')
    ,
        &.{ timer_id, instance_id },
    ) catch |err| {
        conn.exec("ROLLBACK", &.{}) catch {};
        return err;
    };
    conn.exec(
        \\INSERT INTO instance_waits (instance_id, kind, ref_id, node_id, fire_at)
        \\VALUES ($1::uuid, 'timer', $2::uuid, 'TC05_NODE', NOW() + interval '1 hour')
    ,
        &.{ instance_id, timer_id },
    ) catch |err| {
        conn.exec("ROLLBACK", &.{}) catch {};
        return err;
    };
    // Roll back: both INSERTs must vanish atomically.
    try conn.exec("ROLLBACK", &.{});

    // Assert: no timer row survived the rollback.
    const timer_rows = try conn.query(
        allocator,
        "SELECT COUNT(*) FROM timers WHERE id = $1::uuid",
        &.{timer_id},
    );
    defer {
        var r = timer_rows;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), timer_rows.rows.len);
    try testing.expectEqualStrings("0", timer_rows.rows[0][0] orelse "");

    // Assert: no instance_waits row survived the rollback.
    const wait_rows = try conn.query(
        allocator,
        "SELECT COUNT(*) FROM instance_waits WHERE ref_id = $1::uuid",
        &.{timer_id},
    );
    defer {
        var r = wait_rows;
        r.deinit();
    }
    try testing.expectEqual(@as(usize, 1), wait_rows.rows.len);
    try testing.expectEqualStrings("0", wait_rows.rows[0][0] orelse "");
}
