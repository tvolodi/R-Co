const std = @import("std");
const db = @import("pool");
const pagination = @import("../api/pagination.zig");

pub const Uuid = [16]u8;
pub const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

pub const TimelineError = error{
    InstanceNotFound,
    InvalidCursor,
    CursorExpired,
    InvalidPageSize,
    EventStoreFailure,
    IdentityLookupFailure,
    RenderFailure,
    OutOfMemory,
};

pub const TimelineQuery = struct {
    instance_id: Uuid,
    after_sequence: ?i64,
    page_size: u16,
};

pub const TimelineEntry = struct {
    event_type: []const u8,
    timestamp: []const u8,
    actor_display_name: []const u8,
    description: []const u8,

    instance_id: Uuid,
    event_id: Uuid,
    sequence_num: i64,

    task_id: ?Uuid,
    node_id: ?[]const u8,
    metadata_json: []const u8,

    pub fn deinit(self: *const TimelineEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.timestamp);
        allocator.free(self.actor_display_name);
        allocator.free(self.description);
        if (self.node_id) |v| allocator.free(v);
        allocator.free(self.metadata_json);
    }
};

pub const TimelinePage = pagination.PageResponse(TimelineEntry);

const TimelineEvent = struct {
    event_id: Uuid,
    instance_id: Uuid,
    event_type: []const u8,
    payload_json: []const u8,
    metadata_json: []const u8,
    actor_id: ?Uuid,
    created_at_us: i64,
    sequence_num: i64,

    pub fn deinit(self: *const TimelineEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.payload_json);
        allocator.free(self.metadata_json);
    }
};

pub fn deinitPage(allocator: std.mem.Allocator, page: *const TimelinePage) void {
    for (page.items) |item| item.deinit(allocator);
    allocator.free(page.items);
    if (page.next_cursor) |c| allocator.free(c);
}

pub fn listTimeline(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    query: TimelineQuery,
) TimelineError!TimelinePage {
    const effective_page_size = pagination.validatePageSize(query.page_size) catch return TimelineError.InvalidPageSize;
    const conn = pool.acquire() catch return TimelineError.EventStoreFailure;
    defer pool.release(conn);

    var param_arena = std.heap.ArenaAllocator.init(allocator);
    defer param_arena.deinit();
    const pa = param_arena.allocator();

    const instance_hex = uuidToHex(pa, query.instance_id) catch return TimelineError.OutOfMemory;

    // Existence check only — the per-tenant schema (via the pool's search_path)
    // is the isolation boundary; instance_id is globally unique across tenants,
    // so no tenant_id predicate is needed (SPT-03).
    const instance_row = conn.queryRow(
        allocator,
        "SELECT 1 FROM instance_projections WHERE instance_id = $1 LIMIT 1",
        &.{instance_hex},
    ) catch return TimelineError.EventStoreFailure;
    if (instance_row == null) return TimelineError.InstanceNotFound;
    if (instance_row) |row| {
        defer {
            for (row) |col| if (col) |v| allocator.free(v);
            allocator.free(row);
        }
    }

    const after_seq_str: []const u8 = if (query.after_sequence) |v|
        std.fmt.allocPrint(pa, "{d}", .{v}) catch return TimelineError.OutOfMemory
    else
        "";

    const limit_plus_one: u16 = if (effective_page_size < std.math.maxInt(u16)) effective_page_size + 1 else effective_page_size;
    const limit_str = std.fmt.allocPrint(pa, "{d}", .{limit_plus_one}) catch return TimelineError.OutOfMemory;

    const rows = conn.query(
        allocator,
        \\SELECT
        \\  event_id::text,
        \\  instance_id::text,
        \\  event_type,
        \\  payload::text,
        \\  metadata::text,
        \\  actor_id::text,
        \\  created_at_us,
        \\  sequence_number
        \\FROM (
        \\  SELECT
        \\    event_id,
        \\    instance_id,
        \\    event_type,
        \\    payload,
        \\    metadata,
        \\    actor_id,
        \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
        \\    sequence_number
        \\  FROM events
        \\  WHERE instance_id = $1
        \\  UNION ALL
        \\  SELECT
        \\    event_id,
        \\    instance_id,
        \\    event_type,
        \\    payload,
        \\    metadata,
        \\    actor_id,
        \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
        \\    sequence_number
        \\  FROM events_archive
        \\  WHERE instance_id = $1
        \\) AS combined
        \\WHERE ($2::text = '' OR sequence_number > $2::bigint)
        \\ORDER BY created_at_us ASC, sequence_number ASC
        \\LIMIT $3
    ,
        &.{ instance_hex, after_seq_str, limit_str },
    ) catch return TimelineError.EventStoreFailure;
    defer {
        var mr = rows;
        mr.deinit();
    }

    const events = try rowsToTimelineEvents(allocator, rows.rows);
    defer {
        for (events) |ev| ev.deinit(allocator);
        allocator.free(events);
    }

    const has_next = events.len > @as(usize, effective_page_size);
    const page_events = if (has_next) events[0..effective_page_size] else events;

    const items = allocator.alloc(TimelineEntry, page_events.len) catch return TimelineError.OutOfMemory;
    errdefer {
        for (items, 0..) |entry, i| {
            if (i >= page_events.len) break;
            entry.deinit(allocator);
        }
        allocator.free(items);
    }

    for (page_events, 0..) |ev, i| {
        items[i] = try renderTimelineEntry(allocator, conn, ev);
    }

    const next_cursor: ?[]const u8 = if (has_next) blk: {
        const last = page_events[page_events.len - 1];
        const now_us = currentMicrosecondTimestamp();
        const seq_str = std.fmt.allocPrint(allocator, "{d}", .{last.sequence_num}) catch return TimelineError.OutOfMemory;
        defer allocator.free(seq_str);
        const raw = pagination.buildRawCursor(allocator, "TL:", now_us, seq_str) catch return TimelineError.OutOfMemory;
        defer allocator.free(raw);
        const encoded = pagination.encodeCursor(allocator, raw) catch return TimelineError.OutOfMemory;
        break :blk encoded;
    } else null;

    return TimelinePage{
        .items = items,
        .next_cursor = next_cursor,
        .count = page_events.len,
    };
}

fn rowsToTimelineEvents(allocator: std.mem.Allocator, rows: [][]?[]u8) TimelineError![]TimelineEvent {
    const out = allocator.alloc(TimelineEvent, rows.len) catch return TimelineError.OutOfMemory;
    errdefer allocator.free(out);

    for (rows, 0..) |row, i| {
        out[i] = rowToTimelineEvent(allocator, row) catch {
            for (out[0..i]) |ev| ev.deinit(allocator);
            allocator.free(out);
            return TimelineError.RenderFailure;
        };
    }
    return out;
}

fn rowToTimelineEvent(allocator: std.mem.Allocator, row: []?[]u8) TimelineError!TimelineEvent {
    if (row.len < 8) return TimelineError.RenderFailure;
    const event_id_text = row[0] orelse return TimelineError.RenderFailure;
    const instance_id_text = row[1] orelse return TimelineError.RenderFailure;
    const event_type = allocator.dupe(u8, row[2] orelse "UNKNOWN") catch return TimelineError.OutOfMemory;
    errdefer allocator.free(event_type);
    const payload_json = allocator.dupe(u8, row[3] orelse "{}") catch return TimelineError.OutOfMemory;
    errdefer allocator.free(payload_json);
    const metadata_json = allocator.dupe(u8, row[4] orelse "{}") catch return TimelineError.OutOfMemory;
    errdefer allocator.free(metadata_json);

    const actor_id = blk: {
        const raw = row[5] orelse break :blk null;
        break :blk parseUuid(raw) catch null;
    };

    const created_at_us = std.fmt.parseInt(i64, row[6] orelse "0", 10) catch 0;
    const sequence_num = std.fmt.parseInt(i64, row[7] orelse "0", 10) catch 0;

    return TimelineEvent{
        .event_id = parseUuid(event_id_text) catch return TimelineError.RenderFailure,
        .instance_id = parseUuid(instance_id_text) catch return TimelineError.RenderFailure,
        .event_type = event_type,
        .payload_json = payload_json,
        .metadata_json = metadata_json,
        .actor_id = actor_id,
        .created_at_us = created_at_us,
        .sequence_num = sequence_num,
    };
}

fn renderTimelineEntry(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    ev: TimelineEvent,
) TimelineError!TimelineEntry {
    const actor_display_name = try resolveActorDisplayName(allocator, conn, ev.actor_id, ev.metadata_json);
    errdefer allocator.free(actor_display_name);

    const ts = formatTimestamp(allocator, ev.created_at_us) catch return TimelineError.OutOfMemory;
    errdefer allocator.free(ts);

    const task_id = extractUuidContext(ev.metadata_json, ev.payload_json, "task_id");
    const node_id = try extractNodeId(allocator, ev.metadata_json, ev.payload_json);
    errdefer if (node_id) |v| allocator.free(v);

    const description = try renderDescription(
        allocator,
        ev.event_type,
        actor_display_name,
        task_id,
        node_id,
        ev.metadata_json,
        ev.payload_json,
    );
    errdefer allocator.free(description);

    const metadata_json = allocator.dupe(u8, normalizeObjectJson(ev.metadata_json)) catch return TimelineError.OutOfMemory;

    return TimelineEntry{
        .event_type = allocator.dupe(u8, ev.event_type) catch return TimelineError.OutOfMemory,
        .timestamp = ts,
        .actor_display_name = actor_display_name,
        .description = description,
        .instance_id = ev.instance_id,
        .event_id = ev.event_id,
        .sequence_num = ev.sequence_num,
        .task_id = task_id,
        .node_id = node_id,
        .metadata_json = metadata_json,
    };
}

fn resolveActorDisplayName(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    actor_id: ?Uuid,
    metadata_json: []const u8,
) TimelineError![]const u8 {
    if (actor_id) |aid| {
        const actor_hex = uuidToHex(allocator, aid) catch return TimelineError.OutOfMemory;
        defer allocator.free(actor_hex);
        const row = conn.queryRow(
            allocator,
             "SELECT display_name FROM users WHERE id = $1::uuid LIMIT 1",
            &.{actor_hex},
        ) catch return TimelineError.IdentityLookupFailure;
        if (row) |r| {
            defer freeRow(allocator, r);
            if (r.len > 0) {
                if (r[0]) |display_name| {
                    return allocator.dupe(u8, display_name) catch TimelineError.OutOfMemory;
                }
            }
        }
    }

    if (extractJsonStringField(allocator, metadata_json, "token_description") catch null) |token_desc| {
        return token_desc;
    }
    if (extractJsonStringField(allocator, metadata_json, "actor_label") catch null) |actor_label| {
        return actor_label;
    }
    return allocator.dupe(u8, "system") catch TimelineError.OutOfMemory;
}

fn renderDescription(
    allocator: std.mem.Allocator,
    event_type: []const u8,
    actor_display_name: []const u8,
    task_id: ?Uuid,
    node_id: ?[]const u8,
    metadata_json: []const u8,
    payload_json: []const u8,
) TimelineError![]const u8 {
    _ = task_id;

    if (std.mem.eql(u8, event_type, "INSTANCE_STARTED")) {
        return std.fmt.allocPrint(allocator, "Instance started by {s}", .{actor_display_name}) catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "INSTANCE_COMPLETED")) {
        return allocator.dupe(u8, "Instance completed") catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "INSTANCE_CANCELLED")) {
        return std.fmt.allocPrint(allocator, "Instance cancelled by {s}", .{actor_display_name}) catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "INSTANCE_ERROR")) {
        const summary = (extractJsonStringField(allocator, payload_json, "error_summary") catch null) orelse
            (extractJsonStringField(allocator, payload_json, "message") catch null) orelse
            "unknown error";
        defer if (!std.mem.eql(u8, summary, "unknown error")) allocator.free(summary);
        return std.fmt.allocPrint(allocator, "Instance entered ERROR: {s}", .{summary}) catch TimelineError.OutOfMemory;
    }

    const node_label = blk: {
        if (extractJsonStringField(allocator, metadata_json, "task_name") catch null) |task_name| break :blk task_name;
        if (extractJsonStringField(allocator, payload_json, "task_name") catch null) |task_name| break :blk task_name;
        if (node_id) |nid| break :blk nid;
        break :blk "task";
    };
    defer if (!std.mem.eql(u8, node_label, "task") and (node_id == null or !std.mem.eql(u8, node_label, node_id.?))) allocator.free(node_label);

    if (std.mem.eql(u8, event_type, "TASK_ACTIVATED")) {
        return std.fmt.allocPrint(allocator, "Task {s} activated", .{node_label}) catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "TASK_COMPLETED")) {
        return std.fmt.allocPrint(allocator, "Task {s} completed by {s}", .{ node_label, actor_display_name }) catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "TASK_CANCELLED")) {
        return std.fmt.allocPrint(allocator, "Task {s} cancelled", .{node_label}) catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "TIMER_CANCELLED")) {
        return std.fmt.allocPrint(allocator, "Timer for node {s} cancelled", .{node_label}) catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "SERVICE_TASK_ABANDONED")) {
        return allocator.dupe(u8, "Service task abandoned after cancellation") catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "EXECUTION_ERROR")) {
        const err_text = (extractJsonStringField(allocator, payload_json, "error_code") catch null) orelse
            (extractJsonStringField(allocator, payload_json, "message") catch null) orelse
            "unknown";
        defer if (!std.mem.eql(u8, err_text, "unknown")) allocator.free(err_text);
        return std.fmt.allocPrint(allocator, "Execution error at node {s}: {s}", .{ node_label, err_text }) catch TimelineError.OutOfMemory;
    }
    if (std.mem.eql(u8, event_type, "SERVICE_TASK_FAILED")) {
        const reason = (extractJsonStringField(allocator, payload_json, "failure_reason") catch null) orelse
            (extractJsonStringField(allocator, payload_json, "message") catch null) orelse
            "unknown";
        defer if (!std.mem.eql(u8, reason, "unknown")) allocator.free(reason);
        return std.fmt.allocPrint(allocator, "Service task failed at node {s}: {s}", .{ node_label, reason }) catch TimelineError.OutOfMemory;
    }

    return std.fmt.allocPrint(allocator, "Event {s} recorded", .{event_type}) catch TimelineError.OutOfMemory;
}

fn extractNodeId(
    allocator: std.mem.Allocator,
    metadata_json: []const u8,
    payload_json: []const u8,
) TimelineError!?[]const u8 {
    if (extractJsonStringField(allocator, metadata_json, "node_id") catch null) |nid| {
        return nid;
    }
    if (extractJsonStringField(allocator, payload_json, "node_id") catch null) |nid| {
        return nid;
    }
    return null;
}

fn extractUuidContext(metadata_json: []const u8, payload_json: []const u8, field: []const u8) ?Uuid {
    const allocator = std.heap.page_allocator;
    const from_meta = extractJsonStringField(allocator, metadata_json, field) catch null;
    if (from_meta) |v| {
        defer allocator.free(v);
        return parseUuid(v) catch null;
    }
    const from_payload = extractJsonStringField(allocator, payload_json, field) catch null;
    if (from_payload) |v| {
        defer allocator.free(v);
        return parseUuid(v) catch null;
    }
    return null;
}

fn extractJsonStringField(
    allocator: std.mem.Allocator,
    json_bytes: []const u8,
    field: []const u8,
) error{OutOfMemory}!?[]const u8 {
    const trimmed = std.mem.trimStart(u8, json_bytes, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return null;

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_bytes,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    };
}

fn normalizeObjectJson(json_bytes: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, json_bytes, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] != '{') return "{}";
    return json_bytes;
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| if (col) |v| allocator.free(v);
    allocator.free(row);
}

fn currentMicrosecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        const sec_us: i64 = ts.sec * 1_000_000;
        const nsec_us: i64 = @divTrunc(ts.nsec, 1000);
        return sec_us + nsec_us;
    }
}

fn formatTimestamp(allocator: std.mem.Allocator, us: i64) error{OutOfMemory}![]u8 {
    const abs_us: u64 = if (us < 0) 0 else @as(u64, @intCast(us));
    const total_secs: u64 = abs_us / 1_000_000;
    const sub_us: u64 = abs_us % 1_000_000;

    const secs_in_day: u64 = 86400;
    const days: u64 = total_secs / secs_in_day;
    const time_rem: u64 = total_secs % secs_in_day;
    const hour: u64 = time_rem / 3600;
    const minute: u64 = (time_rem % 3600) / 60;
    const second: u64 = time_rem % 60;

    const z: i64 = @as(i64, @intCast(days)) + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @as(u64, @intCast(z - era * 146097));
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    const yr: u64 = @as(u64, @intCast(y + @as(i64, if (m <= 2) 1 else 0)));

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z",
        .{ yr, m, d, hour, minute, second, sub_us },
    );
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

fn parseUuid(hex: []const u8) error{InvalidUuid}![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: [16]u8 = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        if (byte_idx >= 16) return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}
