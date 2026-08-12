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
const validator_mod = @import("validator.zig");

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

    // 1. Load active entity definition
    const def = definition_mod.getDefinitionByName(allocator, pool, params.tenant_id, params.entity_type) catch |err| switch (err) {
        error.DefinitionNotFound => return error.InvalidEntityType,
        else => return error.TransactionFailed,
    };
    var definition = def;
    defer definition.deinit(allocator);

    // 2. Validate field_values against the active definition (ISS-0160 / GH #481).
    //    This was a literal TODO ("we assume JSON is valid or validated
    //    upstream"), and the assumption did not hold — createRecord is called
    //    directly by the REST route handlers with no intervening validation
    //    layer, so any payload was accepted and durably persisted into the
    //    event log. Runs BEFORE the append so a rejected create leaves no
    //    event and no projection row behind.
    try validatePayload(allocator, definition.definition_json, params.field_values);

    // 3. Get or create instance_id for this entity_type
    const instance_id = getOrCreateEntityTypeInstance(allocator, conn, params.tenant_id, params.entity_type) catch return error.TransactionFailed;

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
    // ISS-0159 / GH #480: store.append() returns an EventRecord whose
    // event_type/payload/metadata may be allocator-owned — rowToEventRecord()
    // dupes all three when it reconstructs the ORIGINAL event on a duplicate.
    // Nothing here ever freed them, leaking 3 allocations per call. The
    // non-duplicate path's record comes from duplicateFromParams(), which
    // borrows rather than allocates and sets those fields to ""; EventRecord.deinit
    // guards on `.len > 0`, so this one defer is correct for both shapes.
    var append_record = append_res.record;
    defer append_record.deinit(allocator);

    if (append_res.is_duplicate) {
        // ISS-0159 / GH #480: look up the ORIGINAL event's record_id, not the
        // one minted above. `record_id` is freshly random on every call and was
        // never persisted on a replay, so the lookup matched zero rows and
        // returned InvalidRecord — breaking the EXP-202 idempotency contract
        // exactly when it matters (a client retrying after a network timeout).
        // The original id is carried in the replayed event's payload.
        const original_id = extractRecordId(allocator, append_record.payload) catch null;
        defer if (original_id) |id| allocator.free(id);
        const lookup_id = original_id orelse record_id;
        return fetchRecordResult(allocator, conn, params.entity_type, lookup_id, params.tenant_id);
    }

    // 6. Update entity_record_latest projection
    updateProjection(conn, params.tenant_id, params.entity_type, record_id, params.field_values, false, definition.logical_shape_version, append_res.record.sequence_number) catch return error.TransactionFailed;

    return RecordResult{
        .record_id = try allocator.dupe(u8, record_id),
        .entity_type = try allocator.dupe(u8, params.entity_type),
        .field_values = try allocator.dupe(u8, params.field_values),
        .version_seq = append_res.record.sequence_number,
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

    // Load active definition
    const def = definition_mod.getDefinitionByName(allocator, pool, params.tenant_id, params.entity_type) catch |err| switch (err) {
        error.DefinitionNotFound => return error.InvalidEntityType,
        else => return error.TransactionFailed,
    };
    var definition = def;
    defer definition.deinit(allocator);

    // Validate field_values against the active definition (ISS-0160 / GH #481).
    // updateRecord had the same gap as createRecord: it loaded the definition
    // and built the updated payload without ever comparing the two.
    try validatePayload(allocator, definition.definition_json, params.field_values);

    // Get instance_id
    const instance_id = getOrCreateEntityTypeInstance(allocator, conn, params.tenant_id, params.entity_type) catch return error.TransactionFailed;

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
    // ISS-0159 / GH #480: same leak as createRecord — see the note there.
    var append_record = append_res.record;
    defer append_record.deinit(allocator);

    if (append_res.is_duplicate) {
        return fetchRecordResult(allocator, conn, params.entity_type, params.record_id, params.tenant_id);
    }

    updateProjection(conn, params.tenant_id, params.entity_type, params.record_id, params.field_values, false, definition.logical_shape_version, append_res.record.sequence_number) catch return error.TransactionFailed;

    return RecordResult{
        .record_id = try allocator.dupe(u8, params.record_id),
        .entity_type = try allocator.dupe(u8, params.entity_type),
        .field_values = try allocator.dupe(u8, params.field_values),
        .version_seq = append_res.record.sequence_number,
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

    // Load active definition
    const def = definition_mod.getDefinitionByName(allocator, pool, params.tenant_id, params.entity_type) catch |err| switch (err) {
        error.DefinitionNotFound => return error.InvalidEntityType,
        else => return error.TransactionFailed,
    };
    var definition = def;
    defer definition.deinit(allocator);

    const instance_id = getOrCreateEntityTypeInstance(allocator, conn, params.tenant_id, params.entity_type) catch return error.TransactionFailed;

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
    // ISS-0159 / GH #480: same leak as createRecord — see the note there.
    // (deleteRecord validates nothing: a delete carries no caller payload.)
    var append_record = append_res.record;
    defer append_record.deinit(allocator);

    if (append_res.is_duplicate) {
        return fetchRecordResult(allocator, conn, params.entity_type, params.record_id, params.tenant_id);
    }

    updateProjection(conn, params.tenant_id, params.entity_type, params.record_id, "{}", true, definition.logical_shape_version, append_res.record.sequence_number) catch return error.TransactionFailed;

    return RecordResult{
        .record_id = try allocator.dupe(u8, params.record_id),
        .entity_type = try allocator.dupe(u8, params.entity_type),
        .field_values = try allocator.dupe(u8, "{}"),
        .version_seq = append_res.record.sequence_number,
        .is_duplicate = false,
    };
}

// ── Private helpers ─────────────────────────────────────────────────────────

/// Reject `field_values` if it violates `definition_json` (ISS-0160 / GH #481).
///
/// Returns normally when the payload conforms; `EntityCommandError.InvalidPayload`
/// when it does not. The violation detail is intentionally discarded here —
/// `RecordResult` has nowhere to carry it — but the checking itself is real,
/// and the REST layer can call `validator_mod.validateRecordPayload` directly
/// when it needs the per-field breakdown for an RFC 9457 body.
///
/// A definition that no longer parses is a definitions-table integrity fault,
/// not a caller error, so it surfaces as TransactionFailed rather than being
/// silently treated as "no constraints" — a permissive fallback here would
/// recreate exactly the silent-acceptance defect this function exists to close.
fn validatePayload(
    allocator: std.mem.Allocator,
    definition_json: []const u8,
    field_values: []const u8,
) EntityCommandError!void {
    const violations = validator_mod.validateRecordPayload(
        allocator,
        definition_json,
        field_values,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TransactionFailed,
    };
    defer validator_mod.deinitRecordViolations(allocator, violations);

    if (violations.len > 0) return error.InvalidPayload;
}

/// Pull the `record_id` out of an ENTITY_RECORD_* event payload.
///
/// Used by the duplicate branches to recover the ORIGINAL record's id from the
/// replayed event (ISS-0159 / GH #480). Returns null when the payload is absent,
/// unparseable, or carries no `record_id` — the caller then falls back rather
/// than failing the replay outright. Caller owns the returned slice.
fn extractRecordId(allocator: std.mem.Allocator, payload: []const u8) !?[]const u8 {
    if (payload.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const id_val = parsed.value.object.get("record_id") orelse return null;
    if (id_val != .string) return null;
    if (id_val.string.len == 0) return null;

    return try allocator.dupe(u8, id_val.string);
}

/// Sentinel `definition_id` carried by every synthetic entity-type instance.
///
/// `instance_projections.definition_id` is NOT NULL but has no foreign key to
/// `process_definitions`, so a fixed sentinel is safe and makes entity-type
/// streams trivially identifiable (`WHERE definition_id = ENTITY_STREAM_DEFINITION_ID`)
/// without adding a column. It is deliberately distinct from the all-zero
/// default-tenant UUID so the two never alias in a query.
pub const ENTITY_STREAM_DEFINITION_ID = "00000000-0000-0000-0000-0000000e2117";

/// Resolve (creating on first use) the synthetic process instance that owns the
/// event stream for `entity_type`, per `src/design/entities.md` §"Instance scoping".
///
/// Two rows make up that instance and BOTH must exist:
///   - `entity_type_instances` — the entity_type → instance_id mapping, and
///   - `instance_projections`  — the instance itself.
///
/// `store.append()` validates `SELECT status FROM instance_projections WHERE
/// instance_id = $1` before every append and returns `StoreError.InstanceNotFound`
/// when it is missing. Creating only the mapping row (as this function did before
/// ISS-0156 / GH #475) therefore broke every entity record create/update/delete.
///
/// The projection row is written exactly as `src/engine/instance.zig` writes one
/// for a process instance — `status 'ACTIVE'`, empty `variables`/`current_nodes`,
/// `tenant_id` bound as an explicit $N parameter (ISS-0688 / GH-745: never from
/// the dropped bpm_effective_tenant_id() SQL function or a session GUC — see
/// the INV-1 fix pattern in src/engine/instance.zig) — differing only in
/// carrying the entity sentinel `definition_id` and a NULL `correlation_key`.
/// `ON CONFLICT (instance_id) DO NOTHING` keeps it idempotent across repeated
/// calls, and also self-repairs a mapping row left over from before this fix,
/// whose projection row never existed.
fn getOrCreateEntityTypeInstance(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    tenant_id: []const u8,
    entity_type: []const u8,
) !Uuid {
    var schema_buf: [80]u8 = undefined;
    const schema_name = db.schemaNameForTenant(tenant_id, &schema_buf);

    // Only the schema name — derived from the tenant UUID by schemaNameForTenant,
    // never raw user input — is interpolated. All values are bound as $N.
    const query_sql = std.fmt.allocPrint(allocator,
        \\INSERT INTO {s}.entity_type_instances (entity_type, tenant_id, instance_id)
        \\VALUES ($1, $2::uuid, gen_random_uuid())
        \\ON CONFLICT (entity_type) DO UPDATE SET tenant_id = EXCLUDED.tenant_id
        \\RETURNING instance_id::text
    , .{schema_name}) catch return error.OutOfMemory;
    defer allocator.free(query_sql);

    const row = (conn.queryRow(allocator, query_sql, &.{ entity_type, tenant_id }) catch return error.TransactionFailed) orelse return error.TransactionFailed;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }

    const id_str = row[0] orelse return error.TransactionFailed;
    const instance_id = try entities_mod.parseUuid(id_str);

    try ensureEntityInstanceProjection(allocator, conn, schema_name, tenant_id, id_str);

    return instance_id;
}

/// Create the `instance_projections` row backing a synthetic entity-type
/// instance, if it does not already exist. Idempotent.
fn ensureEntityInstanceProjection(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    schema_name: []const u8,
    tenant_id: []const u8,
    instance_id_str: []const u8,
) !void {
    const sql = std.fmt.allocPrint(allocator,
        \\INSERT INTO {s}.instance_projections
        \\    (tenant_id, instance_id, definition_id, correlation_key,
        \\     status, variables, current_nodes, started_at, updated_at)
        \\VALUES
        \\    ($1::uuid, $2::uuid, $3::uuid, NULL,
        \\     'ACTIVE', '{{}}'::jsonb, '[]'::jsonb, NOW(), NOW())
        \\ON CONFLICT (instance_id) DO NOTHING
    , .{schema_name}) catch return error.OutOfMemory;
    defer allocator.free(sql);

    conn.exec(sql, &.{ tenant_id, instance_id_str, ENTITY_STREAM_DEFINITION_ID }) catch return error.TransactionFailed;
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
    const deleted_at = if (is_deleted) "NOW()" else "NULL";
    const def_ver_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{def_ver});
    defer std.heap.page_allocator.free(def_ver_str);
    const seq_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{seq});
    defer std.heap.page_allocator.free(seq_str);

    var schema_buf: [80]u8 = undefined;
    const schema_name = db.schemaNameForTenant(tenant_id, &schema_buf);

    const sql = std.fmt.allocPrint(std.heap.page_allocator,
        \\INSERT INTO {s}.entity_record_latest (tenant_id, entity_type, record_id, current_state, version_seq, entity_def_version, updated_at, deleted_at)
        \\VALUES ($1, $2, $3, $4::jsonb, $5, $6, NOW(), {s})
        \\ON CONFLICT (entity_type, record_id)
        \\DO UPDATE SET current_state = EXCLUDED.current_state,
        \\          version_seq = EXCLUDED.version_seq,
        \\          entity_def_version = EXCLUDED.entity_def_version,
        \\          updated_at = NOW(),
        \\          deleted_at = {s}
    , .{ schema_name, deleted_at, deleted_at }) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(sql);

    conn.exec(sql, &.{ tenant_id, entity_type, record_id, field_values, seq_str, def_ver_str }) catch return error.TransactionFailed;
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
        \\WHERE entity_type = $1 AND record_id = $2 AND tenant_id = $3
    , .{schema_name});
    defer allocator.free(query_sql);

    const row = (conn.queryRow(allocator, query_sql, &.{ entity_type, record_id, tenant_id }) catch return error.TransactionFailed) orelse return error.InvalidRecord;
    defer {
        for (row) |col| if (col) |v| allocator.free(v);
        allocator.free(row);
    }

    if (row[0] == null) return error.InvalidRecord;

    return RecordResult{
        .record_id = try allocator.dupe(u8, row[0].?),
        .entity_type = try allocator.dupe(u8, row[1].?),
        .field_values = try allocator.dupe(u8, row[2].?),
        .version_seq = std.fmt.parseInt(i64, row[3].?, 10) catch 0,
        .is_duplicate = true,
    };
}
