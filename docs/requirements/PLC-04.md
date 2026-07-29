---
id: PLC-04
title: Cross-tenant module distribution
stage: 15
priority: SHOULD
status: DRAFT
---

# PLC-04 — Cross-tenant module distribution `[SHOULD]`

> A process module published to the catalog by one tenant (the "publishing
> tenant") MAY be shared to other tenants ("subscribing tenants") via an
> explicit platform-admin-authorised sharing grant. A subscribing tenant sees
> only modules explicitly granted to it; by default, no tenant's catalog is
> visible to any other tenant. `module_ref` resolution (PLC-01) only
> considers versions visible to the resolving tenant.

**Acceptance Criteria:**
- GIVEN no sharing grant exists between tenant A's catalog and tenant B,
  WHEN tenant B's SUB_PROCESS node references a `module_id` owned by tenant
  A, THEN resolution fails via PLC-01's not-found path — indistinguishable
  from a nonexistent module, so no information about tenant A's catalog is
  leaked.
- GIVEN a PLATFORM_ADMIN grants tenant B visibility into a specific
  `module_id` owned by tenant A, WHEN tenant B references that `module_id`,
  THEN resolution succeeds using tenant A's ACTIVE versions.
- GIVEN a sharing grant is revoked, WHEN a subscribing tenant already has a
  running instance with an active child instantiated from the revoked
  module, THEN that running instance is unaffected — grants govern new
  activations only, never retroactive termination.

**See:** PLC-01 (module resolution), Stage SPT (tenant isolation model this
must not violate)
