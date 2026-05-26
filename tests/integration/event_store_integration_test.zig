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

const Registry = bpm.registry.Registry;
const RegisterParams = bpm.registry.RegisterParams;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Read BPM_TEST_DB_URL from the environment.
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

/// Create a Pool pointing to the test DB.
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

/// Parse a UUID string like "aabbccdd-0000-0000-0000-000000000001" into [16]u8.
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

    const inst_str = "e5010000-0001-0000-0000-000000000001";
    const def_str = "defdef00-0001-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"es01-idem-01"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000001");

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
    defer alloc.free(events);
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

    const inst_str = "e5020000-0002-0000-0000-000000000002";
    const def_str = "defdef00-0002-0000-0000-000000000002";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "es02-idem-01", "es02-idem-02" });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000002");

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

    const inst_str = "e5020000-0003-0000-0000-000000000003";
    const def_str = "defdef00-0003-0000-0000-000000000003";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "es02b-idem-01", "es02b-idem-02", "es02b-idem-03" });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000003");

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
    defer alloc.free(events);

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

    const inst_str = "e5030000-0003-0000-0000-000000000003";
    const def_str = "defdef00-0003-0000-0000-000000000003";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"es03-idem-001"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000004");

    const first = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES03_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es03-idem-001",
        .metadata = null,
    });
    try std.testing.expect(!first.is_duplicate);

    const second = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES03_TYPE",
        .payload = "{\"x\":99}",
        .actor_id = actor_uuid,
        .idempotency_key = "es03-idem-001",
        .metadata = null,
    });
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

    const inst_a = "e5040000-0004-0000-0000-00000000000a";
    const inst_b = "e5040000-0004-0000-0000-00000000000b";
    const def_a = "defdef00-0004-0000-0000-00000000000a";
    const def_b = "defdef00-0004-0000-0000-00000000000b";
    try insertInstance(&pool, inst_a, def_a);
    try insertInstance(&pool, inst_b, def_b);
    defer cleanupInstance(&pool, inst_a, &.{ "es04-idem-a1", "es04-idem-a2" });
    defer cleanupInstance(&pool, inst_b, &.{"es04-idem-b1"});

    const uuid_a = try parseUuid(alloc, inst_a);
    const uuid_b = try parseUuid(alloc, inst_b);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000005");

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
    defer alloc.free(events);

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

    const inst_str = "e504c0b0-0004-0000-0000-000000000004";
    const def_str = "defdef00-0004-0000-0000-000000000004";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{
        "es04c-idem-01", "es04c-idem-02", "es04c-idem-03",
        "es04c-idem-04", "es04c-idem-05",
    });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000006");

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
    defer alloc.free(events);

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

    const inst_str = "e5050000-0005-0000-0000-000000000005";
    const def_str = "defdef00-0005-0000-0000-000000000005";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000007");

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

    const inst_str = "e5060000-0006-0000-0000-000000000006";
    const def_str = "defdef00-0006-0000-0000-000000000006";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{
        "es06-idem-01", "es06-idem-02", "es06-idem-03",
    });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000008");

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
    defer alloc.free(events);

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

    const inst_str = "e506b000-0006-0000-0000-000000000006";
    const def_str = "defdef00-0006-0000-0000-000000000006";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{
        "es06b-idem-01", "es06b-idem-02", "es06b-idem-03",
        "es06b-idem-04", "es06b-idem-05",
    });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000009");

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
    defer alloc.free(events);

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

    const inst_str = "e5070000-0007-0000-0000-000000000007";
    const def_str = "defdef00-0007-0000-0000-000000000007";
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
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000010");

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

    const inst_str = "e5080000-0008-0000-0000-000000000008";
    const def_str = "defdef00-0008-0000-0000-000000000008";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"es08-idem-01"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000011");

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

    const inst_str = "ad010000-0001-0000-0000-000000000001";
    const def_str = "defdef00-ad01-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"adp01-default-idem-01"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000021");

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
    defer alloc.free(legacy_read);

    const explicit_default = try store.read(alloc, inst_uuid, ReadOpts{
        .tenant_id = bpm.store.DEFAULT_TENANT_ID,
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer alloc.free(explicit_default);

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

    const inst_str = "ad010000-0002-0000-0000-000000000002";
    const def_str = "defdef00-ad01-0000-0000-000000000002";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "adp01-iso-idem-default", "adp01-iso-idem-alt" });

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000022");
    const alt_tenant = "11111111-1111-1111-1111-111111111111";

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
    defer alloc.free(default_events);

    const alt_events = try store.read(alloc, inst_uuid, ReadOpts{
        .tenant_id = alt_tenant,
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer alloc.free(alt_events);

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

    const inst_str = "ad010000-0004-0000-0000-000000000004";
    const def_str = "defdef00-ad01-0000-0000-000000000004";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{"adp01-missing-tenant-idem"});

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = try parseUuid(alloc, "acac0000-0000-0000-0000-000000000024");

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
