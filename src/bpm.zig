//! Single-root re-export shim used by integration tests.
//!
//! Having one module root prevents "file exists in two modules" conflicts
//! that arise when pool.zig is both a named-module root AND imported via a
//! relative path inside store.zig.
pub const pool = @import("db/pool.zig");
pub const db_pool = pool;
pub const registry = @import("event_store/registry.zig");
pub const store = @import("event_store/store.zig");
pub const definition = @import("definition/store.zig");
pub const snapshot = @import("definition/snapshot.zig"); // PD-08
pub const export_import = @import("definition/export_import.zig"); // PD-09
pub const engine = @import("engine/instance.zig"); // EE-01
pub const tasks = @import("tasks/store.zig"); // EE-03
pub const task_routes = @import("api/routes/tasks.zig"); // API-04 / EE-04
pub const instance_routes = @import("api/routes/instances.zig"); // API-03 / OBS-04
pub const metrics_routes = @import("api/routes/metrics.zig"); // OBS-02
pub const audit_routes = @import("api/routes/audit.zig"); // OBS-03
pub const dlq_store = @import("dlq/store.zig"); // OBS-05
pub const dlq_routes = @import("api/routes/dlq.zig"); // OBS-05
pub const api_authorization = @import("api/authorization.zig"); // IDN-03
pub const scheduler = @import("scheduler/store.zig"); // SCH-01
pub const scheduler_poller = @import("scheduler/scheduler.zig"); // SCH-02
pub const reconstruction = @import("engine/reconstruction.zig"); // EE-11
pub const transition = @import("engine/transition.zig"); // EE-12
pub const service_task = @import("engine/service_task.zig"); // EXT-01
pub const plugin_interface = @import("engine/plugin_interface.zig"); // EXT-03
pub const plugin_registry = @import("engine/plugin_registry.zig"); // EXT-03
pub const api_auth = @import("api/middleware/auth.zig");
pub const identity_registry = @import("identity/registry.zig"); // IDN-01
pub const identity_service = @import("identity/service.zig"); // IDN-01
pub const identity_routes = @import("api/routes/identity.zig"); // IDN-01
pub const obs_metrics = @import("obs/metrics.zig"); // OBS-02
pub const obs_audit = @import("obs/audit.zig"); // OBS-03
pub const obs_alerts = @import("obs/alerts.zig"); // OBS-06
pub const webhooks_routes = @import("api/routes/webhooks.zig"); // EXT-02
pub const webhook_subscription_store = @import("webhook/subscription_store.zig"); // EXT-02
pub const webhook_dispatcher = @import("webhook/dispatcher.zig"); // EXT-02
