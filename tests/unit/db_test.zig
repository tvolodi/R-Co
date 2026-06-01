//! Unit test stubs for DB-01 through DB-04.
//!
//! Each test block corresponds to one test case in tests/specs/DB-01-04.md.
//! All blocks return error.SkipZigTest until the TEST-RUNNER implements them.
//!
//! Requirement traceability:
//!   DB-01 → TC-DB-01-01 … TC-DB-01-05
//!   DB-02 → TC-DB-02-01 … TC-DB-02-04
//!   DB-03 → TC-DB-03-01 … TC-DB-03-02  (integration layer; stubs here for catalog)
//!   DB-04 → TC-DB-04-01 … TC-DB-04-02
const std = @import("std");
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const PoolError = bpm.pool.PoolError;

// ---------------------------------------------------------------------------
// DB-01: Schema initialisation
// ---------------------------------------------------------------------------

test "TC-DB-01-01: fresh migration applies all schemas" {
    return error.SkipZigTest;
}

test "TC-DB-01-02: re-applying migrations is idempotent" {
    return error.SkipZigTest;
}

test "TC-DB-01-03: out-of-order migration returns OutOfOrderMigration" {
    return error.SkipZigTest;
}

test "TC-DB-01-04: failed migration SQL is fully rolled back" {
    return error.SkipZigTest;
}

test "TC-DB-01-05: PostgreSQL version below 15 returns UnsupportedPgVersion" {
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
    return error.SkipZigTest;
}

test "TC-DB-02-04: released connection is available for next acquire" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// DB-03: Transactional integrity (integration; stubs for catalog completeness)
// ---------------------------------------------------------------------------

test "TC-DB-03-01: successful transaction commits both event row and state update atomically" {
    return error.SkipZigTest;
}

test "TC-DB-03-02: failed state-table update causes full transaction rollback" {
    return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// DB-04: Health check query
// ---------------------------------------------------------------------------

test "TC-DB-04-01: health check returns latency_ms on successful SELECT 1" {
    return error.SkipZigTest;
}

test "TC-DB-04-02: health check returns ExhaustedPool when all connections are in use" {
    return error.SkipZigTest;
}
