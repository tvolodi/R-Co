# SPT-04 — Test Suite Update and ADP-12 Regression

## Requirement Reference

- Requirement: SPT-04
- Parent requirements: SPT-03, ADP-12, DB-01, DB-03
- Status: TEST-DESIGNED

## Purpose

Update the integration test suite to reflect the schema-per-tenant isolation
architecture introduced by SPT-01/02/03.  Migration 062 dropped `tenant_id`
columns from all public-schema tables.  Any test that previously inserted rows
with explicit `tenant_id` values must be updated to remove those references.

---

## Test Cases

### TC-SPT-04-01: tenant_id columns removed from all public core tables

**Acceptance criterion:** AC-02-01 (via adp02_tenant_scope_test.zig, TC-ADP-02-01)

**Test file:** `tests/integration/adp02_tenant_scope_test.zig`

**Description:** Query `information_schema.columns` and verify `tenant_id`
does not exist in `process_definitions`, `instance_projections`, `tasks`,
`tokens`, `audit_entries`, `audit_log`.  Verify `tenant_schemas` registry
table exists and `bpm_provision_tenant_schema` function exists.

**Test type:** Integration (PostgreSQL)  
**Status:** IMPLEMENTED

---

### TC-SPT-04-02: Schema-per-tenant isolation for process definitions

**Acceptance criterion:** AC-02-02

**Test file:** `tests/integration/adp02_tenant_scope_test.zig`

**Description:** Provision two tenant schemas; insert a definition with the
same name in each schema; verify that querying from schema A returns only
schema A's definition and vice versa.

**Test type:** Integration (PostgreSQL)  
**Status:** IMPLEMENTED

---

### TC-SPT-04-03: instance_projections in tenant schema via search_path

**Acceptance criterion:** AC-02-03

**Test file:** `tests/integration/adp02_tenant_scope_test.zig`

**Description:** Provision a tenant schema; insert an instance_projection;
verify it is accessible via `SET search_path`.

**Test type:** Integration (PostgreSQL)  
**Status:** IMPLEMENTED

---

### TC-SPT-04-04: Task isolation in tenant schemas

**Acceptance criterion:** AC-02-04

**Test file:** `tests/integration/adp02_tenant_scope_test.zig`

**Description:** Provision two tenant schemas; insert tasks in each; verify
cross-schema isolation.

**Test type:** Integration (PostgreSQL)  
**Status:** IMPLEMENTED

---

### TC-SPT-04-05: audit_entries work without tenant_id in public schema

**Acceptance criterion:** AC-02-05

**Test file:** `tests/integration/adp02_tenant_scope_test.zig`

**Description:** Insert two audit entries without tenant_id; verify both
are accessible from any context (no RLS in public schema after SPT-02).

**Test type:** Integration (PostgreSQL)  
**Status:** IMPLEMENTED

---

### TC-SPT-04-06: All other failing integration tests compile and pass

**Acceptance criterion:** `zig build test-integration` exits 0

**Test files modified:**
- `tests/integration/adp03_tenant_context_resolution_test.zig`
- `tests/integration/adp09_tamper_evident_audit_chain_test.zig`
- `tests/integration/adp10_agent_io_capture_audit_test.zig`
- `tests/integration/event_store_integration_test.zig`
- `tests/integration/helpers.zig`
- `tests/integration/obs04_timeline_test.zig`
- `tests/integration/sim01_04_simulation_mode_test.zig`
- `tests/integration/xc01_trace_propagation_test.zig`
- `tests/integration/xc02_audit_immutability_test.zig`
- `tests/integration/xc03_configuration_repository_test.zig`
- `tests/integration/adp04_user_tenant_binding_test.zig`
- `tests/integration/adp04a_external_identity_linkage_test.zig`
- `tests/integration/adp04b_tenant_realm_binding_test.zig`
- `tests/integration/oidc09_jit_provisioning_test.zig`
- `tests/integration/oidc11_identity_stability_test.zig`
- `tests/integration/oidc12_realm_tenant_binding_test.zig`
- `tests/integration/oidc15_realm_deletion_test.zig`
- `tests/integration/oidc34_migration_helper_test.zig`

**Migration added:**
- `migrations/067_spt04_fix_audit_validate_chain.sql`

**Test type:** Integration (PostgreSQL)  
**Status:** IMPLEMENTED

---

## Coverage Map

| Test ID | Requirement | Acceptance Criterion |
|---|---|---|
| TC-SPT-04-01 | SPT-04 | AC-1: no tenant_id in public tables |
| TC-SPT-04-02 | SPT-04, ADP-02 | AC-2: schema isolation for process_definitions |
| TC-SPT-04-03 | SPT-04, ADP-02 | AC-3: instance_projections via search_path |
| TC-SPT-04-04 | SPT-04, ADP-02 | AC-4: task isolation in schemas |
| TC-SPT-04-05 | SPT-04, ADP-02 | AC-5: audit_entries without tenant_id |
| TC-SPT-04-06 | SPT-04 | AC-2: all integration tests pass |

## Infrastructure requirements

- PostgreSQL at `BPM_TEST_DB_URL`
- `zig build test-integration` must set `BPM_TEST_DB_URL` before execution
- Migration 067 must be applied (auto-applied by TestHarness)
