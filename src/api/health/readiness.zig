const std = @import("std");
const db_pool = @import("../../db/pool.zig");
const subsystems = @import("subsystems.zig");

pub const FailingSubsystem = subsystems.FailingSubsystem;
pub const SubsystemChecker = subsystems.SubsystemChecker;

pub const ReadyCheckResult = union(enum) {
    ready: struct {
        db_latency_ms: u64,
    },
    not_ready: struct {
        failing_subsystems: []FailingSubsystem,
    },
};

pub const ReadinessError = error{
    OutOfMemory,
};

pub const DbHealthCheckFn = *const fn (*db_pool.Pool) db_pool.PoolError!db_pool.HealthResult;

pub const ReadinessService = struct {
    pool: *db_pool.Pool,
    checkers: []const SubsystemChecker,
    health_check_fn: DbHealthCheckFn,
    max_ready_ms: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        pool: *db_pool.Pool,
        checkers: []const SubsystemChecker,
    ) ReadinessService {
        _ = allocator;
        return .{
            .pool = pool,
            .checkers = checkers,
            .health_check_fn = defaultDbHealthCheck,
            .max_ready_ms = 1000,
        };
    }

    pub fn initWithDbHealthCheck(
        allocator: std.mem.Allocator,
        pool: *db_pool.Pool,
        checkers: []const SubsystemChecker,
        health_check_fn: DbHealthCheckFn,
    ) ReadinessService {
        _ = allocator;
        return .{
            .pool = pool,
            .checkers = checkers,
            .health_check_fn = health_check_fn,
            .max_ready_ms = 1000,
        };
    }

    pub fn evaluate(
        self: *ReadinessService,
        allocator: std.mem.Allocator,
    ) ReadinessError!ReadyCheckResult {
        const started_ms: i64 = std.Io.Clock.real.now(self.pool.io).toMilliseconds();

        const db_health = self.health_check_fn(self.pool) catch |err| {
            return .{ .not_ready = .{ .failing_subsystems = try allocator.dupe(FailingSubsystem, &.{mapPoolErrorToFailure(err)}) } };
        };

        const failures = try subsystems.runCheckers(allocator, self.checkers);
        if (failures.len > 0) {
            return .{ .not_ready = .{ .failing_subsystems = failures } };
        }
        allocator.free(failures);

        const elapsed_ms: i64 = std.Io.Clock.real.now(self.pool.io).toMilliseconds() - started_ms;
        if (elapsed_ms >= @as(i64, @intCast(self.max_ready_ms))) {
            return .{ .not_ready = .{ .failing_subsystems = try allocator.dupe(FailingSubsystem, &.{.{
                .subsystem = "readiness",
                .code = "READINESS_TIMEOUT",
                .detail = "readiness checks exceeded 1000ms budget",
                .retryable = true,
            }}) } };
        }

        return .{ .ready = .{ .db_latency_ms = db_health.latency_ms } };
    }
};

fn defaultDbHealthCheck(pool: *db_pool.Pool) db_pool.PoolError!db_pool.HealthResult {
    return pool.healthCheck();
}

pub fn mapPoolErrorToFailure(err: db_pool.PoolError) FailingSubsystem {
    return switch (err) {
        db_pool.PoolError.ExhaustedPool => .{
            .subsystem = "database",
            .code = "POOL_EXHAUSTED",
            .detail = "database pool exhausted",
            .retryable = true,
        },
        db_pool.PoolError.ConnectionFailed => .{
            .subsystem = "database",
            .code = "DB_CONNECTION_FAILED",
            .detail = "database connection failed",
            .retryable = true,
        },
        db_pool.PoolError.QueryFailed => .{
            .subsystem = "database",
            .code = "DB_QUERY_FAILED",
            .detail = "database health query failed",
            .retryable = true,
        },
        db_pool.PoolError.StaleConnection => .{
            .subsystem = "database",
            .code = "DB_STALE_CONNECTION",
            .detail = "stale database connection detected",
            .retryable = true,
        },
        else => .{
            .subsystem = "database",
            .code = "DB_UNAVAILABLE",
            .detail = "database subsystem unavailable",
            .retryable = true,
        },
    };
}

const testing = std.testing;

fn dbHealthOk(_: *db_pool.Pool) db_pool.PoolError!db_pool.HealthResult {
    return .{ .latency_ms = 12 };
}

fn dbHealthExhausted(_: *db_pool.Pool) db_pool.PoolError!db_pool.HealthResult {
    return db_pool.PoolError.ExhaustedPool;
}

fn dbHealthConnectionFailed(_: *db_pool.Pool) db_pool.PoolError!db_pool.HealthResult {
    return db_pool.PoolError.ConnectionFailed;
}

fn checkerOk(_: std.mem.Allocator) !subsystems.SubsystemCheckResult {
    return .{ .ok = {} };
}

fn checkerFail(_: std.mem.Allocator) !subsystems.SubsystemCheckResult {
    return .{ .failed = .{
        .subsystem = "api_router",
        .code = "NOT_READY",
        .detail = "router table not initialised",
        .retryable = false,
    } };
}

test "TC-API-12-04: mapPoolErrorToFailure maps exhausted pool to POOL_EXHAUSTED" {
    const mapped = mapPoolErrorToFailure(db_pool.PoolError.ExhaustedPool);
    try testing.expectEqualStrings("database", mapped.subsystem);
    try testing.expectEqualStrings("POOL_EXHAUSTED", mapped.code);
    try testing.expectEqualStrings("database pool exhausted", mapped.detail);
    try testing.expectEqual(true, mapped.retryable);
}

test "TC-API-12-05: evaluate returns ready when DB and critical checkers pass" {
    var dummy_pool: db_pool.Pool = undefined;
    var service = ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerOk }},
        dbHealthOk,
    );

    const result = try service.evaluate(testing.allocator);
    switch (result) {
        .ready => |ready| {
            try testing.expectEqual(@as(u64, 12), ready.db_latency_ms);
        },
        .not_ready => |not_ready| {
            defer testing.allocator.free(not_ready.failing_subsystems);
            return error.TestUnexpectedResult;
        },
    }
}

test "TC-API-12-06: evaluate returns not_ready with aggregated subsystem failures" {
    var dummy_pool: db_pool.Pool = undefined;
    var service = ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerFail }},
        dbHealthOk,
    );

    const result = try service.evaluate(testing.allocator);
    switch (result) {
        .ready => return error.TestUnexpectedResult,
        .not_ready => |not_ready| {
            defer testing.allocator.free(not_ready.failing_subsystems);
            try testing.expectEqual(@as(usize, 1), not_ready.failing_subsystems.len);
            try testing.expectEqualStrings("api_router", not_ready.failing_subsystems[0].subsystem);
            try testing.expectEqualStrings("NOT_READY", not_ready.failing_subsystems[0].code);
        },
    }
}

test "TC-API-12-07: evaluate returns not_ready when DB-04 reports pool exhausted" {
    var dummy_pool: db_pool.Pool = undefined;
    var service = ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerOk }},
        dbHealthExhausted,
    );

    const result = try service.evaluate(testing.allocator);
    switch (result) {
        .ready => return error.TestUnexpectedResult,
        .not_ready => |not_ready| {
            defer testing.allocator.free(not_ready.failing_subsystems);
            try testing.expectEqual(@as(usize, 1), not_ready.failing_subsystems.len);
            try testing.expectEqualStrings("POOL_EXHAUSTED", not_ready.failing_subsystems[0].code);
        },
    }
}

test "TC-API-12-11: evaluate returns not_ready when DB-04 reports connection failure" {
    var dummy_pool: db_pool.Pool = undefined;
    var service = ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerOk }},
        dbHealthConnectionFailed,
    );

    const result = try service.evaluate(testing.allocator);
    switch (result) {
        .ready => return error.TestUnexpectedResult,
        .not_ready => |not_ready| {
            defer testing.allocator.free(not_ready.failing_subsystems);
            try testing.expectEqual(@as(usize, 1), not_ready.failing_subsystems.len);
            try testing.expectEqualStrings("database", not_ready.failing_subsystems[0].subsystem);
            try testing.expectEqualStrings("DB_CONNECTION_FAILED", not_ready.failing_subsystems[0].code);
            try testing.expectEqualStrings("database connection failed", not_ready.failing_subsystems[0].detail);
        },
    }
}
