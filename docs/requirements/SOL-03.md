---
id: SOL-03
title: Role-mapping completion gate before activation
stage: 15
priority: MUST
status: DRAFT
---

# SOL-03 — Role-mapping completion gate before activation `[MUST]`

**Extends:** IDN-05 (role registry), adding an activation-time completeness
check specific to solution-pack-installed definitions.

> A definition installed via SOL-02 MUST NOT be activatable (status DRAFT →
> ACTIVE) while any ROLE name from its solution pack's manifest has no
> binding in the target tenant's IDN-05 role registry. Activation attempts
> against an incomplete role mapping SHALL fail with HTTP 422 listing the
> unbound roles.

**Acceptance Criteria:**
- GIVEN a solution-pack-installed definition with 2 of 3 manifest roles
  still unbound in the target tenant's IDN-05 role registry, WHEN activation
  is attempted, THEN HTTP 422 is returned listing the 2 unbound role names.
- GIVEN all manifest roles are bound to a group in the target tenant's
  IDN-05 role registry, WHEN activation is attempted by an authorised
  caller, THEN normal REPO-08 atomic activation proceeds.
- This gate applies only to definitions created via SOL-02 installation;
  definitions created directly via PD-01 have no manifest and are
  unaffected.

**See:** SOL-01 (manifest source), SOL-02 (installation this gates), REPO-08
(activation mechanism), IDN-05 (the role registry this gate checks against)
