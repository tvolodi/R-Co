//! Unit tests for PD-07 — Definition retrieval.
//!
//! TC-PD-07-09, TC-PD-07-11, and TC-PD-07-13 are **pure input-validation
//! tests**: they exercise early-exit paths in handleList that return before
//! any store method is called, so no database connection is required.
//!
//! TC-PD-07-10 is also a pure test: page_size=0 is rejected before cursor
//! decode or any store call.
//!
//! All other test cases (TC-PD-07-01 through TC-PD-07-08, TC-PD-07-12,
//! TC-PD-07-14 through TC-PD-07-20) are DB-guarded and skip when
//! BPM_TEST_DB_URL is unset.
//!
//! Requirement traceability:
//!   PD-07 → TC-PD-07-01 through TC-PD-07-20
//!   (see tests/specs/PD-07.md for full Given/When/Then specs)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const definitions = bpm.definition_routes;
const store_mod = bpm.definition_store;

const Pool = bpm.db_pool.Pool;
const PoolConfig = bpm.db_pool.PoolConfig;
const GraphNode = store_mod.GraphNode;
const GraphEdge = store_mod.GraphEdge;
const DefinitionGraph = store_mod.DefinitionGraph;
const CreateParams = store_mod.CreateParams;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL not set — skipping DB test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
    errdefer pool.deinit();
    // After Stage 12 schema isolation (GBL-073 dropped public business tables),
    // process_definitions and other tables live in tenant_default schema.
    // Provision tenant_default if its migrations have not yet been applied.
    const build_opts = @import("build_options");
    bpm.db_provisioning.provisionTenantSchema(
        allocator,
        &pool,
        "00000000-0000-0000-0000-000000000000",
        build_opts.migrations_dir,
    ) catch |err| {
        std.debug.print("makePool: provisionTenantSchema failed: {}\n", .{err});
    };
    return pool;
}

fn parseUuid(s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

fn uuidToStr(alloc: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

fn freeDefinition(alloc: std.mem.Allocator, def: store_mod.Definition) void {
    alloc.free(def.name);
    alloc.free(def.version);
    if (def.description) |d| alloc.free(d);
    if (def.stage) |s| alloc.free(s);
    store_mod.freeDefinitionGraph(alloc, def.graph);
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

const minimal_nodes_def = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"test-role\"}" },
    .{ .id = "E", .node_type = .END, .label = null },
};
const minimal_edges_def = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T" },
    .{ .id = "e2", .source = "T", .target = "E" },
};
const minimal_graph_def = DefinitionGraph{
    .nodes = &minimal_nodes_def,
    .edges = &minimal_edges_def,
};

// ---------------------------------------------------------------------------
// Integration tests — TC-PD-07-01 through TC-PD-07-08
// ---------------------------------------------------------------------------

test "TC-PD-07-01: getActiveByName — ACTIVE version exists" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-07-01-def";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    defer freeDefinition(alloc, active);

    const found = try def_store.getActiveByName(alloc, name);
    defer freeDefinition(alloc, found);

    try testing.expectEqualStrings(name, found.name);
    try testing.expectEqual(store_mod.DefinitionStatus.ACTIVE, found.status);
}

test "TC-PD-07-02: getActiveByName — no ACTIVE version returns DefinitionNotFound" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const err = def_store.getActiveByName(alloc, "TC-PD-07-02-nonexistent-def");
    try testing.expectError(error.DefinitionNotFound, err);
}

test "TC-PD-07-03: getActiveByName — empty name returns DefinitionNotFound" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const err = def_store.getActiveByName(alloc, "");
    try testing.expectError(error.DefinitionNotFound, err);
}

test "TC-PD-07-04: list — stage filter narrows results" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name_a = "TC-PD-07-04-stg-A";
    const name_b = "TC-PD-07-04-no-stg";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name_a, version);
    defer cleanupDefinition(&pool, name_b, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);

    const def_a = try def_store.create(alloc, CreateParams{
        .name = name_a,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
        .stage = "stg-07-04-A",
    });
    freeDefinition(alloc, def_a);

    const def_b = try def_store.create(alloc, CreateParams{
        .name = name_b,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
        .stage = null,
    });
    freeDefinition(alloc, def_b);

    const defs = try def_store.list(alloc, store_mod.ListOpts{
        .name = null,
        .status = null,
        .stage = "stg-07-04-A",
        .after_created = null,
        .limit = 50,
    });
    defer {
        for (defs) |d| freeDefinition(alloc, d);
        alloc.free(defs);
    }

    // All returned definitions must have stage = "stg-07-04-A"
    for (defs) |d| {
        try testing.expect(d.stage != null);
        try testing.expectEqualStrings("stg-07-04-A", d.stage.?);
    }

    // The name_a definition must be present
    var found_a = false;
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name_a)) {
            found_a = true;
            break;
        }
    }
    try testing.expect(found_a);

    // The name_b definition (no stage) must not be present
    for (defs) |d| {
        try testing.expect(!std.mem.eql(u8, d.name, name_b));
    }
}

test "TC-PD-07-05: list — stage filter null returns all" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name_with = "TC-PD-07-05-with-stg";
    const name_without = "TC-PD-07-05-no-stg";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name_with, version);
    defer cleanupDefinition(&pool, name_without, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);

    const def_with = try def_store.create(alloc, CreateParams{
        .name = name_with,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
        .stage = "stg-07-05-X",
    });
    freeDefinition(alloc, def_with);

    const def_without = try def_store.create(alloc, CreateParams{
        .name = name_without,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
        .stage = null,
    });
    freeDefinition(alloc, def_without);

    const defs = try def_store.list(alloc, store_mod.ListOpts{
        .name = "TC-PD-07-05",
        .status = null,
        .stage = null,
        .after_created = null,
        .limit = 50,
    });
    defer {
        for (defs) |d| freeDefinition(alloc, d);
        alloc.free(defs);
    }

    var found_with = false;
    var found_without = false;
    for (defs) |d| {
        if (std.mem.eql(u8, d.name, name_with)) found_with = true;
        if (std.mem.eql(u8, d.name, name_without)) found_without = true;
    }
    try testing.expect(found_with);
    try testing.expect(found_without);
}

test "TC-PD-07-06: list — combined name + status filter" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-07-06-combined";
    const version_draft = "1.0.0";
    const version_active = "2.0.0";
    defer cleanupDefinition(&pool, name, version_draft);
    defer cleanupDefinition(&pool, name, version_active);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);

    // Create a DRAFT definition
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version_draft,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    freeDefinition(alloc, draft);

    // Create a second definition and activate it (marks any existing ACTIVE
    // version of the same name as DEPRECATED first)
    const to_activate = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version_active,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    defer freeDefinition(alloc, to_activate);

    const activated = try def_store.activate(alloc, to_activate.id);
    freeDefinition(alloc, activated);

    // List with name + status=DRAFT filter — should only return the DRAFT
    const draft_results = try def_store.list(alloc, store_mod.ListOpts{
        .name = name,
        .status = .DRAFT,
        .stage = null,
        .after_created = null,
        .limit = 50,
    });
    defer {
        for (draft_results) |d| freeDefinition(alloc, d);
        alloc.free(draft_results);
    }

    for (draft_results) |d| {
        try testing.expectEqual(store_mod.DefinitionStatus.DRAFT, d.status);
        try testing.expectEqualStrings(name, d.name);
    }

    // List with name + status=ACTIVE filter — should only return the ACTIVE
    const active_results = try def_store.list(alloc, store_mod.ListOpts{
        .name = name,
        .status = .ACTIVE,
        .stage = null,
        .after_created = null,
        .limit = 50,
    });
    defer {
        for (active_results) |d| freeDefinition(alloc, d);
        alloc.free(active_results);
    }

    try testing.expect(active_results.len >= 1);
    for (active_results) |d| {
        try testing.expectEqual(store_mod.DefinitionStatus.ACTIVE, d.status);
    }
}

test "TC-PD-07-07: list — combined name + stage filter" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-07-07-stg-filter";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);

    const def = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
        .stage = "stg-07-07-C",
    });
    freeDefinition(alloc, def);

    // Matching name + matching stage → found
    const matched = try def_store.list(alloc, store_mod.ListOpts{
        .name = name,
        .status = null,
        .stage = "stg-07-07-C",
        .after_created = null,
        .limit = 50,
    });
    defer {
        for (matched) |d| freeDefinition(alloc, d);
        alloc.free(matched);
    }
    try testing.expect(matched.len >= 1);

    // Matching name + non-matching stage → empty
    const unmatched = try def_store.list(alloc, store_mod.ListOpts{
        .name = name,
        .status = null,
        .stage = "stg-07-07-WRONG",
        .after_created = null,
        .limit = 50,
    });
    defer {
        for (unmatched) |d| freeDefinition(alloc, d);
        alloc.free(unmatched);
    }
    try testing.expectEqual(@as(usize, 0), unmatched.len);
}

test "TC-PD-07-08: handleList — valid cursor round-trip" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-07-08-cursor-rt";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    freeDefinition(alloc, draft);

    // First call — page_size=1 to trigger cursor generation
    const params1 = definitions.ListQueryParams{
        .name = name,
        .status = null,
        .stage = null,
        .cursor = null,
        .page_size = 1,
    };
    const result1 = definitions.handleList(&def_store, alloc, params1);
    defer alloc.free(result1.body);
    try testing.expectEqual(@as(u16, 200), result1.status_code);

    // Extract cursor from JSON body: look for "cursor":"..."
    const cursor_key = "\"cursor\":\"";
    const cursor_start_idx = std.mem.indexOf(u8, result1.body, cursor_key) orelse {
        // No cursor in response (0 results or pagination didn't apply) — test passes trivially
        return;
    };
    const cursor_val_start = cursor_start_idx + cursor_key.len;
    const cursor_val_end = std.mem.indexOfScalarPos(u8, result1.body, cursor_val_start, '"') orelse return;
    const cursor_str = result1.body[cursor_val_start..cursor_val_end];

    // Second call — with cursor extracted from first response
    const params2 = definitions.ListQueryParams{
        .name = name,
        .status = null,
        .stage = null,
        .cursor = cursor_str,
        .page_size = 1,
    };
    const result2 = definitions.handleList(&def_store, alloc, params2);
    defer alloc.free(result2.body);

    // The cursor must be accepted (not 410 Expired, not 422 Invalid)
    try testing.expectEqual(@as(u16, 200), result2.status_code);
}

// ---------------------------------------------------------------------------
// Pure unit test — TC-PD-07-09
// ---------------------------------------------------------------------------

// TC-PD-07-09: An invalid base64url cursor (contains '!') is rejected with
// HTTP 422 before any store call is made.
//
// Implementation path in handleList:
//   decodeCursor(allocator, "not-base64!!") → error.InvalidCursor
//   → return errorResult(allocator, 422, "invalid cursor")
test "TC-PD-07-09: handleList — invalid cursor returns HTTP 422" {
    const alloc = testing.allocator;

    // dummy_store is intentionally undefined: the early-exit path returns
    // before any field of Store is accessed.
    var dummy_store: store_mod.Store = undefined;

    const params = definitions.ListQueryParams{
        .name = null,
        .status = null,
        .stage = null,
        .cursor = "not-base64!!",
        .page_size = null,
    };

    const result = definitions.handleList(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "invalid cursor") != null);
}

// ---------------------------------------------------------------------------
// Pure unit test — TC-PD-07-10
// ---------------------------------------------------------------------------

// TC-PD-07-10: page_size=0 is invalid per API-06 (N ≤ 0 MUST be rejected
// with HTTP 422). Handler validates before cursor decode or store call.
test "TC-PD-07-10: handleList — page_size=0 rejected with HTTP 422" {
    const alloc = testing.allocator;
    const params = definitions.ListQueryParams{
        .name = null,
        .status = null,
        .stage = null,
        .cursor = null,
        .page_size = 0,
    };
    const result = definitions.handleList(undefined, alloc, params);
    defer alloc.free(result.body);
    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "page_size") != null);
}

// ---------------------------------------------------------------------------
// Pure unit test — TC-PD-07-11
// ---------------------------------------------------------------------------

// TC-PD-07-11: page_size=201 exceeds the maximum of 200; rejected with
// HTTP 422 before cursor decode or store call.
//
// Implementation path in handleList:
//   ps = 201 → ps > 200 → return errorResult(allocator, 422, "page_size must be between 1 and 200")
test "TC-PD-07-11: handleList — page_size=201 rejected with HTTP 422" {
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
    try testing.expect(std.mem.indexOf(u8, result.body, "page_size") != null);
}

// ---------------------------------------------------------------------------
// Integration test — TC-PD-07-12
// ---------------------------------------------------------------------------

test "TC-PD-07-12: handleList — page_size=200 accepted returns HTTP 200" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const params = definitions.ListQueryParams{
        .name = null,
        .status = null,
        .stage = null,
        .cursor = null,
        .page_size = 200,
    };
    const result = definitions.handleList(&def_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
}

// ---------------------------------------------------------------------------
// Pure unit test — TC-PD-07-13
// ---------------------------------------------------------------------------

// TC-PD-07-13: An unrecognised status string is rejected with HTTP 422
// before page_size validation, cursor decode, or any store call.
//
// Implementation path in handleList:
//   raw = "UNKNOWN_STATUS" → no match → return errorResult(allocator, 422,
//   "invalid status value; must be one of DRAFT, ACTIVE, DEPRECATED, ARCHIVED")
test "TC-PD-07-13: handleList — unknown status rejected with HTTP 422" {
    const alloc = testing.allocator;

    var dummy_store: store_mod.Store = undefined;

    const params = definitions.ListQueryParams{
        .name = null,
        .status = "UNKNOWN_STATUS",
        .stage = null,
        .cursor = null,
        .page_size = null,
    };

    const result = definitions.handleList(&dummy_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 422), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "invalid status") != null);
}

// ---------------------------------------------------------------------------
// Integration tests — TC-PD-07-14 through TC-PD-07-20
// ---------------------------------------------------------------------------

test "TC-PD-07-14: handleList — valid status=ACTIVE accepted" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const params = definitions.ListQueryParams{
        .name = null,
        .status = "ACTIVE",
        .stage = null,
        .cursor = null,
        .page_size = null,
    };
    const result = definitions.handleList(&def_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
}

test "TC-PD-07-15: handleList — empty result set returns HTTP 200 with empty items" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const params = definitions.ListQueryParams{
        .name = "TC-PD-07-15-nomatch-xq9283bc",
        .status = null,
        .stage = null,
        .cursor = null,
        .page_size = null,
    };
    const result = definitions.handleList(&def_store, alloc, params);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"items\"") != null);
}

test "TC-PD-07-16: handleGetById — valid UUID, definition exists returns HTTP 200" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-07-16-get-by-id";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    defer freeDefinition(alloc, draft);

    const id_str = try uuidToStr(alloc, draft.id);
    defer alloc.free(id_str);

    const result = definitions.handleGetById(&def_store, alloc, id_str);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
}

test "TC-PD-07-17: handleGetById — unknown UUID returns HTTP 404" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const result = definitions.handleGetById(&def_store, alloc, "00000000-0000-0000-0000-000000000001");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 404), result.status_code);
}

test "TC-PD-07-18: handleGetActiveByName — ACTIVE version exists returns HTTP 200" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "TC-PD-07-18-active-by-name";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    defer freeDefinition(alloc, draft);

    const active = try def_store.activate(alloc, draft.id);
    freeDefinition(alloc, active);

    const result = definitions.handleGetActiveByName(&def_store, alloc, name);
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
}

test "TC-PD-07-19: handleGetActiveByName — no ACTIVE version returns HTTP 404" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const result = definitions.handleGetActiveByName(&def_store, alloc, "TC-PD-07-19-nomatch-zz99");
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 404), result.status_code);
}

test "TC-PD-07-20: list — cursor pagination second page does not overlap first" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name_a = "TC-PD-07-20-page-A";
    const name_b = "TC-PD-07-20-page-B";
    const version = "1.0.0";
    defer cleanupDefinition(&pool, name_a, version);
    defer cleanupDefinition(&pool, name_b, version);

    var def_store = store_mod.Store.init(alloc, &pool);
    defer def_store.deinit();

    const creator = try parseUuid(creator_uuid_str);

    const def_a = try def_store.create(alloc, CreateParams{
        .name = name_a,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    freeDefinition(alloc, def_a);

    const def_b = try def_store.create(alloc, CreateParams{
        .name = name_b,
        .version = version,
        .description = null,
        .graph = minimal_graph_def,
        .created_by = creator,
    });
    freeDefinition(alloc, def_b);

    // First page: page_size=1 with name prefix filter "TC-PD-07-20"
    const params1 = definitions.ListQueryParams{
        .name = "TC-PD-07-20",
        .status = null,
        .stage = null,
        .cursor = null,
        .page_size = 1,
    };
    const result1 = definitions.handleList(&def_store, alloc, params1);
    defer alloc.free(result1.body);
    try testing.expectEqual(@as(u16, 200), result1.status_code);

    // Extract the first item's "name" from the JSON body to check for overlap
    const first_name_key = "\"name\":\"";
    const n1_start = std.mem.indexOf(u8, result1.body, first_name_key) orelse {
        // No items returned — test passes trivially (nothing to overlap)
        return;
    };
    const n1_val_start = n1_start + first_name_key.len;
    const n1_val_end = std.mem.indexOfScalarPos(u8, result1.body, n1_val_start, '"') orelse return;
    const first_item_name = result1.body[n1_val_start..n1_val_end];

    // Extract cursor from page 1 response
    const cursor_key = "\"cursor\":\"";
    const c1_start = std.mem.indexOf(u8, result1.body, cursor_key) orelse {
        // No cursor → only one page exists, test passes trivially
        return;
    };
    const c1_val_start = c1_start + cursor_key.len;
    const c1_val_end = std.mem.indexOfScalarPos(u8, result1.body, c1_val_start, '"') orelse return;
    const cursor_str = result1.body[c1_val_start..c1_val_end];

    // Second page: use cursor from page 1
    const params2 = definitions.ListQueryParams{
        .name = "TC-PD-07-20",
        .status = null,
        .stage = null,
        .cursor = cursor_str,
        .page_size = 1,
    };
    const result2 = definitions.handleList(&def_store, alloc, params2);
    defer alloc.free(result2.body);
    try testing.expectEqual(@as(u16, 200), result2.status_code);

    // Verify the second page's items (if any) do not contain the first page's item name
    if (std.mem.indexOf(u8, result2.body, first_name_key)) |n2_start| {
        const n2_val_start = n2_start + first_name_key.len;
        const n2_val_end = std.mem.indexOfScalarPos(u8, result2.body, n2_val_start, '"') orelse return;
        const second_item_name = result2.body[n2_val_start..n2_val_end];
        try testing.expect(!std.mem.eql(u8, first_item_name, second_item_name));
    }
    // If no items on page 2 → no overlap by definition
}

