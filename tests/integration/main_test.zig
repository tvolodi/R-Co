// main_test.zig — integration test entry point.
// Each comptime import below pulls its test blocks into zig build test-integration.
const std = @import("std");
const bpm = @import("bpm");
pub const api_tenant_context = bpm.api_tenant_context;

// Integration test helpers (TestHarness with rollback-on-deinit isolation).
const helpers = @import("helpers.zig");
// Stage 1 — DB layer
const db_integration = @import("db_integration_test.zig");
// Stage 1 — Event store layer
const event_store_integration = @import("event_store_integration_test.zig");
// Stage 2 — Process definition layer (PD-01, PD-02)
const definition_integration = @import("definition_test.zig");
// Stage 2 — Version management (PD-03)
const pd03_version_integration = @import("pd03_version_test.zig");
// Stage 2 — Definition lifecycle (PD-04)
const pd04_lifecycle_integration = @import("pd04_lifecycle_test.zig");
// Stage 2 — Node types (PD-05)
const pd05_node_types_integration = @import("pd05_node_types_test.zig");
// Stage 2 — Definition snapshot (PD-08)
const test_snapshot_integration = @import("test_snapshot_integration.zig");
// Stage 2 — Definition import/export (PD-09)
const test_export_import_integration = @import("test_export_import_integration.zig");
// Stage 2 — Definition search (PD-10)
const pd10_search_integration = @import("pd10_search_test.zig");
// Stage 3 — Start instance (EE-01)
const ee01_start_instance_integration = @import("ee01_start_instance_test.zig");
// Stage 3 — Instance cancellation (EE-08)
const ee08_cancel_instance_integration = @import("ee08_cancel_instance_test.zig");
// Stage 3 — Variable scoping and merge (EE-09)
const ee09_merge_variables_integration = @import("ee09_merge_variables_test.zig");
// Stage 3 — Execution error handling (EE-10)
const ee10_instance_error_integration = @import("instance_error_test.zig");
// Stage 6 — Service task node type (EXT-01)
const ext01_service_task_integration = @import("ext01_service_task_test.zig");
// Stage 6 — Webhook event dispatch (EXT-02)
const ext02_webhook_dispatch_integration = @import("ext02_webhook_dispatch_test.zig");
// Stage 6 — Plugin interface (EXT-03)
const ext03_plugin_integration = @import("ext03_plugin_integration_test.zig");
// Stage 6 — Variable transformer (EXT-04)
const ext04_variable_transformer_integration = @import("ext04_variable_transformer_test.zig");
// Stage 6 — Sub-process support (EXT-05)
const ext05_sub_process_support_integration = @import("ext05_sub_process_support_test.zig");
// Stage 3 — Concurrent instance safety (EE-12)
const ee12_concurrent = @import("concurrent_instances_test.zig");
// Stage 5 — Durable timer creation (SCH-01)
const sch01_timer_creation_integration = @import("sch01_timer_creation_test.zig");
// Stage 5 — Timer polling and firing (SCH-02)
const sch02_timer_polling_integration = @import("sch02_timer_polling_test.zig");
// Stage 5 — Identity user registry integration (IDN-01)
const idn01_user_registry_integration = @import("idn01_user_registry_test.zig");
// Stage 5 — Identity group management integration (IDN-02)
const idn02_group_management_integration = @import("idn02_group_management_test.zig");
// Stage 5 — Role-based access integration (IDN-03)
const idn03_role_access_integration = @import("idn03_role_access_test.zig");
// Stage 5 — API token management integration (IDN-04)
const idn04_api_token_management_integration = @import("idn04_api_token_management_test.zig");
// Stage 4 — Process definition CRUD API (API-02)
const api02_crud_integration = @import("api02_crud_test.zig");
// Stage 4 — Instance read endpoints (API-03)
const api03_instance_read_integration = @import("api03_instance_read_test.zig");
// Stage 4 — Request tracing (API-09)
const api09_trace_integration = @import("trace_test.zig");
// Stage 6 — Prometheus metrics endpoint (OBS-02)
const obs02_metrics_integration = @import("obs02_metrics_test.zig");
// Stage 6 — Immutable audit log (OBS-03)
const obs03_audit_integration = @import("obs03_audit_log_test.zig");
// Stage 6 — Instance timeline endpoint (OBS-04)
const obs04_timeline_integration = @import("obs04_timeline_test.zig");
// Stage 6 — Dead letter queue (OBS-05)
const obs05_dlq_integration = @import("obs05_dlq_test.zig");
// Stage 6 — Alerting hooks (OBS-06)
const obs06_alerts_integration = @import("obs06_alerts_test.zig");
// Stage 6.5 — Tenant context resolution on API (ADP-03)
const adp03_tenant_context_integration = @import("adp03_tenant_context_resolution_test.zig");
// Stage 6.5 — User tenant binding and identity isolation (ADP-04)
const adp04_user_tenant_binding_integration = @import("adp04_user_tenant_binding_test.zig");
// Stage 6.5 — External identity linkage on users (ADP-04a)
const adp04a_external_identity_linkage_integration = @import("adp04a_external_identity_linkage_test.zig");

comptime {
    _ = std;
    _ = helpers;
    _ = db_integration;
    _ = event_store_integration;
    _ = definition_integration;
    _ = pd03_version_integration;
    _ = pd04_lifecycle_integration;
    _ = pd05_node_types_integration;
    _ = test_snapshot_integration;
    _ = test_export_import_integration;
    _ = pd10_search_integration;
    _ = ee01_start_instance_integration;
    _ = ee08_cancel_instance_integration;
    _ = ee09_merge_variables_integration;
    _ = ee10_instance_error_integration;
    _ = ext01_service_task_integration;
    _ = ext02_webhook_dispatch_integration;
    _ = ext03_plugin_integration;
    _ = ext04_variable_transformer_integration;
    _ = ext05_sub_process_support_integration;
    _ = ee12_concurrent;
    _ = sch01_timer_creation_integration;
    _ = sch02_timer_polling_integration;
    _ = idn01_user_registry_integration;
    _ = idn02_group_management_integration;
    _ = idn03_role_access_integration;
    _ = idn04_api_token_management_integration;
    _ = api02_crud_integration;
    _ = api03_instance_read_integration;
    _ = api09_trace_integration;
    _ = obs02_metrics_integration;
    _ = obs03_audit_integration;
    _ = obs04_timeline_integration;
    _ = obs05_dlq_integration;
    _ = obs06_alerts_integration;
    _ = adp03_tenant_context_integration;
    _ = adp04_user_tenant_binding_integration;
    _ = adp04a_external_identity_linkage_integration;
}

test "integration placeholder" {
    _ = std;
}
