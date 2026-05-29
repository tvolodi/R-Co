//! HTTP route handlers for PD-07 definition retrieval endpoints.
//!
//! All three handlers require a valid authenticated session (API-08).
//! Auth is enforced by upstream middleware — handlers may assume the caller
//! has already validated the session before invoking these functions.
//!
//! Route registration (wire in router.zig / main.zig once HTTP layer is ready — Stage 4):
//!   GET  /api/v1/definitions/:id               → handleGetById
//!   GET  /api/v1/definitions                   → handleList
//!   GET  /api/v1/definitions/active/:name      → handleGetActiveByName
//!   POST /api/v1/definitions/:id/deprecate     → handleDeprecate
//!   POST /api/v1/definitions/:id/archive       → handleArchive

const std = @import("std");
const definition_store = @import("../../definition/store.zig");
const export_import = @import("../../definition/export_import.zig");
const graph_mod = @import("../../definition/graph.zig");
const pagination = @import("../pagination.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Query parameters accepted by GET /api/v1/definitions.
pub const ListQueryParams = struct {
    /// Exact name filter; null = all names.
    name: ?[]const u8,
    /// Raw status string — validated before calling Store; null = all statuses.
    status: ?[]const u8,
    /// Free-text stage label filter (PD-07); null = all stages.
    stage: ?[]const u8,
    /// Opaque base64url-encoded pagination cursor (API-06).
    cursor: ?[]const u8,
    /// Page size 1–200; null or 0 → default 50.
    page_size: ?u16,
};

/// Result returned by each handler: an HTTP status code and a JSON body
/// string. The body slice is allocated with the caller-supplied allocator.
pub const HandlerResult = struct {
    status_code: u16,
    /// JSON-encoded response body; owned by the caller allocator.
    body: []const u8,
};

/// Query parameters accepted by GET /api/v1/definitions/search (PD-10).
pub const SearchQueryParams = struct {
    /// The search query string; null if `q=` is absent from the URL.
    q: ?[]const u8,
    /// Page size limit; null or 0 → default 20.
    limit: ?u32,
    /// Page offset; null → default 0.
    offset: ?u32,
};

// ---------------------------------------------------------------------------
// Public handler functions
// ---------------------------------------------------------------------------

/// GET /api/v1/definitions/:id
///
/// Success:  HTTP 200 + JSON definition body.
/// Not found: HTTP 404 + JSON error body.
/// Invalid id: HTTP 422 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleGetById(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid id format");
    };

    const def = store.getById(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// GET /api/v1/definitions
///
/// Query params: ?name=, ?status=, ?stage=, ?cursor=, ?page_size=
/// Success: HTTP 200 + JSON { "items": [...], "cursor": string | null }
/// Invalid params: HTTP 422 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleList(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    params: ListQueryParams,
) HandlerResult {
    // Validate ?status= — must be one of the four known DefinitionStatus values.
    const status_filter: ?definition_store.DefinitionStatus = blk: {
        const raw = params.status orelse break :blk null;
        if (std.mem.eql(u8, raw, "DRAFT")) break :blk .DRAFT;
        if (std.mem.eql(u8, raw, "ACTIVE")) break :blk .ACTIVE;
        if (std.mem.eql(u8, raw, "DEPRECATED")) break :blk .DEPRECATED;
        if (std.mem.eql(u8, raw, "ARCHIVED")) break :blk .ARCHIVED;
        return errorResult(allocator, 422, "invalid status value; must be one of DRAFT, ACTIVE, DEPRECATED, ARCHIVED");
    };

    // Validate ?page_size=.
    const effective_page_size_u16 = pagination.validatePageSize(params.page_size) catch |err| switch (err) {
        error.PageSizeTooLarge => return errorResult(allocator, 422, "page_size must be between 1 and 200"),
    };
    const effective_page_size: u8 = @intCast(effective_page_size_u16);

    // Decode ?cursor= (base64url → "D:{created_at_us}:{cursor_created_at_us}")
    // expiry_ts_offset = 2 (byte index of the cursor creation timestamp after "D:" prefix).
    const after_created: ?i64 = blk: {
        const cursor_str = params.cursor orelse break :blk null;
        const cursor = pagination.decodeCursor(allocator, cursor_str, "D:", 2, pagination.CURSOR_EXPIRY_US) catch |err| switch (err) {
            error.InvalidBase64 => return errorResult(allocator, 422, "invalid cursor"),
            error.WrongEndpoint => return errorResult(allocator, 422, "invalid cursor"),
            error.Expired => return errorResult(allocator, 410, "cursor expired"),
            error.OutOfMemory => return errorResult(allocator, 500, "internal server error"),
        };
        defer cursor.deinit();

        // Format: "D:{cursor_created_at_us}:{created_at_us}"
        // Extract created_at_us (the second segment) for store pagination.
        const after_prefix = cursor.inner[2..]; // skip "D:"
        const colon = std.mem.indexOfScalar(u8, after_prefix, ':') orelse
            return errorResult(allocator, 422, "invalid cursor");
        const created_at_str = after_prefix[colon + 1 ..];
        const ts = std.fmt.parseInt(i64, created_at_str, 10) catch
            return errorResult(allocator, 422, "invalid cursor");
        break :blk ts;
    };

    const opts = definition_store.ListOpts{
        .name = params.name,
        .status = status_filter,
        .stage = params.stage,
        .after_created = after_created,
        .limit = effective_page_size,
    };

    const defs = store.list(allocator, opts) catch |err| switch (err) {
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer {
        for (defs) |d| freeDefinition(allocator, d);
        allocator.free(defs);
    }

    // Encode next-page cursor when the full page was returned.
    // Format: base64url("D:{now_us}:{created_at_us}") with "D:" prefix and 24h expiry.
    const next_cursor: ?[]const u8 = if (defs.len == @as(usize, effective_page_size)) blk: {
        const last = defs[defs.len - 1];
        const now_us = currentMicrosecondTimestamp();
        const created_at_str = std.fmt.allocPrint(allocator, "{d}", .{last.created_at}) catch break :blk null;
        defer allocator.free(created_at_str);
        const raw = pagination.buildRawCursor(allocator, "D:", now_us, created_at_str) catch break :blk null;
        defer allocator.free(raw);
        break :blk pagination.encodeCursor(allocator, raw) catch null;
    } else null;
    defer if (next_cursor) |c| allocator.free(c);

    const body = serializeListResponse(allocator, defs, next_cursor) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// GET /api/v1/definitions/active/:name
///
/// Success:  HTTP 200 + JSON definition body (status = ACTIVE).
/// Not found: HTTP 404 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleGetActiveByName(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    name: []const u8,
) HandlerResult {
    const def = store.getActiveByName(allocator, name) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// GET /api/v1/definitions/search?q={query}&limit={n}&offset={n}
///
/// NOTE: register this route BEFORE /api/v1/definitions/:id in the router so
/// "search" is not consumed as a :id path parameter.
///
/// Success (any result count including zero): HTTP 200 + JSON array.
/// Empty query: HTTP 422 + {"error": "query_empty"}.
/// Query too long: HTTP 422 + {"error": "query_too_long"}.
/// Limit out of range: HTTP 422 + {"error": "limit_out_of_range"}.
/// Pool exhausted: HTTP 503 + {"error": "service_unavailable"}.
/// Server error: HTTP 500 + {"error": "internal_error"}.
pub fn handleSearch(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    params: SearchQueryParams,
) HandlerResult {
    // Step 1: q absent or empty → 422.
    const q = params.q orelse return errorResult(allocator, 422, "query_empty");
    if (q.len == 0) return errorResult(allocator, 422, "query_empty");

    // Step 2: q too long → 422.
    if (q.len > 512) return errorResult(allocator, 422, "query_too_long");

    // Step 3: limit validation (default 20, max 100).
    const effective_limit: u32 = blk: {
        const lim = params.limit orelse break :blk 20;
        if (lim == 0) break :blk 20;
        if (lim > 100) return errorResult(allocator, 422, "limit_out_of_range");
        break :blk lim;
    };

    // Step 4: offset (default 0).
    const effective_offset: u32 = params.offset orelse 0;

    // Step 5: Build SearchOptions.
    const opts = definition_store.SearchOptions{
        .query = q,
        .limit = effective_limit,
        .offset = effective_offset,
    };

    // Step 6: Call Store.search().
    const results = store.search(allocator, opts) catch |err| switch (err) {
        error.QueryEmpty => return errorResult(allocator, 422, "query_empty"),
        error.QueryTooLong => return errorResult(allocator, 422, "query_too_long"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer {
        for (results) |sr| freeDefinition(allocator, sr.definition);
        allocator.free(results);
    }

    // Step 9: Serialize to JSON array (HTTP 200 even when empty).
    const body = serializeSearchResults(allocator, results) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// New request body types (API-02)
// ---------------------------------------------------------------------------

/// Body for POST /api/v1/definitions  (PD-01 create).
pub const CreateDefinitionBody = struct {
    /// Non-empty, ≤ 255 characters (PD-01).
    name: []const u8,
    /// Non-empty string (PD-01).
    version: []const u8,
    /// Optional human-readable description.
    description: ?[]const u8,
    /// The definition graph; optional at creation time — defaults to empty {nodes:[], edges:[]} when null.
    graph: ?definition_store.DefinitionGraph,
    /// Optional process stage label (PD-07).
    stage: ?[]const u8 = null,
};

/// Body for PUT /api/v1/definitions/:id  (full replacement, DRAFT only).
pub const PutDefinitionBody = struct {
    name: []const u8,
    version: []const u8,
    description: ?[]const u8,
    graph: definition_store.DefinitionGraph,
    stage: ?[]const u8,
};

/// Body for PATCH /api/v1/definitions/:id  (partial update, DRAFT only).
/// Any field omitted (null) is left unchanged in the stored record.
pub const PatchDefinitionBody = struct {
    name: ?[]const u8,
    version: ?[]const u8,
    description: ?[]const u8,
    graph: ?definition_store.DefinitionGraph,
    stage: ?[]const u8,
};

// ---------------------------------------------------------------------------
// New write handlers (API-02)
// ---------------------------------------------------------------------------

/// POST /api/v1/definitions
///
/// Creates a new process definition with status DRAFT (PD-01).
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN (enforced upstream).
///
/// Success:            HTTP 201 + JSON Definition body.
/// Name+ver conflict:  HTTP 409.
/// Validation failure: HTTP 422 + violations array.
/// Pool exhausted:     HTTP 503.
/// Server error:       HTTP 500.
pub fn handleCreate(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    body: CreateDefinitionBody,
    actor_id: definition_store.Uuid,
) HandlerResult {
    const effective_graph = body.graph orelse definition_store.DefinitionGraph{
        .nodes = &.{},
        .edges = &.{},
    };

    const params = definition_store.CreateParams{
        .name = body.name,
        .version = body.version,
        .description = body.description,
        .graph = effective_graph,
        .created_by = actor_id,
        .stage = body.stage,
    };

    const def = store.create(allocator, params) catch |err| switch (err) {
        error.NameInvalid => return errorResult(allocator, 422, "name_invalid"),
        error.VersionEmpty => return errorResult(allocator, 422, "version_empty"),
        error.GraphStructureInvalid => return errorResult(allocator, 422, "graph_structure_invalid"),
        error.GraphValidationFailed => {
            const violations = store.lastViolations();
            const body_str = serializeViolations(allocator, violations, 422) catch
                return errorResult(allocator, 500, "serialization failed");
            return .{ .status_code = 422, .body = body_str };
        },
        error.DuplicateNameVersion => return errorResult(allocator, 409, "duplicate_name_version"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeDefinition(allocator, def);

    const resp_body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 201, .body = resp_body };
}

/// PUT /api/v1/definitions/:id
///
/// Full replacement of a DRAFT definition (PD-03).
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN (enforced upstream).
///
/// Success:            HTTP 200 + JSON Definition body.
/// Not found:          HTTP 404.
/// Status ≠ DRAFT:     HTTP 409 + current_status field.
/// Validation failure: HTTP 422 + violations array.
/// Pool exhausted:     HTTP 503.
/// Server error:       HTTP 500.
pub fn handlePut(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
    body: PutDefinitionBody,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid_id_format");
    };

    const params = definition_store.UpdateParams{
        .name = body.name,
        .version = body.version,
        .description = body.description,
        .graph = body.graph,
        .stage = body.stage,
    };

    const def = store.update(allocator, id, params) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
        error.NotDraft => {
            // We cannot retrieve the current status from the error value alone
            // (the Store consumed it).  Emit a static 409 response with a
            // known_status placeholder; the integration layer can populate it.
            const resp = std.fmt.allocPrint(
                allocator,
                "{{\"error\":\"not_draft\",\"current_status\":\"unknown\"}}",
                .{},
            ) catch "{\"error\":\"not_draft\"}";
            return .{ .status_code = 409, .body = resp };
        },
        error.NameInvalid => return errorResult(allocator, 422, "name_invalid"),
        error.VersionEmpty => return errorResult(allocator, 422, "version_empty"),
        error.GraphValidationFailed => {
            const violations = store.lastViolations();
            const body_str = serializeViolations(allocator, violations, 422) catch
                return errorResult(allocator, 500, "serialization failed");
            return .{ .status_code = 422, .body = body_str };
        },
        error.DuplicateNameVersion => return errorResult(allocator, 409, "duplicate_name_version"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeDefinition(allocator, def);

    const resp_body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = resp_body };
}

/// PATCH /api/v1/definitions/:id
///
/// Partial update of a DRAFT definition.  Only supplied (non-null) fields are
/// updated (PD-03).
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN (enforced upstream).
///
/// Success:            HTTP 200 + JSON Definition body.
/// Not found:          HTTP 404.
/// Status ≠ DRAFT:     HTTP 409.
/// Validation failure: HTTP 422 + violations array (only if graph supplied).
/// Pool exhausted:     HTTP 503.
/// Server error:       HTTP 500.
pub fn handlePatch(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
    body: PatchDefinitionBody,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid_id_format");
    };

    const params = definition_store.UpdateParams{
        .name = body.name,
        .version = body.version,
        .description = body.description,
        .graph = body.graph,
        .stage = body.stage,
    };

    const def = store.update(allocator, id, params) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
        error.NotDraft => {
            const resp = std.fmt.allocPrint(
                allocator,
                "{{\"error\":\"not_draft\",\"current_status\":\"unknown\"}}",
                .{},
            ) catch "{\"error\":\"not_draft\"}";
            return .{ .status_code = 409, .body = resp };
        },
        error.NameInvalid => return errorResult(allocator, 422, "name_invalid"),
        error.VersionEmpty => return errorResult(allocator, 422, "version_empty"),
        error.GraphValidationFailed => {
            const violations = store.lastViolations();
            const body_str = serializeViolations(allocator, violations, 422) catch
                return errorResult(allocator, 500, "serialization failed");
            return .{ .status_code = 422, .body = body_str };
        },
        error.DuplicateNameVersion => return errorResult(allocator, 409, "duplicate_name_version"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeDefinition(allocator, def);

    const resp_body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = resp_body };
}

/// DELETE /api/v1/definitions/:id
///
/// Status-dependent delete (PD-04):
///   DRAFT      → hard delete (HTTP 204, no body).
///   ACTIVE     → archive via deprecate+archive path (HTTP 200 + Definition).
///   DEPRECATED → archive (HTTP 200 + Definition).
///   ARCHIVED   → HTTP 409 already_archived.
///   Not found  → HTTP 404.
///
/// Authorisation: PLATFORM_ADMIN only (enforced upstream).
pub fn handleDelete(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid_id_format");
    };

    // Read current status to dispatch to the correct Store method.
    const current = store.getById(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    const current_status = current.status;
    freeDefinition(allocator, current);

    switch (current_status) {
        .DRAFT => {
            store.hardDelete(allocator, id) catch |err| switch (err) {
                error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
                error.NotDraft => return errorResult(allocator, 409, "not_draft"),
                error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
                else => return errorResult(allocator, 500, "internal_error"),
            };
            // HTTP 204: no body.
            const empty = allocator.dupe(u8, "") catch "";
            return .{ .status_code = 204, .body = empty };
        },
        .ACTIVE => {
            // OQ-1 resolution: DELETE on ACTIVE = deprecate then archive in two calls.
            // Both run in the same request; the second call receives DEPRECATED status.
            _ = store.deprecate(allocator, id) catch |err| switch (err) {
                error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
                error.InvalidStatusTransition => return errorResult(allocator, 409, "invalid_status_transition"),
                error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
                else => return errorResult(allocator, 500, "internal_error"),
            };
            const archived_def = store.archive(allocator, id) catch |err| switch (err) {
                error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
                error.InvalidStatusTransition => return errorResult(allocator, 409, "invalid_status_transition"),
                error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
                else => return errorResult(allocator, 500, "internal_error"),
            };
            defer freeDefinition(allocator, archived_def);
            const resp_body = serializeDefinition(allocator, archived_def) catch
                return errorResult(allocator, 500, "serialization failed");
            return .{ .status_code = 200, .body = resp_body };
        },
        .DEPRECATED => {
            const archived_def = store.archive(allocator, id) catch |err| switch (err) {
                error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
                error.InvalidStatusTransition => return errorResult(allocator, 409, "invalid_status_transition"),
                error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
                else => return errorResult(allocator, 500, "internal_error"),
            };
            defer freeDefinition(allocator, archived_def);
            const resp_body = serializeDefinition(allocator, archived_def) catch
                return errorResult(allocator, 500, "serialization failed");
            return .{ .status_code = 200, .body = resp_body };
        },
        .ARCHIVED => {
            const resp = std.fmt.allocPrint(
                allocator,
                "{{\"error\":\"already_archived\"}}",
                .{},
            ) catch "{\"error\":\"already_archived\"}";
            return .{ .status_code = 409, .body = resp };
        },
    }
}

/// POST /api/v1/definitions/:id/activate
///
/// Transitions DRAFT → ACTIVE (PD-03).
/// Idempotent: activating an already-ACTIVE definition returns HTTP 200.
/// Re-runs PD-02 graph validation on the current stored graph before
/// calling Store.activate() (per API-02 AC).
/// Authorisation: PROCESS_DESIGNER or PLATFORM_ADMIN (enforced upstream).
///
/// Success (DRAFT→ACTIVE or already ACTIVE): HTTP 200 + JSON Definition.
/// Not found:          HTTP 404.
/// Status ≠ DRAFT/ACTIVE: HTTP 409.
/// Graph re-validation failure: HTTP 422 + violations array.
/// Pool exhausted:     HTTP 503.
/// Server error:       HTTP 500.
pub fn handleActivate(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid_id_format");
    };

    // Fetch current definition to re-run graph validation (API-02 AC).
    const current = store.getById(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeDefinition(allocator, current);

    // Re-run graph validation on current stored graph before activating.
    // The graph stored in the Definition struct is the in-memory stub (empty
    // nodes/edges) because pg.zig does not yet parse JSONB rows.  When real DB
    // rows are delivered, this will validate the actual stored graph.
    const graph_to_validate = current.graph;
    store.clearLastViolations();

    const vresult = graph_mod.validateGraph(allocator, graph_to_validate) catch
        return errorResult(allocator, 500, "internal_error");
    if (!vresult.valid) {
        store.last_violations = vresult.violations;
        const body_str = serializeViolations(allocator, store.lastViolations(), 422) catch
            return errorResult(allocator, 500, "serialization failed");
        return .{ .status_code = 422, .body = body_str };
    }
    allocator.free(vresult.violations);

    const transform_result = graph_mod.validateEdgeTransforms(allocator, graph_to_validate) catch
        return errorResult(allocator, 500, "internal_error");
    if (!transform_result.valid) {
        store.last_violations = transform_result.violations;
        const body_str = serializeViolations(allocator, store.lastViolations(), 422) catch
            return errorResult(allocator, 500, "serialization failed");
        return .{ .status_code = 422, .body = body_str };
    }
    allocator.free(transform_result.violations);

    const def = store.activate(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not_found"),
        error.AlreadyActive => {
            // Idempotent: return the current definition (already fetched above, but
            // freed via defer; re-fetch to avoid use-after-free).
            const active_def = store.getById(allocator, id) catch
                return errorResult(allocator, 500, "internal_error");
            defer freeDefinition(allocator, active_def);
            const resp_body = serializeDefinition(allocator, active_def) catch
                return errorResult(allocator, 500, "serialization failed");
            return .{ .status_code = 200, .body = resp_body };
        },
        error.NotDraft => {
            const resp = std.fmt.allocPrint(
                allocator,
                "{{\"error\":\"not_draft\",\"current_status\":\"unknown\"}}",
                .{},
            ) catch "{\"error\":\"not_draft\"}";
            return .{ .status_code = 409, .body = resp };
        },
        error.GraphValidationFailed => {
            const body_str = serializeViolations(allocator, store.lastViolations(), 422) catch
                return errorResult(allocator, 500, "serialization failed");
            return .{ .status_code = 422, .body = body_str };
        },
        error.PoolExhausted => return errorResult(allocator, 503, "service_unavailable"),
        else => return errorResult(allocator, 500, "internal_error"),
    };
    defer freeDefinition(allocator, def);

    const resp_body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = resp_body };
}

/// POST /api/v1/definitions/:id/deprecate
///
/// Transitions an ACTIVE definition to DEPRECATED (PD-04).
/// Success:  HTTP 200 + JSON definition body.
/// Not found: HTTP 404 + JSON error body.
/// Invalid id: HTTP 422 + JSON error body.
/// Invalid transition: HTTP 409 + {"error":"invalid_status_transition","message":"Only ACTIVE definitions can be deprecated"}.
/// Pool exhausted: HTTP 503 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleDeprecate(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid id format");
    };

    const def = store.deprecate(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.InvalidStatusTransition => {
            const body = std.fmt.allocPrint(
                allocator,
                "{{\"error\":\"invalid_status_transition\",\"message\":\"Only ACTIVE definitions can be deprecated\"}}",
                .{},
            ) catch "{\"error\":\"invalid_status_transition\"}";
            return .{ .status_code = 409, .body = body };
        },
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// POST /api/v1/definitions/:id/archive
///
/// Transitions a DEPRECATED definition to ARCHIVED (PD-04).
/// Success:  HTTP 200 + JSON definition body.
/// Not found: HTTP 404 + JSON error body.
/// Invalid id: HTTP 422 + JSON error body.
/// Invalid transition: HTTP 409 + {"error":"invalid_status_transition","message":"Only DEPRECATED definitions can be archived"}.
/// Pool exhausted: HTTP 503 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleArchive(
    store: *definition_store.Store,
    allocator: std.mem.Allocator,
    id_str: []const u8,
) HandlerResult {
    const id = parseUuid(id_str) catch {
        return errorResult(allocator, 422, "invalid id format");
    };

    const def = store.archive(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.InvalidStatusTransition => {
            const body = std.fmt.allocPrint(
                allocator,
                "{{\"error\":\"invalid_status_transition\",\"message\":\"Only DEPRECATED definitions can be archived\"}}",
                .{},
            ) catch "{\"error\":\"invalid_status_transition\"}";
            return .{ .status_code = 409, .body = body };
        },
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

// ---------------------------------------------------------------------------
// Private helpers — UUID
// ---------------------------------------------------------------------------

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

fn uuidToHex(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
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

fn statusToStr(status: definition_store.DefinitionStatus) []const u8 {
    return switch (status) {
        .DRAFT => "DRAFT",
        .ACTIVE => "ACTIVE",
        .DEPRECATED => "DEPRECATED",
        .ARCHIVED => "ARCHIVED",
    };
}

// ---------------------------------------------------------------------------
// Private helpers — wall-clock time (permitted in handler layer)
// ---------------------------------------------------------------------------

/// Return the current wall-clock time as UTC microseconds since Unix epoch.
/// Used only for cursor creation timestamps (not in transition.zig).
fn currentMicrosecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        const sec_us: i64 = ts.sec * 1_000_000;
        const nsec_us: i64 = @divTrunc(ts.nsec, 1000);
        return sec_us + nsec_us;
    }
}

// ---------------------------------------------------------------------------
// Private helpers — JSON serialisation
// ---------------------------------------------------------------------------

/// Free all heap-allocated strings inside a Definition.
fn freeDefinition(allocator: std.mem.Allocator, def: definition_store.Definition) void {
    allocator.free(def.name);
    allocator.free(def.version);
    if (def.description) |d| allocator.free(d);
    if (def.stage) |s| allocator.free(s);
    definition_store.freeDefinitionGraph(allocator, def.graph);
}

/// Append a JSON-encoded string (double-quoted, with escaping) to buf.
fn appendJsonStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => {
                const esc = try std.fmt.allocPrint(allocator, "\\u{X:0>4}", .{c});
                defer allocator.free(esc);
                try buf.appendSlice(allocator, esc);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

/// Append a JSON serialisation of a DefinitionGraph ({"nodes":[...],"edges":[...]}) to buf.
fn appendJsonGraph(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), graph: definition_store.DefinitionGraph) !void {
    try buf.appendSlice(allocator, "{\"nodes\":[");
    for (graph.nodes, 0..) |node, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"id\":");
        try appendJsonStr(allocator, buf, node.id);
        try buf.appendSlice(allocator, ",\"node_type\":");
        try appendJsonStr(allocator, buf, @tagName(node.node_type));
        try buf.appendSlice(allocator, ",\"label\":");
        if (node.label) |l| try appendJsonStr(allocator, buf, l) else try buf.appendSlice(allocator, "null");
        try buf.appendSlice(allocator, ",\"attributes\":");
        if (node.attributes) |a| try appendJsonStr(allocator, buf, a) else try buf.appendSlice(allocator, "null");
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "],\"edges\":[");
    for (graph.edges, 0..) |edge, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"id\":");
        try appendJsonStr(allocator, buf, edge.id);
        try buf.appendSlice(allocator, ",\"source\":");
        try appendJsonStr(allocator, buf, edge.source);
        try buf.appendSlice(allocator, ",\"target\":");
        try appendJsonStr(allocator, buf, edge.target);
        try buf.appendSlice(allocator, ",\"condition\":");
        if (edge.condition) |c| try appendJsonStr(allocator, buf, c) else try buf.appendSlice(allocator, "null");
        try buf.appendSlice(allocator, ",\"is_default\":");
        try buf.appendSlice(allocator, if (edge.is_default) "true" else "false");
        try buf.appendSlice(allocator, ",\"transform\":");
        if (edge.transform) |t| try appendJsonStr(allocator, buf, t) else try buf.appendSlice(allocator, "null");
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
}

/// Serialise a single Definition to a JSON string. Caller owns the result.
fn serializeDefinition(allocator: std.mem.Allocator, def: definition_store.Definition) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const id_hex = try uuidToHex(allocator, def.id);
    defer allocator.free(id_hex);
    const created_by_hex = try uuidToHex(allocator, def.created_by);
    defer allocator.free(created_by_hex);

    try buf.appendSlice(allocator, "{\"id\":");
    try appendJsonStr(allocator, &buf, id_hex);
    try buf.appendSlice(allocator, ",\"name\":");
    try appendJsonStr(allocator, &buf, def.name);
    try buf.appendSlice(allocator, ",\"version\":");
    try appendJsonStr(allocator, &buf, def.version);
    try buf.appendSlice(allocator, ",\"description\":");
    if (def.description) |d| {
        try appendJsonStr(allocator, &buf, d);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"status\":");
    try appendJsonStr(allocator, &buf, statusToStr(def.status));
    try buf.appendSlice(allocator, ",\"graph\":");
    try appendJsonGraph(allocator, &buf, def.graph);
    try buf.appendSlice(allocator, ",\"created_by\":");
    try appendJsonStr(allocator, &buf, created_by_hex);
    {
        const ts = try std.fmt.allocPrint(
            allocator,
            ",\"created_at\":{d},\"updated_at\":{d}",
            .{ def.created_at, def.updated_at },
        );
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);
    }
    try buf.appendSlice(allocator, ",\"archived_at\":");
    if (def.archived_at) |a| {
        const ts = try std.fmt.allocPrint(allocator, "{d}", .{a});
        defer allocator.free(ts);
        try buf.appendSlice(allocator, ts);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"stage\":");
    if (def.stage) |s| {
        try appendJsonStr(allocator, &buf, s);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Serialise the paginated list response body. Caller owns the result.
fn serializeListResponse(
    allocator: std.mem.Allocator,
    defs: []const definition_store.Definition,
    cursor: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (defs, 0..) |def, i| {
        if (i > 0) try buf.append(allocator, ',');
        const item = try serializeDefinition(allocator, def);
        defer allocator.free(item);
        try buf.appendSlice(allocator, item);
    }
    try buf.appendSlice(allocator, "],\"cursor\":");
    if (cursor) |c| {
        try appendJsonStr(allocator, &buf, c);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Serialise a []Violation slice as a JSON 422 Problem Details body.
/// Shape: {"status":422,"errors":[{"code":"...","message":"..."},...]}
/// Caller owns the returned slice.
fn serializeViolations(
    allocator: std.mem.Allocator,
    violations: []const definition_store.Violation,
    status_code: u16,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const hdr = try std.fmt.allocPrint(allocator, "{{\"status\":{d},\"errors\":[", .{status_code});
    defer allocator.free(hdr);
    try buf.appendSlice(allocator, hdr);

    for (violations, 0..) |v, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"code\":");
        try appendJsonStr(allocator, &buf, v.code);
        try buf.appendSlice(allocator, ",\"message\":");
        try appendJsonStr(allocator, &buf, v.message);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

/// Build a static error response. Falls back to a literal string on allocation failure.
fn errorResult(allocator: std.mem.Allocator, code: u16, msg: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{msg}) catch
        "{\"error\":\"internal server error\"}";
    return .{ .status_code = code, .body = body };
}

/// Serialise a []SearchResult to a JSON object with an "items" array (PD-10).
/// Caller owns the result. Empty slice → {"items":[]}.
/// Format: {"items":[{"definition":{...},"rank":0.5},...]}
fn serializeSearchResults(
    allocator: std.mem.Allocator,
    results: []const definition_store.SearchResult,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"items\":[");
    for (results, 0..) |sr, i| {
        if (i > 0) try buf.append(allocator, ',');
        const def_json = try serializeDefinition(allocator, sr.definition);
        defer allocator.free(def_json);
        try buf.appendSlice(allocator, "{\"definition\":");
        try buf.appendSlice(allocator, def_json);
        const rank_str = try std.fmt.allocPrint(allocator, ",\"rank\":{}", .{sr.rank});
        defer allocator.free(rank_str);
        try buf.appendSlice(allocator, rank_str);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// PD-09: Export / import handlers
// ---------------------------------------------------------------------------

/// GET /api/v1/definitions/:id/export
///
/// Exports the definition as a self-contained JSON document.
/// Success: HTTP 200 + JSON ExportDocument.
/// Not found: HTTP 404 + JSON error body.
/// Invalid id: HTTP 422 + JSON error body.
/// Pool exhausted: HTTP 503 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleExport(
    allocator: std.mem.Allocator,
    store: *export_import.ExportImportStore,
    definition_id_str: []const u8,
) HandlerResult {
    const id = parseUuid(definition_id_str) catch {
        return errorResult(allocator, 422, "invalid id format");
    };

    const doc = store.exportDefinition(allocator, id) catch |err| switch (err) {
        error.DefinitionNotFound => return errorResult(allocator, 404, "not found"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer {
        allocator.free(doc.name);
        allocator.free(doc.version);
        allocator.free(doc.description);
        allocator.free(doc.exported_at);
        // graph is not freed here — consistent with existing store (pg.zig stub returns empty graph)
    }

    const body = serializeExportDocument(allocator, doc) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 200, .body = body };
}

/// POST /api/v1/definitions/import
///
/// Imports a definition from a previously exported JSON document.
/// Success: HTTP 201 + JSON Definition body (same format as PD-01 create response).
/// Unknown schema version: HTTP 422 + {"error": "unknown_schema_version"}.
/// Name+version conflict: HTTP 409 + {"error": "name_version_conflict"}.
/// Invalid graph (including CEL): HTTP 422 + {"error": "invalid_graph"}.
/// Pool exhausted: HTTP 503 + JSON error body.
/// Server error: HTTP 500 + JSON error body.
pub fn handleImport(
    allocator: std.mem.Allocator,
    store: *export_import.ExportImportStore,
    body: []const u8,
) HandlerResult {
    // Parse body as a generic JSON value for flexible field extraction.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return errorResult(allocator, 422, "invalid import document");
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return errorResult(allocator, 422, "invalid import document"),
    };

    const schema_ver = jsonObjStr(obj, "bpm_export_schema_version") orelse
        return errorResult(allocator, 422, "missing bpm_export_schema_version");
    const id_str = jsonObjStr(obj, "id") orelse "";
    const name = jsonObjStr(obj, "name") orelse
        return errorResult(allocator, 422, "missing name");
    const ver = jsonObjStr(obj, "version") orelse
        return errorResult(allocator, 422, "missing version");
    const description = jsonObjStr(obj, "description") orelse "";
    const exported_at = jsonObjStr(obj, "exported_at") orelse "";

    // Parse graph from "graph" key: stringify back to JSON then re-parse to DefinitionGraph.
    const graph: export_import.DefinitionGraph = blk: {
        const gv = obj.get("graph") orelse
            break :blk export_import.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
        const graph_json = std.json.Stringify.valueAlloc(allocator, gv, .{}) catch
            break :blk export_import.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
        defer allocator.free(graph_json);
        break :blk parseImportGraph(allocator, graph_json) catch
            export_import.DefinitionGraph{ .nodes = &.{}, .edges = &.{} };
    };

    // id is informational only; parseUuid failure falls back to zeroed Uuid.
    const id = parseUuid(id_str) catch std.mem.zeroes(export_import.Uuid);

    const doc = export_import.ExportDocument{
        .bpm_export_schema_version = schema_ver,
        .id = id,
        .name = name,
        .version = ver,
        .description = description,
        .graph = graph,
        .exported_at = exported_at,
    };

    const def = store.importDefinition(allocator, doc) catch |err| switch (err) {
        error.UnknownSchemaVersion => return errorResult(allocator, 422, "unknown_schema_version"),
        error.NameVersionConflict => return errorResult(allocator, 409, "name_version_conflict"),
        error.InvalidGraph => return errorResult(allocator, 422, "invalid_graph"),
        error.PoolExhausted => return errorResult(allocator, 503, "service unavailable"),
        else => return errorResult(allocator, 500, "internal server error"),
    };
    defer freeDefinition(allocator, def);

    const resp_body = serializeDefinition(allocator, def) catch
        return errorResult(allocator, 500, "serialization failed");
    return .{ .status_code = 201, .body = resp_body };
}

// ---------------------------------------------------------------------------
// Private helpers — PD-09
// ---------------------------------------------------------------------------

/// Serialise an ExportDocument to a JSON string. Caller owns the result.
fn serializeExportDocument(allocator: std.mem.Allocator, doc: export_import.ExportDocument) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const id_hex = try uuidToHex(allocator, doc.id);
    defer allocator.free(id_hex);

    try buf.appendSlice(allocator, "{\"bpm_export_schema_version\":");
    try appendJsonStr(allocator, &buf, doc.bpm_export_schema_version);
    try buf.appendSlice(allocator, ",\"id\":");
    try appendJsonStr(allocator, &buf, id_hex);
    try buf.appendSlice(allocator, ",\"name\":");
    try appendJsonStr(allocator, &buf, doc.name);
    try buf.appendSlice(allocator, ",\"version\":");
    try appendJsonStr(allocator, &buf, doc.version);
    try buf.appendSlice(allocator, ",\"description\":");
    try appendJsonStr(allocator, &buf, doc.description);
    try buf.appendSlice(allocator, ",\"graph\":");
    try appendJsonGraph(allocator, &buf, doc.graph);
    try buf.appendSlice(allocator, ",\"exported_at\":");
    try appendJsonStr(allocator, &buf, doc.exported_at);
    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Parse a DefinitionGraph from a JSON string slice (used for import body graph field).
fn parseImportGraph(
    allocator: std.mem.Allocator,
    json_str: []const u8,
) error{ OutOfMemory, InvalidGraph }!export_import.DefinitionGraph {
    if (json_str.len == 0) return error.InvalidGraph;
    const parsed = std.json.parseFromSlice(
        export_import.DefinitionGraph,
        allocator,
        json_str,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return error.InvalidGraph;
    defer parsed.deinit();
    return duplicateImportGraph(allocator, parsed.value);
}

fn duplicateImportGraph(
    allocator: std.mem.Allocator,
    src: export_import.DefinitionGraph,
) error{OutOfMemory}!export_import.DefinitionGraph {
    const nodes = try allocator.alloc(graph_mod.GraphNode, src.nodes.len);
    errdefer allocator.free(nodes);

    for (src.nodes, 0..) |n, i| {
        nodes[i] = .{
            .id = try allocator.dupe(u8, n.id),
            .node_type = n.node_type,
            .label = if (n.label) |l| try allocator.dupe(u8, l) else null,
            .attributes = if (n.attributes) |attr| try allocator.dupe(u8, attr) else null,
        };
    }

    const edges = try allocator.alloc(graph_mod.GraphEdge, src.edges.len);
    errdefer allocator.free(edges);

    for (src.edges, 0..) |e, i| {
        edges[i] = .{
            .id = try allocator.dupe(u8, e.id),
            .source = try allocator.dupe(u8, e.source),
            .target = try allocator.dupe(u8, e.target),
            .condition = if (e.condition) |c| try allocator.dupe(u8, c) else null,
            .transform = if (e.transform) |t| try allocator.dupe(u8, t) else null,
            .is_default = e.is_default,
        };
    }

    return export_import.DefinitionGraph{ .nodes = nodes, .edges = edges };
}

/// Extract a string value from a JSON object by key; returns null if absent or non-string.
fn jsonObjStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}
