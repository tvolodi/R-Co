//! Process instance store — EE-01 (Start Instance), EE-03 (Task Activation)
//!
//! Owns all DB-backed instance creation and transition-persistence logic.
//! Coordinates with SnapshotStore (PD-08) at start time and with TaskStore
//! (EE-03) at each state transition that activates a HUMAN_TASK node.
//!
//! Design artefact: src/design/engine.md §EE-01, §EE-03
const std = @import("std");
const builtin = @import("builtin");
const db = @import("../db/pool.zig");
const Pool = db.Pool;
const PoolError = db.PoolError;
const snapshot_mod = @import("../definition/snapshot.zig");
const task_mod = @import("../tasks/store.zig");
const transition_mod = @import("transition.zig");
const json_schema = @import("../tools/json_schema.zig");

// ---------------------------------------------------------------------------
// fillRandom — cross-platform OS entropy (replaces std.crypto.random removed
// in Zig 0.16). Uses the platform CSPRNG directly.
// ---------------------------------------------------------------------------
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
        else => @compileError("fillRandom: unsupported OS — add a platform branch"),
    }
}

// ---------------------------------------------------------------------------
// Re-export Uuid type (same [16]u8 as definition/store.zig)
// ---------------------------------------------------------------------------

pub const Uuid = snapshot_mod.Uuid;

// ---------------------------------------------------------------------------
// InstanceStatus enum
// ---------------------------------------------------------------------------

pub const InstanceStatus = enum {
    ACTIVE,
    COMPLETED,
    CANCELLED,
    ERROR,
};

// ---------------------------------------------------------------------------
// Instance struct
// ---------------------------------------------------------------------------

pub const Instance = struct {
    /// Primary key from instance_projections.instance_id.
    instance_id: Uuid,
    /// FK to process_definitions.id.
    definition_id: Uuid,
    /// Current lifecycle status.
    status: InstanceStatus,
    /// Nullable; unique per definition_id when non-null (EE-01 AC).
    correlation_key: ?[]const u8,
    /// The caller-supplied initial variables JSON object string.
    /// Seeded into instance_projections.variables at INSERT time.
    initial_variables: []const u8,
    /// JSON string of the DefinitionGraph captured at start (PD-08).
    /// Stub "{}" until pg.zig delivers real rows.
    definition_snapshot: []const u8,
    /// UTC epoch microseconds derived from instance_projections.started_at.
    created_at: i64,
    /// UTC epoch microseconds derived from instance_projections.updated_at.
    updated_at: i64,
};

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const InstanceError = error{
    /// definition_id not found in process_definitions. HTTP 404.
    DefinitionNotFound,
    /// Definition exists but status ≠ ACTIVE. HTTP 409.
    DefinitionNotActive,
    /// correlation_key is non-null and already used for the same definition_id. HTTP 409.
    DuplicateCorrelationKey,
    /// initial_variables is not a JSON object, or definition_id is a malformed UUID.
    /// HTTP 422.
    InvalidInput,
    /// db.Pool.acquire() returned ExhaustedPool. HTTP 503.
    PoolExhausted,
    /// DB transaction failed to commit (transient). HTTP 500.
    TransactionFailed,
};

// ---------------------------------------------------------------------------
// SetInstanceErrorError — EE-10
// ---------------------------------------------------------------------------

pub const SetInstanceErrorError = error{
    /// instance_id not found in instance_projections. Caller should treat as 404.
    InstanceNotFound,
    /// Instance is already in a terminal status (ERROR, CANCELLED, or COMPLETED).
    /// Caller should treat as 409.
    AlreadyTerminal,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Any DB INSERT or UPDATE inside the transaction failed. HTTP 500.
    PersistenceFailed,
    /// Allocator returned OutOfMemory. HTTP 500.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// ErrorType — EE-10
// ---------------------------------------------------------------------------

pub const ErrorType = enum {
    /// EXCLUSIVE_GATEWAY exhausted all outgoing edges with no match and no default edge.
    /// Populated by the EE-05 gateway handler.
    NO_MATCHING_EDGE,
    /// A task output variable failed registered JSON Schema validation (EE-09).
    SCHEMA_VIOLATION,
};

// ---------------------------------------------------------------------------
// EvaluatedCondition — EE-10
// ---------------------------------------------------------------------------

pub const EvaluatedCondition = struct {
    edge_id: []const u8,
    condition: []const u8,
    result: bool,
};

// ---------------------------------------------------------------------------
// SetInstanceErrorArgs — EE-10
// ---------------------------------------------------------------------------

pub const SetInstanceErrorArgs = struct {
    instance_id: Uuid,
    error_type: ErrorType,
    /// Set when error_type = NO_MATCHING_EDGE. Null otherwise.
    affected_node: ?[]const u8,
    /// Set when error_type = SCHEMA_VIOLATION. Null otherwise.
    affected_field: ?[]const u8,
    /// Human-readable description of the root cause.
    reason: []const u8,
    /// Current instance variable map (snapshot at error time).
    /// Must be a valid JSON object string.
    variable_state: []const u8,
    /// Non-null only when error_type = NO_MATCHING_EDGE.
    /// Slice may be empty if no conditions were evaluated (degenerate gateway).
    evaluated_conditions: ?[]const EvaluatedCondition,
    /// The actor_id of the caller initiating the operation that triggered the error.
    actor_id: []const u8,
};

// ---------------------------------------------------------------------------
// ApplyError — EE-03
// ---------------------------------------------------------------------------

pub const ApplyError = error{
    /// transition() returned a TransitionError.
    TransitionFailed,
    /// A DB INSERT, UPDATE, or event write failed after BEGIN.
    PersistenceFailed,
    /// db.Pool.acquire() failed (pool exhausted or shutdown).
    PoolExhausted,
    /// Allocator returned OutOfMemory.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// CompleteTaskError — EE-04
// ---------------------------------------------------------------------------

pub const CompleteTaskError = error{
    /// task_id not found in tasks table. HTTP 404.
    TaskNotFound,
    /// Task status ≠ PENDING (already COMPLETED or CANCELLED). HTTP 409.
    TaskAlreadyTerminated,
    /// output_variables is null or not a JSON object. HTTP 422.
    InvalidInput,
    /// Pure transition function returned a TransitionError. HTTP 500.
    TransitionFailed,
    /// A DB INSERT, UPDATE, or event write failed after BEGIN. HTTP 500.
    PersistenceFailed,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Allocator returned OutOfMemory.
    OutOfMemory,
    /// A variable in output_variables failed schema validation (EE-09).
    /// The instance has been transitioned to ERROR status. HTTP 409.
    SchemaViolationError,
    /// Instance is in ERROR status; no further state transitions allowed. HTTP 409.
    InstanceInError,
    /// Another transaction currently holds the row-level lock on this instance
    /// (SQLSTATE 55P03 from FOR UPDATE NOWAIT). HTTP 409 CONCURRENT_MODIFICATION.
    ConcurrentModification,
};

// ---------------------------------------------------------------------------
// CancelInstanceError — EE-08
// ---------------------------------------------------------------------------

pub const CancelInstanceError = error{
    /// instance_id not found in instance_projections. HTTP 404.
    InstanceNotFound,
    /// Instance status is not ACTIVE (already CANCELLED or COMPLETED). HTTP 409.
    InstanceAlreadyTerminated,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// A DB INSERT, UPDATE, or event write failed after BEGIN. HTTP 500.
    PersistenceFailed,
    /// Allocator returned OutOfMemory. HTTP 500.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// MergeVariablesError — EE-09
// ---------------------------------------------------------------------------

pub const MergeVariablesError = error{
    /// A variable value failed JSON-Schema validation (OQ-EE09-1).
    SchemaViolation,
    /// DB query or update failed inside the caller's transaction.
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// API-03 GET /instances/:id types
// ---------------------------------------------------------------------------

/// Result of InstanceStore.getById() — full instance state plus PENDING tasks.
pub const InstanceWithTasks = struct {
    instance_id: Uuid,
    definition_id: Uuid,
    correlation_key: ?[]const u8, // allocator-owned if non-null
    status: InstanceStatus,
    variables: []const u8, // JSON string, allocator-owned
    error_detail: ?[]const u8, // JSON string or null, allocator-owned
    started_at: i64, // UTC epoch microseconds
    completed_at: ?i64,
    cancelled_at: ?i64,
    /// Slice of PENDING tasks for this instance. Caller-owned.
    tasks: []task_mod.Task,
};

pub const GetByIdError = error{
    InstanceNotFound,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// API-03 GET /instances (list) types
// ---------------------------------------------------------------------------

/// Input parameters for InstanceStore.listInstances().
pub const ListParams = struct {
    /// SQL-safe status string: "ACTIVE" | "COMPLETED" | "CANCELLED" | "ERROR" | null.
    status: ?[]const u8,
    /// Already-parsed UUID, or null for no filter.
    definition_id: ?Uuid,
    /// Decoded cursor: started_at_us of the last-seen item. Null = start from top.
    cursor_started_at: ?i64,
    /// Hex UUID string of the last-seen item (for keyset seek). Null = no cursor.
    cursor_instance_id: ?[]const u8,
    /// Page size [1..200].
    page_size: u16,
};

/// Projection-only row (no tasks) returned by InstanceStore.listInstances().
pub const InstanceProjectionRow = struct {
    instance_id: Uuid,
    definition_id: Uuid,
    correlation_key: ?[]const u8, // allocator-owned if non-null
    status: InstanceStatus,
    started_at: i64, // UTC epoch microseconds
};

pub const ListError = error{
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// EE-09 variable-merge types
// ---------------------------------------------------------------------------

/// Payload stored in each VARIABLE_OVERWRITTEN event (EE-09 §8).
pub const VariableOverwrittenPayload = struct {
    event_type: []const u8,
    instance_id: Uuid,
    task_id: ?Uuid,
    key: []const u8,
    old_value: []const u8,
    new_value: []const u8,
};

/// Detail attached to the EXECUTION_ERROR event on schema violation (EE-09 §7).
pub const SchemaViolationDetail = struct {
    affected_field: []const u8,
    reason: []const u8,
    variable_state: []const u8,
};

/// Return value from mergeVariables.
pub const MergeVariablesResult = struct {
    merged: std.json.ObjectMap,
    overwritten_events: []VariableOverwrittenPayload,
};

// ---------------------------------------------------------------------------
// InstanceStore
// ---------------------------------------------------------------------------

pub const InstanceStore = struct {
    pool: *Pool,
    snapshot_store: *snapshot_mod.SnapshotStore,

    /// pool and snapshot_store must outlive InstanceStore.
    pub fn init(pool: *Pool, snapshot_store: *snapshot_mod.SnapshotStore) InstanceStore {
        return InstanceStore{
            .pool = pool,
            .snapshot_store = snapshot_store,
        };
    }

    pub fn deinit(self: *InstanceStore) void {
        _ = self;
    }

    // -----------------------------------------------------------------------
    // create  (EE-01)
    // -----------------------------------------------------------------------

    /// Start a new process instance.
    ///
    /// Algorithm (design §5):
    ///   a. Validate initial_variables is a JSON object.
    ///   b. Load and verify the definition (must exist and be ACTIVE).
    ///   c. Generate a fresh UUID v4 (client-side) for the new instance.
    ///   d. Capture the definition snapshot via SnapshotStore.create().
    ///   e. Insert the instance_projections row.
    ///   f. Return populated Instance.
    ///
    /// Security: all SQL values bound as $N parameters — no SQL string
    /// interpolation of user-supplied data anywhere in this function.
    pub fn create(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        definition_id: Uuid,
        correlation_key: ?[]const u8,
        initial_variables: []const u8,
    ) InstanceError!Instance {
        var param_arena = std.heap.ArenaAllocator.init(allocator);
        defer param_arena.deinit();
        const a = param_arena.allocator();

        // ── Step a: Validate initial_variables ─────────────────────────────
        // Must be a JSON object (not null, not array, not scalar).
        // Uses a scoped arena so the parsed JSON is freed immediately.
        {
            var val_arena = std.heap.ArenaAllocator.init(allocator);
            defer val_arena.deinit();
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                val_arena.allocator(),
                initial_variables,
                .{ .allocate = .alloc_always },
            ) catch return InstanceError.InvalidInput;
            defer parsed.deinit();
            switch (parsed.value) {
                .object => {}, // valid — continue
                else => return InstanceError.InvalidInput,
            }
        }

        // ── Step b: Load and verify the definition ─────────────────────────
        // Acquire connection, SELECT id+status, release before step d.
        // Security: definition_id bound as $1::uuid — no SQL string interpolation.
        const def_id_hex = uuidToHex(a, definition_id) catch
            return InstanceError.TransactionFailed;

        {
            const conn = self.pool.acquire() catch |err| switch (err) {
                PoolError.ExhaustedPool => return InstanceError.PoolExhausted,
                else => return InstanceError.TransactionFailed,
            };
            defer self.pool.release(conn);

            const def_rows = conn.query(
                allocator,
                \\SELECT id, status FROM process_definitions WHERE id = $1::uuid
            ,
                &.{def_id_hex},
            ) catch return InstanceError.TransactionFailed;
            defer {
                var r = def_rows;
                r.deinit();
            }

            if (def_rows.rows.len == 0) return InstanceError.DefinitionNotFound;

            const status_str = colGet(def_rows.rows[0], 1);
            if (!std.mem.eql(u8, status_str, "ACTIVE")) return InstanceError.DefinitionNotActive;
        }

        // ── Step c: Generate a fresh UUID v4 (client-side) ─────────────────
        // Cryptographically random bytes; version 4 and RFC 4122 variant bits set.
        // Using a fresh UUID per call makes PK collisions negligible.
        var uuid_bytes: Uuid = undefined;
        fillRandom(&uuid_bytes);
        uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40; // version 4
        uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80; // variant RFC 4122

        const inst_id_hex = uuidToHex(a, uuid_bytes) catch
            return InstanceError.TransactionFailed;

        // ── Step d: Capture the definition snapshot (PD-08) ────────────────
        // SnapshotStore.create() opens its own DB transaction internally.
        // Use a temporary arena so the returned Snapshot is freed on exit.
        // SnapshotAlreadyExists means an idempotent retry; continue to step e.
        {
            var snap_arena = std.heap.ArenaAllocator.init(allocator);
            defer snap_arena.deinit();

            if (self.snapshot_store.create(snap_arena.allocator(), uuid_bytes, definition_id)) |_| {
                // Snapshot created successfully; snap_arena.deinit() frees it.
            } else |err| {
                switch (err) {
                    error.DefinitionNotFound => return InstanceError.DefinitionNotFound,
                    error.SnapshotAlreadyExists => {}, // idempotent retry; continue to step e
                    error.PoolExhausted => return InstanceError.PoolExhausted,
                    error.TransactionFailed => return InstanceError.TransactionFailed,
                }
            }
        }

        // ── Step e: Insert the instance_projections row ────────────────────
        // NULLIF($3, '') converts the empty-string sentinel for a null Zig
        // correlation_key into SQL NULL so that:
        //   - NULL correlation_key does not trigger the partial unique index
        //     uq_instance_correlation (WHERE correlation_key IS NOT NULL).
        //   - Non-null correlation_key is stored and participates in uniqueness.
        //
        // ON CONFLICT (definition_id, correlation_key)
        //     WHERE correlation_key IS NOT NULL DO NOTHING
        //   matches the uq_instance_correlation partial index; 0 RETURNING rows
        //   means the conflict fired → DuplicateCorrelationKey.
        //
        // Security: $1=instance_id, $2=definition_id, $3=correlation_key,
        //           $4=initial_variables — all bound via pg parameters.
        const ck_param = correlation_key orelse "";

        const conn2 = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return InstanceError.PoolExhausted,
            else => return InstanceError.TransactionFailed,
        };
        defer self.pool.release(conn2);

        const ins_rows = conn2.query(
            allocator,
            \\INSERT INTO instance_projections
            \\    (instance_id, definition_id, correlation_key,
            \\     status, variables, current_nodes, started_at, updated_at)
            \\VALUES
            \\    ($1::uuid, $2::uuid, NULLIF($3, ''),
            \\     'ACTIVE', $4::jsonb, '[]'::jsonb, NOW(), NOW())
            \\ON CONFLICT (definition_id, correlation_key)
            \\    WHERE correlation_key IS NOT NULL DO NOTHING
            \\RETURNING
            \\    instance_id,
            \\    definition_id,
            \\    correlation_key,
            \\    status,
            \\    variables,
            \\    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ inst_id_hex, def_id_hex, ck_param, initial_variables },
        ) catch return InstanceError.TransactionFailed;
        defer {
            var r = ins_rows;
            r.deinit();
        }

        // 0 RETURNING rows: ON CONFLICT fired for a duplicate non-null
        // correlation_key → DuplicateCorrelationKey (HTTP 409).
        if (ins_rows.rows.len == 0) return InstanceError.DuplicateCorrelationKey;

        // ── Step f: Build and return Instance ──────────────────────────────
        return rowToInstance(allocator, ins_rows.rows[0], initial_variables) catch
            InstanceError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // applyTransition  (EE-03)
    // -----------------------------------------------------------------------

    /// Persist a state transition atomically.
    ///
    /// Algorithm (design §6 EE-03):
    ///   a. Call transition() — pure function, no I/O, outside the transaction.
    ///   b. Compute new_task_node_ids = set_difference(new.pending_task_nodes,
    ///      old.pending_task_nodes).
    ///   c. Acquire a connection and BEGIN TRANSACTION.
    ///   d. INSERT event row into events.
    ///   e. UPDATE instance_projections.
    ///   f. For each new_task_node_id: TaskStore.createInTx().
    ///   g. COMMIT.
    ///   h. Return new_state.
    ///
    /// Atomicity invariant: steps c–g (BEGIN…COMMIT) are a single DB transaction.
    /// If any step fails, ROLLBACK is issued and ApplyError is returned.
    /// transition() (step a) is called before any DB connection is acquired —
    /// a transition failure never opens a connection.
    ///
    /// Security: all SQL parameter values are bound as $N positional parameters.
    /// No user-supplied, snapshot-derived, or state-derived value is concatenated
    /// into any SQL string literal.
    pub fn applyTransition(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        task_store: *task_mod.TaskStore,
        instance_id: Uuid,
        old_state: transition_mod.InstanceState,
        event: transition_mod.TransitionEvent,
        snapshot: snapshot_mod.DefinitionGraph,
    ) ApplyError!transition_mod.InstanceState {
        // ── Step a: Pure transition call (NO I/O, outside DB transaction) ──
        const new_state = transition_mod.transition(allocator, snapshot, old_state, event) catch
            return ApplyError.TransitionFailed;

        // ── Step b: Compute newly activated HUMAN_TASK node IDs ─────────────
        // Set difference: nodes in new_state.pending_task_nodes not in
        // old_state.pending_task_nodes. O(n²) scan is acceptable for small sets.
        var new_task_nodes = std.ArrayList([]const u8).empty;
        defer new_task_nodes.deinit(allocator);
        for (new_state.pending_task_nodes) |new_node| {
            var found = false;
            for (old_state.pending_task_nodes) |old_node| {
                if (std.mem.eql(u8, new_node, old_node)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                new_task_nodes.append(allocator, new_node) catch return ApplyError.OutOfMemory;
            }
        }

        // ── Prepare SQL parameters ──────────────────────────────────────────
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, instance_id) catch return ApplyError.OutOfMemory;

        // Serialize new_state.status to uppercase TEXT.
        const status_str = instanceStatusToString(new_state.status);

        // Serialize tokens to JSON array: [{"node_id":"...","branch_id":"..."}]
        var tokens_buf = std.ArrayList(u8).empty;
        tokens_buf.append(a, '[') catch return ApplyError.OutOfMemory;
        for (new_state.tokens, 0..) |tok, i| {
            if (i > 0) tokens_buf.append(a, ',') catch return ApplyError.OutOfMemory;
            const entry = std.fmt.allocPrint(
                a,
                "{{\"node_id\":\"{s}\",\"branch_id\":\"{s}\"}}",
                .{ tok.node_id, tok.branch_id },
            ) catch return ApplyError.OutOfMemory;
            tokens_buf.appendSlice(a, entry) catch return ApplyError.OutOfMemory;
        }
        tokens_buf.append(a, ']') catch return ApplyError.OutOfMemory;
        const tokens_json = tokens_buf.items;

        // Serialize variables ObjectMap to JSON object string.
        const vars_value = std.json.Value{ .object = new_state.variables };
        const vars_json = std.json.Stringify.valueAlloc(a, vars_value, .{}) catch
            return ApplyError.OutOfMemory;

        // Generate idempotency key (random UUID v4).
        var idem_bytes: Uuid = undefined;
        fillRandom(&idem_bytes);
        idem_bytes[6] = (idem_bytes[6] & 0x0f) | 0x40;
        idem_bytes[8] = (idem_bytes[8] & 0x3f) | 0x80;
        const idem_key_hex = uuidToHex(a, idem_bytes) catch return ApplyError.OutOfMemory;

        // Derive event_type string from the TransitionEvent tag.
        const event_type_str: []const u8 = switch (event) {
            .instance_started => "instance_started",
            .task_completed => "task_completed",
            .unknown => "unknown",
        };

        // ── Step c: Acquire connection and BEGIN ─────────────────────────────
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ApplyError.PoolExhausted,
            else => return ApplyError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        conn.begin() catch return ApplyError.PersistenceFailed;
        // errdefer ROLLBACK — only fires on error returns, not on normal return.
        errdefer conn.rollback() catch {};

        // ── Step d: INSERT event row ─────────────────────────────────────────
        // Uses a CTE to atomically bump instance_sequence and obtain the next
        // sequence number for this instance.
        //
        // Security: $1=instance_id, $2=event_type, $3=payload, $4=idempotency_key
        //           — all bound as $N parameters; no SQL string interpolation.
        conn.exec(
            \\WITH seq AS (
            \\    INSERT INTO instance_sequence (instance_id, next_seq)
            \\    VALUES ($1::uuid, 2)
            \\    ON CONFLICT (instance_id) DO UPDATE
            \\        SET next_seq = instance_sequence.next_seq + 1
            \\    RETURNING next_seq - 1 AS val
            \\)
            \\INSERT INTO events
            \\    (instance_id, event_type, payload, actor_id,
            \\     sequence_number, idempotency_key)
            \\SELECT $1::uuid, $2, $3::jsonb, $1::uuid, seq.val, $4
            \\FROM seq
        ,
            &.{ inst_id_hex, event_type_str, "{}", idem_key_hex },
        ) catch return ApplyError.PersistenceFailed;

        // ── Step e: UPDATE instance_projections ──────────────────────────────
        // Security: $1=instance_id, $2=status, $3=tokens_json, $4=vars_json
        //           — all bound as $N parameters.
        conn.exec(
            \\UPDATE instance_projections
            \\SET
            \\    status        = $2,
            \\    current_nodes = $3::jsonb,
            \\    variables     = $4::jsonb,
            \\    last_event_seq = last_event_seq + 1,
            \\    updated_at    = NOW()
            \\WHERE instance_id = $1::uuid
        ,
            &.{ inst_id_hex, status_str, tokens_json, vars_json },
        ) catch return ApplyError.PersistenceFailed;

        // ── Step f: INSERT Task records for newly activated HUMAN_TASK nodes ─
        for (new_task_nodes.items) |task_node_id| {
            // Look up node in snapshot to get display name and assignee fields.
            var node_name: []const u8 = task_node_id; // fallback: use node_id
            var assignee_type: ?[]const u8 = null;
            var assignee_ref: ?[]const u8 = null;

            for (snapshot.nodes) |node| {
                if (!std.mem.eql(u8, node.id, task_node_id)) continue;
                if (node.label) |lbl| node_name = lbl;
                // Parse assignee_type and assignee_ref from node.attributes JSON.
                // Security: these values are read from the definition snapshot
                // (not HTTP input) but are still bound as $N params in the INSERT.
                if (node.attributes) |attrs| {
                    parseAssigneeFields(a, attrs, &assignee_type, &assignee_ref);
                }
                break;
            }

            // Locate the token parked on this task node to obtain token_id.
            // token.branch_id is a UUID-formatted string derived from instance_id.
            var token_id: Uuid = std.mem.zeroes(Uuid);
            for (new_state.tokens) |tok| {
                if (std.mem.eql(u8, tok.node_id, task_node_id)) {
                    token_id = task_mod.parseUuid(tok.branch_id) catch std.mem.zeroes(Uuid);
                    break;
                }
            }

            _ = task_store.createInTx(
                allocator,
                conn,
                instance_id,
                token_id,
                task_node_id,
                node_name,
                assignee_type,
                assignee_ref,
            ) catch return ApplyError.PersistenceFailed;
        }

        // ── Step g: COMMIT ───────────────────────────────────────────────────
        conn.commit() catch return ApplyError.PersistenceFailed;

        // ── Step h: Return new_state ─────────────────────────────────────────
        return new_state;
    }

    // -----------------------------------------------------------------------
    // completeTask  (EE-04)
    // -----------------------------------------------------------------------

    /// Complete a HUMAN_TASK by submitting output variables.
    ///
    /// Algorithm (design §EE-04 §4):
    ///   a. getById (outside tx) — TaskNotFound if missing.
    ///   b. Check task.status == PENDING — TaskAlreadyTerminated if not.
    ///   c. Load instance projection (current_nodes, variables) — read conn.
    ///   d. Load definition snapshot.
    ///   e. Parse and validate output_variables_json — InvalidInput if not object.
    ///   f. Build TransitionEvent.task_completed.
    ///   g. Call transition() — pure, zero I/O, outside any transaction.
    ///   h. BEGIN TRANSACTION.
    ///   i. completeInTx — UPDATE tasks WHERE status='PENDING'.
    ///   j. INSERT TASK_COMPLETED event row.
    ///   k. UPDATE instance_projections.
    ///   l. createInTx for each newly activated HUMAN_TASK node.
    ///   m. COMMIT.
    ///
    /// Steps h–m are a single atomic DB transaction. Any failure in h–m issues
    /// ROLLBACK (via errdefer) and returns PersistenceFailed.
    ///
    /// Security: all SQL parameter values are bound as $N positional parameters.
    /// No user-supplied value (output_variables_json, task_id) is concatenated
    /// into any SQL string literal at any point in the call chain.
    pub fn completeTask(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        task_store: *task_mod.TaskStore,
        task_id: task_mod.Uuid,
        output_variables_json: []const u8,
    ) CompleteTaskError!transition_mod.InstanceState {
        // ── Step a: Fetch the task (outside the transaction) ─────────────────
        const task = task_store.getById(allocator, task_id) catch |err| switch (err) {
            task_mod.TaskError.NotFound => return CompleteTaskError.TaskNotFound,
            task_mod.TaskError.PoolExhausted => return CompleteTaskError.PoolExhausted,
            task_mod.TaskError.InvalidInput => return CompleteTaskError.InvalidInput,
            task_mod.TaskError.AlreadyTerminated => unreachable, // getById never returns this
        };
        defer task_mod.freeTask(allocator, task);

        // ── Step b: Verify task is PENDING ────────────────────────────────────
        if (task.status != .PENDING) return CompleteTaskError.TaskAlreadyTerminated;

        // Arena for temporary SQL params and raw row data (freed at function exit).
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, task.instance_id) catch return CompleteTaskError.OutOfMemory;

        // ── Step c: Load instance projection ─────────────────────────────────
        // Acquire a read-only connection, SELECT the current state, dupe raw
        // column strings into the arena, then release the connection.
        var def_id: Uuid = std.mem.zeroes(Uuid);
        var tokens_json_str: []const u8 = "[]";
        var vars_json_str: []const u8 = "{}";
        var proj_status: InstanceStatus = .ACTIVE;
        {
            const proj_conn = self.pool.acquire() catch |err| switch (err) {
                PoolError.ExhaustedPool => return CompleteTaskError.PoolExhausted,
                else => return CompleteTaskError.PersistenceFailed,
            };
            defer self.pool.release(proj_conn);

            // Security: $1 = instance_id as hex UUID — no SQL string interpolation.
            const proj_rows = proj_conn.query(
                a,
                \\SELECT
                \\    instance_id,
                \\    definition_id,
                \\    status,
                \\    current_nodes,
                \\    variables
                \\FROM instance_projections
                \\WHERE instance_id = $1::uuid
            ,
                &.{inst_id_hex},
            ) catch return CompleteTaskError.PersistenceFailed;
            defer {
                var r = proj_rows;
                r.deinit();
            }

            if (proj_rows.rows.len == 0) return CompleteTaskError.PersistenceFailed;
            const row = proj_rows.rows[0];

            // Column 1: definition_id (hex UUID).
            def_id = parseUuid(colGet(row, 1)) catch std.mem.zeroes(Uuid);
            proj_status = parseInstanceStatus(colGet(row, 2)) catch .ACTIVE;
            // Dupe raw column data into arena before proj_rows.deinit() frees the buffer.
            tokens_json_str = a.dupe(u8, colGet(row, 3)) catch return CompleteTaskError.OutOfMemory;
            vars_json_str = a.dupe(u8, colGet(row, 4)) catch return CompleteTaskError.OutOfMemory;
        }
        // proj_conn and proj_rows are released here.

        // Parse current_nodes JSON array → []Token (node_id/branch_id in allocator).
        var tokens = std.ArrayList(transition_mod.Token).empty;
        defer tokens.deinit(allocator);
        token_parse: {
            const tok_parsed = std.json.parseFromSlice(
                std.json.Value,
                a,
                tokens_json_str,
                .{ .allocate = .alloc_always },
            ) catch break :token_parse;
            if (tok_parsed.value != .array) break :token_parse;
            for (tok_parsed.value.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const nid_val = obj.get("node_id") orelse continue;
                const bid_val = obj.get("branch_id") orelse continue;
                if (nid_val != .string or bid_val != .string) continue;
                const nid = allocator.dupe(u8, nid_val.string) catch
                    return CompleteTaskError.OutOfMemory;
                const bid = allocator.dupe(u8, bid_val.string) catch {
                    allocator.free(nid);
                    return CompleteTaskError.OutOfMemory;
                };
                tokens.append(allocator, .{ .node_id = nid, .branch_id = bid }) catch {
                    allocator.free(nid);
                    allocator.free(bid);
                    return CompleteTaskError.OutOfMemory;
                };
            }
        }

        // Parse variables JSON object → std.json.ObjectMap.
        const vars_parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            vars_json_str,
            .{ .allocate = .alloc_always },
        ) catch return CompleteTaskError.PersistenceFailed;
        defer vars_parsed.deinit();
        if (vars_parsed.value != .object) return CompleteTaskError.PersistenceFailed;

        // ── Step d: Load the definition snapshot ──────────────────────────────
        const snapshot_obj = self.snapshot_store.getByInstanceId(
            allocator,
            task.instance_id,
        ) catch |err| return switch (err) {
            snapshot_mod.SnapshotError.PoolExhausted => CompleteTaskError.PoolExhausted,
            else => CompleteTaskError.PersistenceFailed,
        };
        const snapshot = snapshot_obj.graph;

        // Compute pending_task_nodes: tokens whose node is a HUMAN_TASK type.
        var pending_task_nodes = std.ArrayList([]const u8).empty;
        defer pending_task_nodes.deinit(allocator);
        for (tokens.items) |tok| {
            for (snapshot.nodes) |node| {
                if (std.mem.eql(u8, node.id, tok.node_id) and node.node_type == .HUMAN_TASK) {
                    const duped = allocator.dupe(u8, tok.node_id) catch
                        return CompleteTaskError.OutOfMemory;
                    pending_task_nodes.append(allocator, duped) catch return CompleteTaskError.OutOfMemory;
                    break;
                }
            }
        }

        const current_state = transition_mod.InstanceState{
            .instance_id = task.instance_id,
            .status = switch (proj_status) {
                .ACTIVE => transition_mod.InstanceStatus.ACTIVE,
                .COMPLETED => transition_mod.InstanceStatus.COMPLETED,
                .CANCELLED => transition_mod.InstanceStatus.CANCELLED,
                .ERROR => transition_mod.InstanceStatus.ERROR,
            },
            .tokens = tokens.items,
            .variables = vars_parsed.value.object,
            .pending_task_nodes = pending_task_nodes.items,
            .error_detail = null,
            .pending_events = &[_]transition_mod.PendingEvent{},
        };

        // ── Step e: Validate and parse output_variables_json ─────────────────
        // Must be a JSON object (not null, not array, not scalar).
        const out_vars_parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            output_variables_json,
            .{ .allocate = .alloc_always },
        ) catch return CompleteTaskError.InvalidInput;
        defer out_vars_parsed.deinit();
        if (out_vars_parsed.value != .object) return CompleteTaskError.InvalidInput;

        // ── Step f: BEGIN transaction; SELECT FOR UPDATE; EE-09 merge ────────
        // Transaction is opened BEFORE mergeVariables to ensure schema lookup and
        // subsequent writes are atomic. tx_committed guards the errdefer rollback.
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return CompleteTaskError.PoolExhausted,
            else => return CompleteTaskError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        conn.begin() catch return CompleteTaskError.PersistenceFailed;
        var tx_committed = false;
        // ROLLBACK on any error return unless tx_committed is set first.
        errdefer if (!tx_committed) conn.rollback() catch {};

        // SELECT FOR UPDATE NOWAIT: lock the projection row for the transaction duration.
        // NOWAIT causes PostgreSQL to raise SQLSTATE 55P03 immediately if the row is
        // locked by another transaction rather than blocking. All query failures at
        // this step are treated as ConcurrentModification per the EE-12 design §3d
        // (SQLSTATE 55P03 cannot be distinguished from other errors at the pool.zig
        // abstraction layer — same approach as reconstruction.zig §EE-11).
        // Also reads status for the EE-10 HTTP 409 guard (§8).
        // Security: $1 = instance_id hex — no SQL string interpolation.
        const lock_rows = conn.query(
            a,
            \\SELECT instance_id, status FROM instance_projections
            \\WHERE instance_id = $1::uuid
            \\FOR UPDATE NOWAIT
        ,
            &.{inst_id_hex},
        ) catch return CompleteTaskError.ConcurrentModification;
        {
            defer {
                var r = lock_rows;
                r.deinit();
            }
            if (lock_rows.rows.len == 0) return CompleteTaskError.PersistenceFailed;
            // Column 0 = instance_id, column 1 = status.
            const locked_status_str = colGet(lock_rows.rows[0], 1);
            const locked_status = parseInstanceStatus(locked_status_str) catch .ACTIVE;
            // EE-10 HTTP 409 guard: reject any state-transition attempt on a non-ACTIVE instance.
            if (locked_status == .ERROR) {
                // ROLLBACK via errdefer; InstanceInError → HTTP 409.
                return CompleteTaskError.InstanceInError;
            }
            if (locked_status == .CANCELLED or locked_status == .COMPLETED) {
                return CompleteTaskError.TaskAlreadyTerminated;
            }
        }

        // [EE-09] Compute merged variables using the three-path collision policy.
        // mergeVariables issues one SELECT (variable_schemas) then returns; all DB
        // writes for events occur after this call, still in the same transaction.
        var violation_detail: ?SchemaViolationDetail = null;
        const merge_result = self.mergeVariables(
            allocator,
            conn,
            def_id,
            task.instance_id,
            task_id,
            current_state.variables,
            out_vars_parsed.value.object,
            &violation_detail,
        ) catch |merge_err| switch (merge_err) {
            MergeVariablesError.SchemaViolation => {
                // EE-10 isolation model (OQ-EE10-3): rollback the completeTask tx first,
                // then call setInstanceError which opens its own transaction.
                // This prevents any partial task-completion state from being visible.
                conn.rollback() catch {};
                tx_committed = true; // Suppress the errdefer rollback (already done).

                const vd = violation_detail orelse SchemaViolationDetail{
                    .affected_field = "",
                    .reason = "schema validation failed",
                    .variable_state = "{}",
                };

                // Serialise current variable state for the EXECUTION_ERROR payload.
                const vars_json_for_error = std.json.Stringify.valueAlloc(
                    allocator,
                    std.json.Value{ .object = current_state.variables },
                    .{},
                ) catch return CompleteTaskError.OutOfMemory;
                defer allocator.free(vars_json_for_error);

                self.setInstanceError(allocator, SetInstanceErrorArgs{
                    .instance_id = task.instance_id,
                    .error_type = .SCHEMA_VIOLATION,
                    .affected_node = null,
                    .affected_field = vd.affected_field,
                    .reason = vd.reason,
                    .variable_state = vars_json_for_error,
                    .evaluated_conditions = null,
                    .actor_id = inst_id_hex, // use instance_id as actor stub; caller supplies real actor_id via IDN-03
                }) catch |set_err| return mapSetErrorToCompleteError(set_err);

                return CompleteTaskError.InstanceInError;
            },
            MergeVariablesError.PersistenceFailed => return CompleteTaskError.PersistenceFailed,
            MergeVariablesError.OutOfMemory => return CompleteTaskError.OutOfMemory,
        };
        defer {
            for (merge_result.overwritten_events) |ev| {
                allocator.free(ev.key);
                allocator.free(ev.old_value);
                allocator.free(ev.new_value);
            }
            if (merge_result.overwritten_events.len > 0)
                allocator.free(merge_result.overwritten_events);
        }

        // ── Step g: Build InstanceState with merged variables ─────────────────
        // Pass merge_result.merged as the variables so that CEL conditions in
        // gateway evaluation (EE-05) see the post-merge variable map.
        const merged_state = transition_mod.InstanceState{
            .instance_id = current_state.instance_id,
            .status = current_state.status,
            .tokens = current_state.tokens,
            .variables = merge_result.merged,
            .pending_task_nodes = current_state.pending_task_nodes,
            .error_detail = current_state.error_detail,
            .pending_events = current_state.pending_events,
            .cancelled_branch_ids = current_state.cancelled_branch_ids,
        };

        // ── Step h: Build TransitionEvent and call transition() ───────────────
        // transition() is a pure function (zero I/O); safe to call inside the tx.
        const event = transition_mod.TransitionEvent{
            .task_completed = .{
                .task_node_id = task.node_id,
                .output_variables = out_vars_parsed.value.object,
            },
        };

        const new_state = transition_mod.transition(allocator, snapshot, merged_state, event) catch |tr_err| switch (tr_err) {
            transition_mod.TransitionError.NoMatchingEdge => {
                // EE-10 / EE-05 no-match path: rollback the completeTask tx first,
                // then call setInstanceError which opens its own transaction.
                conn.rollback() catch {};
                tx_committed = true; // Suppress the errdefer rollback (already done).

                // Serialise current variable state for the EXECUTION_ERROR payload.
                const vars_json_for_error = std.json.Stringify.valueAlloc(
                    allocator,
                    std.json.Value{ .object = merged_state.variables },
                    .{},
                ) catch return CompleteTaskError.OutOfMemory;
                defer allocator.free(vars_json_for_error);

                // Determine the gateway node where the token was parked.
                // The token on the task's node drove us into this gateway.
                // Find the first token that is on an EXCLUSIVE_GATEWAY node in the snapshot.
                var gateway_node_id: ?[]const u8 = null;
                for (merged_state.tokens) |tok| {
                    for (snapshot.nodes) |node| {
                        if (std.mem.eql(u8, node.id, tok.node_id) and node.node_type == .EXCLUSIVE_GATEWAY) {
                            gateway_node_id = tok.node_id;
                            break;
                        }
                    }
                    if (gateway_node_id != null) break;
                }

                self.setInstanceError(allocator, SetInstanceErrorArgs{
                    .instance_id = task.instance_id,
                    .error_type = .NO_MATCHING_EDGE,
                    .affected_node = gateway_node_id,
                    .affected_field = null,
                    .reason = "No outgoing edge condition matched and no default edge defined",
                    .variable_state = vars_json_for_error,
                    .evaluated_conditions = null, // conditions not tracked at this layer
                    .actor_id = inst_id_hex,
                }) catch |set_err| return mapSetErrorToCompleteError(set_err);

                return CompleteTaskError.InstanceInError;
            },
            else => return CompleteTaskError.TransitionFailed,
        };

        // Serialize new_state for SQL parameters (all in arena, freed at function exit).
        const new_status_str = instanceStatusToString(new_state.status);

        var tokens_buf = std.ArrayList(u8).empty;
        tokens_buf.append(a, '[') catch return CompleteTaskError.OutOfMemory;
        for (new_state.tokens, 0..) |tok, i| {
            if (i > 0) tokens_buf.append(a, ',') catch return CompleteTaskError.OutOfMemory;
            const entry = std.fmt.allocPrint(
                a,
                "{{\"node_id\":\"{s}\",\"branch_id\":\"{s}\"}}",
                .{ tok.node_id, tok.branch_id },
            ) catch return CompleteTaskError.OutOfMemory;
            tokens_buf.appendSlice(a, entry) catch return CompleteTaskError.OutOfMemory;
        }
        tokens_buf.append(a, ']') catch return CompleteTaskError.OutOfMemory;
        const new_tokens_json = tokens_buf.items;

        const new_vars_value = std.json.Value{ .object = new_state.variables };
        const new_vars_json = std.json.Stringify.valueAlloc(a, new_vars_value, .{}) catch
            return CompleteTaskError.OutOfMemory;

        // Idempotency key for the TASK_COMPLETED event INSERT.
        var idem_bytes: Uuid = undefined;
        fillRandom(&idem_bytes);
        idem_bytes[6] = (idem_bytes[6] & 0x0f) | 0x40;
        idem_bytes[8] = (idem_bytes[8] & 0x3f) | 0x80;
        const idem_key_hex = uuidToHex(a, idem_bytes) catch return CompleteTaskError.OutOfMemory;

        // ── Step i: UPDATE tasks SET status='COMPLETED' ───────────────────────
        // Security: task_id and output_variables_json bound as $N in completeInTx.
        _ = task_store.completeInTx(allocator, conn, task_id, output_variables_json) catch
            return CompleteTaskError.PersistenceFailed;

        // ── Step j: INSERT TASK_COMPLETED event row ───────────────────────────
        // CTE atomically bumps instance_sequence and inserts into events.
        // Security: all values bound as $N params; no SQL string interpolation.
        conn.exec(
            \\WITH seq AS (
            \\    INSERT INTO instance_sequence (instance_id, next_seq)
            \\    VALUES ($1::uuid, 2)
            \\    ON CONFLICT (instance_id) DO UPDATE
            \\        SET next_seq = instance_sequence.next_seq + 1
            \\    RETURNING next_seq - 1 AS val
            \\)
            \\INSERT INTO events
            \\    (instance_id, event_type, payload, actor_id,
            \\     sequence_number, idempotency_key)
            \\SELECT $1::uuid, $2, $3::jsonb, $1::uuid, seq.val, $4
            \\FROM seq
        ,
            &.{ inst_id_hex, "task_completed", "{}", idem_key_hex },
        ) catch return CompleteTaskError.PersistenceFailed;

        // ── Step k: INSERT VARIABLE_OVERWRITTEN events (EE-09) ────────────────
        // One INSERT per overwritten variable key; all in the same transaction.
        // Security: all values bound as $N params; no SQL string interpolation.
        for (merge_result.overwritten_events) |ov_ev| {
            const ov_payload = buildOverwrittenPayload(a, inst_id_hex, ov_ev) catch
                return CompleteTaskError.OutOfMemory;

            var ov_idem: Uuid = undefined;
            fillRandom(&ov_idem);
            ov_idem[6] = (ov_idem[6] & 0x0f) | 0x40;
            ov_idem[8] = (ov_idem[8] & 0x3f) | 0x80;
            const ov_idem_hex = uuidToHex(a, ov_idem) catch return CompleteTaskError.OutOfMemory;

            conn.exec(
                \\WITH seq AS (
                \\    INSERT INTO instance_sequence (instance_id, next_seq)
                \\    VALUES ($1::uuid, 2)
                \\    ON CONFLICT (instance_id) DO UPDATE
                \\        SET next_seq = instance_sequence.next_seq + 1
                \\    RETURNING next_seq - 1 AS val
                \\)
                \\INSERT INTO events
                \\    (instance_id, event_type, payload, actor_id,
                \\     sequence_number, idempotency_key)
                \\SELECT $1::uuid, $2, $3::jsonb, $1::uuid, seq.val, $4
                \\FROM seq
            ,
                &.{ inst_id_hex, "VARIABLE_OVERWRITTEN", ov_payload, ov_idem_hex },
            ) catch return CompleteTaskError.PersistenceFailed;
        }

        // ── Step l: UPDATE instance_projections ───────────────────────────────
        // Security: $1=instance_id, $2=status, $3=tokens_json, $4=vars_json
        //           — all bound as $N parameters; no SQL string interpolation.
        conn.exec(
            \\UPDATE instance_projections
            \\SET
            \\    status         = $2,
            \\    current_nodes  = $3::jsonb,
            \\    variables      = $4::jsonb,
            \\    last_event_seq = last_event_seq + 1,
            \\    updated_at     = NOW()
            \\WHERE instance_id  = $1::uuid
        ,
            &.{ inst_id_hex, new_status_str, new_tokens_json, new_vars_json },
        ) catch return CompleteTaskError.PersistenceFailed;

        // ── Step m: Create tasks for newly activated HUMAN_TASK nodes ─────────
        // Set difference: new_state.pending_task_nodes minus current_state.pending_task_nodes.
        for (new_state.pending_task_nodes) |new_node| {
            var already_in_old = false;
            for (current_state.pending_task_nodes) |old_node| {
                if (std.mem.eql(u8, new_node, old_node)) {
                    already_in_old = true;
                    break;
                }
            }
            if (already_in_old) continue;

            // Look up the node in the snapshot for display name and assignee fields.
            var node_name: []const u8 = new_node;
            var node_assignee_type: ?[]const u8 = null;
            var node_assignee_ref: ?[]const u8 = null;

            for (snapshot.nodes) |node| {
                if (!std.mem.eql(u8, node.id, new_node)) continue;
                if (node.label) |lbl| node_name = lbl;
                if (node.attributes) |attrs| {
                    parseAssigneeFields(a, attrs, &node_assignee_type, &node_assignee_ref);
                }
                break;
            }

            // Locate the token parked on this new task node to get token_id.
            var token_id: Uuid = std.mem.zeroes(Uuid);
            for (new_state.tokens) |tok| {
                if (std.mem.eql(u8, tok.node_id, new_node)) {
                    token_id = task_mod.parseUuid(tok.branch_id) catch std.mem.zeroes(Uuid);
                    break;
                }
            }

            _ = task_store.createInTx(
                allocator,
                conn,
                task.instance_id,
                token_id,
                new_node,
                node_name,
                node_assignee_type,
                node_assignee_ref,
            ) catch return CompleteTaskError.PersistenceFailed;
        }

        // ── Step n: COMMIT ────────────────────────────────────────────────────
        conn.commit() catch return CompleteTaskError.PersistenceFailed;
        tx_committed = true;

        return new_state;
    }

    // -----------------------------------------------------------------------
    // mergeVariables  (EE-09)
    // -----------------------------------------------------------------------

    /// Merge `output_variables` into `current_vars` using the EE-09 three-path
    /// collision policy:
    ///   1. Schema validation: if a schema exists for the key and the value
    ///      fails, set `violation_out` and return SchemaViolation.
    ///   2. VARIABLE_OVERWRITTEN: if the key already exists in current_vars,
    ///      record an overwrite event (key, old_value, new_value).
    ///   3. New variable: no collision record needed.
    ///
    /// On success, returns a `MergeVariablesResult` with:
    ///   - `merged`: shallow-cloned map with all output_variables applied
    ///   - `overwritten_events`: caller-owned slice (allocated with `allocator`)
    ///
    /// Must be called inside an open transaction (conn must have BEGIN'd).
    /// Issues one SELECT on `variable_schemas`; no writes.
    ///
    /// Security: $1 = definition_id hex — no SQL string interpolation.
    pub fn mergeVariables(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        definition_id: Uuid,
        instance_id: Uuid,
        task_id: ?Uuid,
        current_vars: std.json.ObjectMap,
        output_variables: std.json.ObjectMap,
        violation_out: *?SchemaViolationDetail,
    ) MergeVariablesError!MergeVariablesResult {
        _ = self;

        // Fast path: nothing to merge.
        if (output_variables.count() == 0) {
            const merged = current_vars.clone(allocator) catch return MergeVariablesError.OutOfMemory;
            return MergeVariablesResult{
                .merged = merged,
                .overwritten_events = &.{},
            };
        }

        // Arena for temporary allocations (schema JSON strings, query rows).
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const def_id_hex = uuidToHex(a, definition_id) catch return MergeVariablesError.OutOfMemory;

        // Fetch all variable schemas for this definition.
        // Security: $1 = definition_id hex — no string interpolation.
        const schema_rows = conn.query(
            a,
            \\SELECT variable_key, json_schema
            \\FROM variable_schemas
            \\WHERE definition_id = $1::uuid
        ,
            &.{def_id_hex},
        ) catch return MergeVariablesError.PersistenceFailed;
        defer {
            var r = schema_rows;
            r.deinit();
        }

        // Build a temporary map: variable_key → json_schema string (arena-owned).
        var schema_map = std.StringHashMap([]const u8).init(a);
        for (schema_rows.rows) |row| {
            const key = colGet(row, 0);
            const schema_json = colGet(row, 1);
            if (key.len > 0 and schema_json.len > 0) {
                schema_map.put(key, schema_json) catch return MergeVariablesError.OutOfMemory;
            }
        }

        // Clone current_vars so we can update entries in place.
        var merged = current_vars.clone(allocator) catch return MergeVariablesError.OutOfMemory;
        errdefer merged.deinit(allocator);

        var overwritten = std.ArrayList(VariableOverwrittenPayload).empty;
        errdefer {
            for (overwritten.items) |ev| {
                allocator.free(ev.key);
                allocator.free(ev.old_value);
                allocator.free(ev.new_value);
            }
            overwritten.deinit(allocator);
        }

        var it = output_variables.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const new_value = entry.value_ptr.*;

            // Path 1: schema validation.
            if (schema_map.get(key)) |schema_json_str| {
                var schema_arena = std.heap.ArenaAllocator.init(a);
                defer schema_arena.deinit();
                if (std.json.parseFromSlice(
                    std.json.Value,
                    schema_arena.allocator(),
                    schema_json_str,
                    .{ .allocate = .alloc_always },
                )) |schema_parsed| {
                    const result = json_schema.validate(new_value, schema_parsed.value);
                    if (!result.valid) {
                        // Build violation detail (allocator-owned, caller reads via violation_out).
                        const state_json = std.json.Stringify.valueAlloc(
                            allocator,
                            std.json.Value{ .object = current_vars },
                            .{},
                        ) catch return MergeVariablesError.OutOfMemory;
                        const field_dup = allocator.dupe(u8, key) catch {
                            allocator.free(state_json);
                            return MergeVariablesError.OutOfMemory;
                        };
                        violation_out.* = SchemaViolationDetail{
                            .affected_field = field_dup,
                            .reason = result.message,
                            .variable_state = state_json,
                        };
                        return MergeVariablesError.SchemaViolation;
                    }
                } else |_| {
                    // Unparseable schema string → treat as no constraint.
                }
            }

            // Path 2: collision — variable already exists in current_vars.
            if (current_vars.get(key)) |old_val| {
                const old_json = std.json.Stringify.valueAlloc(allocator, old_val, .{}) catch
                    return MergeVariablesError.OutOfMemory;
                const new_json = std.json.Stringify.valueAlloc(allocator, new_value, .{}) catch {
                    allocator.free(old_json);
                    return MergeVariablesError.OutOfMemory;
                };
                const key_dup = allocator.dupe(u8, key) catch {
                    allocator.free(old_json);
                    allocator.free(new_json);
                    return MergeVariablesError.OutOfMemory;
                };
                overwritten.append(allocator, VariableOverwrittenPayload{
                    .event_type = "VARIABLE_OVERWRITTEN",
                    .instance_id = instance_id,
                    .task_id = task_id,
                    .key = key_dup,
                    .old_value = old_json,
                    .new_value = new_json,
                }) catch {
                    allocator.free(key_dup);
                    allocator.free(old_json);
                    allocator.free(new_json);
                    return MergeVariablesError.OutOfMemory;
                };
            }

            // Path 2 or 3: apply the new value (cloning the key for the merged map).
            merged.put(allocator, key, new_value) catch return MergeVariablesError.OutOfMemory;
        }

        const events_slice = overwritten.toOwnedSlice(allocator) catch return MergeVariablesError.OutOfMemory;
        return MergeVariablesResult{
            .merged = merged,
            .overwritten_events = events_slice,
        };
    }

    // -----------------------------------------------------------------------
    // cancelInstance  (EE-08)
    // -----------------------------------------------------------------------

    /// Cancel a running process instance atomically.
    ///
    /// Implements the full EE-08 8-step algorithm (design §3):
    ///   a. Acquire connection and BEGIN TRANSACTION.
    ///   b. SELECT status, current_nodes FROM instance_projections FOR UPDATE.
    ///   c. 0 rows → InstanceNotFound; status CANCELLED/COMPLETED → InstanceAlreadyTerminated.
    ///   d. UPDATE tasks SET status='CANCELLED' WHERE instance_id=$1 AND status='PENDING'
    ///      RETURNING id — collect cancelled_task_ids.
    ///   e. UPDATE timers SET status='cancelled' WHERE instance_id=$1 AND status='pending'
    ///      RETURNING id — collect cancelled_timer_ids.
    ///   f. INSERT INSTANCE_CANCELLED event with structured payload (§5).
    ///   g. UPDATE instance_projections SET status='CANCELLED', current_nodes=cleared,
    ///      cancelled_at=NOW(), updated_at=NOW().
    ///   h. COMMIT. Return void.
    ///
    /// Steps a–h execute as a single DB transaction. Any failure triggers ROLLBACK via
    /// errdefer. ACTIVE and ERROR instances are both cancellable (OQ-EE08-1).
    ///
    /// Security: all SQL parameter values bound as $N positional parameters.
    /// No user-supplied value (instance_id, actor_id) is concatenated into any SQL
    /// string literal at any point in the call chain.
    pub fn cancelInstance(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        task_store: *task_mod.TaskStore,
        instance_id: Uuid,
        actor_id: []const u8,
    ) CancelInstanceError!void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, instance_id) catch return CancelInstanceError.OutOfMemory;

        // ── Step a: Acquire connection and BEGIN TRANSACTION ──────────────────
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return CancelInstanceError.PoolExhausted,
            else => return CancelInstanceError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        conn.begin() catch return CancelInstanceError.PersistenceFailed;
        // ROLLBACK fires on any error return after BEGIN.
        errdefer conn.rollback() catch {};

        // ── Step b: Lock and read the instance row ────────────────────────────
        // FOR UPDATE acquires an exclusive row-level lock held until COMMIT,
        // serialising concurrent cancel + task-complete requests (EE-12 AC).
        // Security: $1 = instance_id as hex UUID — no SQL string interpolation.
        const lock_rows = conn.query(
            a,
            \\SELECT status, current_nodes FROM instance_projections
            \\WHERE instance_id = $1::uuid
            \\FOR UPDATE
        ,
            &.{inst_id_hex},
        ) catch return CancelInstanceError.PersistenceFailed;
        defer {
            var r = lock_rows;
            r.deinit();
        }

        // ── Step c: Validate instance status ─────────────────────────────────
        if (lock_rows.rows.len == 0) {
            conn.rollback() catch {};
            return CancelInstanceError.InstanceNotFound;
        }

        const status_str = colGet(lock_rows.rows[0], 0);
        const current_status = parseInstanceStatus(status_str) catch .ERROR;
        // CANCELLED and COMPLETED are terminal — return 409.
        // ACTIVE and ERROR are both cancellable (OQ-EE08-1 resolution).
        if (current_status == .CANCELLED or current_status == .COMPLETED) {
            conn.rollback() catch {};
            return CancelInstanceError.InstanceAlreadyTerminated;
        }

        // Capture current_nodes JSON for branch_id extraction (step f payload).
        const current_nodes_json = a.dupe(u8, colGet(lock_rows.rows[0], 1)) catch
            return CancelInstanceError.OutOfMemory;

        // ── Step d: Cancel all PENDING tasks, collect their IDs ───────────────
        // task_store.cancelInTx issues:
        //   UPDATE tasks SET status='CANCELLED', updated_at=NOW()
        //   WHERE instance_id=$1::uuid AND status='PENDING' RETURNING id
        // Returns the count; here we need task IDs for the payload, so we also
        // collect them via a separate query on the same connection (inside the tx).
        //
        // First collect task IDs about to be cancelled (before the UPDATE).
        const task_id_rows = conn.query(
            a,
            \\SELECT id FROM tasks
            \\WHERE instance_id = $1::uuid
            \\  AND status = 'PENDING'
        ,
            &.{inst_id_hex},
        ) catch return CancelInstanceError.PersistenceFailed;

        var cancelled_task_ids = std.ArrayList([]u8).empty;
        defer cancelled_task_ids.deinit(a);
        for (task_id_rows.rows) |row| {
            const id_str = colGet(row, 0);
            if (id_str.len > 0) {
                const duped = a.dupe(u8, id_str) catch return CancelInstanceError.OutOfMemory;
                cancelled_task_ids.append(a, duped) catch return CancelInstanceError.OutOfMemory;
            }
        }
        {
            var r = task_id_rows;
            r.deinit();
        }

        // Now perform the actual cancellation via task_store.cancelInTx.
        _ = task_store.cancelInTx(allocator, conn, instance_id) catch
            return CancelInstanceError.PersistenceFailed;

        // ── Step e: Cancel all pending timers (SCH-03), collect their IDs ─────
        // Timers table uses lowercase 'pending'/'cancelled' status values.
        // Security: $1 = instance_id — bound as $N parameter.
        const timer_id_rows = conn.query(
            a,
            \\SELECT id FROM timers
            \\WHERE instance_id = $1::uuid
            \\  AND status = 'pending'
        ,
            &.{inst_id_hex},
        ) catch return CancelInstanceError.PersistenceFailed;

        var cancelled_timer_ids = std.ArrayList([]u8).empty;
        defer cancelled_timer_ids.deinit(a);
        for (timer_id_rows.rows) |row| {
            const id_str = colGet(row, 0);
            if (id_str.len > 0) {
                const duped = a.dupe(u8, id_str) catch return CancelInstanceError.OutOfMemory;
                cancelled_timer_ids.append(a, duped) catch return CancelInstanceError.OutOfMemory;
            }
        }
        {
            var r = timer_id_rows;
            r.deinit();
        }

        conn.exec(
            \\UPDATE timers
            \\SET
            \\    status       = 'cancelled',
            \\    cancelled_at = NOW()
            \\WHERE instance_id = $1::uuid
            \\  AND status      = 'pending'
        ,
            &.{inst_id_hex},
        ) catch return CancelInstanceError.PersistenceFailed;

        // ── Step f: Build and insert INSTANCE_CANCELLED event ────────────────
        // Extract active token branch_ids from current_nodes JSON.
        // current_nodes is stored as a JSON array of {node_id, branch_id} objects.
        var active_branch_ids = std.ArrayList([]u8).empty;
        defer active_branch_ids.deinit(a);
        extractBranchIds(a, current_nodes_json, &active_branch_ids);

        // Serialize the structured event payload (design §5).
        // Security: payload is built from internal data only; actor_id is bound
        // via $N parameter and not concatenated into the SQL literal.
        const payload_json = buildCancelPayload(a, cancelled_task_ids.items, cancelled_timer_ids.items, active_branch_ids.items, actor_id) catch
            return CancelInstanceError.OutOfMemory;

        // Generate idempotency key (random UUID v4).
        var idem_bytes: Uuid = undefined;
        fillRandom(&idem_bytes);
        idem_bytes[6] = (idem_bytes[6] & 0x0f) | 0x40;
        idem_bytes[8] = (idem_bytes[8] & 0x3f) | 0x80;
        const idem_key_hex = uuidToHex(a, idem_bytes) catch return CancelInstanceError.OutOfMemory;

        // Security: $1=instance_id, $2=event_type, $3=payload, $4=idempotency_key,
        //           $5=actor_id — all bound as $N parameters; no SQL string interpolation.
        conn.exec(
            \\WITH seq AS (
            \\    INSERT INTO instance_sequence (instance_id, next_seq)
            \\    VALUES ($1::uuid, 2)
            \\    ON CONFLICT (instance_id) DO UPDATE
            \\        SET next_seq = instance_sequence.next_seq + 1
            \\    RETURNING next_seq - 1 AS val
            \\)
            \\INSERT INTO events
            \\    (instance_id, event_type, payload, actor_id,
            \\     sequence_number, idempotency_key)
            \\SELECT $1::uuid, $2, $3::jsonb, $4, seq.val, $5
            \\FROM seq
        ,
            &.{ inst_id_hex, "INSTANCE_CANCELLED", payload_json, actor_id, idem_key_hex },
        ) catch return CancelInstanceError.PersistenceFailed;

        // ── Step g: UPDATE instance_projections ───────────────────────────────
        // Set status=CANCELLED, clear current_nodes, record cancelled_at.
        // Security: $1 = instance_id — bound as $N parameter.
        conn.exec(
            \\UPDATE instance_projections
            \\SET
            \\    status        = 'CANCELLED',
            \\    current_nodes = '{"tokens":[],"cancelled_branch_ids":[]}'::jsonb,
            \\    cancelled_at  = NOW(),
            \\    updated_at    = NOW()
            \\WHERE instance_id = $1::uuid
        ,
            &.{inst_id_hex},
        ) catch return CancelInstanceError.PersistenceFailed;

        // ── Step h: COMMIT ────────────────────────────────────────────────────
        conn.commit() catch return CancelInstanceError.PersistenceFailed;
    }

    // -----------------------------------------------------------------------
    // getById  (API-03)
    // -----------------------------------------------------------------------

    /// Fetch a single instance projection plus all PENDING tasks for that instance.
    ///
    /// Algorithm:
    ///   a. Acquire connection.
    ///   b. SELECT instance_projections WHERE instance_id=$1::uuid.
    ///      0 rows → InstanceNotFound.
    ///   c. SELECT tasks WHERE instance_id=$1::uuid AND status='PENDING'.
    ///      0 rows is valid — instance may be in a terminal state.
    ///   d. Return InstanceWithTasks (caller-owned).
    ///
    /// Security: both queries use $1::uuid — no SQL string interpolation.
    pub fn getById(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        instance_id: Uuid,
    ) GetByIdError!InstanceWithTasks {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, instance_id) catch return GetByIdError.OutOfMemory;

        // ── Step a+b: Acquire connection, SELECT instance row ─────────────────
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return GetByIdError.PoolExhausted,
            else => return GetByIdError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        // Security: $1 = instance_id as hex UUID — no SQL string interpolation.
        const proj_rows = conn.query(
            a,
            \\SELECT
            \\    instance_id,
            \\    definition_id,
            \\    correlation_key,
            \\    status,
            \\    variables,
            \\    error_detail,
            \\    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM completed_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM cancelled_at) * 1000000)::bigint
            \\FROM instance_projections
            \\WHERE instance_id = $1::uuid
        ,
            &.{inst_id_hex},
        ) catch return GetByIdError.PersistenceFailed;
        defer {
            var r = proj_rows;
            r.deinit();
        }

        if (proj_rows.rows.len == 0) return GetByIdError.InstanceNotFound;

        const row = proj_rows.rows[0];

        const instance_id_out = parseUuid(colGet(row, 0)) catch std.mem.zeroes(Uuid);
        const definition_id = parseUuid(colGet(row, 1)) catch std.mem.zeroes(Uuid);

        // correlation_key — nullable column
        const ck_col: ?[]u8 = if (row.len > 2) row[2] else null;
        const correlation_key: ?[]const u8 = if (ck_col) |ck|
            allocator.dupe(u8, ck) catch return GetByIdError.OutOfMemory
        else
            null;
        errdefer if (correlation_key) |ck| allocator.free(ck);

        const status = parseInstanceStatus(colGet(row, 3)) catch .ACTIVE;

        // variables (JSONB text, always present)
        const variables_raw = colGet(row, 4);
        const variables = allocator.dupe(u8, variables_raw) catch return GetByIdError.OutOfMemory;
        errdefer allocator.free(variables);

        // error_detail — nullable column
        const ed_col: ?[]u8 = if (row.len > 5) row[5] else null;
        const error_detail: ?[]const u8 = if (ed_col) |ed|
            allocator.dupe(u8, ed) catch return GetByIdError.OutOfMemory
        else
            null;
        errdefer if (error_detail) |ed| allocator.free(ed);

        const started_at = std.fmt.parseInt(i64, colGet(row, 6), 10) catch 0;
        const completed_at: ?i64 = blk: {
            const ca_col: ?[]u8 = if (row.len > 7) row[7] else null;
            const s = if (ca_col) |c| c else break :blk null;
            if (s.len == 0) break :blk null;
            break :blk std.fmt.parseInt(i64, s, 10) catch null;
        };
        const cancelled_at: ?i64 = blk: {
            const ca_col: ?[]u8 = if (row.len > 8) row[8] else null;
            const s = if (ca_col) |c| c else break :blk null;
            if (s.len == 0) break :blk null;
            break :blk std.fmt.parseInt(i64, s, 10) catch null;
        };

        // ── Step c: SELECT PENDING tasks for this instance ──────────────────
        // Security: $1 = instance_id as hex UUID — no SQL string interpolation.
        const task_rows = conn.query(
            a,
            \\SELECT
            \\    id,
            \\    node_id,
            \\    node_name,
            \\    status,
            \\    assignee_type,
            \\    assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint
            \\FROM tasks
            \\WHERE instance_id = $1::uuid
            \\  AND status = 'PENDING'
            \\ORDER BY created_at ASC
        ,
            &.{inst_id_hex},
        ) catch return GetByIdError.PersistenceFailed;
        defer {
            var r = task_rows;
            r.deinit();
        }

        // Build caller-owned []task_mod.Task slice.
        const tasks = allocator.alloc(task_mod.Task, task_rows.rows.len) catch
            return GetByIdError.OutOfMemory;
        errdefer {
            for (tasks) |t| task_mod.freeTask(allocator, t);
            allocator.free(tasks);
        }
        for (task_rows.rows, 0..) |trow, i| {
            const task_id = parseUuid(colGet(trow, 0)) catch std.mem.zeroes(Uuid);
            const node_id = allocator.dupe(u8, colGet(trow, 1)) catch return GetByIdError.OutOfMemory;
            const node_name = allocator.dupe(u8, colGet(trow, 2)) catch {
                allocator.free(node_id);
                return GetByIdError.OutOfMemory;
            };
            const t_status: task_mod.TaskStatus = task_mod.parseTaskStatus(colGet(trow, 3)) catch .PENDING;

            const at_col2: ?[]u8 = if (trow.len > 4) trow[4] else null;
            const t_assignee_type: ?[]const u8 = if (at_col2) |at|
                allocator.dupe(u8, at) catch return GetByIdError.OutOfMemory
            else
                null;
            const ar_col2: ?[]u8 = if (trow.len > 5) trow[5] else null;
            const t_assignee_ref: ?[]const u8 = if (ar_col2) |ar|
                allocator.dupe(u8, ar) catch return GetByIdError.OutOfMemory
            else
                null;

            const t_created_at = std.fmt.parseInt(i64, colGet(trow, 6), 10) catch 0;

            tasks[i] = task_mod.Task{
                .task_id = task_id,
                .instance_id = instance_id,
                .token_id = std.mem.zeroes(Uuid), // not selected; unused in this context
                .node_id = node_id,
                .node_name = node_name,
                .status = t_status,
                .assignee_type = t_assignee_type,
                .assignee_ref = t_assignee_ref,
                .created_at = t_created_at,
                .updated_at = t_created_at, // updated_at not fetched; use created_at as stub
            };
        }

        return InstanceWithTasks{
            .instance_id = instance_id_out,
            .definition_id = definition_id,
            .correlation_key = correlation_key,
            .status = status,
            .variables = variables,
            .error_detail = error_detail,
            .started_at = started_at,
            .completed_at = completed_at,
            .cancelled_at = cancelled_at,
            .tasks = tasks,
        };
    }

    // -----------------------------------------------------------------------
    // list  (API-03)
    // -----------------------------------------------------------------------

    /// Fetch a page of instances from instance_projections.
    ///
    /// Results are ordered by (started_at DESC, instance_id DESC) for stable
    /// keyset pagination. Returns exactly page_size+1 rows or fewer (the extra
    /// row signals to the caller that a next page exists).
    ///
    /// Security: all filter values and the cursor seek values are bound as $N
    /// positional parameters — no SQL string interpolation of user input.
    pub fn listInstances(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        params: ListParams,
    ) ListError![]InstanceProjectionRow {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return ListError.PoolExhausted,
            else => return ListError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        // Build parameters list and SQL for the two query variants (cursor / no cursor).
        // Security: all user values go into the params array; the SQL string contains
        // only schema identifiers and $N placeholders.
        const limit_plus_one = @as(u32, params.page_size) + 1;
        const limit_str = std.fmt.allocPrint(a, "{d}", .{limit_plus_one}) catch
            return ListError.OutOfMemory;

        const status_param: []const u8 = params.status orelse "";
        const def_id_param: []const u8 = if (params.definition_id) |did|
            uuidToHex(a, did) catch return ListError.OutOfMemory
        else
            "";

        const rows = blk: {
            if (params.cursor_started_at == null) {
                // No-cursor variant:
                //   SELECT ... WHERE ($2::text IS NULL OR status = $2)
                //                AND ($3::uuid IS NULL OR definition_id = $3::uuid)
                //   ORDER BY started_at DESC, instance_id DESC  LIMIT $1
                break :blk conn.query(
                    a,
                    \\SELECT
                    \\    instance_id,
                    \\    definition_id,
                    \\    correlation_key,
                    \\    status,
                    \\    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint AS started_at_us
                    \\FROM instance_projections
                    \\WHERE (NULLIF($2, '')::text IS NULL OR status = $2)
                    \\  AND (NULLIF($3, '')::uuid IS NULL OR definition_id = NULLIF($3, '')::uuid)
                    \\ORDER BY started_at DESC, instance_id DESC
                    \\LIMIT $1
                ,
                    &.{ limit_str, status_param, def_id_param },
                ) catch return ListError.PersistenceFailed;
            } else {
                // Cursor variant — seek past the last-seen item.
                // $2 = started_at_us (bigint as text), $3 = cursor_instance_id (hex UUID)
                // $4 = status filter, $5 = definition_id filter
                const cursor_ts_str = std.fmt.allocPrint(
                    a,
                    "{d}",
                    .{params.cursor_started_at.?},
                ) catch return ListError.OutOfMemory;
                const cursor_id_str = params.cursor_instance_id orelse "";

                break :blk conn.query(
                    a,
                    \\SELECT
                    \\    instance_id,
                    \\    definition_id,
                    \\    correlation_key,
                    \\    status,
                    \\    (EXTRACT(EPOCH FROM started_at) * 1000000)::bigint AS started_at_us
                    \\FROM instance_projections
                    \\WHERE (NULLIF($4, '')::text IS NULL OR status = $4)
                    \\  AND (NULLIF($5, '')::uuid IS NULL OR definition_id = NULLIF($5, '')::uuid)
                    \\  AND (started_at, instance_id) < (
                    \\        to_timestamp($2::bigint / 1000000.0),
                    \\        $3::uuid
                    \\      )
                    \\ORDER BY started_at DESC, instance_id DESC
                    \\LIMIT $1
                ,
                    &.{ limit_str, cursor_ts_str, cursor_id_str, status_param, def_id_param },
                ) catch return ListError.PersistenceFailed;
            }
        };
        defer {
            var r = rows;
            r.deinit();
        }

        // Convert rows to caller-owned []InstanceProjectionRow.
        const result = allocator.alloc(InstanceProjectionRow, rows.rows.len) catch
            return ListError.OutOfMemory;
        errdefer allocator.free(result);

        for (rows.rows, 0..) |row, i| {
            const iid = parseUuid(colGet(row, 0)) catch std.mem.zeroes(Uuid);
            const did = parseUuid(colGet(row, 1)) catch std.mem.zeroes(Uuid);

            const ck_col: ?[]u8 = if (row.len > 2) row[2] else null;
            const ck: ?[]const u8 = if (ck_col) |ck|
                allocator.dupe(u8, ck) catch return ListError.OutOfMemory
            else
                null;

            const status = parseInstanceStatus(colGet(row, 3)) catch .ACTIVE;
            const started_at = std.fmt.parseInt(i64, colGet(row, 4), 10) catch 0;

            result[i] = InstanceProjectionRow{
                .instance_id = iid,
                .definition_id = did,
                .correlation_key = ck,
                .status = status,
                .started_at = started_at,
            };
        }

        return result;
    }

    // -----------------------------------------------------------------------
    // setInstanceError  (EE-10)
    // -----------------------------------------------------------------------

    /// Atomically transition an instance to ERROR status.
    ///
    /// Algorithm (design §6 EE-10):
    ///   a. Acquire connection and BEGIN TRANSACTION.
    ///   b. SELECT status, variables FROM instance_projections FOR UPDATE.
    ///      0 rows → InstanceNotFound.
    ///      status IN (ERROR, CANCELLED, COMPLETED) → AlreadyTerminal (ROLLBACK).
    ///      status = ACTIVE → proceed.
    ///   c. Serialise the EXECUTION_ERROR event payload JSON.
    ///   d. INSERT INTO events with event_type='EXECUTION_ERROR'.
    ///   e. UPDATE instance_projections SET status='ERROR', error_detail=payload.
    ///   f. COMMIT. Return void.
    ///
    /// Atomicity: steps a–f are a single DB transaction. Any failure issues ROLLBACK
    /// via errdefer. The instance either fully transitions to ERROR or remains unchanged.
    ///
    /// Security: all SQL values bound as $N parameters — no SQL string interpolation.
    /// args.variable_state, args.actor_id, and the serialised payload are all bound
    /// as $N parameters. No user-supplied value is concatenated into any SQL literal.
    pub fn setInstanceError(
        self: *InstanceStore,
        allocator: std.mem.Allocator,
        args: SetInstanceErrorArgs,
    ) SetInstanceErrorError!void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, args.instance_id) catch
            return SetInstanceErrorError.OutOfMemory;

        // ── Step a: Acquire connection and BEGIN TRANSACTION ──────────────────
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return SetInstanceErrorError.PoolExhausted,
            else => return SetInstanceErrorError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        conn.begin() catch return SetInstanceErrorError.PersistenceFailed;
        // ROLLBACK fires on any error return after BEGIN.
        errdefer conn.rollback() catch {};

        // ── Step b: Lock and read the instance row ────────────────────────────
        // FOR UPDATE serialises concurrent ERROR-triggering operations (§7).
        // Security: $1 = instance_id as hex UUID — no SQL string interpolation.
        const lock_rows = conn.query(
            a,
            \\SELECT status, variables
            \\FROM instance_projections
            \\WHERE instance_id = $1::uuid
            \\FOR UPDATE
        ,
            &.{inst_id_hex},
        ) catch return SetInstanceErrorError.PersistenceFailed;
        defer {
            var r = lock_rows;
            r.deinit();
        }

        if (lock_rows.rows.len == 0) {
            conn.rollback() catch {};
            return SetInstanceErrorError.InstanceNotFound;
        }

        const current_status_str = colGet(lock_rows.rows[0], 0);
        const current_status = parseInstanceStatus(current_status_str) catch .ACTIVE;
        if (current_status == .ERROR or current_status == .CANCELLED or current_status == .COMPLETED) {
            conn.rollback() catch {};
            return SetInstanceErrorError.AlreadyTerminal;
        }
        // status = ACTIVE → proceed.

        // ── Step c: Serialise event payload ──────────────────────────────────
        const payload_json = buildExecutionErrorPayload(allocator, inst_id_hex, args) catch
            return SetInstanceErrorError.OutOfMemory;
        defer allocator.free(payload_json);

        // ── Step d: INSERT EXECUTION_ERROR event ──────────────────────────────
        // Generate a random idempotency key UUID (same pattern as cancelInstance).
        var idem_bytes: Uuid = undefined;
        fillRandom(&idem_bytes);
        idem_bytes[6] = (idem_bytes[6] & 0x0f) | 0x40;
        idem_bytes[8] = (idem_bytes[8] & 0x3f) | 0x80;
        const idem_key_hex = uuidToHex(a, idem_bytes) catch return SetInstanceErrorError.OutOfMemory;

        // Security: $1=instance_id, $2=payload, $3=actor_id, $4=idempotency_key
        //           — all bound as $N params; no SQL string interpolation.
        conn.exec(
            \\WITH seq AS (
            \\    INSERT INTO instance_sequence (instance_id, next_seq)
            \\    VALUES ($1::uuid, 2)
            \\    ON CONFLICT (instance_id) DO UPDATE
            \\        SET next_seq = instance_sequence.next_seq + 1
            \\    RETURNING next_seq - 1 AS val
            \\)
            \\INSERT INTO events
            \\    (instance_id, event_type, payload, actor_id,
            \\     sequence_number, idempotency_key)
            \\SELECT $1::uuid, 'EXECUTION_ERROR', $2::jsonb, $3,
            \\       seq.val, $4
            \\FROM seq
        ,
            &.{ inst_id_hex, payload_json, args.actor_id, idem_key_hex },
        ) catch return SetInstanceErrorError.PersistenceFailed;

        // ── Step e: UPDATE instance_projections ───────────────────────────────
        // Security: $1=instance_id, $2=payload — all bound as $N params.
        conn.exec(
            \\UPDATE instance_projections
            \\SET
            \\    status       = 'ERROR',
            \\    error_detail = $2::jsonb,
            \\    updated_at   = NOW()
            \\WHERE instance_id = $1::uuid
        ,
            &.{ inst_id_hex, payload_json },
        ) catch return SetInstanceErrorError.PersistenceFailed;

        // ── Step f: COMMIT ────────────────────────────────────────────────────
        conn.commit() catch return SetInstanceErrorError.PersistenceFailed;
    }
};

// ---------------------------------------------------------------------------
// EE-10 helpers (module-level)
// ---------------------------------------------------------------------------

/// Map a SetInstanceErrorError to the nearest CompleteTaskError variant.
pub fn mapSetErrorToCompleteError(err: SetInstanceErrorError) CompleteTaskError {
    return switch (err) {
        SetInstanceErrorError.PoolExhausted => CompleteTaskError.PoolExhausted,
        SetInstanceErrorError.OutOfMemory => CompleteTaskError.OutOfMemory,
        SetInstanceErrorError.InstanceNotFound => CompleteTaskError.PersistenceFailed,
        SetInstanceErrorError.AlreadyTerminal => CompleteTaskError.InstanceInError,
        SetInstanceErrorError.PersistenceFailed => CompleteTaskError.PersistenceFailed,
    };
}

/// Build the EXECUTION_ERROR event payload JSON string (EE-10 §4).
///
/// Shape (NO_MATCHING_EDGE):
///   {
///     "event_type": "EXECUTION_ERROR",
///     "instance_id": "<uuid>",
///     "error_type": "NO_MATCHING_EDGE",
///     "affected_node": "<node_id>",
///     "reason": "<string>",
///     "variable_state": { ... },
///     "evaluated_conditions": [ { "edge_id": "...", "condition": "...", "result": false }, ... ]
///   }
///
/// Shape (SCHEMA_VIOLATION):
///   {
///     "event_type": "EXECUTION_ERROR",
///     "instance_id": "<uuid>",
///     "error_type": "SCHEMA_VIOLATION",
///     "affected_field": "<variable_key>",
///     "reason": "<string>",
///     "variable_state": { ... }
///   }
///
/// Security: all string fields are serialised through std.json.stringify — no raw
/// concatenation of user-supplied values into the JSON literal.
fn buildExecutionErrorPayload(
    allocator: std.mem.Allocator,
    instance_id_hex: []const u8,
    args: SetInstanceErrorArgs,
) error{OutOfMemory}![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    const error_type_str: []const u8 = switch (args.error_type) {
        .NO_MATCHING_EDGE => "NO_MATCHING_EDGE",
        .SCHEMA_VIOLATION => "SCHEMA_VIOLATION",
    };

    // Helper: serialise a string as a JSON-quoted value.
    const strJson = struct {
        fn f(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
            return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .string = s }, .{});
        }
    }.f;

    const inst_json = try strJson(allocator, instance_id_hex);
    defer allocator.free(inst_json);
    const etype_json = try strJson(allocator, error_type_str);
    defer allocator.free(etype_json);
    const reason_json = try strJson(allocator, args.reason);
    defer allocator.free(reason_json);

    try buf.appendSlice(allocator, "{\"event_type\":\"EXECUTION_ERROR\"");
    try buf.appendSlice(allocator, ",\"instance_id\":");
    try buf.appendSlice(allocator, inst_json);
    try buf.appendSlice(allocator, ",\"error_type\":");
    try buf.appendSlice(allocator, etype_json);

    switch (args.error_type) {
        .NO_MATCHING_EDGE => {
            if (args.affected_node) |node| {
                const node_json = try strJson(allocator, node);
                defer allocator.free(node_json);
                try buf.appendSlice(allocator, ",\"affected_node\":");
                try buf.appendSlice(allocator, node_json);
            }
        },
        .SCHEMA_VIOLATION => {
            if (args.affected_field) |field| {
                const field_json = try strJson(allocator, field);
                defer allocator.free(field_json);
                try buf.appendSlice(allocator, ",\"affected_field\":");
                try buf.appendSlice(allocator, field_json);
            }
        },
    }

    try buf.appendSlice(allocator, ",\"reason\":");
    try buf.appendSlice(allocator, reason_json);

    // variable_state is already a valid JSON object string (caller-supplied).
    try buf.appendSlice(allocator, ",\"variable_state\":");
    try buf.appendSlice(allocator, args.variable_state);

    // evaluated_conditions: only present for NO_MATCHING_EDGE.
    if (args.evaluated_conditions) |conds| {
        try buf.appendSlice(allocator, ",\"evaluated_conditions\":[");
        for (conds, 0..) |c, i| {
            if (i > 0) try buf.append(allocator, ',');
            const eid_json = try strJson(allocator, c.edge_id);
            defer allocator.free(eid_json);
            const cond_json = try strJson(allocator, c.condition);
            defer allocator.free(cond_json);
            try buf.appendSlice(allocator, "{\"edge_id\":");
            try buf.appendSlice(allocator, eid_json);
            try buf.appendSlice(allocator, ",\"condition\":");
            try buf.appendSlice(allocator, cond_json);
            try buf.appendSlice(allocator, ",\"result\":false}");
        }
        try buf.append(allocator, ']');
    }

    try buf.append(allocator, '}');
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// EE-09 event payload builders (module-level, not methods)
// ---------------------------------------------------------------------------

/// Build the EXECUTION_ERROR event payload JSON (EE-09 §7).
/// Security: all string fields serialised via std.json — no raw concatenation.
fn buildErrorPayload(
    allocator: std.mem.Allocator,
    instance_id_hex: []const u8,
    task_id_hex: []const u8,
    detail: SchemaViolationDetail,
) error{OutOfMemory}![]u8 {
    const affected_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = detail.affected_field },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(affected_json);

    const reason_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = detail.reason },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(reason_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"event_type\":\"EXECUTION_ERROR\",\"instance_id\":\"{s}\",\"task_id\":\"{s}\",\"error_type\":\"SCHEMA_VIOLATION\",\"affected_field\":{s},\"reason\":{s},\"variable_state\":{s}}}",
        .{ instance_id_hex, task_id_hex, affected_json, reason_json, detail.variable_state },
    );
}

/// Build a VARIABLE_OVERWRITTEN event payload JSON (EE-09 §8).
/// Security: key is serialised via std.json — no raw concatenation.
fn buildOverwrittenPayload(
    allocator: std.mem.Allocator,
    instance_id_hex: []const u8,
    ev: VariableOverwrittenPayload,
) error{OutOfMemory}![]u8 {
    const key_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .string = ev.key },
        .{},
    ) catch return error.OutOfMemory;
    defer allocator.free(key_json);

    if (ev.task_id) |tid| {
        const tid_hex = uuidToHex(allocator, tid) catch return error.OutOfMemory;
        defer allocator.free(tid_hex);
        return std.fmt.allocPrint(
            allocator,
            "{{\"event_type\":\"VARIABLE_OVERWRITTEN\",\"instance_id\":\"{s}\",\"task_id\":\"{s}\",\"key\":{s},\"old_value\":{s},\"new_value\":{s}}}",
            .{ instance_id_hex, tid_hex, key_json, ev.old_value, ev.new_value },
        );
    } else {
        return std.fmt.allocPrint(
            allocator,
            "{{\"event_type\":\"VARIABLE_OVERWRITTEN\",\"instance_id\":\"{s}\",\"task_id\":null,\"key\":{s},\"old_value\":{s},\"new_value\":{s}}}",
            .{ instance_id_hex, key_json, ev.old_value, ev.new_value },
        );
    }
}

// ---------------------------------------------------------------------------
// Row parsing helpers
// ---------------------------------------------------------------------------

/// Columns returned by the INSERT RETURNING query:
///   0  instance_id     UUID text
///   1  definition_id   UUID text
///   2  correlation_key TEXT or NULL
///   3  status          TEXT
///   4  variables       JSONB text
///   5  started_at      bigint (UTC µs)
///   6  updated_at      bigint (UTC µs)
fn rowToInstance(
    allocator: std.mem.Allocator,
    row: []?[]u8,
    initial_variables: []const u8,
) error{OutOfMemory}!Instance {
    const instance_id = parseUuid(colGet(row, 0)) catch std.mem.zeroes(Uuid);
    const definition_id = parseUuid(colGet(row, 1)) catch std.mem.zeroes(Uuid);

    // Column 2 is nullable (SQL NULL for no correlation_key).
    const ck_col: ?[]u8 = if (row.len > 2) row[2] else null;
    const correlation_key: ?[]const u8 = if (ck_col) |ck|
        try allocator.dupe(u8, ck)
    else
        null;

    const status_str = colGet(row, 3);
    const status: InstanceStatus = parseInstanceStatus(status_str) catch .ACTIVE;

    // initial_variables is duplicated from the caller's parameter (not the DB
    // column) so the caller owns the returned slice independently.
    const vars = try allocator.dupe(u8, initial_variables);

    // definition_snapshot is a stub until pg.zig delivers real rows.
    const snap = try allocator.dupe(u8, "{}");

    const created_at = std.fmt.parseInt(i64, colGet(row, 5), 10) catch 0;
    const updated_at = std.fmt.parseInt(i64, colGet(row, 6), 10) catch 0;

    return Instance{
        .instance_id = instance_id,
        .definition_id = definition_id,
        .status = status,
        .correlation_key = correlation_key,
        .initial_variables = vars,
        .definition_snapshot = snap,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

// ---------------------------------------------------------------------------
// Module-level helper functions
// ---------------------------------------------------------------------------

inline fn colGet(row: []?[]u8, i: usize) []const u8 {
    if (i >= row.len) return "";
    return row[i] orelse "";
}

fn parseInstanceStatus(s: []const u8) error{InvalidStatus}!InstanceStatus {
    if (std.mem.eql(u8, s, "ACTIVE")) return .ACTIVE;
    if (std.mem.eql(u8, s, "COMPLETED")) return .COMPLETED;
    if (std.mem.eql(u8, s, "CANCELLED")) return .CANCELLED;
    if (std.mem.eql(u8, s, "ERROR")) return .ERROR;
    return error.InvalidStatus;
}

/// Render a UUID as lowercase hex with hyphens: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
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

/// Parse a UUID hex string (36 chars with hyphens) into a raw [16]u8.
fn parseUuid(hex: []const u8) error{InvalidUuid}!Uuid {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: Uuid = undefined;
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

/// Serialize an InstanceStatus to uppercase TEXT for use as a SQL parameter.
fn instanceStatusToString(status: transition_mod.InstanceStatus) []const u8 {
    return switch (status) {
        .ACTIVE => "ACTIVE",
        .COMPLETED => "COMPLETED",
        .CANCELLED => "CANCELLED",
        .ERROR => "ERROR",
    };
}

/// Extract branch_id values from the current_nodes JSONB column value.
///
/// current_nodes is stored as a JSON array of objects with shape:
///   [{"node_id": "...", "branch_id": "..."}, ...]
///
/// On any parse error the list is left unchanged (empty or partially filled).
/// All strings are allocated into `allocator`.
fn extractBranchIds(
    allocator: std.mem.Allocator,
    current_nodes_json: []const u8,
    out: *std.ArrayList([]u8),
) void {
    if (current_nodes_json.len == 0) return;
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        current_nodes_json,
        .{ .allocate = .alloc_always },
    ) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const bid_val = item.object.get("branch_id") orelse continue;
        if (bid_val != .string) continue;
        const duped = allocator.dupe(u8, bid_val.string) catch return;
        out.append(allocator, duped) catch {
            allocator.free(duped);
            return;
        };
    }
}

/// Build the INSTANCE_CANCELLED event payload JSON string (design §5).
///
/// Shape:
///   {
///     "type": "INSTANCE_CANCELLED",
///     "reason": "OPERATOR",
///     "cancelled_task_ids": ["<uuid>", ...],
///     "cancelled_timer_ids": ["<uuid>", ...],
///     "active_token_branch_ids": ["<branch_id>", ...],
///     "actor_id": "<user_id>"
///   }
///
/// All slices are read-only inputs; the returned slice is owned by `allocator`.
fn buildCancelPayload(
    allocator: std.mem.Allocator,
    cancelled_task_ids: [][]u8,
    cancelled_timer_ids: [][]u8,
    active_branch_ids: [][]u8,
    actor_id: []const u8,
) error{OutOfMemory}![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"type\":\"INSTANCE_CANCELLED\",\"reason\":\"OPERATOR\"");

    // cancelled_task_ids array
    try buf.appendSlice(allocator, ",\"cancelled_task_ids\":[");
    for (cancelled_task_ids, 0..) |id, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, id);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');

    // cancelled_timer_ids array
    try buf.appendSlice(allocator, ",\"cancelled_timer_ids\":[");
    for (cancelled_timer_ids, 0..) |id, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, id);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');

    // active_token_branch_ids array
    try buf.appendSlice(allocator, ",\"active_token_branch_ids\":[");
    for (active_branch_ids, 0..) |bid, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, bid);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');

    // actor_id (bound via $N in SQL but also embedded in the payload for replay)
    try buf.appendSlice(allocator, ",\"actor_id\":\"");
    // Escape JSON special chars in actor_id.
    for (actor_id) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.appendSlice(allocator, "\"}");

    return buf.toOwnedSlice(allocator);
}

/// Parse `assignee_type` and `assignee_ref` from a node's JSON attributes string.
///
/// The attributes JSON has the shape: {"assignee_type": "USER", "assignee_ref": "..."}
/// Values are written into *assignee_type and *assignee_ref if present and are strings.
/// On any parse failure the pointers are left unchanged (already null).
fn parseAssigneeFields(
    allocator: std.mem.Allocator,
    attrs: []const u8,
    assignee_type: *?[]const u8,
    assignee_ref: *?[]const u8,
) void {
    var inner_arena = std.heap.ArenaAllocator.init(allocator);
    defer inner_arena.deinit();
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        inner_arena.allocator(),
        attrs,
        .{ .allocate = .alloc_always },
    ) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    if (obj.get("assignee_type")) |v| {
        if (v == .string) {
            assignee_type.* = allocator.dupe(u8, v.string) catch null;
        }
    }
    if (obj.get("assignee_ref")) |v| {
        if (v == .string) {
            assignee_ref.* = allocator.dupe(u8, v.string) catch null;
        }
    }
}
