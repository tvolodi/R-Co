//! Background scheduler poller — SCH-02
//!
//! Polls due timers, claims them with advisory locks, and appends the matching
//! instance event in the same transaction as the timer fire.
const std = @import("std");
const db = @import("../db/pool.zig");
const store_mod = @import("store.zig");
const task_mod = @import("../tasks/store.zig");

pub const Uuid = store_mod.Uuid;

pub const SchedulerConfig = struct {
    poll_interval_ms: u64 = 5000,
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

pub const Scheduler = struct {
    pool: *db.Pool,
    config: SchedulerConfig,

    pub fn init(pool: *db.Pool, config: SchedulerConfig) Scheduler {
        return .{ .pool = pool, .config = config };
    }

    /// Poll due timers once and process every available timer in sequence.
    pub fn pollDueTimers(self: *const Scheduler, allocator: std.mem.Allocator) SchedulerError!PollSummary {
        var summary: PollSummary = .{};

        while (true) {
            const outcome = try self.processNextDueTimer(allocator);
            switch (outcome) {
                .fired => summary.fired += 1,
                .skipped_locked => {
                    summary.skipped_locked += 1;
                    break;
                },
                .none => break,
            }
        }

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
            \\SELECT id::text, instance_id::text, timer_type, action_config::text
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
        const payload_json = colGet(due_rows.rows[0], 3);

        const lock_key = advisoryLockKeyText(timer_id_text) catch return SchedulerError.TransactionFailed;
        const lock_key_text = std.fmt.allocPrint(a, "{}", .{lock_key}) catch return SchedulerError.OutOfMemory;

        const lock_rows = conn.query(
            a,
            \\SELECT pg_try_advisory_xact_lock($1::bigint)
        ,
            &.{lock_key_text},
        ) catch return SchedulerError.TransactionFailed;
        defer {
            var r = lock_rows;
            r.deinit();
        }

        if (lock_rows.rows.len == 0 or lock_rows.rows[0].len == 0) {
            conn.rollback() catch {};
            return .skipped_locked;
        }

        const locked = colGet(lock_rows.rows[0], 0);
        if (!std.mem.eql(u8, locked, "t") and !std.mem.eql(u8, locked, "true")) {
            conn.rollback() catch {};
            return .skipped_locked;
        }

        if (std.mem.eql(u8, timer_type, "human_task_escalation")) {
            const result = try self.fireEscalationTimerInTx(
                allocator,
                conn,
                timer_id_text,
                instance_id_text,
                payload_json,
            );

            switch (result) {
                .fired => {},
                .cancelled_before_fire => {
                    conn.commit() catch return SchedulerError.TransactionFailed;
                    return .none;
                },
                .skipped_locked => {
                    conn.rollback() catch {};
                    return .skipped_locked;
                },
            }
        } else {
            try appendTimerFiredEventInTx(allocator, conn, instance_id_text, timer_id_text);
            try markTimerFiredInTx(conn, timer_id_text);
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

pub fn advisoryLockKey(uuid: Uuid) i64 {
    var key: u64 = 0;
    inline for (uuid[0..8]) |byte| {
        key = (key << 8) | @as(u64, byte);
    }
    return @bitCast(key);
}

fn advisoryLockKeyText(uuid_text: []const u8) error{ InvalidUuid, OutOfMemory }!i64 {
    const uuid = try parseUuid(uuid_text);
    return advisoryLockKey(uuid);
}

fn appendTimerFiredEventInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    instance_id_text: []const u8,
    timer_id_text: []const u8,
) SchedulerError!void {
    var param_arena = std.heap.ArenaAllocator.init(allocator);
    defer param_arena.deinit();
    const a = param_arena.allocator();

    const payload_json = std.fmt.allocPrint(
        a,
        "{{\"timer_id\":\"{s}\"}}",
        .{timer_id_text},
    ) catch return SchedulerError.OutOfMemory;

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
        \\    fired_at = NOW()
        \\WHERE id = $1::uuid
        \\  AND status = 'pending'
    ,
        &.{timer_id_text},
    ) catch return SchedulerError.TransactionFailed;
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
        "{{\"timer_id\":{s},\"task_id\":{s},\"task_node_id\":{s},\"previous_assignee_type\":{s},\"previous_assignee_ref\":{s},\"reassign_to\":{s}}}",
        .{ timer_id_json, task_id_json, task_node_json, prev_type_json, prev_ref_json, reassign_json },
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
