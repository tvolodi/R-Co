// main_test.zig — integration test entry point.
// Each comptime import below pulls its test blocks into zig build test-integration.
const std = @import("std");
const bpm = @import("bpm");
pub const api_tenant_context = bpm.api_tenant_context;
pub const api_pipeline_context = bpm.api_pipeline_context;

// Initialize default test tenant context (nil UUID) for all integration tests.
// This ensures PostgreSQL pool connections have bpm.tenant_id set correctly.
pub fn setTestTenantContext() void {
    api_tenant_context.set("00000000-0000-0000-0000-000000000000");
}

pub fn clearTestTenantContext() void {
    api_tenant_context.clear();
}

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
// Stage 3 — Task store integration (EE-03)
const ee03_task_store_integration = @import("ee03_task_store_test.zig");
// Stage 3 — Tasks API integration (EE-03/EE-04)
const ee03_ee04_tasks_api_integration = @import("ee03_ee04_tasks_api_test.zig");
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
// Stage 6.5 — Tenant realm binding and OIDC ownership invariants (ADP-04b)
const adp04b_tenant_realm_binding_integration = @import("adp04b_tenant_realm_binding_test.zig");
// Stage 6.5 — Artifact hash reference on instance (ADP-05)
const adp05_instance_artifact_hash_integration = @import("adp05_instance_artifact_hash_test.zig");
// Stage 6.5 — Pipeline run correlation on audit and events (ADP-06)
const adp06_pipeline_run_correlation_integration = @import("adp06_pipeline_run_correlation_test.zig");
// Stage 6.5 — Agent role and reserved usernames (ADP-07)
const adp07_agent_role_reserved_usernames_integration = @import("adp07_agent_role_reserved_usernames_test.zig");
// Stage 6.5 — Tamper-evident audit chain (ADP-09)
const adp09_tamper_evident_audit_chain_integration = @import("adp09_tamper_evident_audit_chain_test.zig");
// Stage 6.5 — Agent I/O capture in audit (ADP-10)
const adp10_agent_io_capture_audit_integration = @import("adp10_agent_io_capture_audit_test.zig");
// Stage 6.5 — Default-tenant migration-boundary regression suite (ADP-12)
const adp12_default_tenant_regression_integration = @import("adp12_default_tenant_regression_test.zig");
// Stage 6.5 — Tenant column and policy schema (ADP-02)
const adp02_tenant_scope = @import("adp02_tenant_scope_test.zig");
// Stage 6.5 — OIDC claim validation auth mapping (OIDC-07)
const oidc07_claim_validation_auth_integration = @import("oidc07_claim_validation_auth_test.zig");
// Stage 6.5 — Agent lifecycle foundations (OIDC-16..OIDC-26)
const oidc16_26_agent_lifecycle_foundations_integration = @import("oidc16_26_agent_lifecycle_foundations_test.zig");
// Stage 11 — Simulation mode foundations (SIM-01..SIM-04)
const sim01_04_simulation_mode_integration = @import("sim01_04_simulation_mode_test.zig");
// Stage 11 — Scenario schema/runner and batch execution (SIM-05..SIM-08)
const sim05_08_scenario_runner_integration = @import("sim05_08_scenario_runner_test.zig");
// SPT-01 — Schema-per-tenant provisioning infrastructure
const spt01_provisioning_integration = @import("spt01_provisioning_test.zig");
// Stage F8 — Tenant Management API (TM-01, TM-03)
const tm01_tenant_list_integration = @import("tm01_tenant_list_test.zig");
// Stage 12 — Schema isolation enforcement (TNT-01, TNT-02, TNT-03, TNT-04)
const tnt_schema_isolation_integration = @import("tnt_schema_isolation_test.zig");
// Stage 13 — Service catalog scope (SVC-01)
const svc01_service_catalog_scope_integration = @import("svc01_service_catalog_scope_test.zig");
// Stage 13 — Plugin registry tenant scoping (SVC-02)
const svc02_plugin_dispatch_scope_integration = @import("svc02_plugin_dispatch_scope_test.zig");
// Stage 13 — Definition activation scope validator (SVC-03)
const svc03_definition_activation_scope_integration = @import("svc03_definition_activation_scope_test.zig");
// Stage 13 — Admin API for service catalog (SVC-04)
const svc04_admin_api_integration = @import("svc04_admin_api_test.zig");
// Stage 14 — Tenant type field (ENV-01)
const env01_tenant_type_field_integration = @import("env01_test.zig");
// Stage 14 — Test tenant isolation (ENV-02)
const env02_tenant_isolation_integration = @import("env02_test.zig");
// Stage 14 — Definition promotion (ENV-03)
const env03_definition_promotion_integration = @import("env03_test.zig");
// Stage 14 — Test tenant lifecycle (ENV-05)
const env05_tenant_lifecycle_integration = @import("env05_test.zig");
// ISS-101 — timers.status FAILED constraint (allow 'failed' in timers.status CHECK)
const iss101_timers_failed_status_integration = @import("iss101_timers_failed_status_test.zig");
// EPIC-2 Run 1 — entities subsystem integration tests (EXP-201, EXP-202)
const exp201_202_entities_integration = @import("exp201_202_entities_test.zig");
// ISS-102 — tasks.claimed_by and real claim path
const iss102_claim_integration = @import("iss102_claim_test.zig");
// ISS-106 — webhook_deliveries transactional-outbox table formalization (attempt column,
// status CHECK domain, worker-claim index)
const iss106_webhook_outbox_integration = @import("iss106_webhook_outbox_test.zig");
// ISS-107 — tenant storage_mode column and schema-per-tenant provisioning
const iss107_tenant_storage_mode_integration = @import("iss107_tenant_storage_mode_test.zig");
// ISS-201 — TransitionResult atomic persistence (trigger + emitted_events)
const iss201_transition_result_integration = @import("iss201_transition_result_test.zig");
// ISS-202 — Two-phase (all-or-nothing) variable merge
const iss202_merge_atomicity_integration = @import("iss202_merge_atomicity_test.zig");
// EPIC-3 (ISS-301, ISS-302, ISS-303) — Scheduler concurrency and DLQ routing
const sch303_timer_dlq_integration = @import("sch303_timer_dlq_test.zig");
// EPIC-4 (EXP-401, EXP-402) — compensation metadata validation and restore reconciliation
const exp401_exp402_comp_restore_integration = @import("exp401_exp402_comp_restore_test.zig");
// ISS-502 — SPT cutover transaction (copy + verify + atomic storage_mode flip)
const iss502_spt_cutover_integration = @import("iss502_spt_cutover_test.zig");
// ISS-503 — GBL-084 RLS removal migration (pre-flight guard, DDL teardown, idempotency)
const iss503_rls_removal_integration = @import("test_iss503_rls_removal.zig");

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
    _ = ee03_task_store_integration;
    _ = ee03_ee04_tasks_api_integration;
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
    _ = adp04b_tenant_realm_binding_integration;
    _ = adp05_instance_artifact_hash_integration;
    _ = adp06_pipeline_run_correlation_integration;
    _ = adp07_agent_role_reserved_usernames_integration;
    _ = adp09_tamper_evident_audit_chain_integration;
    _ = adp10_agent_io_capture_audit_integration;
    _ = adp12_default_tenant_regression_integration;
    _ = adp02_tenant_scope;
    _ = oidc07_claim_validation_auth_integration;
    _ = oidc16_26_agent_lifecycle_foundations_integration;
    _ = sim01_04_simulation_mode_integration;
    _ = sim05_08_scenario_runner_integration;
    _ = spt01_provisioning_integration;
    _ = tm01_tenant_list_integration;
    _ = tnt_schema_isolation_integration;
    _ = svc01_service_catalog_scope_integration;
    _ = svc02_plugin_dispatch_scope_integration;
    _ = svc03_definition_activation_scope_integration;
    _ = svc04_admin_api_integration;
    _ = env01_tenant_type_field_integration;
    _ = env02_tenant_isolation_integration;
    _ = env03_definition_promotion_integration;
    _ = env05_tenant_lifecycle_integration;
    _ = iss101_timers_failed_status_integration;
    _ = exp201_202_entities_integration;
    _ = iss102_claim_integration;
    _ = iss106_webhook_outbox_integration;
    _ = iss107_tenant_storage_mode_integration;
    _ = iss201_transition_result_integration;
    _ = iss202_merge_atomicity_integration;
    _ = sch303_timer_dlq_integration;
    _ = exp401_exp402_comp_restore_integration;
    _ = iss502_spt_cutover_integration;
    _ = iss503_rls_removal_integration;
}

test "integration placeholder" {
    _ = std;
}
