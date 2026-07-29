> **Extends:** IDN-05, separating the orchestrating agent from the implementing agent at the API layer.

> Task-spec submission at `POST /api/v1/agent/task-specs` SHALL require the `agent.submit_task_spec` scope AND the `tenant_orchestrator` realm role on the verified token. Either credential alone SHALL return HTTP 403 `orchestrator_role_required`. The check SHALL execute in the request handler, not in a gateway rule and not by deploying the two agent classes to separate network segments, so a direct call to the service port is subject to the same gate. A principal holding both `tenant_orchestrator` and `tenant_implementer` SHALL be rejected at token verification with HTTP 403 `conflicting_agent_roles`.

**Acceptance Criteria:**
- GIVEN a token carrying `agent.submit_task_spec` but not the `tenant_orchestrator` realm role, WHEN a task spec is submitted, THEN the platform returns HTTP 403 `orchestrator_role_required` and writes no `task_specs` row.
- GIVEN a token carrying the `tenant_orchestrator` realm role but not the `agent.submit_task_spec` scope, WHEN a task spec is submitted, THEN the same HTTP 403 `orchestrator_role_required` is returned.
- GIVEN a token carrying both credentials, WHEN a task spec is submitted, THEN it is accepted and persisted with the server-set principal of SBX-02.
- GIVEN a caller bypasses the gateway and calls the service port directly with an implementer token, WHEN the handler executes, THEN the role gate still returns HTTP 403 `orchestrator_role_required`.
- GIVEN a token whose `realm_access.roles` carries both `tenant_orchestrator` and `tenant_implementer`, WHEN any agent endpoint is called, THEN the platform returns HTTP 403 `conflicting_agent_roles` at token verification.
- Every rejected submission appends `TaskSpecSubmissionRejected` naming the principal, the tenant, and which of the two credentials was absent.

**See:** IDN-05, IDN-02, SBX-02, SBX-03, AGT-02, XC-05
