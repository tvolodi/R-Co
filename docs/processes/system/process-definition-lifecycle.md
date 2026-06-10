# Process: Process Definition Lifecycle

| Field | Value |
|-------|-------|
| Process ID | `sys-process-definition-lifecycle` |
| Owner | Platform Admin / Tenant Admin |
| Scope | System-wide (per-tenant namespace) |
| Source | `docs/BPM_Platform_Functional_Requirements.md` (PD-xx requirements) |

## Summary

Governs how process definitions (directed graphs of nodes and transitions) are
created, validated, published, versioned, and retired within a tenant's
namespace. A published definition can be instantiated; only the latest active
version is used for new instances. Older versions remain executable for
in-flight instances until they complete or are migrated.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Tenant Admin | Human or automation | Creates, updates, and publishes process definitions |
| BPM Platform | System | Validates graph structure, stores definitions, enforces versioning |
| Instance Executor | System | Instantiates and drives process instances against a pinned definition version |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `tenant_id` | UUID | Must refer to an active tenant |
| `process_key` | string | Unique within the tenant; identifies the process across versions |
| `name` | string | Human-readable name |
| `graph` | JSON | Nodes, transitions, and start-event definition |
| `event_type_ids` | string[] | Referenced event types must be registered in the tenant's registry |
| `version` (on update) | integer | Must be the current version + 1; optimistic concurrency |

---

## Steps

| # | Actor | Action | Decision | Outcome |
|---|-------|--------|----------|---------|
| 1 | Tenant Admin | Submit process definition via API | Auth check: caller has tenant-admin role? | → 403 Forbidden if not |
| 2 | Platform | Validate graph structure | Graph has exactly one start node? All transitions reference existing nodes? | → 422 Validation error with details |
| 3 | Platform | Validate event type references | All referenced event types exist in this tenant's registry? | → 422 Unresolved event type error |
| 4 | Platform | Persist definition as `draft` | Duplicate `process_key` + `version` combo? | → 409 Conflict |
| 5 | Tenant Admin | Publish definition via API (`POST .../publish`) | Definition in `draft` state? | → 400 if already published or retired |
| 6 | Platform | Set previous active version to `superseded` | Prior active version exists? | Mark it `superseded`; in-flight instances continue on old version |
| 7 | Platform | Set this version to `active` | — | New instance requests now use this version |
| 8 | Tenant Admin | Retire definition via API (`POST .../retire`) | In-flight instances on this version? | Retire is allowed; in-flight instances complete normally |
| 9 | Platform | Set version to `retired` | — | No new instances can be created; existing instances continue |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Single active version | At most one version of a given `process_key` is `active` at any time per tenant |
| Draft → Active only via publish | Cannot instantiate a `draft` definition |
| Retired definitions | In-flight instances on a retired version complete normally; no new instances |
| Superseded definitions | Behave like retired; exist for audit/lineage |
| Immutability | A published definition is immutable; changes require a new version |
| Graph validation | Must have exactly one start event; all node references in transitions must exist in the node list |
| Cross-tenant isolation | Process keys are scoped to `tenant_id`; the same key may exist in multiple tenants independently |
| Event type binding | All event types used in transitions must be registered in the same tenant's event type registry |

---

## Outputs

| Output | Description |
|--------|-------------|
| `definition_id` | UUID for this specific version |
| `process_key` | Stable identifier across versions |
| `version` | Integer version number |
| `status` | `draft` → `active` → `superseded` or `retired` |
| Audit log entry | Every state transition appended to the event log |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| No operational SLA | Definition lifecycle is admin-driven; no automated timers |
| API response | Governed by platform NFR: ≤ 200 ms read, ≤ 500 ms write |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 403 Forbidden | Caller lacks tenant-admin privilege | Authenticate with tenant-admin credentials |
| 422 Graph invalid | Missing start node, dangling transition reference | Fix the graph and resubmit |
| 422 Unresolved event type | Referenced event type not in registry | Register the event type first, then resubmit |
| 409 Conflict | Duplicate `process_key` + `version` | Increment version and resubmit |
| 400 Invalid state transition | Attempt to publish an already-active or retired definition | Check current status before publishing |
| Concurrent update | Two admins submit conflicting versions simultaneously | Optimistic concurrency check rejects the second; retry with current version |
