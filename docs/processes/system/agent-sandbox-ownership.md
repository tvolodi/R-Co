# Process: Agent Sandbox Ownership and Role Separation

| Field | Value |
|-------|-------|
| Process ID | `sys-agent-sandbox-ownership` |
| Platform Workflow | PW-12 |
| Owner | Platform Admin |
| Scope | System-wide (platform tenant; headless) |
| Requirements | SBX-01, SBX-02, SBX-03, SBX-04, SBX-05, SBX-06 |
| Source | `docs/workflows.yaml` (PW-12) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.9 |

## Summary

Separates the orchestrating agent from the implementing agent at the API layer
rather than by deployment convention. Task-spec submission requires both the
`agent.submit_task_spec` scope and the `tenant_orchestrator` realm role, and the
handler force-sets the orchestrator principal from the verified identity so the
persisted spec is server-authoritative. An orchestrator cannot claim a sandbox,
which keeps its cross-sandbox supervisory read from turning into execution
authority. A sandbox binds at claim to exactly one `(tenant_id, agent_principal,
task_spec_id)` triple, and a single sentinel error covers both not-found and
wrong-tenant so response codes cannot be used to probe another tenant.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Orchestrating Agent | ORCH principal, realm role `tenant_orchestrator` | Submits task specs; reads sandbox status across the tenant; never claims a sandbox |
| Implementing Agent | BACKEND-DEV / FRONTEND-DEV principal, realm role `tenant_implementer` | Claims one sandbox per task spec, executes the work, releases the sandbox |
| BPM Platform | System | Enforces the role gate in the handler, force-sets the principal, binds ownership at claim |
| Pool Manager | System | Allocates sandboxes, rejects orchestrator-role claimants, records ownership |
| Audit Log | System | Records every claim, rejected claim, and release with the acting principal |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| Bearer token | JWT | Verified against the tenant realm; supplies `sub`, `scope`, and `realm_access.roles` |
| `agent.submit_task_spec` | scope | Required on task-spec submission alongside the orchestrator realm role |
| `tenant_orchestrator` | realm role | Required on task-spec submission; disqualifies the caller from claiming |
| `tenant_implementer` | realm role | Required on sandbox claim and release |
| `task_spec_id` | UUID | Must exist in the caller's tenant; one sandbox per task spec |
| `sandbox_id` | UUID | Server-generated at allocation; opaque to the caller |
| `orchestrator_principal` | string (server-set) | Always set to the verified token subject; a request-supplied value is discarded |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Orchestrating Agent | `POST /api/v1/agent/task-specs` with the spec document | Token carries `agent.submit_task_spec` scope? | No -> 403 `orchestrator_role_required` | SBX-01 |
| 2 | Platform | Reads `realm_access.roles` from the verified token | Token carries the `tenant_orchestrator` realm role? | No -> 403 `orchestrator_role_required`; the scope alone is not sufficient | SBX-01 |
| 3 | Platform | Discards any `orchestrator_principal` in the request body and sets `spec.orchestrator_principal = identity.subject` | Body carried a different principal? | The submitted value is dropped before canonicalisation; no error is raised | SBX-02 |
| 4 | Platform | Canonicalises and hashes the spec with the server-set principal included, then persists it | - | Persisted JSON is authoritative; `spec_hash` covers the server-set principal | SBX-02 |
| 5 | Orchestrating Agent | `POST /api/v1/agent/sandboxes/{sandbox_id}/claim` | Caller holds `tenant_orchestrator`? | -> 403 `orchestrator_may_not_claim`; the sandbox stays unowned | SBX-03 |
| 6 | Implementing Agent | `POST /api/v1/agent/sandboxes/{sandbox_id}/claim` with `task_spec_id` | Caller holds `tenant_implementer`? | No -> 403 `implementer_role_required` | SBX-03, SBX-04 |
| 7 | Pool Manager | Resolves `sandbox_id` within the caller's tenant | Sandbox unknown, or owned by another tenant? | -> 403 `sandbox_not_accessible` - one sentinel covering both cases | SBX-05 |
| 8 | Pool Manager | Writes the ownership binding `(tenant_id, agent_principal, task_spec_id)` under unique index `ux_sandbox_owner` | Binding already exists for a different principal? | -> 409 `sandbox_already_claimed`; the existing owner is not disclosed | SBX-04 |
| 9 | Pool Manager | Returns the claim | - | Sandbox state -> `claimed`; `claimed_at` and `agent_principal` recorded | SBX-04 |
| 10 | Implementing Agent | Executes the task spec inside the claimed sandbox | Request principal differs from `agent_principal` on the binding? | -> 403 `sandbox_not_accessible`; the same sentinel as an unknown sandbox | SBX-04, SBX-05 |
| 11 | Orchestrating Agent | `GET /api/v1/agent/sandboxes` to read status across the tenant | Caller holds `tenant_orchestrator`? | Returns state, owner principal, and `task_spec_id` for every sandbox in the tenant; no execution endpoint is exposed | SBX-03, SBX-06 |
| 12 | Implementing Agent | `POST /api/v1/agent/sandboxes/{sandbox_id}/release` | Caller is the bound `agent_principal`? | No -> 403 `sandbox_not_accessible`. Yes -> state `released`; binding row cleared | SBX-04, SBX-06 |
| 13 | Audit Log | Appends `SandboxClaimed`, `SandboxClaimRejected`, or `SandboxReleased` with acting principal, tenant, sandbox, and task spec | - | Rejected claims are recorded with the same detail as accepted claims | SBX-06 |
| 14 | Pool Manager | Reclaims a sandbox whose owner has been idle for 60 minutes | Binding still present? | State -> `released`; `SandboxReclaimed` appended with the prior owner | SBX-06 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Gate lives in the handler | The role check runs in the request handler, not in a gateway rule and not by deploying the two agents separately. A direct call to the service port hits the same check. |
| Two conditions on submission | Task-spec submission requires the `agent.submit_task_spec` scope AND the `tenant_orchestrator` realm role. Either one alone returns 403 `orchestrator_role_required`. |
| Server-authoritative principal | `orchestrator_principal` is force-set from the verified token subject. A client-supplied value is discarded before the spec is canonicalised, so `spec_hash` cannot be computed over a forged principal. |
| Orchestrator cannot claim | `Claim` rejects any caller holding `tenant_orchestrator` with 403 `orchestrator_may_not_claim`. Supervisory read across sandboxes is retained; execution authority is not granted. |
| Role exclusivity | A principal holding both `tenant_orchestrator` and `tenant_implementer` is rejected at token verification with 403 `conflicting_agent_roles`. |
| Ownership triple | A claim binds `(tenant_id, agent_principal, task_spec_id)` under unique index `ux_sandbox_owner`. One sandbox has exactly one owner, and one task spec has exactly one sandbox. |
| One sentinel error | `sandbox_not_accessible` returns 403 for an unknown sandbox, a sandbox in another tenant, and a sandbox owned by another principal. The body and headers are identical in all three cases. |
| Claim conflict is distinct | A second claim on a sandbox the caller can see in its own tenant returns 409 `sandbox_already_claimed` without naming the current owner. |
| Release is owner-only | Only the bound `agent_principal` releases a sandbox. The orchestrator cannot release another agent's sandbox. |
| Audit on rejection | Rejected claims are audited with the acting principal, so probing attempts are visible even though the response carries no signal. |
| No cross-tenant pool | Sandboxes are allocated per tenant. No pool entry is visible across tenant boundaries at any endpoint. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `task_specs` row | Carries the server-set `orchestrator_principal`, covered by `spec_hash` |
| Sandbox binding | `(tenant_id, agent_principal, task_spec_id)` under `ux_sandbox_owner` |
| Sandbox state | `available` -> `claimed` -> `released` |
| Supervisory listing | Per-tenant sandbox status, owner principal, and task spec for the orchestrator |
| HTTP status | 201 on claim, 403 sentinel on any inaccessible sandbox, 409 on an already-claimed sandbox |
| Audit entries | `TaskSpecSubmitted`, `SandboxClaimed`, `SandboxClaimRejected`, `SandboxReleased`, `SandboxReclaimed` |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Idle sandbox reclaim | 60 minutes without a request from the owner | `claimed_at` or last activity | Pool Manager releases the sandbox and appends `SandboxReclaimed` |
| Claim response | 200 ms | Claim request | Platform write NFR |
| Token lifetime | 15 minutes | Token issue | Expired token returns 401 `token_expired`; the binding survives the refresh |
| Probe rate limit | 20 sentinel 403s per principal per minute | Repeated inaccessible-sandbox responses | Further requests return 429 `probe_rate_exceeded`; the burst is audited |
| No business timer | - | - | This process is headless; no human task and no business escalation path exists |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 403 `orchestrator_role_required` | Task-spec submission missing the scope, the realm role, or both | Reissue the token with `agent.submit_task_spec` and `tenant_orchestrator` |
| 403 `conflicting_agent_roles` | Principal holds both orchestrator and implementer realm roles | Split the identity into two principals, one per role |
| 403 `orchestrator_may_not_claim` | Orchestrator called the claim endpoint | The orchestrator dispatches an implementing agent to claim instead |
| 403 `implementer_role_required` | Claim by a principal without `tenant_implementer` | Grant the implementer realm role to the agent identity |
| 403 `sandbox_not_accessible` | Unknown sandbox, sandbox in another tenant, or sandbox owned by another principal | Identical response in all three cases; the caller cannot tell which applies |
| 409 `sandbox_already_claimed` | A visible in-tenant sandbox already carries a binding | Wait for release, wait for the 60-minute reclaim, or request a different sandbox |
| 404 `task_spec_not_found` | `task_spec_id` unknown in the caller's tenant | The orchestrating agent submits the spec before the claim |
| 401 `token_expired` | Bearer token past its 15-minute lifetime | Refresh the token; the sandbox binding is unaffected |
| 429 `probe_rate_exceeded` | More than 20 sentinel 403s from one principal in a minute | Burst is audited; the principal backs off before retrying |
| Forged principal in body | Client supplied `orchestrator_principal` | Value is discarded silently; the persisted spec carries the verified subject |
| Owner crash mid-task | Implementing agent terminates while holding a claim | Idle reclaim releases the sandbox after 60 minutes; the task spec is re-claimable |
