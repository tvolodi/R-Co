> **Extends:** SBX-03, binding a sandbox to exactly one implementing agent.

> A claim SHALL bind the sandbox to the triple `(tenant_id, agent_principal, task_spec_id)` under the unique index `ux_sandbox_owner`. One sandbox has exactly one owner, and one task spec has exactly one sandbox. A claim against a sandbox already bound to a different principal SHALL return HTTP 409 `sandbox_already_claimed` without naming the current owner. Every request that operates inside a claimed sandbox SHALL be checked against the bound `agent_principal`, and a mismatch SHALL return the SBX-05 sentinel rather than a distinct error.

**Acceptance Criteria:**
- GIVEN an unowned sandbox in the caller's tenant, WHEN an implementer claims it with a `task_spec_id`, THEN the binding row is written, `claimed_at` is set, and the platform returns HTTP 201.
- GIVEN a sandbox bound to principal `impl-a`, WHEN principal `impl-b` in the same tenant claims it, THEN the platform returns HTTP 409 `sandbox_already_claimed` and the response body does not name `impl-a`.
- GIVEN a sandbox bound to `impl-a` for `task_spec_id` T, WHEN `impl-a` claims a second sandbox for the same T, THEN the platform returns HTTP 409 `sandbox_already_claimed`; the unique index covers the task spec as well as the sandbox.
- GIVEN a sandbox bound to `impl-a`, WHEN `impl-b` issues an execution request inside it, THEN the platform returns HTTP 403 `sandbox_not_accessible`, the same sentinel returned for an unknown sandbox.
- GIVEN two implementers claim one unowned sandbox concurrently, WHEN both execute, THEN the unique index admits exactly one binding and the other receives HTTP 409 `sandbox_already_claimed`.
- GIVEN a released sandbox, WHEN it is claimed again, THEN a new binding row is written and the prior owner has no residual access.

**See:** SBX-03, SBX-05, SBX-06, AGT-03, TNT-01
