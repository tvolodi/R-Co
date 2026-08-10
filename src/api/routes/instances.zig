//! HTTP route handlers for instance operations:
//!   EE-01 — POST /api/v1/instances
//!   EE-08 — POST /api/v1/instances/:id/cancel
//!   EE-11 — POST /api/v1/instances/:id/reconstruct
//!
//! Wire in main.zig:
//!   pub const instance_routes = @import("api/routes/instances.zig");
const std = @import("std");
const instance_mod = @import("../../engine/instance.zig");
const task_mod = @import("../../tasks/store.zig");
const reconstruction_mod = @import("../../engine/reconstruction.zig");
const event_store = @import("../../event_store/store.zig");
const event_registry = @import("../../event_store/registry.zig");
const timeline_mod = @import("../../obs/timeline.zig");
const pagination = @import("../pagination.zig");

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

// ---------------------------------------------------------------------------
// Public handler functions
// ---------------------------------------------------------------------------

/// POST /api/v1/instances
///
/// Request body (application/json):
///   {
///     "definition_id":    "<UUID>",
///     "correlation_key":  "<string> | null",   // optional
///     "initial_variables": { ... }              // required JSON object
///   }
///
/// Success — HTTP 201:
///   { "instance_id": "<UUID>", "status": "ACTIVE", "created_at": "<ISO8601>" }
///
/// Error codes:
///   400  MALFORMED_JSON
///   404  DEFINITION_NOT_FOUND
///   409  DEFINITION_NOT_ACTIVE
///   409  DUPLICATE_CORRELATION_KEY
///   422  INVALID_DEFINITION_ID
///   422  INVALID_CORRELATION_KEY
///   422  INVALID_INITIAL_VARIABLES
///   500  INTERNAL_ERROR
///   503  SERVICE_UNAVAILABLE
pub fn handleCreate(
    store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    body: []const u8,
) HandlerResult {
    // ── Step 1: Parse JSON body ────────────────────────────────────────────
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch {
        return errorResult(allocator, 400, "MALFORMED_JSON", "Request body is not valid JSON");
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 400, "MALFORMED_JSON", "Request body must be a JSON object"),
    };

    // ── Step 2: Extract definition_id (required UUID string) ──────────────
    const def_id_raw = obj.get("definition_id") orelse
        return errorResult(allocator, 422, "INVALID_DEFINITION_ID", "definition_id is required");
    const def_id_str: []const u8 = switch (def_id_raw) {
        .string => |s| s,
        else => return errorResult(allocator, 422, "INVALID_DEFINITION_ID", "definition_id must be a UUID string"),
    };
    const definition_id = parseUuid(def_id_str) catch
        return errorResult(allocator, 422, "INVALID_DEFINITION_ID", "definition_id is not a valid UUID");

    // ── Step 3: Extract correlation_key (optional string or null) ─────────
    const correlation_key: ?[]const u8 = blk: {
        const ck_val = obj.get("correlation_key") orelse break :blk null;
        switch (ck_val) {
            .null => break :blk null,
            .string => |s| break :blk s,
            else => return errorResult(
                allocator,
                422,
                "INVALID_CORRELATION_KEY",
                "correlation_key must be a string or null",
            ),
        }
    };

    // ── Step 4: Extract initial_variables (required JSON object) ──────────
    const iv_raw = obj.get("initial_variables") orelse
        return errorResult(allocator, 422, "INVALID_INITIAL_VARIABLES", "initial_variables is required");
    switch (iv_raw) {
        .object => {},
        else => return errorResult(
            allocator,
            422,
            "INVALID_INITIAL_VARIABLES",
            "initial_variables must be a JSON object",
        ),
    }

    // Re-serialise the initial_variables value to a canonical JSON string.
    // Security: this re-encodes the already-parsed value — no user string passed
    // directly to SQL (the store further binds it via $4::jsonb).
    const iv_json = std.json.Stringify.valueAlloc(allocator, iv_raw, .{}) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Failed to serialize initial_variables");
    defer allocator.free(iv_json);

    // ── Step 5: Call InstanceStore.create() ───────────────────────────────
    const instance = store.create(
        allocator,
        definition_id,
        correlation_key,
        iv_json,
    ) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(
            allocator,
            404,
            "DEFINITION_NOT_FOUND",
            "Definition not found",
        ),
        error.DefinitionNotActive => return errorResult(
            allocator,
            409,
            "DEFINITION_NOT_ACTIVE",
            "Only ACTIVE definitions can be started",
        ),
        error.DuplicateCorrelationKey => return errorResult(
            allocator,
            409,
            "DUPLICATE_CORRELATION_KEY",
            "A process instance with this correlation key already exists for this definition",
        ),
        error.InvalidInput => return errorResult(
            allocator,
            422,
            "INVALID_INITIAL_VARIABLES",
            "initial_variables must be a JSON object",
        ),
        error.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "Service temporarily unavailable",
        ),
        error.TransactionFailed => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Internal server error",
        ),
    };
    // Free caller-owned Instance slices.
    defer {
        allocator.free(instance.initial_variables);
        allocator.free(instance.definition_snapshot);
        if (instance.correlation_key) |ck| allocator.free(ck);
    }

    // ── Step 6: Build HTTP 201 response ───────────────────────────────────
    const inst_id_hex = uuidToHex(allocator, instance.instance_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Failed to format instance ID");
    defer allocator.free(inst_id_hex);

    const created_at_str = formatTimestamp(allocator, instance.created_at) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Failed to format timestamp");
    defer allocator.free(created_at_str);

    const body_out = std.fmt.allocPrint(
        allocator,
        "{{\"instance_id\":\"{s}\",\"status\":\"ACTIVE\",\"created_at\":\"{s}\"}}",
        .{ inst_id_hex, created_at_str },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return .{ .status_code = 201, .body = body_out };
}

/// POST /api/v1/instances/:id/cancel
///
/// Path parameter: `id` — UUID string identifying the instance to cancel.
/// `actor_id` — authenticated caller's user identity from the auth middleware.
///              Passed as an empty string placeholder until IDN-04 delivers
///              real user IDs (OQ-EE08-2); stored in the event payload verbatim.
///
/// Success — HTTP 200:
///   { "instance_id": "<UUID>", "status": "CANCELLED" }
///
/// Error codes:
///   404  INSTANCE_NOT_FOUND
///   409  INSTANCE_ALREADY_TERMINATED
///   422  INVALID_INSTANCE_ID
///   500  INTERNAL_ERROR
///   503  SERVICE_UNAVAILABLE
pub fn handleCancel(
    store: *instance_mod.InstanceStore,
    task_store: *task_mod.TaskStore,
    allocator: std.mem.Allocator,
    instance_id_str: []const u8,
    actor_id: []const u8,
) HandlerResult {
    // ── Step 1: Parse the instance_id path parameter ──────────────────────
    const instance_id = parseUuid(instance_id_str) catch
        return errorResult(allocator, 422, "INVALID_INSTANCE_ID", "instance_id is not a valid UUID");

    // ── Step 2: Call InstanceStore.cancelInstance() ───────────────────────
    store.cancelInstance(allocator, task_store, instance_id, actor_id) catch |err| switch (err) {
        error.InstanceNotFound => return errorResult(
            allocator,
            404,
            "INSTANCE_NOT_FOUND",
            "Instance not found",
        ),
        error.InstanceAlreadyTerminated => return errorResult(
            allocator,
            409,
            "INSTANCE_ALREADY_TERMINATED",
            "Instance is already cancelled or completed",
        ),
        error.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "Service temporarily unavailable",
        ),
        error.PersistenceFailed, error.OutOfMemory => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Internal server error",
        ),
    };

    // ── Step 3: Build HTTP 200 response ───────────────────────────────────
    const inst_id_hex = uuidToHex(allocator, instance_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Failed to format instance ID");
    defer allocator.free(inst_id_hex);

    const body_out = std.fmt.allocPrint(
        allocator,
        "{{\"instance_id\":\"{s}\",\"status\":\"CANCELLED\"}}",
        .{inst_id_hex},
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return .{ .status_code = 200, .body = body_out };
}

// ---------------------------------------------------------------------------
// handleReconstruct  (EE-11)
// ---------------------------------------------------------------------------

/// POST /api/v1/instances/:id/reconstruct
///
/// Replays the full ordered event log for the given instance through the pure
/// transition function and persists the resulting state back to
/// instance_projections (write_back = true).
///
/// Requires operator-level authorization (enforced by auth middleware before
/// this handler is invoked).
///
/// Success — HTTP 200:
///   { "instance_id": "<UUID>", "status": "<STATUS>",
///     "tokens": [...], "variables": {...} }
///
/// Error codes:
///   404  INSTANCE_NOT_FOUND  — no events found for this instance_id
///   409  LOCK_CONTENTION     — instance_projections row locked by another tx
///   422  INVALID_INSTANCE_ID — path parameter is not a valid UUID
///   500  INTERNAL_ERROR      — replay failed or serialization error
///   503  SERVICE_UNAVAILABLE — connection pool exhausted
pub fn handleReconstruct(
    store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    instance_id_str: []const u8,
) HandlerResult {
    // ── Step 1: Parse instance_id from path parameter ─────────────────────
    const instance_id = parseUuid(instance_id_str) catch
        return errorResult(allocator, 422, "INVALID_INSTANCE_ID", "instance_id is not a valid UUID");

    // ── Step 2: Reconstruct state and write back ──────────────────────────
    const state = reconstruction_mod.reconstructInstance(
        allocator,
        store.pool,
        store.snapshot_store,
        instance_id,
        true, // write_back = true per EE-11 spec
    ) catch |err| switch (err) {
        error.InstanceNotFound => return errorResult(
            allocator,
            404,
            "INSTANCE_NOT_FOUND",
            "Instance not found",
        ),
        error.LockContention => return errorResult(
            allocator,
            409,
            "LOCK_CONTENTION",
            "Instance is locked by another transaction",
        ),
        error.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "Service temporarily unavailable",
        ),
        else => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "State reconstruction failed",
        ),
    };

    // ── Step 3: Serialize response ─────────────────────────────────────────
    // Use a local arena for intermediate strings; the final body is allocated
    // in `allocator` so it outlives the arena deinit.
    var serial_arena = std.heap.ArenaAllocator.init(allocator);
    defer serial_arena.deinit();
    const sa = serial_arena.allocator();

    const inst_id_hex = uuidToHex(sa, instance_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const status_str: []const u8 = switch (state.status) {
        .ACTIVE => "ACTIVE",
        .COMPLETED => "COMPLETED",
        .CANCELLED => "CANCELLED",
        .ERROR => "ERROR",
        .RESTORED_ORPHAN => "RESTORED_ORPHAN",
    };

    // tokens JSON array
    var tokens_buf = std.ArrayList(u8).empty;
    tokens_buf.append(sa, '[') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    for (state.tokens, 0..) |tok, i| {
        if (i > 0) tokens_buf.append(sa, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const entry = std.fmt.allocPrint(
            sa,
            "{{\"node_id\":\"{s}\",\"branch_id\":\"{s}\"}}",
            .{ tok.node_id, tok.branch_id },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        tokens_buf.appendSlice(sa, entry) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    tokens_buf.append(sa, ']') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    // variables JSON object
    const vars_json = std.json.Stringify.valueAlloc(
        sa,
        std.json.Value{ .object = state.variables },
        .{},
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    // Final body allocated in `allocator` — survives serial_arena.deinit().
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"instance_id\":\"{s}\",\"status\":\"{s}\",\"tokens\":{s},\"variables\":{s}}}",
        .{ inst_id_hex, status_str, tokens_buf.items, vars_json },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// handleGetById  (API-03)
// ---------------------------------------------------------------------------

/// GET /api/v1/instances/:id
///
/// Returns the full instance state including current_tasks (PENDING tasks only),
/// variables (nested JSON object), started_at, completed_at / cancelled_at if terminal,
/// and error_detail if status is ERROR.
///
/// Authorisation: any authenticated role (API-03 AC).
///
/// Success:        HTTP 200 + JSON InstanceDetailResponse.
/// Not found:      HTTP 404.
/// Invalid UUID:   HTTP 422.
/// Pool exhausted: HTTP 503.
/// Server error:   HTTP 500.
pub fn handleGetById(
    instance_store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    instance_id_str: []const u8,
) HandlerResult {
    // ── Step 1: Parse UUID from path parameter ─────────────────────────────
    const instance_id = parseUuid(instance_id_str) catch
        return errorResult(allocator, 422, "INVALID_INSTANCE_ID", "instance_id is not a valid UUID");

    // ── Step 2: Fetch instance + PENDING tasks ──────────────────────────────
    const data = instance_store.getById(allocator, instance_id) catch |err| switch (err) {
        error.InstanceNotFound => return errorResult(allocator, 404, "INSTANCE_NOT_FOUND", "Instance not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        error.PersistenceFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
    };
    // Free all allocator-owned fields on exit.
    defer {
        if (data.correlation_key) |ck| allocator.free(ck);
        allocator.free(data.variables);
        if (data.error_detail) |ed| allocator.free(ed);
        for (data.tasks) |t| task_mod.freeTask(allocator, t);
        allocator.free(data.tasks);
    }

    // ── Step 3: Build JSON response ─────────────────────────────────────────
    // Use a local arena for intermediate strings; the final body is the only
    // thing allocated from `allocator` that must outlive this function.
    var serial_arena = std.heap.ArenaAllocator.init(allocator);
    defer serial_arena.deinit();
    const sa = serial_arena.allocator();

    const inst_id_hex = uuidToHex(sa, data.instance_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    const def_id_hex = uuidToHex(sa, data.definition_id) catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const status_str: []const u8 = switch (data.status) {
        .ACTIVE => "ACTIVE",
        .COMPLETED => "COMPLETED",
        .CANCELLED => "CANCELLED",
        .ERROR => "ERROR",
        .RESTORED_ORPHAN => "RESTORED_ORPHAN",
    };

    // correlation_key: JSON string or null
    const ck_json: []const u8 = if (data.correlation_key) |ck|
        std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = ck }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
    else
        "null";

    // current_tasks JSON array
    var tasks_buf = std.ArrayList(u8).empty;
    tasks_buf.append(sa, '[') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    for (data.tasks, 0..) |t, i| {
        if (i > 0) tasks_buf.append(sa, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const t_id_hex = uuidToHex(sa, t.task_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const t_node_id_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = t.node_id }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const t_node_name_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = t.node_name }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const t_at_json: []const u8 = if (t.assignee_type) |at|
            std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = at }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
        else
            "null";
        const t_ar_json: []const u8 = if (t.assignee_ref) |ar|
            std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = ar }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
        else
            "null";

        const entry = std.fmt.allocPrint(
            sa,
            "{{\"task_id\":\"{s}\",\"node_id\":{s},\"node_name\":{s},\"status\":\"PENDING\",\"assignee_type\":{s},\"assignee_ref\":{s},\"created_at\":{d}}}",
            .{ t_id_hex, t_node_id_json, t_node_name_json, t_at_json, t_ar_json, t.created_at },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        tasks_buf.appendSlice(sa, entry) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    tasks_buf.append(sa, ']') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    // variables: re-parse the JSONB string and re-embed as a raw JSON object.
    // This ensures the response has `"variables": {...}` not `"variables": "{...}"`.
    // OQ-3 resolution: option (a) — embed as a nested JSON object.
    const vars_embedded: []const u8 = blk: {
        const parsed_vars = std.json.parseFromSlice(
            std.json.Value,
            sa,
            data.variables,
            .{ .allocate = .alloc_always },
        ) catch break :blk data.variables; // fallback: embed raw string if parse fails
        defer parsed_vars.deinit();
        break :blk std.json.Stringify.valueAlloc(sa, parsed_vars.value, .{}) catch data.variables;
    };

    // completed_at: integer or null
    const completed_at_json: []const u8 = if (data.completed_at) |ca|
        std.fmt.allocPrint(sa, "{d}", .{ca}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
    else
        "null";

    // cancelled_at: integer or null
    const cancelled_at_json: []const u8 = if (data.cancelled_at) |ca|
        std.fmt.allocPrint(sa, "{d}", .{ca}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
    else
        "null";

    // error_detail: raw JSON string or null
    const error_detail_json: []const u8 = data.error_detail orelse "null";

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"instance_id\":\"{s}\",\"definition_id\":\"{s}\",\"correlation_key\":{s},\"status\":\"{s}\",\"current_tasks\":{s},\"variables\":{s},\"started_at\":{d},\"completed_at\":{s},\"cancelled_at\":{s},\"error_detail\":{s}}}",
        .{
            inst_id_hex,
            def_id_hex,
            ck_json,
            status_str,
            tasks_buf.items,
            vars_embedded,
            data.started_at,
            completed_at_json,
            cancelled_at_json,
            error_detail_json,
        },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// handleList  (API-03)
// ---------------------------------------------------------------------------

/// GET /api/v1/instances
///
/// Returns a paginated, optionally-filtered list of instances.
/// Results sorted by started_at DESC, instance_id DESC (keyset pagination).
///
/// Query parameters (parsed before this handler is called):
///   status        — optional filter: "ACTIVE" | "COMPLETED" | "CANCELLED" | "ERROR"
///   definition_id — optional UUID filter string
///   cursor        — optional opaque continuation cursor (base64url)
///   page_size     — validated integer, default 50, max 200
///
/// Authorisation: any authenticated role (API-03 AC).
///
/// Success:              HTTP 200 + JSON InstanceListResponse.
/// Invalid status value: HTTP 422.
/// Invalid definition_id UUID: HTTP 422.
/// Invalid cursor:       HTTP 422.
/// Expired cursor:       HTTP 410.
/// Invalid page_size:    HTTP 422.
/// Pool exhausted:       HTTP 503.
/// Server error:         HTTP 500.
pub fn handleList(
    instance_store: *instance_mod.InstanceStore,
    allocator: std.mem.Allocator,
    params: ListInstancesParams,
) HandlerResult {
    // ── Step 1: Validate status filter ─────────────────────────────────────
    if (params.status) |s| {
        const valid = std.mem.eql(u8, s, "ACTIVE") or
            std.mem.eql(u8, s, "COMPLETED") or
            std.mem.eql(u8, s, "CANCELLED") or
            std.mem.eql(u8, s, "ERROR");
        if (!valid) return errorResult(
            allocator,
            422,
            "INVALID_STATUS",
            "status must be one of: ACTIVE, COMPLETED, CANCELLED, ERROR",
        );
    }

    // ── Step 2: Validate page_size ──────────────────────────────────────────
    const effective_page_size = pagination.validatePageSize(params.page_size) catch |err| switch (err) {
        error.PageSizeTooLarge => return errorResult(
            allocator,
            422,
            "INVALID_PAGE_SIZE",
            "page_size must be between 1 and 200",
        ),
    };

    // ── Step 3: Parse definition_id UUID (if present) ──────────────────────
    const definition_id_uuid: ?instance_mod.Uuid = blk: {
        const raw = params.definition_id orelse break :blk null;
        break :blk parseUuid(raw) catch
            return errorResult(allocator, 422, "INVALID_DEFINITION_ID", "definition_id is not a valid UUID");
    };

    // ── Step 4: Decode cursor (if present) ─────────────────────────────────
    // Cursor format:
    //   base64url_no_pad( "I:" decimal(started_at_us) ":" instance_id_hex ":" decimal(cursor_created_at_us) )
    // The "I:" prefix discriminates instance cursors from other endpoints.
    // The third segment enables 24-hour expiry checking without external storage.
    var cursor_started_at: ?i64 = null;
    var cursor_instance_id: ?[]const u8 = null;
    if (params.cursor) |cursor_str| {
        // Decode base64 + validate "I:" prefix.
        // Use a large expiry window for the base decodeCursor call — we do the
        // real expiry check manually against the third segment.
        const cursor = pagination.decodeCursor(allocator, cursor_str, "I:", 2, std.math.maxInt(i64)) catch |err| switch (err) {
            error.InvalidBase64 => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid base64url"),
            error.WrongEndpoint => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid for this endpoint"),
            error.Expired => unreachable, // expiry window is maxInt
            error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        };
        defer cursor.deinit();

        // Find the three colons: "I:" colon, then started_at ":" colon, then instance_id ":" colon
        const after_prefix = cursor.inner[2..]; // skip "I:"
        const first_colon = pagination.findNthColon(after_prefix, 1) orelse
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor format is invalid");
        const second_colon = pagination.findNthColon(after_prefix, 2) orelse
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor format is invalid");

        const ts_part = after_prefix[0..first_colon];
        const id_part = after_prefix[first_colon + 1 .. second_colon];
        const age_part = after_prefix[second_colon + 1 ..];

        const ts = std.fmt.parseInt(i64, ts_part, 10) catch
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor timestamp is not a valid integer");
        const cursor_age_us = std.fmt.parseInt(i64, age_part, 10) catch
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor age is not a valid integer");

        // Expiry check: 24 hours = 86_400_000_000 microseconds.
        const now_us = currentMicrosecondTimestamp();
        if (now_us - cursor_age_us > pagination.CURSOR_EXPIRY_US) {
            return errorResult(allocator, 410, "CURSOR_EXPIRED", "Cursor has expired; please restart pagination");
        }

        cursor_started_at = ts;
        // Dupe the id_part into allocator so it outlives `cursor`.
        cursor_instance_id = allocator.dupe(u8, id_part) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory");
    }
    defer if (cursor_instance_id) |cid| allocator.free(cid);

    // ── Step 5: Call InstanceStore.listInstances() ─────────────────────────
    const list_params = instance_mod.ListParams{
        .status = params.status,
        .definition_id = definition_id_uuid,
        .cursor_started_at = cursor_started_at,
        .cursor_instance_id = cursor_instance_id,
        .page_size = effective_page_size,
    };

    const rows = instance_store.listInstances(allocator, list_params) catch |err| switch (err) {
        error.PoolExhausted => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        error.PersistenceFailed => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
    };
    defer {
        for (rows) |row| {
            if (row.correlation_key) |ck| allocator.free(ck);
        }
        allocator.free(rows);
    }

    // ── Step 6: Determine next cursor ──────────────────────────────────────
    // If we got page_size+1 rows, there is a next page.
    const has_next = rows.len > @as(usize, effective_page_size);
    const page_rows = if (has_next) rows[0..effective_page_size] else rows;

    var serial_arena = std.heap.ArenaAllocator.init(allocator);
    defer serial_arena.deinit();
    const sa = serial_arena.allocator();

    const next_cursor_json: []const u8 = if (has_next) blk: {
        // Derive cursor from the last item on the page (page_rows[page_rows.len - 1]).
        const last = page_rows[page_rows.len - 1];
        const last_id_hex = uuidToHex(sa, last.instance_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const now_us2 = currentMicrosecondTimestamp();
        const raw_cursor = pagination.buildRawCursorTimestampKey(
            sa,
            "I:",
            last.started_at,
            last_id_hex,
            now_us2,
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const encoded = pagination.encodeCursor(sa, raw_cursor) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const quoted = std.fmt.allocPrint(sa, "\"{s}\"", .{encoded}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        break :blk quoted;
    } else "null";

    // ── Step 7: Serialize items array ──────────────────────────────────────
    var items_buf = std.ArrayList(u8).empty;
    items_buf.append(sa, '[') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    for (page_rows, 0..) |row, i| {
        if (i > 0) items_buf.append(sa, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const iid_hex = uuidToHex(sa, row.instance_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const did_hex = uuidToHex(sa, row.definition_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const ck_json: []const u8 = if (row.correlation_key) |ck|
            std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = ck }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
        else
            "null";
        const status_str2: []const u8 = switch (row.status) {
            .ACTIVE => "ACTIVE",
            .COMPLETED => "COMPLETED",
            .CANCELLED => "CANCELLED",
            .ERROR => "ERROR",
            .RESTORED_ORPHAN => "RESTORED_ORPHAN",
        };
        const entry = std.fmt.allocPrint(
            sa,
            "{{\"instance_id\":\"{s}\",\"definition_id\":\"{s}\",\"correlation_key\":{s},\"status\":\"{s}\",\"started_at\":{d}}}",
            .{ iid_hex, did_hex, ck_json, status_str2, row.started_at },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        items_buf.appendSlice(sa, entry) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    items_buf.append(sa, ']') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    // ── Step 8: Build final JSON body ───────────────────────────────────────
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"items\":{s},\"next_cursor\":{s},\"count\":{d}}}",
        .{ items_buf.items, next_cursor_json, page_rows.len },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// ListInstancesParams — query parameters for handleList
// ---------------------------------------------------------------------------

/// Query parameters for GET /api/v1/instances.
pub const ListInstancesParams = struct {
    /// Optional filter: "ACTIVE" | "COMPLETED" | "CANCELLED" | "ERROR". Null = no filter.
    status: ?[]const u8,
    /// Optional filter: UUID string. Null = no filter.
    definition_id: ?[]const u8,
    /// Opaque base64url cursor. Null = first page.
    cursor: ?[]const u8,
    /// Page size; default 50, max 200. Must be >= 1.
    page_size: u16,
};

// ---------------------------------------------------------------------------
// HistoryParams — query parameters for handleHistory (API-05)
// ---------------------------------------------------------------------------

/// Query parameters for GET /api/v1/instances/:id/history.
pub const HistoryParams = struct {
    /// Optional: filter to a specific event_type name. Null = all types.
    event_type: ?[]const u8 = null,
    /// Optional: ISO 8601 timestamp (inclusive lower bound on created_at).
    from: ?[]const u8 = null,
    /// Optional: ISO 8601 timestamp (inclusive upper bound on created_at).
    to: ?[]const u8 = null,
    /// Optional: ADP-06 pipeline run correlation filter.
    pipeline_run_id: ?[]const u8 = null,
    /// Cursor for continuation pagination (opaque base64url string).
    cursor: ?[]const u8 = null,
    /// Page size; default 50, max 200.
    page_size: u16 = 50,
};

/// Query parameters for GET /api/v1/instances/:id/timeline.
pub const TimelineParams = struct {
    /// Opaque base64url cursor. Null = first page.
    cursor: ?[]const u8,
    /// Page size; default 50, max 200.
    page_size: u16,
};

// ---------------------------------------------------------------------------
// handleHistory  (API-05)
// ---------------------------------------------------------------------------

/// GET /api/v1/instances/:id/history
///
/// Returns the full ordered event log for an instance in ascending sequence order.
/// Includes archived events (events_archive) merged by sequence_number with live events.
///
/// Query parameters:
///   event_type — optional filter to a specific event type name
///   from       — optional ISO 8601 timestamp (inclusive lower bound on created_at)
///   to         — optional ISO 8601 timestamp (inclusive upper bound on created_at)
///   pipeline_run_id — optional ADP-06 correlation filter
///   cursor     — optional opaque continuation cursor
///   page_size  — validated integer, default 50, max 200
///
/// Authorisation: any authenticated role (API-05 AC).
///
/// Success:              HTTP 200 + JSON HistoryResponse.
/// Instance not found:   HTTP 404 + Problem Details.
/// Invalid instance_id:  HTTP 422 + Problem Details.
/// from > to:            HTTP 422 + Problem Details.
/// Unknown event_type:   HTTP 422 + Problem Details.
/// Invalid from/to:      HTTP 422 + Problem Details.
/// Invalid cursor:       HTTP 422 + Problem Details.
/// Expired cursor:       HTTP 410 + Problem Details.
/// Invalid page_size:    HTTP 422 + Problem Details.
/// Pool exhausted:       HTTP 503 + Problem Details.
/// Server error:         HTTP 500 + Problem Details.
pub fn handleHistory(
    event_store_mod: *event_store.Store,
    allocator: std.mem.Allocator,
    instance_id_str: []const u8,
    params: HistoryParams,
) HandlerResult {
    // ── Step 1: Parse UUID from path parameter ─────────────────────────────
    const instance_id = parseUuid(instance_id_str) catch
        return errorResult(allocator, 422, "INVALID_INSTANCE_ID", "instance_id is not a valid UUID");

    // ── Step 2: Validate page_size ──────────────────────────────────────────
    const effective_history_page_size = pagination.validatePageSize(params.page_size) catch |err| switch (err) {
        error.PageSizeTooLarge => return errorResult(
            allocator,
            422,
            "INVALID_PAGE_SIZE",
            "page_size must be between 1 and 200",
        ),
    };

    // ── Step 3: Parse from/to timestamps ────────────────────────────────────
    const from_us: ?i64 = if (params.from) |f| blk: {
        break :blk parseIso8601ToMicros(f) catch
            return errorResult(allocator, 422, "INVALID_TIMESTAMP", "from timestamp is not a valid ISO 8601 string");
    } else null;

    const to_us: ?i64 = if (params.to) |t| blk: {
        break :blk parseIso8601ToMicros(t) catch
            return errorResult(allocator, 422, "INVALID_TIMESTAMP", "to timestamp is not a valid ISO 8601 string");
    } else null;

    // ── Step 4: Validate from <= to ─────────────────────────────────────────
    if (from_us != null and to_us != null and from_us.? > to_us.?) {
        return errorResult(allocator, 422, "INVALID_TIMESTAMP_RANGE", "from timestamp must not be after to timestamp");
    }

    // ── Step 5: Decode cursor (if present) ──────────────────────────────────
    // Cursor format: base64url_no_pad("H:" || decimal(now_us) || ":" || decimal(sequence_number))
    // where now_us is the server time when the cursor was created.
    // Validate format first, then check expiry.
    var after_sequence: ?i64 = null;
    if (params.cursor) |cursor_str| {
        // Use decodeCursor for base64 + prefix check, but skip expiry (huge window).
        // We do the real expiry check after format validation.
        const cursor = pagination.decodeCursor(allocator, cursor_str, "H:", 2, std.math.maxInt(i64)) catch |err| switch (err) {
            error.InvalidBase64 => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid base64url"),
            error.WrongEndpoint => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid for this endpoint"),
            error.Expired => unreachable, // expiry window is maxInt
            error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        };
        defer cursor.deinit();

        // Format: "H:{now_us}:{sequence_number}"
        // Skip "H:" prefix, find colon separator.
        const after_prefix = cursor.inner[2..];
        const colon = std.mem.indexOfScalar(u8, after_prefix, ':') orelse
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor format is invalid");

        const now_us_str = after_prefix[0..colon];
        const seq_str = after_prefix[colon + 1 ..];

        const cursor_now_us = std.fmt.parseInt(i64, now_us_str, 10) catch
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor timestamp is not a valid integer");
        const cursor_seq = std.fmt.parseInt(i64, seq_str, 10) catch
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor sequence is not a valid integer");

        // Expiry check after format validation: 24 hours.
        const current_us = currentMicrosecondTimestamp();
        if (current_us - cursor_now_us > pagination.CURSOR_EXPIRY_US) {
            return errorResult(allocator, 410, "CURSOR_EXPIRED", "Cursor has expired; please restart pagination");
        }

        after_sequence = cursor_seq;
    }

    // ── Step 6: Validate event_type against registry ───────────────────────
    if (params.event_type) |et| {
        // GH-280 / ISS-0040 rework: getType() returns an EventTypeRecord that
        // owns three allocations (name, json_schema, description) — this call
        // site only needs the UnknownEventType/success signal, but previously
        // discarded the record with a bare `_ =`, leaking all three on every
        // successful lookup (every GET .../history?event_type=<known type>
        // request). event_store.Registry.freeTypeRecord() is the same helper
        // Registry.validatePayload() already uses to release this exact type.
        const type_record = event_store_mod.registry.getType(allocator, et) catch |err| switch (err) {
            event_registry.RegistryError.UnknownEventType => return errorResult(
                allocator,
                422,
                "UNKNOWN_EVENT_TYPE",
                "event_type is not registered",
            ),
            else => return errorResult(allocator, 503, "SERVICE_UNAVAILABLE", "Service temporarily unavailable"),
        };
        event_registry.Registry.freeTypeRecord(allocator, type_record);
    }

    // ── Step 7: Call Store.readHistory() ────────────────────────────────────
    const records = event_store_mod.readHistory(
        allocator,
        instance_id,
        event_store.HistoryReadOpts{
            .event_type = params.event_type,
            .from = from_us,
            .to = to_us,
            .pipeline_run_id = params.pipeline_run_id,
            .after_sequence = after_sequence,
            .limit = effective_history_page_size,
        },
    ) catch |err| switch (err) {
        event_store.StoreError.InstanceNotFound => return errorResult(
            allocator,
            404,
            "INSTANCE_NOT_FOUND",
            "Instance not found",
        ),
        event_store.StoreError.PoolExhausted => return errorResult(
            allocator,
            503,
            "SERVICE_UNAVAILABLE",
            "Service temporarily unavailable",
        ),
        else => return errorResult(
            allocator,
            500,
            "INTERNAL_ERROR",
            "Internal server error",
        ),
    };
    defer {
        for (records) |rec| {
            allocator.free(rec.event_type);
            allocator.free(rec.payload);
            allocator.free(rec.metadata);
        }
        allocator.free(records);
    }

    // ── Step 8: Build serialised response ───────────────────────────────────
    var serial_arena = std.heap.ArenaAllocator.init(allocator);
    defer serial_arena.deinit();
    const sa = serial_arena.allocator();

    // Determine if there's a next page: if we got page_size + 1 rows.
    const has_next = records.len > @as(usize, effective_history_page_size);
    const page_records = if (has_next) records[0..effective_history_page_size] else records;

    // Serialise items array
    var items_buf = std.ArrayList(u8).empty;
    items_buf.append(sa, '[') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    for (page_records, 0..) |rec, i| {
        if (i > 0) items_buf.append(sa, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const eid_hex = uuidToHex(sa, rec.event_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const iid_hex = uuidToHex(sa, rec.instance_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const aid_hex = uuidToHex(sa, rec.actor_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const et_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = rec.event_type }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const payload_json: []const u8 = blk: {
            // payload is already a JSON string; embed it directly or as a raw string.
            // If it starts with '{', embed as raw JSON; otherwise string-quote it.
            const trimmed = std.mem.trimStart(u8, rec.payload, &std.ascii.whitespace);
            if (trimmed.len > 0 and trimmed[0] == '{') break :blk rec.payload;
            break :blk std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = rec.payload }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        };
        const ikey_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = rec.idempotency_key }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const meta_json: []const u8 = blk: {
            const trimmed = std.mem.trimStart(u8, rec.metadata, &std.ascii.whitespace);
            if (trimmed.len > 0 and trimmed[0] == '{') break :blk rec.metadata;
            break :blk std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = rec.metadata }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        };

        const entry = std.fmt.allocPrint(
            sa,
            "{{\"event_id\":\"{s}\",\"instance_id\":\"{s}\",\"event_type\":{s},\"payload\":{s},\"actor_id\":\"{s}\",\"created_at\":{d},\"sequence_number\":{d},\"idempotency_key\":{s},\"metadata\":{s},\"global_seq\":{d}}}",
            .{
                eid_hex,        iid_hex,             et_json,   payload_json, aid_hex,
                rec.created_at, rec.sequence_number, ikey_json, meta_json,    rec.global_seq,
            },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        items_buf.appendSlice(sa, entry) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    items_buf.append(sa, ']') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    // Encode next_cursor if there's a next page
    const next_cursor_json: []const u8 = if (has_next) blk: {
        const last = page_records[page_records.len - 1];
        const now_us2 = currentMicrosecondTimestamp();
        // Format: H:{now_us}:{sequence_number}
        const raw_with_seq = std.fmt.allocPrint(
            sa,
            "H:{d}:{d}",
            .{ now_us2, last.sequence_number },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const encoded = pagination.encodeCursor(sa, raw_with_seq) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const quoted = std.fmt.allocPrint(sa, "\"{s}\"", .{encoded}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        break :blk quoted;
    } else "null";

    // ── Step 9: Build final JSON body ───────────────────────────────────────
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"items\":{s},\"next_cursor\":{s},\"count\":{d}}}",
        .{ items_buf.items, next_cursor_json, page_records.len },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// handleTimeline  (OBS-04)
// ---------------------------------------------------------------------------

/// GET /api/v1/instances/:id/timeline
///
/// Returns a human-readable ascending chronological timeline for an instance,
/// including archived events and actor display-name resolution.
pub fn handleTimeline(
    event_store_mod: *event_store.Store,
    allocator: std.mem.Allocator,
    instance_id_str: []const u8,
    params: TimelineParams,
) HandlerResult {
    const instance_id = parseUuid(instance_id_str) catch
        return errorResult(allocator, 422, "INVALID_INSTANCE_ID", "instance_id is not a valid UUID");

    const effective_page_size = pagination.validatePageSize(params.page_size) catch |err| switch (err) {
        error.PageSizeTooLarge => return errorResult(
            allocator,
            422,
            "INVALID_PAGE_SIZE",
            "page_size must be between 1 and 200",
        ),
    };

    var after_sequence: ?i64 = null;
    if (params.cursor) |cursor_str| {
        const cursor = pagination.decodeCursor(
            allocator,
            cursor_str,
            "TL:",
            3,
            pagination.CURSOR_EXPIRY_US,
        ) catch |err| switch (err) {
            error.InvalidBase64 => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid base64url"),
            error.WrongEndpoint => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor is not valid for this endpoint"),
            error.Expired => return errorResult(allocator, 410, "CURSOR_EXPIRED", "Cursor has expired; please restart pagination"),
            error.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
        };
        defer cursor.deinit();

        const after_prefix = cursor.inner[3..];
        const colon = std.mem.indexOfScalar(u8, after_prefix, ':') orelse
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor format is invalid");
        const seq_str = after_prefix[colon + 1 ..];
        after_sequence = std.fmt.parseInt(i64, seq_str, 10) catch
            return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor sequence is not a valid integer");
    }

    const page = timeline_mod.listTimeline(
        allocator,
        event_store_mod.pool,
        .{
            .instance_id = instance_id,
            .after_sequence = after_sequence,
            .page_size = effective_page_size,
        },
    ) catch |err| switch (err) {
        timeline_mod.TimelineError.InstanceNotFound => return errorResult(allocator, 404, "INSTANCE_NOT_FOUND", "Instance not found"),
        timeline_mod.TimelineError.InvalidCursor => return errorResult(allocator, 422, "INVALID_CURSOR", "Cursor format is invalid"),
        timeline_mod.TimelineError.CursorExpired => return errorResult(allocator, 410, "CURSOR_EXPIRED", "Cursor has expired; please restart pagination"),
        timeline_mod.TimelineError.InvalidPageSize => return errorResult(allocator, 422, "INVALID_PAGE_SIZE", "page_size must be between 1 and 200"),
        timeline_mod.TimelineError.EventStoreFailure,
        timeline_mod.TimelineError.IdentityLookupFailure,
        timeline_mod.TimelineError.RenderFailure,
        => return errorResult(allocator, 500, "INTERNAL_ERROR", "Internal server error"),
        timeline_mod.TimelineError.OutOfMemory => return errorResult(allocator, 500, "INTERNAL_ERROR", "Out of memory"),
    };
    defer timeline_mod.deinitPage(allocator, &page);

    var serial_arena = std.heap.ArenaAllocator.init(allocator);
    defer serial_arena.deinit();
    const sa = serial_arena.allocator();

    var items_buf = std.ArrayList(u8).empty;
    items_buf.append(sa, '[') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    for (page.items, 0..) |item, i| {
        if (i > 0) items_buf.append(sa, ',') catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const event_type_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = item.event_type }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const ts_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = item.timestamp }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const actor_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = item.actor_display_name }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const description_json = std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = item.description }, .{}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const iid_hex = uuidToHex(sa, item.instance_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        const eid_hex = uuidToHex(sa, item.event_id) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

        const task_id_json: []const u8 = if (item.task_id) |tid| blk: {
            const tid_hex = uuidToHex(sa, tid) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
            break :blk std.fmt.allocPrint(sa, "\"{s}\"", .{tid_hex}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        } else "null";

        const node_id_json: []const u8 = if (item.node_id) |nid|
            std.json.Stringify.valueAlloc(sa, std.json.Value{ .string = nid }, .{}) catch
                return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
        else
            "null";

        const metadata_json: []const u8 = blk: {
            const trimmed = std.mem.trimStart(u8, item.metadata_json, &std.ascii.whitespace);
            if (trimmed.len > 0 and trimmed[0] == '{') break :blk item.metadata_json;
            break :blk "{}";
        };

        const entry = std.fmt.allocPrint(
            sa,
            "{{\"event_type\":{s},\"timestamp\":{s},\"actor_display_name\":{s},\"description\":{s},\"instance_id\":\"{s}\",\"event_id\":\"{s}\",\"sequence_num\":{d},\"task_id\":{s},\"node_id\":{s},\"metadata\":{s}}}",
            .{
                event_type_json,
                ts_json,
                actor_json,
                description_json,
                iid_hex,
                eid_hex,
                item.sequence_num,
                task_id_json,
                node_id_json,
                metadata_json,
            },
        ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
        items_buf.appendSlice(sa, entry) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");
    }
    items_buf.append(sa, ']') catch
        return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    const next_cursor_json: []const u8 = if (page.next_cursor) |cursor|
        std.fmt.allocPrint(sa, "\"{s}\"", .{cursor}) catch
            return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed")
    else
        "null";

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"items\":{s},\"next_cursor\":{s},\"count\":{d}}}",
        .{ items_buf.items, next_cursor_json, page.count },
    ) catch return errorResult(allocator, 500, "INTERNAL_ERROR", "Serialization failed");

    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Return the current wall-clock time as UTC microseconds since Unix epoch.
///
/// Zig 0.16 removed std.time.microTimestamp() / nanoTimestamp() from the
/// public API.  The correct portable approach is:
///   - Windows: RtlGetSystemTimePrecise() → 100-ns intervals since 1601-01-01
///     subtract the Windows-to-Unix epoch offset and divide by 10.
///   - POSIX:   posix.system.clock_gettime(.REALTIME, &ts) → timespec.
///
/// This function is used only in the HTTP handler layer (not in transition.zig
/// or any pure-function module), so OS-level calls are permitted here.
fn currentMicrosecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        // RtlGetSystemTimePrecise returns a LARGE_INTEGER (i64) counting
        // 100-nanosecond intervals since 1601-01-01 00:00:00 UTC.
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        // Offset between Windows epoch (1601-01-01) and Unix epoch (1970-01-01):
        // 116444736000000000 × 100 ns intervals.
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10); // convert 100-ns to microseconds
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        const sec_us: i64 = ts.sec * 1_000_000;
        const nsec_us: i64 = @divTrunc(ts.nsec, 1000);
        return sec_us + nsec_us;
    }
}

fn errorResult(
    allocator: std.mem.Allocator,
    status: u16,
    code: []const u8,
    message: []const u8,
) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"{s}\",\"message\":\"{s}\"}}",
        .{ code, message },
    ) catch "{\"error\":\"internal_error\"}";
    return .{ .status_code = status, .body = body };
}

/// Format a UTC microsecond epoch as ISO 8601: YYYY-MM-DDTHH:MM:SS.ffffffZ
///
/// Uses Howard Hinnant's civil-from-days algorithm for correct Gregorian
/// calendar decomposition of any Unix timestamp in the post-1970 range.
/// Reference: https://howardhinnant.github.io/date_algorithms.html
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

    // Shift epoch from 1970-01-01 to 0000-03-01 for Gregorian cycle arithmetic.
    const z: i64 = @as(i64, @intCast(days)) + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @as(u64, @intCast(z - era * 146097)); // day-of-era [0, 146096]
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year-of-era [0, 399]
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100); // day-of-year [0, 365]
    const mp: u64 = (5 * doy + 2) / 153; // month-prime [0, 11]
    const d: u64 = doy - (153 * mp + 2) / 5 + 1; // day [1, 31]
    const m: u64 = if (mp < 10) mp + 3 else mp - 9; // month [1, 12]
    const yr: u64 = @as(u64, @intCast(y + @as(i64, if (m <= 2) 1 else 0)));

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z",
        .{ yr, m, d, hour, minute, second, sub_us },
    );
}

/// Render a UUID as lowercase hex with hyphens: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
fn uuidToHex(allocator: std.mem.Allocator, uuid: instance_mod.Uuid) error{OutOfMemory}![]u8 {
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

/// Parse an ISO 8601 timestamp string into UTC microseconds since Unix epoch.
///
/// Accepted formats:
///   YYYY-MM-DDTHH:MM:SSZ
///   YYYY-MM-DDTHH:MM:SS.sssZ
///   YYYY-MM-DDTHH:MM:SS+HH:MM
///   YYYY-MM-DDTHH:MM:SS-HH:MM
///
/// Uses Howard Hinnant's civil-from-days algorithm for date conversion.
fn parseIso8601ToMicros(s: []const u8) error{InvalidTimestamp}!i64 {
    if (s.len < 20) return error.InvalidTimestamp; // minimum: YYYY-MM-DDTHH:MM:SSZ

    // Parse date: YYYY-MM-DD
    const year = parse4Digits(s[0..4]) catch return error.InvalidTimestamp;
    if (s[4] != '-') return error.InvalidTimestamp;
    const month = parse2Digits(s[5..7]) catch return error.InvalidTimestamp;
    if (s[7] != '-') return error.InvalidTimestamp;
    const day = parse2Digits(s[8..10]) catch return error.InvalidTimestamp;
    if (s[10] != 'T') return error.InvalidTimestamp;

    // Parse time: HH:MM:SS
    const hour = parse2Digits(s[11..13]) catch return error.InvalidTimestamp;
    if (s[13] != ':') return error.InvalidTimestamp;
    const minute = parse2Digits(s[14..16]) catch return error.InvalidTimestamp;
    if (s[16] != ':') return error.InvalidTimestamp;
    const second = parse2Digits(s[17..19]) catch return error.InvalidTimestamp;

    var pos: usize = 19;
    var sub_us: i64 = 0;

    // Optional fractional seconds: .sss (milliseconds) or .ssssss (microseconds)
    if (pos < s.len and s[pos] == '.') {
        pos += 1;
        var frac: i64 = 0;
        var digits: usize = 0;
        while (pos < s.len and s[pos] >= '0' and s[pos] <= '9' and digits < 6) : ({
            pos += 1;
            digits += 1;
        }) {
            frac = frac * 10 + (s[pos] - '0');
        }
        // Normalise to microseconds
        sub_us = switch (digits) {
            1 => frac * 100_000,
            2 => frac * 10_000,
            3 => frac * 1_000,
            4 => frac * 100,
            5 => frac * 10,
            6 => frac,
            else => frac,
        };
    }

    // Timezone offset
    var tz_offset_min: i64 = 0;
    if (pos >= s.len) return error.InvalidTimestamp;
    if (s[pos] == 'Z') {
        pos += 1;
    } else if (s[pos] == '+' or s[pos] == '-') {
        const sign: i64 = if (s[pos] == '+') 1 else -1;
        pos += 1;
        if (pos + 2 > s.len) return error.InvalidTimestamp;
        // Support both HH:MM and HHMM formats
        if (pos + 5 <= s.len and s[pos + 2] == ':') {
            const tz_h = parse2Digits(s[pos .. pos + 2]) catch return error.InvalidTimestamp;
            const tz_m = parse2Digits(s[pos + 3 .. pos + 5]) catch return error.InvalidTimestamp;
            tz_offset_min = sign * (@as(i64, tz_h) * 60 + tz_m);
            pos += 5;
        } else if (pos + 4 <= s.len) {
            const tz_h = parse2Digits(s[pos .. pos + 2]) catch return error.InvalidTimestamp;
            const tz_m = parse2Digits(s[pos + 2 .. pos + 4]) catch return error.InvalidTimestamp;
            tz_offset_min = sign * (@as(i64, tz_h) * 60 + tz_m);
            pos += 4;
        } else {
            return error.InvalidTimestamp;
        }
    } else {
        return error.InvalidTimestamp;
    }

    // There should be no trailing characters
    if (pos != s.len) return error.InvalidTimestamp;

    // Calculate days since Unix epoch using civil-from-days algorithm.
    // Shift to March-based year (month 1 = March, ... month 12 = February).
    const m_adj: i64 = if (month <= 2) @as(i64, month) + 9 else @as(i64, month) - 3;
    const y_adj: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era: i64 = @divFloor(y_adj, 400);
    const yoe: i64 = y_adj - era * 400; // year-of-era [0, 399]
    const doy: i64 = @divFloor(153 * m_adj + 2, 5) + day - 1; // day-of-year [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // day-of-era
    const days_since_epoch: i64 = era * 146097 + doe - 719468; // 719468 = days from 0000-03-01 to 1970-01-01

    const total_seconds: i64 = days_since_epoch * 86400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        second -
        tz_offset_min * 60;

    return total_seconds * 1_000_000 + sub_us;
}

fn parse4Digits(s: []const u8) error{InvalidTimestamp}!i64 {
    if (s.len < 4) return error.InvalidTimestamp;
    return (@as(i64, s[0] - '0') * 1000 +
        @as(i64, s[1] - '0') * 100 +
        @as(i64, s[2] - '0') * 10 +
        @as(i64, s[3] - '0'));
}

fn parse2Digits(s: []const u8) error{InvalidTimestamp}!i64 {
    if (s.len < 2) return error.InvalidTimestamp;
    return (@as(i64, s[0] - '0') * 10 + @as(i64, s[1] - '0'));
}
