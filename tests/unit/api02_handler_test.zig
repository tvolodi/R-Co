//! Unit tests for API-02 — Process Definition CRUD handler layer.
//!
//! These tests exercise the pure input-validation early-exit paths in each
//! API-02 handler function.  All paths that return before any Store method is
//! called can be tested without a database connection.  Store-touching paths
//! are exercised by integration tests in tests/integration/api02_crud_test.zig.
//!
//! Strategy: pass an `undefined` Store pointer to handlers whose failing branch
//! is reached before the first store field access.  This is safe only when the
//! handler is guaranteed to return on a validation error before accessing the
//! store — confirmed per reading of each handler's early-exit branch.
//!
//! Requirement traceability:
//!   API-02 → TC-API-02-04 (name_invalid), TC-API-02-06 (invalid status),
//!             TC-API-02-07 (page_size=0), TC-API-02-08 (invalid cursor),
//!             TC-API-02-11 (handleGetById invalid UUID),
//!             TC-API-02-16 (handlePut invalid UUID),
//!             TC-API-02-20 (handlePatch invalid UUID),
//!             TC-API-02-27 (handleDelete invalid UUID),
//!             TC-API-02-33 (handleActivate invalid UUID)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

// src/main.zig is wired as the named "bpm" module in build.zig.
// It publishes definition_routes and definition_store.
const bpm = @import("bpm");
const definitions = bpm.definition_routes;
const store_mod = bpm.definition_store;

// ---------------------------------------------------------------------------
// GET /definitions — invalid ?status= filter
// TC-API-02-06
// ---------------------------------------------------------------------------

test "TC-API-02-06: handleList — invalid status returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const params = definitions.ListQueryParams{
        .name = null,
        .status = "INVALID_STATUS",
        .stage = null,
        .cursor = null,
        .page_size = null,
    };

    const result = definitions.handleList(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// GET /definitions — page_size=0
// TC-API-02-07
// ---------------------------------------------------------------------------

test "TC-API-02-07: handleList — page_size=0 returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const params = definitions.ListQueryParams{
        .name = null,
        .status = null,
        .stage = null,
        .cursor = null,
        .page_size = 0,
    };

    const result = definitions.handleList(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// GET /definitions — page_size > 200
// ---------------------------------------------------------------------------

test "TC-API-02-07b: handleList — page_size=201 returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const params = definitions.ListQueryParams{
        .name = null,
        .status = null,
        .stage = null,
        .cursor = null,
        .page_size = 201,
    };

    const result = definitions.handleList(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// GET /definitions — invalid cursor (non-base64url characters)
// TC-API-02-08
// ---------------------------------------------------------------------------

test "TC-API-02-08: handleList — invalid base64url cursor returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const params = definitions.ListQueryParams{
        .name = null,
        .status = null,
        .stage = null,
        .cursor = "not-base64!!chars",
        .page_size = null,
    };

    const result = definitions.handleList(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "invalid cursor") != null);
}

// ---------------------------------------------------------------------------
// GET /definitions/:id — malformed UUID
// TC-API-02-11
// ---------------------------------------------------------------------------

test "TC-API-02-11: handleGetById — malformed UUID returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const result = definitions.handleGetById(&dummy_store, alloc, "not-a-valid-uuid");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// GET /definitions/:id — UUID too short
// ---------------------------------------------------------------------------

test "TC-API-02-11b: handleGetById — UUID string too short returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const result = definitions.handleGetById(&dummy_store, alloc, "00000000-0000-0000-0000");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
}

// ---------------------------------------------------------------------------
// PUT /definitions/:id — malformed UUID path parameter
// TC-API-02-16
// ---------------------------------------------------------------------------

test "TC-API-02-16: handlePut — malformed UUID returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    // The handler calls parseUuid before accessing the store.
    const body = definitions.PutDefinitionBody{
        .name = "test-proc",
        .version = "1.0",
        .description = null,
        .graph = store_mod.DefinitionGraph{ .nodes = &.{}, .edges = &.{} },
        .stage = null,
    };

    const result = definitions.handlePut(&dummy_store, alloc, "not-a-uuid", body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "invalid_id_format") != null);
}

// ---------------------------------------------------------------------------
// PATCH /definitions/:id — malformed UUID path parameter
// TC-API-02-20
// ---------------------------------------------------------------------------

test "TC-API-02-20: handlePatch — malformed UUID returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const body = definitions.PatchDefinitionBody{
        .name = null,
        .version = null,
        .description = "updated description",
        .graph = null,
        .stage = null,
    };

    const result = definitions.handlePatch(&dummy_store, alloc, "bad-uuid-string", body);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "invalid_id_format") != null);
}

// ---------------------------------------------------------------------------
// DELETE /definitions/:id — malformed UUID path parameter
// TC-API-02-27
// ---------------------------------------------------------------------------

test "TC-API-02-27: handleDelete — malformed UUID returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const result = definitions.handleDelete(&dummy_store, alloc, "not-a-uuid-at-all");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "invalid_id_format") != null);
}

// ---------------------------------------------------------------------------
// POST /definitions/:id/activate — malformed UUID path parameter
// TC-API-02-33
// ---------------------------------------------------------------------------

test "TC-API-02-33: handleActivate — malformed UUID returns HTTP 422" {
    const alloc = testing.allocator;
    var dummy_store: store_mod.Store = undefined;

    const result = definitions.handleActivate(&dummy_store, alloc, "garbage-uuid");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "invalid_id_format") != null);
}
