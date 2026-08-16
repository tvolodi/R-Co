//! Event store — ES-01, ES-02, ES-03, ES-04, ES-05, ES-06, ES-07, ES-08
//!
//! Append-only log of typed, immutable events.  All writes go through a single
//! transaction (DB-03).  Idempotency is enforced at the DB level via a UNIQUE
//! index on events(idempotency_key) and a fallback check in events_archive
//! (Invariant #5 in the design artefact).
//!
//! XC-04 Kernel Determinism: This module is part of the platform kernel.
//! It contains NO LLM API calls, HTTP requests, or external service dependencies.
//! All event writes are transactional and deterministic (ES-02, DB-03).
//!
//! Design artefact: src/design/event_store.md
const std = @import("std");
const db = @import("pool");
const pipeline_context_mod = @import("pipeline_context");
const platform = @import("platform.zig");
const Pool = db.Pool;
const PoolError = db.PoolError;
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
/// Re-export so consumers importing this file as a named module (e.g. the
/// `event_store` module used by tests/unit/event_store_test.zig) can reach
/// registry.zig, which is otherwise only addressable by relative path from
/// inside this module. (ISS-0148)
pub const registry_module = registry_mod;
const metrics = @import("obs_metrics");

// ---------------------------------------------------------------------------
// Shared type
// ---------------------------------------------------------------------------

/// Raw 16-byte UUID v4 representation.
pub const Uuid = [16]u8;
pub const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const StoreError = error{
    /// tenant_id is absent at storage boundary; deterministic fallback is required by caller.
    MissingTenantContext,
    /// Pool.acquire() returned ExhaustedPool → HTTP 503.
    PoolExhausted,
    /// instance_id does not exist in instance_projections → HTTP 404 (ES-01).
    InstanceNotFound,
    /// Append to an instance with status CANCELLED or COMPLETED → HTTP 409 (ES-01).
    InstanceTerminated,
    /// event_type not registered in event_type_registry → HTTP 422 (ES-05).
    UnknownEventType,
    /// Payload fails registered JSON Schema → HTTP 422 (ES-05).
    PayloadSchemaInvalid,
    /// metadata value is not a string, key > 128 chars, value > 1024 chars,
    /// or more than 50 entries → HTTP 422 (ES-08).
    MetadataInvalid,
    /// Caller metadata pipeline_run_id conflicts with trusted request context.
    PipelineRunIdMetadataConflict,
    /// idempotency_key is absent or empty → HTTP 422 (ES-03).
    IdempotencyKeyMissing,
    /// idempotency_key > 255 chars → HTTP 422 (ES-03).
    IdempotencyKeyTooLong,
    /// payload is null, a JSON array, or a JSON scalar → HTTP 422 (ES-01).
    PayloadInvalid,
    /// actor_id is nil or empty → HTTP 422 (ES-01).
    ActorIdMissing,
    /// A multi-table transaction failed to commit (DB-03).
    TransactionFailed,
    /// retention policy upsert is missing required keep_days/keep_count
    /// or includes a value that does not match policy mode.
    InvalidRetentionPolicyValue,
    /// hard-delete retention is forbidden for replay-critical families.
    ProtectedFamilyHardDeleteForbidden,
    /// An append's created_at falls in a calendar month with no attached
    /// partition on events/events_ephemeral → HTTP 503 (PAR-01 AC4). Distinct
    /// from the generic TransactionFailed: this is Postgres SQLSTATE 23514
    /// (check_violation) raised by partition routing finding no matching
    /// partition, not an ordinary constraint failure, and it is transient —
    /// resolved by the next plat_partition_maintenance run (PAR-02) rather
    /// than a caller input error.
    PartitionMissingForWrite,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const EventRecord = struct {
    event_id: Uuid,
    instance_id: Uuid,
    event_type: []const u8,
    /// JSON object bytes; inline ≤ 4096 bytes, else fetched from event_payload_store.
    payload: []const u8,
    actor_id: Uuid,
    /// UTC microseconds since Unix epoch; microsecond precision (ES-01).
    created_at: i64,
    /// Per-instance monotonically increasing; assigned from instance_sequence (ES-02).
    sequence_number: i64,
    /// Global unique key, 1..255 chars (ES-03).
    idempotency_key: []const u8,
    /// JSON bytes; string→string map; defaults to "{}". (ES-08)
    metadata: []const u8,
    /// Cross-instance monotone; from events_global_seq PostgreSQL sequence (ES-04).
    global_seq: i64,

    pub fn deinit(self: *EventRecord, allocator: std.mem.Allocator) void {
        if (self.event_type.len > 0) allocator.free(self.event_type);
        if (self.payload.len > 0) allocator.free(self.payload);
        if (self.metadata.len > 0) allocator.free(self.metadata);
    }
};

pub const AppendParams = struct {
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
    instance_id: Uuid,
    event_type: []const u8,
    payload: []const u8,
    actor_id: Uuid,
    idempotency_key: []const u8,
    metadata: ?[]const u8,
    pipeline_run_id: ?[]const u8 = null,
};

pub const AppendResult = struct {
    record: EventRecord,
    /// true  → idempotency_key already committed; return HTTP 200 (ES-03).
    /// false → new event persisted; return HTTP 201 (ES-01).
    is_duplicate: bool,
};

/// Parameters for a platform-scoped EXECUTION_* event (no owning workflow instance).
/// instance_id, actor_id, tenant_id are fixed to platform sentinels by appendPlatform.
pub const PlatformAppendParams = struct {
    event_type: []const u8,
    payload: []const u8,
    idempotency_key: []const u8,
};

pub const ReadOpts = struct {
    /// Return events with sequence_number ≤ value; null = no upper limit (ES-06).
    up_to_sequence: ?i64,
    /// Return events with created_at ≤ value (UTC µs); null = no upper limit (ES-06).
    /// If both are set, up_to_sequence takes precedence (ES-06).
    up_to_timestamp: ?i64,
};

pub const GlobalReadOpts = struct {
    /// Resume cursor: return events with global_seq > value; null = from start (ES-04).
    after_global_seq: ?i64,
    /// Optional correlation filter for ADP-06 metadata propagation.
    pipeline_run_id: ?[]const u8 = null,
    /// Page size; 1..1000; 0 treated as default 100 (ES-04).
    limit: u32,
};

pub const HistoryReadOpts = struct {
    /// Optional: filter to a specific event_type name. Null = all types.
    event_type: ?[]const u8,
    /// Optional: inclusive lower bound on created_at (UTC µs). Null = no lower bound.
    from: ?i64,
    /// Optional: inclusive upper bound on created_at (UTC µs). Null = no upper bound.
    to: ?i64,
    /// Optional ADP-06 metadata filter.
    pipeline_run_id: ?[]const u8 = null,
    /// Cursor: only return events with sequence_number > this value. Null = from start.
    after_sequence: ?i64,
    /// Maximum number of events to return. 1..200.
    limit: u16,
};

pub const RetentionPolicyMode = enum {
    keep_forever,
    keep_days,
    keep_count,
    hard_delete_days,
    hard_delete_count,
};

pub const RetentionPolicyUpsertParams = struct {
    event_type: []const u8,
    policy: RetentionPolicyMode,
    keep_days: ?u32 = null,
    keep_count: ?u32 = null,
};

pub const RetentionPolicyViolation = struct {
    code: []const u8,
    title: []const u8,
    detail: []const u8,
    reason: []const u8,
    event_family: []const u8,
    allowed_modes: [3][]const u8,
    requested_mode: []const u8,
    event_type: []const u8,
};

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

pub const Store = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    registry: *Registry,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// pool and registry must outlive Store.
    pub fn init(
        allocator: std.mem.Allocator,
        pool: *Pool,
        registry: *Registry,
    ) Store {
        return Store{
            .allocator = allocator,
            .pool = pool,
            .registry = registry,
        };
    }

    pub fn deinit(self: *Store) void {
        _ = self;
    }

    // -----------------------------------------------------------------------
    // appendPlatform (PAR-02 AC5, ISS-0670)
    // -----------------------------------------------------------------------

    /// Append a platform-scoped EXECUTION_* event.
    ///
    /// Differences from append():
    ///  - Skips instance_projections existence check.
    ///  - Skips instance_sequence counter; sequence_number is written as 0.
    ///  - Uses PLATFORM_INSTANCE_ID, PLATFORM_ACTOR_ID, PLATFORM_TENANT_ID sentinels.
    ///  - Does NOT update instance_projections.last_event_seq.
    ///  - ES-03 idempotency, ES-05 registry validation, DB-03 atomicity preserved.
    ///
    /// Returns AppendResult with is_duplicate=true if idempotency_key already committed.
    pub fn appendPlatform(
        self: *Store,
        allocator: std.mem.Allocator,
        params: PlatformAppendParams,
    ) StoreError!AppendResult {
        // Pre-write validation.
        if (params.idempotency_key.len == 0) return StoreError.IdempotencyKeyMissing;
        if (params.idempotency_key.len > 255) return StoreError.IdempotencyKeyTooLong;
        if (!isJsonObject(params.payload)) return StoreError.PayloadInvalid;

        // ES-05: registry validation.
        self.registry.validatePayload(allocator, params.event_type, params.payload) catch |err| switch (err) {
            registry_mod.RegistryError.UnknownEventType => return StoreError.UnknownEventType,
            registry_mod.RegistryError.PayloadValidationFailed => return StoreError.PayloadSchemaInvalid,
            registry_mod.RegistryError.PoolExhausted => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };

        // PAR-03: retention-class routing (events vs events_ephemeral).
        const type_record = self.registry.getType(allocator, params.event_type) catch |err| switch (err) {
            registry_mod.RegistryError.UnknownEventType => return StoreError.UnknownEventType,
            registry_mod.RegistryError.PoolExhausted => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer registry_mod.Registry.freeTypeRecord(allocator, type_record);
        const target_table: []const u8 = if (std.mem.eql(u8, type_record.retention_class, "delete"))
            "events_ephemeral"
        else
            "events";

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer self.pool.release(conn);

        conn.exec("BEGIN", &.{}) catch return StoreError.TransactionFailed;
        errdefer conn.exec("ROLLBACK", &.{}) catch {};

        // Platform events are cross-tenant; public schema holds all three event tables.
        conn.exec("SET LOCAL search_path TO public", &.{}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };

        // ES-03: idempotency via plat_event_idempotency.
        const idem_rows = conn.query(
            allocator,
            \\INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
            \\VALUES ($1, gen_random_uuid(), NOW())
            \\ON CONFLICT (idempotency_key) DO NOTHING
            \\RETURNING event_id, (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us
        ,
            &.{params.idempotency_key},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };
        defer {
            var mr = idem_rows;
            mr.deinit();
        }

        const generated_event_id: []const u8 = if (idem_rows.rows.len > 0 and idem_rows.rows[0].len > 0)
            (idem_rows.rows[0][0] orelse "")
        else
            "";

        if (idem_rows.rows.len == 0) {
            conn.exec("ROLLBACK", &.{}) catch {};
            return AppendResult{
                .record = EventRecord{
                    .event_id = std.mem.zeroes(Uuid),
                    .instance_id = std.mem.zeroes(Uuid),
                    .event_type = "",
                    .payload = "",
                    .actor_id = std.mem.zeroes(Uuid),
                    .created_at = 0,
                    .sequence_number = 0,
                    .idempotency_key = params.idempotency_key,
                    .metadata = "{}",
                    .global_seq = 0,
                },
                .is_duplicate = true,
            };
        }

        // INSERT into target table with platform sentinels; sequence_number=0 (no per-instance stream).
        const insert_sql_events =
            \\INSERT INTO events
            \\  (event_id, instance_id, event_type, payload, actor_id,
            \\   sequence_number, idempotency_key, metadata, global_seq)
            \\VALUES
            \\  ($1::uuid, $2::uuid, $3, $4::jsonb, $5::uuid,
            \\   0, $6, '{}'::jsonb, nextval('events_global_seq'))
        ;
        const insert_sql_ephemeral =
            \\INSERT INTO events_ephemeral
            \\  (event_id, instance_id, event_type, payload, actor_id,
            \\   sequence_number, idempotency_key, metadata, global_seq)
            \\VALUES
            \\  ($1::uuid, $2::uuid, $3, $4::jsonb, $5::uuid,
            \\   0, $6, '{}'::jsonb, nextval('events_global_seq'))
        ;
        const insert_sql = if (std.mem.eql(u8, target_table, "events_ephemeral"))
            insert_sql_ephemeral
        else
            insert_sql_events;

        conn.exec(insert_sql, &.{
            generated_event_id,
            platform.PLATFORM_INSTANCE_ID,
            params.event_type,
            params.payload,
            platform.PLATFORM_ACTOR_ID,
            params.idempotency_key,
        }) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };

        conn.exec("COMMIT", &.{}) catch return StoreError.TransactionFailed;

        return AppendResult{
            .record = EventRecord{
                .event_id = std.mem.zeroes(Uuid),
                .instance_id = std.mem.zeroes(Uuid),
                .event_type = "",
                .payload = params.payload,
                .actor_id = std.mem.zeroes(Uuid),
                .created_at = 0,
                .sequence_number = 0,
                .idempotency_key = params.idempotency_key,
                .metadata = "{}",
                .global_seq = 0,
            },
            .is_duplicate = false,
        };
    }

    // -----------------------------------------------------------------------
    // append (ES-01, ES-02, ES-03, ES-05, ES-08, DB-03)
    // -----------------------------------------------------------------------

    /// Append a typed, immutable event to the event log.
    ///
    /// Pre-write validations (no DB writes on failure):
    ///  - actor_id must be non-nil (ES-01)
    ///  - idempotency_key must be 1..255 chars (ES-03)
    ///  - payload must be a JSON object (ES-01)
    ///  - metadata validated in-process before any SQL (ES-08)
    ///  - registry.validatePayload() called before transaction (ES-05)
    ///
    /// Transaction (DB-03, atomic — all or nothing):
    ///  1. SELECT instance_projections WHERE instance_id = $1 (status check)
    ///  2. SELECT/lock instance_sequence FOR UPDATE (ES-02)
    ///  3. INSERT events … ON CONFLICT (idempotency_key) DO NOTHING RETURNING *
    ///  4. [if payload > 4096 bytes] INSERT event_payload_store
    ///  5. UPDATE instance_sequence SET next_seq = next_seq + 1
    ///  6. UPDATE instance_projections SET last_event_seq, updated_at
    ///
    /// Idempotency across archival (Invariant #5):
    ///  If the primary INSERT returns no rows, check events_archive to
    ///  distinguish a live-duplicate from a post-archival duplicate.
    pub fn append(
        self: *Store,
        allocator: std.mem.Allocator,
        params: AppendParams,
    ) StoreError!AppendResult {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();
        // --- Pre-write validation (no DB writes below this line) ---

        // ES-01/ES-03/ES-08 pre-write validation. Shared with the unit tests via
        // the public wrapper so both exercise identical bytes (ISS-0148).
        const metadata = try validateAppendParams(param_alloc, params);

        const pipeline_run_id = params.pipeline_run_id orelse currentRequestPipelineRunId();
        if (pipeline_run_id.len > 0) {
            const metadata_pipeline_run_id = metadataPipelineRunId(allocator, metadata) catch return StoreError.MetadataInvalid;
            defer if (metadata_pipeline_run_id) |v| allocator.free(v);
            if (metadata_pipeline_run_id) |v| {
                if (!std.mem.eql(u8, v, pipeline_run_id)) {
                    return StoreError.PipelineRunIdMetadataConflict;
                }
            }
        }

        // ES-05: registry validation before any write.
        self.registry.validatePayload(allocator, params.event_type, params.payload) catch |err| switch (err) {
            registry_mod.RegistryError.UnknownEventType => return StoreError.UnknownEventType,
            registry_mod.RegistryError.PayloadValidationFailed => return StoreError.PayloadSchemaInvalid,
            registry_mod.RegistryError.PoolExhausted => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };

        // PAR-03: retention-class routing. A second getType() call —
        // validatePayload() (above) already fetched this row internally but
        // discards everything except json_schema. Not folded into one call:
        // validatePayload()'s signature is a released ES-05 interface
        // (src/design/event_store.md) not touched by this batch. Still
        // inside the pre-write validation phase — no DB writes committed
        // yet either way.
        const type_record = self.registry.getType(allocator, params.event_type) catch |err| switch (err) {
            registry_mod.RegistryError.UnknownEventType => return StoreError.UnknownEventType,
            registry_mod.RegistryError.PoolExhausted => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer registry_mod.Registry.freeTypeRecord(allocator, type_record);
        // target_table is a compile-time-known one-of-two literal string,
        // never user input, never interpolated from params — Zig has no
        // parameterised-identifier placeholder, so it selects between two
        // fixed, hand-written SQL statement bodies below rather than being
        // bound as a $N value.
        const target_table: []const u8 = if (std.mem.eql(u8, type_record.retention_class, "delete"))
            "events_ephemeral"
        else
            "events";

        // --- Transaction ---
        const append_started_ms: i64 = std.Io.Clock.real.now(self.pool.io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self.pool.io).toMilliseconds() - append_started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            metrics.recordEventAppendDurationSeconds(elapsed_s);
        }

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var effective_pipeline_run_id: []const u8 = pipeline_run_id;
        if (effective_pipeline_run_id.len == 0) {
            const session_row_opt = conn.queryRow(
                allocator,
                "SELECT COALESCE(current_setting('bpm.pipeline_run_id', true), '')",
                &.{},
            ) catch null;
            if (session_row_opt) |session_row| {
                defer {
                    for (session_row) |c| if (c) |v| allocator.free(v);
                    allocator.free(session_row);
                }
                if (session_row.len > 0) {
                    if (session_row[0]) |v| {
                        if (v.len > 0) {
                            effective_pipeline_run_id = param_alloc.dupe(u8, v) catch return StoreError.TransactionFailed;
                        }
                    }
                }
            }
        }

        // BEGIN
        conn.exec("BEGIN", &.{}) catch return StoreError.TransactionFailed;
        errdefer conn.exec("ROLLBACK", &.{}) catch {};

        // ISS-0128: SET LOCAL search_path TO <schema>,public
        // Transaction-scoped protection against stale session-level search_path
        // on pooled connections. Pattern from ISS-0130 (PR #531, migrations.zig).
        var schema_buf: [80]u8 = undefined;
        const schema_name = db.schemaNameForTenant(params.tenant_id, &schema_buf);

        var set_path_buf: [128]u8 = undefined;
        const set_path_sql = std.fmt.bufPrint(
            &set_path_buf,
            "SET LOCAL search_path TO {s},public",
            .{schema_name},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };

        conn.exec(set_path_sql, &.{}) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };

        if (effective_pipeline_run_id.len > 0) {
            conn.exec("SELECT set_config('bpm.pipeline_run_id', $1, false)", &.{effective_pipeline_run_id}) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return StoreError.TransactionFailed;
            };
        }

        // Step 1: Check instance exists and is ACTIVE.
        // Parameterised — no string interpolation. (ES-01, security)
        const instance_rows = conn.query(
            allocator,
            "SELECT status FROM instance_projections WHERE instance_id = $1",
            &.{uuidToHex(param_alloc, params.instance_id) catch return StoreError.TransactionFailed},
        ) catch return StoreError.TransactionFailed;
        defer {
            var mr = instance_rows;
            mr.deinit();
        }

        if (instance_rows.rows.len == 0) {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.InstanceNotFound;
        }
        const status = blk: {
            const row = instance_rows.rows[0];
            if (row.len > 0) {
                break :blk row[0] orelse "";
            }
            break :blk @as([]const u8, "");
        };
        if (std.mem.eql(u8, status, "CANCELLED") or std.mem.eql(u8, status, "COMPLETED")) {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.InstanceTerminated;
        }

        // Step 2: Acquire per-instance sequence lock and get next_seq (ES-02).
        // INSERT … ON CONFLICT to handle first append to a new instance.
        const seq_rows = conn.query(
            allocator,
            \\INSERT INTO instance_sequence (instance_id, next_seq)
            \\VALUES ($1, 2)
            \\ON CONFLICT (instance_id) DO UPDATE
            \\  SET next_seq = instance_sequence.next_seq + 1
            \\RETURNING next_seq - 1 AS assigned_seq
        ,
            &.{uuidToHex(param_alloc, params.instance_id) catch return StoreError.TransactionFailed},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };
        defer {
            var mr = seq_rows;
            mr.deinit();
        }
        const sequence_number: i64 = blk: {
            if (seq_rows.rows.len > 0 and seq_rows.rows[0].len > 0) {
                if (seq_rows.rows[0][0]) |v| {
                    break :blk std.fmt.parseInt(i64, v, 10) catch 1;
                }
            }
            break :blk 1;
        };

        // Step 3 (PAR-01/PAR-03): idempotency-key uniqueness now lives in the
        // non-partitioned plat_event_idempotency sidecar table (global scope,
        // independent of which calendar-month partition the event row itself
        // lands in), NOT in a UNIQUE index on events — partitioning would
        // otherwise silently narrow idempotency_key uniqueness to per-
        // partition scope (PAR-01 AC2). Insert into plat_event_idempotency
        // FIRST, in the SAME transaction; if that returns no row, the key
        // already exists — fetch the pre-existing (event_id, created_at) and
        // read the original row from the correct table WITHOUT ever touching
        // events/events_ephemeral. If it returns a row, proceed to INSERT
        // INTO target_table (PAR-01's design doc, Open questions §3).
        const large_payload = params.payload.len > 4096;
        const stored_payload = if (large_payload)
            // Placeholder ref; real side-table logic pending pg.zig.
            "{\"$ref\":\"pending\"}"
        else
            params.payload;

        const idem_rows = conn.query(
            allocator,
            \\INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
            \\VALUES ($1, gen_random_uuid(), NOW())
            \\ON CONFLICT (idempotency_key) DO NOTHING
            \\RETURNING event_id, (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us
        ,
            &.{params.idempotency_key},
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };
        defer {
            var mr = idem_rows;
            mr.deinit();
        }

        // Capture the event_id plat_event_idempotency's INSERT just generated
        // (gen_random_uuid() evaluated ONCE, by that statement) so the
        // events/events_ephemeral INSERT below can bind the SAME value
        // explicitly, rather than letting it call gen_random_uuid() again via
        // its own column DEFAULT — two independent calls would produce two
        // DIFFERENT UUIDs, silently orphaning the plat_event_idempotency row
        // from the event row it is supposed to resolve to (confirmed live:
        // this exact bug made every duplicate-detection lookup fail to find
        // the original row, since the row plat_event_idempotency pointed at
        // never existed under that event_id).
        const generated_event_id: []const u8 = if (idem_rows.rows.len > 0 and idem_rows.rows[0].len > 0)
            (idem_rows.rows[0][0] orelse "")
        else
            "";

        if (idem_rows.rows.len == 0) {
            conn.exec("ROLLBACK", &.{}) catch {};
            // PAR-01 Invariant #5 successor: resolve the pre-existing
            // (event_id, created_at) from plat_event_idempotency, then read
            // the original row from whichever of events / events_archive /
            // events_ephemeral it actually lives in (partition pruning
            // applies automatically once created_at is known). Re-derive
            // target_table the same way the original append did (a second
            // registry.getType() lookup keyed by the SAME event_type, which
            // this call already has from params.event_type) — PAR-03's
            // design doc, Open questions §6, option (a): no schema change to
            // plat_event_idempotency needed.
            //
            // ISS-0187 / GH #521: reuse the already-held `conn` (rolled back
            // above, so it is outside any transaction and safe to read on)
            // instead of acquiring a second pool connection.
            const orig = orig_blk: {
                const resolve_rows = conn.query(
                    allocator,
                    "SELECT event_id::text, (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint::text FROM plat_event_idempotency WHERE idempotency_key = $1",
                    &.{params.idempotency_key},
                ) catch break :orig_blk duplicateFromParams(allocator, params, sequence_number, metadata);
                defer {
                    var mr = resolve_rows;
                    mr.deinit();
                }
                if (resolve_rows.rows.len == 0 or resolve_rows.rows[0].len < 2) {
                    break :orig_blk duplicateFromParams(allocator, params, sequence_number, metadata);
                }
                const resolved_event_id = resolve_rows.rows[0][0] orelse
                    break :orig_blk duplicateFromParams(allocator, params, sequence_number, metadata);

                // Check events, then events_ephemeral, then events_archive —
                // the duplicate could live in any of the three depending on
                // the event type's retention_class at the time it was
                // originally appended (which may differ from its CURRENT
                // retention_class if reconfigured since).
                const search_tables = [_][]const u8{ "events", "events_ephemeral", "events_archive" };
                for (search_tables) |table_name| {
                    const sql = std.fmt.allocPrint(
                        allocator,
                        "SELECT event_id, instance_id, event_type, payload, actor_id, " ++
                            "(EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us, " ++
                            "sequence_number, idempotency_key, metadata, global_seq " ++
                            "FROM {s} WHERE event_id::text = $1",
                        .{table_name},
                    ) catch break :orig_blk duplicateFromParams(allocator, params, sequence_number, metadata);
                    defer allocator.free(sql);

                    const rows = conn.query(allocator, sql, &.{resolved_event_id}) catch continue;
                    defer {
                        var mr = rows;
                        mr.deinit();
                    }
                    if (rows.rows.len > 0) {
                        break :orig_blk rowToEventRecord(allocator, rows.rows[0], "") catch
                            duplicateFromParams(allocator, params, sequence_number, metadata);
                    }
                }
                break :orig_blk duplicateFromParams(allocator, params, sequence_number, metadata);
            };
            return AppendResult{
                .record = orig,
                .is_duplicate = true,
            };
        }

        // Step 3b: INSERT the event row into target_table (events or
        // events_ephemeral — PAR-03's append-time retention-class routing).
        // Identical column list and $N positions in both branches; differing
        // only in the INSERT INTO / implicit ON CONFLICT target — the same
        // idempotency_key uniqueness is enforced globally by
        // plat_event_idempotency above, not by a per-table UNIQUE index, so
        // ON CONFLICT DO NOTHING here is defense-in-depth against the
        // (should-be-impossible, since plat_event_idempotency's own PK
        // already claimed the key) case of two callers racing between the
        // plat_event_idempotency insert and this one.
        // No ON CONFLICT clause: PAR-01 removes events' own uq_event_idempotency
        // unique index (partitioning would otherwise silently narrow
        // idempotency_key uniqueness to per-partition scope, PAR-01 AC2) —
        // with no unique/exclusion constraint left on events.idempotency_key,
        // PostgreSQL's ON CONFLICT has nothing to infer an arbiter index from
        // and raises 42P10 ("no unique or exclusion constraint matching the
        // ON CONFLICT specification") at parse time. Idempotency is now fully
        // guaranteed by the plat_event_idempotency INSERT immediately above
        // (Step 3) already having claimed this idempotency_key in the SAME
        // transaction before this INSERT is ever reached — a second INSERT
        // for the same key cannot get here at all (Step 3 returns the
        // duplicate-detection branch before this code runs), so no
        // conflict-handling clause is needed on this statement.
        const events_insert_sql =
            \\INSERT INTO events
            \\  (event_id, instance_id, event_type, payload, actor_id,
            \\sequence_number, idempotency_key, metadata,
            \\   global_seq)
            \\VALUES
            \\  ($9::uuid, $1, $2, $3::jsonb, $4,
            \\   $5, $6,
            \\   CASE
            \\     WHEN $8::text = '' THEN $7::jsonb
            \\     ELSE jsonb_set($7::jsonb, '{pipeline_run_id}', to_jsonb($8::text), true)
            \\   END,
            \\   nextval('events_global_seq'))
            \\RETURNING
            \\  event_id, instance_id, event_type, payload, actor_id,
            \\  (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
            \\  sequence_number, idempotency_key, metadata, global_seq
        ;
        const events_ephemeral_insert_sql =
            \\INSERT INTO events_ephemeral
            \\  (event_id, instance_id, event_type, payload, actor_id,
            \\sequence_number, idempotency_key, metadata,
            \\   global_seq)
            \\VALUES
            \\  ($9::uuid, $1, $2, $3::jsonb, $4,
            \\   $5, $6,
            \\   CASE
            \\     WHEN $8::text = '' THEN $7::jsonb
            \\     ELSE jsonb_set($7::jsonb, '{pipeline_run_id}', to_jsonb($8::text), true)
            \\   END,
            \\   nextval('events_global_seq'))
            \\RETURNING
            \\  event_id, instance_id, event_type, payload, actor_id,
            \\  (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
            \\  sequence_number, idempotency_key, metadata, global_seq
        ;

        const insert_sql = if (std.mem.eql(u8, target_table, "events_ephemeral"))
            events_ephemeral_insert_sql
        else
            events_insert_sql;

        const insert_rows = conn.query(
            allocator,
            insert_sql,
            &.{
                uuidToHex(param_alloc, params.instance_id) catch return StoreError.TransactionFailed,
                params.event_type,
                stored_payload,
                uuidToHex(param_alloc, params.actor_id) catch return StoreError.TransactionFailed,
                intToStr(param_alloc, sequence_number) catch return StoreError.TransactionFailed,
                params.idempotency_key,
                metadata,
                effective_pipeline_run_id,
                generated_event_id,
            },
        ) catch {
            // PAR-01 AC4: an append whose created_at falls in a calendar
            // month with no attached partition on the target table fails
            // Postgres's partition routing with SQLSTATE 23514
            // (check_violation) — "no partition of relation ... found for
            // row" — not an ordinary constraint violation. Distinguish it
            // from every other INSERT failure here (which stays
            // TransactionFailed) so the caller gets a structured, transient
            // (HTTP 503, see src/api/errors.zig) error instead of a generic
            // 5xx, per the Error taxonomy in
            // src/design/par-01-monthly-range-partitioning.md.
            // lastSqlState() returns a slice INTO the connection's mutable
            // last_sqlstate field, not an owned copy — conn.exec("ROLLBACK")
            // immediately below issues a new query, which resets that same
            // backing array before this code can read it. Copy the bytes out
            // to a local buffer first so the comparison sees the INSERT's
            // SQLSTATE, not ROLLBACK's (empty) one.
            var sqlstate_buf: [5]u8 = undefined;
            const is_partition_missing = if (conn.lastSqlState()) |s| blk: {
                @memcpy(&sqlstate_buf, s);
                break :blk std.mem.eql(u8, &sqlstate_buf, "23514");
            } else false;
            conn.exec("ROLLBACK", &.{}) catch {};
            if (is_partition_missing) {
                return StoreError.PartitionMissingForWrite;
            }
            return StoreError.TransactionFailed;
        };
        defer {
            var mr = insert_rows;
            mr.deinit();
        }

        if (insert_rows.rows.len == 0) {
            // Should not occur in practice: plat_event_idempotency's own PK
            // already claimed this idempotency_key moments earlier in the
            // same transaction. Treated as a transaction failure rather than
            // silently returning a duplicate result with no real row.
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        }

        const inserted_event_id: []const u8 = insert_rows.rows[0][0] orelse "";
        const inserted_created_at_us_text: []const u8 = if (insert_rows.rows[0].len > 5)
            (insert_rows.rows[0][5] orelse "0")
        else
            "0";

        // Step 4: Large payload side-table insert (NFR-05, ES-01). Now
        // supplies the REAL event_id from the RETURNING row above (fixing
        // the pre-existing "pending-event-id" placeholder bug) and the new
        // created_at column PAR-01's widened composite FK requires (a
        // composite FK to a partitioned parent must reference the FULL
        // partition key, not event_id alone).
        if (large_payload) {
            conn.exec(
                "INSERT INTO event_payload_store (event_id, created_at, payload, byte_size) VALUES ($1::uuid, to_timestamp($2::bigint / 1000000.0), $3, $4)",
                &.{
                    inserted_event_id,
                    inserted_created_at_us_text,
                    params.payload,
                    intToStr(param_alloc, @as(i64, @intCast(params.payload.len))) catch return StoreError.TransactionFailed,
                },
            ) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return StoreError.TransactionFailed;
            };
        }

        // Step 5: UPDATE instance_projections (last_event_seq, updated_at,
        // PAR-06 AC4's first_event_at/last_event_at window columns). (DB-03)
        // $3 is the SAME created_at the just-inserted events/events_ephemeral
        // row received (RETURNING created_at_us, read into
        // inserted_created_at_us_text above) — converted from UTC-microseconds
        // bigint text to timestamptz via to_timestamp(), matching the
        // conversion the large-payload side-table INSERT immediately above
        // already performs for the same value. first_event_at uses COALESCE
        // so it is set exactly once, on the instance's first append (PAR-06
        // design doc, "Store.append() extension"); last_event_at is
        // unconditionally overwritten on every append and always carries the
        // +1 microsecond upper-bound adjustment AT WRITE TIME, so the bounded
        // reconstruction query can use a plain exclusive `<` comparison.
        // Parameterised — no interpolation. (security)
        conn.exec(
            \\UPDATE instance_projections
            \\SET last_event_seq  = $1,
            \\    updated_at      = NOW(),
            \\    first_event_at  = COALESCE(first_event_at, to_timestamp($3::bigint / 1000000.0)),
            \\    last_event_at   = to_timestamp($3::bigint / 1000000.0) + INTERVAL '1 microsecond'
            \\WHERE instance_id = $2
        ,
            &.{
                intToStr(param_alloc, sequence_number) catch return StoreError.TransactionFailed,
                uuidToHex(param_alloc, params.instance_id) catch return StoreError.TransactionFailed,
                inserted_created_at_us_text,
            },
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };

        // COMMIT
        conn.exec("COMMIT", &.{}) catch return StoreError.TransactionFailed;

        // Build EventRecord from params (stable memory; avoids borrowing from
        // insert_rows which is freed by defer before the caller can read strings).
        const record = duplicateFromParams(allocator, params, sequence_number, metadata);

        return AppendResult{ .record = record, .is_duplicate = false };
    }

    // -----------------------------------------------------------------------
    // read (ES-02, ES-06)
    // -----------------------------------------------------------------------

    /// Return events for instance_id in ascending sequence_number order.
    ///
    /// Returns InstanceNotFound if instance_id does not exist.
    /// All filters use $N placeholders — no string interpolation. (security)
    pub fn read(
        self: *Store,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        opts: ReadOpts,
    ) StoreError![]EventRecord {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Verify instance exists.
        const check = conn.query(
            allocator,
            "SELECT 1 FROM instance_projections WHERE instance_id = $1",
            &.{uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed},
        ) catch return StoreError.TransactionFailed;
        defer {
            var mr = check;
            mr.deinit();
        }
        if (check.rows.len == 0) return StoreError.InstanceNotFound;

        // Build the filter clause.  up_to_sequence takes precedence (ES-06).
        if (opts.up_to_sequence != null) {
            const rows = conn.query(
                allocator,
                \\SELECT event_id, instance_id, event_type, payload, actor_id,
                \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
                \\       sequence_number, idempotency_key, metadata, global_seq
                \\FROM events
                \\WHERE instance_id = $1
                \\  AND sequence_number <= $2::bigint
                \\ORDER BY sequence_number ASC
            ,
                &.{
                    uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed,
                    intToStr(param_alloc, opts.up_to_sequence.?) catch return StoreError.TransactionFailed,
                },
            ) catch return StoreError.TransactionFailed;
            defer {
                var mr = rows;
                mr.deinit();
            }
            return rowsToEventRecords(allocator, rows.rows);
        }

        if (opts.up_to_timestamp != null) {
            const rows = conn.query(
                allocator,
                \\SELECT event_id, instance_id, event_type, payload, actor_id,
                \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
                \\       sequence_number, idempotency_key, metadata, global_seq
                \\FROM events
                \\WHERE instance_id = $1
                \\  AND (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint <= $2
                \\ORDER BY sequence_number ASC
            ,
                &.{
                    uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed,
                    intToStr(param_alloc, opts.up_to_timestamp.?) catch return StoreError.TransactionFailed,
                },
            ) catch return StoreError.TransactionFailed;
            defer {
                var mr = rows;
                mr.deinit();
            }
            return rowsToEventRecords(allocator, rows.rows);
        }

        // No filters.
        const rows = conn.query(
            allocator,
            \\SELECT event_id, instance_id, event_type, payload, actor_id,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       sequence_number, idempotency_key, metadata, global_seq
            \\FROM events
            \\WHERE instance_id = $1
            \\ORDER BY sequence_number ASC
        ,
            &.{
                uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed,
            },
        ) catch return StoreError.TransactionFailed;
        defer {
            var mr = rows;
            mr.deinit();
        }
        return rowsToEventRecords(allocator, rows.rows);
    }

    // -----------------------------------------------------------------------
    // readGlobal (ES-04)
    // -----------------------------------------------------------------------

    /// Return events across all instances ordered by global_seq.
    ///
    /// Supports cursor-based pagination via GlobalReadOpts.after_global_seq.
    /// All parameters use $N placeholders — no string interpolation. (security)
    pub fn readGlobal(
        self: *Store,
        allocator: std.mem.Allocator,
        opts: GlobalReadOpts,
    ) StoreError![]EventRecord {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const page_size: u32 = if (opts.limit == 0 or opts.limit > 1000) 100 else opts.limit;
        const cursor: i64 = opts.after_global_seq orelse 0;
        const pipeline_filter = opts.pipeline_run_id orelse "";

        // Parameterised query — no string interpolation. (ES-04, security)
        const rows = conn.query(
            allocator,
            \\SELECT event_id, instance_id, event_type, payload, actor_id,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       sequence_number, idempotency_key, metadata, global_seq
            \\FROM events
            \\WHERE global_seq > $1
            \\  AND ($3::text = '' OR metadata->>'pipeline_run_id' = $3)
            \\ORDER BY global_seq ASC
            \\LIMIT $2
        ,
            &.{
                intToStr(param_alloc, cursor) catch return StoreError.TransactionFailed,
                uintToStr(param_alloc, page_size) catch return StoreError.TransactionFailed,
                pipeline_filter,
            },
        ) catch return StoreError.TransactionFailed;
        defer {
            var mr = rows;
            mr.deinit();
        }
        return rowsToEventRecords(allocator, rows.rows);
    }

    // -----------------------------------------------------------------------
    // readHistory (API-05, ES-07)
    // -----------------------------------------------------------------------

    /// Read history for an instance, spanning both `events` and `events_archive`.
    /// Returns events in ascending sequence_number order.
    ///
    /// Covers: API-05 (history endpoint), ES-07 (archived event inclusion).
    ///
    /// Returns InstanceNotFound if instance_id does not exist in instance_projections.
    /// Returns empty list if instance exists but has no events matching the filters.
    /// All SQL uses $N placeholders — no string interpolation. (security)
    pub fn readHistory(
        self: *Store,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        opts: HistoryReadOpts,
    ) StoreError![]EventRecord {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Verify instance exists (API-05: 404 if not found).
        const check = conn.query(
            allocator,
            "SELECT 1 FROM instance_projections WHERE instance_id = $1",
            &.{uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed},
        ) catch return StoreError.TransactionFailed;
        defer {
            var mr = check;
            mr.deinit();
        }
        if (check.rows.len == 0) return StoreError.InstanceNotFound;

        // Build the UNION ALL query dynamically based on which filters are present.
        // Inner SELECT from events:
        //   SELECT event_id, instance_id, event_type, payload, actor_id,
        //          created_at, sequence_number, idempotency_key, metadata, global_seq
        //   FROM events WHERE instance_id = $1 [AND filters...]
        // UNION ALL
        //   SELECT event_id, instance_id, event_type, payload, actor_id,
        //          created_at, sequence_number, idempotency_key, metadata, global_seq
        //   FROM events_archive WHERE instance_id = $1 [AND filters...]
        // Outer SELECT converts created_at → created_at_us via EXTRACT(EPOCH).
        // Additional WHERE on sequence_number for cursor, ORDER BY sequence_number ASC, LIMIT.

        const instance_hex = uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed;

        // Build filter conditions and parameter values.
        // We'll append to params list and build WHERE clauses.

        var params_list: std.ArrayList([]const u8) = .empty;
        defer params_list.deinit(allocator);

        // $1 = instance_id
        params_list.append(allocator, instance_hex) catch return StoreError.TransactionFailed;

        // event_type filter ($2 for events, reused for archive)
        if (opts.event_type) |et| {
            params_list.append(allocator, et) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // from filter ($3 for events, reused for archive)
        if (opts.from) |f| {
            params_list.append(allocator, intToStr(param_alloc, f) catch return StoreError.TransactionFailed) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // to filter ($4 for events, reused for archive)
        if (opts.to) |t| {
            params_list.append(allocator, intToStr(param_alloc, t) catch return StoreError.TransactionFailed) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // pipeline_run_id filter ($5)
        if (opts.pipeline_run_id) |prid| {
            params_list.append(allocator, prid) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // after_sequence cursor ($6)
        if (opts.after_sequence) |as| {
            params_list.append(allocator, intToStr(param_alloc, as) catch return StoreError.TransactionFailed) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // limit ($7) — fetch page_size + 1 to detect next page
        const fetch_limit: u16 = if (opts.limit < 200) opts.limit + 1 else opts.limit;
        params_list.append(allocator, intToStr(param_alloc, @as(i64, fetch_limit)) catch return StoreError.TransactionFailed) catch return StoreError.TransactionFailed;

        // Build the dynamic SQL.  We use the PostgreSQL extended query protocol,
        // so parameter count must match the number of $N references.
        // Strategy: always use $N references, and when a filter is absent we use
        // a condition that is always true (e.g. $2::text = '' meaning no filter).

        const sql =
            \\SELECT event_id, instance_id, event_type, payload, actor_id,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
            \\       sequence_number, idempotency_key, metadata, global_seq
            \\FROM (
            \\    SELECT event_id, instance_id, event_type, payload, actor_id,
            \\           created_at, sequence_number, idempotency_key, metadata, global_seq
            \\    FROM events
            \\    WHERE instance_id = $1
            \\      AND ($2::text = '' OR event_type = $2)
            \\      AND ($3::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint >= $3::bigint)
            \\      AND ($4::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint <= $4::bigint)
            \\      AND ($5::text = '' OR metadata->>'pipeline_run_id' = $5)
            \\    UNION ALL
            \\    SELECT event_id, instance_id, event_type, payload, actor_id,
            \\           created_at, sequence_number, idempotency_key, metadata, global_seq
            \\    FROM events_archive
            \\    WHERE instance_id = $1
            \\      AND ($2::text = '' OR event_type = $2)
            \\      AND ($3::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint >= $3::bigint)
            \\      AND ($4::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint <= $4::bigint)
            \\      AND ($5::text = '' OR metadata->>'pipeline_run_id' = $5)
            \\) AS combined
            \\WHERE ($6::text = '' OR sequence_number > $6::bigint)
            \\ORDER BY sequence_number ASC
            \\LIMIT $7
        ;

        const rows = conn.query(
            allocator,
            sql,
            params_list.items,
        ) catch return StoreError.TransactionFailed;
        defer {
            var mr = rows;
            mr.deinit();
        }

        return rowsToEventRecords(allocator, rows.rows);
    }

    // -----------------------------------------------------------------------
    // pointInTime (ES-06)
    // -----------------------------------------------------------------------

    /// Return events for instance_id with created_at ≤ before (UTC microseconds).
    ///
    /// Convenience wrapper over read() with ReadOpts.up_to_timestamp = before.
    pub fn pointInTime(
        self: *Store,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
        before: i64,
    ) StoreError![]EventRecord {
        return self.read(allocator, instance_id, ReadOpts{
            .up_to_sequence = null,
            .up_to_timestamp = before,
        });
    }

    // -----------------------------------------------------------------------
    // retention policy configuration (ES-07, ADP-11)
    // -----------------------------------------------------------------------

    /// Upsert retention policy with deterministic ADP-11 guardrails.
    ///
    /// Protected replay-critical event families ({INSTANCE_*, TASK_*,
    /// GATEWAY_*, EXECUTION_*}) reject hard-delete modes at configuration
    /// time using a typed error. Non-protected families preserve ES-07
    /// configurability, including hard-delete modes.
    pub fn upsertRetentionPolicy(
        self: *Store,
        allocator: std.mem.Allocator,
        params: RetentionPolicyUpsertParams,
    ) StoreError!void {
        // ES-07/ADP-11 validation, shared with unit tests (ISS-0148).
        try validateRetentionPolicyParams(allocator, params);

        const normalized_event_type = normalizeEventType(allocator, params.event_type) catch return StoreError.TransactionFailed;
        defer allocator.free(normalized_event_type);

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();

        const keep_days_text: []const u8 = if (params.keep_days) |v|
            uintToStr(param_alloc, v) catch return StoreError.TransactionFailed
        else
            "";

        const keep_count_text: []const u8 = if (params.keep_count) |v|
            uintToStr(param_alloc, v) catch return StoreError.TransactionFailed
        else
            "";

        conn.exec(
            "INSERT INTO event_retention_policies (event_type, policy, keep_days, keep_count, updated_at) " ++
                "VALUES ($1, $2, NULLIF($3, '')::integer, NULLIF($4, '')::integer, NOW()) " ++
                "ON CONFLICT (event_type) DO UPDATE SET " ++
                "policy = EXCLUDED.policy, keep_days = EXCLUDED.keep_days, " ++
                "keep_count = EXCLUDED.keep_count, updated_at = NOW()",
            &.{
                normalized_event_type,
                retentionPolicyModeToSql(params.policy),
                keep_days_text,
                keep_count_text,
            },
        ) catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
    }

    // -----------------------------------------------------------------------
    // archive() retired — PAR-03 (this batch, WF02-batch-3-20260811)
    // -----------------------------------------------------------------------
    // Store.archive() (ES-07's row-level archival-move mechanics) has been
    // REMOVED. Its DELETE FROM events / DELETE FROM events_archive-adjacent
    // pattern is incompatible with PAR-03's "No DELETE statement SHALL run
    // against events or events_archive at any point" rule. The mechanism it
    // implemented is superseded by PartitionRetention.runArchivalAging() /
    // runEphemeralDrop() (src/scheduler/partition_retention.zig), which
    // operate at whole-PARTITION granularity via DETACH/ATTACH/DROP rather
    // than row-level DELETE. See src/design/par-03-partition-scoped-
    // retention.md's "Store.archive() retirement" section for the full
    // removal scope, the verified zero-call-site finding (confirmed: the
    // three `store.archive(...)` sites in src/api/routes/definitions.zig
    // resolve to the UNRELATED definition.Store.archive(),
    // src/definition/store.zig, a workflow-definition status transition with
    // no events/events_archive interaction), and the disposition of its
    // former dependent tests (TC-ES-07-01, TC-ES-07-02, TC-ADP-11-02,
    // TC-ADP-11-03 in tests/integration/event_store_integration_test.zig,
    // rewritten to assert the retirement and exercise PartitionRetention
    // instead). upsertRetentionPolicy() (above) is NOT removed — it
    // implements ADP-11's config-time rejection AC, which does not touch
    // events/events_archive rows and is not in conflict with PAR-03.
};

// ---------------------------------------------------------------------------
// Row parsing helpers (placeholders for when pg.zig returns real rows)
// ---------------------------------------------------------------------------

fn rowToEventRecord(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    idempotency_key: []const u8,
) error{OutOfMemory}!EventRecord {
    // Columns: event_id, instance_id, event_type, payload, actor_id,
    //          created_at_us, sequence_number, idempotency_key, metadata, global_seq
    const event_type = try allocator.dupe(u8, if (row.len > 2) row[2] orelse "unknown" else "unknown");
    errdefer allocator.free(event_type);
    const payload = try allocator.dupe(u8, if (row.len > 3) row[3] orelse "{}" else "{}");
    errdefer allocator.free(payload);
    const seq = if (row.len > 6) blk: {
        const s = row[6] orelse "0";
        break :blk std.fmt.parseInt(i64, s, 10) catch 0;
    } else 0;
    const created_at = if (row.len > 5) blk: {
        const s = row[5] orelse "0";
        break :blk std.fmt.parseInt(i64, s, 10) catch 0;
    } else 0;
    const metadata = try allocator.dupe(u8, if (row.len > 8) row[8] orelse "{}" else "{}");
    const global_seq = if (row.len > 9) blk: {
        const s = row[9] orelse "0";
        break :blk std.fmt.parseInt(i64, s, 10) catch 0;
    } else 0;

    return EventRecord{
        .event_id = std.mem.zeroes(Uuid),
        .instance_id = std.mem.zeroes(Uuid),
        .event_type = event_type,
        .payload = payload,
        .actor_id = std.mem.zeroes(Uuid),
        .created_at = created_at,
        .sequence_number = seq,
        .idempotency_key = idempotency_key,
        .metadata = metadata,
        .global_seq = global_seq,
    };
}

fn duplicateFromParams(allocator: std.mem.Allocator, params: AppendParams, sequence_number: i64, metadata: []const u8) EventRecord {
    // ES-08: the caller-visible record must carry the effective metadata
    // (params.metadata orelse "{}"), not a hardcoded placeholder — a prior
    // version discarded the `metadata` argument entirely (`_ = metadata;`),
    // so every successful append() returned `.metadata = ""` regardless of
    // what was actually inserted. `metadata` here may be arena-scoped
    // (validateAppendParams' return value), so it must be duplicated with
    // the long-lived `allocator` before being stored on the returned
    // EventRecord. Degrade to "" on allocation failure, matching this
    // function's existing infallible-fallback contract (it is used as a
    // `catch` expression and cannot itself return an error).
    const owned_metadata = allocator.dupe(u8, metadata) catch "";
    return EventRecord{
        .event_id = std.mem.zeroes(Uuid),
        .instance_id = params.instance_id,
        .event_type = "",
        .payload = "",
        .actor_id = params.actor_id,
        .created_at = 0,
        .sequence_number = sequence_number,
        .idempotency_key = params.idempotency_key,
        .metadata = owned_metadata,
        .global_seq = 0,
    };
}

fn currentRequestPipelineRunId() []const u8 {
    return pipeline_context_mod.get();
}

fn metadataPipelineRunId(allocator: std.mem.Allocator, metadata: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, metadata, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const pipeline_id = parsed.value.object.get("pipeline_run_id") orelse return null;
    if (pipeline_id != .string) return null;
    return try allocator.dupe(u8, pipeline_id.string);
}

fn rowsToEventRecords(allocator: std.mem.Allocator, rows: [][]?[]u8) StoreError![]EventRecord {
    const records = allocator.alloc(EventRecord, rows.len) catch return StoreError.TransactionFailed;
    var i: usize = 0;
    errdefer {
        for (records[0..i]) |rec| {
            allocator.free(rec.event_type);
            allocator.free(rec.payload);
            allocator.free(rec.metadata);
        }
        allocator.free(records);
    }
    while (i < rows.len) : (i += 1) {
        records[i] = rowToEventRecord(allocator, rows[i], "") catch return StoreError.TransactionFailed;
    }
    return records;
}

// ---------------------------------------------------------------------------
// Module-level helpers
// ---------------------------------------------------------------------------

/// Return true if bytes is a JSON object (starts with '{').
fn isJsonObject(bytes: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, bytes, &std.ascii.whitespace);
    return trimmed.len > 0 and trimmed[0] == '{';
}

/// Return true if all 16 bytes of the UUID are zero.
fn isNilUuid(uuid: Uuid) bool {
    return std.mem.allEqual(u8, &uuid, 0);
}

pub fn retentionPolicyErrorCode(err: StoreError) ?[]const u8 {
    return switch (err) {
        StoreError.ProtectedFamilyHardDeleteForbidden => "RETENTION_POLICY_PROTECTED_FAMILY_HARD_DELETE_FORBIDDEN",
        StoreError.InvalidRetentionPolicyValue => "RETENTION_POLICY_INPUT_INVALID",
        else => null,
    };
}

pub fn retentionPolicyViolation(event_type: []const u8, policy: RetentionPolicyMode) ?RetentionPolicyViolation {
    if (!isProtectedEventFamily(event_type)) return null;
    if (!retentionPolicyModeIsHardDelete(policy)) return null;

    return RetentionPolicyViolation{
        .code = "RETENTION_POLICY_PROTECTED_FAMILY_HARD_DELETE_FORBIDDEN",
        .title = "Retention policy rejected",
        .detail = "Hard-delete retention is forbidden for protected replay-critical event families.",
        .reason = "HARD_DELETE_NOT_ALLOWED_FOR_PROTECTED_FAMILY",
        .event_family = protectedFamilyLabel(event_type),
        .allowed_modes = .{ "keep_forever", "keep_days", "keep_count" },
        .requested_mode = retentionPolicyModeToSql(policy),
        .event_type = event_type,
    };
}

fn validateRetentionPolicyUpsert(normalized_event_type: []const u8, params: RetentionPolicyUpsertParams) StoreError!void {
    switch (params.policy) {
        .keep_forever => {
            if (params.keep_days != null or params.keep_count != null) {
                return StoreError.InvalidRetentionPolicyValue;
            }
        },
        .keep_days, .hard_delete_days => {
            if (params.keep_days == null or params.keep_count != null) {
                return StoreError.InvalidRetentionPolicyValue;
            }
        },
        .keep_count, .hard_delete_count => {
            if (params.keep_count == null or params.keep_days != null) {
                return StoreError.InvalidRetentionPolicyValue;
            }
        },
    }

    if (isProtectedEventFamily(normalized_event_type) and retentionPolicyModeIsHardDelete(params.policy)) {
        return StoreError.ProtectedFamilyHardDeleteForbidden;
    }
}

fn retentionPolicyModeIsHardDelete(policy: RetentionPolicyMode) bool {
    return switch (policy) {
        .hard_delete_days, .hard_delete_count => true,
        else => false,
    };
}

fn retentionPolicyModeToSql(policy: RetentionPolicyMode) []const u8 {
    return switch (policy) {
        .keep_forever => "keep_forever",
        .keep_days => "keep_days",
        .keep_count => "keep_count",
        .hard_delete_days => "hard_delete_days",
        .hard_delete_count => "hard_delete_count",
    };
}

fn normalizeEventType(allocator: std.mem.Allocator, event_type: []const u8) error{OutOfMemory}![]u8 {
    const trimmed = std.mem.trim(u8, event_type, &std.ascii.whitespace);
    var normalized = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |ch, i| {
        normalized[i] = std.ascii.toUpper(ch);
    }
    return normalized;
}

fn isProtectedEventFamily(event_type: []const u8) bool {
    return std.mem.startsWith(u8, event_type, "INSTANCE_") or
        std.mem.startsWith(u8, event_type, "TASK_") or
        std.mem.startsWith(u8, event_type, "GATEWAY_") or
        std.mem.startsWith(u8, event_type, "EXECUTION_");
}

fn protectedFamilyLabel(event_type: []const u8) []const u8 {
    if (std.mem.startsWith(u8, event_type, "INSTANCE_")) return "INSTANCE_*";
    if (std.mem.startsWith(u8, event_type, "TASK_")) return "TASK_*";
    if (std.mem.startsWith(u8, event_type, "GATEWAY_")) return "GATEWAY_*";
    if (std.mem.startsWith(u8, event_type, "EXECUTION_")) return "EXECUTION_*";
    return "UNKNOWN";
}

// ---------------------------------------------------------------------------
// Pre-write validation surface (ISS-0148)
//
// append() performs a block of purely in-process validation before it touches
// the pool (Invariant #9: "all checks are in-process before any SQL").  Those
// checks are the executable statement of ES-01/ES-03/ES-08's rejection rules,
// but they lived behind private `fn`s, so the only way to reach them was an
// append() call — which needs a live DB.  That is why ES-01/ES-03/ES-08's
// unit-level cases sat as SkipZigTest stubs.
//
// validateAppendParams is not a reimplementation of those rules: append()
// calls it, so a unit test that calls it exercises exactly the bytes that run
// in production.  Anything requiring instance state, sequence assignment, or
// idempotency lookup remains DB-bound and is covered in
// tests/integration/event_store_integration_test.zig.
// ---------------------------------------------------------------------------

/// Run every pre-write validation append() applies before acquiring a
/// connection, in append()'s exact order. Returns the effective metadata
/// (params.metadata orelse "{}") on success — ES-08's default-to-{} rule.
pub fn validateAppendParams(
    allocator: std.mem.Allocator,
    params: AppendParams,
) StoreError![]const u8 {
    // ES-01: actor_id must be non-nil.
    if (isNilUuid(params.actor_id)) return StoreError.ActorIdMissing;

    // ES-03: idempotency_key constraints.
    if (params.idempotency_key.len == 0) return StoreError.IdempotencyKeyMissing;
    if (params.idempotency_key.len > 255) return StoreError.IdempotencyKeyTooLong;

    if (params.tenant_id.len == 0) return StoreError.MissingTenantContext;

    // ES-01: payload must be a JSON object (not null, array, or scalar).
    if (!isJsonObject(params.payload)) return StoreError.PayloadInvalid;

    // ES-08: metadata constraints.
    const metadata = params.metadata orelse "{}";
    try validateMetadata(allocator, metadata);

    return metadata;
}

/// Validate a retention policy upsert (ES-07 / ADP-11) without touching the DB.
/// Normalises event_type the same way upsertRetentionPolicy does.
pub fn validateRetentionPolicyParams(
    allocator: std.mem.Allocator,
    params: RetentionPolicyUpsertParams,
) StoreError!void {
    if (params.event_type.len == 0) return StoreError.InvalidRetentionPolicyValue;
    const normalized = normalizeEventType(allocator, params.event_type) catch
        return StoreError.TransactionFailed;
    defer allocator.free(normalized);
    try validateRetentionPolicyUpsert(normalized, params);
}

/// Validate metadata JSON object constraints (ES-08).
/// All checks are in-process before any SQL (Invariant #9).
/// Enforces: is JSON object, ≤50 entries, keys ≤128 chars, values are strings ≤1024 chars.
fn validateMetadata(allocator: std.mem.Allocator, metadata: []const u8) StoreError!void {
    if (!isJsonObject(metadata)) return StoreError.MetadataInvalid;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, metadata, .{}) catch
        return StoreError.MetadataInvalid;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return StoreError.MetadataInvalid,
    };
    if (obj.count() > 50) return StoreError.MetadataInvalid;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.len > 128) return StoreError.MetadataInvalid;
        switch (entry.value_ptr.*) {
            .string => |s| if (s.len > 1024) return StoreError.MetadataInvalid,
            else => return StoreError.MetadataInvalid,
        }
    }
}

/// Render a UUID as a lowercase hex string with hyphens: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
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

/// Serialise a signed integer to a decimal string owned by allocator.
fn intToStr(allocator: std.mem.Allocator, value: i64) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

/// Serialise an unsigned integer to a decimal string owned by allocator.
fn uintToStr(allocator: std.mem.Allocator, value: u32) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}
