//! Scheduler timer persistence store — SCH-01
//!
//! Owns durable timer row insertion for timer-node arrivals.
//! Must be called inside an already-open transaction to satisfy DB-03 atomicity.
const std = @import("std");
const db = @import("../db/pool.zig");

pub const Uuid = [16]u8;

pub const CreateTimerArgs = struct {
    timer_id: Uuid,
    instance_id: Uuid,
    step_name: []const u8,
    duration_iso8601: []const u8,
    payload_json: []const u8,
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
        \\     status)
        \\VALUES
        \\    ($1::uuid, $2::uuid, NULL,
        \\     'scheduled_transition', $3,
        \\     NOW() + $4::interval,
        \\     'auto_transition', $5::jsonb,
        \\     'pending')
        \\ON CONFLICT (id) DO NOTHING
        \\RETURNING id
    ,
        &.{ timer_id_hex, instance_id_hex, args.step_name, args.duration_iso8601, args.payload_json },
    ) catch return TimerStoreError.QueryFailed;
    defer {
        var r = ins_rows;
        r.deinit();
    }

    if (ins_rows.rows.len == 0) return TimerStoreError.DuplicateTimerId;
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
