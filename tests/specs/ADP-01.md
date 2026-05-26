# Test Spec: ADP-01 — Tenant Column on Event Store

**Requirement:** ADP-01 — The event table and archive table include additive tenant_id with default-tenant backward compatibility, and all event store operations are tenant-scoped without cross-tenant leakage.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-ADP-01-01: default-tenant behavior remains backward compatible
**Given:** A legacy-style append/read path that does not pass explicit tenant context and an active instance in test DB.  
**When:** The event is appended and read through the existing event store APIs with default options.  
**Then:** Exactly the same default-tenant event is returned, matching pre-adaptation behavior.  
**Layer:** integration  
**Acceptance criterion mapped:** Automated tests cover default-tenant compatibility behavior.

### TC-ADP-01-02: tenant-scoped reads isolate events by tenant_id
**Given:** Two appends for the same instance using different tenant scopes (default tenant and non-default tenant).  
**When:** Ordered reads are performed once per tenant scope.  
**Then:** Each read returns only that tenant's events; no cross-tenant leakage occurs.  
**Layer:** integration  
**Acceptance criterion mapped:** Automated tests cover tenant-scoped behavior and non-regression.

### TC-ADP-01-03: migration provisions additive tenant columns/defaults and required indexes
**Given:** Migrations have been applied to the integration database.  
**When:** Schema metadata is queried for events/events_archive tenant_id columns and ADP-01 indexes.  
**Then:** Both tables expose non-null tenant_id with default default-tenant value, and all four tenant indexes exist.  
**Layer:** integration  
**Acceptance criterion mapped:** Migration-side expectations are explicitly covered.

### TC-ADP-01-04: append rejects empty tenant context deterministically
**Given:** A storage-layer append call that explicitly passes an empty tenant_id string.  
**When:** The append is executed.  
**Then:** The call fails with MissingTenantContext and writes no live/archive event rows for that idempotency key.  
**Layer:** integration  
**Acceptance criterion mapped:** Edge cases for missing tenant context are asserted deterministically.

## Traceability

- ADP-01 main acceptance: TC-ADP-01-01, TC-ADP-01-02, TC-ADP-01-03, TC-ADP-01-04.
- ES-01 (append immutability and validation path): TC-ADP-01-01, TC-ADP-01-04.
- ES-02 (ordered instance reads): TC-ADP-01-01, TC-ADP-01-02.
- ES-04 (tenant-partitioned global semantics baseline via tenant-scoped query behavior): TC-ADP-01-02.
- ES-06 (read contract continuity under tenant filter): TC-ADP-01-01, TC-ADP-01-02.
