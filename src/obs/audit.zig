const std = @import("std");
const db = @import("pool");
const pagination = @import("../api/pagination.zig");

pub const AuditError = error{
    PoolExhausted,
    PersistenceFailed,
    InvalidCursor,
    CursorExpired,
    InvalidFilter,
    OutOfMemory,
};

pub const AuditEntry = struct {
    audit_id: []u8,
    actor_id: ?[]u8,
    action: []u8,
    resource_type: []u8,
    resource_id: []u8,
    pipeline_run_id: ?[]u8,
    timestamp: []u8,
    before_state: ?[]u8,
    after_state: ?[]u8,

    pub fn deinit(self: AuditEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.audit_id);
        if (self.actor_id) |v| allocator.free(v);
        allocator.free(self.action);
        allocator.free(self.resource_type);
        allocator.free(self.resource_id);
        if (self.pipeline_run_id) |v| allocator.free(v);
        allocator.free(self.timestamp);
        if (self.before_state) |v| allocator.free(v);
        if (self.after_state) |v| allocator.free(v);
    }
};

pub const ListFilters = struct {
    actor_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    pipeline_run_id: ?[]const u8 = null,
    from_ts: ?[]const u8 = null,
    to_ts: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    page_size: ?u16 = null,
};

pub const ListResult = struct {
    items: []AuditEntry,
    next_cursor: ?[]u8,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        if (self.next_cursor) |c| allocator.free(c);
    }
};

pub fn list(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    filters: ListFilters,
) AuditError!ListResult {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const page_size = pagination.validatePageSize(filters.page_size) catch return error.InvalidFilter;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sql: std.ArrayList(u8) = .empty;
    var params: std.ArrayList([]const u8) = .empty;

    sql.appendSlice(a,
        \\SELECT
        \\  audit_id::text,
        \\  actor_id::text,
        \\  action,
        \\  resource_type,
        \\  resource_id::text,
            \\  pipeline_run_id::text,
        \\  to_char("timestamp" AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  before_state::text,
        \\  after_state::text,
        \\  (EXTRACT(EPOCH FROM "timestamp") * 1000000)::bigint
        \\FROM audit_entries
        \\WHERE 1=1
        \\  AND tenant_id = bpm_effective_tenant_id()
    ) catch return error.OutOfMemory;

    var pidx: usize = 1;
    if (filters.actor_id) |actor| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND actor_id = ${d}::uuid", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, actor) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.resource_type) |rt| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND resource_type = ${d}", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, rt) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.resource_id) |rid| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND resource_id = ${d}::uuid", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, rid) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.pipeline_run_id) |pipeline_run_id| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND pipeline_run_id = ${d}::uuid", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, pipeline_run_id) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.from_ts) |from_ts| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND \"timestamp\" >= ${d}::timestamptz", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, from_ts) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.to_ts) |to_ts| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND \"timestamp\" <= ${d}::timestamptz", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, to_ts) catch return error.OutOfMemory;
        pidx += 1;
    }

    var cursor_ts_us: ?i64 = null;
    var cursor_audit_id: ?[]const u8 = null;
    if (filters.cursor) |cursor_str| {
        const decoded = pagination.decodeCursor(allocator, cursor_str, "A:", 2, pagination.CURSOR_EXPIRY_US) catch |err| switch (err) {
            error.Expired => return error.CursorExpired,
            else => return error.InvalidCursor,
        };
        defer decoded.deinit();

        const tail = decoded.inner[2..];
        const c1 = std.mem.indexOfScalar(u8, tail, ':') orelse return error.InvalidCursor;
        const c2_abs = std.mem.indexOfScalarPos(u8, tail, c1 + 1, ':') orelse return error.InvalidCursor;

        cursor_ts_us = std.fmt.parseInt(i64, tail[0..c1], 10) catch return error.InvalidCursor;
        cursor_audit_id = tail[c1 + 1 .. c2_abs];

        sql.appendSlice(a, std.fmt.allocPrint(
            a,
            "\nAND ((\"timestamp\" < to_timestamp(${d}::double precision / 1000000.0)) OR ((\"timestamp\" = to_timestamp(${d}::double precision / 1000000.0)) AND audit_id < ${d}::uuid))",
            .{ pidx, pidx, pidx + 1 },
        ) catch return error.OutOfMemory) catch return error.OutOfMemory;

        const ts_str = std.fmt.allocPrint(a, "{d}", .{cursor_ts_us.?}) catch return error.OutOfMemory;
        params.append(a, ts_str) catch return error.OutOfMemory;
        const audit_id_param = a.dupe(u8, cursor_audit_id.?) catch return error.OutOfMemory;
        params.append(a, audit_id_param) catch return error.OutOfMemory;
        pidx += 2;
    }

    sql.appendSlice(a, std.fmt.allocPrint(
        a,
        "\nORDER BY \"timestamp\" DESC, audit_id DESC\nLIMIT ${d}",
        .{pidx},
    ) catch return error.OutOfMemory) catch return error.OutOfMemory;
    const lim = std.fmt.allocPrint(a, "{d}", .{page_size + 1}) catch return error.OutOfMemory;
    params.append(a, lim) catch return error.OutOfMemory;

    var rows = conn.query(allocator, sql.items, params.items) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer rows.deinit();

    const has_next = rows.rows.len > page_size;
    const out_len = if (has_next) page_size else rows.rows.len;

    const items = allocator.alloc(AuditEntry, out_len) catch return error.OutOfMemory;
    errdefer {
        for (items[0..out_len]) |item| item.deinit(allocator);
        allocator.free(items);
    }

    for (rows.rows[0..out_len], 0..) |row, idx| {
        items[idx] = .{
            .audit_id = allocator.dupe(u8, row[0] orelse "") catch return error.OutOfMemory,
            .actor_id = if (row[1]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .action = allocator.dupe(u8, row[2] orelse "") catch return error.OutOfMemory,
            .resource_type = allocator.dupe(u8, row[3] orelse "") catch return error.OutOfMemory,
            .resource_id = allocator.dupe(u8, row[4] orelse "") catch return error.OutOfMemory,
            .pipeline_run_id = if (row[5]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .timestamp = allocator.dupe(u8, row[6] orelse "") catch return error.OutOfMemory,
            .before_state = if (row[7]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .after_state = if (row[8]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
        };
    }

    var next_cursor: ?[]u8 = null;
    if (has_next and out_len > 0) {
        const last = rows.rows[out_len - 1];
        const ts_us = std.fmt.parseInt(i64, last[9] orelse "0", 10) catch 0;
        const now_us = currentMicrosecondTimestamp();
        const raw = pagination.buildRawCursorTimestampKey(
            allocator,
            "A:",
            ts_us,
            last[0] orelse "",
            now_us,
        ) catch return error.OutOfMemory;
        defer allocator.free(raw);
        next_cursor = pagination.encodeCursor(allocator, raw) catch return error.OutOfMemory;
    }

    return .{ .items = items, .next_cursor = next_cursor };
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
