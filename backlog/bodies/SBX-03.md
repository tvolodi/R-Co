> **Extends:** SBX-01, denying the orchestrator execution authority over sandboxes.

> The sandbox claim endpoint SHALL reject any caller holding the `tenant_orchestrator` realm role with HTTP 403 `orchestrator_may_not_claim`, and SHALL require the `tenant_implementer` realm role, returning HTTP 403 `implementer_role_required` otherwise. The orchestrator retains supervisory read across every sandbox in its tenant through `GET /api/v1/agent/sandboxes`, which exposes state, owner principal, and `task_spec_id` and exposes no execution endpoint. An orchestrator therefore cannot drive a sandbox while holding cross-sandbox visibility.

**Acceptance Criteria:**
- GIVEN a caller holding `tenant_orchestrator`, WHEN it calls the claim endpoint, THEN the platform returns HTTP 403 `orchestrator_may_not_claim` and the sandbox remains unowned.
- GIVEN a caller holding neither agent realm role, WHEN it calls the claim endpoint, THEN the platform returns HTTP 403 `implementer_role_required`.
- GIVEN a caller holding `tenant_orchestrator`, WHEN it calls `GET /api/v1/agent/sandboxes`, THEN it receives state, owner principal, and `task_spec_id` for every sandbox in its tenant and for no sandbox outside it.
- GIVEN a caller holding `tenant_orchestrator`, WHEN it calls any sandbox execution route, THEN the platform returns HTTP 403 `orchestrator_may_not_claim`; supervisory read grants no execution path.
- GIVEN a caller holding `tenant_implementer`, WHEN it calls `GET /api/v1/agent/sandboxes`, THEN the listing is restricted to sandboxes bound to that principal.
- Every rejected claim appends `SandboxClaimRejected` naming the acting principal, the sandbox, and the rejection identifier.

**See:** SBX-01, SBX-04, SBX-05, SBX-06, IDN-05
