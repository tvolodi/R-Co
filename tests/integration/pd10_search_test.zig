//! Integration tests for PD-10 — Definition search.
//!
//! Tests exercise Store.search() against a real PostgreSQL database.
//! All 12 test cases from tests/specs/PD-10.md are implemented here.
//!
//! Requires: BPM_TEST_DB_URL environment variable (DB-dependent tests skip
//! when not set).  Validation tests (TC-PD-10-05, TC-PD-10-06, TC-PD-10-11)
//! exercise Store-level pre-checks that return before any DB access; they
//! run unconditionally.
//!
//! Isolation: each test cleans up its own rows explicitly by name after the
//! test body.  All cleanup uses parameterised SQL — no string interpolation.
//!
//! Requirement traceability:
//!   PD-10 → TC-PD-10-01, TC-PD-10-02, TC-PD-10-03, TC-PD-10-04,
//!            TC-PD-10-05, TC-PD-10-06, TC-PD-10-07, TC-PD-10-08,
//!            TC-PD-10-09, TC-PD-10-10, TC-PD-10-11, TC-PD-10-12
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const SearchOptions = bpm.definition.SearchOptions;
const SearchResult = bpm.definition.SearchResult;
const DefinitionError = bpm.definition.DefinitionError;
const DefinitionStatus = bpm.definition.DefinitionStatus;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const Definition = bpm.definition.Definition;

// ---------------------------------------------------------------------------
// Fixed test UUIDs (deterministic — no RNG dependency)
// ---------------------------------------------------------------------------

/// Fake "created_by" UUID; no FK constraint on process_definitions.created_by.
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

// ---------------------------------------------------------------------------
// Minimal valid graph: START → HUMAN_TASK → END
// HUMAN_TASK requires a "role" attribute per PD-05.
// ---------------------------------------------------------------------------

const g_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const g_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const minimal_graph = DefinitionGraph{ .nodes = &g_nodes, .edges = &g_edges };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Parse a UUID hex string (36 chars with hyphens) into [16]u8.
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

/// Free heap-allocated fields of a Definition returned by Store methods.
fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

/// Free all SearchResults in a slice and the slice itself.
fn freeSearchResults(allocator: std.mem.Allocator, results: []SearchResult) void {
    for (results) |sr| freeDefinition(allocator, sr.definition);
    allocator.free(results);
}

/// Delete all rows matching name exactly.  Best-effort; ignores errors.
fn cleanupByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1",
        &.{name},
    ) catch {};
}

/// Force a specific status on a row identified by name + version.
/// For test setup only — never used in production paths.
fn forceStatus(pool: *Pool, name: []const u8, version: []const u8, status: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "UPDATE process_definitions SET status = $1 WHERE name = $2 AND version = $3",
        &.{ status, name, version },
    ) catch {};
}

// ---------------------------------------------------------------------------
// TC-PD-10-01: exact name match returns rank 3.0
// ---------------------------------------------------------------------------

test "TC-PD-10-01: Store.search — exact name match returns result with rank 3.0" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-10-01 Onboarding Flow";
    defer cleanupByName(&pool, def_name);

    const creator = try parseUuid(creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = "Integration test definition for TC-PD-10-01",
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    // Query with the exact definition name → rank 3.0.
    const results = try def_store.search(alloc, SearchOptions{
        .query = def_name,
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    try std.testing.expect(results.len >= 1);
    var found = false;
    for (results) |sr| {
        if (std.mem.eql(u8, sr.definition.name, def_name)) {
            try std.testing.expectEqual(@as(f32, 3.0), sr.rank);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------------
// TC-PD-10-02: partial name match returns rank 2.0
// ---------------------------------------------------------------------------

test "TC-PD-10-02: Store.search — partial name match returns result with rank 2.0" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-10-02 Invoice Processing Pipeline";
    defer cleanupByName(&pool, def_name);

    const creator = try parseUuid(creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = "Integration test definition for TC-PD-10-02",
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    // Query "Invoice" is a substring of the name but not the full name → rank 2.0.
    const results = try def_store.search(alloc, SearchOptions{
        .query = "Invoice",
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    try std.testing.expect(results.len >= 1);
    var found = false;
    for (results) |sr| {
        if (std.mem.eql(u8, sr.definition.name, def_name)) {
            // Rank 2.0: name ILIKE '%Invoice%' but name ≠ 'Invoice' exactly.
            try std.testing.expectEqual(@as(f32, 2.0), sr.rank);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------------
// TC-PD-10-03: description-only match returns rank 1.0
// ---------------------------------------------------------------------------

test "TC-PD-10-03: Store.search — description-only match returns result with rank 1.0" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-PD-10-03 Approval Process";
    const description = "quarterly budget review cycle";
    defer cleanupByName(&pool, def_name);

    const creator = try parseUuid(creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = description,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    // Query matches the description but not the name → rank 1.0 (ELSE branch).
    const results = try def_store.search(alloc, SearchOptions{
        .query = "quarterly budget review",
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    try std.testing.expect(results.len >= 1);
    var found = false;
    for (results) |sr| {
        if (std.mem.eql(u8, sr.definition.name, def_name)) {
            try std.testing.expectEqual(@as(f32, 1.0), sr.rank);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------------
// TC-PD-10-04: no matching definitions returns empty slice (not an error)
// ---------------------------------------------------------------------------

test "TC-PD-10-04: Store.search — no matching definitions returns empty slice" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // A query that cannot match any real definition name or description.
    const results = try def_store.search(alloc, SearchOptions{
        .query = "xyzxyz_no_match_99901",
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

// ---------------------------------------------------------------------------
// TC-PD-10-05: empty query returns QueryEmpty (no DB access)
// ---------------------------------------------------------------------------

// Store.search() validates before acquiring a pool connection, so this test
// does not require BPM_TEST_DB_URL.
test "TC-PD-10-05: Store.search — empty query returns QueryEmpty without DB access" {
    const alloc = std.testing.allocator;

    // dummy_pool is never accessed because validation fires first.
    var dummy_pool: Pool = undefined;
    var store = DefinitionStore.init(alloc, &dummy_pool);
    // deinit is safe: last_violations is empty (no create() was called).
    defer store.deinit();

    const result = store.search(alloc, SearchOptions{
        .query = "",
        .limit = 20,
        .offset = 0,
    });
    try std.testing.expectError(DefinitionError.QueryEmpty, result);
}

// ---------------------------------------------------------------------------
// TC-PD-10-06: query > 512 characters returns QueryTooLong (no DB access)
// ---------------------------------------------------------------------------

test "TC-PD-10-06: Store.search — query longer than 512 chars returns QueryTooLong" {
    const alloc = std.testing.allocator;

    var dummy_pool: Pool = undefined;
    var store = DefinitionStore.init(alloc, &dummy_pool);
    defer store.deinit();

    var long_query_arr: [513]u8 = undefined;
    @memset(&long_query_arr, 'a');
    const long_query: []const u8 = &long_query_arr;

    const result = store.search(alloc, SearchOptions{
        .query = long_query,
        .limit = 20,
        .offset = 0,
    });
    try std.testing.expectError(DefinitionError.QueryTooLong, result);
}

// ---------------------------------------------------------------------------
// TC-PD-10-07: case-insensitive search
// ---------------------------------------------------------------------------

test "TC-PD-10-07: Store.search — uppercase query matches lowercase definition name" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Definition name is all lowercase.
    const def_name = "tc-pd-10-07 payroll process";
    defer cleanupByName(&pool, def_name);

    const creator = try parseUuid(creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def = try def_store.create(alloc, CreateParams{
        .name = def_name,
        .version = "1.0.0",
        .description = "Integration test definition for TC-PD-10-07",
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def);

    // Query is all uppercase — ILIKE is case-insensitive in PostgreSQL.
    const results = try def_store.search(alloc, SearchOptions{
        .query = "TC-PD-10-07 PAYROLL PROCESS",
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    try std.testing.expect(results.len >= 1);
    var found = false;
    for (results) |sr| {
        if (std.mem.eql(u8, sr.definition.name, def_name)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------------
// TC-PD-10-08: name match ordered before description-only match
// ---------------------------------------------------------------------------

test "TC-PD-10-08: Store.search — name match (rank 2.0) before description match (rank 1.0)" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name_match = "TC-PD-10-08 purchasing workflow";
    const desc_match = "TC-PD-10-08 unrelated process";
    defer cleanupByName(&pool, name_match);
    defer cleanupByName(&pool, desc_match);

    const creator = try parseUuid(creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Definition whose name contains "purchasing" → rank 2.0 for query "purchasing".
    const def_a = try def_store.create(alloc, CreateParams{
        .name = name_match,
        .version = "1.0.0",
        .description = "does not mention the keyword",
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_a);

    // Definition whose description contains "purchasing" → rank 1.0.
    const def_b = try def_store.create(alloc, CreateParams{
        .name = desc_match,
        .version = "1.0.0",
        .description = "purchasing approval flow",
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_b);

    const results = try def_store.search(alloc, SearchOptions{
        .query = "purchasing",
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    // Exactly two results expected (one per test definition).
    try std.testing.expectEqual(@as(usize, 2), results.len);

    // First result must be the name-matching definition (higher rank).
    try std.testing.expect(results[0].rank > results[1].rank);
    try std.testing.expect(std.mem.eql(u8, results[0].definition.name, name_match));
    try std.testing.expect(std.mem.eql(u8, results[1].definition.name, desc_match));
}

// ---------------------------------------------------------------------------
// TC-PD-10-09: pagination via limit and offset
// ---------------------------------------------------------------------------

test "TC-PD-10-09: Store.search — limit and offset control the result window" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name_a = "TC-PD-10-09 paginate-A";
    const name_b = "TC-PD-10-09 paginate-B";
    const name_c = "TC-PD-10-09 paginate-C";
    defer cleanupByName(&pool, name_a);
    defer cleanupByName(&pool, name_b);
    defer cleanupByName(&pool, name_c);

    const creator = try parseUuid(creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const def_a = try def_store.create(alloc, CreateParams{
        .name = name_a,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_a);

    const def_b = try def_store.create(alloc, CreateParams{
        .name = name_b,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_b);

    const def_c = try def_store.create(alloc, CreateParams{
        .name = name_c,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_c);

    // First page: limit=2, offset=0 → 2 results.
    const page1 = try def_store.search(alloc, SearchOptions{
        .query = "TC-PD-10-09",
        .limit = 2,
        .offset = 0,
    });
    defer freeSearchResults(alloc, page1);
    try std.testing.expectEqual(@as(usize, 2), page1.len);

    // Second page: limit=2, offset=2 → 1 remaining result.
    const page2 = try def_store.search(alloc, SearchOptions{
        .query = "TC-PD-10-09",
        .limit = 2,
        .offset = 2,
    });
    defer freeSearchResults(alloc, page2);
    try std.testing.expectEqual(@as(usize, 1), page2.len);
}

// ---------------------------------------------------------------------------
// TC-PD-10-10: SQL-special characters handled safely (no injection)
// ---------------------------------------------------------------------------

test "TC-PD-10-10: Store.search — SQL-special chars are handled safely; no injection" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Query contains single-quote, percent, underscore, and a DROP statement.
    // If SQL injection were possible this would fail; instead it is safely bound
    // as parameter $1/$2 by pg.zig and returns 0 results.
    const injection_query = "'; DROP TABLE process_definitions; --";

    const results = try def_store.search(alloc, SearchOptions{
        .query = injection_query,
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    // No rows match the injection string and the table is intact.
    try std.testing.expectEqual(@as(usize, 0), results.len);

    // Verify the table is still intact by running a count query via the pool.
    const conn = try pool.acquire();
    defer pool.release(conn);
    const count_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM process_definitions",
        &.{},
    );
    defer {
        var r = count_rows;
        r.deinit();
    }
    // As long as the query succeeds, the table exists — injection did not execute.
    try std.testing.expect(count_rows.rows.len >= 0);
}

// ---------------------------------------------------------------------------
// TC-PD-10-11: empty query at Store level mirrors absent-URL-param behaviour
//
// At the HTTP handler layer, `q = null` (absent URL parameter) is checked
// before Store.search() is ever called — the handler returns 422 immediately.
// At the Store level, the equivalent scenario is an empty query string, which
// triggers the same QueryEmpty error.  The unit test covers the handler path;
// this integration test covers the Store-level belt-and-suspenders check.
// ---------------------------------------------------------------------------

test "TC-PD-10-11: Store.search — empty query (absent-param equivalent) returns QueryEmpty" {
    const alloc = std.testing.allocator;

    // Validation fires before pool acquisition — no DB needed.
    var dummy_pool: Pool = undefined;
    var store = DefinitionStore.init(alloc, &dummy_pool);
    defer store.deinit();

    const result = store.search(alloc, SearchOptions{
        .query = "",
        .limit = 20,
        .offset = 0,
    });
    try std.testing.expectError(DefinitionError.QueryEmpty, result);
}

// ---------------------------------------------------------------------------
// TC-PD-10-12: definitions in all four statuses are returned
// ---------------------------------------------------------------------------

test "TC-PD-10-12: Store.search — returns definitions in DRAFT, ACTIVE, DEPRECATED, ARCHIVED" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name_draft = "TC-PD-10-12 draft def";
    const name_active = "TC-PD-10-12 active def";
    const name_deprecated = "TC-PD-10-12 deprecated def";
    const name_archived = "TC-PD-10-12 archived def";
    defer cleanupByName(&pool, name_draft);
    defer cleanupByName(&pool, name_active);
    defer cleanupByName(&pool, name_deprecated);
    defer cleanupByName(&pool, name_archived);

    const creator = try parseUuid(creator_uuid_str);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    // Create all four definitions in their initial DRAFT status.
    const def_draft = try def_store.create(alloc, CreateParams{
        .name = name_draft,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_draft);

    const def_active = try def_store.create(alloc, CreateParams{
        .name = name_active,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_active);

    const def_deprecated = try def_store.create(alloc, CreateParams{
        .name = name_deprecated,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_deprecated);

    const def_archived = try def_store.create(alloc, CreateParams{
        .name = name_archived,
        .version = "1.0.0",
        .description = null,
        .graph = minimal_graph,
        .created_by = creator,
    });
    defer freeDefinition(alloc, def_archived);

    // Force status on three of the four rows (DRAFT stays as-is).
    forceStatus(&pool, name_active, "1.0.0", "ACTIVE");
    forceStatus(&pool, name_deprecated, "1.0.0", "DEPRECATED");
    forceStatus(&pool, name_archived, "1.0.0", "ARCHIVED");

    // Search covers all statuses — no WHERE status = ... in the query.
    const results = try def_store.search(alloc, SearchOptions{
        .query = "TC-PD-10-12",
        .limit = 20,
        .offset = 0,
    });
    defer freeSearchResults(alloc, results);

    try std.testing.expectEqual(@as(usize, 4), results.len);

    // Verify all four statuses appear in the result set.
    var has_draft = false;
    var has_active = false;
    var has_deprecated = false;
    var has_archived = false;

    for (results) |sr| {
        switch (sr.definition.status) {
            .DRAFT => has_draft = true,
            .ACTIVE => has_active = true,
            .DEPRECATED => has_deprecated = true,
            .ARCHIVED => has_archived = true,
        }
    }

    try std.testing.expect(has_draft);
    try std.testing.expect(has_active);
    try std.testing.expect(has_deprecated);
    try std.testing.expect(has_archived);
}
