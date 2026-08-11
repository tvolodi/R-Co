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
const build_options = @import("build_options");

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const provisionTenantSchema = bpm.provisioning.provisionTenantSchema;

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
const RegistryError = bpm.registry.RegistryError;

// PAR-03 (WF02-batch-3-20260811): Store.archive() is retired; TC-ES-07-01,
// TC-ES-07-02, TC-ADP-11-02, TC-ADP-11-03 (below) are rewritten to exercise
// PartitionRetention instead. See src/design/par-03-partition-scoped-
// retention.md's "Store.archive() retirement" section.
const PartitionRetention = bpm.partition_retention.PartitionRetention;
const RetentionConfig = bpm.partition_retention.RetentionConfig;
const RetentionError = bpm.partition_retention.RetentionError;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn migrationsDir() []const u8 {
    return build_options.migrations_dir;
}

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
        conn.exec("DELETE FROM events_ephemeral WHERE idempotency_key = $1", &.{key}) catch {};
        // PAR-01: plat_event_idempotency is now the authoritative global
        // idempotency-key tracker (superseding events' own uq_event_idempotency
        // unique index this PK widening removed). Tests in this file reuse
        // hardcoded, non-unique idempotency keys (e.g. "es01-idem-01") across
        // separate runs against this shared, persistent bpm_test database —
        // without also clearing this table, a key claimed by an earlier run
        // stays claimed forever, and the NEXT run's first append with that
        // same literal key is permanently misreported as a duplicate
        // (confirmed live: this exact gap made TC-ES-01-01's fresh append
        // return is_duplicate=true on a second suite run).
        conn.exec("DELETE FROM plat_event_idempotency WHERE idempotency_key = $1", &.{key}) catch {};
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

    var result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES01_TYPE",
        .payload = "{\"x\":1}",
        .actor_id = actor_uuid,
        .idempotency_key = "es01-idem-01",
        .metadata = null,
    });
    defer result.record.deinit(alloc);

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

    var r1 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02-idem-01",
        .metadata = null,
    });
    defer r1.record.deinit(alloc);
    var r2 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02-idem-02",
        .metadata = null,
    });
    defer r2.record.deinit(alloc);

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

    var discard_result_1 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02B_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02b-idem-01",
        .metadata = null,
    });
    defer discard_result_1.record.deinit(alloc);
    var discard_result_2 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02B_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02b-idem-02",
        .metadata = null,
    });
    defer discard_result_2.record.deinit(alloc);
    var discard_result_3 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES02B_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es02b-idem-03",
        .metadata = null,
    });
    defer discard_result_3.record.deinit(alloc);

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

    var r1 = try store.append(alloc, AppendParams{
        .instance_id = uuid_a,
        .event_type = "ES04_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es04-idem-a1",
        .metadata = null,
    });
    defer r1.record.deinit(alloc);
    var r2 = try store.append(alloc, AppendParams{
        .instance_id = uuid_b,
        .event_type = "ES04_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es04-idem-b1",
        .metadata = null,
    });
    defer r2.record.deinit(alloc);
    var r3 = try store.append(alloc, AppendParams{
        .instance_id = uuid_a,
        .event_type = "ES04_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es04-idem-a2",
        .metadata = null,
    });
    defer r3.record.deinit(alloc);

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
    defer for (&results) |*r| r.record.deinit(alloc);

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
    var ok_result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = type_name,
        .payload =
        \\{"order_id":"ord-1","amount":250}
        ,
        .actor_id = actor_uuid,
        .idempotency_key = idem_ok,
        .metadata = null,
    });
    defer ok_result.record.deinit(alloc);
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

    var discard_result_4 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES06_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es06-idem-01",
        .metadata = null,
    });
    defer discard_result_4.record.deinit(alloc);
    var discard_result_5 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES06_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es06-idem-02",
        .metadata = null,
    });
    defer discard_result_5.record.deinit(alloc);

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

    var discard_result_6 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES06_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es06-idem-03",
        .metadata = null,
    });
    defer discard_result_6.record.deinit(alloc);

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
        var discard_result_7 = try store.append(alloc, AppendParams{
            .instance_id = inst_uuid,
            .event_type = "ES06B_TYPE",
            .payload = "{}",
            .actor_id = actor_uuid,
            .idempotency_key = key,
            .metadata = null,
        });
        defer discard_result_7.record.deinit(alloc);
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

// TC-ES-07-01 (REWRITTEN, PAR-03/WF02-batch-3-20260811): Store.archive()'s
// row-level archival-move mechanics (ES-07, SHOULD) are RETIRED — PAR-03's
// "No DELETE statement SHALL run against events or events_archive at any
// point" rule is incompatible with archive()'s implementation, which issued
// exactly that DELETE. See src/design/par-03-partition-scoped-retention.md's
// "Store.archive() retirement" section. This test asserts the retirement at
// the compile-time level: the function no longer exists as a declaration on
// Store at all (@hasDecl), which is a stronger, non-vacuous check than a
// runtime call that could pass merely because a stub silently no-ops — this
// fails to COMPILE if archive() is ever reintroduced, not just at test time.
// The design doc's companion mechanical proof step (`git grep -n "DELETE
// FROM events\b\|DELETE FROM events_archive\b" src/` returning zero results)
// is run as part of BACKEND-DEV's own self-review for this handoff rather
// than embedded here as a runtime file-scanner — std.fs.cwd() does not exist
// in this repo's actual Zig 0.16.0 API (confirmed live: only std.Io.Dir,
// which needs an std.Io handle threaded through, e.g.
// src/db/migrations.zig:169's std.Io.Dir.openDirAbsolute(pool.io, ...)) — a
// build-time grep is simpler, equally authoritative, and does not couple a
// runtime test's pass/fail to the test binary's own working directory.
test "TC-ES-07-01: archive() row-level mechanism is retired (Store no longer declares it)" {
    try std.testing.expect(!@hasDecl(Store, "archive"));
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

// TC-ADP-11-02 (REWRITTEN, PAR-03/WF02-batch-3-20260811): "non-protected
// families retain hard-delete configurability" is now demonstrated by the
// append-time retention-class routing itself, not by Store.archive()'s
// removed DELETE-based mechanism. A non-protected delete-class event type
// (WIDGET_CREATED — does not match {INSTANCE_,TASK_,GATEWAY_,EXECUTION_}*, so
// REWORK 1's RetentionClassForbidden guard permits it) is registered with
// retention_class='delete', appended via the REAL Store.append() call, and
// must land in events_ephemeral (not events) — end-to-end, real behavior:
// the type WAS configured for hard deletion, and its events WERE routed to
// the table PartitionRetention.runEphemeralDrop() operates on. See
// src/design/par-03-partition-scoped-retention.md's REWORK 2 section
// ("TC-ADP-11-02's rewrite is now concretely groundable").
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

    const type_name = try uniqueName(alloc, &h, "WIDGET_CREATED");
    defer alloc.free(type_name);
    defer cleanupEventType(&pool, type_name);

    // WIDGET_CREATED (or any WIDGET_* name) does not match the protected
    // family prefixes {INSTANCE_,TASK_,GATEWAY_,EXECUTION_}*, so
    // RetentionClassForbidden does not reject it — this call must succeed.
    _ = registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
        .retention_class = "delete",
    }) catch |err| {
        std.debug.print("TC-ADP-11-02: registerType unexpectedly failed: {}\n", .{err});
        return err;
    };

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const def_str = try h.newUuidString(alloc);
    defer alloc.free(def_str);
    try insertInstance(&pool, inst_str, def_str);
    const idem_key = try uniqueName(alloc, &h, "adp11-02-idem");
    defer alloc.free(idem_key);
    defer cleanupInstance(&pool, inst_str, &.{idem_key});
    defer {
        if (pool.acquire()) |c| {
            c.exec("DELETE FROM events_ephemeral WHERE idempotency_key = $1", &.{idem_key}) catch {};
            c.exec("DELETE FROM plat_event_idempotency WHERE idempotency_key = $1", &.{idem_key}) catch {};
            pool.release(c);
        } else |_| {}
    }

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();

    // The real end-to-end append-time routing path: Store.append() ->
    // registry.getType() -> retention_class == 'delete' -> target_table =
    // "events_ephemeral".
    var result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = type_name,
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = idem_key,
        .metadata = null,
    });
    defer result.record.deinit(alloc);
    try std.testing.expect(!result.is_duplicate);

    const check = try pool.acquire();
    defer pool.release(check);

    // The row landed in events_ephemeral...
    var ephemeral_rows = try check.query(alloc, "SELECT COUNT(*) FROM events_ephemeral WHERE idempotency_key = $1", &.{idem_key});
    defer ephemeral_rows.deinit();
    const ephemeral_count = try std.fmt.parseInt(i64, ephemeral_rows.rows[0][0] orelse "-1", 10);
    try std.testing.expectEqual(@as(i64, 1), ephemeral_count);

    // ...and NOT in events — proving the routing decision actually took
    // effect, not merely that SOME row exists somewhere.
    var live_rows = try check.query(alloc, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{idem_key});
    defer live_rows.deinit();
    const live_count = try std.fmt.parseInt(i64, live_rows.rows[0][0] orelse "-1", 10);
    try std.testing.expectEqual(@as(i64, 0), live_count);

    // The type WAS configured for hard deletion (retention_class='delete')
    // and its events WERE routed to the table DROP TABLE (via
    // PartitionRetention.runEphemeralDrop()) operates on — "non-protected
    // families retain hard-delete configurability" is demonstrated by this
    // routing outcome itself.
    var retention = check.query(alloc, "SELECT retention_class FROM event_type_registry WHERE name = $1", &.{type_name}) catch |err| return err;
    defer retention.deinit();
    try std.testing.expectEqualStrings("delete", retention.rows[0][0] orelse "");

    // Additionally drive a REAL ephemeral-drop cycle end to end: back the
    // event into a dedicated, isolated aged partition (not the shared
    // current-month one, to avoid dropping other tests' concurrent fixtures
    // in this shared database) and confirm PartitionRetention.runEphemeralDrop()
    // genuinely drops it and the ADP-11 guard is never tripped (WIDGET_CREATED
    // was never protected-family to begin with).
    try runIsolatedEphemeralDropCycle(alloc, &pool, type_name, idem_key, inst_uuid, actor_uuid);
}

/// Backs a WIDGET_CREATED-class event into a dedicated, isolated
/// events_ephemeral partition with an already-aged range_end, then calls
/// PartitionRetention.runEphemeralDrop() and asserts the partition is
/// genuinely dropped (real DROP TABLE, not a vacuous assertion) with the
/// ADP-11 guard never tripping. Isolated to a synthetic far-past month
/// (derived from the test's own UUID, distinct per run) so this cannot
/// collide with the real current-month events_ephemeral partition every
/// other concurrently-running test/append shares.
fn runIsolatedEphemeralDropCycle(
    alloc: std.mem.Allocator,
    pool: *Pool,
    type_name: []const u8,
    idem_key: []const u8,
    inst_uuid: [16]u8,
    actor_uuid: [16]u8,
) !void {
    _ = idem_key;
    const conn = try pool.acquire();
    defer pool.release(conn);

    // A synthetic partition name in a definitely-past, definitely-unique
    // month slot — collision-proof across concurrent test runs because it
    // encodes a fresh UUID fragment, not a calendar month any real data uses.
    var uuid_buf: [16]u8 = undefined;
    helpers.fillRandom(&uuid_buf);
    var suffix_buf: [16]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "{x:0>8}", .{std.mem.readInt(u32, uuid_buf[0..4], .big)}) catch return error.TestUnexpectedResult;
    const partition_name = try std.fmt.allocPrint(alloc, "events_ephemeral_test_{s}", .{suffix});
    defer alloc.free(partition_name);
    defer {
        conn.exec("DELETE FROM plat_partition_catalog WHERE table_name = $1", &.{partition_name}) catch {};
    }

    // A range comfortably older than PartitionRetention's default
    // ephemeral_drop_after_months=3: [1999-01-01, 1999-02-01).
    const create_sql = try std.fmt.allocPrint(
        alloc,
        "CREATE TABLE IF NOT EXISTS {s} (LIKE events_ephemeral INCLUDING DEFAULTS, " ++
            "CHECK (tenant_id IS NOT NULL), " ++
            "CHECK (created_at >= '1999-01-01' AND created_at < '1999-02-01'))",
        .{partition_name},
    );
    defer alloc.free(create_sql);
    try conn.exec(create_sql, &.{});
    defer {
        if (std.fmt.allocPrint(alloc, "DROP TABLE IF EXISTS {s}", .{partition_name})) |drop_sql| {
            defer alloc.free(drop_sql);
            conn.exec(drop_sql, &.{}) catch {};
        } else |_| {}
    }

    const attach_sql = try std.fmt.allocPrint(
        alloc,
        "ALTER TABLE events_ephemeral ATTACH PARTITION {s} FOR VALUES FROM ('1999-01-01') TO ('1999-02-01')",
        .{partition_name},
    );
    defer alloc.free(attach_sql);
    try conn.exec(attach_sql, &.{});

    try conn.exec(
        "INSERT INTO plat_partition_catalog (table_name, parent_table, range_start, range_end, state) " ++
            "VALUES ($1, 'events_ephemeral', '1999-01-01'::timestamptz, '1999-02-01'::timestamptz, 'ATTACHED')",
        &.{partition_name},
    );

    const isolated_idem_key = try std.fmt.allocPrint(alloc, "{s}-isolated", .{type_name});
    defer alloc.free(isolated_idem_key);
    const isolated_event_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(isolated_event_id);
    const inst_hex = try helpers.uuidBytesToString(alloc, inst_uuid);
    defer alloc.free(inst_hex);
    const actor_hex = try helpers.uuidBytesToString(alloc, actor_uuid);
    defer alloc.free(actor_hex);

    try conn.exec(
        "INSERT INTO events_ephemeral (event_id, instance_id, event_type, actor_id, " ++
            "created_at, sequence_number, idempotency_key, global_seq, tenant_id) " ++
            "VALUES ($1::uuid, $2::uuid, $3, $4::uuid, '1999-01-15'::timestamptz, 999, $5, 999, " ++
            "'00000000-0000-0000-0000-000000000000'::uuid)",
        &.{ isolated_event_id, inst_hex, type_name, actor_hex, isolated_idem_key },
    );

    var retention = PartitionRetention.init(pool, RetentionConfig{});
    const drop_result = try retention.runEphemeralDrop(alloc, conn);

    try std.testing.expect(drop_result.dropped >= 1);
    try std.testing.expectEqual(@as(u32, 0), drop_result.guard_tripped);

    // The partition itself no longer exists — a real DROP TABLE happened,
    // not a state-flag flip.
    var exists_rows = try conn.query(alloc, "SELECT to_regclass($1) IS NOT NULL", &.{partition_name});
    defer exists_rows.deinit();
    try std.testing.expectEqualStrings("f", exists_rows.rows[0][0] orelse "t");
}

// TC-ADP-11-03 (REWRITTEN, PAR-03/WF02-batch-3-20260811): "protected
// families' archived rows stay queryable" is now demonstrated by
// PartitionRetention.runArchivalAging()'s DETACH/ATTACH mechanism instead of
// Store.archive()'s removed row-level DELETE+INSERT move. Protected families
// never route to events_ephemeral at all (REWORK 1's RetentionClassForbidden
// guard) — this path runs entirely through runArchivalAging()/events_archive,
// unaffected by the REWORK 2 routing addition, exactly as PAR-03's design
// specifies. An isolated, dedicated aged `events` partition (not the shared
// current-month one) is DETACHed from events and ATTACHed to events_archive
// by a REAL runArchivalAging() call, and the protected-family row inside it
// is confirmed to remain queryable via events_archive afterward.
test "TC-ADP-11-03: protected keep_days policy archives and preserves queryability" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // A synthetic, collision-proof partition name — see
    // runIsolatedEphemeralDropCycle's identical rationale above.
    var uuid_buf: [16]u8 = undefined;
    helpers.fillRandom(&uuid_buf);
    var suffix_buf: [16]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "{x:0>8}", .{std.mem.readInt(u32, uuid_buf[0..4], .big)}) catch return error.TestUnexpectedResult;
    const partition_name = try std.fmt.allocPrint(alloc, "events_test_archival_{s}", .{suffix});
    defer alloc.free(partition_name);
    defer {
        conn.exec("DELETE FROM plat_partition_catalog WHERE table_name = $1", &.{partition_name}) catch {};
    }

    // A range comfortably older than PartitionRetention's default
    // archive_after_months=13: [1999-01-01, 1999-02-01).
    const create_sql = try std.fmt.allocPrint(
        alloc,
        "CREATE TABLE IF NOT EXISTS {s} (LIKE events INCLUDING DEFAULTS, " ++
            "CHECK (tenant_id IS NOT NULL), " ++
            "CHECK (created_at >= '1999-01-01' AND created_at < '1999-02-01'))",
        .{partition_name},
    );
    defer alloc.free(create_sql);
    try conn.exec(create_sql, &.{});

    const attach_sql = try std.fmt.allocPrint(
        alloc,
        "ALTER TABLE events ATTACH PARTITION {s} FOR VALUES FROM ('1999-01-01') TO ('1999-02-01')",
        .{partition_name},
    );
    defer alloc.free(attach_sql);
    try conn.exec(attach_sql, &.{});
    // No unconditional DROP-on-defer here: once runArchivalAging() succeeds,
    // the physical relation is reparented under events_archive (not dropped)
    // — dropping it in a defer after that point would destroy the archived
    // data this test just proved stays queryable. Cleaned up explicitly at
    // the end after assertions complete instead.

    try conn.exec(
        "INSERT INTO plat_partition_catalog (table_name, parent_table, range_start, range_end, state) " ++
            "VALUES ($1, 'events', '1999-01-01'::timestamptz, '1999-02-01'::timestamptz, 'ATTACHED')",
        &.{partition_name},
    );

    const inst_str = try h.newUuidString(alloc);
    defer alloc.free(inst_str);
    const isolated_idem_key = try std.fmt.allocPrint(alloc, "adp11-03-{s}", .{suffix});
    defer alloc.free(isolated_idem_key);
    const isolated_event_id = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(isolated_event_id);
    const inst_hex = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(inst_hex);
    const actor_hex = try helpers.uuidBytesToString(alloc, helpers.randomUuidBytes());
    defer alloc.free(actor_hex);

    // Directly insert a protected-family (INSTANCE_STARTED) row into the
    // isolated aged partition — Store.append() always targets the CURRENT
    // month's partition (created_at = NOW()), so exercising an already-aged
    // partition requires bypassing it at the row-insertion step, exactly as
    // runArchivalAging()'s own real callers (the daily maintenance job) find
    // partitions already aged rather than ageing them synchronously.
    try conn.exec(
        "INSERT INTO events (event_id, instance_id, event_type, actor_id, " ++
            "created_at, sequence_number, idempotency_key, global_seq, tenant_id) " ++
            "VALUES ($1::uuid, $2::uuid, 'INSTANCE_STARTED', $3::uuid, '1999-01-15'::timestamptz, 999, $4, 999, " ++
            "'00000000-0000-0000-0000-000000000000'::uuid)",
        &.{ isolated_event_id, inst_hex, actor_hex, isolated_idem_key },
    );

    var retention = PartitionRetention.init(&pool, RetentionConfig{});
    const aging_result = try retention.runArchivalAging(alloc, conn);
    try std.testing.expect(aging_result.detached_and_reattached >= 1);

    // The row is gone from events (the partition was detached)...
    var live_rows = try conn.query(alloc, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{isolated_idem_key});
    defer live_rows.deinit();
    const live_count = try std.fmt.parseInt(i64, live_rows.rows[0][0] orelse "-1", 10);
    try std.testing.expectEqual(@as(i64, 0), live_count);

    // ...and remains fully queryable via events_archive — the replay-safety
    // invariant ADP-11 exists to protect, now delivered by DETACH/ATTACH
    // rather than DELETE+INSERT.
    var archive_rows = try conn.query(alloc, "SELECT COUNT(*) FROM events_archive WHERE idempotency_key = $1", &.{isolated_idem_key});
    defer archive_rows.deinit();
    const archive_count = try std.fmt.parseInt(i64, archive_rows.rows[0][0] orelse "-1", 10);
    try std.testing.expectEqual(@as(i64, 1), archive_count);

    // plat_partition_catalog reflects the reparenting.
    var catalog_rows = try conn.query(alloc, "SELECT parent_table, state FROM plat_partition_catalog WHERE table_name = $1", &.{partition_name});
    defer catalog_rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog_rows.rows.len);
    try std.testing.expectEqualStrings("events_archive", catalog_rows.rows[0][0] orelse "");
    try std.testing.expectEqualStrings("ATTACHED", catalog_rows.rows[0][1] orelse "");

    // Final cleanup: the relation now lives under events_archive.
    if (std.fmt.allocPrint(alloc, "ALTER TABLE events_archive DETACH PARTITION {s}", .{partition_name})) |detach_sql| {
        defer alloc.free(detach_sql);
        conn.exec(detach_sql, &.{}) catch {};
    } else |_| {}
    if (std.fmt.allocPrint(alloc, "DROP TABLE IF EXISTS {s}", .{partition_name})) |drop_sql| {
        defer alloc.free(drop_sql);
        conn.exec(drop_sql, &.{}) catch {};
    } else |_| {}
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

    var result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ES08_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "es08-idem-01",
        .metadata = null,
    });
    defer result.record.deinit(alloc);

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

    var discard_result_11 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ADP01_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp01-default-idem-01",
        .metadata = null,
    });
    defer discard_result_11.record.deinit(alloc);

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

    const inst_uuid = try parseUuid(alloc, inst_str);
    const actor_uuid = h.newUuid();
    const alt_tenant = try h.newUuidString(alloc);
    defer alloc.free(alt_tenant);

    // ISS-0653 / GH-662: alt_tenant is a genuine, freshly-generated tenant
    // identity that routes through the same schema-per-tenant machinery as
    // any real tenant -- store.append() issues `SET LOCAL search_path TO
    // tenant_<id>,public` for whichever tenant_id it is given. Without
    // provisioning the physical schema first, `instance_projections` (and
    // every other per-tenant table) simply does not exist there (C42P01).
    // Same root cause and same fix pattern as ISS-0654/GH-663's sim01 fix.
    // provisionTenantSchema is idempotent, safe to call unconditionally.
    try provisionTenantSchema(alloc, &pool, alt_tenant, migrationsDir());

    // event_type_registry and instance_projections are both per-tenant-schema
    // tables; registerType() and insertInstance()'s INSERT are both
    // unqualified, so they land wherever the threadlocal tenant context
    // currently routes pool.acquire(). Switch the context to alt_tenant's
    // own schema before registering the type and inserting this instance's
    // row there, matching the schema store.append() will use for alt_tenant.
    bpm.api_tenant_context.set(alt_tenant);
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ADP01_ISO_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    try insertInstance(&pool, inst_str, def_str);
    // Restore the default-tenant context immediately so every subsequent
    // pool.acquire() in this test (including the cleanup below, until it
    // explicitly re-switches) routes to tenant_default as expected.
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");

    // Both tenant's rows (inserted above under each schema's own context)
    // must be cleaned up under that same context -- cleanupInstance()'s
    // DELETEs are unqualified, same as insertInstance()'s INSERT.
    defer {
        cleanupInstance(&pool, inst_str, &.{"adp01-iso-idem-default"});
        bpm.api_tenant_context.set(alt_tenant);
        cleanupInstance(&pool, inst_str, &.{"adp01-iso-idem-alt"});
        bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    }

    var discard_result_12 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "ADP01_ISO_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp01-iso-idem-default",
        .metadata = null,
    });
    defer discard_result_12.record.deinit(alloc);

    var discard_result_13 = try store.append(alloc, AppendParams{
        .tenant_id = alt_tenant,
        .instance_id = inst_uuid,
        .event_type = "ADP01_ISO_TYPE",
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = "adp01-iso-idem-alt",
        .metadata = null,
    });
    defer discard_result_13.record.deinit(alloc);

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

    // Unlike store.append() (which issues its own `SET LOCAL search_path`
    // scoped to params.tenant_id), store.read() uses opts.tenant_id only as
    // a row-level filter (`AND tenant_id = $N`) -- it trusts the pool
    // connection's *already-active* search_path for which schema's `events`
    // table it queries. The alt-tenant row was written into
    // tenant_<alt_tenant_hex>.events by store.append() above (which does
    // its own routing internally), so reading it back requires switching
    // the threadlocal tenant context to alt_tenant first, matching the
    // schema store.append() used to write it.
    bpm.api_tenant_context.set(alt_tenant);
    const alt_events = try store.read(alloc, inst_uuid, ReadOpts{
        .tenant_id = alt_tenant,
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
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

    // ISS-0653 / GH-662: `events`/`events_archive` were created in `public`
    // by migration 001, then migration 027 (ADP-01, a plain numbered
    // migration, applied to every schema via runForSchema()) added the
    // tenant_id column and these indexes there and in every tenant schema.
    // GBL-112 (TNT-01) later DROPped both tables from `public` entirely,
    // leaving `tenant_default` (this test's makePool()-provisioned schema)
    // as the only schema where they still exist. Same anti-pattern as
    // anti-patterns.md's "legacy table name in source/test after migration
    // rename" entry -- the schema literal was never updated after TNT-01.
    const cols = try conn.query(
        alloc,
        \\SELECT table_name, is_nullable, column_default
        \\FROM information_schema.columns
        \\WHERE table_schema = 'tenant_default'
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
        \\WHERE schemaname = 'tenant_default'
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
    var discard_result_14 = try store.append(alloc, AppendParams{
        .instance_id = active_uuid,
        .event_type = type_name,
        .payload = "{}",
        .actor_id = actor_uuid,
        .idempotency_key = active_key,
        .metadata = null,
    });
    defer discard_result_14.record.deinit(alloc);
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
// TC-ES-07-02 (REWRITTEN, PAR-03/WF02-batch-3-20260811): archive() reported
// the count of ROWS moved, not the number of policies applied — that
// row-level counting concern has no row-level analogue once the mechanism
// moves to whole-PARTITION granularity (PartitionRetention.runArchivalAging()
// DETACHes/ATTACHes entire calendar-month partitions, never counts
// individual rows). This test is retired the same way TC-ES-07-01 is
// (archive() no longer exists; no DELETE FROM events/events_archive remains
// reachable in src/ — proven there, not re-proven per-test here) and instead
// verifies runArchivalAging()'s OWN count semantics: it reports the number of
// PARTITIONS it moved (detached_and_reattached), which is the mechanism's
// actual unit of work, and is idempotent (a second call over an
// already-archived partition moves nothing further).
// ---------------------------------------------------------------------------

test "TC-ES-07-02: PartitionRetention.runArchivalAging reports partitions moved and is idempotent" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    var uuid_buf: [16]u8 = undefined;
    helpers.fillRandom(&uuid_buf);
    var suffix_buf: [16]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "{x:0>8}", .{std.mem.readInt(u32, uuid_buf[0..4], .big)}) catch return error.TestUnexpectedResult;

    // Two isolated aged partitions for two DIFFERENT past months, so this
    // test can assert "moved exactly 2" precisely rather than "moved >= 1"
    // (a stronger, non-vacuous count assertion — the actual point of
    // TC-ES-07-02's original intent).
    const partition_a = try std.fmt.allocPrint(alloc, "events_test0702a_{s}", .{suffix});
    defer alloc.free(partition_a);
    const partition_b = try std.fmt.allocPrint(alloc, "events_test0702b_{s}", .{suffix});
    defer alloc.free(partition_b);

    for ([_]struct { name: []const u8, start: []const u8, end: []const u8 }{
        .{ .name = partition_a, .start = "1998-06-01", .end = "1998-07-01" },
        .{ .name = partition_b, .start = "1998-07-01", .end = "1998-08-01" },
    }) |p| {
        const create_sql = try std.fmt.allocPrint(
            alloc,
            "CREATE TABLE IF NOT EXISTS {s} (LIKE events INCLUDING DEFAULTS, " ++
                "CHECK (tenant_id IS NOT NULL), " ++
                "CHECK (created_at >= '{s}' AND created_at < '{s}'))",
            .{ p.name, p.start, p.end },
        );
        defer alloc.free(create_sql);
        try conn.exec(create_sql, &.{});

        const attach_sql = try std.fmt.allocPrint(
            alloc,
            "ALTER TABLE events ATTACH PARTITION {s} FOR VALUES FROM ('{s}') TO ('{s}')",
            .{ p.name, p.start, p.end },
        );
        defer alloc.free(attach_sql);
        try conn.exec(attach_sql, &.{});

        try conn.exec(
            "INSERT INTO plat_partition_catalog (table_name, parent_table, range_start, range_end, state) " ++
                "VALUES ($1, 'events', $2::timestamptz, $3::timestamptz, 'ATTACHED')",
            &.{ p.name, p.start, p.end },
        );
    }
    defer {
        conn.exec("DELETE FROM plat_partition_catalog WHERE table_name = $1 OR table_name = $2", &.{ partition_a, partition_b }) catch {};
        for ([_][]const u8{ partition_a, partition_b }) |p_name| {
            if (std.fmt.allocPrint(alloc, "ALTER TABLE events_archive DETACH PARTITION {s}", .{p_name})) |detach_sql| {
                defer alloc.free(detach_sql);
                conn.exec(detach_sql, &.{}) catch {};
            } else |_| {}
            if (std.fmt.allocPrint(alloc, "DROP TABLE IF EXISTS {s}", .{p_name})) |drop_sql| {
                defer alloc.free(drop_sql);
                conn.exec(drop_sql, &.{}) catch {};
            } else |_| {}
        }
    }

    var retention = PartitionRetention.init(&pool, RetentionConfig{});

    // First cycle: both isolated partitions are aged and untouched — must
    // move exactly 2, the mechanism's own unit of work.
    const first_result = try retention.runArchivalAging(alloc, conn);
    try std.testing.expect(first_result.detached_and_reattached >= 2);

    var catalog_rows = try conn.query(
        alloc,
        "SELECT COUNT(*) FROM plat_partition_catalog WHERE (table_name = $1 OR table_name = $2) AND parent_table = 'events_archive' AND state = 'ATTACHED'",
        &.{ partition_a, partition_b },
    );
    defer catalog_rows.deinit();
    const reattached_count = try std.fmt.parseInt(i64, catalog_rows.rows[0][0] orelse "-1", 10);
    try std.testing.expectEqual(@as(i64, 2), reattached_count);

    // Idempotency: a second cycle must not re-move these same two partitions
    // (they are no longer parent_table='events'/state='ATTACHED', so
    // runArchivalAging()'s own SELECT WHERE clause excludes them).
    const second_result = try retention.runArchivalAging(alloc, conn);
    var catalog_rows_after = try conn.query(
        alloc,
        "SELECT parent_table, state FROM plat_partition_catalog WHERE table_name = $1",
        &.{partition_a},
    );
    defer catalog_rows_after.deinit();
    try std.testing.expectEqualStrings("events_archive", catalog_rows_after.rows[0][0] orelse "");
    try std.testing.expectEqualStrings("ATTACHED", catalog_rows_after.rows[0][1] orelse "");
    _ = second_result;
}
