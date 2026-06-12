//! HTTP route handlers for task operations:
//!   EE-03 / API-04 — GET /api/v1/tasks (cursor-paginated list)
//!   API-04         — GET /api/v1/tasks/:id
//!   EE-04 / API-04 — POST /api/v1/tasks/:id/complete
//!   API-04         — POST /api/v1/tasks/:id/assign
//!   API-04         — POST /api/v1/tasks/:id/reassign
//!
//! Wire in main.zig:
//!   pub const task_routes = @import("api/routes/tasks.zig");
const std = @import("std");
const task_mod = @import("../../tasks/store.zig");
const identity_service = @import("../../identity/service.zig");
const instance_mod = @import("../../engine/instance.zig");
const webhook_dispatcher = @import("../../webhook/dispatcher.zig");
const pagination = @import("../pagination.zig");
const authorization = @import("../authorization.zig");

const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Result returned by a handler: an HTTP status code and a JSON body string.
/// The body slice is allocated with the caller-supplied allocator.
pub const HandlerResult = struct {
    status_code: u16,
    /// JSON-encoded response body; owned by the caller allocator.
    body: []const u8,
};

/// Authenticated caller context, extracted from the bearer token.
pub const Actor = struct {
    /// Caller's user identifier (from token subject).
    user_id: []const u8,
    /// Optional explicit role set from API-08 principal extraction.
    /// When null, handlers derive a conservative fallback role set from flags.
    roles: ?[]const authorization.Role = null,
    /// True if caller holds PROCESS_OPERATOR, PROCESS_DESIGNER, or PLATFORM_ADMIN.
    is_operator_or_above: bool,
    /// True if caller holds PLATFORM_ADMIN.
    is_platform_admin: bool,
    /// Request tenant context from auth middleware claim resolution.
    tenant_id: [36]u8 = DEFAULT_TENANT_ID.*,
};

/// Query parameters for GET /api/v1/tasks (parsed by the router before calling handleList).
pub const ListTasksParams = struct {
    /// Optional: filter to tasks assigned to this user_id.
    assignee_id: ?[]const u8,
    /// Optional: filter by task status.
    status: ?task_mod.TaskStatus,
    /// Optional: filter to tasks belonging to this process instance UUID.
    instance_id: ?task_mod.Uuid,
    /// Cursor for continuation pagination (opaque base64url string).
    cursor: ?[]const u8,
    /// Page size; default 50, max 200.
    page_size: u16,
};

// ---------------------------------------------------------------------------
// handleList  (API-04 / API-06)
// ---------------------------------------------------------------------------

/// GET /api/v1/tasks
///
/// Returns a paginated, optionally-filtered list of tasks.
/// Results sorted by created_at DESC, task_id DESC (stable cursor pagination).
///
/// Role-based row filtering:
///   TASK_WORKER: only tasks where assignee_ref = actor.user_id AND assignee_type = 'USER'.
///   PROCESS_OPERATOR or above: all tasks (no extra row filter).
///
/// Query parameters (parsed before this handler is called):
///   assignee_id — optional user_id filter
///   status      — optional status filter
///   instance_id — optional instance UUID filter
///   cursor      — optional continuation cursor
///   page_size   — validated integer, default 50, max 200
///
/// Authorisation: any authenticated role.
///
/// Success:              HTTP 200 + JSON TaskListResponse.
/// Invalid page_size:    HTTP 422 + Problem Details.
/// Malformed cursor:     HTTP 422 + Problem Details.
/// Expired cursor:       HTTP 410 + Problem Details.
/// Pool exhausted:       HTTP 503 + Problem Details.
/// Server error:         HTTP 500 + Problem Details.
pub fn handleList(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    params: ListTasksParams,
) HandlerResult {
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .TasksList,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "caller is not authorized to list tasks");
    }

    // ── Step 1: Validate page_size ─────────────────────────────────────────
    const effective_page_size = pagination.validatePageSize(params.page_size) catch |err| switch (err) {
        error.PageSizeTooLarge => return errorResult(
            allocator,
            422,
            "INVALID_PAGE_SIZE",
            "page_size must be between 1 and 200",
        ),
    };

    // ── Step 2: Decode cursor (if present) ─────────────────────────────────
    // Cursor format: base64url_no_pad( "T:" || decimal(created_at_us) || ":" || task_id_hex )
    // The "T:" prefix discriminates task cursors from other endpoint cursors.
    // expiry_ts_offset = 2 (byte index of timestamp after "T:" prefix).
    var cursor_created_at: ?i64 = null;
    var cursor_task_id_opt: ?[]u8 = null;
    if (params.cursor) |cursor_str| {
        const cursor = pagination.decodeCursor(allocator, cursor_str, "T:", 2, pagination.CURSOR_EXPIRY_US) catch |err| switch (err) {
            error.InvalidBase64 => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid base64url"),
            error.WrongEndpoint => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid for this endpoint"),
            error.Expired => return errorResult(allocator, 410, "CURSOR_EXPIRED", "Cursor has expired; please restart pagination"),
            error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        };
        defer cursor.deinit();

        // Extract created_at_us and task_id from inner (format: "T:TS:ID")
        const after_prefix = cursor.inner[2..]; // skip "T:"
        const colon = std.mem.indexOfScalar(u8, after_prefix, ':') orelse
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor format is invalid");
        const ts = std.fmt.parseInt(i64, after_prefix[0..colon], 10) catch
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor timestamp is not a valid integer");

        cursor_created_at = ts;
        cursor_task_id_opt = allocator.dupe(u8, after_prefix[colon + 1 ..]) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory");
    }
    defer if (cursor_task_id_opt) |cid| allocator.free(cid);

    // ── Step 3: Apply role-based row filter ─────────────────────────────────
    var effective_assignee_id: ?[]const u8 = params.assignee_id;
    var assignee_type_user_only: bool = false;
    var include_group_membership_for_user: bool = false;

    if (decision.kind == .AllowWithRowFilter) {
        effective_assignee_id = actor.user_id;
        assignee_type_user_only = false;
        include_group_membership_for_user = true;
    }

    // ── Step 4: Call TaskStore.listCursor() ─────────────────────────────────
    const store_params = task_mod.ListCursorParams{
        .assignee_id = effective_assignee_id,
        .assignee_type_user_only = assignee_type_user_only,
        .include_group_membership_for_user = include_group_membership_for_user,
        .status = params.status,
        .instance_id = params.instance_id,
        .cursor_created_at = cursor_created_at,
        .cursor_task_id = cursor_task_id_opt,
        .page_size = effective_page_size,
    };

    const rows = store.listCursor(allocator, store_params) catch |err| switch (err) {
        task_mod.TaskError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        else => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Task query failed",
        ),
    };
    defer {
        for (rows) |t| task_mod.freeTask(allocator, t);
        allocator.free(rows);
    }

    // ── Step 5: Determine next cursor ──────────────────────────────────────
    const has_next = rows.len > @as(usize, effective_page_size);
    const page_rows = if (has_next) rows[0..effective_page_size] else rows;

    var serial_arena = std.heap.ArenaAllocator.init(allocator);
    defer serial_arena.deinit();
    const sa = serial_arena.allocator();

    const next_cursor_json: []const u8 = if (has_next and page_rows.len > 0) blk: {
        const last = page_rows[page_rows.len - 1];
        const last_id_hex = uuidToHex(sa, last.task_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        // Cursor raw: "T:" || decimal(created_at_us) || ":" || task_id_hex
        const raw_cursor = pagination.buildRawCursor(sa, "T:", last.created_at, last_id_hex) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const encoded = pagination.encodeCursor(sa, raw_cursor) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const quoted = std.fmt.allocPrint(sa, "\"{s}\"", .{encoded}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        break :blk quoted;
    } else "null";

    // ── Step 6: Serialize items ─────────────────────────────────────────────
    var items_buf = std.ArrayList(u8).empty;
    items_buf.append(sa, '[') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    for (page_rows, 0..) |task, i| {
        if (i > 0) items_buf.append(sa, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const task_id_hex = uuidToHex(sa, task.task_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const inst_id_hex = uuidToHex(sa, task.instance_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const status_str = task_mod.taskStatusToString(task.status);

        const at_json: []const u8 = if (task.assignee_type) |at|
            std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = at }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
        else
            "null";

        const ar_json: []const u8 = if (task.assignee_ref) |ar|
            std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = ar }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
        else
            "null";

        const node_id_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = task.node_id }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const node_name_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = task.node_name }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const entry = std.fmt.allocPrint(
            sa,
            "{{\"id\":\"{s}\",\"task_id\":\"{s}\",\"instance_id\":\"{s}\"," ++
                "\"node_id\":{s},\"node_name\":{s}," ++
                "\"status\":\"{s}\"," ++
                "\"assignee_type\":{s},\"assignee_ref\":{s}," ++
                "\"created_at\":{d}}}",
            .{
                task_id_hex,
                task_id_hex,
                inst_id_hex,
                node_id_json,
                node_name_json,
                status_str,
                at_json,
                ar_json,
                task.created_at,
            },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        items_buf.appendSlice(sa, entry) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    items_buf.append(sa, ']') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    // ── Step 7: Build final JSON body ───────────────────────────────────────
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"items\":{s},\"next_cursor\":{s},\"count\":{d}}}",
        .{ items_buf.items, next_cursor_json, page_rows.len },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return HandlerResult{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// handleGetById  (API-04)
// ---------------------------------------------------------------------------

/// GET /api/v1/tasks/:id
///
/// Returns the full task record.
///
/// Authorisation: any authenticated role.
///
/// Success:          HTTP 200 + JSON TaskDetailResponse.
/// Not found:        HTTP 404 + Problem Details.
/// Invalid UUID:     HTTP 422 + Problem Details.
/// Pool exhausted:   HTTP 503 + Problem Details.
/// Server error:     HTTP 500 + Problem Details.
pub fn handleGetById(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    task_id_str: []const u8,
) HandlerResult {
    const task_id = task_mod.parseUuid(task_id_str) catch {
        return errorResult(allocator, 422, "INVALID_TASK_ID", "task_id is not a valid UUID");
    };

    const task = store.getById(allocator, task_id) catch |err| switch (err) {
        task_mod.TaskError.NotFound => return errorResult(
            allocator,
            404,
            "TASK_NOT_FOUND",
            "task not found",
        ),
        task_mod.TaskError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        else => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Task query failed",
        ),
    };
    defer task_mod.freeTask(allocator, task);

    return serializeTaskDetail(allocator, task);
}

// ---------------------------------------------------------------------------
// handleComplete  (EE-04 / API-04)
// ---------------------------------------------------------------------------

/// POST /api/v1/tasks/:task_id/complete
///
/// Validates input, performs role/ownership check, calls InstanceStore.completeTask,
/// and returns HTTP 200 with `{"status":"ok","task_id":"<hex-uuid>"}`.
///
/// Role check (API-04):
///   TASK_WORKER may only complete tasks assigned to them.
///   PROCESS_OPERATOR or above may complete any task.
///
/// Security: output_variables_json is not injected into SQL strings; it is
/// validated as a JSON object and passed to completeTask which binds it as a
/// $N parameter only. The task_id_str path parameter is validated as a UUID
/// before use.
pub fn handleComplete(
    store: *task_mod.TaskStore,
    instance_store: *instance_mod.InstanceStore,
    identity: *identity_service.Service,
    allocator: std.mem.Allocator,
    actor: Actor,
    task_id_str: []const u8,
    body: []const u8,
) HandlerResult {
    // identity is no longer used in the TASK_WORKER ownership check (ISS-102);
    // the parameter is kept for API compatibility.
    _ = identity;
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .TasksComplete,
    );
    if (decision.kind == .Deny403) {
        return errorResult(
            allocator,
            403,
            "FORBIDDEN",
            "Caller is not authorized to complete tasks",
        );
    }

    // ── Step 1: Parse task_id ───────────────────────────────────────────────
    const task_id = task_mod.parseUuid(task_id_str) catch {
        return errorResult(allocator, 422, "INVALID_TASK_ID", "task_id is not a valid UUID");
    };

    // ── Step 2: Fetch task (for ownership check) ────────────────────────────
    const task = store.getById(allocator, task_id) catch |err| switch (err) {
        task_mod.TaskError.NotFound => return errorResult(
            allocator,
            404,
            "TASK_NOT_FOUND",
            "task not found",
        ),
        task_mod.TaskError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        else => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Task query failed",
        ),
    };
    defer task_mod.freeTask(allocator, task);

    // ── Step 3: Role/ownership check (ISS-102 updated guard) ────────────────
    // The check order per design §4.2:
    //   1. If task.claimed_by IS NOT NULL: allow iff claimed_by == actor.user_id
    //   2. Else if assignee_type == "USER": allow iff assignee_ref == actor.user_id
    //   3. Else (GROUP/ROLE pool, not yet claimed): deny — worker must claim first.
    // PROCESS_OPERATOR and above bypass this block entirely (no change).
    if (authorization.isTaskWorkerOnly(roles)) {
        const complete_allowed = if (task.claimed_by) |cb| blk: {
            // Branch 1: task has been claimed — only the claimer may complete.
            const cb_hex = uuidToHex(allocator, cb) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");
            defer allocator.free(cb_hex);
            break :blk std.mem.eql(u8, cb_hex, actor.user_id);
        } else if (task.assignee_type) |at| blk: {
            // Branch 2: unclaimed — allow only a directly USER-assigned actor.
            if (std.mem.eql(u8, at, "USER")) {
                break :blk task.assignee_ref != null and
                    std.mem.eql(u8, task.assignee_ref.?, actor.user_id);
            }
            // Branch 3: GROUP/ROLE pool task, not yet claimed — deny.
            break :blk false;
        } else false;

        if (!complete_allowed) {
            return errorResult(
                allocator,
                403,
                "UNAUTHORIZED_COMPLETE",
                "Caller is not authorized to complete this task; claim the task first",
            );
        }
    }

    // ── Step 4: Parse and validate request body ─────────────────────────────
    const body_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch {
        return errorResult(allocator, 422, "INVALID_INPUT", "request body is not valid JSON");
    };
    defer body_parsed.deinit();

    if (body_parsed.value != .object) {
        return errorResult(allocator, 422, "INVALID_INPUT", "request body must be a JSON object");
    }

    const out_vars_val = body_parsed.value.object.get("output_variables") orelse {
        return errorResult(allocator, 422, "INVALID_INPUT", "output_variables is required");
    };

    if (out_vars_val != .object) {
        return errorResult(allocator, 422, "INVALID_INPUT", "output_variables must be a JSON object");
    }

    const out_vars_value = std.json.Value{ .object = out_vars_val.object };
    const output_variables_json = std.json.Stringify.valueAlloc(allocator, out_vars_value, .{}) catch {
        return internalError(allocator);
    };
    defer allocator.free(output_variables_json);

    // ── Step 5: Delegate to InstanceStore.completeTask (EE-04) ─────────────
    const new_state = instance_store.completeTask(
        allocator,
        store,
        task_id,
        output_variables_json,
    ) catch |err| switch (err) {
        instance_mod.CompleteTaskError.TaskNotFound => return errorResult(allocator, 404, "TASK_NOT_FOUND", "task not found"),
        instance_mod.CompleteTaskError.TaskAlreadyTerminated => return errorResult(allocator, 409, "TASK_ALREADY_TERMINATED", "task is not in PENDING status"),
        // ISS-208: instance not ACTIVE (CANCELLED or COMPLETED) — race-safe guard.
        instance_mod.CompleteTaskError.InstanceNotActive => return errorResult(allocator, 409, "INSTANCE_NOT_ACTIVE", "Task completion is not allowed: the parent instance is not in ACTIVE status."),
        instance_mod.CompleteTaskError.InvalidInput => return errorResult(allocator, 422, "INVALID_INPUT", "output_variables is not a valid JSON object"),
        instance_mod.CompleteTaskError.TransitionFailed => return errorResult(allocator, 500, "TRANSITION_FAILED", "state transition failed"),
        instance_mod.CompleteTaskError.PersistenceFailed => return errorResult(allocator, 500, "PERSISTENCE_FAILED", "database operation failed"),
        instance_mod.CompleteTaskError.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "DB connection pool exhausted"),
        instance_mod.CompleteTaskError.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "out of memory"),
        instance_mod.CompleteTaskError.SchemaViolationError => return errorResult(allocator, 409, "INSTANCE_IN_ERROR", "Instance transitioned to ERROR due to schema violation. Use the dead letter API to retry or discard."),
        instance_mod.CompleteTaskError.InstanceInError => return errorResult(allocator, 409, "INSTANCE_IN_ERROR", "Instance is in ERROR status. Use the dead letter API to retry or discard."),
        instance_mod.CompleteTaskError.ConcurrentModification => return errorResult(allocator, 409, "CONCURRENT_MODIFICATION", "Another request is currently modifying this instance; retry after a short delay."),
    };
    _ = new_state;

    const task_id_hex = uuidToHex(allocator, task_id) catch return internalError(allocator);
    defer allocator.free(task_id_hex);

    dispatchTaskCompletedWebhooks(
        allocator,
        store.pool,
        task.instance_id,
        output_variables_json,
        task_id_hex,
    );

    const resp_body = std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"ok\",\"task_id\":\"{s}\"}}",
        .{task_id_hex},
    ) catch return internalError(allocator);

    return HandlerResult{ .status_code = 200, .body = resp_body };
}

// ---------------------------------------------------------------------------
// handleClaim  (ISS-102)
// ---------------------------------------------------------------------------

/// POST /api/v1/tasks/:id/claim
///
/// Atomically claims a PENDING, unclaimed task for the authenticated actor.
/// Uses a conditional UPDATE on claimed_by so concurrent claims are serialised
/// by PostgreSQL — exactly one claim wins; all others receive 409.
///
/// Authorisation: any authenticated role (TASK_WORKER or above).
///
/// Success:              HTTP 200 + JSON TaskDetailResponse (claimed_by populated).
/// Task not found:       HTTP 404 + Problem Details.
/// Task already claimed: HTTP 409 + Problem Details (code: TASK_ALREADY_CLAIMED).
/// Task not PENDING:     HTTP 409 + Problem Details (code: TASK_NOT_PENDING).
/// Invalid UUID:         HTTP 422 + Problem Details.
/// Pool exhausted:       HTTP 503 + Problem Details.
/// Server error:         HTTP 500 + Problem Details.
pub fn handleClaim(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    task_id_str: []const u8,
) HandlerResult {
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .TasksComplete,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "caller is not authorized to claim tasks");
    }

    // ── Step 1: Parse task_id ───────────────────────────────────────────────
    const task_id = task_mod.parseUuid(task_id_str) catch {
        return errorResult(allocator, 422, "INVALID_TASK_ID", "task_id is not a valid UUID");
    };

    // ── Step 2: Attempt atomic claim ────────────────────────────────────────
    const task = store.claimTask(allocator, task_id, actor.user_id) catch |err| switch (err) {
        task_mod.ClaimError.NotFound => return errorResult(
            allocator,
            404,
            "TASK_NOT_FOUND",
            "task not found",
        ),
        task_mod.ClaimError.AlreadyClaimed => return errorResult(
            allocator,
            409,
            "TASK_ALREADY_CLAIMED",
            "task has already been claimed by another worker",
        ),
        task_mod.ClaimError.NotPending => return errorResult(
            allocator,
            409,
            "TASK_NOT_PENDING",
            "task is not in PENDING status",
        ),
        task_mod.ClaimError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        task_mod.ClaimError.InvalidInput => return errorResult(
            allocator,
            422,
            "INVALID_INPUT",
            "claim failed due to invalid input",
        ),
    };
    defer task_mod.freeTask(allocator, task);

    return serializeTaskDetail(allocator, task);
}

// ---------------------------------------------------------------------------
// handleAssign  (API-04)
// ---------------------------------------------------------------------------

/// POST /api/v1/tasks/:id/assign
///
/// Assigns an unassigned PENDING task to a specific user.
///
/// Authorisation: PROCESS_OPERATOR or above.
///
/// Success:                        HTTP 200 + JSON TaskDetailResponse.
/// Task not found:                 HTTP 404.
/// Task already assigned:          HTTP 409.
/// Task already completed/cancelled: HTTP 409.
/// Caller not PROCESS_OPERATOR:    HTTP 403.
/// user_id missing/empty:          HTTP 422.
/// Pool exhausted:                 HTTP 503.
/// Server error:                   HTTP 500.
pub fn handleAssign(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    task_id_str: []const u8,
    body: []const u8,
) HandlerResult {
    // ── Step 1: Role check ──────────────────────────────────────────────────
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .TasksAssign,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "assign requires PROCESS_OPERATOR or above");
    }

    // ── Step 2: Parse task_id ───────────────────────────────────────────────
    const task_id = task_mod.parseUuid(task_id_str) catch {
        return errorResult(allocator, 422, "INVALID_TASK_ID", "task_id is not a valid UUID");
    };

    // ── Step 3: Parse body — extract user_id ───────────────────────────────
    const user_id = extractUserIdFromBody(allocator, body) orelse {
        return errorResult(allocator, 422, "INVALID_INPUT", "user_id is required and must be non-empty");
    };
    defer allocator.free(user_id);

    // ── Step 4: Pre-check existence to distinguish 404 from 409 ────────────
    const existing = store.getById(allocator, task_id) catch |err| switch (err) {
        task_mod.TaskError.NotFound => return errorResult(
            allocator,
            404,
            "TASK_NOT_FOUND",
            "task not found",
        ),
        task_mod.TaskError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        else => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Task query failed",
        ),
    };
    task_mod.freeTask(allocator, existing);

    // ── Step 5: Call TaskStore.assign() ────────────────────────────────────
    const updated = store.assign(allocator, task_id, user_id) catch |err| switch (err) {
        task_mod.AssignError.NotFound => return errorResult(
            allocator,
            404,
            "TASK_NOT_FOUND",
            "task not found",
        ),
        task_mod.AssignError.AssignmentConflict => return errorResult(
            allocator,
            409,
            "TASK_ALREADY_ASSIGNED",
            "task is already assigned or not in PENDING status",
        ),
        task_mod.AssignError.AlreadyTerminated => return errorResult(
            allocator,
            409,
            "TASK_ALREADY_TERMINATED",
            "task is not in PENDING status",
        ),
        task_mod.AssignError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        task_mod.AssignError.PersistenceFailed, task_mod.AssignError.OutOfMemory => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Task assignment failed",
        ),
    };
    defer task_mod.freeTask(allocator, updated);

    return serializeTaskDetail(allocator, updated);
}

// ---------------------------------------------------------------------------
// handleReassign  (API-04)
// ---------------------------------------------------------------------------

/// POST /api/v1/tasks/:id/reassign
///
/// Changes the assignee of an already-assigned PENDING task.
///
/// Authorisation: PROCESS_OPERATOR or above.
///
/// Success:                          HTTP 200 + JSON TaskDetailResponse.
/// Task not found:                   HTTP 404.
/// Task not currently assigned:      HTTP 409.
/// Task already completed/cancelled: HTTP 409.
/// Caller not PROCESS_OPERATOR:      HTTP 403.
/// user_id missing/empty:            HTTP 422.
/// Pool exhausted:                   HTTP 503.
/// Server error:                     HTTP 500.
pub fn handleReassign(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    task_id_str: []const u8,
    body: []const u8,
) HandlerResult {
    // ── Step 1: Role check ──────────────────────────────────────────────────
    var derived_roles: [3]authorization.Role = undefined;
    const roles = resolveActorRoles(actor, &derived_roles);
    const decision = authorization.evaluateAccess(
        .{ .user_id = actor.user_id, .roles = roles },
        .TasksReassign,
    );
    if (decision.kind == .Deny403) {
        return errorResult(allocator, 403, "FORBIDDEN", "reassign requires PROCESS_OPERATOR or above");
    }

    // ── Step 2: Parse task_id ───────────────────────────────────────────────
    const task_id = task_mod.parseUuid(task_id_str) catch {
        return errorResult(allocator, 422, "INVALID_TASK_ID", "task_id is not a valid UUID");
    };

    // ── Step 3: Parse body — extract user_id ───────────────────────────────
    const new_user_id = extractUserIdFromBody(allocator, body) orelse {
        return errorResult(allocator, 422, "INVALID_INPUT", "user_id is required and must be non-empty");
    };
    defer allocator.free(new_user_id);

    // ── Step 4: Pre-check existence to distinguish 404 from 409 ────────────
    const existing = store.getById(allocator, task_id) catch |err| switch (err) {
        task_mod.TaskError.NotFound => return errorResult(
            allocator,
            404,
            "TASK_NOT_FOUND",
            "task not found",
        ),
        task_mod.TaskError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        else => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Task query failed",
        ),
    };
    task_mod.freeTask(allocator, existing);

    // ── Step 5: Call TaskStore.reassign() ───────────────────────────────────
    const updated = store.reassign(allocator, task_id, new_user_id) catch |err| switch (err) {
        task_mod.AssignError.NotFound => return errorResult(
            allocator,
            404,
            "TASK_NOT_FOUND",
            "task not found",
        ),
        task_mod.AssignError.AssignmentConflict => return errorResult(
            allocator,
            409,
            "TASK_NOT_ASSIGNED",
            "task is not currently assigned or not in PENDING status",
        ),
        task_mod.AssignError.AlreadyTerminated => return errorResult(
            allocator,
            409,
            "TASK_ALREADY_TERMINATED",
            "task is not in PENDING status",
        ),
        task_mod.AssignError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "DB connection pool exhausted",
        ),
        task_mod.AssignError.PersistenceFailed, task_mod.AssignError.OutOfMemory => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Task reassignment failed",
        ),
    };
    defer task_mod.freeTask(allocator, updated);

    return serializeTaskDetail(allocator, updated);
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Parse a JSON body and extract a non-empty "user_id" string.
/// Returns a caller-owned dupe, or null if missing/empty/non-string.
fn extractUserIdFromBody(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const val = parsed.value.object.get("user_id") orelse return null;
    const s: []const u8 = switch (val) {
        .string => |sv| sv,
        else => return null,
    };
    if (s.len == 0) return null;
    return allocator.dupe(u8, s) catch null;
}

fn resolveActorRoles(actor: Actor, derived: *[3]authorization.Role) []const authorization.Role {
    if (actor.roles) |roles| return roles;

    if (actor.is_platform_admin) {
        derived[0] = .PLATFORM_ADMIN;
        return derived[0..1];
    }
    if (actor.is_operator_or_above) {
        derived[0] = .PROCESS_OPERATOR;
        return derived[0..1];
    }
    derived[0] = .TASK_WORKER;
    return derived[0..1];
}

/// Serialize a Task into a TaskDetailResponse JSON body (HTTP 200).
/// Caller allocates; Task must not be freed before this function returns.
fn serializeTaskDetail(allocator: std.mem.Allocator, task: task_mod.Task) HandlerResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const task_id_hex = uuidToHex(a, task.task_id) catch return internalError(allocator);
    const inst_id_hex = uuidToHex(a, task.instance_id) catch return internalError(allocator);
    const status_str = task_mod.taskStatusToString(task.status);

    const at_json: []const u8 = if (task.assignee_type) |at|
        std.json.Stringify.valueAlloc(a, std.json.Value{ .string = at }, .{}) catch
            return internalError(allocator)
    else
        "null";

    const ar_json: []const u8 = if (task.assignee_ref) |ar|
        std.json.Stringify.valueAlloc(a, std.json.Value{ .string = ar }, .{}) catch
            return internalError(allocator)
    else
        "null";

    const node_id_json = std.json.Stringify.valueAlloc(a, std.json.Value{ .string = task.node_id }, .{}) catch
        return internalError(allocator);
    const node_name_json = std.json.Stringify.valueAlloc(a, std.json.Value{ .string = task.node_name }, .{}) catch
        return internalError(allocator);

    // form_schema is already a JSON string (stored as JSONB, returned as text).
    // Pass it raw into the response body — no extra quoting needed.
    const form_schema_json: []const u8 = task.form_schema orelse "null";

    const ck_json: []const u8 = if (task.correlation_key) |ck|
        std.json.Stringify.valueAlloc(a, std.json.Value{ .string = ck }, .{}) catch
            return internalError(allocator)
    else
        "null";

    // claimed_by: serialize as hex UUID string or null.
    const claimed_by_json: []const u8 = if (task.claimed_by) |cb|
        std.fmt.allocPrint(a, "\"{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\"", .{
            cb[0],  cb[1],  cb[2],  cb[3],
            cb[4],  cb[5],  cb[6],  cb[7],
            cb[8],  cb[9],  cb[10], cb[11],
            cb[12], cb[13], cb[14], cb[15],
        }) catch return internalError(allocator)
    else
        "null";

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"task_id\":\"{s}\",\"instance_id\":\"{s}\"," ++
            "\"node_id\":{s},\"node_name\":{s}," ++
            "\"status\":\"{s}\"," ++
            "\"assignee_type\":{s},\"assignee_ref\":{s}," ++
            "\"claimed_by\":{s}," ++
            "\"form_schema\":{s},\"correlation_key\":{s}," ++
            "\"created_at\":{d},\"updated_at\":{d}}}",
        .{
            task_id_hex,
            task_id_hex,
            inst_id_hex,
            node_id_json,
            node_name_json,
            status_str,
            at_json,
            ar_json,
            claimed_by_json,
            form_schema_json,
            ck_json,
            task.created_at,
            task.updated_at,
        },
    ) catch return internalError(allocator);

    return HandlerResult{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// handleInbox  (TK-UI / user inbox)
// ---------------------------------------------------------------------------

/// GET /api/v1/tasks/inbox
///
/// Returns tasks assigned to the calling user (inbox).
/// Wraps handleList with automatic filtering by actor.user_id and actor's groups.
///
/// Authorisation: any authenticated role.
///
/// Success:              HTTP 200 + JSON TaskListResponse.
/// Invalid page_size:    HTTP 422 + Problem Details.
/// Malformed cursor:     HTTP 422 + Problem Details.
/// Pool exhausted:       HTTP 503 + Problem Details.
/// Server error:         HTTP 500 + Problem Details.
pub fn handleInbox(
    store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    actor: Actor,
    cursor: ?[]const u8,
    page_size: u16,
) HandlerResult {
    // Operators and above see all tasks (no assignee filter).
    // Task workers see only tasks assigned to themselves or their groups.
    const effective_assignee_id: ?[]const u8 = if (actor.is_operator_or_above)
        null
    else
        actor.user_id;

    const params = ListTasksParams{
        .assignee_id = effective_assignee_id,
        .status = null,
        .instance_id = null,
        .cursor = cursor,
        .page_size = page_size,
    };
    return handleList(store, allocator, actor, params);
}

fn errorResult(
    allocator: std.mem.Allocator,
    status_code: u16,
    code: []const u8,
    message: []const u8,
) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"{s}\",\"message\":\"{s}\"}}",
        .{ code, message },
    ) catch return HandlerResult{
        .status_code = 500,
        .body = "{\"error\":\"INTERNAL_ERROR\",\"message\":\"allocation failed\"}",
    };
    return HandlerResult{ .status_code = status_code, .body = body };
}

fn internalError(allocator: std.mem.Allocator) HandlerResult {
    return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error");
}

fn dispatchTaskCompletedWebhooks(
    allocator: std.mem.Allocator,
    pool: anytype,
    instance_id: task_mod.Uuid,
    payload_json: []const u8,
    trace_id: []const u8,
) void {
    const timestamp = formatTimestamp(allocator, currentMicrosecondTimestamp()) catch return;
    defer allocator.free(timestamp);

    const instance_id_hex = uuidToHex(allocator, instance_id) catch return;
    defer allocator.free(instance_id_hex);

    const inserted = webhook_dispatcher.enqueueDeliveryAttempts(allocator, pool, .{
        .event_type = .task_completed,
        .instance_id = instance_id_hex,
        .timestamp = timestamp,
        .payload_json = payload_json,
        .trace_id = trace_id,
    }) catch return;

    _ = inserted;
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

fn formatTimestamp(allocator: std.mem.Allocator, us: i64) error{OutOfMemory}![]u8 {
    const abs_us: u64 = if (us < 0) 0 else @as(u64, @intCast(us));
    const total_secs: u64 = abs_us / 1_000_000;
    const sub_us: u64 = abs_us % 1_000_000;

    const days: u64 = total_secs / 86400;
    const time_rem: u64 = total_secs % 86400;
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

/// Render a UUID as lowercase hex with hyphens: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
fn uuidToHex(allocator: std.mem.Allocator, uuid: task_mod.Uuid) error{OutOfMemory}![]u8 {
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
