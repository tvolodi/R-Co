//! Unit tests for EE-03 — GET /tasks handler (handleList).
//! Unit tests for EE-04 — POST /tasks/:id/complete handler (handleComplete).
//!
//! Pure input-validation tests exercise early-exit paths in handleList and
//! handleComplete that return before any TaskStore or InstanceStore method is
//! called — no database is needed.
//!
//! Tests that require a real database are stubbed with error.SkipZigTest and
//! are implemented in the integration test suite.
//!
//! Requirement traceability:
//!   EE-03 → TC-EE-03-06 (see tests/specs/EE-03.md)
//!   EE-04 → TC-EE-04-07, TC-EE-04-08 (see tests/specs/EE-04.md)
//!
//! Run with: zig build test  (pure paths run; DB stubs skipped)
//! Run live:  zig build test-integration  (requires BPM_TEST_DB_URL)

const std = @import("std");
const testing = std.testing;

// src/main.zig is wired as the named "bpm" module in build.zig.
// task_routes, task_store, and engine_instance are re-exported from main.zig
// so that types are deduplicated across the module tree.
const bpm = @import("bpm");
const task_routes = bpm.task_routes;
const task_store_mod = bpm.task_store;
const instance_mod = bpm.engine_instance;

// ---------------------------------------------------------------------------
// Pure input-validation tests (no database required)
// ---------------------------------------------------------------------------

// page_size = 0 → HTTP 422 INVALID_PAGE_SIZE.
// The handler rejects out-of-range page_size before touching the TaskStore.
test "TC-EE-03-API-01: handleList — page_size=0 returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = false, .is_platform_admin = false };
    const params = task_routes.ListTasksParams{ .assignee_id = null, .status = null, .instance_id = null, .cursor = null, .page_size = 0 };

    const result = task_routes.handleList(&dummy_store, alloc, actor, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_PAGE_SIZE") != null);
}

// page_size = 201 (above max) → HTTP 422 INVALID_PAGE_SIZE.
test "TC-EE-03-API-02: handleList — page_size=201 returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = false, .is_platform_admin = false };
    const params = task_routes.ListTasksParams{ .assignee_id = null, .status = null, .instance_id = null, .cursor = null, .page_size = 201 };

    const result = task_routes.handleList(&dummy_store, alloc, actor, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_PAGE_SIZE") != null);
}

// Cursor that is not valid base64url → HTTP 422 INVALID_CURSOR.
test "TC-EE-03-API-03: handleList — invalid base64url cursor returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = false, .is_platform_admin = false };
    // "!!!" is not valid base64url.
    const params = task_routes.ListTasksParams{ .assignee_id = null, .status = null, .instance_id = null, .cursor = "!!!", .page_size = 50 };

    const result = task_routes.handleList(&dummy_store, alloc, actor, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_CURSOR") != null);
}

// Cursor that decodes to valid base64url but lacks the "T:" prefix → HTTP 422 INVALID_CURSOR.
// base64url_no_pad("X:test") = "WDp0ZXN0".
test "TC-EE-03-API-04: handleList — cursor with wrong prefix returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = false, .is_platform_admin = false };
    // Encode "X:test" at comptime — a valid base64url cursor but wrong endpoint prefix.
    const plain = "X:test";
    const encoder = std.base64.url_safe_no_pad.Encoder;
    var enc_buf: [8]u8 = undefined;
    _ = encoder.encode(enc_buf[0..encoder.calcSize(plain.len)], plain);
    const params = task_routes.ListTasksParams{ .assignee_id = null, .status = null, .instance_id = null, .cursor = enc_buf[0..encoder.calcSize(plain.len)], .page_size = 50 };

    const result = task_routes.handleList(&dummy_store, alloc, actor, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_CURSOR") != null);
}

// Known-valid status value PENDING is accepted (no 422/400 from param parsing).
// DB-touching — requires real PostgreSQL → stub per T-1.
test "TC-EE-03-API-05: handleList — PENDING status value is accepted as valid" {
    return error.SkipZigTest;
}

// Known-valid status value COMPLETED is accepted.
// DB-touching — requires real PostgreSQL → stub per T-1.
test "TC-EE-03-API-06: handleList — COMPLETED status value is accepted as valid" {
    return error.SkipZigTest;
}

// Known-valid status value CANCELLED is accepted.
// DB-touching — requires real PostgreSQL → stub per T-1.
test "TC-EE-03-API-07: handleList — CANCELLED status value is accepted as valid" {
    return error.SkipZigTest;
}

// Empty query string is accepted (no filters → no parameter errors).
// DB-touching — requires real PostgreSQL → stub per T-1.
test "TC-EE-03-API-08: handleList — empty query string causes no parameter errors" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// Integration stubs (require real PostgreSQL — TC-EE-03-06)
// ---------------------------------------------------------------------------

// TC-EE-03-06: GET /tasks returns empty tasks array immediately after
// instance start if no HUMAN_TASK has yet been activated.
// Implemented in the integration test suite.
test "TC-EE-03-06: handleList — empty tasks array when no tasks exist" {
    return error.SkipZigTest;
}

// TC-EE-03-06b: GET /tasks with instance_id filter returns only tasks for
// that instance.  Implemented in the integration test suite.
test "TC-EE-03-API-09: handleList — filters results by instance_id" {
    return error.SkipZigTest;
}

// TC-EE-03-06c: GET /tasks with status=PENDING returns only PENDING tasks.
// Implemented in the integration test suite.
test "TC-EE-03-API-10: handleList — filters results by status" {
    return error.SkipZigTest;
}

// TC-EE-03-06d: GET /tasks with limit=2&offset=2 returns the correct page.
// Implemented in the integration test suite.
test "TC-EE-03-API-11: handleList — pagination via limit and offset" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// EE-04 pure input-validation tests for handleComplete (no database required)
// ---------------------------------------------------------------------------

// TC-EE-04-08: Malformed task_id (not a UUID) → HTTP 422 INVALID_INPUT.
// The handler rejects the path parameter before any TaskStore access.
// Preconditions: none (no DB state required).
// Traceability: EE-04 edge case — malformed path parameter.
test "TC-EE-04-08: handleComplete — malformed task_id returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    var dummy_instance_store: instance_mod.InstanceStore = undefined;
    var dummy_identity_registry: bpm.identity_registry.Registry = undefined;
    var dummy_identity_service = bpm.identity_service.Service.init(&dummy_identity_registry);

    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = false, .is_platform_admin = false };
    const result = task_routes.handleComplete(
        &dummy_store,
        &dummy_instance_store,
        &dummy_identity_service,
        alloc,
        actor,
        "not-a-uuid",
        "{\"output_variables\":{}}",
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_TASK_ID") != null);
}

// TC-EE-04-07: output_variables = null → HTTP 422 INVALID_INPUT.
// Requires DB (task fetch happens before body parsing in API-04 design) — skip in unit suite.
test "TC-EE-04-07: handleComplete — null output_variables returns HTTP 422" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// API-04 pure input-validation tests for handleGetById (no database required)
// ---------------------------------------------------------------------------

// TC-API-04-23: Malformed task_id (not UUID) → HTTP 422 INVALID_TASK_ID.
// The handler rejects the path parameter before any TaskStore access.
// Preconditions: none (no DB state required).
// Traceability: API-04 — GET /tasks/:id edge case.
test "TC-API-04-23: handleGetById — malformed task_id returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const result = task_routes.handleGetById(&dummy_store, alloc, "not-a-uuid");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_TASK_ID") != null);
}

// ---------------------------------------------------------------------------
// API-04 pure input-validation tests for handleAssign (no database required)
// ---------------------------------------------------------------------------

// TC-API-04-43: TASK_WORKER caller → HTTP 403 FORBIDDEN.
// The role check fires before any store access or body parsing.
// Preconditions: none (no DB state required).
// Traceability: API-04 — POST /tasks/:id/assign authorisation.
test "TC-API-04-43: handleAssign — TASK_WORKER caller returns HTTP 403" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    // is_operator_or_above = false → role check rejects before store access.
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = false, .is_platform_admin = false };
    const result = task_routes.handleAssign(&dummy_store, alloc, actor, "not-a-uuid", "{}");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "FORBIDDEN") != null);
}

// TC-API-04-45: user_id missing from body → HTTP 422 INVALID_INPUT.
// Role check passes, task_id is a valid UUID, body has no user_id field.
// user_id extraction returns null before store.getById is called.
// Preconditions: none (no DB state required).
// Traceability: API-04 — POST /tasks/:id/assign body validation.
test "TC-API-04-45: handleAssign — user_id missing from body returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = true, .is_platform_admin = false };
    // Body has no user_id → extractUserIdFromBody returns null → 422 before getById.
    const result = task_routes.handleAssign(
        &dummy_store,
        alloc,
        actor,
        "00000000-0000-0000-0000-000000000001",
        "{}",
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_INPUT") != null);
}

// TC-API-04-46: user_id empty string → HTTP 422 INVALID_INPUT.
// Role check passes, task_id is a valid UUID, body has user_id="" (empty).
// extractUserIdFromBody returns null before store.getById is called.
// Preconditions: none (no DB state required).
// Traceability: API-04 — POST /tasks/:id/assign body validation.
test "TC-API-04-46: handleAssign — user_id empty string returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = true, .is_platform_admin = false };
    // Body has user_id="" → extractUserIdFromBody returns null → 422 before getById.
    const result = task_routes.handleAssign(
        &dummy_store,
        alloc,
        actor,
        "00000000-0000-0000-0000-000000000001",
        "{\"user_id\":\"\"}",
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_INPUT") != null);
}

// ---------------------------------------------------------------------------
// API-04 pure input-validation tests for handleReassign (no database required)
// ---------------------------------------------------------------------------

// TC-API-04-53: TASK_WORKER caller → HTTP 403 FORBIDDEN.
// The role check fires before any store access or body parsing.
// Preconditions: none (no DB state required).
// Traceability: API-04 — POST /tasks/:id/reassign authorisation.
test "TC-API-04-53: handleReassign — TASK_WORKER caller returns HTTP 403" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    // is_operator_or_above = false → role check rejects before store access.
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = false, .is_platform_admin = false };
    const result = task_routes.handleReassign(&dummy_store, alloc, actor, "not-a-uuid", "{}");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 403), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "FORBIDDEN") != null);
}

// TC-API-04-55: user_id missing from body → HTTP 422 INVALID_INPUT.
// Role check passes, task_id is a valid UUID, body has no user_id field.
// user_id extraction returns null before store.reassign is called.
// Preconditions: none (no DB state required).
// Traceability: API-04 — POST /tasks/:id/reassign body validation.
test "TC-API-04-55: handleReassign — user_id missing from body returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = true, .is_platform_admin = false };
    // Body has no user_id → extractUserIdFromBody returns null → 422 before reassign.
    const result = task_routes.handleReassign(
        &dummy_store,
        alloc,
        actor,
        "00000000-0000-0000-0000-000000000001",
        "{}",
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_INPUT") != null);
}

// TC-API-04-56: user_id empty string → HTTP 422 INVALID_INPUT.
// Role check passes, task_id is a valid UUID, body has user_id="" (empty).
// extractUserIdFromBody returns null before store.reassign is called.
// Preconditions: none (no DB state required).
// Traceability: API-04 — POST /tasks/:id/reassign body validation.
test "TC-API-04-56: handleReassign — user_id empty string returns HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: task_store_mod.TaskStore = undefined;
    const actor = task_routes.Actor{ .user_id = "u1", .is_operator_or_above = true, .is_platform_admin = false };
    // Body has user_id="" → extractUserIdFromBody returns null → 422 before reassign.
    const result = task_routes.handleReassign(
        &dummy_store,
        alloc,
        actor,
        "00000000-0000-0000-0000-000000000001",
        "{\"user_id\":\"\"}",
    );
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "INVALID_INPUT") != null);
}

// ---------------------------------------------------------------------------
// Skipped unit tests (architectural gaps or covered by existing tests)
// ---------------------------------------------------------------------------

// TC-API-04-06: Cursor from /instances endpoint → HTTP 422 INVALID_CURSOR.
// SKIP: The "I:" prefix is rejected by the same code path exercised in
// TC-EE-03-API-04 (wrong-prefix cursor with "X:"). The handler rejects any
// prefix that is not "T:"; the specific "I:" value adds no additional
// coverage. LOW priority per handoff ap040004a; explicit cross-endpoint
// coverage is addressed in integration tests.
test "TC-API-04-06: handleList — cursor from instances endpoint returns HTTP 422" {
    return error.SkipZigTest;
}

// TC-API-04-08: Invalid status value → HTTP 422 INVALID_STATUS.
// SKIP: `ListTasksParams.status` is a typed `?TaskStatus` enum — the
// string-to-enum conversion occurs in the HTTP parameter-parsing layer
// (router) before handleList is invoked. No unit-testable parsing function
// exists in the current architecture. Covered by integration tests.
test "TC-API-04-08: handleList — invalid status value returns HTTP 422" {
    return error.SkipZigTest;
}

// TC-API-04-14: Invalid instance_id UUID format → HTTP 422 INVALID_INSTANCE_ID.
// SKIP: `ListTasksParams.instance_id` is a typed `?Uuid` — UUID parsing
// occurs in the HTTP parameter-parsing layer before handleList is invoked.
// No unit-testable parsing function exists in the current architecture.
// Covered by integration tests.
test "TC-API-04-14: handleList — invalid instance_id UUID format returns HTTP 422" {
    return error.SkipZigTest;
}
