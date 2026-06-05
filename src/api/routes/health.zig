const std = @import("std");
const db_pool = @import("pool");
const errors = @import("../errors.zig");
const logger = @import("../../obs/logger.zig");
const metrics = @import("obs_metrics");
const response = @import("../response.zig");
const readiness_mod = @import("../health/readiness.zig");
const trace_context = @import("../trace_context.zig");

pub const HandlerResult = response.HandlerResult;

pub fn handleLive(allocator: std.mem.Allocator) HandlerResult {
    const log_fields = [_]logger.LogField{
        .{ .key = "endpoint", .value = .{ .string = "/health/live" } },
        .{ .key = "status_code", .value = .{ .integer = 200 } },
    };
    logger.log(allocator, .INFO, "api.health", "health live request completed", &log_fields) catch {};

    const body = std.fmt.allocPrint(allocator, "{{\"status\":\"ok\"}}", .{}) catch {
        metrics.recordHttpRequest("GET", "/health/live", 500);
        metrics.recordHttpError5xx("/health/live");
        return response.problemResponse(
            allocator,
            errors.problemInternalError("failed to build liveness response"),
        );
    };
    metrics.recordHttpRequest("GET", "/health/live", 200);
    return response.ok(body);
}

pub fn handleReady(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    readiness: *readiness_mod.ReadinessService,
) HandlerResult {
    _ = pool;

    const ready_result = readiness.evaluate(allocator) catch {
        metrics.recordHttpRequest("GET", "/health/ready", 500);
        metrics.recordHttpError5xx("/health/ready");
        return response.problemResponse(
            allocator,
            errors.problemInternalError("failed to evaluate readiness"),
        );
    };

    switch (ready_result) {
        .ready => |ready| {
            const log_fields = [_]logger.LogField{
                .{ .key = "endpoint", .value = .{ .string = "/health/ready" } },
                .{ .key = "status_code", .value = .{ .integer = 200 } },
                .{ .key = "db_latency_ms", .value = .{ .integer = @intCast(ready.db_latency_ms) } },
            };
            logger.log(allocator, .INFO, "api.health", "health readiness request completed", &log_fields) catch {};

            const body = std.fmt.allocPrint(
                allocator,
                "{{\"status\":\"ok\",\"db_latency_ms\":{d}}}",
                .{ready.db_latency_ms},
            ) catch {
                metrics.recordHttpRequest("GET", "/health/ready", 500);
                metrics.recordHttpError5xx("/health/ready");
                return response.problemResponse(
                    allocator,
                    errors.problemInternalError("failed to build readiness response"),
                );
            };
            metrics.recordHttpRequest("GET", "/health/ready", 200);
            return response.ok(body);
        },
        .not_ready => |not_ready| {
            defer allocator.free(not_ready.failing_subsystems);

            const log_fields = [_]logger.LogField{
                .{ .key = "endpoint", .value = .{ .string = "/health/ready" } },
                .{ .key = "status_code", .value = .{ .integer = 503 } },
                .{ .key = "failing_subsystem_count", .value = .{ .integer = @intCast(not_ready.failing_subsystems.len) } },
            };
            logger.log(allocator, .WARN, "api.health", "health readiness request degraded", &log_fields) catch {};

            const body = buildNotReadyBody(allocator, not_ready.failing_subsystems) catch {
                metrics.recordHttpRequest("GET", "/health/ready", 500);
                metrics.recordHttpError5xx("/health/ready");
                return response.problemResponse(
                    allocator,
                    errors.problemInternalError("failed to build degraded readiness response"),
                );
            };
            metrics.recordHttpRequest("GET", "/health/ready", 503);
            return .{ .status_code = 503, .body = body };
        },
    }
}

fn buildNotReadyBody(
    allocator: std.mem.Allocator,
    failing_subsystems: []const readiness_mod.FailingSubsystem,
) error{OutOfMemory}![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"status\":\"degraded\",\"failing_subsystems\":[");
    for (failing_subsystems, 0..) |failure, i| {
        if (i > 0) try out.append(allocator, ',');
        const entry = try std.fmt.allocPrint(allocator,
            "{{\"subsystem\":\"{s}\",\"code\":\"{s}\",\"detail\":\"{s}\",\"retryable\":{s}}}",
            .{
                failure.subsystem,
                failure.code,
                failure.detail,
                if (failure.retryable) "true" else "false",
            });
        defer allocator.free(entry);
        try out.appendSlice(allocator, entry);
    }
    try out.appendSlice(allocator, "]}");

    return try out.toOwnedSlice(allocator);
}

const testing = std.testing;

fn fakeDbHealth(_: *db_pool.Pool) db_pool.PoolError!db_pool.HealthResult {
    return .{ .latency_ms = 7 };
}

fn fakeDbHealthFail(_: *db_pool.Pool) db_pool.PoolError!db_pool.HealthResult {
    return db_pool.PoolError.ExhaustedPool;
}

fn fakeDbHealthQueryFailed(_: *db_pool.Pool) db_pool.PoolError!db_pool.HealthResult {
    return db_pool.PoolError.QueryFailed;
}

fn checkerOk(_: std.mem.Allocator) !@import("../health/subsystems.zig").SubsystemCheckResult {
    return .{ .ok = {} };
}

test "TC-API-12-01: handleLive returns HTTP 200 with status ok" {
    const result = handleLive(testing.allocator);
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expectEqualStrings("{\"status\":\"ok\"}", result.body);
}

test "TC-API-12-02: handleReady returns HTTP 200 with db latency when ready" {
    var dummy_pool: db_pool.Pool = undefined;
    var readiness = readiness_mod.ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerOk }},
        fakeDbHealth,
    );

    const result = handleReady(testing.allocator, &dummy_pool, &readiness);
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"db_latency_ms\":7") != null);
}

test "TC-API-12-03: handleReady returns HTTP 503 with failing subsystem details" {
    var dummy_pool: db_pool.Pool = undefined;
    var readiness = readiness_mod.ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerOk }},
        fakeDbHealthFail,
    );

    const result = handleReady(testing.allocator, &dummy_pool, &readiness);
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 503), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"degraded\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"subsystem\":\"database\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"code\":\"POOL_EXHAUSTED\"") != null);
}

test "TC-API-12-09: handleReady returns HTTP 503 when DB-04 query health check fails" {
    var dummy_pool: db_pool.Pool = undefined;
    var readiness = readiness_mod.ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerOk }},
        fakeDbHealthQueryFailed,
    );

    const result = handleReady(testing.allocator, &dummy_pool, &readiness);
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 503), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"degraded\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"subsystem\":\"database\"") != null);
    try testing.expect(std.mem.indexOf(u8, result.body, "\"code\":\"DB_QUERY_FAILED\"") != null);
}

test "TC-API-12-10: health handlers remain stable with API-09 trace context set" {
    trace_context.set("api12-trace");
    defer trace_context.clear();

    const live_result = handleLive(testing.allocator);
    defer testing.allocator.free(live_result.body);
    try testing.expectEqual(@as(u16, 200), live_result.status_code);
    try testing.expectEqualStrings("{\"status\":\"ok\"}", live_result.body);

    var dummy_pool: db_pool.Pool = undefined;
    var readiness = readiness_mod.ReadinessService.initWithDbHealthCheck(
        testing.allocator,
        &dummy_pool,
        &.{.{ .name = "api_router", .checkFn = checkerOk }},
        fakeDbHealth,
    );

    const ready_result = handleReady(testing.allocator, &dummy_pool, &readiness);
    defer testing.allocator.free(ready_result.body);
    try testing.expectEqual(@as(u16, 200), ready_result.status_code);
    try testing.expect(std.mem.indexOf(u8, ready_result.body, "\"status\":\"ok\"") != null);
}
