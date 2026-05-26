//! Unit tests for PD-10 — Definition search input validation.
//!
//! These tests exercise early-exit paths in handleSearch that return before
//! any Store method (and therefore any database connection) is called.
//! No database connection is required; dummy_store is left undefined and is
//! never accessed by the tested paths.
//!
//! Requirement traceability:
//!   PD-10 → TC-PD-10-05, TC-PD-10-06, TC-PD-10-11
//!   (see tests/specs/PD-10.md for full Given/When/Then specs)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

// src/main.zig is wired as the named "bpm" module in build.zig (module root
// = src/).  definition_routes and definition_store are re-exported from main.zig
// so that Store and SearchQueryParams share the same type identity as the
// types used inside handleSearch.
const bpm = @import("bpm");
const definitions = bpm.definition_routes;
const store_mod = bpm.definition_store;

// ---------------------------------------------------------------------------
// TC-PD-10-05: empty query string → HTTP 422 query_empty
// ---------------------------------------------------------------------------

// handleSearch checks `q.len == 0` before touching the store.
// dummy_store is intentionally undefined: the handler returns before any
// field of Store is dereferenced.
test "TC-PD-10-05: handleSearch — empty q string returns HTTP 422 query_empty" {
    const alloc = testing.allocator;

    var dummy_store: store_mod.Store = undefined;

    const params = definitions.SearchQueryParams{
        .q = "",
        .limit = null,
        .offset = null,
    };

    const result = definitions.handleSearch(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "query_empty") != null);
}

// ---------------------------------------------------------------------------
// TC-PD-10-06: query > 512 characters → HTTP 422 query_too_long
// ---------------------------------------------------------------------------

test "TC-PD-10-06: handleSearch — query longer than 512 chars returns HTTP 422 query_too_long" {
    const alloc = testing.allocator;

    var dummy_store: store_mod.Store = undefined;

    // Build a 513-character query string (comptime repetition).
    const long_query_buf: [513]u8 = blk: {
        var buf: [513]u8 = undefined;
        @memset(&buf, 'a');
        break :blk buf;
    };
    const long_query: []const u8 = &long_query_buf;

    const params = definitions.SearchQueryParams{
        .q = long_query,
        .limit = null,
        .offset = null,
    };

    const result = definitions.handleSearch(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "query_too_long") != null);
}

// ---------------------------------------------------------------------------
// TC-PD-10-11: absent q parameter (q = null) → HTTP 422 query_empty
// ---------------------------------------------------------------------------

// handleSearch checks `params.q orelse return errorResult(...)` as its first
// step, so a null q is rejected before any store access.
test "TC-PD-10-11: handleSearch — null q (absent URL parameter) returns HTTP 422 query_empty" {
    const alloc = testing.allocator;

    var dummy_store: store_mod.Store = undefined;

    const params = definitions.SearchQueryParams{
        .q = null,
        .limit = null,
        .offset = null,
    };

    const result = definitions.handleSearch(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "query_empty") != null);
}
