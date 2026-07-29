---
id: IDN-05
title: Named role registry and ROLE assignee resolution
stage: 5
priority: MUST
status: DRAFT
---

# IDN-05 — Named role registry and ROLE assignee resolution `[MUST]`

<!-- CHANGE: Added 2026-07-21. Discovered as a prerequisite gap during
REQ-VALIDATOR review of Stage 15 (SOL-01, SOL-03): PD-05 declares HUMAN_TASK
assignee_type = ROLE as valid syntax, but no released requirement specifies
how a ROLE assignee_ref is registered or resolved to actual users. IDN-03
covers only the fixed 3-tier platform RBAC (PLATFORM_ADMIN /
PROCESS_DESIGNER / TASK_WORKER / PROCESS_OPERATOR), a different concept from
an open-ended, tenant-defined business role name. Without this requirement,
SOL-01's "role the pack expects the tenant to provide" and SOL-03's "role
mapping" gate are not testable. -->

**Extends:** IDN-02 (groups), PD-05 (HUMAN_TASK `assignee_type = ROLE`).

> The platform SHALL maintain a per-tenant registry mapping named business
> roles — distinct from the fixed platform RBAC roles of IDN-03 — to a
> group. A HUMAN_TASK node's `assignee_ref` for `assignee_type = ROLE` names
> a role in this registry. At task activation (EE-03), the platform resolves
> the named role to its bound group and creates the Task with GROUP
> semantics (any ACTIVE member of the bound group may claim and complete it,
> per IDN-02).

**Acceptance Criteria:**
- GIVEN a PLATFORM_ADMIN or a tenant admin holding PROCESS_DESIGNER
  registers a role name bound to an existing `group_id` in a tenant, WHEN a
  HUMAN_TASK node with `assignee_type = ROLE` and matching `assignee_ref`
  activates in that tenant, THEN the Task is created and any ACTIVE member
  of the bound group may claim and complete it.
- GIVEN a HUMAN_TASK node's `assignee_ref` (ROLE type) has no binding in the
  current tenant's role registry, WHEN the node activates, THEN the Task is
  still created in PENDING status, mirroring EE-03's existing "group with no
  current members" edge case; the instance does NOT transition to ERROR.
- Role names are scoped per tenant: the same role name string MAY be bound
  to different groups in different tenants. This is the mechanism a
  solution pack manifest (SOL-01) relies on — a pack lists role names, and
  each installing tenant independently binds them.
- `GET /roles` lists registered role names and their bound `group_id` for
  the calling tenant.
- `POST /roles` with `{ "name": "...", "group_id": "..." }` creates or
  updates a binding; a non-existent `group_id` MUST cause HTTP 404.

**See:** IDN-02 (groups), IDN-03 (distinguishes the fixed platform RBAC
roles from these named business roles — same word, different concept),
PD-05 (`assignee_type = ROLE`), EE-03 (task activation and the existing
no-members edge case), SOL-01 (manifest lists role names), SOL-03
(activation gate checks bindings against this registry)

**Edge cases:**
- A role name registered in one tenant has no effect in any other tenant
  (scoping mirrors IDN-02 group scoping).
- Re-binding a role name to a different group: existing PENDING tasks
  already created under the old binding are unaffected (mirrors IDN-02's
  "removing a user from a group does not affect already-assigned tasks").
