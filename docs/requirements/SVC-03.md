---
id: SVC-03
title: Definition activation validates service and plugin availability for the activating tenant
stage: 13
priority: MUST
status: RELEASED
---

# SVC-03 — Definition activation validates service and plugin availability for the activating tenant `[MUST]`

> When a process definition is activated (status set to `ACTIVE`), the platform
> SHALL validate that every SERVICE_TASK node's referenced service or plugin is
> available to the activating tenant. A definition that references a
> tenant-scoped service or plugin belonging to a different tenant MUST be
> rejected at activation time, not at runtime.

**Acceptance Criteria:**
- GIVEN a process definition D for tenant T contains a SERVICE_TASK node with
  `service_id = "X"`, WHEN D is activated, THEN the platform checks:
  - If `service_catalog` has an entry for `"X"` with `scope = 'global'`: PASS.
  - If `service_catalog` has an entry for `"X"` with `scope = 'tenant'` and
    `owner_tenant_id = T`: PASS.
  - If `service_catalog` has an entry for `"X"` with `scope = 'tenant'` and
    `owner_tenant_id ≠ T`: FAIL — HTTP 422,
    `"service X is not available to tenant T"`.
  - If `service_catalog` has no entry for `"X"`: FAIL — HTTP 422,
    `"service X is not registered"`.
- GIVEN a process definition D for tenant T contains a SERVICE_TASK node with
  `plugin_handler = "P"`, WHEN D is activated, THEN the platform checks the
  plugin registry: if P is `scope = .tenant` and `owner_tenant_id ≠ T`,
  activation is rejected with HTTP 422.
- GIVEN all SERVICE_TASK references resolve correctly for tenant T, WHEN D is
  activated, THEN activation proceeds normally per existing PD-08 rules.
- Activation validation is atomic: if any single SERVICE_TASK reference fails,
  the entire activation is rejected; no partial activation occurs.
- The validation runs at activation time (status DRAFT → ACTIVE) and also at
  re-activation time (DEPRECATED → ACTIVE); it does not run on DRAFT creation.

**See:** SVC-01 (service catalog scope), SVC-02 (plugin scope), PD-08
(definition snapshot and activation), ADP-08 (service task catalog reference)

**Edge cases:**
- A definition was activated when a service was global, then the service is
  changed to tenant-scoped for a different tenant: existing `ACTIVE` definition
  is not retroactively invalidated; the change takes effect on the next
  activation attempt.
- A definition references both a service_id (catalog lookup) and a
  plugin_handler (plugin registry lookup) on the same node: both are validated;
  both must pass.
- `service_id` and `plugin_handler` both absent on a SERVICE_TASK node: existing
  validation error (PD-05 node attribute check) catches this before SVC-03
  validation runs.
