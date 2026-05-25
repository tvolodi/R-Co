const std = @import("std");
const db = @import("../db/pool.zig");
const pagination = @import("../api/pagination.zig");

pub const DlqItemType = enum {
    SERVICE_TASK,
    WEBHOOK,
    TIMER,
};

pub const DlqStoreError = error{
    PoolExhausted,
    PersistenceFailed,
    InvalidCursor,
    CursorExpired,
    InvalidFilter,
    ItemNotFound,
    InstanceCancelled,
    OutOfMemory,
};

pub const MoveToDlqInput = struct {
    instance_id: ?[]const u8,
    item_type: DlqItemType,
    retry_count: u16,
    retry_limit: u16,
    original_payload_json: []const u8,
    error_chain_json: []const u8,
    processor_metadata_json: []const u8,
    first_failed_at: []const u8,
    last_failed_at: []const u8,
    source_ref: []const u8,
    reason: []const u8,
};

pub const DlqItem = struct {
    id: []u8,
    instance_id: ?[]u8,
    item_type: DlqItemType,
    retry_count: u16,
    retry_limit: u16,
    original_payload_json: []u8,
    error_chain_json: []u8,
    processor_metadata_json: []u8,
    first_failed_at: []u8,
    last_failed_at: []u8,
    created_at: []u8,
    created_at_us: i64,

    pub fn deinit(self: DlqItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.instance_id) |v| allocator.free(v);
        allocator.free(self.original_payload_json);
        allocator.free(self.error_chain_json);
        allocator.free(self.processor_metadata_json);
        allocator.free(self.first_failed_at);
        allocator.free(self.last_failed_at);
        allocator.free(self.created_at);
    }
};

pub const ListFilters = struct {
    cursor: ?[]const u8 = null,
    page_size: ?u16 = null,
    instance_id: ?[]const u8 = null,
    item_type: ?DlqItemType = null,
};

pub const ListResult = struct {
    items: []DlqItem,
    next_cursor: ?[]u8,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        if (self.next_cursor) |cursor| allocator.free(cursor);
    }
};

pub const RetryResult = struct {
    id: []u8,
    item_type: DlqItemType,

    pub fn deinit(self: RetryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

pub const DiscardResult = struct {
    id: []u8,

    pub fn deinit(self: DiscardResult, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

pub fn moveToDlq(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    input: MoveToDlqInput,
) DlqStoreError!void {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const item_type = itemTypeToString(input.item_type);
    const entry_type = entryTypeForItemType(input.item_type);
    const retry_count_text = std.fmt.allocPrint(allocator, "{d}", .{input.retry_count}) catch return error.OutOfMemory;
    defer allocator.free(retry_count_text);
    const retry_limit_text = std.fmt.allocPrint(allocator, "{d}", .{input.retry_limit}) catch return error.OutOfMemory;
    defer allocator.free(retry_limit_text);

    const instance_id = input.instance_id orelse "";
    const rows = conn.query(
        allocator,
        \\INSERT INTO dead_letter_queue (
        \\  entry_type,
        \\  instance_id,
        \\  reason,
        \\  error_detail,
        \\  retry_count,
        \\  max_retries,
        \\  status,
        \\  item_type,
        \\  retry_limit,
        \\  original_payload,
        \\  error_chain,
        \\  processor_metadata,
        \\  first_failed_at,
        \\  last_failed_at,
        \\  source_ref,
        \\  updated_at
        \\)
        \\VALUES (
        \\  $1,
        \\  NULLIF($2, '')::uuid,
        \\  $3,
        \\  CASE WHEN jsonb_typeof($4::jsonb) = 'array' THEN jsonb_build_object('chain', $4::jsonb) ELSE $4::jsonb END,
        \\  $5::int,
        \\  $6::int,
        \\  'pending',
        \\  $7,
        \\  $6::int,
        \\  $8::jsonb,
        \\  $4::jsonb,
        \\  $9::jsonb,
        \\  $10::timestamptz,
        \\  $11::timestamptz,
        \\  $12,
        \\  NOW()
        \\)
        \\ON CONFLICT (item_type, source_ref, last_failed_at)
        \\DO NOTHING
        \\RETURNING id::text
    ,
        &.{
            entry_type,
            instance_id,
            input.reason,
            input.error_chain_json,
            retry_count_text,
            retry_limit_text,
            item_type,
            input.original_payload_json,
            input.processor_metadata_json,
            input.first_failed_at,
            input.last_failed_at,
            input.source_ref,
        },
    ) catch return error.PersistenceFailed;
    defer {
        var r = rows;
        r.deinit();
    }
}

pub fn list(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    filters: ListFilters,
) DlqStoreError!ListResult {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const page_size = pagination.validatePageSize(filters.page_size) catch return error.InvalidFilter;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cursor_sort_us: ?i64 = null;
    var cursor_id: ?[]const u8 = null;
    var cursor_id_owned: ?[]u8 = null;
    defer if (cursor_id_owned) |owned| allocator.free(owned);
    if (filters.cursor) |cursor| {
        const decoded = pagination.decodeCursor(allocator, cursor, "DLQ:", 4, pagination.CURSOR_EXPIRY_US) catch |err| switch (err) {
            error.Expired => return error.CursorExpired,
            else => return error.InvalidCursor,
        };
        defer decoded.deinit();

        const tail = decoded.inner[4..];
        const c1 = std.mem.indexOfScalar(u8, tail, ':') orelse return error.InvalidCursor;
        const c2_abs = std.mem.indexOfScalarPos(u8, tail, c1 + 1, ':') orelse return error.InvalidCursor;
        cursor_sort_us = std.fmt.parseInt(i64, tail[c1 + 1 .. c2_abs], 10) catch return error.InvalidCursor;
        cursor_id_owned = allocator.dupe(u8, tail[c2_abs + 1 ..]) catch return error.OutOfMemory;
        cursor_id = cursor_id_owned;
        if (cursor_id.?.len == 0) return error.InvalidCursor;
    }

    var sql: std.ArrayList(u8) = .empty;
    var params: std.ArrayList([]const u8) = .empty;
    sql.appendSlice(a,
        \\SELECT
        \\  id::text,
        \\  instance_id::text,
        \\  item_type,
        \\  retry_count::text,
        \\  retry_limit::text,
        \\  original_payload::text,
        \\  error_chain::text,
        \\  processor_metadata::text,
        \\  to_char(first_failed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  to_char(last_failed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint::text
        \\FROM dead_letter_queue
        \\WHERE status IN ('pending', 'retrying')
    ) catch return error.OutOfMemory;

    var pidx: usize = 1;
    if (filters.instance_id) |instance_id| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND instance_id = ${d}::uuid", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, instance_id) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.item_type) |item_type| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND item_type = ${d}", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, itemTypeToString(item_type)) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (cursor_sort_us != null and cursor_id != null) {
        sql.appendSlice(a, std.fmt.allocPrint(
            a,
            "\nAND ((created_at < to_timestamp(${d}::double precision / 1000000.0)) OR ((created_at = to_timestamp(${d}::double precision / 1000000.0)) AND id::text < ${d}::text))",
            .{ pidx, pidx, pidx + 1 },
        ) catch return error.OutOfMemory) catch return error.OutOfMemory;

        const sort_us_param = std.fmt.allocPrint(a, "{d}", .{cursor_sort_us.?}) catch return error.OutOfMemory;
        params.append(a, sort_us_param) catch return error.OutOfMemory;
        params.append(a, cursor_id.?) catch return error.OutOfMemory;
        pidx += 2;
    }

    sql.appendSlice(a, std.fmt.allocPrint(a, "\nORDER BY created_at DESC, id DESC\nLIMIT ${d}", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
    const lim = std.fmt.allocPrint(a, "{d}", .{page_size + 1}) catch return error.OutOfMemory;
    params.append(a, lim) catch return error.OutOfMemory;

    var rows = conn.query(allocator, sql.items, params.items) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer rows.deinit();

    const has_next = rows.rows.len > page_size;
    const out_len = if (has_next) page_size else rows.rows.len;

    const items = allocator.alloc(DlqItem, out_len) catch return error.OutOfMemory;
    errdefer {
        for (items[0..out_len]) |item| item.deinit(allocator);
        allocator.free(items);
    }

    for (rows.rows[0..out_len], 0..) |row, idx| {
        const item_type = itemTypeFromString(row[2] orelse "") orelse return error.PersistenceFailed;
        const retry_count = std.fmt.parseInt(u16, row[3] orelse "0", 10) catch return error.PersistenceFailed;
        const retry_limit = std.fmt.parseInt(u16, row[4] orelse "0", 10) catch return error.PersistenceFailed;
        const created_at_us = std.fmt.parseInt(i64, row[11] orelse "0", 10) catch return error.PersistenceFailed;

        items[idx] = .{
            .id = allocator.dupe(u8, row[0] orelse "") catch return error.OutOfMemory,
            .instance_id = if (row[1]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .item_type = item_type,
            .retry_count = retry_count,
            .retry_limit = retry_limit,
            .original_payload_json = allocator.dupe(u8, row[5] orelse "{}") catch return error.OutOfMemory,
            .error_chain_json = allocator.dupe(u8, row[6] orelse "[]") catch return error.OutOfMemory,
            .processor_metadata_json = allocator.dupe(u8, row[7] orelse "{}") catch return error.OutOfMemory,
            .first_failed_at = allocator.dupe(u8, row[8] orelse "") catch return error.OutOfMemory,
            .last_failed_at = allocator.dupe(u8, row[9] orelse "") catch return error.OutOfMemory,
            .created_at = allocator.dupe(u8, row[10] orelse "") catch return error.OutOfMemory,
            .created_at_us = created_at_us,
        };
    }

    var next_cursor: ?[]u8 = null;
    if (has_next and out_len > 0) {
        const last = items[out_len - 1];
        const now_us = currentMicrosecondTimestamp();
        const raw = std.fmt.allocPrint(allocator, "DLQ:{d}:{d}:{s}", .{ now_us, last.created_at_us, last.id }) catch return error.OutOfMemory;
        defer allocator.free(raw);
        next_cursor = pagination.encodeCursor(allocator, raw) catch return error.OutOfMemory;
    }

    return .{ .items = items, .next_cursor = next_cursor };
}

pub fn retry(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    actor_id: []const u8,
    dlq_id: []const u8,
) DlqStoreError!RetryResult {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;
    errdefer conn.rollback() catch {};

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, instance_id::text, item_type
        \\FROM dead_letter_queue
        \\WHERE id = $1::uuid
        \\FOR UPDATE
    ,
        &.{dlq_id},
    ) catch return error.PersistenceFailed;

    if (row == null) {
        conn.rollback() catch {};
        return error.ItemNotFound;
    }

    const locked = row.?;
    defer {
        for (locked) |col| {
            if (col) |v| allocator.free(v);
        }
        allocator.free(locked);
    }

    const locked_id = locked[0] orelse return error.PersistenceFailed;
    const maybe_instance_id = locked[1];
    const item_type = itemTypeFromString(locked[2] orelse "") orelse return error.PersistenceFailed;

    if (maybe_instance_id) |instance_id| {
        const inst_row = conn.queryRow(
            allocator,
            \\SELECT status
            \\FROM instance_projections
            \\WHERE instance_id = $1::uuid
            \\FOR UPDATE
        ,
            &.{instance_id},
        ) catch return error.PersistenceFailed;

        if (inst_row) |r| {
            defer {
                for (r) |col| {
                    if (col) |v| allocator.free(v);
                }
                allocator.free(r);
            }

            const status = r[0] orelse "";
            if (std.mem.eql(u8, status, "CANCELLED")) {
                conn.exec("SELECT set_config('bpm.actor_id', $1, true)", &.{actor_id}) catch return error.PersistenceFailed;
                conn.exec("SELECT set_config('bpm.audit_action', 'dlq.discard', true)", &.{}) catch return error.PersistenceFailed;
                conn.exec("DELETE FROM dead_letter_queue WHERE id = $1::uuid", &.{locked_id}) catch return error.PersistenceFailed;
                conn.commit() catch return error.PersistenceFailed;
                return error.InstanceCancelled;
            }
        }
    }

    conn.exec(
        \\UPDATE dead_letter_queue
        \\SET retry_count = 0,
        \\    status = 'retrying',
        \\    last_retried_at = NOW(),
        \\    updated_at = NOW()
        \\WHERE id = $1::uuid
    ,
        &.{locked_id},
    ) catch return error.PersistenceFailed;

    conn.exec("SELECT set_config('bpm.actor_id', $1, true)", &.{actor_id}) catch return error.PersistenceFailed;
    conn.exec("SELECT set_config('bpm.audit_action', 'dlq.retry', true)", &.{}) catch return error.PersistenceFailed;
    conn.exec("DELETE FROM dead_letter_queue WHERE id = $1::uuid", &.{locked_id}) catch return error.PersistenceFailed;

    conn.commit() catch return error.PersistenceFailed;

    return .{
        .id = allocator.dupe(u8, locked_id) catch return error.OutOfMemory,
        .item_type = item_type,
    };
}

pub fn discard(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    actor_id: []const u8,
    dlq_id: []const u8,
    reason: ?[]const u8,
) DlqStoreError!DiscardResult {
    _ = reason;

    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;
    errdefer conn.rollback() catch {};

    conn.exec("SELECT set_config('bpm.actor_id', $1, true)", &.{actor_id}) catch return error.PersistenceFailed;
    conn.exec("SELECT set_config('bpm.audit_action', 'dlq.discard', true)", &.{}) catch return error.PersistenceFailed;

    const row = conn.query(
        allocator,
        \\DELETE FROM dead_letter_queue
        \\WHERE id = $1::uuid
        \\RETURNING id::text
    ,
        &.{dlq_id},
    ) catch return error.PersistenceFailed;
    defer {
        var r = row;
        r.deinit();
    }

    if (row.rows.len == 0) {
        conn.rollback() catch {};
        return error.ItemNotFound;
    }

    conn.commit() catch return error.PersistenceFailed;

    return .{
        .id = allocator.dupe(u8, row.rows[0][0] orelse "") catch return error.OutOfMemory,
    };
}

pub fn itemTypeToString(item_type: DlqItemType) []const u8 {
    return switch (item_type) {
        .SERVICE_TASK => "SERVICE_TASK",
        .WEBHOOK => "WEBHOOK",
        .TIMER => "TIMER",
    };
}

pub fn itemTypeFromString(raw: []const u8) ?DlqItemType {
    if (std.mem.eql(u8, raw, "SERVICE_TASK")) return .SERVICE_TASK;
    if (std.mem.eql(u8, raw, "WEBHOOK")) return .WEBHOOK;
    if (std.mem.eql(u8, raw, "TIMER")) return .TIMER;
    return null;
}

fn entryTypeForItemType(item_type: DlqItemType) []const u8 {
    return switch (item_type) {
        .SERVICE_TASK => "service_task_failed",
        .WEBHOOK => "webhook_failed",
        .TIMER => "timer_failed",
    };
}

fn currentMicrosecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    }
    const posix = std.posix;
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1_000_000 + @divTrunc(ts.nsec, 1000);
}
