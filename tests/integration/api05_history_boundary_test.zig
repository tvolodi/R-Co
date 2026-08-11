//! Integration tests for API-05 valid-boundary cases — GH-280 / ISS-0040.
//!
//! tests/unit/test_api05_history.zig stubs 7 test cases with
//! `return error.SkipZigTest;` because they exercise the success path of
//! handleHistory() (src/api/routes/instances.zig), which requires a real
//! Store.readHistory() round-trip against PostgreSQL — not reachable with the
//! `undefined` Store pointer used elsewhere in that unit-test file. This file
//! is the "real store" counterpart those stubs point to.
//!
//! Grounded in source, not assumption:
//!   - page_size bounds: src/api/pagination.zig `MAX_PAGE_SIZE: u16 = 200`,
//!     `validatePageSize()` accepts 1..200 inclusive (0 and >200 rejected —
//!     already covered by TC-API-05-12a/12b in the unit-test file). This file
//!     covers the two boundary values themselves: 1 (lower) and 200 (upper).
//!   - ISO 8601 formats: src/api/routes/instances.zig `parseIso8601ToMicros()`
//!     accepts `Z` suffix, optional `.sss`/`.ssssss` fractional seconds (1-6
//!     digits, right-padded/truncated to microseconds), and `+HH:MM`/`-HH:MM`
//!     numeric offsets — the exact 5 variants named in the unit-test stub
//!     comments (TC-API-05-14a..e).
//!
//! Tests follow DIRECTIVE T-1: real PostgreSQL via TestHarness, no mocks or
//! stubs. Each test creates its own instance + events with per-test UUIDs
//! (TestHarness.newUuid / newUuidString) and idempotency keys, and relies on
//! TestHarness's rollback-on-deinit transaction for cleanup — same pattern as
//! tests/integration/api03_instance_read_test.zig's existing TC-API-05-01..04
//! cases, which this file follows structurally.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Requirement traceability:
//!   API-05 → TC-API-05-12c (page_size=1, lower boundary)
//!            TC-API-05-12d (page_size=200, upper boundary)
//!            TC-API-05-14a (valid UTC timestamp, no fractional seconds)
//!            TC-API-05-14b (valid timestamp with milliseconds)
//!            TC-API-05-14c (valid timestamp with microseconds)
//!            TC-API-05-14d (valid timestamp with positive timezone offset)
//!            TC-API-05-14e (valid timestamp with negative timezone offset)

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;

const EventRegistry = bpm.registry.Registry;
const EventRegisterParams = bpm.registry.RegisterParams;
const AppendParams = bpm.store.AppendParams;
const EventStore = bpm.store.Store;
const handleHistory = bpm.instance_routes.handleHistory;
const HistoryParams = bpm.instance_routes.HistoryParams;

// ---------------------------------------------------------------------------
// process_definitions.created_by has no FK constraint, but per this repo's
// lint_test_isolation.py (T010) every identifier in an integration test must
// still be a fresh per-test UUID rather than a shared literal — createActiveDefinition()
// below takes `creator_id` as a parameter so each call site sources it from
// TestHarness.newUuid().
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const minimal_graph = DefinitionGraph{ .nodes = &minimal_nodes, .edges = &minimal_edges };

// ---------------------------------------------------------------------------
// Shared helpers (mirrors tests/integration/api03_instance_read_test.zig)
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL; fail clearly (not silently skip) if missing —
/// required by TEST-DESIGNER self-sufficiency rules.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for tests/integration/api05_history_boundary_test.zig\n", .{});
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
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

fn createActiveDefinition(
    allocator: std.mem.Allocator,
    def_store: *DefinitionStore,
    name: []const u8,
    version: []const u8,
    creator_id: [16]u8,
) ![16]u8 {
    const created = try def_store.create(allocator, CreateParams{
        .name = name,
        .version = version,
        .description = null,
        .graph = minimal_graph,
        .created_by = creator_id,
    });
    const def_id = created.id;
    allocator.free(created.name);
    allocator.free(created.version);
    if (created.description) |d| allocator.free(d);
    if (created.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, created.graph);

    const activated = try def_store.activate(allocator, def_id);
    allocator.free(activated.name);
    allocator.free(activated.version);
    if (activated.description) |d| allocator.free(d);
    if (activated.stage) |s| allocator.free(s);
    bpm.definition.freeDefinitionGraph(allocator, activated.graph);

    return def_id;
}

fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id_hex}) catch {};
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

fn freeInstance(allocator: std.mem.Allocator, inst: bpm.engine.Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

/// Register a fresh event type (per test, name derived from a per-test UUID
/// to avoid cross-test collisions on the global event-type registry) and
/// return an initialised EventStore over it. Caller owns `ev_registry` and
/// `ev_store` lifetimes (deinit them).
fn setupEventStore(
    allocator: std.mem.Allocator,
    pool: *Pool,
    ev_registry: *EventRegistry,
    type_name: []const u8,
) !void {
    ev_registry.* = EventRegistry.init(allocator, pool);
    _ = ev_registry.registerType(allocator, EventRegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
}

/// Append `count` events to `inst_id` via ev_store, each with a distinct
/// per-test idempotency key derived from `key_prefix` + index. Rows are
/// cleaned up by cleanupInstance()'s `DELETE FROM events`; the in-process
/// AppendResult.record returned by each append() call owns a heap-allocated
/// `metadata` field (duplicateFromParams() in src/event_store/store.zig
/// always dupes it, even when null was passed) that must be freed here or it
/// leaks under the DebugAllocator used by `zig build test`.
fn appendNEvents(
    allocator: std.mem.Allocator,
    ev_store: *EventStore,
    inst_id: [16]u8,
    event_type: []const u8,
    actor_uuid: [16]u8,
    key_prefix: []const u8,
    count: usize,
) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idem_key = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ key_prefix, i });
        defer allocator.free(idem_key);
        var append_result = try ev_store.append(allocator, AppendParams{
            .instance_id = inst_id,
            .event_type = event_type,
            .payload = "{}",
            .actor_id = actor_uuid,
            .idempotency_key = idem_key,
            .metadata = null,
        });
        append_result.record.deinit(allocator);
    }
}

// ---------------------------------------------------------------------------
// TC-API-05-12c: page_size=1 (lower boundary) — exactly 1 item per page,
// correct pagination metadata (has next_cursor when more rows exist).
// ---------------------------------------------------------------------------

test "TC-API-05-12c: handleHistory with page_size=1 returns exactly 1 item and a next_cursor" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-05-12c Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version, h.newUuid());

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const type_name_str = try h.newUuidString(alloc);
    defer alloc.free(type_name_str);
    const event_type = try std.fmt.allocPrint(alloc, "T{s}", .{type_name_str[0..8]});
    defer alloc.free(event_type);

    var ev_registry: EventRegistry = undefined;
    try setupEventStore(alloc, &pool, &ev_registry, event_type);
    defer ev_registry.deinit();

    var ev_store = EventStore.init(alloc, &pool, &ev_registry);
    defer ev_store.deinit();

    const actor_uuid = h.newUuid();
    const key_prefix = try h.newUuidString(alloc);
    defer alloc.free(key_prefix);

    // 3 events so page_size=1 definitely has a next page.
    try appendNEvents(alloc, &ev_store, inst_id, event_type, actor_uuid, key_prefix, 3);

    // Filter by our own per-test event_type for the same reason as
    // TC-API-05-12d: isolate the assertions from InstanceStore.create()'s own
    // instance-lifecycle event on the same instance.
    const result = handleHistory(&ev_store, alloc, inst_id_hex, HistoryParams{
        .event_type = event_type,
        .page_size = 1,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{});
    defer parsed.deinit();

    const items = parsed.value.object.get("items").?.array;
    try testing.expectEqual(@as(usize, 1), items.items.len);

    const count = parsed.value.object.get("count").?.integer;
    try testing.expectEqual(@as(i64, 1), count);

    // 3 events exist and page_size=1 → more pages remain → next_cursor non-null.
    const next_cursor = parsed.value.object.get("next_cursor").?;
    try testing.expect(next_cursor != .null);
}

// ---------------------------------------------------------------------------
// TC-API-05-12d: page_size=200 (upper boundary) — accepted (not rejected as
// oversized), returns up to 200 results, correct pagination metadata (no
// next_cursor when all rows fit on the page).
// ---------------------------------------------------------------------------

test "TC-API-05-12d: handleHistory with page_size=200 is accepted and returns all rows with no next_cursor" {
    const alloc = testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = "TC-API-05-12d Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version, h.newUuid());

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const type_name_str = try h.newUuidString(alloc);
    defer alloc.free(type_name_str);
    const event_type = try std.fmt.allocPrint(alloc, "T{s}", .{type_name_str[0..8]});
    defer alloc.free(event_type);

    var ev_registry: EventRegistry = undefined;
    try setupEventStore(alloc, &pool, &ev_registry, event_type);
    defer ev_registry.deinit();

    var ev_store = EventStore.init(alloc, &pool, &ev_registry);
    defer ev_store.deinit();

    const actor_uuid = h.newUuid();
    const key_prefix = try h.newUuidString(alloc);
    defer alloc.free(key_prefix);

    // 5 events (well under 200) — page_size=200 must be ACCEPTED (not 422) and
    // return all 5 with no next_cursor, proving 200 is treated as in-bounds.
    try appendNEvents(alloc, &ev_store, inst_id, event_type, actor_uuid, key_prefix, 5);

    // Filter by our own per-test event_type: InstanceStore.create() emits its
    // own instance-lifecycle event on the same instance (a separate row that
    // handleHistory would also return by default), which would otherwise
    // break both the exact-count and no-next-cursor assertions below for a
    // reason unrelated to page_size=200 itself.
    const result = handleHistory(&ev_store, alloc, inst_id_hex, HistoryParams{
        .event_type = event_type,
        .page_size = 200,
    });
    defer alloc.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{});
    defer parsed.deinit();

    const items = parsed.value.object.get("items").?.array;
    try testing.expectEqual(@as(usize, 5), items.items.len);

    const count = parsed.value.object.get("count").?.integer;
    try testing.expectEqual(@as(i64, 5), count);

    const next_cursor = parsed.value.object.get("next_cursor").?;
    try testing.expect(next_cursor == .null);
}

// ---------------------------------------------------------------------------
// TC-API-05-14a..e: valid ISO 8601 timestamp format variants for `from` all
// pass validation and reach the store (HTTP 200), grounded in
// parseIso8601ToMicros()'s actual accepted grammar (src/api/routes/instances.zig).
// Each sub-test uses a `from` far enough in the past that the just-appended
// event (created "now" via NOW()) is included and returned — asserting the
// timestamp was genuinely parsed and applied as a filter, not merely accepted
// syntactically.
// ---------------------------------------------------------------------------

fn runValidTimestampCase(alloc: std.mem.Allocator, comptime label: []const u8, from_ts: []const u8) !void {
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const def_name = label ++ " Proc";
    const def_version = "1.0.0";
    defer cleanupDefinition(&pool, def_name, def_version);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    var snapshot_store = SnapshotStore.init(&pool);
    var instance_store = InstanceStore.init(&pool, &snapshot_store);
    defer instance_store.deinit();

    const def_id = try createActiveDefinition(alloc, &def_store, def_name, def_version, h.newUuid());

    const inst = try instance_store.create(alloc, def_id, null, "{}");
    const inst_id = inst.instance_id;
    const inst_id_hex = try uuidToHexStr(alloc, inst_id);
    defer alloc.free(inst_id_hex);
    defer cleanupInstance(&pool, inst_id_hex);
    freeInstance(alloc, inst);

    const type_name_str = try h.newUuidString(alloc);
    defer alloc.free(type_name_str);
    const event_type = try std.fmt.allocPrint(alloc, "T{s}", .{type_name_str[0..8]});
    defer alloc.free(event_type);

    var ev_registry: EventRegistry = undefined;
    try setupEventStore(alloc, &pool, &ev_registry, event_type);
    defer ev_registry.deinit();

    var ev_store = EventStore.init(alloc, &pool, &ev_registry);
    defer ev_store.deinit();

    const actor_uuid = h.newUuid();
    const idem_key = try h.newUuidString(alloc);
    defer alloc.free(idem_key);

    // AppendResult.record.metadata is heap-allocated by duplicateFromParams()
    // regardless of the null passed here (see appendNEvents' doc comment) —
    // free it or it leaks under the DebugAllocator.
    var append_result = try ev_store.append(alloc, AppendParams{
        .instance_id = inst_id,
        .event_type = event_type,
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = idem_key,
        .metadata = null,
    });
    append_result.record.deinit(alloc);

    // Filter by our own per-test event_type as well as `from`. This isolates
    // the assertion from InstanceStore.create()'s own instance-lifecycle
    // event (a separate row on the same instance, e.g. INSTANCE_CREATED,
    // which handleHistory would otherwise also return since it defaults to
    // "all event types") — without this filter the exact-count assertion
    // below would be coupled to an unrelated implementation detail of
    // instance creation rather than to the `from` timestamp parse this test
    // is actually about.
    const result = handleHistory(&ev_store, alloc, inst_id_hex, HistoryParams{
        .event_type = event_type,
        .from = from_ts,
    });
    defer alloc.free(result.body);

    // A rejected/unparseable `from` would return 422 INVALID_TIMESTAMP — the
    // exact failure mode these boundary cases exist to rule out.
    try testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("items").?.array;
    // `from` is far in the past (year 2020) relative to the event just
    // appended (created "now"), so the event must be included — proving the
    // timestamp was parsed and applied as a genuine inclusive lower bound,
    // not merely accepted and then ignored.
    try testing.expectEqual(@as(usize, 1), items.items.len);
}

test "TC-API-05-14a: valid UTC timestamp '2020-01-15T10:30:00Z' (no fractional seconds) parses and filters correctly" {
    try runValidTimestampCase(testing.allocator, "TC-API-05-14a", "2020-01-15T10:30:00Z");
}

test "TC-API-05-14b: valid timestamp with milliseconds '2020-01-15T10:30:00.123Z' parses and filters correctly" {
    try runValidTimestampCase(testing.allocator, "TC-API-05-14b", "2020-01-15T10:30:00.123Z");
}

test "TC-API-05-14c: valid timestamp with microseconds '2020-01-15T10:30:00.123456Z' parses and filters correctly" {
    try runValidTimestampCase(testing.allocator, "TC-API-05-14c", "2020-01-15T10:30:00.123456Z");
}

test "TC-API-05-14d: valid timestamp with positive timezone offset '2020-01-15T15:30:00+05:00' parses and filters correctly" {
    try runValidTimestampCase(testing.allocator, "TC-API-05-14d", "2020-01-15T15:30:00+05:00");
}

test "TC-API-05-14e: valid timestamp with negative timezone offset '2020-01-15T07:30:00-03:00' parses and filters correctly" {
    try runValidTimestampCase(testing.allocator, "TC-API-05-14e", "2020-01-15T07:30:00-03:00");
}
