//! Unit tests for DB-01 through DB-04.
//!
//! Each test block corresponds to one test case in tests/specs/DB-01-04.md.
//! DB-guarded tests return error.SkipZigTest when BPM_TEST_DB_URL is unset.
//!
//! Requirement traceability:
//!   DB-01 → TC-DB-01-01 … TC-DB-01-05
//!   DB-02 → TC-DB-02-01 … TC-DB-02-04
//!   DB-03 → TC-DB-03-01 … TC-DB-03-02
//!   DB-04 → TC-DB-04-01 … TC-DB-04-02
const std = @import("std");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const PoolError = bpm.pool.PoolError;
const HealthResult = bpm.pool.HealthResult;
const Store = bpm.store.Store;
const AppendParams = bpm.store.AppendParams;
const StoreError = bpm.store.StoreError;
const Registry = bpm.registry.Registry;
const RegisterParams = bpm.registry.RegisterParams;

// ---------------------------------------------------------------------------
// Helpers (mirrors the pattern in event_store_test.zig)
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

// ---------------------------------------------------------------------------
// DB-01: Schema initialisation
// ---------------------------------------------------------------------------

test "TC-DB-01-01: fresh migration applies all schemas" {
    // Migration runner has no callable API — cannot be tested without CLI invocation.
    return error.SkipZigTest;
}

test "TC-DB-01-02: re-applying migrations is idempotent" {
    // Migration runner has no callable API — cannot be tested without CLI invocation.
    return error.SkipZigTest;
}

test "TC-DB-01-03: out-of-order migration returns OutOfOrderMigration" {
    // Migration runner has no callable API — cannot be tested without CLI invocation.
    return error.SkipZigTest;
}

test "TC-DB-01-04: failed migration SQL is fully rolled back" {
    // Migration runner has no callable API — cannot be tested without CLI invocation.
    return error.SkipZigTest;
}

test "TC-DB-01-05: PostgreSQL version below 15 returns UnsupportedPgVersion" {
    // Migration runner has no callable API — cannot be tested without CLI invocation.
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// DB-02: Connection pooling
// ---------------------------------------------------------------------------

test "TC-DB-02-01: pool_size below lower bound returns InvalidPoolSize" {
    const result = Pool.init(std.testing.io, std.testing.allocator, PoolConfig{
        .url = "postgres://fake:fake@localhost/fake",
        .pool_size = 1,
    });
    try std.testing.expectError(PoolError.InvalidPoolSize, result);
}

test "TC-DB-02-02: pool_size above upper bound returns InvalidPoolSize" {
    const result = Pool.init(std.testing.io, std.testing.allocator, PoolConfig{
        .url = "postgres://fake:fake@localhost/fake",
        .pool_size = 201,
    });
    try std.testing.expectError(PoolError.InvalidPoolSize, result);
}

test "TC-DB-02-03: fully exhausted pool returns ExhaustedPool immediately" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 2 });
    defer pool.deinit();

    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    // Third acquire must return ExhaustedPool immediately (no blocking).
    const err3 = pool.acquire();
    pool.release(c2);
    pool.release(c1);
    try std.testing.expectError(PoolError.ExhaustedPool, err3);
}

test "TC-DB-02-04: released connection is available for next acquire" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 2 });
    defer pool.deinit();

    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    pool.release(c1);
    // After releasing c1, a third acquire must succeed.
    const c3 = try pool.acquire();
    pool.release(c3);
    pool.release(c2);
}

// ---------------------------------------------------------------------------
// DB-03: Transactional integrity
// ---------------------------------------------------------------------------

test "TC-DB-03-01: successful transaction commits both event row and state update atomically" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const inst_str = "db030100-0000-0000-0000-000000000001";
    const def_str = "db030100-0000-0000-0000-000000000002";
    const idem_key = "tc-db-03-01-idem";

    try insertInstance(&pool, inst_str, def_str);
    defer cleanupInstance(&pool, inst_str, &.{idem_key});

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "TC_DB0301_TYPE",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const inst_id = try parseUuid(inst_str);
    const actor_id = try parseUuid("00000000-0000-0000-0000-000000000001");

    const result = try store.append(alloc, AppendParams{
        .instance_id = inst_id,
        .event_type = "TC_DB0301_TYPE",
        .payload = "{}",
        .actor_id = actor_id,
        .idempotency_key = idem_key,
        .tenant_id = bpm.store.DEFAULT_TENANT_ID,
        .metadata = null,
    });

    try std.testing.expect(!result.is_duplicate);
    try std.testing.expect(result.record.sequence_number >= 1);

    // Verify both the event row AND the sequence counter were committed atomically.
    const conn = try pool.acquire();
    defer pool.release(conn);

    var evt_rows = try conn.query(alloc, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{idem_key});
    defer evt_rows.deinit();
    const cnt_str = if (evt_rows.rows.len > 0) evt_rows.rows[0][0] orelse "0" else "0";
    const cnt = try std.fmt.parseInt(u64, cnt_str, 10);
    try std.testing.expectEqual(@as(u64, 1), cnt);

    var seq_rows = try conn.query(alloc, "SELECT last_event_seq FROM instance_projections WHERE instance_id = $1::uuid", &.{inst_str});
    defer seq_rows.deinit();
    const seq_str = if (seq_rows.rows.len > 0) seq_rows.rows[0][0] orelse "0" else "0";
    const seq = try std.fmt.parseInt(i64, seq_str, 10);
    try std.testing.expect(seq >= 1);
}

test "TC-DB-03-02: failed state-table update causes full transaction rollback" {
    // No injectable failure point for rollback without mocking (DIRECTIVE T-1).
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// DB-04: Health check query
// ---------------------------------------------------------------------------

test "TC-DB-04-01: health check returns latency_ms on successful SELECT 1" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const result = try pool.healthCheck();
    // latency_ms is u64; confirm the function returned without error.
    _ = result.latency_ms;
}

test "TC-DB-04-02: health check returns ExhaustedPool when all connections are in use" {
    const alloc = std.testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 2 });
    defer pool.deinit();

    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    const hc_result = pool.healthCheck();
    pool.release(c2);
    pool.release(c1);
    try std.testing.expectError(PoolError.ExhaustedPool, hc_result);
}
