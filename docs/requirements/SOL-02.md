---
id: SOL-02
title: Solution pack installation into a target tenant
stage: 15
priority: MUST
status: DRAFT
---

# SOL-02 — Solution pack installation into a target tenant `[MUST]`

> **Extends:** ENV-03, generalized from a fixed test-tenant →
> linked-production-tenant pairing to installation into any target tenant by
> ID.

> An authorised caller (PLATFORM_ADMIN, or PROCESS_DESIGNER holding install
> rights on the target tenant) SHALL be able to install a solution pack into
> any target tenant. Installation creates all bundled definitions as DRAFT,
> registers all bundled service catalog entries and variable schemas —
> reusing any existing entry with an identical name and schema, and
> rejecting the installation on conflict where an existing entry shares a
> name but not a schema — and returns a role-mapping checklist listing every
> manifest ROLE name with no binding yet registered in the target tenant's
> IDN-05 role registry.

**Acceptance Criteria:**
- GIVEN a valid solution pack and a target tenant with status ACTIVE, WHEN
  installation is requested, THEN all bundled definitions are created with
  status DRAFT, all service catalog and variable schema entries are
  registered or matched, and the response includes an explicit list of
  unresolved ROLE names.
- GIVEN a target tenant already has a service catalog entry with the same
  `service_id` but a different request/response schema than the pack's, WHEN
  installation is attempted, THEN it is rejected with HTTP 409 identifying
  the conflicting entry — no silent overwrite of tenant-owned catalog data.
- GIVEN a target tenant already has an identically-named, identically-schemaed
  service catalog entry, WHEN installation is attempted, THEN that entry is
  reused rather than duplicated.
- GIVEN installation completes, WHEN the installing caller lists definitions
  on the target tenant, THEN all bundled definitions appear with status
  DRAFT — an explicit activation step (REPO-08) is required before any of
  them run live; installation never auto-activates.
- GIVEN a target tenant not in ACTIVE status, WHEN installation is attempted,
  THEN HTTP 409 is returned (mirrors ENV-03's `ProductionTenantInactive`
  check).

**Edge cases:**
- Re-installing the same pack version into a tenant that already has it:
  idempotent — existing DRAFT definitions matching `pack_id` + `version` are
  left untouched; a warning, not an error, is returned.
- Installing pack version 2.0.0 over an existing 1.x installation: new DRAFT
  definitions are created alongside the 1.x definitions under existing PD-03
  versioning rules; 1.x definitions are not deleted or auto-deactivated.

**See:** ENV-03 (promotion precedent), PD-09 (export/import mechanism),
PD-03 (versioning rules), REPO-08 (atomic activation), IDN-05 (role registry
the checklist checks against), SOL-01 (the pack this installs), SOL-03
(activation gate on installed definitions)
