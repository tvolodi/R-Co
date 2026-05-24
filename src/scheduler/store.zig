//! Scheduler timer persistence store — SCH-01
//!
//! Owns durable timer row insertion for timer-node arrivals.
//! Must be called inside an already-open transaction to satisfy DB-03 atomicity.
const std = @import("std");
const db = @import("../db/pool.zig");
const recurrence_mod = @import("recurrence.zig");

pub const Uuid = [16]u8;

pub const CreateTimerArgs = struct {
    timer_id: Uuid,
    instance_id: Uuid,
    step_name: []const u8,
    duration_iso8601: []const u8,
    repeat_expression: ?[]const u8 = null,
    payload_json: []const u8,
};

pub const TimerRecurrenceState = struct {
    expression: []const u8,
    repeat_total: ?u32,
    fired_count: u32,
    interval_us: u64,
};

pub const CreateRecurringTimerArgs = struct {
    timer_id: Uuid,
    instance_id: Uuid,
    step_name: []const u8,
    action_type: []const u8,
    fire_at_us: i64,
    payload_json: []const u8,
    recurrence: TimerRecurrenceState,
};

pub const TimerKind = enum {
    scheduled_transition,
    human_task_escalation,
};

pub const EscalationTarget = struct {
    assignee_type: []const u8,
    assignee_ref: []const u8,
};

pub const CreateEscalationTimerArgs = struct {
    timer_id: Uuid,
    instance_id: Uuid,
    task_id: Uuid,
    task_node_id: []const u8,
    escalation_duration_iso8601: []const u8,
    task_created_at_utc: i64,
    reassign_to: ?EscalationTarget,
};

pub const TimerStoreError = error{
    InvalidInput,
    InstanceCancelled,
    InstanceNotFound,
    DuplicateTimerId,
    QueryFailed,
    OutOfMemory,
};

/// Insert a durable PENDING timer in the current transaction.
///
/// fire_at is derived at insert time as NOW() + duration_iso8601::interval,
/// which preserves the SCH-01 "due immediately" behavior for zero/negative values.
pub fn insertPendingTimerInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    args: CreateTimerArgs,
) TimerStoreError!void {
    if (args.step_name.len == 0 or args.duration_iso8601.len == 0 or args.payload_json.len == 0) {
        return TimerStoreError.InvalidInput;
    }

    // Validate payload contract up-front so SQL failures are mapped cleanly.
    {
        var payload_arena = std.heap.ArenaAllocator.init(allocator);
        defer payload_arena.deinit();

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            payload_arena.allocator(),
            args.payload_json,
            .{ .allocate = .alloc_always },
        ) catch return TimerStoreError.InvalidInput;
        defer parsed.deinit();

        if (parsed.value != .object) return TimerStoreError.InvalidInput;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const timer_id_hex = uuidToHex(a, args.timer_id) catch return TimerStoreError.OutOfMemory;
    const instance_id_hex = uuidToHex(a, args.instance_id) catch return TimerStoreError.OutOfMemory;

    var repeat_expression_text: []const u8 = "";
    var repeat_total_text: []const u8 = "";
    var repeat_interval_us_text: []const u8 = "";
    if (args.repeat_expression) |expr| {
        const spec = recurrence_mod.parseRepeatExpression(a, expr) catch |err| switch (err) {
            recurrence_mod.ParseRepeatError.InvalidFormat,
            recurrence_mod.ParseRepeatError.InvalidRepeatCount,
            recurrence_mod.ParseRepeatError.InvalidDuration,
            recurrence_mod.ParseRepeatError.ZeroInterval,
            => return TimerStoreError.InvalidInput,
            recurrence_mod.ParseRepeatError.Overflow,
            recurrence_mod.ParseRepeatError.OutOfMemory,
            => return TimerStoreError.OutOfMemory,
        };

        repeat_expression_text = spec.normalized;
        if (spec.repeat_total) |n| {
            repeat_total_text = std.fmt.allocPrint(a, "{}", .{n}) catch return TimerStoreError.OutOfMemory;
        }
        repeat_interval_us_text = std.fmt.allocPrint(a, "{}", .{spec.interval_us}) catch return TimerStoreError.OutOfMemory;
    }

    // Explicit guard: no timer creation for terminal CANCELLED instances.
    const lock_row = conn.queryRow(
        a,
        \\SELECT status
        \\FROM instance_projections
        \\WHERE instance_id = $1::uuid
        \\FOR UPDATE
    ,
        &.{instance_id_hex},
    ) catch return TimerStoreError.QueryFailed;

    if (lock_row == null) return TimerStoreError.InstanceNotFound;
    const status = colGet(lock_row.?, 0);
    if (std.mem.eql(u8, status, "CANCELLED")) return TimerStoreError.InstanceCancelled;

    // Keep lowercase DB status values to stay compatible with existing scheduler indexes.
    const ins_rows = conn.query(
        a,
        \\INSERT INTO timers
        \\    (id, instance_id, token_id,
        \\     timer_type, step_name,
        \\     fires_at,
        \\     action_type, action_config,
        \\     status,
        \\     repeat_expression, repeat_total, fired_count, repeat_interval_us)
        \\VALUES
        \\    ($1::uuid, $2::uuid, NULL,
        \\     'scheduled_transition', $3,
        \\     NOW() + $4::interval,
        \\     'auto_transition', $5::jsonb,
        \\     'pending',
        \\     NULLIF($6, ''), NULLIF($7, '')::integer,
        \\     CASE WHEN NULLIF($6, '') IS NULL THEN NULL ELSE 0 END,
        \\     NULLIF($8, '')::bigint)
        \\ON CONFLICT (id) DO NOTHING
        \\RETURNING id
    ,
        &.{
            timer_id_hex,
            instance_id_hex,
            args.step_name,
            args.duration_iso8601,
            args.payload_json,
            repeat_expression_text,
            repeat_total_text,
            repeat_interval_us_text,
        },
    ) catch return TimerStoreError.QueryFailed;
    defer {
        var r = ins_rows;
        r.deinit();
    }

    if (ins_rows.rows.len == 0) return TimerStoreError.DuplicateTimerId;
}

pub fn insertRecurringPendingTimerInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    args: CreateRecurringTimerArgs,
) TimerStoreError!void {
    if (args.step_name.len == 0 or args.action_type.len == 0 or args.payload_json.len == 0 or args.recurrence.expression.len == 0) {
        return TimerStoreError.InvalidInput;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const timer_id_hex = uuidToHex(a, args.timer_id) catch return TimerStoreError.OutOfMemory;
    const instance_id_hex = uuidToHex(a, args.instance_id) catch return TimerStoreError.OutOfMemory;
    const fire_at_us_text = std.fmt.allocPrint(a, "{}", .{args.fire_at_us}) catch return TimerStoreError.OutOfMemory;
    const repeat_interval_us_text = std.fmt.allocPrint(a, "{}", .{args.recurrence.interval_us}) catch return TimerStoreError.OutOfMemory;
    const fired_count_text = std.fmt.allocPrint(a, "{}", .{args.recurrence.fired_count}) catch return TimerStoreError.OutOfMemory;
    const repeat_total_text = if (args.recurrence.repeat_total) |n|
        std.fmt.allocPrint(a, "{}", .{n}) catch return TimerStoreError.OutOfMemory
    else
        "";

    const ins_rows = conn.query(
        a,
        \\INSERT INTO timers
        \\    (id, instance_id, token_id,
        \\     timer_type, step_name,
        \\     fires_at,
        \\     action_type, action_config,
        \\     status,
        \\     repeat_expression, repeat_total, fired_count, repeat_interval_us)
        \\VALUES
        \\    ($1::uuid, $2::uuid, NULL,
        \\     'scheduled_transition', $3,
        \\     to_timestamp($4::double precision / 1000000.0),
        \\     $5, $6::jsonb,
        \\     'pending',
        \\     $7, NULLIF($8, '')::integer, $9::integer, $10::bigint)
        \\ON CONFLICT (id) DO NOTHING
        \\RETURNING id
    ,
        &.{
            timer_id_hex,
            instance_id_hex,
            args.step_name,
            fire_at_us_text,
            args.action_type,
            args.payload_json,
            args.recurrence.expression,
            repeat_total_text,
            fired_count_text,
            repeat_interval_us_text,
        },
    ) catch return TimerStoreError.QueryFailed;
    defer {
        var r = ins_rows;
        r.deinit();
    }

    if (ins_rows.rows.len == 0) return TimerStoreError.DuplicateTimerId;
}

pub fn insertEscalationTimerInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    args: CreateEscalationTimerArgs,
) TimerStoreError!void {
    if (args.task_node_id.len == 0 or args.escalation_duration_iso8601.len == 0) {
        return TimerStoreError.InvalidInput;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const timer_id_hex = uuidToHex(a, args.timer_id) catch return TimerStoreError.OutOfMemory;
    const instance_id_hex = uuidToHex(a, args.instance_id) catch return TimerStoreError.OutOfMemory;
    const task_id_hex = uuidToHex(a, args.task_id) catch return TimerStoreError.OutOfMemory;
    const created_at_text = std.fmt.allocPrint(a, "{}", .{args.task_created_at_utc}) catch return TimerStoreError.OutOfMemory;
    const reassignee_type = if (args.reassign_to) |target| target.assignee_type else "";
    const reassignee_ref = if (args.reassign_to) |target| target.assignee_ref else "";

    const lock_row = conn.queryRow(
        a,
        \\SELECT status
        \\FROM instance_projections
        \\WHERE instance_id = $1::uuid
        \\FOR UPDATE
    ,
        &.{instance_id_hex},
    ) catch return TimerStoreError.QueryFailed;

    if (lock_row == null) return TimerStoreError.InstanceNotFound;
    const status = colGet(lock_row.?, 0);
    if (std.mem.eql(u8, status, "CANCELLED")) return TimerStoreError.InstanceCancelled;

    const ins_rows = conn.query(
        a,
        \\INSERT INTO timers
        \\    (id, instance_id, token_id,
        \\     timer_type, step_name,
        \\     fires_at,
        \\     action_type, action_config,
        \\     status)
        \\VALUES
        \\    ($1::uuid, $2::uuid, NULL,
        \\     'human_task_escalation', $3::text,
        \\     to_timestamp($4::double precision / 1000000.0) + $5::interval,
        \\     'append_escalation_event',
        \\     jsonb_strip_nulls(jsonb_build_object(
        \\         'schema_version', 1,
        \\         'timer_kind', 'human_task_escalation',
        \\         'source', 'EE-03',
        \\         'instance_id', $2::text,
        \\         'task_id', $6::text,
        \\         'task_node_id', $3::text,
        \\         'escalation_duration_iso8601', $9::text,
        \\         'task_created_at_utc', $4::bigint,
        \\         'due_at_utc', (EXTRACT(EPOCH FROM (to_timestamp($4::double precision / 1000000.0) + $5::interval)) * 1000000)::bigint,
        \\         'reassign_to', CASE
        \\             WHEN NULLIF($7::text, '') IS NOT NULL AND NULLIF($8::text, '') IS NOT NULL THEN jsonb_build_object(
        \\                 'assignee_type', NULLIF($7::text, ''),
        \\                 'assignee_ref', NULLIF($8::text, '')
        \\             )
        \\             ELSE NULL
        \\         END
        \\     )),
        \\     'pending')
        \\ON CONFLICT (id) DO NOTHING
        \\RETURNING id
    ,
        &.{
            timer_id_hex,
            instance_id_hex,
            args.task_node_id,
            created_at_text,
            args.escalation_duration_iso8601,
            task_id_hex,
            reassignee_type,
            reassignee_ref,
            args.escalation_duration_iso8601,
        },
    ) catch return TimerStoreError.QueryFailed;
    defer {
        var r = ins_rows;
        r.deinit();
    }

    if (ins_rows.rows.len == 0) return TimerStoreError.DuplicateTimerId;
}

pub fn cancelPendingEscalationTimersForTaskInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    task_id: Uuid,
) TimerStoreError!u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const task_id_hex = uuidToHex(a, task_id) catch return TimerStoreError.OutOfMemory;

    const rows = conn.query(
        allocator,
        \\UPDATE timers
        \\SET
        \\    status = 'cancelled',
        \\    cancelled_at = NOW(),
        \\    cancel_reason = 'TASK_COMPLETED'
        \\WHERE timer_type = 'human_task_escalation'
        \\  AND status = 'pending'
        \\  AND action_config ->> 'task_id' = $1
        \\RETURNING id
    ,
        &.{task_id_hex},
    ) catch return TimerStoreError.QueryFailed;
    defer {
        var r = rows;
        r.deinit();
    }

    return @as(u64, rows.rows.len);
}

inline fn colGet(row: []?[]u8, i: usize) []const u8 {
    if (i >= row.len) return "";
    return row[i] orelse "";
}

fn uuidToHex(allocator: std.mem.Allocator, uuid: Uuid) error{OutOfMemory}![]u8 {
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
