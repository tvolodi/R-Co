//! Integration tests for ES-01 through ES-08 (event store layer).
//!
//! Requires a real PostgreSQL database reachable at BPM_TEST_DB_URL.
//! Every test uses TestHarness for migration bootstrap, then a Pool for
//! Store operations (Store manages its own connections).
//!
//! Requirement traceability:
//!   ES-01 → TC-ES-01-01
//!   ES-02 → TC-ES-02-01, TC-ES-02-02
//!   ES-03 → TC-ES-03-01
//!   ES-04 → TC-ES-04-01, TC-ES-04-02
//!   ES-05 → TC-ES-05-01 (integration portion)
//!   ES-06 → TC-ES-06-01, TC-ES-06-02
//!   ES-07 → TC-ES-07-01
//!   ES-08 → TC-ES-08-04 (integration portion)
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const Store = bpm.store.Store;
const AppendParams = bpm.store.AppendParams;
const AppendResult = bpm.store.AppendResult;
const ReadOpts = bpm.store.ReadOpts;
const GlobalReadOpts = bpm.store.GlobalReadOpts;
const StoreError = bpm.store.StoreError;
const RetentionPolicyMode = bpm.store.RetentionPolicyMode;
const RetentionPolicyUpsertParams = bpm.store.RetentionPolicyUpsertParams;

const Registry = bpm.registry.Registry;
const RegisterParams = bpm.registry.RegisterParams;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL from the environment.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

/// Create a Pool pointing to the test DB.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Parse a UUID string (canonical 36-char hyphenated form) into [16]u8.
/// Strips dashes before calling hexToBytes.
fn parseUuid(allocator: std.mem.Allocator, s: []const u8) ![16]u8 {
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
    _ = allocator; // silence unused warning
    return out;
}

/// Insert an instance_projections row (autocommit) so that Store can see it.
fn insertInstance(pool: *Pool, inst_id: []const u8, def_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO instance_projections " ++
            "(instance_id, definition_id, status, last_event_seq) " ++
            "VALUES ($1::uuid, $2::uuid, 'ACTIVE', 0) ON CONFLICT DO NOTHING",
        &.{ inst_id, def_id },
    );
}

/// Insert an instance_projections row with an explicit lifecycle status.
/// Used by TC-ES-01-03 / TC-ES-01-04, which need a terminated instance.
fn insertInstanceWithStatus(pool: *Pool, inst_id: []const u8, def_id: []const u8, status: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO instance_projections " ++
            "(instance_id, definition_id, status, last_event_seq) " ++
            "VALUES ($1::uuid, $2::uuid, $3, 0) " ++
            "ON CONFLICT (instance_id) DO UPDATE SET status = EXCLUDED.status",
        &.{ inst_id, def_id, status },
    );
}

/// Build a per-test-unique identifier of the form "<prefix>-<uuid>".
///
/// Used for event type names and idempotency keys so that no two tests — and no
/// two runs of the same test against this shared database — can collide (T010).
/// Caller owns the returned slice.
fn uniqueName(allocator: std.mem.Allocator, h: *TestHarness, prefix: []const u8) ![]u8 {
    const id = try h.newUuidString(allocator);
    defer allocator.free(id);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, id });
}

/// Count live event rows carrying the given idempotency_key.
fn countEvents(pool: *Pool, alloc: std.mem.Allocator, idem_key: []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var res = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE idempotency_key = $1",
        &.{idem_key},
    );
    defer res.deinit();
    if (res.rows.len == 0 or res.rows[0].len == 0) return 0;
    return std.fmt.parseInt(i64, res.rows[0][0] orelse "0", 10) catch 0;
}

/// Delete a per-test event type registration (best-effort cleanup).
/// registerType() autocommits, so the row outlives the harness transaction and
/// must be removed explicitly or it accumulates in the shared test database.
fn cleanupEventType(pool: *Pool, type_name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM event_type_registry WHERE name = $1", &.{type_name}) catch {};
}

/// Delete test data written by a test (best-effort cleanup).
fn cleanupInstance(pool: *Pool, inst_id: []const u8, idem_keys: []const []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    for (idem_keys) |key| {
        conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{key}) catch {};
        conn.exec("DELETE FROM events_archive WHERE idempotency_key = $1", &.{key}) catch {};
    }
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{inst_id}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{inst_id}) catch {};
}

// ---------------------------------------------------------------------------
// ES-01: Append round-trip
// ---------------------------------------------------------------------------

// TC-ES-01-01
// Appends one event and verifies AppendResult fields and readback via Store.read().
test "TC-ES-01-01: valid append returns AppendResult with is_duplicate=false and persisted record" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES01_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"es01-idem-01"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    const result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES01_TYPE",
        .payload = "{\"x\":1}",
        .actor_id = actor_uuid,
        .idempotency_key = "es01-idem-01",
        .metadata = null,
    });

    try std.testing.expect(!result.is_duplicate);
    // sequence_number must be >= 1.
    try std.testing.expect(result.record.sequence_number >= 1);

    // The event must be readable back via Store.read().
    const events = try store.read(alloc, inst_uuid, ReadOpts{
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer {
        for (events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(events);
    }
    try std.testing.expect(events.len >= 1);
}

// ---------------------------------------------------------------------------
// ES-02: Ordered read
// ---------------------------------------------------------------------------

// TC-ES-02-01
// Two sequential appends must receive sequence_numbers 1 and 2.
test "TC-ES-02-01: two sequential appends receive sequence_numbers 1 and 2" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES02_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "es02-idem-01", "es02-idem-02" });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    const r1 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02-idem-01",
        .metadata = null,
    });
    const r2 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02-idem-02",
        .metadata = null,
    });

    try std.testing.expectEqual(@as(i64, 1), r1.record.sequence_number);
    try std.testing.expectEqual(@as(i64, 2), r2.record.sequence_number);
}

// TC-ES-02-02
// Store.read() returns 3 events sorted by ascending sequence_number.
test "TC-ES-02-02: Store.read returns events sorted by ascending sequence_number" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES02B_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "es02b-idem-01", "es02b-idem-02", "es02b-idem-03" });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02B_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02b-idem-01",
        .metadata = null,
    });
    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02B_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02b-idem-02",
        .metadata = null,
    });
    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02B_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02b-idem-03",
        .metadata = null,
    });

    const events = try store.read(alloc, inst_uuid, ReadOpts{
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer {
        for (events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(events);
    }

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(i64, 1), events[0].sequence_number);
    try std.testing.expectEqual(@as(i64, 2), events[1].sequence_number);
    try std.testing.expectEqual(@as(i64, 3), events[2].sequence_number);
}

// ---------------------------------------------------------------------------
// ES-03: Idempotency deduplication
// ---------------------------------------------------------------------------

// TC-ES-03-01
// A second append with the same idempotency_key must return is_duplicate=true
// and the same event_id as the first, without inserting a new row.
test "TC-ES-03-01: duplicate idempotency_key returns original event with is_duplicate=true" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES03_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"es03-idem-001"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    var first = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES03_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es03-idem-001",
        .metadata = null,
    });
    defer first.record.deinit(alloc);
    try std.testing.expect(!first.is_duplicate);

    var second = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES03_TYPE",
        .payload = "{\"x\":99}",
        .actor_id = actor_uuid,
        .idempotency_key = "es03-idem-001",
        .metadata = null,
    });
    defer second.record.deinit(alloc);
    try std.testing.expect(second.is_duplicate);
    // The returned sequence_number must match the first call.
    try std.testing.expectEqual(first.record.sequence_number, second.record.sequence_number);

    // Only one events row must exist for this key.
    const check_conn = try pool.acquire();
    defer pool.release(check_conn);
    var cnt = try check_conn.query(alloc, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{"es03-idem-001"});
    defer cnt.deinit();
    if (cnt.rows.len > 0) {
        if (cnt.rows[0][0]) |s| {
            const n = try std.fmt.parseInt(i64, s, 10);
            try std.testing.expectEqual(@as(i64, 1), n);
        }
    }
}

// ---------------------------------------------------------------------------
// ES-04: Global stream ordering
// ---------------------------------------------------------------------------

// TC-ES-04-01
// Events appended to two different instances must appear in readGlobal()
// with strictly ascending global_seq values.
test "TC-ES-04-01: readGlobal returns events in ascending global_seq order" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES04_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_a = try h.newUuidString(alloc);
    defer alloc.free(inst_a);
    const inst_b = try h.newUuidString(alloc);
    defer alloc.free(inst_b);
    const def_a = try h.newUuidString(alloc);
    defer alloc.free(def_a);
    const def_b = try h.newUuidString(alloc);
    defer alloc.free(def_b);
    try insertInstance(&pool, inst_a, def_a);
    try insertInstance(&pool, inst_b, def_b);
    defer cleanupInstance(&pool, inst_a, &.{ "es04-idem-a1", "es04-idem-a2" });
    defer cleanupInstance(&pool, inst_b, &.{"es04-idem-b1"});

    const uuid_a = try parseUuid(alloc, inst_a);
    const uuid_b = try parseUuid(alloc, inst_b);
    const actor_uuid = h.newUuid();

    const r1 = try store.append(alloc, AppendParams{
        .instance_id = uuid_a,
        .event_type = "ES04_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es04-idem-a1",
        .metadata = null,
    });
    const r2 = try store.append(alloc, AppendParams{
        .instance_id = uuid_b,
        .event_type = "ES04_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es04-idem-b1",
        .metadata = null,
    });
    const r3 = try store.append(alloc, AppendParams{
        .instance_id = uuid_a,
        .event_type = "ES04_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es04-idem-a2",
        .metadata = null,
    });

    // Read all events with global_seq > the value before r1.
    const after: i64 = r1.record.global_seq - 1;
    const events = try store.readGlobal(alloc, GlobalReadOpts{
        .after_global_seq = after,
        .limit = 100,
    });
    defer {
        for (events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(events);
    }

    // Must contain at least our 3 appended events.
    try std.testing.expect(events.len >= 3);

    // Verify global_seq is strictly ascending.
    var prev_seq: i64 = 0;
    for (events) |ev| {
        try std.testing.expect(ev.global_seq > prev_seq);
        prev_seq = ev.global_seq;
    }
    _ = r2;
    _ = r3;
}

// TC-ES-04-02
// readGlobal with after_global_seq cursor returns only events after that point.
test "TC-ES-04-02: readGlobal with after_global_seq cursor returns only later events" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES04C_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{
        "es04c-idem-01", "es04c-idem-02", "es04c-idem-03",
        "es04c-idem-04", "es04c-idem-05",
    });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    var results: [5]AppendResult = undefined;
    const keys = [5][]const u8{
        "es04c-idem-01", "es04c-idem-02", "es04c-idem-03",
        "es04c-idem-04", "es04c-idem-05",
    };
    for (&results, 0..) |*r, i| {
        r.* = try store.append(alloc, AppendParams{
            .instance_id = inst_uuid,
            .event_type = "ES04C_TYPE",
            .payload = "{}",
            .actor_id = actor_uuid,
            .idempotency_key = keys[i],
            .metadata = null,
        });
    }

    // Use global_seq of 3rd event as cursor → should get events 4 and 5.
    const cursor = results[2].record.global_seq;
    const events = try store.readGlobal(alloc, GlobalReadOpts{
        .after_global_seq = cursor,
        .limit = 100,
    });
    defer {
        for (events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(events);
    }

    // Must include at least 2 events (the 4th and 5th we just appended).
    try std.testing.expect(events.len >= 2);
    for (events) |ev| {
        try std.testing.expect(ev.global_seq > cursor);
    }
}

// ---------------------------------------------------------------------------
// ES-05: Event type registry (integration portion)
// ---------------------------------------------------------------------------

// TC-ES-05-01 (integration)
// An unregistered event_type causes Store.append() to return UnknownEventType
// before any DB write.
test "TC-ES-05-01: append with unregistered event_type returns UnknownEventType" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Intentionally do NOT register any type.
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    const err = store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TOTALLY_UNKNOWN",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es05-idem-unknown",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.UnknownEventType, err);

    // No events row must have been inserted.
    const check = try pool.acquire();
    defer pool.release(check);
    var cnt = try check.query(alloc, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{"es05-idem-unknown"});
    defer cnt.deinit();
    if (cnt.rows.len > 0) {
        if (cnt.rows[0][0]) |s| {
            const n = try std.fmt.parseInt(i64, s, 10);
            try std.testing.expectEqual(@as(i64, 0), n);
        }
    }
}

// TC-ES-05-02 (integration) — ISS-0155 / GH #473
//
// ES-05: "GIVEN event type T is registered, WHEN a caller appends a payload
// that fails the registered schema, THEN the platform returns HTTP 422 ...
// listing every validation failure (field path, constraint violated, actual
// value)." The mapped store-level error is PayloadSchemaInvalid.
//
// This is the DB half of the fix and the ONLY level that can catch the second
// half of the ISS-0155 defect: Registry.getType used to return a placeholder
// with json_schema hardcoded to "{}", so even a correct validatePayload would
// have validated every payload against the empty schema. The pure
// schema-vs-payload decision is unit-tested in tests/unit/event_store_test.zig
// (TC-ES-05-02a..g); what is asserted HERE is that the schema actually stored
// in event_type_registry is the one enforced.
//
// Fixture isolation: per-test UUIDs and a per-test event type name, so this
// test does not collide with any sibling binary sharing BPM_TEST_DB_URL.
test "TC-ES-05-02: append with payload failing registered schema returns PayloadSchemaInvalid" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Per-test unique identifiers (ISS-0113: never reuse deterministic keys in
    // a shared test database).
    const suffix = try h.newUuidString(alloc);
    defer alloc.free(suffix);
    const type_name = try std.fmt.allocPrint(alloc, "ES05_SCHEMA_{s}", .{suffix[0..8]});
    defer alloc.free(type_name);
    const idem_ok = try std.fmt.allocPrint(alloc, "es05-schema-ok-{s}", .{suffix});
    defer alloc.free(idem_ok);
    const idem_bad = try std.fmt.allocPrint(alloc, "es05-schema-bad-{s}", .{suffix});
    defer alloc.free(idem_bad);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    // A schema with real constraints — NOT "{}". If getType ever regresses to
    // returning a placeholder empty schema, the reject case below stops failing.
    _ = try registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema =
        \\{"type":"object","required":["order_id","amount"],"properties":{"order_id":{"type":"string"},"amount":{"type":"integer","minimum":1}}}
        ,
        .description = null,
    });
    defer cleanupEventType(&pool, type_name);

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    // A fresh random UUID, not a fixed literal — the shared test database is
    // written concurrently by sibling binaries (ISS-0113).
    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ idem_ok, idem_bad });

    const actor_str = try h.newUuidString(alloc);
    defer alloc.free(actor_str);
    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, actor_str);

    // ── Direction 1: a CONFORMING payload is accepted and persisted ──────────
    // Without this half, "reject everything" would satisfy the reject case.
    const ok_result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = type_name,
        .payload =
        \\{"order_id":"ord-1","amount":250}
        ,
        .actor_id = actor_uuid,
        .idempotency_key = idem_ok,
        .metadata = null,
    });
    try std.testing.expect(!ok_result.is_duplicate);

    // ── Direction 2: a NON-CONFORMING payload is rejected ────────────────────
    // "amount" violates minimum, and "order_id" is missing entirely. Both are
    // valid JSON objects, so the pre-ISS-0155 is-object-only check accepted
    // them; only real schema enforcement rejects them.
    const err = store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = type_name,
        .payload =
        \\{"amount":0}
        ,
        .actor_id = actor_uuid,
        .idempotency_key = idem_bad,
        .metadata = null,
    });
    try std.testing.expectError(StoreError.PayloadSchemaInvalid, err);

    // ES-05 requires the per-field detail behind the 422, not just the status.
    const failures = registry.lastValidationFailures();
    try std.testing.expectEqual(@as(usize, 2), failures.len);
    try std.testing.expectEqualStrings("/order_id", failures[0].field_path);
    try std.testing.expectEqualStrings("required", failures[0].constraint);
    try std.testing.expectEqualStrings("null", failures[0].actual);
    try std.testing.expectEqualStrings("/amount", failures[1].field_path);
    try std.testing.expectEqualStrings("minimum", failures[1].constraint);
    try std.testing.expectEqualStrings("0", failures[1].actual);

    // The rejected append must not have written an events row.
    const check = try pool.acquire();
    defer pool.release(check);
    var cnt = try check.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE idempotency_key = $1",
        &.{idem_bad},
    );
    defer cnt.deinit();
    try std.testing.expect(cnt.rows.len > 0);
    if (cnt.rows[0][0]) |s| {
        try std.testing.expectEqual(@as(i64, 0), try std.fmt.parseInt(i64, s, 10));
    }
}

// ---------------------------------------------------------------------------
// ES-06: Point-in-time query
// ---------------------------------------------------------------------------

// TC-ES-06-01
// Store.pointInTime() returns only events whose created_at <= the given timestamp.
test "TC-ES-06-01: pointInTime filters out events created after the timestamp" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES06_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{
        "es06-idem-01", "es06-idem-02", "es06-idem-03",
    });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES06_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es06-idem-01",
        .metadata = null,
    });
    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES06_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es06-idem-02",
        .metadata = null,
    });

    // Capture the cutoff from the DB clock (not the client clock) to avoid
    // host/container clock skew.  pg_sleep(0.01) then advances the server
    // wall clock by 10 ms so that event 3's DB-assigned created_at is
    // strictly after the cutoff, regardless of OS scheduling granularity.
    var cutoff: i64 = 0;
    {
        const tc_conn = try pool.acquire();
        defer pool.release(tc_conn);
        var ts_rows = try tc_conn.query(
            alloc,
            "SELECT (EXTRACT(EPOCH FROM NOW()) * 1000000)::bigint",
            &.{},
        );
        defer ts_rows.deinit();
        if (ts_rows.rows.len > 0 and ts_rows.rows[0].len > 0) {
            if (ts_rows.rows[0][0]) |s| {
                cutoff = try std.fmt.parseInt(i64, s, 10);
            }
        }
        // Advance server clock; event 3 will receive a created_at > cutoff.
        try tc_conn.exec("SELECT pg_sleep(0.01)", &.{});
    }

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES06_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es06-idem-03",
        .metadata = null,
    });

    const events = try store.pointInTime(alloc, inst_uuid, cutoff);
    defer {
        for (events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(events);
    }

    // Only events 1 and 2 should appear (event 3 was appended after cutoff).
    try std.testing.expect(events.len <= 2);
    for (events) |ev| {
        try std.testing.expect(ev.created_at <= cutoff);
    }
}

// TC-ES-06-02
// Store.read() with up_to_sequence = K returns exactly events 1..K.
test "TC-ES-06-02: read with up_to_sequence returns exactly events 1..K" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES06B_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{
        "es06b-idem-01", "es06b-idem-02", "es06b-idem-03",
        "es06b-idem-04", "es06b-idem-05",
    });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    const idem_keys = [5][]const u8{
        "es06b-idem-01", "es06b-idem-02", "es06b-idem-03",
        "es06b-idem-04", "es06b-idem-05",
    };
    for (idem_keys) |key| {
        _ = try store.append(alloc, AppendParams{
            .instance_id = inst_uuid,
            .event_type = "ES06B_TYPE",
            .payload = "{}",
            .actor_id = actor_uuid,
            .idempotency_key = key,
            .metadata = null,
        });
    }

    const events = try store.read(alloc, inst_uuid, ReadOpts{
        .up_to_sequence = 3,
        .up_to_timestamp = null,
    });
    defer {
        for (events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(events);
    }

    try std.testing.expectEqual(@as(usize, 3), events.len);
    for (events, 0..) |ev, i| {
        try std.testing.expectEqual(@as(i64, @intCast(i + 1)), ev.sequence_number);
    }
}

// ---------------------------------------------------------------------------
// ES-07: Retention / archival
// ---------------------------------------------------------------------------

// TC-ES-07-01
// Store.archive() with retention_days = 0 and a matching policy moves events
// to events_archive.  We set up a keep_days = 0 policy and verify the move.
test "TC-ES-07-01: archive moves expired events to events_archive" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES07_ARCHIVE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"es07-idem-01"});
    defer {
        if (pool.acquire()) |c| {
            c.exec("DELETE FROM events_archive WHERE idempotency_key = $1", &.{"es07-idem-01"}) catch {};
            c.exec("DELETE FROM event_retention_policies WHERE event_type = $1", &.{"ES07_ARCHIVE"}) catch {};
            pool.release(c);
        } else |_| {}
    }

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES07_ARCHIVE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es07-idem-01",
        .metadata = null,
    });

    // Insert a retention policy that expires everything immediately (keep_days = 0).
    const policy_conn = try pool.acquire();
    try policy_conn.exec(
        "INSERT INTO event_retention_policies (event_type, policy, keep_days) " ++
            "VALUES ($1, 'keep_days', '0') ON CONFLICT DO NOTHING",
        &.{"ES07_ARCHIVE"},
    );
    pool.release(policy_conn);

    _ = try store.archive(alloc, 0);

    // Verify the event is now in events_archive.
    const check = try pool.acquire();
    defer pool.release(check);
    var arc = try check.query(alloc, "SELECT COUNT(*) FROM events_archive WHERE idempotency_key = $1", &.{"es07-idem-01"});
    defer arc.deinit();
    if (arc.rows.len > 0) {
        if (arc.rows[0][0]) |s| {
            const n = try std.fmt.parseInt(i64, s, 10);
            try std.testing.expect(n >= 1);
        }
    }
}

// ---------------------------------------------------------------------------
// ADP-11: Replay-safe retention policy
// ---------------------------------------------------------------------------

test "TC-ADP-11-01: protected family rejects hard-delete policy deterministically" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    try std.testing.expectError(
        StoreError.ProtectedFamilyHardDeleteForbidden,
        store.upsertRetentionPolicy(alloc, RetentionPolicyUpsertParams{
            .event_type = "INSTANCE_STARTED",
            .policy = RetentionPolicyMode.hard_delete_days,
            .keep_days = 0,
        }),
    );

    const violation = bpm.store.retentionPolicyViolation("INSTANCE_STARTED", RetentionPolicyMode.hard_delete_days) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("RETENTION_POLICY_PROTECTED_FAMILY_HARD_DELETE_FORBIDDEN", violation.code);
    try std.testing.expectEqualStrings("HARD_DELETE_NOT_ALLOWED_FOR_PROTECTED_FAMILY", violation.reason);
    try std.testing.expectEqualStrings("INSTANCE_*", violation.event_family);
    try std.testing.expectEqualStrings("hard_delete_days", violation.requested_mode);
    try std.testing.expectEqualStrings("keep_forever", violation.allowed_modes[0]);
    try std.testing.expectEqualStrings("keep_days", violation.allowed_modes[1]);
    try std.testing.expectEqualStrings("keep_count", violation.allowed_modes[2]);

    const maybe_code = bpm.store.retentionPolicyErrorCode(StoreError.ProtectedFamilyHardDeleteForbidden);
    try std.testing.expect(maybe_code != null);
    try std.testing.expectEqualStrings("RETENTION_POLICY_PROTECTED_FAMILY_HARD_DELETE_FORBIDDEN", maybe_code.?);
}

test "TC-ADP-11-02: non-protected families retain hard-delete configurability" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ADP11_AUDIT_EVENT",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"adp11-idem-01"});
    defer {
        if (pool.acquire()) |c| {
            c.exec("DELETE FROM event_retention_policies WHERE event_type = $1", &.{"ADP11_AUDIT_EVENT"}) catch {};
            c.exec("DELETE FROM events_archive WHERE idempotency_key = $1", &.{"adp11-idem-01"}) catch {};
            c.exec("DELETE FROM events WHERE idempotency_key = $1", &.{"adp11-idem-01"}) catch {};
            pool.release(c);
        } else |_| {}
    }

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ADP11_AUDIT_EVENT",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp11-idem-01",
        .metadata = null,
    });

    try store.upsertRetentionPolicy(alloc, RetentionPolicyUpsertParams{
        .event_type = "ADP11_AUDIT_EVENT",
        .policy = RetentionPolicyMode.hard_delete_days,
        .keep_days = 0,
    });

    _ = try store.archive(alloc, 0);

    const check = try pool.acquire();
    defer pool.release(check);

    var live_rows = try check.query(alloc, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{"adp11-idem-01"});
    defer live_rows.deinit();
    var archive_rows = try check.query(alloc, "SELECT COUNT(*) FROM events_archive WHERE idempotency_key = $1", &.{"adp11-idem-01"});
    defer archive_rows.deinit();

    if (live_rows.rows.len == 0 or archive_rows.rows.len == 0) {
        try std.testing.expect(false);
        return;
    }

    const live_count = try std.fmt.parseInt(i64, live_rows.rows[0][0] orelse "-1", 10);
    const archive_count = try std.fmt.parseInt(i64, archive_rows.rows[0][0] orelse "-1", 10);

    try std.testing.expectEqual(@as(i64, 0), live_count);
    try std.testing.expectEqual(@as(i64, 0), archive_count);
}

test "TC-ADP-11-03: protected keep_days policy archives and preserves queryability" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "INSTANCE_STARTED",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"adp11-idem-02"});
    defer {
        if (pool.acquire()) |c| {
            c.exec("DELETE FROM event_retention_policies WHERE event_type = $1", &.{"INSTANCE_STARTED"}) catch {};
            pool.release(c);
        } else |_| {}
    }

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    // ISS-0155: INSTANCE_STARTED's registered schema (migrations/
    // 002_event_type_registry.sql) requires "definition_id". This payload used
    // to be "{}", which passed only because ES-05 schema enforcement was a
    // no-op. The payload is now made to conform rather than the enforcement
    // weakened — this test is about retention policy, not about schema
    // validation, so a conforming payload is the correct fixture.
    // Built from def_str (the definition this instance was actually seeded
    // with) rather than a second, unrelated UUID literal.
    const started_payload = try std.fmt.allocPrint(
        alloc,
        "{{\"definition_id\":\"{s}\"}}",
        .{def_str},
    );
    defer alloc.free(started_payload);

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "INSTANCE_STARTED",
        .payload = started_payload,
        .actor_id = actor_uuid,
        .idempotency_key = "adp11-idem-02",
        .metadata = null,
    });

    try store.upsertRetentionPolicy(alloc, RetentionPolicyUpsertParams{
        .event_type = "INSTANCE_STARTED",
        .policy = RetentionPolicyMode.keep_days,
        .keep_days = 0,
    });

    _ = try store.archive(alloc, 0);

    const check = try pool.acquire();
    defer pool.release(check);

    var live_rows = try check.query(alloc, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{"adp11-idem-02"});
    defer live_rows.deinit();
    var archive_rows = try check.query(alloc, "SELECT COUNT(*) FROM events_archive WHERE idempotency_key = $1", &.{"adp11-idem-02"});
    defer archive_rows.deinit();

    if (live_rows.rows.len == 0 or archive_rows.rows.len == 0) {
        try std.testing.expect(false);
        return;
    }

    const live_count = try std.fmt.parseInt(i64, live_rows.rows[0][0] orelse "-1", 10);
    const archive_count = try std.fmt.parseInt(i64, archive_rows.rows[0][0] orelse "-1", 10);

    try std.testing.expectEqual(@as(i64, 0), live_count);
    try std.testing.expectEqual(@as(i64, 1), archive_count);
}

// ---------------------------------------------------------------------------
// ES-08: Event metadata (integration portion)
// ---------------------------------------------------------------------------

// TC-ES-08-04
// Appending with metadata = null should return a record with metadata = "{}".
test "TC-ES-08-04: absent metadata field defaults to empty object in returned record" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ES08_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"es08-idem-01"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    const result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES08_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es08-idem-01",
        .metadata = null,
    });

    // metadata must be "{}" (the empty JSON object), never null.
    try std.testing.expectEqualStrings("{}", result.record.metadata);
}

// ---------------------------------------------------------------------------
// ADP-01: Tenant scope on event store (integration)
// ---------------------------------------------------------------------------

test "TC-ADP-01-01: default-tenant behavior remains backward compatible" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ADP01_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"adp01-default-idem-01"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ADP01_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp01-default-idem-01",
        .metadata = null,
    });

    const legacy_read = try store.read(alloc, inst_uuid, ReadOpts{
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer {
        for (legacy_read) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(legacy_read);
    }

    const explicit_default = try store.read(alloc, inst_uuid, ReadOpts{
        .tenant_id = bpm.store.DEFAULT_TENANT_ID,
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer {
        for (explicit_default) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(explicit_default);
    }

    try std.testing.expectEqual(@as(usize, 1), legacy_read.len);
    try std.testing.expectEqual(@as(usize, 1), explicit_default.len);
}

test "TC-ADP-01-02: tenant-scoped reads isolate events by tenant_id" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ADP01_ISO_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "adp01-iso-idem-default", "adp01-iso-idem-alt" });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();
    const alt_tenant = try h.newUuidString(alloc);
    defer alloc.free(alt_tenant);

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ADP01_ISO_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp01-iso-idem-default",
        .metadata = null,
    });

    _ = try store.append(alloc, AppendParams{
        .tenant_id = alt_tenant,
        .instance_id = inst_uuid,
        .event_type = "ADP01_ISO_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp01-iso-idem-alt",
        .metadata = null,
    });

    const default_events = try store.read(alloc, inst_uuid, ReadOpts{
        .tenant_id = bpm.store.DEFAULT_TENANT_ID,
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer {
        for (default_events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(default_events);
    }

    const alt_events = try store.read(alloc, inst_uuid, ReadOpts{
        .tenant_id = alt_tenant,
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer {
        for (alt_events) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(alt_events);
    }

    try std.testing.expectEqual(@as(usize, 1), default_events.len);
    try std.testing.expectEqual(@as(usize, 1), alt_events.len);
}

test "TC-ADP-01-03: migration provisions tenant columns/defaults and tenant indexes" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const cols = try conn.query(
        alloc,
        \\SELECT table_name, is_nullable, column_default
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND column_name = 'tenant_id'
        \\  AND table_name IN ('events', 'events_archive')
        \\ORDER BY table_name ASC
    ,
        &.{},
    );
    defer {
        var mr = cols;
        mr.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), cols.rows.len);

    for (cols.rows) |row| {
        const nullable = row[1] orelse "";
        const default_expr = row[2] orelse "";
        try std.testing.expectEqualStrings("NO", nullable);
        try std.testing.expect(std.mem.indexOf(u8, default_expr, bpm.store.DEFAULT_TENANT_ID) != null);
    }

    const idx = try conn.query(
        alloc,
        \\SELECT indexname
        \\FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND indexname IN (
        \\      'idx_events_tenant_instance_seq',
        \\      'idx_events_tenant_global_seq',
        \\      'idx_events_archive_tenant_instance_seq',
        \\      'idx_events_archive_tenant_global_seq'
        \\  )
        \\ORDER BY indexname ASC
    ,
        &.{},
    );
    defer {
        var mr = idx;
        mr.deinit();
    }

    try std.testing.expectEqual(@as(usize, 4), idx.rows.len);
    try std.testing.expectEqualStrings("idx_events_archive_tenant_global_seq", idx.rows[0][0] orelse "");
    try std.testing.expectEqualStrings("idx_events_archive_tenant_instance_seq", idx.rows[1][0] orelse "");
    try std.testing.expectEqualStrings("idx_events_tenant_global_seq", idx.rows[2][0] orelse "");
    try std.testing.expectEqualStrings("idx_events_tenant_instance_seq", idx.rows[3][0] orelse "");
}

test "TC-ADP-01-04: append rejects empty tenant context deterministically" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ADP01_ERR_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"adp01-missing-tenant-idem"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    try std.testing.expectError(StoreError.MissingTenantContext, store.append(alloc, AppendParams{
        .tenant_id = "",
        .instance_id = inst_uuid,
        .event_type = "ADP01_ERR_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp01-missing-tenant-idem",
        .metadata = null,
    }));

    const check_conn = try pool.acquire();
    defer pool.release(check_conn);

    var cnt = try check_conn.query(
        alloc,
        "SELECT COUNT(*) FROM events WHERE idempotency_key = $1",
        &.{"adp01-missing-tenant-idem"},
    );
    defer cnt.deinit();
    const live_count = std.fmt.parseInt(i64, cnt.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 0), live_count);

    var arc = try check_conn.query(
        alloc,
        "SELECT COUNT(*) FROM events_archive WHERE idempotency_key = $1",
        &.{"adp01-missing-tenant-idem"},
    );
    defer arc.deinit();
    const archive_count = std.fmt.parseInt(i64, arc.rows[0][0] orelse "0", 10) catch 0;
    try std.testing.expectEqual(@as(i64, 0), archive_count);
}

// ---------------------------------------------------------------------------
// TC-ES-01-05: append with nil actor_id returns ActorIdMissing
// ---------------------------------------------------------------------------

test "TC-ES-01-05: append with nil actor_id returns ActorIdMissing" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_uuid = h.newUuid();
    var nil_actor: [16]u8 = undefined;
    @memset(&nil_actor, 0);

    try std.testing.expectError(StoreError.ActorIdMissing, store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "SOME_TYPE",
        .payload = "{}",
        .actor_id = nil_actor,
        .idempotency_key = "es01-05-idem",
        .metadata = null,
    }));
}

// ---------------------------------------------------------------------------
// TC-ES-01-06: append with array payload returns PayloadInvalid
// ---------------------------------------------------------------------------

test "TC-ES-01-06: append with array payload returns PayloadInvalid" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_uuid = h.newUuid();
    const actor_uuid = h.newUuid();

    try std.testing.expectError(StoreError.PayloadInvalid, store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "SOME_TYPE",
        .payload = "[1,2,3]",
        .actor_id = actor_uuid,
        .idempotency_key = "es01-06-idem",
        .metadata = null,
    }));
}

// ---------------------------------------------------------------------------
// TC-ES-03-02: append with empty idempotency_key returns IdempotencyKeyMissing
// ---------------------------------------------------------------------------

test "TC-ES-03-02: append with empty idempotency_key returns IdempotencyKeyMissing" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_uuid = h.newUuid();
    const actor_uuid = h.newUuid();

    try std.testing.expectError(StoreError.IdempotencyKeyMissing, store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "SOME_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "",
        .metadata = null,
    }));
}

// ---------------------------------------------------------------------------
// TC-ES-03-03: append with 256-char idempotency_key returns IdempotencyKeyTooLong
// ---------------------------------------------------------------------------

test "TC-ES-03-03: append with 256-char idempotency_key returns IdempotencyKeyTooLong" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_uuid = h.newUuid();
    const actor_uuid = h.newUuid();

    var long_key_arr: [256]u8 = undefined;
    @memset(&long_key_arr, 'x');
    const long_key: []const u8 = &long_key_arr;

    try std.testing.expectError(StoreError.IdempotencyKeyTooLong, store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "SOME_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = long_key,
        .metadata = null,
    }));
}

// ---------------------------------------------------------------------------
// TC-ES-01-02: append to a non-existent instance returns InstanceNotFound
//
// ES-01 acceptance criterion: "instance_id MUST reference an existing process
// instance; if the instance does not exist, the platform returns HTTP 404."
// StoreError.InstanceNotFound is the store-layer expression of that 404.
//
// The event type is registered first because Store.append() runs ES-05 registry
// validation BEFORE the instance lookup — without a registered type the call
// would fail with UnknownEventType and never reach the path under test.
// ---------------------------------------------------------------------------

test "TC-ES-01-02: append to non-existent instance returns InstanceNotFound" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Per-test unique names/keys (T010): nothing here is shared with any other
    // test or any earlier run of this test.
    const type_name = try uniqueName(alloc, &h, "ES0102");
    defer alloc.free(type_name);
    const idem_key = try uniqueName(alloc, &h, "es01-02");
    defer alloc.free(idem_key);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    defer cleanupEventType(&pool, type_name);
    _ = registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    // Deliberately NOT inserted into instance_projections.
    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const actor_str = try h.newUuidString(alloc);
    defer alloc.free(actor_str);
    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, actor_str);

    // Cleanup is unconditional: registered before the assertion so that an
    // unexpected successful append still gets torn down.
    defer cleanupInstance(&pool, inst_str, &.{idem_key});

    // Precondition: the instance really is absent.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var pre = try conn.query(
            alloc,
            "SELECT COUNT(*) FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_str},
        );
        defer pre.deinit();
        const n = std.fmt.parseInt(i64, pre.rows[0][0] orelse "0", 10) catch -1;
        try std.testing.expectEqual(@as(i64, 0), n);
    }

    try std.testing.expectError(StoreError.InstanceNotFound, store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = type_name,
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = idem_key,
        .metadata = null,
    }));

    // "no event row is inserted" — the rejection must not leave a partial write.
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, idem_key));
}

// ---------------------------------------------------------------------------
// TC-ES-01-03: append to a COMPLETED instance returns InstanceTerminated
//
// ES-01 acceptance criterion: "Appending an event to a CANCELLED or COMPLETED
// instance MUST be rejected with HTTP 409." StoreError.InstanceTerminated is
// the store-layer expression of that 409 (no HTTP route exposes event append
// yet, so the store boundary is the enforcement point).
// ---------------------------------------------------------------------------

test "TC-ES-01-03: append to COMPLETED instance returns InstanceTerminated" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const type_name = try uniqueName(alloc, &h, "ES0103");
    defer alloc.free(type_name);
    const idem_key = try uniqueName(alloc, &h, "es01-03");
    defer alloc.free(idem_key);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    defer cleanupEventType(&pool, type_name);
    _ = registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    const actor_str = try h.newUuidString(alloc);
    defer alloc.free(actor_str);

    defer cleanupInstance(&pool, inst_str, &.{idem_key});
    try insertInstanceWithStatus(&pool, inst_str, def_str, "COMPLETED");

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, actor_str);

    try std.testing.expectError(StoreError.InstanceTerminated, store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = type_name,
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = idem_key,
        .metadata = null,
    }));

    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, idem_key));
}

// ---------------------------------------------------------------------------
// TC-ES-01-04: append to a CANCELLED instance returns InstanceTerminated
//
// Same ES-01 HTTP-409 acceptance criterion as TC-ES-01-03, exercising the
// CANCELLED half of the terminal-status check.
// ---------------------------------------------------------------------------

test "TC-ES-01-04: append to CANCELLED instance returns InstanceTerminated" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const type_name = try uniqueName(alloc, &h, "ES0104");
    defer alloc.free(type_name);
    const idem_key = try uniqueName(alloc, &h, "es01-04");
    defer alloc.free(idem_key);
    const active_key = try uniqueName(alloc, &h, "es01-04-active");
    defer alloc.free(active_key);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    defer cleanupEventType(&pool, type_name);
    _ = registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    const actor_str = try h.newUuidString(alloc);
    defer alloc.free(actor_str);

    defer cleanupInstance(&pool, inst_str, &.{idem_key});
    try insertInstanceWithStatus(&pool, inst_str, def_str, "CANCELLED");

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, actor_str);

    try std.testing.expectError(StoreError.InstanceTerminated, store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = type_name,
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = idem_key,
        .metadata = null,
    }));

    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, idem_key));

    // An ACTIVE instance is the control: the same append must succeed, proving
    // the rejection above is caused by the terminal status and not by the
    // fixture being unusable for some other reason.
    const active_str = try h.newUuidString(alloc);
    defer alloc.free(active_str);
    const active_def = try h.newUuidString(alloc);
    defer alloc.free(active_def);

    defer cleanupInstance(&pool, active_str, &.{active_key});
    try insertInstanceWithStatus(&pool, active_str, active_def, "ACTIVE");
    const active_uuid = try parseUuid(alloc, active_str);
    _ = try store.append(alloc, AppendParams{
        .instance_id = active_uuid,
        .event_type = type_name,
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = active_key,
        .metadata = null,
    });
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&pool, alloc, active_key));
}

// ---------------------------------------------------------------------------
// TC-ES-05-04: registerType with a duplicate (name, schema_version) returns
// DuplicateEventTypeVersion
//
// ES-05 acceptance criterion: "Registering a duplicate name+version combination
// MUST be rejected with HTTP 409." RegistryError.DuplicateEventTypeVersion is
// the registry-layer expression of that 409.
// ---------------------------------------------------------------------------

test "TC-ES-05-04: registerType with duplicate name+version returns DuplicateEventTypeVersion" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    // Per-test unique type name (T010): the name is the very thing under test,
    // so it must not be shared with any other test or earlier run.
    const type_name = try uniqueName(alloc, &h, "ES0504_DUP");
    defer alloc.free(type_name);
    // registerType() autocommits, so cleanup must be unconditional and is
    // registered before the first registration attempt.
    defer cleanupEventType(&pool, type_name);

    // First registration must succeed.
    _ = try registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    });

    // Second registration with the SAME name and SAME schema_version → 409.
    try std.testing.expectError(
        bpm.registry.RegistryError.DuplicateEventTypeVersion,
        registry.registerType(alloc, RegisterParams{
            .name = type_name,
            .schema_version = 1,
            .json_schema = "{\"type\":\"object\"}",
            .description = "second attempt",
        }),
    );

    // "no new row is inserted" — exactly one row for (name, version = 1).
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var res = try conn.query(
            alloc,
            "SELECT COUNT(*) FROM event_type_registry WHERE name = $1 AND schema_version = 1",
            &.{type_name},
        );
        defer res.deinit();
        const n = std.fmt.parseInt(i64, res.rows[0][0] orelse "0", 10) catch -1;
        try std.testing.expectEqual(@as(i64, 1), n);
    }

    // Control: a NEW schema_version of the same name is NOT a duplicate. This
    // proves the rejection keys on (name, version) and not on name alone.
    _ = try registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 2,
        .json_schema = "{}",
        .description = null,
    });
}

// ---------------------------------------------------------------------------
// TC-ES-07-02: archive returns the count of moved rows
//
// Spec (tests/specs/ES-01-08.md): GIVEN an events table with exactly 3 expired
// events and 2 non-expired events, WHEN Store.archive() is called, THEN it
// returns exactly 3 and the 2 non-expired events remain in events.
//
// Five events are appended through the real Store, then three are backdated
// past the keep_days boundary via SQL (Store.append always stamps created_at =
// NOW(), so ageing has to be simulated at the row level).
// ---------------------------------------------------------------------------

test "TC-ES-07-02: archive returns count of moved rows and leaves non-expired events" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Per-test unique event type: archive() is driven by a per-event_type
    // retention policy, so a shared name would let concurrent tests archive
    // each other's rows and make the returned count non-deterministic (T010).
    const type_name = try uniqueName(alloc, &h, "ES0702_COUNT");
    defer alloc.free(type_name);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    defer cleanupEventType(&pool, type_name);
    _ = registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    const actor_str = try h.newUuidString(alloc);
    defer alloc.free(actor_str);

    var keys: [5][]const u8 = undefined;
    var allocated: usize = 0;
    defer for (keys[0..allocated]) |k| alloc.free(k);
    for (0..5) |i| {
        const label = if (i < 3) "es07-02-old" else "es07-02-new";
        keys[i] = try uniqueName(alloc, &h, label);
        allocated += 1;
    }

    // Unconditional cleanup: events, events_archive, instance rows, policy.
    defer cleanupInstance(&pool, inst_str, &keys);
    defer {
        if (pool.acquire()) |c| {
            for (keys) |k| {
                c.exec("DELETE FROM events_archive WHERE idempotency_key = $1", &.{k}) catch {};
            }
            c.exec("DELETE FROM event_retention_policies WHERE event_type = $1", &.{type_name}) catch {};
            pool.release(c);
        } else |_| {}
    }

    try insertInstance(&pool, inst_str, def_str);

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, actor_str);

    for (keys) |k| {
        _ = try store.append(alloc, AppendParams{
            .instance_id = inst_uuid,
            .event_type = type_name,
            .payload = "{}",
            .actor_id = actor_uuid,
            .idempotency_key = k,
            .metadata = null,
        });
    }

    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        // Age the three "old" events 10 days into the past; the two "new" ones
        // stay at NOW() and must survive a keep_days = 1 policy.
        try conn.exec(
            "UPDATE events SET created_at = NOW() - INTERVAL '10 days' " ++
                "WHERE idempotency_key IN ($1, $2, $3)",
            &.{ keys[0], keys[1], keys[2] },
        );

        try conn.exec(
            "INSERT INTO event_retention_policies (event_type, policy, keep_days) " ++
                "VALUES ($1, 'keep_days', '1') " ++
                "ON CONFLICT (event_type) DO UPDATE SET policy = 'keep_days', keep_days = '1'",
            &.{type_name},
        );
    }

    // Precondition: all five events are live before archival.
    var live_before: i64 = 0;
    for (keys) |k| live_before += try countEvents(&pool, alloc, k);
    try std.testing.expectEqual(@as(i64, 5), live_before);

    const moved = try store.archive(alloc, 0);

    // The three expired events left `events` …
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, keys[0]));
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, keys[1]));
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, keys[2]));

    // … and the two non-expired events are untouched.
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&pool, alloc, keys[3]));
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&pool, alloc, keys[4]));

    // The three moved rows are retrievable from events_archive.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var arc = try conn.query(
            alloc,
            "SELECT COUNT(*) FROM events_archive WHERE idempotency_key IN ($1, $2, $3)",
            &.{ keys[0], keys[1], keys[2] },
        );
        defer arc.deinit();
        const n = std.fmt.parseInt(i64, arc.rows[0][0] orelse "0", 10) catch -1;
        try std.testing.expectEqual(@as(i64, 3), n);
    }

    // The core assertion of TC-ES-07-02: archive() reports the number of ROWS
    // it moved, not the number of policies it applied.
    //
    // archive() sweeps every policy in the table, so a concurrently running
    // test may legitimately contribute rows of its own type to this total —
    // hence >= rather than ==. The bound is still strong enough to be the
    // thing under test: the defect this guards against (counting policies)
    // returns 1 for this test's three expired rows, which fails here. The
    // "exactly three" half of the spec is asserted precisely above, scoped to
    // this test's own idempotency keys.
    try std.testing.expect(moved >= 3);

    // ES-07: "The archival operation MUST be idempotent." This test's rows are
    // all archived now, so a second sweep must not move them again, must not
    // touch the two non-expired rows, and must not duplicate the archived ones.
    _ = try store.archive(alloc, 0);
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, keys[0]));
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, keys[1]));
    try std.testing.expectEqual(@as(i64, 0), try countEvents(&pool, alloc, keys[2]));
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&pool, alloc, keys[3]));
    try std.testing.expectEqual(@as(i64, 1), try countEvents(&pool, alloc, keys[4]));
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        var arc = try conn.query(
            alloc,
            "SELECT COUNT(*) FROM events_archive WHERE idempotency_key IN ($1, $2, $3)",
            &.{ keys[0], keys[1], keys[2] },
        );
        defer arc.deinit();
        const n = std.fmt.parseInt(i64, arc.rows[0][0] orelse "0", 10) catch -1;
        try std.testing.expectEqual(@as(i64, 3), n);
    }
}
