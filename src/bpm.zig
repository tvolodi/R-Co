//! Single-root re-export shim used by integration tests.
//!
//! Having one module root prevents "file exists in two modules" conflicts
//! that arise when pool.zig is both a named-module root AND imported via a
//! relative path inside store.zig.
pub const pool = @import("pool");
pub const db_pool = pool;
pub const registry = @import("event_store/registry.zig");
pub const store = @import("event_store/store.zig");
pub const definition = @import("definition/store.zig");
pub const snapshot = @import("definition/snapshot.zig"); // PD-08
pub const export_import = @import("definition/export_import.zig"); // PD-09
pub const engine = @import("engine/instance.zig"); // EE-01
pub const pin_resolver = @import("engine/pin_resolver.zig"); // PIN-01
pub const pin_rebind = @import("engine/pin_rebind.zig"); // PIN-05
pub const pin_rebind_routes = @import("api/routes/pin_rebind.zig"); // PIN-05
pub const tasks = @import("tasks/store.zig"); // EE-03
pub const task_routes = @import("api/routes/tasks.zig"); // API-04 / EE-04
pub const instance_routes = @import("api/routes/instances.zig"); // API-03 / OBS-04
pub const metrics_routes = @import("api/routes/metrics.zig"); // OBS-02
pub const health_routes = @import("api/routes/health.zig"); // API-12
pub const tenant_config_routes = @import("api/routes/tenant_config.zig"); // OIDC-F-05
pub const api_health_readiness = @import("api/health/readiness.zig"); // API-12
pub const audit_routes = @import("api/routes/audit.zig"); // OBS-03
pub const dlq_store = @import("dlq/store.zig"); // OBS-05
pub const dlq_routes = @import("api/routes/dlq.zig"); // OBS-05
pub const api_authorization = @import("api/authorization.zig"); // IDN-03
pub const scheduler = @import("scheduler/store.zig"); // SCH-01
pub const scheduler_poller = @import("scheduler/scheduler.zig"); // SCH-02
// PAR-05 (WF02-batch-4-20260811): partition_maintenance is now reached via
// the SAME named module `@import("partition_maintenance")` that
// src/db/partition_conversion.zig also depends on (build.zig's
// partition_maintenance_mod), rather than the relative
// `@import("scheduler/partition_maintenance.zig")` this line used before.
// Both this file (bpm_src_mod) and partition_conversion_mod now pull in
// partition_maintenance.zig's compiled unit — a relative import here
// alongside partition_conversion's named-module import of the same file
// would violate Zig 0.16's single-owner module rule ("file exists in
// multiple modules"), the identical class of conflict partition_attach's
// own named-module re-export (below) was already introduced to avoid.
pub const partition_maintenance = @import("partition_maintenance");
pub const partition_retention = @import("scheduler/partition_retention.zig"); // PAR-03
// PAR-04: named module, not a relative @import. partition_maintenance.zig and
// partition_retention.zig (both relatively owned by THIS file, re-exported
// above) each import partition_attach.zig as the named module
// `@import("partition_attach")` (see build.zig's partition_attach_mod
// comment — their own standalone addTest roots cannot reach src/db/ via a
// relative path that escapes their module root). A second, relative
// ownership of the same file from here would violate Zig 0.16's single-owner
// module rule the same way src/lua/ vs src/simulation/ already documents
// above — so this re-export uses the identical named module instead of
// `@import("db/partition_attach.zig")`.
pub const partition_attach = @import("partition_attach");
// PAR-05: named module — see partition_maintenance's comment above for the
// identical rationale (src/db/partition_conversion.zig cannot be reached
// both relatively-from-nowhere and as partition_conversion_mod's own root).
pub const partition_conversion = @import("partition_conversion");
pub const reconstruction = @import("engine/reconstruction.zig"); // EE-11
pub const transition = @import("engine/transition.zig"); // EE-12
pub const snapshot_writer = @import("engine/snapshot_writer.zig"); // ISS-601
pub const service_task = @import("engine/service_task.zig"); // EXT-01
pub const plugin_interface = @import("engine/plugin_interface.zig"); // EXT-03
pub const plugin_registry = @import("engine/plugin_registry.zig"); // EXT-03
pub const api_auth = @import("api/middleware/auth.zig");
pub const api_tenant_context = @import("tenant_context");
pub const api_pipeline_context = @import("pipeline_context");
pub const trace_context = @import("api/trace_context.zig");
pub const uuid = @import("util/uuid.zig");
pub const identity_registry = @import("identity/registry.zig"); // IDN-01
pub const identity_service = @import("identity/service.zig"); // IDN-01
pub const identity_routes = @import("api/routes/identity.zig"); // IDN-01
pub const role_registry = @import("identity/role_registry.zig"); // IDN-05
pub const oidc_agent_lifecycle = @import("oidc/agent_lifecycle.zig"); // OIDC-16..26
pub const obs_metrics = @import("obs_metrics"); // OBS-02
pub const obs_audit = @import("obs/audit.zig"); // OBS-03
pub const obs_alerts = @import("obs/alerts.zig"); // OBS-06
pub const webhooks_routes = @import("api/routes/webhooks.zig"); // EXT-02
pub const webhook_subscription_store = @import("webhook/subscription_store.zig"); // EXT-02
pub const webhook_dispatcher = @import("webhook/dispatcher.zig"); // EXT-02
pub const onboarding_mod = @import("identity/onboarding.zig"); // OIDC-35
pub const onboarding_routes = @import("api/routes/onboarding.zig"); // OIDC-35
pub const identity_provider = @import("identity_provider"); // OIDC provider contract
pub const simulation = @import("simulation/mod.zig"); // SIM-01..SIM-04
pub const simulation_runner = @import("simulation/scenario_runner.zig"); // SIM-05..SIM-08
pub const simulation_test_routes = @import("api/routes/simulation_test.zig"); // SIM-07..SIM-08
pub const provisioning = @import("db/provisioning.zig"); // SPT-01
pub const migrations = @import("db/migrations.zig"); // SPT-01
pub const ddl_namespace = @import("platform/ddl_namespace.zig"); // DDL-05
pub const ddl_validate = @import("platform/ddl_validate.zig"); // DDL-01
pub const migration_fanout = @import("platform/migration_fanout.zig"); // MIG-02, MIG-03, MIG-04, MIG-05
pub const platform_migrations_routes = @import("api/routes/platform_migrations.zig"); // MIG-06
pub const pending_migration_gate = @import("operations/pending_migration_gate.zig"); // MIG-06 AC5
pub const bootstrap_audit = @import("bootstrap/audit.zig"); // TNT-04
pub const tenant_migration = @import("admin/tenant_migration.zig"); // TNT-06
pub const tenant_status = @import("api/middleware/tenant_status.zig"); // TNT-06
pub const service_catalog = @import("repository/service_catalog.zig"); // SVC-01, SVC-04
// ISS-0137 / GH #439: exp601_tier_quota_test.zig reached these two by relative
// path (../../src/...), which escapes the tests/integration module root and
// Zig 0.16 rejects. Re-exporting here is what this shim is for — every other
// integration test reaches src/ through `bpm`, and tenant_status above is the
// direct precedent for re-exporting an api/middleware module.
pub const quota_policy = @import("config/quota_policy.zig"); // EXP-601
pub const quota_enforcement = @import("api/middleware/quota_enforcement.zig"); // EXP-601
pub const service_scope_validator = @import("definition/service_scope_validator.zig"); // SVC-03
pub const services_routes = @import("api/routes/services.zig"); // SVC-04
pub const effects_mod = @import("effects/mod.zig"); // EXP-301/302/303 async effects subsystem
pub const effects_stub = @import("effects/stub.zig"); // EXP-303 stub executor
pub const effects_queue = @import("effects/queue.zig"); // EXP-301 outbox queue
pub const effects_worker = @import("effects/worker.zig"); // EXP-301 worker loop
pub const secrets = @import("secrets/mod.zig"); // EXP-501 secrets provider surface
pub const promotion_mod = @import("definition/promotion.zig"); // ENV-03 definition promotion domain
pub const promotion_routes = @import("api/routes/promotion.zig"); // ENV-03 promotion HTTP handler
pub const promotion_plan_mod = @import("definition/promotion_plan.zig"); // PRM-01 promotion plan and diff report
pub const promotions_routes = @import("api/routes/promotions.zig"); // PRM-01 promotion plan HTTP handler
pub const tenant_lifecycle_admin = @import("admin/tenant_lifecycle.zig"); // ENV-05 reset/delete lifecycle
pub const entities = @import("entities/mod.zig"); // EXP-201/EXP-202 entities subsystem

// ISS-0147 / GH #463 — src/wasm subsystem (WASM-01..14, all RELEASED).
//
// Imported BY NAME, not by relative path. Every file under src/wasm/ reaches
// its siblings relatively (engine.zig -> wasmtime_bindings.zig, executor.zig ->
// five siblings, ...), so those files are already owned by `wasm_mod`
// (build.zig, root src/wasm/mod.zig). Writing @import("wasm/mod.zig") here
// would enrol the same files into bpm_src_mod as well and Zig 0.16 rejects the
// build with "file exists in multiple modules" — the Single-Owner Module Rule
// documented against src/repository and src/oidc in build.zig.
//
// No Wasmtime link is configured and none is needed: src/wasm/ contains zero
// @cImport and zero linkSystemLibrary. wasmtime_bindings.zig declares only
// `extern struct`/`extern union` TYPES — a memory-layout qualifier, not a
// link-time symbol reference — and every binding fn is an `inline fn` stub
// returning a failure sentinel (`engine_new` -> null, `module_new` -> 1).
// Real @cImport bindings land in Stage 10 per that file's own header comment;
// linking Wasmtime is a Stage 10 concern, not a prerequisite for compiling
// this subsystem today.
pub const wasm = @import("wasm"); // WASM-01..14

// ISS-0153 / GH #471 — src/lua subsystem (LUA-01..16).
//
// Deliberately NOT re-exported here, unlike `wasm` above, and that asymmetry is
// intentional rather than an oversight.
//
// src/lua/host_api/call_service.zig and host_api/now.zig import
// `../../simulation/*.zig`, and src/simulation/types.zig imports
// `../event_store/store.zig`. Those files are already plain members of THIS
// module (bpm_src_mod) via `pub const simulation = @import("simulation/mod.zig")`
// above. Making src/lua/mod.zig a named module root as well would enrol the
// simulation and event_store files into two modules at once and Zig 0.16
// rejects that with "file exists in multiple modules" — the Single-Owner Module
// Rule. Re-exporting it relatively from here instead would work, but would drag
// libc into every target that imports `bpm` (executor.zig's defaultAlloc uses
// std.c.malloc/realloc/free for the LuaJIT C-ABI allocator).
//
// The subsystem is instead kept analysed by a dedicated addTest root,
// src/lua_test_root.zig (`zig build test-lua`, also reached by `zig build
// test`), which is what stops it rotting silently again. See that file for the
// full account of what this wiring caught, and src/lua/luajit_bindings.zig for
// the evidence that no LuaJIT is available to link.
