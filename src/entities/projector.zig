//! Entity record projector — EXP-202
//!
//! Replays entity events to produce record snapshots and rebuilds
//! the entity_record_latest projection table from the event store.
//!
//! Design artefact: src/design/entities.md (Projection section)

const std = @import("std");
const db = @import("pool");
const events_mod = @import("events.zig");
const entities_mod = @import("mod.zig");

const Pool = db.Pool;
const Uuid = entities_mod.Uuid;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const ProjectorError = error{
    PoolExhausted,
    InvalidPayload,
    ProjectionFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const RecordSnapshot = struct {
    entity_type: []const u8,
    entity_def_version: u32,
    field_values: []const u8,
    is_deleted: bool,
    updated_at: i64,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Replay a sequence of entity events and produce the final snapshot.
/// Events must be in chronological order (oldest first).
/// Returns null if no events are provided.
pub fn replayStream(
    allocator: std.mem.Allocator,
    payloads: []const []const u8,
) ProjectorError!?RecordSnapshot {
    if (payloads.len == 0) return null;

    var snapshot: ?RecordSnapshot = null;

    for (payloads) |payload_json| {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            payload_json,
            .{ .allocate = .alloc_always },
        ) catch return ProjectorError.InvalidPayload;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return ProjectorError.InvalidPayload;

        const entity_type = switch (root.object.get("entity_type") orelse return ProjectorError.InvalidPayload) {
            .string => |s| s,
            else => return ProjectorError.InvalidPayload,
        };
        const def_ver_val = root.object.get("entity_def_version") orelse return ProjectorError.InvalidPayload;
        const entity_def_version = switch (def_ver_val) {
            .integer => |v| @as(u32, @intCast(v)),
            else => return ProjectorError.InvalidPayload,
        };
        const field_values_raw = root.object.get("field_values") orelse return ProjectorError.InvalidPayload;
        const field_values = blk: {
            switch (field_values_raw) {
                .string => |s| break :blk s,
                else => {
                    // Re-serialise the object/array to a string
                    var buf = std.ArrayList(u8).init(allocator);
                    std.json.stringify(field_values_raw, .{}, buf.writer()) catch return ProjectorError.InvalidPayload;
                    break :blk buf.items;
                },
            }
        };

        // Determine if this is a delete event
        const is_delete = root.object.get("prior_field_values") != null;

        if (snapshot) |*snp| {
            allocator.free(snp.entity_type);
            allocator.free(snp.field_values);
        }

        snapshot = RecordSnapshot{
            .entity_type = try allocator.dupe(u8, entity_type),
            .entity_def_version = entity_def_version,
            .field_values = try allocator.dupe(u8, field_values),
            .is_deleted = is_delete,
            .updated_at = 0,
        };
    }

    return snapshot;
}

/// Rebuild the entity_record_latest projection for a specific entity type
/// by replaying all events from the event store.
pub fn rebuildProjection(
    allocator: std.mem.Allocator,
    pool: *Pool,
    entity_type: []const u8,
    tenant_id: []const u8,
) ProjectorError!void {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return ProjectorError.PoolExhausted,
        else => return ProjectorError.ProjectionFailed,
    };
    defer pool.release(conn);

    // Fetch all entity events for this type, ordered by event order
    const rows = conn.query(allocator,
        \\SELECT e.payload::text
        \\FROM events e
        \\JOIN event_type_registry etr ON e.event_type_id = etr.id
         \\WHERE e.tenant_id = (SELECT id FROM tenants WHERE external_id = $1 OR id = $1::uuid)
        \\  AND etr.name IN ('ENTITY_RECORD_CREATED', 'ENTITY_RECORD_UPDATED', 'ENTITY_RECORD_DELETED')
        \\  AND e.payload->>'entity_type' = $2
        \\ORDER BY e.created_at ASC
    , &.{
        .{ .text = tenant_id },
        .{ .text = entity_type },
    }) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return ProjectorError.PoolExhausted,
        else => return ProjectorError.ProjectionFailed,
    };
    defer {
        for (rows) |row| {
            for (row) |*col| if (col.*) |*v| allocator.free(v.*);
            allocator.free(row);
        }
        allocator.free(rows);
    }

    // Group events by record_id
    var record_events = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = record_events.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*.items) |p| allocator.free(p);
            entry.value_ptr.*.deinit();
            allocator.free(entry.key_ptr.*);
        }
        record_events.deinit();
    }

    for (rows) |row| {
        const payload_str = row[0] orelse continue;
        const payload = try allocator.dupe(u8, payload_str);

        var parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            payload,
            .{ .allocate = .alloc_always },
        ) catch continue;
        defer parsed.deinit();

        const record_id = switch (parsed.value.object.get("record_id") orelse {
            allocator.free(payload);
            continue;
        }) {
            .string => |s| s,
            else => {
                allocator.free(payload);
                continue;
            },
        };

        const key = try allocator.dupe(u8, record_id);
        const gop = try record_events.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList([]const u8).init(allocator);
        } else {
            allocator.free(key);
        }
        try gop.value_ptr.*.append(payload);
    }

    // Replay each record's events and upsert into entity_record_latest
    var evit = record_events.iterator();
    while (evit.next()) |entry| {
        const record_id = entry.key_ptr.*;
        const event_payloads = entry.value_ptr.*.items;

        const snapshot = replayStream(allocator, event_payloads) catch continue orelse continue;

        // Upsert into entity_record_latest
        conn.execute(
            \\INSERT INTO entity_record_latest (entity_type, entity_def_version, record_id, tenant_id, field_values, is_deleted, updated_at)
            \\VALUES ($1, $2, $3, $4, $5::jsonb, $6, NOW())
            \\ON CONFLICT (entity_type, record_id, tenant_id)
            \\DO UPDATE SET field_values = $5::jsonb, is_deleted = $6, entity_def_version = $2, updated_at = NOW()
        , &.{
            .{ .text = snapshot.entity_type },
            .{ .integer = @as(i64, @intCast(snapshot.entity_def_version)) },
            .{ .text = record_id },
            .{ .text = tenant_id },
            .{ .text = snapshot.field_values },
            .{ .boolean = snapshot.is_deleted },
        }) catch continue;

        allocator.free(snapshot.entity_type);
        allocator.free(snapshot.field_values);
    }
}
