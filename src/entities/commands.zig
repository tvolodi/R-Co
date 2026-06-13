//! Entity record commands — EXP-202
//!
//! Implements the event-sourced command path for entity records:
//! ENTITY_RECORD_CREATED, ENTITY_RECORD_UPDATED, ENTITY_RECORD_DELETED.
//! Validates payloads against entity definitions and updates the
//! entity_record_latest projection table atomically with the event append.
//!
//! Design artefact: src/design/entities.md

const std = @import("std");
const builtin = @import("builtin");
const db = @import("pool");
const entities_mod = @import("mod.zig");
const events_mod = @import("events.zig");
const definition_mod = @import("definition.zig");

// ── Internal Helpers (Zig 0.16.0 CSPRNG) ───────────────────────────────────

fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => {
            var prng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))));
            prng.random().bytes(buf);
        },
    }
}

const Uuid = entities_mod.Uuid;

pub const EntityCommandError = error{
    PoolExhausted,
    InvalidEntityType,
    InvalidRecord,
    InvalidPayload,
    TransactionFailed,
    IdempotencyKeyMissing,
    OutOfMemory,
};

pub const CreateRecordParams = struct {
    entity_type: []const u8,
    field_values: []const u8,
    idempotency_key: []const u8,
    actor_id: []const u8,
    tenant_id: []const u8,
};

pub const UpdateRecordParams = struct {
    entity_type: []const u8,
    record_id: []const u8,
    field_values: []const u8,
    idempotency_key: []const u8,
    actor_id: []const u8,
    tenant_id: []const u8,
};

pub const DeleteRecordParams = struct {
    entity_type: []const u8,
    record_id: []const u8,
    idempotency_key: []const u8,
    actor_id: []const u8,
    tenant_id: []const u8,
};

pub const RecordResult = struct {
    record_id: []const u8,
    entity_type: []const u8,
    field_values: []const u8,
    version_seq: i64,
    is_duplicate: bool,
};

pub fn createRecord(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    store: anytype,
    registry: anytype,
    params: CreateRecordParams,
) EntityCommandError!RecordResult {
    _ = registry;
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.TransactionFailed,
    };
    defer pool.release(conn);

    // EXP-202: Wrap in transaction to ensure metadata and projection consistency.
    conn.begin() catch return error.TransactionFailed;
    var success = false;
    defer if (!success) conn.rollback() catch {};

    // 1. Load active entity definition
    const def = definition_mod.getDefinitionByName(allocator, conn, params.tenant_id, params.entity_type) catch |err| switch (err) {
        error.DefinitionNotFound => return error.InvalidEntityType,
        else => return error.TransactionFailed,
    };
    var definition = def;
    defer definition.deinit(allocator);

    // 2. EXP-202: Add basic logical shape validation (required field presence)
    if (params.field_values.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, params.field_values, .{}) catch {
            return error.InvalidPayload;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        for (definition.fields) |field| {
            if (field.required) {
                if (!obj.contains(field.name)) {
                    return error.InvalidPayload;
                }
            }
        }
    }

    // 3. Get or create instance_id for this entity_type
    const def_uuid = entities_mod.parseUuid(definition.id) catch return error.TransactionFailed;
    const instance_id = getOrCreateEntityTypeInstance(conn, params.tenant_id, params.entity_type, def_uuid) catch return error.TransactionFailed;

    // 4. Build event payload
    const record_uuid = blk: {
        var bytes: [16]u8 = undefined;
        fillRandom(&bytes);
        break :blk bytes;
    };
    const record_id = entities_mod.formatUuid(allocator, record_uuid) catch return error.OutOfMemory;
    defer allocator.free(record_id);

    const payload = events_mod.buildCreatedPayload(
        allocator,
        params.entity_type,
        definition.logical_shape_version,
        record_id,
        params.field_values,
    ) catch return error.OutOfMemory;
    defer allocator.free(payload);

    // 5. Append event
    const actor_uuid = entities_mod.parseUuid(params.actor_id) catch return error.InvalidRecord;
    const append_res = store.append(allocator, .{
        .tenant_id = params.tenant_id,
        .instance_id = instance_id,
        .event_type = events_mod.EntityEventType.entity_record_created.wireName(),
        .payload = payload,
        .actor_id = actor_uuid,
        .idempotency_key = params.idempotency_key,
        .metadata = null,
    }) catch |err| switch (err) {
        error.PoolExhausted => return error.PoolExhausted,
        else => return error.TransactionFailed,
    };
    var append_res_mut = append_res;
    defer append_res_mut.record.deinit(allocator);

    if (append_res_mut.is_duplicate) {
        success = true;
        conn.commit() catch return error.TransactionFailed;

        // EXP-202: For idempotent duplicates, we must extract the original record_id
        // from the event payload since the one we generated for this attempt is wrong.
        if (append_res_mut.record.payload.len == 0) {
            return error.TransactionFailed;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, append_res_mut.record.payload, .{}) catch return error.TransactionFailed;
        defer parsed.deinit();
        const obj = parsed.value.object;
        const existing_id = obj.get("record_id") orelse return error.TransactionFailed;
        const existing_id_str = existing_id.string;
        std.debug.print("Duplicate record_id: {s}\n", .{existing_id_str});

        // Fetch existing record state for duplicate
        const result = fetchRecordResult(allocator, conn, params.entity_type, existing_id_str, params.tenant_id) catch |err| {
            if (err == error.InvalidRecord) {
                // EXP-202: Self-healing projection. If event exists but projection doesn't,
                // re-run projection update and try fetch again.
                std.debug.print("Duplicate found but projection missing. Healing... record_id: {s}\n", .{existing_id_str});
                try updateProjection(conn, params.tenant_id, params.entity_type, existing_id_str, params.field_values, false, definition.logical_shape_version, append_res_mut.record.sequence_number);
                return fetchRecordResult(allocator, conn, params.entity_type, existing_id_str, params.tenant_id);
            }
            return err;
        };
        return result;
    }

    // 6. Update entity_record_latest projection
    std.debug.print("Updating projection for record: {s}\n", .{record_id});
    try updateProjection(conn, params.tenant_id, params.entity_type, record_id, params.field_values, false, definition.logical_shape_version, append_res_mut.record.sequence_number);

    success = true;
    conn.commit() catch return error.TransactionFailed;

    const record_id_dupe = try allocator.dupe(u8, record_id);
    errdefer allocator.free(record_id_dupe);
    const entity_type_dupe = try allocator.dupe(u8, params.entity_type);
    errdefer allocator.free(entity_type_dupe);
    const field_values_dupe = try allocator.dupe(u8, params.field_values);
    errdefer allocator.free(field_values_dupe);

    return RecordResult{
        .record_id = record_id_dupe,
        .entity_type = entity_type_dupe,
        .field_values = field_values_dupe,
        .version_seq = append_res_mut.record.sequence_number,
        .is_duplicate = false,
    };
}

pub fn updateRecord(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    store: anytype,
    registry: anytype,
    params: UpdateRecordParams,
) EntityCommandError!RecordResult {
    _ = registry;
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.TransactionFailed,
    };
    defer pool.release(conn);

    // EXP-202: Wrap in transaction
    conn.begin() catch return error.TransactionFailed;
    var success = false;
    defer if (!success) conn.rollback() catch {};

    // Load active definition
    const def = definition_mod.getDefinitionByName(allocator, conn, params.tenant_id, params.entity_type) catch |err| switch (err) {
        error.DefinitionNotFound => return error.InvalidEntityType,
        else => return error.TransactionFailed,
    };
    var definition = def;
    defer definition.deinit(allocator);

    // Get instance_id
    const def_uuid = entities_mod.parseUuid(definition.id) catch return error.TransactionFailed;
    const instance_id = getOrCreateEntityTypeInstance(conn, params.tenant_id, params.entity_type, def_uuid) catch return error.TransactionFailed;

    // TODO: diff against current state to find changed_fields

    const payload = events_mod.buildUpdatedPayload(
        allocator,
        params.entity_type,
        definition.logical_shape_version,
        params.record_id,
        params.field_values,
        "[]", // changed_fields placeholder
    ) catch return error.OutOfMemory;
    defer allocator.free(payload);

    const actor_uuid = entities_mod.parseUuid(params.actor_id) catch return error.InvalidRecord;
    const append_res = store.append(allocator, .{
        .tenant_id = params.tenant_id,
        .instance_id = instance_id,
        .event_type = events_mod.EntityEventType.entity_record_updated.wireName(),
        .payload = payload,
        .actor_id = actor_uuid,
        .idempotency_key = params.idempotency_key,
        .metadata = null,
    }) catch |err| switch (err) {
        error.PoolExhausted => return error.PoolExhausted,
        else => return error.TransactionFailed,
    };
    var append_res_mut = append_res;
    defer append_res_mut.record.deinit(allocator);

    if (append_res_mut.is_duplicate) {
        success = true;
        conn.commit() catch return error.TransactionFailed;
        return fetchRecordResult(allocator, conn, params.entity_type, params.record_id, params.tenant_id);
    }

    updateProjection(conn, params.tenant_id, params.entity_type, params.record_id, params.field_values, false, definition.logical_shape_version, append_res_mut.record.sequence_number) catch return error.TransactionFailed;

    success = true;
    conn.commit() catch return error.TransactionFailed;

    const record_id_dupe = try allocator.dupe(u8, params.record_id);
    errdefer allocator.free(record_id_dupe);
    const entity_type_dupe = try allocator.dupe(u8, params.entity_type);
    errdefer allocator.free(entity_type_dupe);
    const field_values_dupe = try allocator.dupe(u8, params.field_values);
    errdefer allocator.free(field_values_dupe);

    return RecordResult{
        .record_id = record_id_dupe,
        .entity_type = entity_type_dupe,
        .field_values = field_values_dupe,
        .version_seq = append_res_mut.record.sequence_number,
        .is_duplicate = false,
    };
}

pub fn deleteRecord(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    store: anytype,
    registry: anytype,
    params: DeleteRecordParams,
) EntityCommandError!RecordResult {
    _ = registry;
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.TransactionFailed,
    };
    defer pool.release(conn);

    // EXP-202: Wrap in transaction
    conn.begin() catch return error.TransactionFailed;
    var success = false;
    defer if (!success) conn.rollback() catch {};

    // Load active definition
    const def = definition_mod.getDefinitionByName(allocator, conn, params.tenant_id, params.entity_type) catch |err| switch (err) {
        error.DefinitionNotFound => return error.InvalidEntityType,
        else => return error.TransactionFailed,
    };
    var definition = def;
    defer definition.deinit(allocator);

    const def_uuid = entities_mod.parseUuid(definition.id) catch return error.TransactionFailed;
    const instance_id = getOrCreateEntityTypeInstance(conn, params.tenant_id, params.entity_type, def_uuid) catch return error.TransactionFailed;

    // Fetch current state for deletion payload
    const current = fetchRecordResult(allocator, conn, params.entity_type, params.record_id, params.tenant_id) catch |err| switch (err) {
        error.InvalidRecord => return error.InvalidRecord,
        else => return error.TransactionFailed,
    };
    const current_state = current;
    defer allocator.free(current_state.record_id);
    defer allocator.free(current_state.entity_type);
    defer allocator.free(current_state.field_values);

    const payload = events_mod.buildDeletedPayload(
        allocator,
        params.entity_type,
        definition.logical_shape_version,
        params.record_id,
        current_state.field_values,
    ) catch return error.OutOfMemory;
    defer allocator.free(payload);

    const actor_uuid = entities_mod.parseUuid(params.actor_id) catch return error.InvalidRecord;
    const append_res = store.append(allocator, .{
        .tenant_id = params.tenant_id,
        .instance_id = instance_id,
        .event_type = events_mod.EntityEventType.entity_record_deleted.wireName(),
        .payload = payload,
        .actor_id = actor_uuid,
        .idempotency_key = params.idempotency_key,
        .metadata = null,
    }) catch |err| switch (err) {
        error.PoolExhausted => return error.PoolExhausted,
        else => return error.TransactionFailed,
    };
    var append_res_mut = append_res;
    defer append_res_mut.record.deinit(allocator);

    if (append_res_mut.is_duplicate) {
        success = true;
        conn.commit() catch return error.TransactionFailed;
        return fetchRecordResult(allocator, conn, params.entity_type, params.record_id, params.tenant_id);
    }

    updateProjection(conn, params.tenant_id, params.entity_type, params.record_id, "{}", true, definition.logical_shape_version, append_res_mut.record.sequence_number) catch return error.TransactionFailed;

    success = true;
    conn.commit() catch return error.TransactionFailed;

    const record_id_dupe = try allocator.dupe(u8, params.record_id);
    errdefer allocator.free(record_id_dupe);
    const entity_type_dupe = try allocator.dupe(u8, params.entity_type);
    errdefer allocator.free(entity_type_dupe);
    const field_values_dupe = try allocator.dupe(u8, "{}");
    errdefer allocator.free(field_values_dupe);

    return RecordResult{
        .record_id = record_id_dupe,
        .entity_type = entity_type_dupe,
        .field_values = field_values_dupe,
        .version_seq = append_res_mut.record.sequence_number,
        .is_duplicate = false,
    };
}

// ── Private helpers ─────────────────────────────────────────────────────────

fn getOrCreateEntityTypeInstance(conn: *db.Conn, tenant_id: []const u8, entity_type: []const u8, definition_id: Uuid) !Uuid {
    // 1. Ensure entity_type_instances entry exists
    var schema_buf: [80]u8 = undefined;
    const schema = db.schemaNameForTenant(tenant_id, &schema_buf);
    const sql = try std.fmt.allocPrint(std.heap.page_allocator,
        \\INSERT INTO {s}.entity_type_instances (entity_type, tenant_id, instance_id)
        \\VALUES ($1, $2::uuid, gen_random_uuid())
        \\ON CONFLICT (entity_type) DO UPDATE SET tenant_id = EXCLUDED.tenant_id
        \\RETURNING instance_id::text
    , .{schema});
    defer std.heap.page_allocator.free(sql);

    const row = (conn.queryRow(std.heap.page_allocator, sql, &.{ entity_type, tenant_id }) catch return error.TransactionFailed) orelse return error.TransactionFailed;
    defer {
        if (row[0]) |v| std.heap.page_allocator.free(v);
        std.heap.page_allocator.free(row);
    }

    const id_str = row[0] orelse return error.TransactionFailed;
    const instance_id = try entities_mod.parseUuid(id_str);

    // 2. Ensure instance_projections entry exists (required by Store.append)
    // We register the entity type as a virtual "process instance" so the Event Store
    // can track its event stream sequence.
    const def_id_str = try entities_mod.formatUuid(std.heap.page_allocator, definition_id);
    defer std.heap.page_allocator.free(def_id_str);

    _ = conn.exec(
        \\INSERT INTO instance_projections (instance_id, definition_id, status, current_nodes, variables, started_at, updated_at)
        \\VALUES ($1::uuid, $2::uuid, 'ACTIVE', '[]'::jsonb, '{}'::jsonb, NOW(), NOW())
        \\ON CONFLICT (instance_id) DO UPDATE SET updated_at = NOW()
    , &.{ id_str, def_id_str }) catch return error.TransactionFailed;

    return instance_id;
}

fn updateProjection(
    conn: *db.Conn,
    tenant_id: []const u8,
    entity_type: []const u8,
    record_id: []const u8,
    field_values: []const u8,
    is_deleted: bool,
    def_ver: u32,
    seq: i64,
) !void {
    const deleted_at = if (is_deleted) "NOW()::timestamptz" else "NULL::timestamptz";
    const def_ver_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{def_ver});
    defer std.heap.page_allocator.free(def_ver_str);
    const seq_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{seq});
    defer std.heap.page_allocator.free(seq_str);

    var schema_buf: [80]u8 = undefined;
    const schema_name = db.schemaNameForTenant(tenant_id, &schema_buf);

    const sql = try std.fmt.allocPrint(std.heap.page_allocator,
        \\INSERT INTO {s}.entity_record_latest (tenant_id, entity_type, record_id, current_state, version_seq, entity_def_version, updated_at, deleted_at)
        \\VALUES ($1::uuid, $2::text, $3::uuid, $4::jsonb, $5::bigint, $6::integer, NOW(), {s})
        \\ON CONFLICT (entity_type, record_id)
        \\DO UPDATE SET current_state = EXCLUDED.current_state,
        \\          version_seq = EXCLUDED.version_seq,
        \\          entity_def_version = EXCLUDED.entity_def_version,
        \\          updated_at = NOW(),
        \\          deleted_at = EXCLUDED.deleted_at
    , .{ schema_name, deleted_at });
    defer std.heap.page_allocator.free(sql);

    const params = [_][]const u8{
        tenant_id,
        entity_type,
        record_id,
        field_values,
        seq_str,
        def_ver_str,
    };

    std.debug.print("updateProjection: SQL={s}\n", .{sql});
    std.debug.print("updateProjection Params: tenant={s}, type={s}, record={s}, values={s}, seq={s}, def_ver={s}\n", .{ params[0], params[1], params[2], params[3], params[4], params[5] });

    conn.exec(sql, &params) catch |err| {
        std.debug.print("updateProjection failed: {any}\n", .{err});
        return error.TransactionFailed;
    };
}

fn fetchRecordResult(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    entity_type: []const u8,
    record_id: []const u8,
    tenant_id: []const u8,
) !RecordResult {
    var schema_buf: [80]u8 = undefined;
    const schema_name = db.schemaNameForTenant(tenant_id, &schema_buf);

    const query_sql = try std.fmt.allocPrint(allocator,
        \\SELECT record_id::text, entity_type, current_state::text, version_seq::text
        \\FROM {s}.entity_record_latest
        \\WHERE entity_type = $1 AND record_id = $2::uuid AND tenant_id = $3::uuid
    , .{schema_name});
    defer allocator.free(query_sql);

    std.debug.print("Fetching duplicate: SQL={s}, Params: type={s}, record={s}, tenant={s}\n", .{ query_sql, entity_type, record_id, tenant_id });
    const row = (conn.queryRow(allocator, query_sql, &.{ entity_type, record_id, tenant_id }) catch return error.TransactionFailed) orelse return error.InvalidRecord;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }

    if (row[0] == null) return error.InvalidRecord;

    const record_id_dupe = try allocator.dupe(u8, row[0].?);
    errdefer allocator.free(record_id_dupe);
    const entity_type_dupe = try allocator.dupe(u8, row[1].?);
    errdefer allocator.free(entity_type_dupe);
    const field_values_dupe = try allocator.dupe(u8, row[2].?);
    errdefer allocator.free(field_values_dupe);

    return RecordResult{
        .record_id = record_id_dupe,
        .entity_type = entity_type_dupe,
        .field_values = field_values_dupe,
        .version_seq = std.fmt.parseInt(i64, row[3].?, 10) catch 0,
        .is_duplicate = true,
    };
}
