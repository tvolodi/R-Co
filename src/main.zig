const std = @import("std");

// Module references — imported here so that `zig build` and `zig build test`
// compile and validate all Stage 1 modules.
pub const db_pool = @import("db/pool.zig");
pub const db_migrations = @import("db/migrations.zig");
pub const config_mod = @import("config.zig");
pub const event_store = @import("event_store/store.zig");
pub const event_registry = @import("event_store/registry.zig");
pub const definition_graph = @import("definition/graph.zig");
pub const definition_store = @import("definition/store.zig");
pub const definition_snapshot = @import("definition/snapshot.zig");
pub const definition_export_import = @import("definition/export_import.zig"); // PD-09
pub const definition_routes = @import("api/routes/definitions.zig");
pub const engine_instance = @import("engine/instance.zig");
pub const engine_reconstruction = @import("engine/reconstruction.zig"); // EE-11
pub const instance_routes = @import("api/routes/instances.zig");
// API-03 new handlers exported for router registration:
//   GET /api/v1/instances         → instance_routes.handleList
//   GET /api/v1/instances/:id     → instance_routes.handleGetById
// Register GET /instances (list) BEFORE GET /instances/:id so that the literal
// path segment "instances" is not consumed as a UUID path parameter.
// API-05 history endpoint:
//   GET /api/v1/instances/:id/history → instance_routes.handleHistory
// Register this BEFORE the generic /:id route so "history" is not parsed as UUID.
pub const task_store = @import("tasks/store.zig");
pub const scheduler_poller = @import("scheduler/scheduler.zig"); // SCH-02
pub const task_routes = @import("api/routes/tasks.zig");
pub const json_schema_mod = @import("tools/json_schema.zig"); // EE-09 schema validator (pure)
pub const api_errors = @import("api/errors.zig"); // API-01 RFC 9457 Problem Details
pub const api_response = @import("api/response.zig"); // API-01 response builder
pub const api_content_type = @import("api/middleware/content_type.zig"); // API-01 Content-Type enforcement
pub const api_trace_context = @import("api/trace_context.zig"); // API-09 trace context
pub const api_tenant_context = @import("api/tenant_context.zig"); // ADP-03 request tenant context
pub const api_pipeline_context = @import("api/pipeline_context.zig"); // ADP-06 request pipeline context
pub const api_trace = @import("api/middleware/trace.zig"); // API-09 trace middleware
pub const api_rate_limit = @import("api/middleware/rate_limit.zig"); // API-10 rate limiting
pub const api_openapi = @import("api/openapi/mod.zig"); // API-11 OpenAPI builder/serializer
pub const openapi_routes = @import("api/routes/openapi.zig"); // API-11 public /openapi.json route handler
pub const health_routes = @import("api/routes/health.zig"); // API-12 public /health/live and /health/ready handlers
pub const metrics_routes = @import("api/routes/metrics.zig"); // OBS-02 public /metrics route handler
pub const audit_routes = @import("api/routes/audit.zig"); // OBS-03 GET /audit route handler
pub const dlq_store = @import("dlq/store.zig"); // OBS-05 dead-letter persistence
pub const dlq_routes = @import("api/routes/dlq.zig"); // OBS-05 DLQ API handlers
pub const webhooks_routes = @import("api/routes/webhooks.zig"); // EXT-02 webhook subscription API handlers
pub const api_health_readiness = @import("api/health/readiness.zig"); // API-12 readiness evaluation
pub const api_health_subsystems = @import("api/health/subsystems.zig"); // API-12 critical subsystem checks
pub const obs_logger = @import("obs/logger.zig"); // OBS-01 structured logger
pub const obs_metrics = @import("obs/metrics.zig"); // OBS-02 Prometheus metrics
pub const obs_audit = @import("obs/audit.zig"); // OBS-03 audit query service
pub const obs_alerts = @import("obs/alerts.zig"); // OBS-06 alerting hooks
pub const webhook_subscription_store = @import("webhook/subscription_store.zig"); // EXT-02 subscription storage
pub const webhook_dispatcher = @import("webhook/dispatcher.zig"); // EXT-02 webhook delivery dispatcher
pub const identity_registry = @import("identity/registry.zig"); // IDN-01 user registry persistence
pub const identity_service = @import("identity/service.zig"); // IDN-01 user registry service
pub const identity_routes = @import("api/routes/identity.zig"); // IDN-01 user registry HTTP handlers

const placeholder_health_live = "{\"status\":\"live\"}";
const placeholder_health_ready = "{\"status\":\"ready\",\"api\":\"placeholder\"}";
const placeholder_not_implemented =
    "{\"type\":\"https://bpm.local/problems/not-implemented\",\"title\":\"Not Implemented\",\"status\":501,\"detail\":\"Runtime placeholder server is active; API routes are not wired yet.\"}";

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    var io_threaded = std.Io.Threaded.init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const config = try config_mod.load(allocator);
    try obs_logger.init(.{ .level = config.log_level, .component = "main" });

    const fields = [_]obs_logger.LogField{
        .{ .key = "port", .value = .{ .integer = config.port } },
        .{ .key = "environment", .value = .{ .string = config.env } },
    };
    obs_logger.log(allocator, .INFO, "main", "startup configuration validated", &fields) catch {};

    try runPlaceholderApiServer(io, allocator, config.port);
}

fn runPlaceholderApiServer(io: std.Io, allocator: std.mem.Allocator, port: u16) !void {
    const listen_address = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    var server = try listen_address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const listening_fields = [_]obs_logger.LogField{
        .{ .key = "port", .value = .{ .integer = port } },
    };
    obs_logger.log(allocator, .INFO, "main", "runtime placeholder API server listening", &listening_fields) catch {};

    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);
        try servePlaceholderRequest(io, stream);
    }
}

fn servePlaceholderRequest(io: std.Io, stream: std.Io.net.Stream) !void {
    var recv_buffer: [4096]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    var request = server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    const json_content_header = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    if (std.mem.eql(u8, request.head.target, "/health/live")) {
        try request.respond(placeholder_health_live, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &json_content_header,
        });
        return;
    }

    if (std.mem.eql(u8, request.head.target, "/health/ready")) {
        try request.respond(placeholder_health_ready, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &json_content_header,
        });
        return;
    }

    try request.respond(placeholder_not_implemented, .{
        .status = .not_implemented,
        .keep_alive = false,
        .extra_headers = &json_content_header,
    });
}
pub const engine_transition = @import("engine/transition.zig");
