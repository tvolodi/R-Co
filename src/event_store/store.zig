//! Event store — ES-01, ES-02, ES-03, ES-04, ES-05, ES-06, ES-07, ES-08
//!
//! Append-only log of typed, immutable events.  All writes go through a single
//! transaction (DB-03).  Idempotency is enforced at the DB level via a UNIQUE
//! index on events(idempotency_key) and a fallback check in events_archive
//! (Invariant #5 in the design artefact).
//!
//! Design artefact: src/design/event_store.md
const std = @import("std");
const db = @import("../db/pool.zig");
const root = @import("root");
const Pool = db.Pool;
const PoolError = db.PoolError;
const registry_mod = @import("registry.zig");
const Registry = registry_mod.Registry;
const metrics = @import("../obs/metrics.zig");

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

pub const ReadOpts = struct {
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
    /// Return events with sequence_number ≤ value; null = no upper limit (ES-06).
    up_to_sequence: ?i64,
    /// Return events with created_at ≤ value (UTC µs); null = no upper limit (ES-06).
    /// If both are set, up_to_sequence takes precedence (ES-06).
    up_to_timestamp: ?i64,
};

pub const GlobalReadOpts = struct {
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
    /// Resume cursor: return events with global_seq > value; null = from start (ES-04).
    after_global_seq: ?i64,
    /// Optional correlation filter for ADP-06 metadata propagation.
    pipeline_run_id: ?[]const u8 = null,
    /// Page size; 1..1000; 0 treated as default 100 (ES-04).
    limit: u32,
};

pub const HistoryReadOpts = struct {
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
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
        const append_started_ms: i64 = std.Io.Clock.real.now(self.pool.io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self.pool.io).toMilliseconds() - append_started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            metrics.recordEventAppendDurationSeconds(elapsed_s);
        }

        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();
        // --- Pre-write validation (no DB writes below this line) ---

        // ES-01: actor_id must be non-nil.
        if (isNilUuid(params.actor_id)) return StoreError.ActorIdMissing;

        // ES-03: idempotency_key constraints.
        if (params.idempotency_key.len == 0) return StoreError.IdempotencyKeyMissing;
        if (params.idempotency_key.len > 255) return StoreError.IdempotencyKeyTooLong;

        if (params.tenant_id.len == 0) return StoreError.MissingTenantContext;

        // ES-01: payload must be a JSON object (not null, array, or scalar).
        if (!isJsonObject(params.payload)) return StoreError.PayloadInvalid;

        // ES-08: metadata constraints (all validated before any SQL).
        const metadata = params.metadata orelse "{}";
        try validateMetadata(metadata);

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

        // --- Transaction ---

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

        // Step 3: INSERT event with ON CONFLICT DO NOTHING (ES-03, ES-04).
        // All columns use $N placeholders — no string interpolation. (security)
        const large_payload = params.payload.len > 4096;
        const stored_payload = if (large_payload)
            // Placeholder ref; real side-table logic pending pg.zig.
            "{\"$ref\":\"pending\"}"
        else
            params.payload;

        const insert_rows = conn.query(
            allocator,
            \\INSERT INTO events
            \\  (instance_id, event_type, payload, actor_id,
            \\sequence_number, idempotency_key, metadata, tenant_id,
            \\   global_seq)
            \\VALUES
            \\  ($1, $2, $3::jsonb, $4,
            \\   $5, $6,
            \\   CASE
            \\     WHEN $9::text = '' THEN $7::jsonb
            \\     ELSE jsonb_set($7::jsonb, '{pipeline_run_id}', to_jsonb($9::text), true)
            \\   END,
            \\   $8::uuid,
            \\   nextval('events_global_seq'))
            \\ON CONFLICT (idempotency_key) DO NOTHING
            \\RETURNING
            \\  event_id, instance_id, event_type, payload, actor_id,
            \\  (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint AS created_at_us,
            \\  sequence_number, idempotency_key, metadata, global_seq
        ,
            &.{
                uuidToHex(param_alloc, params.instance_id) catch return StoreError.TransactionFailed,
                params.event_type,
                stored_payload,
                uuidToHex(param_alloc, params.actor_id) catch return StoreError.TransactionFailed,
                intToStr(param_alloc, sequence_number) catch return StoreError.TransactionFailed,
                params.idempotency_key,
                metadata,
                params.tenant_id,
                effective_pipeline_run_id,
            },
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };
        defer {
            var mr = insert_rows;
            mr.deinit();
        }

        // If RETURNING yielded no rows, this is a duplicate.
        if (insert_rows.rows.len == 0) {
            conn.exec("ROLLBACK", &.{}) catch {};
            // Invariant #5: check events_archive for post-archival duplicate.
            // Query only the scalar sequence_number to avoid dangling string
            // pointers from rowToEventRecord. (ES-03, security: parameterised)
            const dup_conn = self.pool.acquire() catch return StoreError.TransactionFailed;
            defer self.pool.release(dup_conn);

            const orig_seq: i64 = orig_blk: {
                // Check live events table first.
                const live_seq_rows = dup_conn.query(
                    allocator,
                    "SELECT sequence_number FROM events WHERE idempotency_key = $1",
                    &.{params.idempotency_key},
                ) catch break :orig_blk sequence_number;
                defer {
                    var mr = live_seq_rows;
                    mr.deinit();
                }
                if (live_seq_rows.rows.len > 0 and live_seq_rows.rows[0].len > 0) {
                    if (live_seq_rows.rows[0][0]) |s|
                        break :orig_blk std.fmt.parseInt(i64, s, 10) catch sequence_number;
                }
                // Check events_archive (post-archival duplicate).
                const arch_seq_rows = dup_conn.query(
                    allocator,
                    "SELECT sequence_number FROM events_archive WHERE idempotency_key = $1",
                    &.{params.idempotency_key},
                ) catch break :orig_blk sequence_number;
                defer {
                    var mr = arch_seq_rows;
                    mr.deinit();
                }
                if (arch_seq_rows.rows.len > 0 and arch_seq_rows.rows[0].len > 0) {
                    if (arch_seq_rows.rows[0][0]) |s|
                        break :orig_blk std.fmt.parseInt(i64, s, 10) catch sequence_number;
                }
                break :orig_blk sequence_number;
            };
            return AppendResult{
                .record = duplicateFromParams(params, orig_seq, metadata),
                .is_duplicate = true,
            };
        }

        // Step 4: Large payload side-table insert (NFR-05, ES-01).
        if (large_payload) {
            conn.exec(
                "INSERT INTO event_payload_store (event_id, payload, byte_size) VALUES ($1, $2, $3)",
                &.{
                    "pending-event-id", // real event_id from RETURNING row
                    params.payload,
                    intToStr(param_alloc, @as(i64, @intCast(params.payload.len))) catch return StoreError.TransactionFailed,
                },
            ) catch {
                conn.exec("ROLLBACK", &.{}) catch {};
                return StoreError.TransactionFailed;
            };
        }

        // Step 5: UPDATE instance_projections (last_event_seq, updated_at). (DB-03)
        // Parameterised — no interpolation. (security)
        conn.exec(
            \\UPDATE instance_projections
            \\SET last_event_seq = $1, updated_at = NOW()
            \\WHERE instance_id = $2
        ,
            &.{
                intToStr(param_alloc, sequence_number) catch return StoreError.TransactionFailed,
                uuidToHex(param_alloc, params.instance_id) catch return StoreError.TransactionFailed,
            },
        ) catch {
            conn.exec("ROLLBACK", &.{}) catch {};
            return StoreError.TransactionFailed;
        };

        // COMMIT
        conn.exec("COMMIT", &.{}) catch return StoreError.TransactionFailed;

        // Build EventRecord from params (stable memory; avoids borrowing from
        // insert_rows which is freed by defer before the caller can read strings).
        const record = duplicateFromParams(params, sequence_number, metadata);

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
                \\  AND tenant_id = $2::uuid
                \\  AND sequence_number <= $3::bigint
                \\ORDER BY sequence_number ASC
            ,
                &.{
                    uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed,
                    opts.tenant_id,
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
                \\  AND tenant_id = $2::uuid
                \\  AND (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint <= $3
                \\ORDER BY sequence_number ASC
            ,
                &.{
                    uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed,
                    opts.tenant_id,
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
            \\WHERE instance_id = $1 AND tenant_id = $2::uuid
            \\ORDER BY sequence_number ASC
        ,
            &.{
                uuidToHex(param_alloc, instance_id) catch return StoreError.TransactionFailed,
                opts.tenant_id,
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
            \\WHERE global_seq > $1 AND tenant_id = $2::uuid
            \\  AND ($4::text = '' OR metadata->>'pipeline_run_id' = $4)
            \\ORDER BY global_seq ASC
            \\LIMIT $3
        ,
            &.{
                intToStr(param_alloc, cursor) catch return StoreError.TransactionFailed,
                opts.tenant_id,
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

        // $2 = tenant_id
        params_list.append(allocator, opts.tenant_id) catch return StoreError.TransactionFailed;

        // event_type filter ($3 for events, reused for archive)
        if (opts.event_type) |et| {
            params_list.append(allocator, et) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // from filter ($4 for events, reused for archive)
        if (opts.from) |f| {
            params_list.append(allocator, intToStr(param_alloc, f) catch return StoreError.TransactionFailed) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // to filter ($5 for events, reused for archive)
        if (opts.to) |t| {
            params_list.append(allocator, intToStr(param_alloc, t) catch return StoreError.TransactionFailed) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // pipeline_run_id filter ($6)
        if (opts.pipeline_run_id) |prid| {
            params_list.append(allocator, prid) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // after_sequence cursor ($7)
        if (opts.after_sequence) |as| {
            params_list.append(allocator, intToStr(param_alloc, as) catch return StoreError.TransactionFailed) catch return StoreError.TransactionFailed;
        } else {
            params_list.append(allocator, "") catch return StoreError.TransactionFailed;
        }

        // limit ($8) — fetch page_size + 1 to detect next page
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
            \\      AND tenant_id = $2::uuid
            \\      AND ($3::text = '' OR event_type = $3)
            \\      AND ($4::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint >= $4::bigint)
            \\      AND ($5::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint <= $5::bigint)
            \\      AND ($6::text = '' OR metadata->>'pipeline_run_id' = $6)
            \\    UNION ALL
            \\    SELECT event_id, instance_id, event_type, payload, actor_id,
            \\           created_at, sequence_number, idempotency_key, metadata, global_seq
            \\    FROM events_archive
            \\    WHERE instance_id = $1
            \\      AND tenant_id = $2::uuid
            \\      AND ($3::text = '' OR event_type = $3)
            \\      AND ($4::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint >= $4::bigint)
            \\      AND ($5::text = '' OR (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint <= $5::bigint)
            \\      AND ($6::text = '' OR metadata->>'pipeline_run_id' = $6)
            \\) AS combined
            \\WHERE ($7::text = '' OR sequence_number > $7::bigint)
            \\ORDER BY sequence_number ASC
            \\LIMIT $8
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
    // archive (ES-07)
    // -----------------------------------------------------------------------

    /// Move expired events to events_archive per event_retention_policies.
    ///
    /// retention_days is the global fallback applied to event types with no
    /// registered policy when retention_days > 0.  0 = only registered policies.
    /// Returns the total number of event rows moved.
    ///
    /// Archival invariants (Invariant #11, #12):
    ///  - INSERT events_archive … ON CONFLICT DO NOTHING ensures idempotency.
    ///  - Rows are deleted from events ONLY after confirming presence in archive.
    ///  - No lock on instance_projections or instance_sequence.
    pub fn archive(
        self: *Store,
        allocator: std.mem.Allocator,
        retention_days: u32,
    ) StoreError!u64 {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const param_alloc = param_arena.allocator();
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return StoreError.PoolExhausted,
            else => return StoreError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var total_moved: u64 = 0;

        // Fetch all retention policies.
        // Parameterised — no string interpolation. (security)
        const policies = conn.query(
            allocator,
            "SELECT event_type, policy, keep_days, keep_count FROM event_retention_policies",
            &.{},
        ) catch return StoreError.TransactionFailed;
        defer {
            var mr = policies;
            mr.deinit();
        }

        for (policies.rows) |policy_row| {
            if (policy_row.len < 4) continue;
            const event_type = policy_row[0] orelse continue;
            const policy = policy_row[1] orelse continue;

            if (std.mem.eql(u8, policy, "keep_forever")) continue;

            if (std.mem.eql(u8, policy, "keep_days")) {
                const keep_days_str = policy_row[2] orelse continue;
                const keep_days = std.fmt.parseInt(i64, keep_days_str, 10) catch continue;
                // Move rows older than keep_days.
                // Parameterised. (ES-07, security)
                conn.exec(
                    \\INSERT INTO events_archive
                    \\  (event_id, instance_id, event_type, payload, actor_id,
                    \\   created_at, sequence_number, idempotency_key, metadata, global_seq,
                    \\   archived_at, tenant_id)
                    \\  SELECT event_id, instance_id, event_type, payload, actor_id,
                    \\         created_at, sequence_number, idempotency_key, metadata, global_seq,
                    \\         NOW() AS archived_at, tenant_id
                    \\  FROM events
                    \\  WHERE event_type = $1
                    \\    AND created_at <= NOW() - ($2 || ' days')::interval
                    \\ON CONFLICT (idempotency_key) DO NOTHING
                ,
                    &.{
                        event_type,
                        intToStr(param_alloc, keep_days) catch continue,
                    },
                ) catch continue;
                // Delete only rows confirmed in archive. (Invariant #11)
                conn.exec(
                    \\DELETE FROM events e
                    \\WHERE event_type = $1
                    \\  AND created_at <= NOW() - ($2 || ' days')::interval
                    \\  AND EXISTS (
                    \\    SELECT 1 FROM events_archive ea
                    \\    WHERE ea.idempotency_key = e.idempotency_key
                    \\  )
                ,
                    &.{
                        event_type,
                        intToStr(param_alloc, keep_days) catch continue,
                    },
                ) catch continue;
                total_moved += 1; // real count from DELETE RETURNING not available yet
            } else if (std.mem.eql(u8, policy, "keep_count")) {
                const keep_count_str = policy_row[3] orelse continue;
                const keep_count = std.fmt.parseInt(i64, keep_count_str, 10) catch continue;
                // Move rows beyond the keep_count most recent.
                // Parameterised. (ES-07, security)
                conn.exec(
                    \\INSERT INTO events_archive
                    \\  (event_id, instance_id, event_type, payload, actor_id,
                    \\   created_at, sequence_number, idempotency_key, metadata, global_seq,
                    \\   archived_at, tenant_id)
                    \\  SELECT event_id, instance_id, event_type, payload, actor_id,
                    \\         created_at, sequence_number, idempotency_key, metadata, global_seq,
                    \\         NOW() AS archived_at, tenant_id
                    \\  FROM events
                    \\  WHERE event_type = $1
                    \\    AND event_id NOT IN (
                    \\      SELECT event_id FROM events
                    \\      WHERE event_type = $1
                    \\      ORDER BY sequence_number DESC
                    \\      LIMIT $2
                    \\    )
                    \\ON CONFLICT (idempotency_key) DO NOTHING
                ,
                    &.{
                        event_type,
                        intToStr(param_alloc, keep_count) catch continue,
                    },
                ) catch continue;
                conn.exec(
                    \\DELETE FROM events e
                    \\WHERE event_type = $1
                    \\  AND e.event_id NOT IN (
                    \\    SELECT event_id FROM events
                    \\    WHERE event_type = $1
                    \\    ORDER BY sequence_number DESC
                    \\    LIMIT $2
                    \\  )
                    \\  AND EXISTS (
                    \\    SELECT 1 FROM events_archive ea
                    \\    WHERE ea.idempotency_key = e.idempotency_key
                    \\  )
                ,
                    &.{
                        event_type,
                        intToStr(param_alloc, keep_count) catch continue,
                    },
                ) catch continue;
                total_moved += 1;
            }
        }

        // Apply global fallback retention.
        if (retention_days > 0) {
            conn.exec(
                \\INSERT INTO events_archive
                \\  (event_id, instance_id, event_type, payload, actor_id,
                \\   created_at, sequence_number, idempotency_key, metadata, global_seq,
                \\   archived_at, tenant_id)
                \\  SELECT event_id, instance_id, event_type, payload, actor_id,
                \\         created_at, sequence_number, idempotency_key, metadata, global_seq,
                \\         NOW() AS archived_at, tenant_id
                \\  FROM events
                \\  WHERE created_at <= NOW() - ($1 || ' days')::interval
                \\    AND event_type NOT IN (
                \\      SELECT event_type FROM event_retention_policies
                \\    )
                \\ON CONFLICT (idempotency_key) DO NOTHING
            ,
                &.{uintToStr(param_alloc, retention_days) catch return StoreError.TransactionFailed},
            ) catch return StoreError.TransactionFailed;
            conn.exec(
                \\DELETE FROM events e
                \\WHERE created_at <= NOW() - ($1 || ' days')::interval
                \\  AND event_type NOT IN (
                \\    SELECT event_type FROM event_retention_policies
                \\  )
                \\  AND EXISTS (
                \\    SELECT 1 FROM events_archive ea
                \\    WHERE ea.idempotency_key = e.idempotency_key
                \\  )
            ,
                &.{uintToStr(param_alloc, retention_days) catch return StoreError.TransactionFailed},
            ) catch return StoreError.TransactionFailed;
            total_moved += 1;
        }

        return total_moved;
    }
};

// ---------------------------------------------------------------------------
// Row parsing helpers (placeholders for when pg.zig returns real rows)
// ---------------------------------------------------------------------------

fn rowToEventRecord(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    idempotency_key: []const u8,
) error{OutOfMemory}!EventRecord {
    _ = allocator;
    // Columns: event_id, instance_id, event_type, payload, actor_id,
    //          created_at_us, sequence_number, idempotency_key, metadata, global_seq
    const event_type = if (row.len > 2) row[2] orelse "unknown" else "unknown";
    const payload = if (row.len > 3) row[3] orelse "{}" else "{}";
    const seq = if (row.len > 6) blk: {
        const s = row[6] orelse "0";
        break :blk std.fmt.parseInt(i64, s, 10) catch 0;
    } else 0;
    const created_at = if (row.len > 5) blk: {
        const s = row[5] orelse "0";
        break :blk std.fmt.parseInt(i64, s, 10) catch 0;
    } else 0;
    const metadata = if (row.len > 8) row[8] orelse "{}" else "{}";
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

fn duplicateFromParams(params: AppendParams, sequence_number: i64, metadata: []const u8) EventRecord {
    return EventRecord{
        .event_id = std.mem.zeroes(Uuid),
        .instance_id = params.instance_id,
        .event_type = params.event_type,
        .payload = params.payload,
        .actor_id = params.actor_id,
        .created_at = 0,
        .sequence_number = sequence_number,
        .idempotency_key = params.idempotency_key,
        .metadata = metadata,
        .global_seq = 0,
    };
}

fn currentRequestPipelineRunId() []const u8 {
    if (@hasDecl(root, "api_pipeline_context")) {
        return root.api_pipeline_context.get();
    }
    return "";
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
    for (rows, 0..) |row, i| {
        records[i] = rowToEventRecord(allocator, row, "") catch {
            allocator.free(records);
            return StoreError.TransactionFailed;
        };
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

/// Validate metadata JSON object constraints (ES-08).
/// All checks are in-process before any SQL (Invariant #9).
fn validateMetadata(metadata: []const u8) StoreError!void {
    if (!isJsonObject(metadata)) return StoreError.MetadataInvalid;
    // TODO: full JSON parse to enforce ≤50 entries, key ≤128, value ≤1024,
    //       all-values-are-strings when a JSON parser is available.
    //       For now, structural check (is JSON object) is the guard.
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
