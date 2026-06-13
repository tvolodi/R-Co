//! Effects outbox queue — EXP-301
//!
//! Provides transactional outbox insert and re-entry functions.
//! All DB writes must occur inside an already-open transaction so they are
//! atomic with the EFFECT_EMITTED event row.
//!
//! Security: all values are bound as $N parameters — no SQL string interpolation.
const std = @import("std");
const db = @import("pool");
const mod = @import("mod.zig");

pub const EffectSpec = mod.EffectSpec;
pub const EffectQueueError = mod.EffectQueueError;
pub const EffectReentryError = mod.EffectReentryError;

// ---------------------------------------------------------------------------
// insertEffectInTx — called from event-store writer, inside a transaction
// ---------------------------------------------------------------------------

/// Insert one effects_outbox row for an EFFECT_EMITTED event.
/// MUST be called inside an already-open transaction on `conn`.
/// Returns the assigned effect_delivery_id UUID string (caller owns memory).
pub fn insertEffectInTx(
    allocator: std.mem.Allocator,
    conn: anytype,
    spec: EffectSpec,
) EffectQueueError![]const u8 {
    const kind_str = spec.kind.toWire();
    const rows = conn.query(
        allocator,
        \\INSERT INTO effects_outbox
        \\  (effect_event_id, instance_id, node_id, correlation_key,
        \\   kind, spec_json, status, attempt_count, max_attempts,
        \\   next_attempt_at, created_at, updated_at)
        \\VALUES
        \\  (NULLIF($1,'')::uuid, NULLIF($2,'')::uuid, $3, $4,
        \\   $5, $6::jsonb, 'pending', 0, 5,
        \\   NOW() + '5 seconds'::interval, NOW(), NOW())
        \\RETURNING effect_delivery_id::text
    ,
        &.{ spec.effect_event_id, spec.instance_id, spec.node_id, spec.correlation_key, kind_str, spec.spec_json },
    ) catch return error.PersistenceFailed;
    defer {
        var r = rows;
        r.deinit();
    }

    if (rows.rows.len == 0) return error.PersistenceFailed;
    const id_str = rows.rows[0][0] orelse return error.PersistenceFailed;
    return allocator.dupe(u8, id_str) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// markDelivered — called by effects worker on successful HTTP 2xx
// ---------------------------------------------------------------------------

/// Mark an effects_outbox row as delivered and record the final HTTP status.
pub fn markDelivered(
    allocator: std.mem.Allocator,
    conn: anytype,
    effect_delivery_id: []const u8,
    http_status: u16,
) EffectQueueError!void {
    const status_str = try std.fmt.allocPrint(allocator, "{d}", .{http_status});
    defer allocator.free(status_str);

    conn.exec(
        \\UPDATE effects_outbox
        \\SET status = 'delivered',
        \\    last_http_status = $2::smallint,
        \\    updated_at = NOW()
        \\WHERE effect_delivery_id = $1::uuid
    ,
        &.{ effect_delivery_id, status_str },
    ) catch return error.PersistenceFailed;
}

// ---------------------------------------------------------------------------
// markRetry — called by effects worker on retriable failure
// ---------------------------------------------------------------------------

/// Increment attempt_count and push next_attempt_at forward using the
/// pre-computed backoff interval string (e.g. "30 seconds").
pub fn markRetry(
    allocator: std.mem.Allocator,
    conn: anytype,
    effect_delivery_id: []const u8,
    http_status: u16,
    last_error: []const u8,
    backoff_ms: u32,
) EffectQueueError!void {
    const status_str = try std.fmt.allocPrint(allocator, "{d}", .{http_status});
    defer allocator.free(status_str);
    const backoff_str = try std.fmt.allocPrint(allocator, "{d} milliseconds", .{backoff_ms});
    defer allocator.free(backoff_str);

    conn.exec(
        \\UPDATE effects_outbox
        \\SET attempt_count    = attempt_count + 1,
        \\    next_attempt_at  = NOW() + $3::interval,
        \\    last_http_status = NULLIF($2,'')::smallint,
        \\    last_error       = $4,
        \\    updated_at       = NOW()
        \\WHERE effect_delivery_id = $1::uuid
    ,
        &.{ effect_delivery_id, status_str, backoff_str, last_error },
    ) catch return error.PersistenceFailed;
}

// ---------------------------------------------------------------------------
// markDeadLettered — called by effects worker on terminal failure
// ---------------------------------------------------------------------------

pub fn markDeadLettered(
    conn: anytype,
    effect_delivery_id: []const u8,
    last_error: []const u8,
) EffectQueueError!void {
    conn.exec(
        \\UPDATE effects_outbox
        \\SET status      = 'dead_lettered',
        \\    last_error  = $2,
        \\    updated_at  = NOW()
        \\WHERE effect_delivery_id = $1::uuid
    ,
        &.{ effect_delivery_id, last_error },
    ) catch return error.PersistenceFailed;
}

// ---------------------------------------------------------------------------
// fetchDueRows — called by effects worker sweep
// ---------------------------------------------------------------------------

pub const OutboxRow = struct {
    effect_delivery_id: []u8,
    correlation_key: []u8,
    kind_str: []u8,
    spec_json: []u8,
    attempt_count: u8,
    instance_id: []u8,
    node_id: []u8,
    effect_event_id: []u8,

    pub fn deinit(self: OutboxRow, allocator: std.mem.Allocator) void {
        allocator.free(self.effect_delivery_id);
        allocator.free(self.correlation_key);
        allocator.free(self.kind_str);
        allocator.free(self.spec_json);
        allocator.free(self.instance_id);
        allocator.free(self.node_id);
        allocator.free(self.effect_event_id);
    }
};

/// Fetch up to `limit` due effects_outbox rows using FOR UPDATE SKIP LOCKED.
/// Caller is responsible for calling deinit() on each returned row.
pub fn fetchDueRows(
    allocator: std.mem.Allocator,
    conn: anytype,
    limit: u32,
) EffectQueueError![]OutboxRow {
    const limit_str = std.fmt.allocPrint(allocator, "{d}", .{limit}) catch return error.OutOfMemory;
    defer allocator.free(limit_str);

    const rows = conn.query(
        allocator,
        \\SELECT
        \\  effect_delivery_id::text,
        \\  correlation_key,
        \\  kind,
        \\  spec_json::text,
        \\  attempt_count::text,
        \\  instance_id::text,
        \\  node_id,
        \\  effect_event_id::text
        \\FROM effects_outbox
        \\WHERE status = 'pending'
        \\  AND next_attempt_at <= NOW()
        \\ORDER BY next_attempt_at ASC
        \\LIMIT $1
        \\FOR UPDATE SKIP LOCKED
    ,
        &.{limit_str},
    ) catch return error.PersistenceFailed;
    defer {
        var r = rows;
        r.deinit();
    }

    var result = std.ArrayList(OutboxRow).empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }

    for (rows.rows) |row| {
        const id = allocator.dupe(u8, row[0] orelse continue) catch return error.OutOfMemory;
        const corr = allocator.dupe(u8, row[1] orelse "") catch { allocator.free(id); return error.OutOfMemory; };
        const kind = allocator.dupe(u8, row[2] orelse "http_call") catch { allocator.free(id); allocator.free(corr); return error.OutOfMemory; };
        const spec = allocator.dupe(u8, row[3] orelse "{}") catch { allocator.free(id); allocator.free(corr); allocator.free(kind); return error.OutOfMemory; };
        const attempt_str = row[4] orelse "0";
        const attempt: u8 = @intCast(std.fmt.parseInt(u8, attempt_str, 10) catch 0);
        const inst = allocator.dupe(u8, row[5] orelse "") catch { allocator.free(id); allocator.free(corr); allocator.free(kind); allocator.free(spec); return error.OutOfMemory; };
        const nid = allocator.dupe(u8, row[6] orelse "") catch { allocator.free(id); allocator.free(corr); allocator.free(kind); allocator.free(spec); allocator.free(inst); return error.OutOfMemory; };
        const eid = allocator.dupe(u8, row[7] orelse "") catch { allocator.free(id); allocator.free(corr); allocator.free(kind); allocator.free(spec); allocator.free(inst); allocator.free(nid); return error.OutOfMemory; };

        result.append(allocator, OutboxRow{
            .effect_delivery_id = id,
            .correlation_key = corr,
            .kind_str = kind,
            .spec_json = spec,
            .attempt_count = attempt,
            .instance_id = inst,
            .node_id = nid,
            .effect_event_id = eid,
        }) catch {
            allocator.free(id); allocator.free(corr); allocator.free(kind);
            allocator.free(spec); allocator.free(inst); allocator.free(nid); allocator.free(eid);
            return error.OutOfMemory;
        };
    }

    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}
