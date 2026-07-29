> **Extends:** SBX-04, defining release, reclaim, and the audit record for sandbox ownership.

> Only the bound `agent_principal` SHALL release a sandbox; a release by any other caller returns HTTP 403 `sandbox_not_accessible`. A sandbox whose owner has issued no request for 60 minutes SHALL be reclaimed by the pool manager, which clears the binding, sets state `released`, and appends `SandboxReclaimed` naming the prior owner. Claims, rejected claims, releases, and reclaims SHALL each append an audit entry carrying the acting principal, `tenant_id`, `sandbox_id`, and `task_spec_id`, so a probing burst is visible in the audit record even though SBX-05 gives the prober no response signal.

**Acceptance Criteria:**
- GIVEN a sandbox bound to `impl-a`, WHEN `impl-b` calls release, THEN the platform returns HTTP 403 `sandbox_not_accessible` and the binding is unchanged.
- GIVEN a sandbox bound to `impl-a`, WHEN an orchestrator calls release, THEN the platform returns HTTP 403 `sandbox_not_accessible`; supervisory read grants no release authority.
- GIVEN a sandbox bound to `impl-a`, WHEN `impl-a` calls release, THEN state becomes `released`, the binding row is cleared, and `SandboxReleased` is appended.
- GIVEN an owner that issues no request for 61 minutes, WHEN the pool manager evaluates idleness, THEN the sandbox is released, `SandboxReclaimed` is appended naming the prior owner, and the sandbox becomes claimable by another implementer.
- GIVEN a principal that triggers 30 sentinel responses in one minute, WHEN the audit log is read, THEN 30 `SandboxClaimRejected` entries name that principal and the requested `sandbox_id` values, and the entries carry the owning tenant even though no response did.
- GIVEN an implementing agent terminates while holding a claim, WHEN 60 minutes elapse, THEN the sandbox is reclaimed and its `task_spec_id` is claimable again without operator action.

**See:** SBX-04, SBX-05, SBX-03, OBS-03, XC-05, ADP-05
