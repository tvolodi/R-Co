---
id: PLC-02
title: Catalog entry publication requires a declared interface
stage: 15
priority: SHOULD
status: DRAFT
---

# PLC-02 — Catalog entry publication requires a declared interface `[SHOULD]`

> A process module MAY be published to the catalog (status DRAFT → ACTIVE)
> only if the SUB_PROCESS entry point it exposes has a fully declared SPC-01
> interface. A module without a declared interface cannot be published as a
> catalog entry; it remains usable only as an ordinary tenant-local
> sub-process via direct `child_definition_id`.

**Acceptance Criteria:**
- GIVEN a module whose designated entry point has no declared `interface`,
  WHEN publication (DRAFT → ACTIVE) is attempted, THEN HTTP 422 is returned
  identifying the missing interface.
- GIVEN a module with a fully declared interface, WHEN publication is
  attempted by a caller holding PROCESS_DESIGNER or above, THEN status
  transitions to ACTIVE and the module becomes resolvable via `module_ref`.

**See:** SPC-01 (the required interface), PLC-01 (catalog entry shape)
