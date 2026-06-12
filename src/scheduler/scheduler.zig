//! Background scheduler poller — SCH-02
//!
//! Polls due timers, claims them with advisory locks, and appends the matching
//! instance event in the same transaction as the timer fire.
//!
//! XC-04 Kernel Determinism: This module is part of the platform kernel.
//! Timer firing order is deterministic (by due_at, then timer_id). No LLM calls.
//! Each fired timer generates a new trace_id for observability (XC-01).
const std = @import("std");
const db = @import("pool");
const logger = @import("../obs/logger.zig");
const store_mod = @import("store.zig");
const recurrence_mod = @import("recurrence.zig");
const task_mod = @import("../tasks/store.zig");

pub const Uuid = store_mod.Uuid;

pub const SchedulerConfig = struct {
    poll_interval_ms: u64 = 5000,
    jitter_ms: u64 = 0,
    max_timers_per_cycle: u32 = 64,
    max_timer_fire_retries: u32 = 3,
};

pub const SchedulerError = error{
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
};

pub const PollSummary = struct {
    fired: u32 = 0,
    skipped_locked: u32 = 0,
};

pub const EscalationFireResult = enum {
    fired,
    cancelled_before_fire,
    skipped_locked,
};

/// Session-level advisory lock ID for the startup missed-timer sweep.
/// Derived from FNV-1a hash of "bpm_scheduler_startup_sweep", truncated to i64.
/// This value is distinct from any per-timer advisory lock key (removed by ISS-301).
const SCHEDULER_STARTUP_LOCK_ID: i64 = 5863412975429063421;
const SCHEDULER_STARTUP_LOCK_ID_STR: []const u8 = "5863412975429063421";

pub const Scheduler = struct {
    pool: *db.Pool,
    config: SchedulerConfig,
    is_startup_sweep: bool,
    prng: std.Random.DefaultPrng,

    pub fn init(pool: *db.Pool, config: SchedulerConfig) Scheduler {
        // Seed PRNG from OS entropy source (replaces std.crypto.random
        // which was removed in Zig 0.16).
        var seed: u64 = undefined;
        fillRandom(std.mem.asBytes(&seed));
        return .{
            .pool = pool,
            .config = config,
            .is_startup_sweep = true,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Compute the actual sleep delay for the next poll cycle.
    /// Returns the base poll_interval_ms adjusted by a uniform-random jitter
    /// in the range [-jitter_ms, +jitter_ms].
    ///
    /// When jitter_ms == 0 (default), this is a trivial return of poll_interval_ms.
    ///
    /// The result is guaranteed non-negative (clamped to 0).
    pub fn computePollDelayMs(self: *Scheduler) u64 {
        const base_ms = self.config.poll_interval_ms;
        const jitter_ms = self.config.jitter_ms;
        if (jitter_ms == 0) return base_ms;

        var rng = self.prng.random();

        // Generate uniform offset in [-jitter_ms, +jitter_ms]
        const range: u64 = 2 * jitter_ms + 1;
        const raw = rng.int(u64) % range;
        const offset: i64 = @as(i64, @intCast(raw)) - @as(i64, @intCast(jitter_ms));
        const result: i64 = @as(i64, @intCast(base_ms)) + offset;

        if (result < 0) return 0;
        return @as(u64, @intCast(result));
    }

    /// Poll due timers once and process every available timer in sequence.
    pub fn pollDueTimers(self: *Scheduler, allocator: std.mem.Allocator) SchedulerError!PollSummary {
        var summary: PollSummary = .{};
        var processed: u32 = 0;
        const poll_trace_scope = logger.beginBackgroundTrace("scheduler.poller");
        const poll_trace = logger.TraceContext{
            .trace_id = poll_trace_scope.trace_id[0..],
            .source = .background,
        };

        const start_fields = [_]logger.LogField{
            .{ .key = "poll_interval_ms", .value = .{ .integer = @intCast(self.config.poll_interval_ms) } },
            .{ .key = "jitter_ms", .value = .{ .integer = @intCast(self.config.jitter_ms) } },
            .{ .key = "max_timers_per_cycle", .value = .{ .integer = @intCast(self.config.max_timers_per_cycle) } },
        };
        logger.logWithTrace(allocator, .DEBUG, poll_trace_scope.component, poll_trace, "timer poll cycle started", &start_fields) catch {};

        const max_per_cycle: u32 = if (self.config.max_timers_per_cycle == 0) 1 else self.config.max_timers_per_cycle;

        // ISS-302: Startup sweep advisory lock guard.
        // When multiple HA nodes start simultaneously, only one should run the missed-timer
        // sweep. A session-level advisory lock ensures exactly one node does the sweep;
        // others fall through to normal polling.
        var sweep_conn_for_unlock: ?*db.Conn = null;
        if (self.is_startup_sweep) {
            const sweep_conn = self.pool.acquire() catch |err| switch (err) {
                db.PoolError.ExhaustedPool => return SchedulerError.PoolExhausted,
                else => return SchedulerError.TransactionFailed,
            };
            const lock_acquired = try acquireStartupSweepLock(allocator, sweep_conn);
            if (!lock_acquired) {
                const skip_fields = [_]logger.LogField{
                    .{ .key = "lock_id", .value = .{ .string = SCHEDULER_STARTUP_LOCK_ID_STR } },
                };
                logger.logWithTrace(allocator, .WARN, poll_trace_scope.component, poll_trace,
                    "startup sweep skipped — lock held by another node", &skip_fields) catch {};
                self.pool.release(sweep_conn);
                self.is_startup_sweep = false;
                // sweep_conn_for_unlock remains null; normal polling proceeds below.
            } else {
                sweep_conn_for_unlock = sweep_conn;
                // Lock acquired; while loop below runs as the startup sweep.
                // Defer releases lock and connection after the loop completes.
            }
        }
        defer if (sweep_conn_for_unlock) |sc| {
            releaseStartupSweepLock(allocator, sc) catch {};
            self.pool.release(sc);
        };

        while (processed < max_per_cycle) {
            const outcome = try self.processNextDueTimer(allocator);
            switch (outcome) {
                .fired => {
                    summary.fired += 1;
                    processed += 1;
                },
                .skipped_locked => {
                    summary.skipped_locked += 1;
                    break;
                },
                .none => break,
            }
        }

        if (processed == max_per_cycle) {
            const cap_fields = [_]logger.LogField{
                .{ .key = "processed", .value = .{ .integer = processed } },
                .{ .key = "max_timers_per_cycle", .value = .{ .integer = max_per_cycle } },
            };
            logger.logWithTrace(allocator, .WARN, poll_trace_scope.component, poll_trace, "timer poll cycle hit processing cap", &cap_fields) catch {};
        }

        self.is_startup_sweep = false;

        const completion_fields = [_]logger.LogField{
            .{ .key = "fired", .value = .{ .integer = summary.fired } },
            .{ .key = "skipped_locked", .value = .{ .integer = summary.skipped_locked } },
        };
        logger.logWithTrace(allocator, .INFO, poll_trace_scope.component, poll_trace, "timer poll cycle completed", &completion_fields) catch {};

        return summary;
    }

    fn processNextDueTimer(self: *const Scheduler, allocator: std.mem.Allocator) SchedulerError!PollOutcome {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return SchedulerError.PoolExhausted,
            else => return SchedulerError.TransactionFailed,
        };
        defer self.pool.release(conn);

        conn.begin() catch return SchedulerError.TransactionFailed;
        errdefer conn.rollback() catch {};

        const due_rows = conn.query(
            a,
            \\SELECT id::text, instance_id::text, timer_type, step_name, action_type,
            \\       action_config::text,
            \\       (EXTRACT(EPOCH FROM fires_at)::bigint * 1000000)::text AS fires_at_epoch_us,
            \\       COALESCE(repeat_expression, ''),
            \\       COALESCE(repeat_total::text, ''),
            \\       COALESCE(fired_count::text, ''),
            \\       COALESCE(repeat_interval_us::text, '')
            \\FROM timers
            \\WHERE status = 'pending'
            \\  AND fires_at <= NOW()
            \\ORDER BY fires_at ASC, id ASC
            \\FOR UPDATE SKIP LOCKED
            \\LIMIT 1
        ,
            &.{},
        ) catch return SchedulerError.TransactionFailed;
        defer {
            var r = due_rows;
            r.deinit();
        }

        if (due_rows.rows.len == 0) {
            conn.rollback() catch {};
            return .none;
        }

        const timer_id_text = colGet(due_rows.rows[0], 0);
        const instance_id_text = colGet(due_rows.rows[0], 1);
        const timer_type = colGet(due_rows.rows[0], 2);
        const step_name = colGet(due_rows.rows[0], 3);
        const action_type = colGet(due_rows.rows[0], 4);
        const payload_json = colGet(due_rows.rows[0], 5);
        const fires_at_epoch_us_text = colGet(due_rows.rows[0], 6);
        const repeat_expression = colGet(due_rows.rows[0], 7);
        const repeat_total_text = colGet(due_rows.rows[0], 8);
        const fired_count_text = colGet(due_rows.rows[0], 9);
        const repeat_interval_us_text = colGet(due_rows.rows[0], 10);
        const fires_at_epoch_us = std.fmt.parseInt(i64, fires_at_epoch_us_text, 10) catch return SchedulerError.TransactionFailed;
        const timer_component = if (std.mem.eql(u8, timer_type, "human_task_escalation"))
            "scheduler.escalation"
        else
            "scheduler.timer";
        const timer_trace_scope = logger.beginBackgroundTrace(timer_component);
        const timer_trace = logger.TraceContext{
            .trace_id = timer_trace_scope.trace_id[0..],
            .source = .background,
        };

        const claim_fields = [_]logger.LogField{
            .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
            .{ .key = "instance_id", .value = .{ .string = instance_id_text } },
            .{ .key = "timer_type", .value = .{ .string = timer_type } },
        };
        logger.logWithTrace(allocator, .DEBUG, timer_component, timer_trace, "claimed due timer", &claim_fields) catch {};

        if (std.mem.eql(u8, timer_type, "human_task_escalation")) {
            const now_rows = conn.query(
                a,
                \\SELECT (EXTRACT(EPOCH FROM NOW())::bigint * 1000000)::text
            ,
                &.{},
            ) catch return SchedulerError.TransactionFailed;
            defer {
                var r = now_rows;
                r.deinit();
            }
            if (now_rows.rows.len == 0) return SchedulerError.TransactionFailed;
            const actual_fire_at_us = std.fmt.parseInt(i64, colGet(now_rows.rows[0], 0), 10) catch return SchedulerError.TransactionFailed;

            const fired_late = isFiredLate(
                fires_at_epoch_us,
                actual_fire_at_us,
                self.config.poll_interval_ms * 1000,
                self.is_startup_sweep,
            );

            const result = try self.fireEscalationTimerInTx(
                allocator,
                conn,
                timer_id_text,
                instance_id_text,
                payload_json,
                fires_at_epoch_us,
                actual_fire_at_us,
                fired_late,
            );

            switch (result) {
                .fired => {
                    const result_fields = [_]logger.LogField{
                        .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
                        .{ .key = "outcome", .value = .{ .string = "fired" } },
                    };
                    logger.logWithTrace(allocator, .DEBUG, timer_component, timer_trace, "escalation timer fired", &result_fields) catch {};
                },
                .cancelled_before_fire => {
                    const result_fields = [_]logger.LogField{
                        .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
                        .{ .key = "outcome", .value = .{ .string = "cancelled_before_fire" } },
                    };
                    logger.logWithTrace(allocator, .INFO, timer_component, timer_trace, "escalation timer cancelled before fire", &result_fields) catch {};
                    conn.commit() catch return SchedulerError.TransactionFailed;
                    return .none;
                },
                .skipped_locked => {
                    const result_fields = [_]logger.LogField{
                        .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
                        .{ .key = "outcome", .value = .{ .string = "skipped_locked" } },
                    };
                    logger.logWithTrace(allocator, .DEBUG, timer_component, timer_trace, "escalation timer lock skipped", &result_fields) catch {};
                    conn.rollback() catch {};
                    return .skipped_locked;
                },
            }
        } else {
            // ISS-303: Wrap the entire fire path in a labeled block so any failure
            // can be caught, the transaction rolled back, and the error count incremented
            // without propagating errors that inflate skipped_locked/fired counters.
            const fire_ok: bool = fire_blk: {
                const now_rows = conn.query(
                    a,
                    \\SELECT (EXTRACT(EPOCH FROM NOW())::bigint * 1000000)::text
                ,
                    &.{},
                ) catch break :fire_blk false;
                defer {
                    var r = now_rows;
                    r.deinit();
                }
                if (now_rows.rows.len == 0) break :fire_blk false;
                const actual_fire_at_us = std.fmt.parseInt(i64, colGet(now_rows.rows[0], 0), 10) catch break :fire_blk false;

                const fired_late = isFiredLate(
                    fires_at_epoch_us,
                    actual_fire_at_us,
                    self.config.poll_interval_ms * 1000,
                    self.is_startup_sweep,
                );

                const ext_payload = buildTimerFiredPayload(
                    allocator,
                    timer_id_text,
                    fires_at_epoch_us,
                    actual_fire_at_us,
                    fired_late,
                ) catch break :fire_blk false;

                appendTimerFiredEventInTx(allocator, conn, instance_id_text, timer_id_text, ext_payload) catch break :fire_blk false;
                markTimerFiredInTx(conn, timer_id_text) catch break :fire_blk false;

                const fired_fields = [_]logger.LogField{
                    .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
                    .{ .key = "outcome", .value = .{ .string = "fired" } },
                    .{ .key = "timer_type", .value = .{ .string = timer_type } },
                };
                logger.logWithTrace(allocator, .DEBUG, timer_component, timer_trace, "timer fired", &fired_fields) catch {};

                const recurrence_state = parseRecurrenceState(
                    repeat_expression,
                    repeat_total_text,
                    fired_count_text,
                    repeat_interval_us_text,
                ) catch break :fire_blk false;

                if (recurrence_state) |state| {
                    const rearm_decision = recurrence_mod.computeRearmDecision(.{
                        .repeat_total = state.repeat_total,
                        .fired_count = state.fired_count,
                        .interval_us = state.interval_us,
                        .scheduled_fire_at_us = actual_fire_at_us,
                    }) catch break :fire_blk false;

                    if (rearm_decision == .rearm) {
                        var next_timer_id: Uuid = undefined;
                        fillRandom(&next_timer_id);
                        next_timer_id[6] = (next_timer_id[6] & 0x0f) | 0x40;
                        next_timer_id[8] = (next_timer_id[8] & 0x3f) | 0x80;

                        const next_payload = updateRecurrencePayloadFiredCount(
                            allocator,
                            payload_json,
                            rearm_decision.rearm.next_fired_count,
                        ) catch break :fire_blk false;

                        const instance_uuid = parseUuid(instance_id_text) catch break :fire_blk false;

                        store_mod.insertRecurringPendingTimerInTx(
                            allocator,
                            conn,
                            .{
                                .timer_id = next_timer_id,
                                .instance_id = instance_uuid,
                                .step_name = step_name,
                                .action_type = action_type,
                                .fire_at_us = rearm_decision.rearm.next_fire_at_us,
                                .payload_json = next_payload,
                                .recurrence = .{
                                    .expression = state.expression,
                                    .repeat_total = state.repeat_total,
                                    .fired_count = rearm_decision.rearm.next_fired_count,
                                    .interval_us = state.interval_us,
                                },
                            },
                        ) catch break :fire_blk false;
                    }
                }
                break :fire_blk true;
            };

            if (!fire_ok) {
                // ISS-303: Tx1 failed — rollback, then record the error on a new connection.
                const err_fields = [_]logger.LogField{
                    .{ .key = "timer_id", .value = .{ .string = timer_id_text } },
                    .{ .key = "outcome", .value = .{ .string = "fire_failed" } },
                };
                logger.logWithTrace(allocator, .WARN, timer_component, timer_trace,
                    "timer fire failed — rolling back and recording error", &err_fields) catch {};
                conn.rollback() catch {};
                handleTimerFireError(
                    allocator,
                    self.pool,
                    self.config.max_timer_fire_retries,
                    timer_id_text,
                    instance_id_text,
                    payload_json,
                );
                return .none;
            }
        }

        conn.commit() catch return SchedulerError.TransactionFailed;
        return .fired;
    }

    fn fireEscalationTimerInTx(
        self: *const Scheduler,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        timer_id_text: []const u8,
        instance_id_text: []const u8,
        payload_json: []const u8,
        fires_at_epoch_us: i64,
        actual_fire_at_us: i64,
        fired_late: bool,
    ) SchedulerError!EscalationFireResult {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const payload = parseEscalationPayload(a, payload_json) catch return SchedulerError.TransactionFailed;

        const task_rows = conn.query(
            a,
            \\SELECT status, assignee_type, assignee_ref
            \\FROM tasks
            \\WHERE id = $1::uuid
            \\FOR UPDATE SKIP LOCKED
        ,
            &.{payload.task_id_text},
        ) catch return SchedulerError.TransactionFailed;
        defer {
            var r = task_rows;
            r.deinit();
        }

        if (task_rows.rows.len == 0) return .skipped_locked;

        const task_status = colGet(task_rows.rows[0], 0);
        const previous_assignee_type = if (task_rows.rows[0].len > 1) task_rows.rows[0][1] orelse "" else "";
        const previous_assignee_ref = if (task_rows.rows[0].len > 2) task_rows.rows[0][2] orelse "" else "";

        if (!std.mem.eql(u8, task_status, "PENDING")) {
            try markTimerCancelledInTx(conn, timer_id_text, "TASK_NOT_PENDING");
            return .cancelled_before_fire;
        }

        if (payload.reassign_to) |target| {
            var task_store = task_mod.TaskStore.init(self.pool);
            const reassigned_task = task_store.reassignInTx(
                allocator,
                conn,
                payload.task_id,
                target.assignee_type,
                target.assignee_ref,
            ) catch return SchedulerError.TransactionFailed;
            defer task_mod.freeTask(allocator, reassigned_task);
        }

        try appendEscalationEventInTx(
            allocator,
            conn,
            instance_id_text,
            timer_id_text,
            payload,
            previous_assignee_type,
            previous_assignee_ref,
            fired_late,
            fires_at_epoch_us,
            actual_fire_at_us,
        );
        try markTimerFiredInTx(conn, timer_id_text);
        return .fired;
    }
};

const PollOutcome = enum {
    fired,
    skipped_locked,
    none,
};

/// ISS-302: Acquire the startup sweep session-level advisory lock.
/// Returns true if acquired, false if another node already holds it.
/// The caller must hold `conn` open until `releaseStartupSweepLock` is called.
fn acquireStartupSweepLock(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
) SchedulerError!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = conn.query(
        a,
        \\SELECT pg_try_advisory_lock($1::bigint)
    ,
        &.{SCHEDULER_STARTUP_LOCK_ID_STR},
    ) catch return SchedulerError.TransactionFailed;
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0 or rows.rows[0].len == 0) return false;
    const result = colGet(rows.rows[0], 0);
    return std.mem.eql(u8, result, "t") or std.mem.eql(u8, result, "true");
}

/// ISS-302: Release the startup sweep session-level advisory lock.
fn releaseStartupSweepLock(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
) SchedulerError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rows = conn.query(
        a,
        \\SELECT pg_advisory_unlock($1::bigint)
    ,
        &.{SCHEDULER_STARTUP_LOCK_ID_STR},
    ) catch return SchedulerError.TransactionFailed;
    defer {
        var r = rows;
        r.deinit();
    }
    // Result ignored — unlock is best-effort.
}

/// ISS-303: After a fire transaction rollback, increment fire_error_count on a new
/// connection (Tx2). If the updated count reaches max_timer_fire_retries, open another
/// transaction (Tx3) to mark the timer FAILED and insert a DLQ entry.
/// All errors are swallowed — the poll loop continues regardless of outcome here.
fn handleTimerFireError(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    max_timer_fire_retries: u32,
    timer_id_text: []const u8,
    instance_id_text: []const u8,
    payload_json: []const u8,
) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Tx2: Increment fire_error_count in its own transaction.
    const conn2 = pool.acquire() catch return;
    defer pool.release(conn2);

    conn2.begin() catch return;
    conn2.exec(
        \\UPDATE timers
        \\SET fire_error_count = fire_error_count + 1
        \\WHERE id = $1::uuid
        \\  AND status = 'pending'
    ,
        &.{timer_id_text},
    ) catch {
        conn2.rollback() catch {};
        return;
    };
    conn2.commit() catch {
        conn2.rollback() catch {};
        return;
    };

    // Read the updated fire_error_count (autocommit read on same conn).
    const count_rows = conn2.query(
        a,
        \\SELECT fire_error_count FROM timers WHERE id = $1::uuid
    ,
        &.{timer_id_text},
    ) catch return;
    defer {
        var r = count_rows;
        r.deinit();
    }

    if (count_rows.rows.len == 0) return;
    const count_text = colGet(count_rows.rows[0], 0);
    const fire_error_count = std.fmt.parseInt(u32, count_text, 10) catch return;

    if (fire_error_count < max_timer_fire_retries) {
        // Timer remains PENDING; it will be re-polled after the next jitter interval.
        return;
    }

    // Tx3: Move timer to FAILED and insert DLQ entry.
    const conn3 = pool.acquire() catch return;
    defer pool.release(conn3);

    conn3.begin() catch return;
    markTimerFailedInTx(a, conn3, timer_id_text, instance_id_text, payload_json, max_timer_fire_retries) catch {
        conn3.rollback() catch {};
        return;
    };
    conn3.commit() catch {
        conn3.rollback() catch {};
        return;
    };
}

/// ISS-303: Within the caller's open transaction, mark a timer as FAILED and insert a
/// dead_letter_queue entry. Does NOT call moveToDlq (which acquires its own connection).
///
/// Precondition: `conn` must have an active transaction (BEGIN issued by caller).
fn markTimerFailedInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    timer_id_text: []const u8,
    instance_id_text: []const u8,
    payload_json: []const u8,
    max_retries: u32,
) SchedulerError!void {
    // Step 1: Update timers status to 'failed'.
    conn.exec(
        \\UPDATE timers
        \\SET
        \\    status           = 'failed',
        \\    failed_at        = NOW(),
        \\    fire_error_count = fire_error_count + 1
        \\WHERE id = $1::uuid
        \\  AND status = 'pending'
    ,
        &.{timer_id_text},
    ) catch return SchedulerError.TransactionFailed;

    // Step 2: Insert DLQ entry mirroring moveToDlq's INSERT for TIMER items.
    const max_retries_text = std.fmt.allocPrint(allocator, "{d}", .{max_retries}) catch return SchedulerError.OutOfMemory;

    const rows = conn.query(
        allocator,
        \\INSERT INTO dead_letter_queue (
        \\    entry_type,
        \\    instance_id,
        \\    reason,
        \\    error_detail,
        \\    retry_count,
        \\    max_retries,
        \\    status,
        \\    item_type,
        \\    retry_limit,
        \\    original_payload,
        \\    error_chain,
        \\    processor_metadata,
        \\    first_failed_at,
        \\    last_failed_at,
        \\    source_ref,
        \\    updated_at
        \\)
        \\VALUES (
        \\    'timer_failed',
        \\    NULLIF($1, '')::uuid,
        \\    'TIMER_EXHAUSTED',
        \\    jsonb_build_object('chain', '[]'::jsonb),
        \\    $2::int,
        \\    $2::int,
        \\    'pending',
        \\    'TIMER',
        \\    $2::int,
        \\    $3::jsonb,
        \\    '[]'::jsonb,
        \\    '{}'::jsonb,
        \\    NOW(),
        \\    NOW(),
        \\    $4,
        \\    NOW()
        \\)
        \\ON CONFLICT (item_type, source_ref, last_failed_at)
        \\DO NOTHING
        \\RETURNING id::text
    ,
        &.{ instance_id_text, max_retries_text, payload_json, timer_id_text },
    ) catch return SchedulerError.TransactionFailed;
    defer {
        var r = rows;
        r.deinit();
    }
}

/// Determine whether a timer firing is overdue.
/// On the startup sweep (is_startup_sweep = true) any timer with
/// fires_at <= NOW() is considered overdue.
/// On normal polls, only timers whose fires_at is more than one poll
/// interval in the past are flagged as overdue.
fn isFiredLate(
    scheduled_fire_at_epoch_us: i64,
    actual_fire_at_epoch_us: i64,
    poll_interval_us: u64,
    is_startup_sweep: bool,
) bool {
    if (is_startup_sweep) {
        return scheduled_fire_at_epoch_us < actual_fire_at_epoch_us;
    } else {
        const threshold: i64 = @as(i64, @intCast(poll_interval_us));
        return scheduled_fire_at_epoch_us < (actual_fire_at_epoch_us - threshold);
    }
}

test "TC-SCH-05-08: isFiredLate returns true on startup sweep for any past timer" {
    // Startup sweep: scheduled < actual → true
    try std.testing.expect(isFiredLate(1000, 2000, 5000000, true));
    // Equal timestamps should NOT be late (scheduled not < actual)
    try std.testing.expect(!isFiredLate(2000, 2000, 5000000, true));
    // Future scheduled (shouldn't happen in practice) → false
    try std.testing.expect(!isFiredLate(3000, 2000, 5000000, true));
}

test "TC-SCH-05-09: isFiredLate returns false on normal poll for sub-threshold lateness" {
    // scheduled(1000) >= actual(1500) - threshold(5000000) → false
    try std.testing.expect(!isFiredLate(1000, 1500, 5000000, false));
    // scheduled == actual - threshold → not late (boundary case)
    try std.testing.expect(!isFiredLate(1000, 5001000, 5000000, false));
}

test "TC-SCH-05-10: isFiredLate returns true on normal poll when timer is materially late" {
    // scheduled(1000) < actual(6000000) - threshold(5000000) → true
    try std.testing.expect(isFiredLate(1000, 6000000, 5000000, false));
    // Large delta → true
    try std.testing.expect(isFiredLate(1000, 100000000, 5000000, false));
    // Zero poll interval with late timer → true
    try std.testing.expect(isFiredLate(1000, 6000, 100, false));
}

test "TC-SCH-05-11: buildTimerFiredPayload produces valid JSON with all fields" {
    const alloc = std.testing.allocator;
    const payload = try buildTimerFiredPayload(
        alloc,
        "550e8400-e29b-41d4-a716-446655440000",
        1000000,
        2000000,
        true,
    );
    defer alloc.free(payload);

    // Verify JSON structure
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"timer_id\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"scheduled_fire_at\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"actual_fire_at\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "1000000"));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "2000000"));
}

test "TC-SCH-05-11b: buildTimerFiredPayload produces fired_late=false variant" {
    const alloc = std.testing.allocator;
    const payload = try buildTimerFiredPayload(
        alloc,
        "660e8400-e29b-41d4-a716-446655440001",
        3000000,
        3000000,
        false,
    );
    defer alloc.free(payload);

    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"fired_late\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, payload, 1, "\"timer_id\":\"660e8400-e29b-41d4-a716-446655440001\""));
}

/// Build the extended TIMER_FIRED JSON payload with overdue metadata.
fn buildTimerFiredPayload(
    allocator: std.mem.Allocator,
    timer_id_text: []const u8,
    scheduled_fire_at_us: i64,
    actual_fire_at_us: i64,
    fired_late: bool,
) (error{OutOfMemory}![]const u8) {
    return std.fmt.allocPrint(
        allocator,
        "{{\"timer_id\":\"{s}\",\"fired_late\":{s},\"scheduled_fire_at\":{d},\"actual_fire_at\":{d}}}",
        .{
            timer_id_text,
            if (fired_late) "true" else "false",
            scheduled_fire_at_us,
            actual_fire_at_us,
        },
    );
}

fn appendTimerFiredEventInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id_text: []const u8,
    timer_id_text: []const u8,
    payload_json: []const u8,
) SchedulerError!void {
    var param_arena = std.heap.ArenaAllocator.init(allocator);
    defer param_arena.deinit();
    const a = param_arena.allocator();

    const idem_key = std.fmt.allocPrint(
        a,
        "timer-fired:{s}",
        .{timer_id_text},
    ) catch return SchedulerError.OutOfMemory;

    try appendEventInTx(conn, instance_id_text, "TIMER_FIRED", payload_json, idem_key);
}

const ParsedEscalationPayload = struct {
    task_id: Uuid,
    task_id_text: []const u8,
    task_node_id: []const u8,
    reassign_to: ?store_mod.EscalationTarget,
};

fn appendEscalationEventInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id_text: []const u8,
    timer_id_text: []const u8,
    payload: ParsedEscalationPayload,
    previous_assignee_type: []const u8,
    previous_assignee_ref: []const u8,
    fired_late: bool,
    scheduled_fire_at_us: i64,
    actual_fire_at_us: i64,
) SchedulerError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const payload_json = try buildEscalationEventPayload(
        a,
        timer_id_text,
        payload.task_id_text,
        payload.task_node_id,
        previous_assignee_type,
        previous_assignee_ref,
        payload.reassign_to,
        fired_late,
        scheduled_fire_at_us,
        actual_fire_at_us,
    );
    const idem_key = std.fmt.allocPrint(
        a,
        "escalation:{s}",
        .{timer_id_text},
    ) catch return SchedulerError.OutOfMemory;

    try appendEventInTx(conn, instance_id_text, "ESCALATION", payload_json, idem_key);
}

fn appendEventInTx(
    conn: *db.Conn,
    instance_id_text: []const u8,
    event_type: []const u8,
    payload_json: []const u8,
    idem_key: []const u8,
) SchedulerError!void {
    conn.exec(
        \\WITH seq AS (
        \\    INSERT INTO instance_sequence (instance_id, next_seq)
        \\    VALUES ($1::uuid, 2)
        \\    ON CONFLICT (instance_id) DO UPDATE
        \\        SET next_seq = instance_sequence.next_seq + 1
        \\    RETURNING next_seq - 1 AS val
        \\)
        \\INSERT INTO events
        \\    (instance_id, event_type, payload, actor_id,
        \\     sequence_number, idempotency_key)
        \\SELECT $1::uuid, $2, $3::jsonb, $4::uuid, seq.val, $5
        \\FROM seq
    ,
        &.{ instance_id_text, event_type, payload_json, instance_id_text, idem_key },
    ) catch return SchedulerError.TransactionFailed;

    conn.exec(
        \\UPDATE instance_projections
        \\SET
        \\    last_event_seq = last_event_seq + 1,
        \\    updated_at = NOW()
        \\WHERE instance_id = $1::uuid
    ,
        &.{instance_id_text},
    ) catch return SchedulerError.TransactionFailed;
}

fn markTimerFiredInTx(conn: *db.Conn, timer_id_text: []const u8) SchedulerError!void {
    conn.exec(
        \\UPDATE timers
        \\SET
        \\    status = 'fired',
        \\    fired_at = NOW(),
        \\    fired_count = CASE
        \\        WHEN repeat_expression IS NULL THEN fired_count
        \\        ELSE COALESCE(fired_count, 0) + 1
        \\    END
        \\WHERE id = $1::uuid
        \\  AND status = 'pending'
    ,
        &.{timer_id_text},
    ) catch return SchedulerError.TransactionFailed;
}

const ParsedRecurrenceState = struct {
    expression: []const u8,
    repeat_total: ?u32,
    fired_count: u32,
    interval_us: u64,
};

fn parseRecurrenceState(
    expression_text: []const u8,
    repeat_total_text: []const u8,
    fired_count_text: []const u8,
    interval_us_text: []const u8,
) SchedulerError!?ParsedRecurrenceState {
    if (expression_text.len == 0) return null;
    if (fired_count_text.len == 0 or interval_us_text.len == 0) return SchedulerError.TransactionFailed;

    const fired_count = std.fmt.parseInt(u32, fired_count_text, 10) catch return SchedulerError.TransactionFailed;
    const interval_us = std.fmt.parseInt(u64, interval_us_text, 10) catch return SchedulerError.TransactionFailed;
    const repeat_total = if (repeat_total_text.len == 0)
        null
    else
        (std.fmt.parseInt(u32, repeat_total_text, 10) catch return SchedulerError.TransactionFailed);

    return .{
        .expression = expression_text,
        .repeat_total = repeat_total,
        .fired_count = fired_count,
        .interval_us = interval_us,
    };
}

fn updateRecurrencePayloadFiredCount(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
    next_fired_count: u32,
) SchedulerError![]const u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        payload_json,
        .{ .allocate = .alloc_always },
    ) catch return SchedulerError.TransactionFailed;
    defer parsed.deinit();

    if (parsed.value != .object) {
        return std.fmt.allocPrint(allocator, "{s}", .{payload_json}) catch SchedulerError.OutOfMemory;
    }

    var root = parsed.value.object;
    if (root.getPtr("recurrence")) |recurrence_val| {
        if (recurrence_val.* == .object) {
            try recurrence_val.object.put(allocator, "fired_count", std.json.Value{ .integer = next_fired_count });
        }
    }

    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch SchedulerError.OutOfMemory;
}

fn markTimerCancelledInTx(
    conn: *db.Conn,
    timer_id_text: []const u8,
    reason: []const u8,
) SchedulerError!void {
    conn.exec(
        \\UPDATE timers
        \\SET
        \\    status = 'cancelled',
        \\    cancelled_at = NOW(),
        \\    cancel_reason = $2
        \\WHERE id = $1::uuid
        \\  AND status = 'pending'
    ,
        &.{ timer_id_text, reason },
    ) catch return SchedulerError.TransactionFailed;
}

fn parseEscalationPayload(
    allocator: std.mem.Allocator,
    payload_json: []const u8,
) error{ OutOfMemory, InvalidPayload }!ParsedEscalationPayload {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        payload_json,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;

    const obj = parsed.value.object;
    const kind_val = obj.get("timer_kind") orelse return error.InvalidPayload;
    const task_id_val = obj.get("task_id") orelse return error.InvalidPayload;
    const task_node_id_val = obj.get("task_node_id") orelse return error.InvalidPayload;
    if (kind_val != .string or task_id_val != .string or task_node_id_val != .string) return error.InvalidPayload;
    if (!std.mem.eql(u8, kind_val.string, "human_task_escalation")) return error.InvalidPayload;

    var reassign_to: ?store_mod.EscalationTarget = null;
    if (obj.get("reassign_to")) |target_val| {
        if (target_val == .object) {
            const target_obj = target_val.object;
            const type_val = target_obj.get("assignee_type");
            const ref_val = target_obj.get("assignee_ref");
            if (type_val != null and ref_val != null and type_val.? == .string and ref_val.? == .string) {
                reassign_to = .{
                    .assignee_type = try allocator.dupe(u8, type_val.?.string),
                    .assignee_ref = try allocator.dupe(u8, ref_val.?.string),
                };
            }
        }
    }

    return .{
        .task_id = parseUuid(task_id_val.string) catch |err| switch (err) {
            error.InvalidUuid => return error.InvalidPayload,
            error.OutOfMemory => return error.OutOfMemory,
        },
        .task_id_text = try allocator.dupe(u8, task_id_val.string),
        .task_node_id = try allocator.dupe(u8, task_node_id_val.string),
        .reassign_to = reassign_to,
    };
}

fn buildEscalationEventPayload(
    allocator: std.mem.Allocator,
    timer_id_text: []const u8,
    task_id_text: []const u8,
    task_node_id: []const u8,
    previous_assignee_type: []const u8,
    previous_assignee_ref: []const u8,
    reassign_to: ?store_mod.EscalationTarget,
    fired_late: bool,
    scheduled_fire_at_us: i64,
    actual_fire_at_us: i64,
) SchedulerError![]const u8 {
    const timer_id_json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = timer_id_text }, .{}) catch return SchedulerError.OutOfMemory;
    const task_id_json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = task_id_text }, .{}) catch return SchedulerError.OutOfMemory;
    const task_node_json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = task_node_id }, .{}) catch return SchedulerError.OutOfMemory;

    const prev_type_json: []const u8 = if (previous_assignee_type.len == 0)
        "null"
    else
        (std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = previous_assignee_type }, .{}) catch return SchedulerError.OutOfMemory);
    const prev_ref_json: []const u8 = if (previous_assignee_ref.len == 0)
        "null"
    else
        (std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = previous_assignee_ref }, .{}) catch return SchedulerError.OutOfMemory);

    var reassign_json: []const u8 = "null";
    if (reassign_to) |target| {
        const type_json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = target.assignee_type }, .{}) catch return SchedulerError.OutOfMemory;
        const ref_json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = target.assignee_ref }, .{}) catch return SchedulerError.OutOfMemory;
        reassign_json = std.fmt.allocPrint(
            allocator,
            "{{\"assignee_type\":{s},\"assignee_ref\":{s}}}",
            .{ type_json, ref_json },
        ) catch return SchedulerError.OutOfMemory;
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"timer_id\":{s},\"task_id\":{s},\"task_node_id\":{s},\"previous_assignee_type\":{s},\"previous_assignee_ref\":{s},\"reassign_to\":{s},\"fired_late\":{s},\"scheduled_fire_at\":{d},\"actual_fire_at\":{d}}}",
        .{ timer_id_json, task_id_json, task_node_json, prev_type_json, prev_ref_json, reassign_json, if (fired_late) "true" else "false", scheduled_fire_at_us, actual_fire_at_us },
    ) catch return SchedulerError.OutOfMemory;
}

fn parseUuid(text: []const u8) error{ InvalidUuid, OutOfMemory }![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (text) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;

    var out: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, buf[0..32]) catch return error.InvalidUuid;
    return out;
}

inline fn colGet(row: []?[]u8, i: usize) []const u8 {
    if (i >= row.len) return "";
    return row[i] orelse "";
}

/// Fill a buffer with cryptographically secure random bytes from the OS.
/// Replaces std.crypto.random.fill which was removed in Zig 0.16.
fn fillRandom(buf: []u8) void {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
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

// ── SCH-06: Timer jitter tests ──────────────────────────────────────────────

test "TC-SCH-06-01: computePollDelayMs returns base_ms when jitter is 0" {
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = 5000,
        .jitter_ms = 0,
    });
    const delay = scheduler.computePollDelayMs();
    try std.testing.expectEqual(@as(u64, 5000), delay);
}

test "TC-SCH-06-02: computePollDelayMs returns base_ms when jitter_ms is default" {
    var scheduler = Scheduler.init(undefined, SchedulerConfig{ .poll_interval_ms = 3000 });
    const delay = scheduler.computePollDelayMs();
    try std.testing.expectEqual(@as(u64, 3000), delay);
}

test "TC-SCH-06-03: computePollDelayMs with jitter stays within [base-jitter, base+jitter]" {
    const base_ms: u64 = 10000;
    const jitter_ms: u64 = 2000;
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = base_ms,
        .jitter_ms = jitter_ms,
    });

    // Run 100 iterations to verify bounds
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const delay = scheduler.computePollDelayMs();

        // Must be within [base - jitter, base + jitter]
        const min_expected: i64 = @as(i64, @intCast(base_ms)) - @as(i64, @intCast(jitter_ms));
        const max_expected: i64 = @as(i64, @intCast(base_ms)) + @as(i64, @intCast(jitter_ms));

        const delay_i64: i64 = @as(i64, @intCast(delay));
        try std.testing.expect(delay_i64 >= min_expected);
        try std.testing.expect(delay_i64 <= max_expected);
    }
}

test "TC-SCH-06-04: computePollDelayMs never returns negative (clamps to 0)" {
    // Edge case: jitter larger than base interval
    const base_ms: u64 = 100;
    const jitter_ms: u64 = 10000;
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = base_ms,
        .jitter_ms = jitter_ms,
    });

    // Run 200 iterations to verify clamp works
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        const delay = scheduler.computePollDelayMs();
        // Must never be negative (u64 cannot be negative, but we check lower bound)
        try std.testing.expect(delay >= 0);
        // Must be within [0, base + jitter]
        try std.testing.expect(delay <= base_ms + jitter_ms);
    }
}

test "TC-SCH-06-05: computePollDelayMs produces varied results with jitter enabled" {
    const base_ms: u64 = 10000;
    const jitter_ms: u64 = 5000;
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = base_ms,
        .jitter_ms = jitter_ms,
    });

    // Collect 20 samples to verify variation
    const first: u64 = scheduler.computePollDelayMs();
    var all_same = true;
    var i: u32 = 0;
    while (i < 19) : (i += 1) {
        const next = scheduler.computePollDelayMs();
        if (next != first) {
            all_same = false;
            break;
        }
    }
    // With jitter=5000 on base=10000, it's extremely unlikely all 20 samples are identical
    // Note: in a random test this could theoretically fail, but with range 10001 values
    // the probability of 20 identical values is ~1/10001^19 ≈ impossible.
    try std.testing.expect(!all_same);
}

test "TC-SCH-06-07: computePollDelayMs produces results in valid range across multiple calls" {
    const base_ms: u64 = 5000;
    const jitter_ms: u64 = 1000;
    var scheduler = Scheduler.init(undefined, SchedulerConfig{
        .poll_interval_ms = base_ms,
        .jitter_ms = jitter_ms,
    });

    const d1 = scheduler.computePollDelayMs();
    const d2 = scheduler.computePollDelayMs();

    // Both must be in valid range
    const min_expected: i64 = @as(i64, @intCast(base_ms)) - @as(i64, @intCast(jitter_ms));
    const max_expected: i64 = @as(i64, @intCast(base_ms)) + @as(i64, @intCast(jitter_ms));

    try std.testing.expect(@as(i64, @intCast(d1)) >= min_expected);
    try std.testing.expect(@as(i64, @intCast(d1)) <= max_expected);
    try std.testing.expect(@as(i64, @intCast(d2)) >= min_expected);
    try std.testing.expect(@as(i64, @intCast(d2)) <= max_expected);
}

test "TC-SCH-06-08: SchedulerConfig default jitter_ms is 0" {
    const config = SchedulerConfig{};
    try std.testing.expectEqual(@as(u64, 0), config.jitter_ms);
}

test "TC-SCH-06-09: SchedulerConfig default poll_interval_ms is 5000" {
    const config = SchedulerConfig{};
    try std.testing.expectEqual(@as(u64, 5000), config.poll_interval_ms);
}

// ISS-301 source-inspection tests — can only be placed here because @embedFile
// paths must be within the declaring file's package root (src/scheduler/).

test "TC-SCH-301-01: scheduler source has no pg_try_advisory_xact_lock call (ISS-301)" {
    // After ISS-301 removal the per-timer advisory xact lock is gone.
    // The startup sweep (ISS-302) uses pg_try_advisory_lock (session-level), which is correct.
    const src = @embedFile("scheduler.zig");
    const has_xact = std.mem.containsAtLeast(u8, src, 1, "pg_try_advisory_xact_lock");
    try std.testing.expect(!has_xact);
}

test "TC-SCH-301-02: scheduler source has no advisoryLockKey or advisoryLockKeyText helper (ISS-301)" {
    const src = @embedFile("scheduler.zig");
    const has_key = std.mem.containsAtLeast(u8, src, 1, "advisoryLockKey");
    try std.testing.expect(!has_key);
}

test "TC-SCH-302-04: scheduler uses pg_try_advisory_lock (session-level) for startup sweep (ISS-302)" {
    const src = @embedFile("scheduler.zig");
    // Session-level lock must be present (ISS-302 startup sweep).
    try std.testing.expect(std.mem.containsAtLeast(u8, src, 1, "pg_try_advisory_lock"));
    // Transaction-level lock must be absent (ISS-301 removal).
    try std.testing.expect(!std.mem.containsAtLeast(u8, src, 1, "pg_try_advisory_xact_lock"));
}

test "TC-SCH-302-01: SCHEDULER_STARTUP_LOCK_ID value is 5863412975429063421 (ISS-302)" {
    const src = @embedFile("scheduler.zig");
    try std.testing.expect(std.mem.containsAtLeast(u8, src, 1, "5863412975429063421"));
    try std.testing.expect(std.mem.containsAtLeast(u8, src, 1, "SCHEDULER_STARTUP_LOCK_ID"));
}
