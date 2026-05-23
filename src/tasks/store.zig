//! Task store — EE-03 (Task activation)
//!
//! Owns all DB-backed task creation and query logic against the `tasks` table.
//! `createInTx` uses an already-open DB connection; the caller owns the transaction.
//! `list` acquires its own connection from the pool.
//!
//! Design artefact: src/design/engine.md §EE-03
const std = @import("std");
const db = @import("../db/pool.zig");
const Pool = db.Pool;
const PoolError = db.PoolError;
const graph_mod = @import("../definition/graph.zig");

/// Raw 16-byte UUID v4 representation (same as graph_mod.Uuid).
pub const Uuid = graph_mod.Uuid;

// ---------------------------------------------------------------------------
// TaskStatus enum
// ---------------------------------------------------------------------------

pub const TaskStatus = enum {
    PENDING,
    COMPLETED,
    CANCELLED,
};

// ---------------------------------------------------------------------------
// Task struct
// ---------------------------------------------------------------------------

pub const Task = struct {
    /// Primary key from tasks.id.
    task_id: Uuid,
    /// FK to instance_projections.instance_id.
    instance_id: Uuid,
    /// FK to tokens.id — the execution token parked on this task node.
    token_id: Uuid,
    /// The HUMAN_TASK node_id in the definition graph.
    node_id: []const u8,
    /// The display name of the HUMAN_TASK node (from GraphNode.label).
    node_name: []const u8,
    /// Current lifecycle status.
    status: TaskStatus,
    /// Assignee type: USER | GROUP | ROLE, or null if unassigned.
    assignee_type: ?[]const u8,
    /// Assignee reference: user_id / group_name / role_name, or null.
    assignee_ref: ?[]const u8,
    /// UTC epoch microseconds derived from tasks.created_at.
    created_at: i64,
    /// UTC epoch microseconds derived from tasks.updated_at.
    updated_at: i64,
};

// ---------------------------------------------------------------------------
// TaskError
// ---------------------------------------------------------------------------

pub const TaskError = error{
    /// task_id not found in tasks table. HTTP 404.
    NotFound,
    /// Task status ≠ PENDING (already COMPLETED or CANCELLED). HTTP 409.
    AlreadyTerminated,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Malformed parameter (e.g. invalid UUID format, invalid status). HTTP 422.
    InvalidInput,
};

// ---------------------------------------------------------------------------
// AssignError  (API-04)
// ---------------------------------------------------------------------------

pub const AssignError = error{
    /// task_id not found. HTTP 404.
    NotFound,
    /// Task is already assigned (for assign) or not assigned (for reassign). HTTP 409.
    AssignmentConflict,
    /// Task status ≠ PENDING (cannot assign/reassign a completed/cancelled task). HTTP 409.
    AlreadyTerminated,
    /// db.Pool.acquire() failed (pool exhausted or shutdown). HTTP 503.
    PoolExhausted,
    /// Malformed parameter or DB error. HTTP 500.
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// ListCursorParams  (API-04 / API-06)
// ---------------------------------------------------------------------------

/// Parameters for TaskStore.listCursor().
pub const ListCursorParams = struct {
    /// Filter by assignee user_id (maps to assignee_ref where assignee_type='USER').
    /// Null = no filter. For TASK_WORKER: always set to actor.user_id.
    assignee_id: ?[]const u8,
    /// If true AND assignee_id is set: add AND assignee_type = 'USER'.
    /// Always true when filtering for role-based row restriction.
    assignee_type_user_only: bool,
    /// Optional status filter.
    status: ?TaskStatus,
    /// Optional instance_id filter.
    instance_id: ?Uuid,
    /// Decoded cursor values. Null = start from the top.
    cursor_created_at: ?i64,
    cursor_task_id: ?[]const u8,
    /// Page size [1..200].
    page_size: u16,
};

// ---------------------------------------------------------------------------
// TaskStore
// ---------------------------------------------------------------------------

pub const TaskStore = struct {
    pool: *Pool,

    /// pool must outlive TaskStore.
    pub fn init(pool: *Pool) TaskStore {
        return TaskStore{ .pool = pool };
    }

    // -----------------------------------------------------------------------
    // createInTx  (EE-03)
    // -----------------------------------------------------------------------

    /// Insert one row into `tasks` using an already-open DB connection.
    ///
    /// The caller owns the transaction; this function does NOT issue BEGIN or
    /// COMMIT. Use the returned Task to confirm the DB-generated task_id and
    /// created_at values.
    ///
    /// Security: all six parameter values are bound via $N positional
    /// placeholders — no SQL string interpolation of user-supplied or
    /// snapshot-derived data anywhere in this function.
    pub fn createInTx(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        instance_id: Uuid,
        token_id: Uuid,
        node_id: []const u8,
        node_name: []const u8,
        assignee_type: ?[]const u8,
        assignee_ref: ?[]const u8,
    ) TaskError!Task {
        _ = self;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, instance_id) catch return TaskError.InvalidInput;
        const tok_id_hex = uuidToHex(a, token_id) catch return TaskError.InvalidInput;

        // Use empty-string sentinel for NULL; NULLIF($5, '') converts back to
        // SQL NULL so that unassigned tasks have NULL assignee_type/ref.
        const at_param: []const u8 = assignee_type orelse "";
        const ar_param: []const u8 = assignee_ref orelse "";

        // Security: $1=instance_id, $2=token_id, $3=node_id, $4=node_name,
        //           $5=assignee_type, $6=assignee_ref — all bound as $N params.
        const rows = conn.query(
            allocator,
            \\INSERT INTO tasks
            \\    (instance_id, token_id, node_id, node_name, status,
            \\     assignee_type, assignee_ref)
            \\VALUES
            \\    ($1::uuid, $2::uuid, $3, $4, 'PENDING',
            \\     NULLIF($5, ''), NULLIF($6, ''))
            \\RETURNING
            \\    id,
            \\    instance_id,
            \\    token_id,
            \\    node_id,
            \\    node_name,
            \\    status,
            \\    assignee_type,
            \\    assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ inst_id_hex, tok_id_hex, node_id, node_name, at_param, ar_param },
        ) catch return TaskError.InvalidInput;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return TaskError.InvalidInput;
        return rowToTask(allocator, rows.rows[0]) catch TaskError.InvalidInput;
    }

    // -----------------------------------------------------------------------
    // getById  (EE-04)
    // -----------------------------------------------------------------------

    /// Fetch a single Task by primary key.
    ///
    /// Acquires its own connection from self.pool; the caller does not supply
    /// a connection. Returns TaskError.NotFound when 0 rows match.
    ///
    /// Security: task_id is bound exclusively as $1::uuid — no SQL string
    /// interpolation of user-supplied data.
    pub fn getById(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        task_id: Uuid,
    ) TaskError!Task {
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return TaskError.PoolExhausted,
            else => return TaskError.InvalidInput,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const task_id_hex = uuidToHex(a, task_id) catch return TaskError.InvalidInput;

        // Security: $1 = task_id as hex UUID — no SQL string interpolation.
        const rows = conn.query(
            allocator,
            \\SELECT
            \\    id,
            \\    instance_id,
            \\    token_id,
            \\    node_id,
            \\    node_name,
            \\    status,
            \\    assignee_type,
            \\    assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM tasks
            \\WHERE id = $1::uuid
        ,
            &.{task_id_hex},
        ) catch return TaskError.InvalidInput;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return TaskError.NotFound;
        return rowToTask(allocator, rows.rows[0]) catch TaskError.InvalidInput;
    }

    // -----------------------------------------------------------------------
    // completeInTx  (EE-04)
    // -----------------------------------------------------------------------

    /// Update a task row to COMPLETED status using an already-open DB connection.
    ///
    /// The caller owns the transaction; completeInTx does NOT issue BEGIN,
    /// COMMIT, or ROLLBACK.
    ///
    /// Returns TaskError.AlreadyTerminated when the WHERE id=$1 AND status='PENDING'
    /// predicate matches 0 rows — indicating the task was concurrently completed
    /// or cancelled.
    ///
    /// Security: both parameter values are bound as $N positional parameters —
    /// no SQL string interpolation of user-supplied data.
    pub fn completeInTx(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        task_id: Uuid,
        output_variables_json: []const u8,
    ) TaskError!Task {
        _ = self;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const task_id_hex = uuidToHex(a, task_id) catch return TaskError.InvalidInput;

        // Security: $1=task_id, $2=output_variables_json — both bound as $N params.
        const rows = conn.query(
            allocator,
            \\UPDATE tasks
            \\SET
            \\    status           = 'COMPLETED',
            \\    output_variables = $2::jsonb,
            \\    completed_at     = NOW(),
            \\    updated_at       = NOW()
            \\WHERE id = $1::uuid
            \\  AND status = 'PENDING'
            \\RETURNING
            \\    id,
            \\    instance_id,
            \\    token_id,
            \\    node_id,
            \\    node_name,
            \\    status,
            \\    assignee_type,
            \\    assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ task_id_hex, output_variables_json },
        ) catch return TaskError.InvalidInput;
        defer {
            var r = rows;
            r.deinit();
        }

        // 0 RETURNING rows: WHERE status='PENDING' predicate matched no row.
        // Either non-existent (getById already confirmed existence) or
        // concurrently completed/cancelled. Return AlreadyTerminated (HTTP 409).
        if (rows.rows.len == 0) return TaskError.AlreadyTerminated;
        return rowToTask(allocator, rows.rows[0]) catch TaskError.InvalidInput;
    }

    // -----------------------------------------------------------------------
    // cancelInTx  (EE-08)
    // -----------------------------------------------------------------------

    /// Cancel all PENDING tasks for a given instance using an already-open DB connection.
    ///
    /// The caller owns the transaction; cancelInTx does NOT issue BEGIN, COMMIT, or ROLLBACK.
    ///
    /// Returns the count of rows updated (0 is valid — instance may have no open tasks).
    ///
    /// Security: instance_id is bound as $1::uuid — no SQL string interpolation.
    pub fn cancelInTx(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        instance_id: Uuid,
    ) TaskError!u64 {
        _ = self;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const inst_id_hex = uuidToHex(a, instance_id) catch return TaskError.InvalidInput;

        // Security: $1 = instance_id as hex UUID — no SQL string interpolation.
        const rows = conn.query(
            allocator,
            \\UPDATE tasks
            \\SET
            \\    status     = 'CANCELLED',
            \\    updated_at = NOW()
            \\WHERE instance_id = $1::uuid
            \\  AND status = 'PENDING'
            \\RETURNING id
        ,
            &.{inst_id_hex},
        ) catch return TaskError.InvalidInput;
        defer {
            var r = rows;
            r.deinit();
        }

        return @as(u64, rows.rows.len);
    }

    // -----------------------------------------------------------------------
    // list  (EE-03)
    // -----------------------------------------------------------------------

    /// Query tasks with optional filters; returns a caller-owned slice.
    ///
    /// Filters are applied only when non-null. limit is clamped to 1–200
    /// (0 → default 50). offset must be ≥ 0.
    ///
    /// Security: all filter values are bound as $N positional parameters.
    /// The SQL string contains only fixed schema identifiers and $N placeholders;
    /// no user-supplied value is ever concatenated into the SQL literal.
    pub fn list(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        instance_id: ?Uuid,
        status_filter: ?TaskStatus,
        assignee_ref_filter: ?[]const u8,
        limit: u32,
        offset: u32,
    ) TaskError![]Task {
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return TaskError.PoolExhausted,
            else => return TaskError.InvalidInput,
        };
        defer self.pool.release(conn);

        const clamped_limit: u32 = if (limit == 0) 50 else if (limit > 200) 200 else limit;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Accumulate $N params and WHERE condition fragments.
        // Only fixed SQL schema identifiers and $N placeholders appear in the
        // condition strings; actual user/filter values go into the params array.
        var params = std.ArrayList([]const u8).empty;
        var conditions = std.ArrayList([]const u8).empty;

        if (instance_id) |iid| {
            const hex = uuidToHex(a, iid) catch return TaskError.InvalidInput;
            params.append(a, hex) catch return TaskError.InvalidInput;
            const cond = std.fmt.allocPrint(
                a,
                "instance_id = ${d}::uuid",
                .{params.items.len},
            ) catch return TaskError.InvalidInput;
            conditions.append(a, cond) catch return TaskError.InvalidInput;
        }

        if (status_filter) |sf| {
            const s = taskStatusToString(sf);
            params.append(a, s) catch return TaskError.InvalidInput;
            const cond = std.fmt.allocPrint(
                a,
                "status = ${d}",
                .{params.items.len},
            ) catch return TaskError.InvalidInput;
            conditions.append(a, cond) catch return TaskError.InvalidInput;
        }

        if (assignee_ref_filter) |arf| {
            params.append(a, arf) catch return TaskError.InvalidInput;
            const cond = std.fmt.allocPrint(
                a,
                "assignee_ref = ${d}",
                .{params.items.len},
            ) catch return TaskError.InvalidInput;
            conditions.append(a, cond) catch return TaskError.InvalidInput;
        }

        // LIMIT and OFFSET are always the last two parameters.
        const limit_str = std.fmt.allocPrint(a, "{d}", .{clamped_limit}) catch
            return TaskError.InvalidInput;
        params.append(a, limit_str) catch return TaskError.InvalidInput;
        const limit_idx = params.items.len;

        const offset_str = std.fmt.allocPrint(a, "{d}", .{offset}) catch
            return TaskError.InvalidInput;
        params.append(a, offset_str) catch return TaskError.InvalidInput;
        const offset_idx = params.items.len;

        // Build the SQL string.
        // Security: only fixed schema identifiers and $N placeholders appear in
        // the SQL string. No user-supplied value is ever concatenated into SQL.
        var sql_buf = std.ArrayList(u8).empty;
        sql_buf.appendSlice(a,
            \\SELECT
            \\    id, instance_id, token_id, node_id, node_name, status,
            \\    assignee_type, assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM tasks
        ) catch return TaskError.InvalidInput;

        if (conditions.items.len > 0) {
            sql_buf.appendSlice(a, "\nWHERE ") catch return TaskError.InvalidInput;
            for (conditions.items, 0..) |cond, i| {
                if (i > 0) {
                    sql_buf.appendSlice(a, " AND ") catch return TaskError.InvalidInput;
                }
                sql_buf.appendSlice(a, cond) catch return TaskError.InvalidInput;
            }
        }

        const limit_offset_clause = std.fmt.allocPrint(
            a,
            "\nORDER BY created_at ASC\nLIMIT ${d} OFFSET ${d}",
            .{ limit_idx, offset_idx },
        ) catch return TaskError.InvalidInput;
        sql_buf.appendSlice(a, limit_offset_clause) catch return TaskError.InvalidInput;

        const rows = conn.query(
            allocator,
            sql_buf.items,
            params.items,
        ) catch return TaskError.InvalidInput;
        defer {
            var r = rows;
            r.deinit();
        }

        const tasks = allocator.alloc(Task, rows.rows.len) catch return TaskError.InvalidInput;
        for (rows.rows, 0..) |row, i| {
            tasks[i] = rowToTask(allocator, row) catch {
                for (tasks[0..i]) |t| freeTask(allocator, t);
                allocator.free(tasks);
                return TaskError.InvalidInput;
            };
        }
        return tasks;
    }

    // -----------------------------------------------------------------------
    // listCursor  (API-04 / API-06)
    // -----------------------------------------------------------------------

    /// Fetch a page of tasks using cursor-based (keyset) pagination.
    ///
    /// Results are ordered by (created_at DESC, id DESC).
    /// Returns exactly page_size rows or fewer (fewer means last page).
    /// Fetches page_size + 1 rows internally; returns at most page_size.
    ///
    /// Security: all filter values bound as $N positional parameters.
    ///
    /// Errors:
    ///   TaskError.PoolExhausted  → HTTP 503
    ///   TaskError.InvalidInput   → HTTP 500
    pub fn listCursor(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        params: ListCursorParams,
    ) TaskError![]Task {
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return TaskError.PoolExhausted,
            else => return TaskError.InvalidInput,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Accumulate $N params and WHERE condition fragments.
        var sql_params = std.ArrayList([]const u8).empty;
        var conditions = std.ArrayList([]const u8).empty;

        // instance_id filter
        if (params.instance_id) |iid| {
            const hex = uuidToHex(a, iid) catch return TaskError.InvalidInput;
            sql_params.append(a, hex) catch return TaskError.InvalidInput;
            const cond = std.fmt.allocPrint(
                a,
                "instance_id = ${d}::uuid",
                .{sql_params.items.len},
            ) catch return TaskError.InvalidInput;
            conditions.append(a, cond) catch return TaskError.InvalidInput;
        }

        // status filter
        if (params.status) |sf| {
            const s = taskStatusToString(sf);
            sql_params.append(a, s) catch return TaskError.InvalidInput;
            const cond = std.fmt.allocPrint(
                a,
                "status = ${d}",
                .{sql_params.items.len},
            ) catch return TaskError.InvalidInput;
            conditions.append(a, cond) catch return TaskError.InvalidInput;
        }

        // assignee_id filter
        if (params.assignee_id) |aid| {
            sql_params.append(a, aid) catch return TaskError.InvalidInput;
            const cond = std.fmt.allocPrint(
                a,
                "assignee_ref = ${d}",
                .{sql_params.items.len},
            ) catch return TaskError.InvalidInput;
            conditions.append(a, cond) catch return TaskError.InvalidInput;

            // For TASK_WORKER row-level restriction: also require assignee_type = 'USER'.
            // Security: 'USER' is a fixed SQL literal, not user-supplied.
            if (params.assignee_type_user_only) {
                const cond2 = std.mem.Allocator.dupe(a, u8, "assignee_type = 'USER'") catch
                    return TaskError.InvalidInput;
                conditions.append(a, cond2) catch return TaskError.InvalidInput;
            }
        }

        // Cursor seek condition
        if (params.cursor_created_at) |cat| {
            if (params.cursor_task_id) |ctid| {
                // Convert cursor_created_at (µs epoch) to a timestamptz literal.
                // Bind both as parameters; use the (created_at, id) < (...) keyset.
                // We convert µs epoch to a timestamptz via to_timestamp($N / 1000000.0).
                const cat_str = std.fmt.allocPrint(a, "{d}", .{cat}) catch
                    return TaskError.InvalidInput;
                sql_params.append(a, cat_str) catch return TaskError.InvalidInput;
                const cat_idx = sql_params.items.len;

                sql_params.append(a, ctid) catch return TaskError.InvalidInput;
                const ctid_idx = sql_params.items.len;

                const cond = std.fmt.allocPrint(
                    a,
                    "(created_at, id) < (to_timestamp(${d}::bigint / 1000000.0), ${d}::uuid)",
                    .{ cat_idx, ctid_idx },
                ) catch return TaskError.InvalidInput;
                conditions.append(a, cond) catch return TaskError.InvalidInput;
            }
        }

        // Build SQL string.
        var sql_buf = std.ArrayList(u8).empty;
        sql_buf.appendSlice(a,
            \\SELECT
            \\    id, instance_id, token_id, node_id, node_name, status,
            \\    assignee_type, assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM tasks
        ) catch return TaskError.InvalidInput;

        if (conditions.items.len > 0) {
            sql_buf.appendSlice(a, "\nWHERE ") catch return TaskError.InvalidInput;
            for (conditions.items, 0..) |cond, i| {
                if (i > 0) sql_buf.appendSlice(a, "\n  AND ") catch return TaskError.InvalidInput;
                sql_buf.appendSlice(a, cond) catch return TaskError.InvalidInput;
            }
        }

        // page_size + 1 to detect next page
        const fetch_size: u32 = @as(u32, params.page_size) + 1;
        const fetch_str = std.fmt.allocPrint(a, "{d}", .{fetch_size}) catch
            return TaskError.InvalidInput;
        sql_params.append(a, fetch_str) catch return TaskError.InvalidInput;
        const limit_idx = sql_params.items.len;

        const order_limit = std.fmt.allocPrint(
            a,
            "\nORDER BY created_at DESC, id DESC\nLIMIT ${d}",
            .{limit_idx},
        ) catch return TaskError.InvalidInput;
        sql_buf.appendSlice(a, order_limit) catch return TaskError.InvalidInput;

        const rows = conn.query(
            allocator,
            sql_buf.items,
            sql_params.items,
        ) catch return TaskError.InvalidInput;
        defer {
            var r = rows;
            r.deinit();
        }

        const tasks = allocator.alloc(Task, rows.rows.len) catch return TaskError.InvalidInput;
        for (rows.rows, 0..) |row, i| {
            tasks[i] = rowToTask(allocator, row) catch {
                for (tasks[0..i]) |t| freeTask(allocator, t);
                allocator.free(tasks);
                return TaskError.InvalidInput;
            };
        }
        return tasks;
    }

    // -----------------------------------------------------------------------
    // assign  (API-04)
    // -----------------------------------------------------------------------

    /// Assign an unassigned PENDING task to a user.
    ///
    /// Preconditions enforced atomically by the UPDATE WHERE clause:
    ///   - status = 'PENDING'
    ///   - assignee_ref IS NULL (unassigned)
    ///
    /// Returns AssignError.AssignmentConflict if 0 rows updated
    /// (task already assigned, not PENDING, or not found after pre-check).
    ///
    /// Security: user_id is bound as $2 — no SQL string interpolation.
    pub fn assign(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        task_id: Uuid,
        user_id: []const u8,
    ) AssignError!Task {
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return AssignError.PoolExhausted,
            else => return AssignError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const task_id_hex = uuidToHex(a, task_id) catch return AssignError.PersistenceFailed;

        // Security: $1=task_id, $2=user_id — both bound as $N positional parameters.
        const rows = conn.query(
            allocator,
            \\UPDATE tasks
            \\SET
            \\    assignee_type = 'USER',
            \\    assignee_ref  = $2,
            \\    updated_at    = NOW()
            \\WHERE id = $1::uuid
            \\  AND status = 'PENDING'
            \\  AND assignee_ref IS NULL
            \\RETURNING
            \\    id, instance_id, token_id, node_id, node_name, status,
            \\    assignee_type, assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ task_id_hex, user_id },
        ) catch return AssignError.PersistenceFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return AssignError.AssignmentConflict;
        return rowToTask(allocator, rows.rows[0]) catch AssignError.OutOfMemory;
    }

    // -----------------------------------------------------------------------
    // reassign  (API-04)
    // -----------------------------------------------------------------------

    /// Change the assignee of an already-assigned PENDING task.
    ///
    /// Preconditions enforced atomically:
    ///   - status = 'PENDING'
    ///   - assignee_ref IS NOT NULL (must already be assigned)
    ///
    /// Returns AssignError.AssignmentConflict if 0 rows updated.
    ///
    /// Security: both parameters bound as $N — no SQL string interpolation.
    pub fn reassign(
        self: *TaskStore,
        allocator: std.mem.Allocator,
        task_id: Uuid,
        new_user_id: []const u8,
    ) AssignError!Task {
        const conn = self.pool.acquire() catch |err| switch (err) {
            PoolError.ExhaustedPool => return AssignError.PoolExhausted,
            else => return AssignError.PersistenceFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const task_id_hex = uuidToHex(a, task_id) catch return AssignError.PersistenceFailed;

        // Security: $1=task_id, $2=new_user_id — both bound as $N positional parameters.
        const rows = conn.query(
            allocator,
            \\UPDATE tasks
            \\SET
            \\    assignee_type = 'USER',
            \\    assignee_ref  = $2,
            \\    updated_at    = NOW()
            \\WHERE id = $1::uuid
            \\  AND status = 'PENDING'
            \\  AND assignee_ref IS NOT NULL
            \\RETURNING
            \\    id, instance_id, token_id, node_id, node_name, status,
            \\    assignee_type, assignee_ref,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\    (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ task_id_hex, new_user_id },
        ) catch return AssignError.PersistenceFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return AssignError.AssignmentConflict;
        return rowToTask(allocator, rows.rows[0]) catch AssignError.OutOfMemory;
    }
};

// ---------------------------------------------------------------------------
// Row parsing helpers
// ---------------------------------------------------------------------------

/// Free all allocator-owned slices within a Task.
pub fn freeTask(allocator: std.mem.Allocator, task: Task) void {
    allocator.free(task.node_id);
    allocator.free(task.node_name);
    if (task.assignee_type) |at| allocator.free(at);
    if (task.assignee_ref) |ar| allocator.free(ar);
}

/// Parse one DB row into a Task struct.
///
/// Columns (0-indexed):
///   0  id (task_id)     UUID text
///   1  instance_id      UUID text
///   2  token_id         UUID text
///   3  node_id          TEXT
///   4  node_name        TEXT
///   5  status           TEXT
///   6  assignee_type    TEXT or NULL
///   7  assignee_ref     TEXT or NULL
///   8  created_at       bigint (UTC µs)
///   9  updated_at       bigint (UTC µs)
fn rowToTask(
    allocator: std.mem.Allocator,
    row: []?[]u8,
) error{OutOfMemory}!Task {
    const task_id = parseUuid(colGet(row, 0)) catch std.mem.zeroes(Uuid);
    const instance_id = parseUuid(colGet(row, 1)) catch std.mem.zeroes(Uuid);
    const token_id = parseUuid(colGet(row, 2)) catch std.mem.zeroes(Uuid);

    const node_id = try allocator.dupe(u8, colGet(row, 3));
    const node_name = try allocator.dupe(u8, colGet(row, 4));

    const status_str = colGet(row, 5);
    const status: TaskStatus = parseTaskStatus(status_str) catch .PENDING;

    const at_col: ?[]u8 = if (row.len > 6) row[6] else null;
    const assignee_type: ?[]const u8 = if (at_col) |at|
        try allocator.dupe(u8, at)
    else
        null;

    const ar_col: ?[]u8 = if (row.len > 7) row[7] else null;
    const assignee_ref: ?[]const u8 = if (ar_col) |ar|
        try allocator.dupe(u8, ar)
    else
        null;

    const created_at = std.fmt.parseInt(i64, colGet(row, 8), 10) catch 0;
    const updated_at = std.fmt.parseInt(i64, colGet(row, 9), 10) catch 0;

    return Task{
        .task_id = task_id,
        .instance_id = instance_id,
        .token_id = token_id,
        .node_id = node_id,
        .node_name = node_name,
        .status = status,
        .assignee_type = assignee_type,
        .assignee_ref = assignee_ref,
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

pub fn parseTaskStatus(s: []const u8) error{InvalidStatus}!TaskStatus {
    if (std.mem.eql(u8, s, "PENDING")) return .PENDING;
    if (std.mem.eql(u8, s, "COMPLETED")) return .COMPLETED;
    if (std.mem.eql(u8, s, "CANCELLED")) return .CANCELLED;
    return error.InvalidStatus;
}

pub fn taskStatusToString(status: TaskStatus) []const u8 {
    return switch (status) {
        .PENDING => "PENDING",
        .COMPLETED => "COMPLETED",
        .CANCELLED => "CANCELLED",
    };
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
pub fn parseUuid(hex: []const u8) error{InvalidUuid}!Uuid {
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
