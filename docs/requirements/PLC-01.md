---
id: PLC-01
title: Process module catalog
stage: 15
priority: SHOULD
status: DRAFT
---

# PLC-01 — Process module catalog `[SHOULD]`

> **Extends:** the REPO-07 service catalog pattern, applied to reusable
> sub-process definitions instead of external services.

> The platform SHALL maintain a process module catalog registering reusable
> sub-process definitions with: `module_id` (stable name, unique per
> publishing tenant), `version` (semver string), `owning_definition_id` (the
> definition this version resolves to), `interface_schema` (the SPC-01
> contract declared at the module's entry point), `exportable` (boolean,
> default true — governs whether SOL-01 may inline this module's content
> into a solution pack), and `status` (DRAFT | ACTIVE | DEPRECATED). A
> SUB_PROCESS node MAY reference a catalog entry via `module_ref:
> {module_id, version_constraint}` instead of a tenant-local
> `child_definition_id`.

**Acceptance Criteria:**
- GIVEN a SUB_PROCESS node using `module_ref`, WHEN the node activates, THEN
  the platform resolves the highest ACTIVE version satisfying
  `version_constraint` that is visible to the tenant the parent instance is
  running in, and uses that version's `owning_definition_id` as the child
  definition.
- GIVEN no ACTIVE catalog version satisfies the constraint visible to the
  current tenant, WHEN the node activates, THEN the parent instance
  transitions to ERROR status per EE-10, identifying the unresolved module
  reference (mirrors ADP-08's service-not-found handling).
- GIVEN both `child_definition_id` and `module_ref` are present on the same
  node, WHEN the definition is created or updated, THEN it is rejected with
  HTTP 422 — the two mechanisms have different resolution scopes
  (tenant-local vs. catalog-resolved) so silent precedence, unlike ADP-08's
  url/service_id coexistence, is not safe to apply here.
- GIVEN a SUB_PROCESS node with neither `child_definition_id` nor
  `module_ref` present, WHEN the definition is created or updated, THEN it
  is rejected with HTTP 422 (this extends the existing
  `SUB_PROCESS_MISSING_CHILD_DEFINITION_ID` validation rule to require at
  least one of the two forms, rather than mandating `child_definition_id`
  unconditionally).
- Legacy SUB_PROCESS nodes using `child_definition_id` directly continue to
  work unchanged.

**See:** REPO-07 (service catalog precedent), ADP-08 (service_id resolution
precedent), EXT-05 (sub-process support), SPC-01 (interface contract carried
by a catalog entry), PLC-02 (publication gate), PLC-04 (cross-tenant
visibility), SOL-01 (`exportable` flag consumed on pack export)
