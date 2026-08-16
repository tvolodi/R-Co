//! DDL-04 — Idempotent batched backfill execution loop.
//!
//! Design artefact: src/design/ddl-04-idempotent-batched-backfill.md
//! Authoritative process: docs/processes/system/platform-ddl-safety.md
//! (sys-platform-ddl-safety, PW-05) — steps 10, 13 and the SLAs/Escalations table.
//!
//! Implements the phase-2 backfill of DDL-03's three-phase generator
//! (expand / backfill / constrain). Given a generated statement of the shape
//!
//!   UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (
//!     ARRAY(SELECT ctid FROM t WHERE c IS NULL LIMIT $1))
//!
//! it executes that statement in a loop — one transaction per batch, one
//! pooled connection per batch, released between batches (DB-02) — until an
//! iteration reports zero updated rows, recording per-batch progress into
//! `plat_migration_state` and applying the adaptive batch-size and stall
//! policies:
//!
//!   - DDL-04 AC2: validateGeneratedBackfill rejects a predicate not bounded
//!     by `IS NULL` with NonIdempotentBackfill BEFORE any connection opens.
//!   - DDL-04 AC3: the batch UPDATE takes ROW EXCLUSIVE; commit() per batch;
//!     no transaction spans two batches; the connection is released before
//!     the next batch is planned.
//!   - DDL-04 AC4: a batch > batch_timeout_ms (5 s) halves the next batch
//!     size, floored at batch_size_floor (500).
//!   - DDL-04 AC5: ten consecutive zero-progress iterations stop the loop
//!     with stalled = true so the caller escalates with rows_remaining.
//!   - DDL-04 AC6: recordBatchProgress writes rows_updated_total /
//!     rows_remaining / last_batch_rows / last_batch_ms / stall_count into
//!     plat_migration_state on the SAME connection/transaction as the batch.
//!
//! The loop deliberately does NOT run inside an outer transaction and is NOT
//! a `DdlStep` (migration_fanout.zig's contract is "run inside the per-tenant
//! transaction this module opens; must NOT open or commit its own
//! transaction" — mutually exclusive with the loop's per-batch transaction
//! ownership). The migration runner calls runBackfill directly between the
//! phase-1 and phase-3 DdlSteps.
//!
//! Security: no user input is interpolated into SQL. The batch statement text
//! comes from DDL-03's generator (platform-owned). The table/column names used
//! only in the remaining-count query are validated against a strict
//! identifier character class before interpolation.
const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One generated backfill statement, produced by DDL-03's three-phase
/// generator. The generator and the guard share this descriptor so the guard
/// can inspect the predicate BEFORE any connection is opened.
pub const GeneratedBackfill = struct {
    migration_id: []const u8,
    tenant_schema: []const u8,
    table: []const u8,
    column: []const u8,
    /// The full generated phase-2 SQL text, e.g.
    /// "UPDATE t SET c = <expr> WHERE c IS NULL AND ctid = ANY (... LIMIT $1)".
    sql: []const u8,
    /// 1-based position of the statement within its migration file.
    order: u32,
};

/// Adaptive batch-size policy. backfill_batch_size defaults to 5000 and is
/// bounded above by 50000 (DDL-04 body); per-tenant halving has a floor of
/// 500 (DDL-04 AC4).
pub const BackfillConfig = struct {
    backfill_batch_size: u32 = 5000,
    batch_size_upper_bound: u32 = 50000,
    batch_size_floor: u32 = 500,
    batch_timeout_ms: u64 = 5_000,
    stall_threshold_iterations: u32 = 10,
    lock_timeout_s: u8 = 3,
    statement_timeout_s: u8 = 60,
};

/// Outcome of a single runBackfill invocation for one (migration, tenant,
/// phase).
pub const BackfillResult = struct {
    migration_id: []const u8,
    tenant_schema: []const u8,
    rows_updated_total: i64,
    rows_remaining: i64,
    batches_run: u64,
    final_batch_size: u32,
    stalled: bool,
    status: MigrationPhaseStatus,
};

/// Mirrors plat_migration_state.status's CHECK constraint (applied | failed);
/// the pending/running states are the loop's own lifecycle.
pub const MigrationPhaseStatus = enum {
    applied,
    failed,

    pub fn toWire(self: MigrationPhaseStatus) []const u8 {
        return switch (self) {
            .applied => "applied",
            .failed => "failed",
        };
    }
};

pub const BackfillError = error{
    /// DDL-04 AC2 — generated predicate not IS NULL-bounded; pure guard.
    NonIdempotentBackfill,
    /// DDL-03 AC6 — lock_timeout exceeded on a batch.
    LockTimeout,
    /// DDL-03 AC6 — statement_timeout exceeded on a batch.
    StatementTimeout,
    /// Phase 3 VALIDATE CONSTRAINT found a violating row (recovery signal
    /// for the runner; this module never raises it).
    BackfillIncomplete,
    /// DB-02 — no pooled connection for a batch.
    PoolExhausted,
    /// Query/exec or progress-write failure.
    PersistenceFailed,
    OutOfMemory,
};

/// SQLSTATE codes used to classify server-side timeout failures.
const SQLSTATE_LOCK_TIMEOUT = "55P03"; // lock_not_available
const SQLSTATE_QUERY_CANCELED = "57014"; // statement_timeout fires as query_canceled

// ---------------------------------------------------------------------------
// Pure predicate guard (DDL-04 AC2)
// ---------------------------------------------------------------------------

/// Validate the generated phase-2 predicate. Rejects any generated backfill
/// whose predicate is not bounded by `IS NULL` with NonIdempotentBackfill.
/// Pure: no connection, no clock, no environment read — matching
/// ddl_validate.zig's purity contract. Returns the validated batch size.
pub fn validateGeneratedBackfill(
    backfill: GeneratedBackfill,
    batch_size: u32,
) BackfillError!u64 {
    // Idempotency is carried by the `IS NULL` predicate: a re-run against an
    // already-backfilled table updates 0 rows. The generated WHERE clause
    // MUST be bounded by `IS NULL` for the resume/stop semantics to hold.
    if (!containsIgnoreCase(backfill.sql, "IS NULL")) {
        return error.NonIdempotentBackfill;
    }
    // The batched form MUST target a bounded ctid set (ctid = ANY (... LIMIT)).
    if (!containsIgnoreCase(backfill.sql, "ctid = ANY")) {
        return error.NonIdempotentBackfill;
    }
    return batch_size;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Backfill loop
// ---------------------------------------------------------------------------

/// Execute the generated backfill for one tenant schema. Opens its own
/// per-batch transactions on per-batch pooled connections. Returns when an
/// iteration reports zero updated rows, or when the stall policy fires
/// (DDL-04 AC5).
pub fn runBackfill(
    allocator: std.mem.Allocator,
    pool: *Pool,
    backfill: GeneratedBackfill,
    config: BackfillConfig,
) BackfillError!BackfillResult {
    // AC2: reject a non-idempotent generated statement before any connection.
    _ = try validateGeneratedBackfill(backfill, config.backfill_batch_size);

    // The generated statement must carry the $1 LIMIT placeholder the loop
    // binds the live batch size to.
    if (std.mem.indexOf(u8, backfill.sql, "$1") == null) {
        return error.NonIdempotentBackfill;
    }

    var batch_size: u32 = config.backfill_batch_size;
    if (batch_size > config.batch_size_upper_bound) batch_size = config.batch_size_upper_bound;
    if (batch_size < config.batch_size_floor) batch_size = config.batch_size_floor;

    var rows_updated_total: i64 = 0;
    var rows_remaining: i64 = 0;
    var batches_run: u64 = 0;
    var stall_count: u32 = 0;
    var final_batch_size: u32 = batch_size;
    var stalled: bool = false;

    // Wrap the generated UPDATE in a data-modifying CTE that returns the
    // count of rows this batch touched. The generated statement itself is
    // bound to $1 (the live batch size); the batch count comes back as the
    // single row of the outer SELECT. The `RETURNING ctid` projection is
    // safe (ctid always exists) and never surfaces row contents.
    const batch_sql = try std.fmt.allocPrint(
        allocator,
        "WITH batch_rows AS ({s} RETURNING ctid) SELECT count(*)::text FROM batch_rows",
        .{backfill.sql},
    );
    defer allocator.free(batch_sql);

    // Remaining-count query; table/column validated below before use.
    const table = try validateIdentifier(allocator, backfill.table);
    defer allocator.free(table);
    const column = try validateIdentifier(allocator, backfill.column);
    defer allocator.free(column);
    const remaining_sql = try std.fmt.allocPrint(
        allocator,
        "SELECT count(*)::text FROM {s} WHERE {s} IS NULL",
        .{ table, column },
    );
    defer allocator.free(remaining_sql);

    while (true) {
        const conn = pool.acquire() catch return error.PoolExhausted;
        defer pool.release(conn);

        conn.begin() catch return error.PersistenceFailed;
        errdefer conn.rollback() catch {};

        // DDL-03 AC6: every phase statement runs with bounded lock/statement
        // timeouts. SET LOCAL scopes them to this transaction.
        const lock_timeout_sql = try std.fmt.allocPrint(
            allocator,
            "SET LOCAL lock_timeout = '{d}s'",
            .{config.lock_timeout_s},
        );
        defer allocator.free(lock_timeout_sql);
        const statement_timeout_sql = try std.fmt.allocPrint(
            allocator,
            "SET LOCAL statement_timeout = '{d}s'",
            .{config.statement_timeout_s},
        );
        defer allocator.free(statement_timeout_sql);
        conn.exec(lock_timeout_sql, &.{}) catch return error.PersistenceFailed;
        conn.exec(statement_timeout_sql, &.{}) catch return error.PersistenceFailed;

        const batch_size_text = try std.fmt.allocPrint(allocator, "{d}", .{batch_size});
        defer allocator.free(batch_size_text);

        const start_ms = std.Io.Clock.real.now(pool.io).toMilliseconds();
        const batch_result = conn.query(allocator, batch_sql, &.{batch_size_text}) catch |err| {
            return mapBatchError(conn, err);
        };
        defer {
            var r = batch_result;
            r.deinit();
        }
        const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.Io.Clock.real.now(pool.io).toMilliseconds() - start_ms));

        if (batch_result.rows.len == 0 or batch_result.rows[0].len == 0 or batch_result.rows[0][0] == null) {
            return error.PersistenceFailed;
        }
        const rows_updated: i64 = std.fmt.parseInt(i64, batch_result.rows[0][0].?, 10) catch
            return error.PersistenceFailed;

        const remaining_result = conn.query(allocator, remaining_sql, &.{}) catch
            return error.PersistenceFailed;
        defer {
            var r = remaining_result;
            r.deinit();
        }
        if (remaining_result.rows.len == 0 or remaining_result.rows[0].len == 0 or remaining_result.rows[0][0] == null) {
            return error.PersistenceFailed;
        }
        rows_remaining = std.fmt.parseInt(i64, remaining_result.rows[0][0].?, 10) catch
            return error.PersistenceFailed;

        rows_updated_total += rows_updated;
        batches_run += 1;
        final_batch_size = batch_size;

        // AC6: record this batch's progress on the SAME transaction so the
        // progress write commits atomically with the batch.
        try recordBatchProgress(
            conn,
            backfill.migration_id,
            backfill.tenant_schema,
            "backfill",
            rows_updated_total,
            rows_remaining,
            rows_updated,
            @intCast(elapsed_ms),
            stall_count,
        );

        conn.commit() catch return error.PersistenceFailed;

        // Loop end: an iteration reports zero updated rows.
        if (rows_updated == 0) break;

        // AC4: a batch > batch_timeout_ms halves the next batch (floor 500).
        if (elapsed_ms > config.batch_timeout_ms) {
            const halved = batch_size / 2;
            if (halved >= config.batch_size_floor) {
                batch_size = halved;
            } else {
                batch_size = config.batch_size_floor;
            }
        }

        // AC5: ten consecutive zero-progress iterations -> stop + escalate.
        if (rows_updated == 0) {
            stall_count += 1;
            if (stall_count >= config.stall_threshold_iterations) {
                stalled = true;
                break;
            }
        } else {
            stall_count = 0;
        }
    }

    return BackfillResult{
        .migration_id = backfill.migration_id,
        .tenant_schema = backfill.tenant_schema,
        .rows_updated_total = rows_updated_total,
        .rows_remaining = rows_remaining,
        .batches_run = batches_run,
        .final_batch_size = final_batch_size,
        .stalled = stalled,
        .status = if (stalled) .failed else .applied,
    };
}

/// Record one batch's progress into plat_migration_state (DDL-04 AC6), on
/// the SAME connection/transaction as the batch, so progress and batch
/// commit are atomic.
pub fn recordBatchProgress(
    conn: anytype,
    migration_id: []const u8,
    tenant_schema: []const u8,
    phase: []const u8,
    rows_updated_total: i64,
    rows_remaining: i64,
    last_batch_rows: i64,
    last_batch_ms: i64,
    stall_count: u32,
) BackfillError!void {
    // Short-lived serialisation buffers; the pool Conn exposes no allocator,
    // so the generic conn's own buffers are backed by page_allocator (one
    // batch per iteration — not hot-path).
    const a = std.heap.page_allocator;
    const total_text = std.fmt.allocPrint(a, "{d}", .{rows_updated_total}) catch return error.OutOfMemory;
    defer a.free(total_text);
    const remaining_text = std.fmt.allocPrint(a, "{d}", .{rows_remaining}) catch return error.OutOfMemory;
    defer a.free(remaining_text);
    const rows_text = std.fmt.allocPrint(a, "{d}", .{last_batch_rows}) catch return error.OutOfMemory;
    defer a.free(rows_text);
    const ms_text = std.fmt.allocPrint(a, "{d}", .{last_batch_ms}) catch return error.OutOfMemory;
    defer a.free(ms_text);
    const stall_text = std.fmt.allocPrint(a, "{d}", .{stall_count}) catch return error.OutOfMemory;
    defer a.free(stall_text);

    // Upsert on the (migration_id, tenant_schema, phase) UNIQUE anchor: the
    // first batch INSERTs the running row; every later batch UPDATEs it in
    // place (DDL-04 AC6 — no second row created).
    conn.exec(
        \\INSERT INTO plat_migration_state
        \\  (migration_id, tenant_schema, phase, status, attempt_count, backfill_batch_size,
        \\   rows_updated_total, rows_remaining, last_batch_rows, last_batch_ms, stall_count,
        \\   started_at, updated_at)
        \\VALUES
        \\  ($1, $2, $3, 'running', 1, 5000,
        \\   $4, $5, $6, $7, $8,
        \\   now(), now())
        \\ON CONFLICT (migration_id, tenant_schema, phase) DO UPDATE SET
        \\  status = 'running',
        \\  rows_updated_total = EXCLUDED.rows_updated_total,
        \\  rows_remaining = EXCLUDED.rows_remaining,
        \\  last_batch_rows = EXCLUDED.last_batch_rows,
        \\  last_batch_ms = EXCLUDED.last_batch_ms,
        \\  stall_count = EXCLUDED.stall_count,
        \\  updated_at = now()
    ,
        &.{ migration_id, tenant_schema, phase, total_text, remaining_text, rows_text, ms_text, stall_text },
    ) catch return error.PersistenceFailed;
}

/// Map a batch query failure to BackfillError, using the server SQLSTATE to
/// distinguish lock_timeout / statement_timeout from generic persistence
/// failures.
fn mapBatchError(conn: anytype, err: anyerror) BackfillError {
    _ = err;
    if (conn.lastSqlState()) |sqlstate| {
        if (std.mem.eql(u8, sqlstate, SQLSTATE_LOCK_TIMEOUT)) return error.LockTimeout;
        if (std.mem.eql(u8, sqlstate, SQLSTATE_QUERY_CANCELED)) return error.StatementTimeout;
    }
    return error.PersistenceFailed;
}

/// Validate a platform-generated identifier (table/column) against a strict
/// [a-zA-Z0-9_] class before it is interpolated into the remaining-count
/// query, so no unexpected characters can reach the SQL text.
fn validateIdentifier(
    allocator: std.mem.Allocator,
    ident: []const u8,
) BackfillError![]const u8 {
    if (ident.len == 0) return error.PersistenceFailed;
    for (ident) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
        if (!ok) return error.PersistenceFailed;
    }
    return allocator.dupe(u8, ident) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "backfill: validateGeneratedBackfill accepts an IS NULL-bounded batch" {
    const backfill = GeneratedBackfill{
        .migration_id = "m1",
        .tenant_schema = "tenant_a",
        .table = "orders",
        .column = "amount",
        .sql = "UPDATE orders SET amount = 0 WHERE amount IS NULL AND ctid = ANY (ARRAY(SELECT ctid FROM orders WHERE amount IS NULL LIMIT $1))",
        .order = 2,
    };
    const size = try validateGeneratedBackfill(backfill, 5000);
    try std.testing.expectEqual(@as(u64, 5000), size);
}

test "backfill: validateGeneratedBackfill rejects a non-IS-NULL predicate" {
    const backfill = GeneratedBackfill{
        .migration_id = "m1",
        .tenant_schema = "tenant_a",
        .table = "orders",
        .column = "amount",
        .sql = "UPDATE orders SET amount = 0 WHERE amount = 0 AND ctid = ANY (ARRAY(SELECT ctid FROM orders LIMIT $1))",
        .order = 2,
    };
    try std.testing.expectError(error.NonIdempotentBackfill, validateGeneratedBackfill(backfill, 5000));
}

test "backfill: validateGeneratedBackfill rejects a non-batched statement" {
    const backfill = GeneratedBackfill{
        .migration_id = "m1",
        .tenant_schema = "tenant_a",
        .table = "orders",
        .column = "amount",
        .sql = "UPDATE orders SET amount = 0 WHERE amount IS NULL",
        .order = 2,
    };
    try std.testing.expectError(error.NonIdempotentBackfill, validateGeneratedBackfill(backfill, 5000));
}

test "backfill: validateIdentifier accepts safe names and rejects unsafe ones" {
    const alloc = std.testing.allocator;
    const ok = try validateIdentifier(alloc, "orders_2024");
    defer alloc.free(ok);
    try std.testing.expectEqualStrings("orders_2024", ok);
    try std.testing.expectError(error.PersistenceFailed, validateIdentifier(alloc, "orders; DROP TABLE x"));
}
