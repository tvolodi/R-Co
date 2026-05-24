//! Integration tests for OBS-02 — Prometheus metrics endpoint.
//!
//! This suite is self-sufficient: it exercises real route handlers in-process
//! with a deterministic global metrics registry fixture.

const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");

const metrics_routes = bpm.metrics_routes;
const metrics = bpm.obs_metrics;

const MetricsFixture = struct {
    registry: metrics.MetricsRegistry,

    fn init(self: *MetricsFixture) void {
        self.* = .{
            .registry = metrics.MetricsRegistry.init(testing.allocator),
        };
        metrics.installGlobal(&self.registry);
    }

    fn deinit(self: *MetricsFixture) void {
        metrics.clearGlobal();
        self.registry.deinit();
    }
};

test "TC-OBS-02-INT-01: GET /metrics is unauthenticated and returns Prometheus contract" {
    var fixture: MetricsFixture = undefined;
    fixture.init();
    defer fixture.deinit();

    const result = metrics_routes.handleMetrics(testing.allocator);
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.indexOf(u8, result.content_type, "text/plain") != null);
    try testing.expect(std.mem.indexOf(u8, result.content_type, "version=0.0.4") != null);
}

test "TC-OBS-02-INT-02: /metrics emits required metric families and key labels" {
    var fixture: MetricsFixture = undefined;
    fixture.init();
    defer fixture.deinit();

    // Seed representative runtime activity before scraping.
    metrics.setActiveInstances(1);
    metrics.recordTaskCompletion("def-a");
    metrics.recordEventAppendDurationSeconds(0.1);
    metrics.recordDbQueryDurationSeconds(.select, 0.01);
    metrics.recordHttpRequest("GET", "/health/live", 200);

    const first_scrape = metrics_routes.handleMetrics(testing.allocator);
    testing.allocator.free(first_scrape.body);

    const second_scrape = metrics_routes.handleMetrics(testing.allocator);
    defer testing.allocator.free(second_scrape.body);

    try testing.expectEqual(@as(u16, 200), second_scrape.status_code);
    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "# TYPE bpm_active_instances_total gauge") != null);
    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "# TYPE bpm_task_completions_total counter") != null);
    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "# TYPE bpm_event_append_duration_seconds histogram") != null);
    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "# TYPE bpm_db_query_duration_seconds histogram") != null);
    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "# TYPE bpm_http_requests_total counter") != null);
    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "# TYPE bpm_http_errors_total counter") != null);

    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "bpm_http_requests_total{method=\"GET\",path=\"/metrics\",status=\"200\"}") != null);
    try testing.expect(std.mem.indexOf(u8, second_scrape.body, "bpm_db_query_duration_seconds_bucket{query_type=\"select\"") != null);
}

test "TC-OBS-02-INT-03: repeated /metrics scraping preserves /health/live observability state" {
    var fixture: MetricsFixture = undefined;
    fixture.init();
    defer fixture.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const scrape = metrics_routes.handleMetrics(testing.allocator);
        testing.allocator.free(scrape.body);
        try testing.expectEqual(@as(u16, 200), scrape.status_code);
    }

    metrics.recordHttpRequest("GET", "/health/live", 200);
    const final_scrape = metrics_routes.handleMetrics(testing.allocator);
    defer testing.allocator.free(final_scrape.body);

    try testing.expectEqual(@as(u16, 200), final_scrape.status_code);
    try testing.expect(std.mem.indexOf(u8, final_scrape.body, "bpm_http_requests_total{method=\"GET\",path=\"/health/live\",status=\"200\"} 1") != null);
}
