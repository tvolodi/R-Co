//! Unit tests for ES-01 through ES-08.
//!
//! Pure tests (no DB) run with std.mem.zeroes(Pool) — safe because the timing
//! block now sits after all pre-write validations (ISS-0039 fix).
//!
//! DB-guarded tests read BPM_TEST_DB_URL and return error.SkipZigTest when
//! the variable is absent so that CI can skip them gracefully.
//!
//! Requirement traceability:
//!   ES-01 → TC-ES-01-01 … TC-ES-01-06
//!   ES-02 → TC-ES-02-01 … TC-ES-02-02
//!   ES-03 → TC-ES-03-01 … TC-ES-03-03
//!   ES-04 → TC-ES-04-01 … TC-ES-04-02
//!   ES-05 → TC-ES-05-01 … TC-ES-05-04
//!   ES-06 → TC-ES-06-01 … TC-ES-06-02
//!   ES-07 → TC-ES-07-01 … TC-ES-07-02
//!   ES-08 → TC-ES-08-01 … TC-ES-08-04
const std = @import("std");
const bpm = @import("bpm");

const Store = bpm.store.Store;
const Registry = bpm.registry.Registry;
const AppendParams = bpm.store.AppendParams;
const StoreError = bpm.store.StoreError;
const RegistryError = bpm.registry.RegistryError;
const RegisterParams = bpm.registry.RegisterParams;
const ReadOpts = bpm.store.ReadOpts;
const GlobalReadOpts = bpm.store.GlobalReadOpts;
const RetentionPolicyUpsertParams = bpm.store.RetentionPolicyUpsertParams;
const RetentionPolicyMode = bpm.store.RetentionPolicyMode;
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

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
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
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

fn insertInstance(pool: *Pool, inst_id: []const u8, def_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "INSERT INTO instance_projections " ++
            "(instance_id, definition_id, status, last_event_seq) " ++
            "VALUES ($1::uuid, $2::uuid, 'ACTIVE', 0) ON CONFLICT (instance_id) DO NOTHING",
        &.{ inst_id, def_id },
    );
}

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

fn freeEventRecords(allocator: std.mem.Allocator, events: []bpm.store.EventRecord) void {
    for (events) |ev| {
        allocator.free(ev.event_type);
        allocator.free(ev.payload);
        allocator.free(ev.metadata);
    }
    allocator.free(events);
}

// ---------------------------------------------------------------------------
// ES-01: Append event — PURE tests (no DB required)
// ---------------------------------------------------------------------------

test "TC-ES-01-05: append with nil actor_id returns ActorIdMissing" {
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();
    const result = store.append(alloc, AppendParams{
        .instance_id = [_]u8{1} ** 16,
        .event_type = "T",
        .payload = "{}",
        .actor_id = std.mem.zeroes([16]u8),
        .idempotency_key = "k",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.ActorIdMissing, result);
}

test "TC-ES-01-06: append with JSON array payload returns PayloadInvalid" {
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();
    const result = store.append(alloc, AppendParams{
        .instance_id = [_]u8{1} ** 16,
        .event_type = "T",
        .payload = "[]",
        .actor_id = [_]u8{1} ** 16,
        .idempotency_key = "k",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.PayloadInvalid, result);
}

// ---------------------------------------------------------------------------
// ES-03: Event idempotency — PURE tests
// ---------------------------------------------------------------------------

test "TC-ES-03-02: empty idempotency_key returns IdempotencyKeyMissing" {
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();
    const result = store.append(alloc, AppendParams{
        .instance_id = [_]u8{1} ** 16,
        .event_type = "T",
        .payload = "{}",
        .actor_id = [_]u8{1} ** 16,
        .idempotency_key = "",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.IdempotencyKeyMissing, result);
}

test "TC-ES-03-03: idempotency_key of 256 characters returns IdempotencyKeyTooLong" {
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();
    const long_key = "x" ** 256;
    const result = store.append(alloc, AppendParams{
        .instance_id = [_]u8{1} ** 16,
        .event_type = "T",
        .payload = "{}",
        .actor_id = [_]u8{1} ** 16,
        .idempotency_key = long_key,
        .metadata = null,
    });
    try std.testing.expectError(StoreError.IdempotencyKeyTooLong, result);
}

// ---------------------------------------------------------------------------
// ES-05: Event type registry — PURE test
// ---------------------------------------------------------------------------

test "TC-ES-05-03: registerType with invalid JSON schema returns InvalidJsonSchema" {
    // This check happens before pool.acquire() — safe with undefined Pool.
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    const result = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0503_TYPE",
        .schema_version = 1,
        .json_schema = "not-a-json-object",
        .description = null,
    });
    try std.testing.expectError(RegistryError.InvalidJsonSchema, result);
}

// ---------------------------------------------------------------------------
// ES-08: Event metadata — PURE tests
// ---------------------------------------------------------------------------

test "TC-ES-08-01: append with metadata key > 128 chars returns MetadataInvalid" {
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();
    const long_key = "k" ** 129;
    const metadata = "{\"" ++ long_key ++ "\": \"v\"}";
    const result = store.append(alloc, AppendParams{
        .instance_id = [_]u8{1} ** 16,
        .event_type = "T",
        .payload = "{}",
        .actor_id = [_]u8{1} ** 16,
        .idempotency_key = "k",
        .metadata = metadata,
    });
    try std.testing.expectError(StoreError.MetadataInvalid, result);
}

test "TC-ES-08-02: append with metadata value > 1024 chars returns MetadataInvalid" {
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();
    const long_val = "v" ** 1025;
    const metadata = "{\"k\": \"" ++ long_val ++ "\"}";
    const result = store.append(alloc, AppendParams{
        .instance_id = [_]u8{1} ** 16,
        .event_type = "T",
        .payload = "{}",
        .actor_id = [_]u8{1} ** 16,
        .idempotency_key = "k",
        .metadata = metadata,
    });
    try std.testing.expectError(StoreError.MetadataInvalid, result);
}

test "TC-ES-08-03: append with 51 metadata entries returns MetadataInvalid" {
    const alloc = std.testing.allocator;
    var pool: Pool = undefined;
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    // Build a 51-entry JSON object using a fixed stack buffer.
    var meta_buf: [8192]u8 = undefined;
    var meta_len: usize = 0;
    meta_buf[meta_len] = '{';
    meta_len += 1;
    for (0..51) |i| {
        if (i > 0) {
            meta_buf[meta_len] = ',';
            meta_len += 1;
        }
        const written = std.fmt.bufPrint(meta_buf[meta_len..], "\"k{d}\":\"v\"", .{i}) catch unreachable;
        meta_len += written.len;
    }
    meta_buf[meta_len] = '}';
    meta_len += 1;
    const metadata_51 = meta_buf[0..meta_len];

    const result = store.append(alloc, AppendParams{
        .instance_id = [_]u8{1} ** 16,
        .event_type = "T",
        .payload = "{}",
        .actor_id = [_]u8{1} ** 16,
        .idempotency_key = "k",
        .metadata = metadata_51,
    });
    try std.testing.expectError(StoreError.MetadataInvalid, result);
}

// ---------------------------------------------------------------------------
// ES-01: Append event — DB-guarded tests
// ---------------------------------------------------------------------------

test "TC-ES-01-01: valid append returns AppendResult with is_duplicate=false and persisted record" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0101_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5010100-0000-0000-0000-000000000001";
    const def_str = "d5010100-0000-0000-0000-000000000001";
    const idem_key = "tc-es-01-01-idem";
    cleanupInstance(&pool, inst_str, &.{idem_key});
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{idem_key});

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0xaa} ** 16;

    const result = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0101_TYPE",
        .payload = "{\"x\":1}",
        .actor_id = actor,
        .idempotency_key = idem_key,
        .metadata = null,
    });

    try std.testing.expect(!result.is_duplicate);
    try std.testing.expect(result.record.sequence_number >= 1);
}

test "TC-ES-01-02: append to non-existent instance returns InstanceNotFound" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0102_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    // Use a UUID that has never been inserted into instance_projections.
    const ghost_uuid = try parseUuid("deadbeef-dead-dead-dead-deaddeadbeef");
    const actor: [16]u8 = [_]u8{0xbb} ** 16;

    const result = store.append(alloc, AppendParams{
        .instance_id = ghost_uuid,
        .event_type = "TC_ES0102_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-01-02-idem",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.InstanceNotFound, result);
}

test "TC-ES-01-03: append to COMPLETED instance returns InstanceTerminated" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0103_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5010300-0000-0000-0000-000000000001";
    const def_str = "d5010300-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{});

    // Mark instance COMPLETED via direct SQL.
    {
        const cc = try pool.acquire();
        defer pool.release(cc);
        try cc.exec(
            "UPDATE instance_projections SET status='COMPLETED' WHERE instance_id=$1::uuid",
            &.{inst_str},
        );
    }

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0xcc} ** 16;
    const result = store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0103_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-01-03-idem",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.InstanceTerminated, result);
}

test "TC-ES-01-04: append to CANCELLED instance returns InstanceTerminated" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0104_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5010400-0000-0000-0000-000000000001";
    const def_str = "d5010400-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{});

    {
        const cc = try pool.acquire();
        defer pool.release(cc);
        try cc.exec(
            "UPDATE instance_projections SET status='CANCELLED' WHERE instance_id=$1::uuid",
            &.{inst_str},
        );
    }

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0xdd} ** 16;
    const result = store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0104_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-01-04-idem",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.InstanceTerminated, result);
}

// ---------------------------------------------------------------------------
// ES-02: Ordered read — DB-guarded tests
// ---------------------------------------------------------------------------

test "TC-ES-02-01: two sequential appends to same instance receive sequence_numbers 1 and 2" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0201_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5020100-0000-0000-0000-000000000001";
    const def_str = "d5020100-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "tc-es-02-01-a", "tc-es-02-01-b" });

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x02} ** 16;

    const r1 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0201_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-02-01-a",
        .metadata = null,
    });
    const r2 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0201_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-02-01-b",
        .metadata = null,
    });

    try std.testing.expectEqual(@as(i64, 1), r1.record.sequence_number);
    try std.testing.expectEqual(@as(i64, 2), r2.record.sequence_number);
}

test "TC-ES-02-02: Store.read returns events sorted by ascending sequence_number" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0202_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5020200-0000-0000-0000-000000000001";
    const def_str = "d5020200-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "tc-es-02-02-a", "tc-es-02-02-b", "tc-es-02-02-c" });

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x22} ** 16;
    const idem_keys = [_][]const u8{ "tc-es-02-02-a", "tc-es-02-02-b", "tc-es-02-02-c" };

    for (idem_keys) |k| {
        _ = try store.append(alloc, AppendParams{
            .instance_id = inst_uuid,
            .event_type = "TC_ES0202_TYPE",
            .payload = "{}",
            .actor_id = actor,
            .idempotency_key = k,
            .metadata = null,
        });
    }

    const events = try store.read(alloc, inst_uuid, ReadOpts{
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer freeEventRecords(alloc, events);

    try std.testing.expect(events.len >= 3);
    var prev_seq: i64 = 0;
    for (events) |ev| {
        try std.testing.expect(ev.sequence_number > prev_seq);
        prev_seq = ev.sequence_number;
    }
}

// ---------------------------------------------------------------------------
// ES-03: Event idempotency — DB-guarded test
// ---------------------------------------------------------------------------

test "TC-ES-03-01: duplicate idempotency_key returns original event with is_duplicate=true" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0301_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5030100-0000-0000-0000-000000000001";
    const def_str = "d5030100-0000-0000-0000-000000000001";
    const idem_key = "tc-es-03-01-idem";
    cleanupInstance(&pool, inst_str, &.{idem_key});
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{idem_key});

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x30} ** 16;

    const r1 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0301_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = idem_key,
        .metadata = null,
    });

    const r2 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0301_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = idem_key,
        .metadata = null,
    });

    try std.testing.expect(!r1.is_duplicate);
    try std.testing.expect(r2.is_duplicate);
    try std.testing.expectEqual(r1.record.sequence_number, r2.record.sequence_number);
}

// ---------------------------------------------------------------------------
// ES-04: Global event stream — DB-guarded tests
// ---------------------------------------------------------------------------

test "TC-ES-04-01: readGlobal returns events in ascending global_seq order" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0401_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5040100-0000-0000-0000-000000000001";
    const def_str = "d5040100-0000-0000-0000-000000000001";
    cleanupInstance(&pool, inst_str, &.{ "tc-es-04-01-a", "tc-es-04-01-b" });
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "tc-es-04-01-a", "tc-es-04-01-b" });

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x04} ** 16;

    const r1 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0401_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-04-01-a",
        .metadata = null,
    });
    const r2 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0401_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-04-01-b",
        .metadata = null,
    });

    // global_seq must increase between consecutive appends.
    try std.testing.expect(r2.record.global_seq > r1.record.global_seq);

    // readGlobal starting from just before r1 must return events in ascending order.
    const events = try store.readGlobal(alloc, GlobalReadOpts{
        .after_global_seq = r1.record.global_seq - 1,
        .limit = 100,
    });
    defer freeEventRecords(alloc, events);

    var prev_gseq: i64 = 0;
    for (events) |ev| {
        try std.testing.expect(ev.global_seq > prev_gseq);
        prev_gseq = ev.global_seq;
    }
    try std.testing.expect(events.len >= 2);
}

test "TC-ES-04-02: readGlobal with after_global_seq cursor returns only events after that position" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0402_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5040200-0000-0000-0000-000000000001";
    const def_str = "d5040200-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "tc-es-04-02-a", "tc-es-04-02-b" });

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x42} ** 16;

    const r1 = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0402_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-04-02-a",
        .metadata = null,
    });
    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0402_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-04-02-b",
        .metadata = null,
    });

    // Cursor = r1.global_seq: must skip r1 and return only events after it.
    const after = try store.readGlobal(alloc, GlobalReadOpts{
        .after_global_seq = r1.record.global_seq,
        .limit = 100,
    });
    defer freeEventRecords(alloc, after);

    try std.testing.expect(after.len >= 1);
    try std.testing.expect(after[0].global_seq > r1.record.global_seq);
}

// ---------------------------------------------------------------------------
// ES-05: Event type registry — DB-guarded tests
// ---------------------------------------------------------------------------

test "TC-ES-05-01: append with unregistered event_type returns UnknownEventType" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    // Use an empty registry (no types registered) so lookup hits the DB and misses.
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5050100-0000-0000-0000-000000000001";
    const def_str = "d5050100-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{});

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x50} ** 16;

    const result = store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TOTALLY_UNKNOWN_TYPE_9999_XYZ",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = "tc-es-05-01-idem",
        .metadata = null,
    });
    try std.testing.expectError(StoreError.UnknownEventType, result);
}

test "TC-ES-05-02: append with payload failing registered schema returns PayloadSchemaInvalid" {
    // Registry.validatePayload only performs an isJsonObject structural check.
    // Full JSON Schema validation is not implemented, so the PayloadSchemaInvalid
    // path cannot be triggered with a valid JSON object — exercising it would
    // require injecting a mock validator, which violates DIRECTIVE T-1.
    // Kept as a stub pending a full JSON Schema validator implementation.
    return error.SkipZigTest;
}

test "TC-ES-05-04: registerType with duplicate name+version returns DuplicateEventTypeVersion" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();

    // First registration (may already exist from a previous run — ignore error).
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0504_TYPE",
        .schema_version = 99,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    // Second registration with identical (name, version) must always fail.
    const result = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0504_TYPE",
        .schema_version = 99,
        .json_schema = "{}",
        .description = null,
    });
    try std.testing.expectError(RegistryError.DuplicateEventTypeVersion, result);
}

// ---------------------------------------------------------------------------
// ES-06: Point-in-time query — DB-guarded tests
// ---------------------------------------------------------------------------

test "TC-ES-06-01: pointInTime with before timestamp filters out later events" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0601_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5060100-0000-0000-0000-000000000001";
    const def_str = "d5060100-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "tc-es-06-01-a", "tc-es-06-01-b", "tc-es-06-01-c" });

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x60} ** 16;
    const idem_keys = [_][]const u8{ "tc-es-06-01-a", "tc-es-06-01-b", "tc-es-06-01-c" };

    for (idem_keys) |k| {
        _ = try store.append(alloc, AppendParams{
            .instance_id = inst_uuid,
            .event_type = "TC_ES0601_TYPE",
            .payload = "{}",
            .actor_id = actor,
            .idempotency_key = k,
            .metadata = null,
        });
    }

    // Timestamp 0 (Unix epoch) is before any real event — must return empty.
    const empty = try store.pointInTime(alloc, inst_uuid, 0);
    defer freeEventRecords(alloc, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    // Max i64 is far future — must include all 3 events for this instance.
    const all_events = try store.pointInTime(alloc, inst_uuid, std.math.maxInt(i64));
    defer freeEventRecords(alloc, all_events);
    try std.testing.expect(all_events.len >= 3);
}

test "TC-ES-06-02: read with up_to_sequence returns exactly events 1..K" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0602_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5060200-0000-0000-0000-000000000001";
    const def_str = "d5060200-0000-0000-0000-000000000001";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{ "tc-es-06-02-a", "tc-es-06-02-b", "tc-es-06-02-c" });

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x62} ** 16;
    const idem_keys = [_][]const u8{ "tc-es-06-02-a", "tc-es-06-02-b", "tc-es-06-02-c" };

    for (idem_keys) |k| {
        _ = try store.append(alloc, AppendParams{
            .instance_id = inst_uuid,
            .event_type = "TC_ES0602_TYPE",
            .payload = "{}",
            .actor_id = actor,
            .idempotency_key = k,
            .metadata = null,
        });
    }

    const events_k2 = try store.read(alloc, inst_uuid, ReadOpts{
        .up_to_sequence = 2,
        .up_to_timestamp = null,
    });
    defer freeEventRecords(alloc, events_k2);

    try std.testing.expectEqual(@as(usize, 2), events_k2.len);
    try std.testing.expectEqual(@as(i64, 1), events_k2[0].sequence_number);
    try std.testing.expectEqual(@as(i64, 2), events_k2[1].sequence_number);
}

// ---------------------------------------------------------------------------
// ES-07: Retention policy — DB-guarded tests
// ---------------------------------------------------------------------------

test "TC-ES-07-01: archive moves events past retention period to events_archive" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0701_ARCH",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5070100-0000-0000-0000-000000000001";
    const def_str = "d5070100-0000-0000-0000-000000000001";
    const idem_key = "tc-es-07-01-idem";
    try insertInstance(&pool, inst_str, def_str);

    // Cleanup both live and archive tables (archive may have received the row).
    defer {
        if (pool.acquire()) |cc| {
            cc.exec("DELETE FROM events_archive WHERE idempotency_key=$1", &.{idem_key}) catch {};
            cc.exec("DELETE FROM events WHERE idempotency_key=$1", &.{idem_key}) catch {};
            cc.exec("DELETE FROM instance_sequence WHERE instance_id=$1::uuid", &.{inst_str}) catch {};
            cc.exec("DELETE FROM instance_projections WHERE instance_id=$1::uuid", &.{inst_str}) catch {};
            pool.release(cc);
        } else |_| {}
    }

    // keep_days=0 archives any event with created_at <= NOW().
    try store.upsertRetentionPolicy(alloc, RetentionPolicyUpsertParams{
        .event_type = "TC_ES0701_ARCH",
        .policy = RetentionPolicyMode.keep_days,
        .keep_days = 0,
    });

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x70} ** 16;
    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0701_ARCH",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = idem_key,
        .metadata = null,
    });

    _ = try store.archive(alloc, 0);

    // Verify event landed in events_archive.
    const cc = try pool.acquire();
    defer pool.release(cc);
    const rows = try cc.query(
        alloc,
        "SELECT COUNT(*) FROM events_archive WHERE idempotency_key=$1",
        &.{idem_key},
    );
    defer {
        var mr = rows;
        mr.deinit();
    }
    try std.testing.expect(rows.rows.len > 0);
    const cnt_str = rows.rows[0][0] orelse "0";
    const cnt = try std.fmt.parseInt(u64, cnt_str, 10);
    try std.testing.expect(cnt >= 1);
}

test "TC-ES-07-02: archive returns count of moved policy buckets" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0702_CNT",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    // Ensure at least one keep_days policy is registered.
    try store.upsertRetentionPolicy(alloc, RetentionPolicyUpsertParams{
        .event_type = "TC_ES0702_CNT",
        .policy = RetentionPolicyMode.keep_days,
        .keep_days = 0,
    });

    const count = try store.archive(alloc, 0);
    // At least one keep_days policy exists so the archive loop runs at least once.
    try std.testing.expect(count >= 1);
}

// ---------------------------------------------------------------------------
// ES-08: Event metadata — DB-guarded test
// ---------------------------------------------------------------------------

test "TC-ES-08-04: absent metadata field defaults to empty JSON object in returned record" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_ES0804_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_str = "e5080400-0000-0000-0000-000000000001";
    const def_str = "d5080400-0000-0000-0000-000000000001";
    const idem_key = "tc-es-08-04-idem";
    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{idem_key});

    const inst_uuid = try parseUuid(inst_str);
    const actor: [16]u8 = [_]u8{0x84} ** 16;

    _ = try store.append(alloc, AppendParams{
        .instance_id = inst_uuid,
        .event_type = "TC_ES0804_TYPE",
        .payload = "{}",
        .actor_id = actor,
        .idempotency_key = idem_key,
        .metadata = null, // no metadata supplied
    });

    // Read back and verify metadata stored as "{}".
    const events = try store.read(alloc, inst_uuid, ReadOpts{
        .up_to_sequence = null,
        .up_to_timestamp = null,
    });
    defer freeEventRecords(alloc, events);

    try std.testing.expect(events.len >= 1);
    try std.testing.expectEqualStrings("{}", events[0].metadata);
}
