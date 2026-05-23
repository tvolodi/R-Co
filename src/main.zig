const std = @import("std");

// Module references — imported here so that `zig build` and `zig build test`
// compile and validate all Stage 1 modules.
pub const db_pool = @import("db/pool.zig");
pub const db_migrations = @import("db/migrations.zig");
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
pub const task_routes = @import("api/routes/tasks.zig");
pub const json_schema_mod = @import("tools/json_schema.zig"); // EE-09 schema validator (pure)
pub const api_errors = @import("api/errors.zig"); // API-01 RFC 9457 Problem Details
pub const api_response = @import("api/response.zig"); // API-01 response builder
pub const api_content_type = @import("api/middleware/content_type.zig"); // API-01 Content-Type enforcement
pub const api_trace_context = @import("api/trace_context.zig"); // API-09 trace context
pub const api_trace = @import("api/middleware/trace.zig"); // API-09 trace middleware
pub const api_rate_limit = @import("api/middleware/rate_limit.zig"); // API-10 rate limiting
pub const api_openapi = @import("api/openapi/mod.zig"); // API-11 OpenAPI builder/serializer
pub const openapi_routes = @import("api/routes/openapi.zig"); // API-11 public /openapi.json route handler
pub const health_routes = @import("api/routes/health.zig"); // API-12 public /health/live and /health/ready handlers
pub const api_health_readiness = @import("api/health/readiness.zig"); // API-12 readiness evaluation
pub const api_health_subsystems = @import("api/health/subsystems.zig"); // API-12 critical subsystem checks
pub const obs_logger = @import("obs/logger.zig"); // OBS-01 structured logger

pub fn main() !void {
    std.debug.print("BPM Platform — not yet implemented\n", .{});
}
pub const engine_transition = @import("engine/transition.zig");
