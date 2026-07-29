---
id: SOL-01
title: Solution pack manifest
stage: 15
priority: MUST
status: DRAFT
---

# SOL-01 — Solution pack manifest `[MUST]`

> **Extends:** PD-09, generalized from a single definition to a
> dependency-closure bundle.

> The platform SHALL support exporting a "solution pack": a self-contained
> JSON document listing one or more process definitions, their transitive
> `module_ref` dependencies (PLC-01), the service catalog entries (REPO-07)
> referenced by any SERVICE_TASK in the set, and the variable schemas
> referenced by any variable key used in the set — together with a manifest
> listing every distinct ROLE name found in any HUMAN_TASK `assignee_ref`
> across the set (the roles the pack expects the installing tenant to
> provide). Each pack carries a `pack_id`, `version` (semver), and
> `bpm_export_schema_version`.

**Acceptance Criteria:**
- GIVEN a set of definitions selected for packaging, WHEN exported, THEN the
  resulting JSON includes every definition's full graph, every referenced
  service catalog entry, every referenced variable schema, and every
  distinct ROLE name from HUMAN_TASK `assignee_type = ROLE` nodes across the
  set.
- GIVEN a definition in the pack references a `module_ref` owned by a
  different tenant with no PLC-04 sharing grant to the installing tenant,
  WHEN exported, THEN the module's own definition content is inlined into
  the pack rather than left as an unresolved reference, unless the
  publishing tenant has marked the module non-exportable, in which case
  export fails with a structured error naming the blocking module.
- The manifest lists required roles in a form readable by a non-technical
  stakeholder without parsing the full graph JSON (a flat list of role
  names, not embedded in node attribute trees).

**See:** PD-09 (export/import mechanism reused), REPO-07 (service catalog),
PLC-01 (module dependency resolution), PLC-04 (cross-tenant module
inlining), IDN-05 (the role registry these role names are bound in per
installing tenant), SOL-02 (installation of the pack this produces)
