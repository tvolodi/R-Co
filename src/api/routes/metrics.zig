const std = @import("std");
const errors = @import("../errors.zig");
const response = @import("../response.zig");
const metrics = @import("obs_metrics");

pub const HandlerResult = response.HandlerResult;

pub fn handleMetrics(allocator: std.mem.Allocator) HandlerResult {
    const body = metrics.collectGlobalPrometheusText(allocator) catch {
        metrics.recordHttpRequest("GET", "/metrics", 500);
        metrics.recordHttpError5xx("/metrics");
        return response.problemResponse(
            allocator,
            errors.problemInternalError("failed to render metrics"),
        );
    };

    metrics.recordHttpRequest("GET", "/metrics", 200);

    // /metrics is intentionally unauthenticated (OBS-02).
    return .{
        .status_code = 200,
        .body = body,
        .content_type = metrics.PROMETHEUS_CONTENT_TYPE,
    };
}

test "TC-OBS-02-03: /metrics returns 200 with Prometheus content type" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();
    metrics.installGlobal(&registry);
    defer metrics.clearGlobal();

    const result = handleMetrics(std.testing.allocator);
    defer std.testing.allocator.free(result.body);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expectEqualStrings(metrics.PROMETHEUS_CONTENT_TYPE, result.content_type);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "bpm_active_instances_total") != null);
}

test "TC-OBS-02-07: /metrics serves stale in-memory gauge state during DB refresh outage" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();
    metrics.installGlobal(&registry);
    defer metrics.clearGlobal();

    registry.setActiveInstances(21);
    registry.markActiveInstancesStale();
    registry.incTaskCompletions("def-stale");

    const result = handleMetrics(std.testing.allocator);
    defer std.testing.allocator.free(result.body);

    try std.testing.expectEqual(@as(u16, 200), result.status_code);
    try std.testing.expectEqualStrings(metrics.PROMETHEUS_CONTENT_TYPE, result.content_type);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "bpm_active_instances_total 21") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "bpm_task_completions_total{definition_id=\"def-stale\"}") != null);
}
