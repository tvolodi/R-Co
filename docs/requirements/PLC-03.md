---
id: PLC-03
title: Cross-version compatibility check on publish
stage: 15
priority: SHOULD
status: DRAFT
---

# PLC-03 — Cross-version compatibility check on publish `[SHOULD]`

> When a new version of an already-cataloged module is published, the
> platform SHOULD compare its declared interface against the immediately
> preceding ACTIVE version and flag — without blocking — breaking changes: an
> input that was optional and is now required, or an output that was
> previously required and has been removed.

**Acceptance Criteria:**
- GIVEN version 1.1.0 of a module removes a previously optional input, WHEN
  published, THEN publication succeeds and a `COMPATIBILITY_WARNING` is
  recorded and returned in the response body.
- GIVEN version 2.0.0 removes a previously-required output, WHEN published,
  THEN the same warning is recorded; publication is not blocked (SHOULD, not
  MUST — a major version bump may be an intentional breaking change).

**See:** PLC-01 (catalog versioning), PLC-02 (publication gate)
