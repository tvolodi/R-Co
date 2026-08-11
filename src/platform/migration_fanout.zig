//! Platform migration fanout — MIG-02, MIG-03
//!
//! Design artefact: src/design/mig-02-mig-03-platform-migration-fanout.md
//! Depends on: MIG-01 (platform.platform_migrations control table,
//! migrations/1144_platform_migrations_control_table.sql)
//!
//! Applies one platform migration across every enabled tenant, tracking
//! per-tenant outcome in platform.platform_migrations. Two tightly coupled
//! responsibilities:
//!
//!   - MIG-02 (commit-with-DDL): a tenant's control row moves to `done`
//!     inside the SAME transaction as that tenant's DDL, so a `done` row is
//!     proof the DDL committed. A failure is recorded as `failed` in a
//!     separate transaction opened only after the DDL transaction has rolled
//!     back — never inside it.
//!   - MIG-03 (fanout with continue-on-failure): the loop runs over a
//!     snapshot of enabled tenants ordered by tenant_id, taken once at the
//!     start of the run; a single pg_try_advisory_lock(hashtext(migration_id))
//!     serializes concurrent runs of the SAME migration_id (different
//!     migration_ids may run concurrently); a per-tenant failure never stops
//!     the loop.
//!
//! Builds on SPT-01: reuses pool.zig's Pool for connection acquisition and
//! pool.zig's schemaNameForTenant for schema resolution — the same
//! "acquire a connection, SET search_path, run DDL" shape
//! src/db/migrations.zig::Migrations.runForSchema already establishes,
//! generalized to a caller-supplied DDL step with its own lock and
//! accounting.
const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;
const Conn = pool_mod.Conn;
const PoolError = pool_mod.PoolError;
const logger = @import("../obs/logger.zig");

// ---------------------------------------------------------------------------
// Public request / response / error types
// ---------------------------------------------------------------------------

pub const FanoutRequest = struct {
    /// Identifies the migration being applied. Also the advisory-lock key
    /// input: pg_try_advisory_lock(hashtext(migration_id)).
    migration_id: []const u8,
    /// Caller-supplied correlation ID for this run, stored on every control
    /// row this run writes (platform.platform_migrations.run_id).
    run_id: []const u8,
};

pub const FanoutResult = struct {
    run_id: []const u8,
    done: u32,
    failed: u32,
    /// Always 0 at a normal return in this design (every snapshot tenant
    /// gets a done or failed row — MIG-03 AC1). Present because MIG-01's
    /// control table has a `pending` status and a future resume path (MIG-04,
    /// out of scope here) reads rows left pending by a crash mid-run; a
    /// clean run never leaves any.
    pending: u32,
};

pub const FanoutError = error{
    /// MIG-03 AC2: another run already holds the advisory lock for this
    /// migration_id. Caller maps this to HTTP 409 MigrationAlreadyRunning.
    MigrationAlreadyRunning,
    PoolExhausted,
    /// Reading the enabled-tenant snapshot itself failed (distinct from a
    /// per-tenant DDL failure, which is caught and recorded, never raised).
    SnapshotQueryFailed,
};

/// One tenant's unit of DDL work, supplied by the caller. Runs inside the
/// per-tenant transaction this module opens; must NOT open or commit its own
/// transaction — runFanout owns the transaction boundary (MIG-02's whole
/// point is that the control-row write and the DDL share one transaction the
/// fanout module opens and closes, not one the DDL step manages).
pub const DdlStep = *const fn (conn: *Conn, schema_name: []const u8) anyerror!void;

const TenantOutcome = enum { done, failed };

// ---------------------------------------------------------------------------
// runFanout
// ---------------------------------------------------------------------------

/// Apply `step` across a snapshot of enabled (`public.tenant.status =
/// 'ACTIVE'`) tenants, ordered by tenant_id ascending, tracking outcome in
/// platform.platform_migrations. See the design doc's Data flow section for
/// the full sequence diagram.
pub fn runFanout(
    allocator: std.mem.Allocator,
    pool: *Pool,
    request: FanoutRequest,
    step: DdlStep,
) FanoutError!FanoutResult {
    // ------------------------------------------------------------------
    // Acquire the advisory lock for this migration_id on a dedicated
    // connection, held for the duration of the run. pg_try_advisory_lock is
    // non-blocking: it returns immediately with a boolean rather than
    // queueing, which is what lets a contended second run be turned away
    // with MigrationAlreadyRunning (mapped by the caller to HTTP 409)
    // instead of hanging (MIG-03 AC2).
    // ------------------------------------------------------------------
    const lock_conn = pool.acquire() catch return FanoutError.PoolExhausted;
    // Released via pg_advisory_unlock in the deferred block below, then the
    // connection itself is released back to the pool. Both must happen even
    // on an early return (e.g. SnapshotQueryFailed) — deferred here rather
    // than relying on any exit path to remember it explicitly.
    var lock_acquired = false;
    defer {
        if (lock_acquired) {
            releaseMigrationLock(lock_conn, request.migration_id);
        }
        pool.release(lock_conn);
    }

    lock_acquired = try acquireMigrationLock(lock_conn, request.migration_id);
    if (!lock_acquired) {
        return FanoutError.MigrationAlreadyRunning;
    }

    // ------------------------------------------------------------------
    // Snapshot: enabled tenants, ordered by tenant_id. Taken ONCE — a
    // tenant created after this point has no pending row seeded for this
    // migration_id and is never visited by this run's loop (MIG-03 AC4;
    // being caught up is the tenant-onboarding path's job, out of scope
    // here — see the design doc's Open Questions §2).
    // ------------------------------------------------------------------
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var snapshot_result = lock_conn.query(
        arena_alloc,
        "SELECT id::text FROM public.tenant WHERE status = 'ACTIVE' ORDER BY id",
        &.{},
    ) catch return FanoutError.SnapshotQueryFailed;
    defer snapshot_result.deinit();

    const tenant_count = snapshot_result.rows.len;
    var tenant_ids = allocator.alloc([]const u8, tenant_count) catch return FanoutError.SnapshotQueryFailed;
    defer allocator.free(tenant_ids);
    for (snapshot_result.rows, 0..) |row, i| {
        const tenant_id_col = row[0] orelse return FanoutError.SnapshotQueryFailed;
        tenant_ids[i] = allocator.dupe(u8, tenant_id_col) catch return FanoutError.SnapshotQueryFailed;
    }
    defer for (tenant_ids) |tid| allocator.free(tid);

    // Seed control rows: one 'pending' row per snapshot tenant, upserted on
    // (migration_id, tenant_id) so a re-run of the same migration_id against
    // an unrelated snapshot (e.g. after a crash) does not duplicate rows —
    // ON CONFLICT DO NOTHING leaves any already-terminal row (done/failed)
    // from a prior run untouched here; this batch does not implement
    // re-running a done/failed row (that is MIG-05, out of scope).
    for (tenant_ids) |tenant_id| {
        seedPendingRow(lock_conn, request, tenant_id) catch return FanoutError.SnapshotQueryFailed;
    }

    // ------------------------------------------------------------------
    // Loop: apply step() to every snapshot tenant in order. A per-tenant
    // failure never stops the loop (MIG-03 AC1) — applyToTenant never
    // raises for a DDL failure, only records TenantOutcome.failed.
    // ------------------------------------------------------------------
    var done_count: u32 = 0;
    var failed_count: u32 = 0;
    for (tenant_ids) |tenant_id| {
        const outcome = applyToTenant(allocator, pool, request, tenant_id, step);
        switch (outcome) {
            .done => done_count += 1,
            .failed => failed_count += 1,
        }
    }

    return FanoutResult{
        .run_id = request.run_id,
        .done = done_count,
        .failed = failed_count,
        .pending = 0,
    };
}

// ---------------------------------------------------------------------------
// applyToTenant — MIG-02 transaction-boundary protocol
// ---------------------------------------------------------------------------

/// Applies `step` for exactly one tenant under MIG-02's transaction
/// protocol:
///   1. Acquire a fresh connection for this tenant from the pool.
///   2. BEGIN; SET LOCAL search_path TO <tenant_schema>,public.
///   3. Run step(conn, schema_name).
///   4a. On success: UPDATE the control row to 'done' in the SAME
///       transaction, then COMMIT. A done row is therefore proof the DDL
///       committed (MIG-02 AC1).
///   4b. On failure: ROLLBACK (neither partial DDL nor a done row survives
///       — MIG-02 AC2), then record 'failed' in a SEPARATE transaction
///       opened only after the rollback (MIG-02 AC3).
///
/// Never returns an error for a DDL failure — that is recorded as
/// TenantOutcome.failed, not raised. If the separate failure-recording
/// transaction itself also fails, the control row is left at whatever it
/// already was (`pending`, from the seed step) and this is logged, not
/// escalated (MIG-02 AC4) — escalating would abort the whole fanout over one
/// tenant's bookkeeping hiccup, defeating MIG-03's continue-on-failure
/// guarantee.
fn applyToTenant(
    allocator: std.mem.Allocator,
    pool: *Pool,
    request: FanoutRequest,
    tenant_id: []const u8,
    step: DdlStep,
) TenantOutcome {
    const conn = pool.acquire() catch {
        // No code path writes a tenant's control row on a connection other
        // than the one applying that tenant's DDL (MIG-02 AC5) — since no
        // connection could even be acquired, nothing was attempted, so the
        // row is left pending exactly as MIG-02 AC4 describes for a
        // bookkeeping failure. Logged so the gap is visible, not silent.
        logSwallowedFailure(allocator, "migration_fanout.acquire_failed", request, tenant_id, "PoolExhausted");
        return .failed;
    };
    defer pool.release(conn);

    var schema_buf: [80]u8 = undefined;
    const schema_name = pool_mod.schemaNameForTenant(tenant_id, &schema_buf);

    conn.exec("BEGIN", &.{}) catch {
        logSwallowedFailure(allocator, "migration_fanout.begin_failed", request, tenant_id, "QueryFailed");
        return .failed;
    };

    {
        var path_buf: [128]u8 = undefined;
        const set_path_sql = std.fmt.bufPrint(&path_buf, "SET LOCAL search_path TO {s},public", .{schema_name}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            recordFailureSeparately(allocator, pool, request, tenant_id, "search_path formatting failed");
            return .failed;
        };
        conn.exec(set_path_sql, &.{}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            recordFailureSeparately(allocator, pool, request, tenant_id, "SET LOCAL search_path failed");
            return .failed;
        };
    }

    step(conn, schema_name) catch |err| {
        // DDL step raised: roll back this tenant's transaction (neither
        // partial DDL nor a done row survives — MIG-02 AC2), THEN record the
        // failure in a separate transaction (MIG-02 AC3). The error text
        // recorded is @errorName(err) — the pool abstraction (src/db/pool.zig
        // Conn.exec/query) collapses every server-side error into
        // PoolError.QueryFailed/StaleConnection and does not thread the raw
        // PostgreSQL SQLSTATE through, so the error's Zig name is the richest
        // machine-readable signal available at this layer, consistent with
        // this codebase's established convention (see e.g.
        // src/effects/worker.zig, src/main.zig, which all use
        // @errorName(err) as the persisted/logged error text).
        conn.exec("ROLLBACK", &.{}) catch {};
        recordFailureSeparately(allocator, pool, request, tenant_id, @errorName(err));
        return .failed;
    };

    // Success path: write the 'done' row in the SAME transaction as the DDL
    // that just ran, then commit. A done row surviving is therefore proof
    // the DDL committed (MIG-02 AC1).
    markDone(conn, request, tenant_id) catch {
        conn.exec("ROLLBACK", &.{}) catch {};
        recordFailureSeparately(allocator, pool, request, tenant_id, "control row update failed");
        return .failed;
    };

    conn.exec("COMMIT", &.{}) catch {
        // COMMIT itself failing means the DDL did NOT durably commit either
        // (COMMIT is atomic — if it fails the whole transaction is rolled
        // back by Postgres), so this genuinely is a failure outcome, not a
        // false failed status on a real success.
        recordFailureSeparately(allocator, pool, request, tenant_id, "commit failed");
        return .failed;
    };

    return .done;
}

// ---------------------------------------------------------------------------
// SQL helpers
// ---------------------------------------------------------------------------

/// pg_try_advisory_lock(hashtext(migration_id)) — non-blocking. Returns true
/// if the lock was acquired, false if another session already holds it (the
/// caller maps false to error.MigrationAlreadyRunning / HTTP 409).
///
/// Two different migration_id values hash to two different lock keys, so
/// concurrent runs of DIFFERENT migrations never contend with each other
/// (MIG-03 AC3) — only same-migration_id runs serialize.
fn acquireMigrationLock(conn: *Conn, migration_id: []const u8) FanoutError!bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var result = conn.query(
        a,
        "SELECT pg_try_advisory_lock(hashtext($1))",
        &.{migration_id},
    ) catch return FanoutError.PoolExhausted;
    defer result.deinit();

    if (result.rows.len == 0 or result.rows[0].len == 0) return false;
    const raw = result.rows[0][0] orelse return false;
    return std.mem.eql(u8, raw, "t") or std.mem.eql(u8, raw, "true");
}

fn releaseMigrationLock(conn: *Conn, migration_id: []const u8) void {
    conn.exec(
        "SELECT pg_advisory_unlock(hashtext($1))",
        &.{migration_id},
    ) catch {};
}

/// Seed a 'pending' control row for (migration_id, tenant_id). Idempotent:
/// ON CONFLICT DO NOTHING leaves an already-existing row (from a prior run,
/// in any status) untouched, so re-running the seed step never regresses a
/// done/failed row back to pending.
fn seedPendingRow(conn: *Conn, request: FanoutRequest, tenant_id: []const u8) PoolError!void {
    try conn.exec(
        \\INSERT INTO platform.platform_migrations (migration_id, tenant_id, status, run_id)
        \\VALUES ($1, $2::uuid, 'pending', $3)
        \\ON CONFLICT (migration_id, tenant_id) DO NOTHING
    ,
        &.{ request.migration_id, tenant_id, request.run_id },
    );
}

/// Move the control row to 'done', setting completed_at and clearing
/// error_msg. Called inside the SAME transaction as the tenant's DDL step —
/// see applyToTenant.
fn markDone(conn: *Conn, request: FanoutRequest, tenant_id: []const u8) PoolError!void {
    try conn.exec(
        \\UPDATE platform.platform_migrations
        \\SET status = 'done', completed_at = now(), error_msg = NULL, run_id = $3
        \\WHERE migration_id = $1 AND tenant_id = $2::uuid
    ,
        &.{ request.migration_id, tenant_id, request.run_id },
    );
}

/// Record a tenant failure in a brand-new connection and transaction, opened
/// only AFTER the tenant's own DDL transaction has already rolled back
/// (MIG-02 AC3: "in their own transaction"). If this itself fails (e.g. the
/// platform DB briefly unreachable), the row is left exactly as the seed
/// step left it (pending) and the failure is logged, not escalated
/// (MIG-02 AC4) — see logSwallowedFailure.
fn recordFailureSeparately(
    allocator: std.mem.Allocator,
    pool: *Pool,
    request: FanoutRequest,
    tenant_id: []const u8,
    error_text: []const u8,
) void {
    const fail_conn = pool.acquire() catch {
        logSwallowedFailure(allocator, "migration_fanout.failure_record_acquire_failed", request, tenant_id, error_text);
        return;
    };
    defer pool.release(fail_conn);

    fail_conn.exec("BEGIN", &.{}) catch {
        logSwallowedFailure(allocator, "migration_fanout.failure_record_begin_failed", request, tenant_id, error_text);
        return;
    };

    fail_conn.exec(
        \\UPDATE platform.platform_migrations
        \\SET status = 'failed', error_msg = $3, run_id = $4
        \\WHERE migration_id = $1 AND tenant_id = $2::uuid
    ,
        &.{ request.migration_id, tenant_id, error_text, request.run_id },
    ) catch {
        fail_conn.exec("ROLLBACK", &.{}) catch {};
        logSwallowedFailure(allocator, "migration_fanout.failure_record_update_failed", request, tenant_id, error_text);
        return;
    };

    fail_conn.exec("COMMIT", &.{}) catch {
        logSwallowedFailure(allocator, "migration_fanout.failure_record_commit_failed", request, tenant_id, error_text);
        return;
    };
}

/// MIG-02 AC4: the failure-recording transaction itself failed. The control
/// row is left at whatever it already was (pending, from the seed step) —
/// this function only logs; it must never retry in a loop and must never
/// escalate into a runFanout-level error, since doing so would abort the
/// whole fanout over one tenant's bookkeeping hiccup, defeating MIG-03's
/// continue-on-failure guarantee.
fn logSwallowedFailure(
    allocator: std.mem.Allocator,
    component: []const u8,
    request: FanoutRequest,
    tenant_id: []const u8,
    detail: []const u8,
) void {
    const fields = [_]logger.LogField{
        .{ .key = "migration_id", .value = .{ .string = request.migration_id } },
        .{ .key = "run_id", .value = .{ .string = request.run_id } },
        .{ .key = "tenant_id", .value = .{ .string = tenant_id } },
        .{ .key = "detail", .value = .{ .string = detail } },
    };
    logger.log(allocator, .ERROR, component, "platform migration control row bookkeeping failed; row left pending for future resume", &fields) catch {};
}
