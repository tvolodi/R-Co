# UAT Scenario YAML — Schema and Examples

**Version:** 1.0 · 2026-06-04  
**Location:** `tests/simulation/scenarios/*.yaml`  
**Read by:** `UAT-RUNNER`  
**Written by:** Business owner (or ORCH via a future WF-06 authoring workflow)

---

## Design principle

Scenario files are intentionally written in **business language**. A business
owner should be able to read a scenario file, understand exactly what it is
testing, and agree or disagree with the expected outcomes — without reading
any code.

Engineering details (API endpoints, Playwright selectors, test IDs) do NOT
belong in scenario files. They belong in the pipeline test files that
UAT-RUNNER drives.

---

## Full schema

```yaml
# ── Identity ──────────────────────────────────────────────────────────────────
id: <kebab-case unique string>
  # e.g. "swiftroute-shipment-high-value"
  # Must match the pipeline test file name if one exists:
  #   web/tests/e2e/pipelines/<id>.pipeline.e2e.spec.ts

company_id: <swiftroute | vortex | meridian>
  # Which simulated company this scenario belongs to

process_id: <process id from company's process_*.yaml>
  # e.g. "proc-swiftroute-shipment-approval"

title: "<plain English title>"
  # Written as a business owner would describe it.
  # E.g.: "High-value shipment requires CEO co-sign"

version: "1.0"

tags:
  - <happy_path | escalation | timeout | compensation | parallel | committee | regression>
  # Used by ORCH to group scenarios and prioritise re-runs.

description: >
  <2–4 sentences. What business situation does this scenario test? Why does
  it matter? What could go wrong if it breaks?>

# ── Actors ────────────────────────────────────────────────────────────────────
actors:
  <role_label>: <actor_id from org_structure.yaml>
  # role_label is business-readable (e.g. "dispatcher", "ceo")
  # actor_id is the technical ID that UAT-RUNNER maps to a user credential
  #
  # Example:
  #   dispatcher: actor-swiftroute-lena
  #   ops_manager: actor-swiftroute-marco
  #   ceo:         actor-swiftroute-alice

# ── Preconditions ─────────────────────────────────────────────────────────────
preconditions:
  - description: "<what must be true before this scenario starts>"
    check: <system_seeded | process_definition_active | no_pending_instances | custom>
    # system_seeded:             seed.py has run for this company
    # process_definition_active: the referenced process_id has status ACTIVE
    # no_pending_instances:      no open instances of this process for this company
    # custom:                    UAT-RUNNER evaluates via API call (see detail field)
    detail: "<optional: API call or specific check for 'custom' type>"

# ── Scenario steps ────────────────────────────────────────────────────────────
steps:
  - step: <integer, 1-based>
    actor: <role_label from actors map>
    action: "<what the actor does, in plain English>"
    # Describes the business action, not the technical implementation.
    # E.g.: "submits a shipment request for 12 packages to Hamburg,
    #         declared value €750, cargo type standard"
    via: <gui | api>
    # gui: UAT-RUNNER drives the Playwright test for this step
    # api: UAT-RUNNER calls the BPM API directly (faster, for setup steps)
    input:
      <variable_name>: <value>
      # These map to process variables defined in process_*.yaml.
      # E.g.:
      #   destination: "Hamburg"
      #   declared_value: 750
      #   cargo_type: standard
    produces:
      <output_label>: "<what this step produces that later steps read>"
      # E.g.:  instance_id: "the process instance ID for this shipment request"
    sla_context:
      expected_within_hours: <number | null>
      # If set: UAT-RUNNER checks that the next expected task appears within
      # this many hours from step submission (clock-time, not business-hours)

  # ... additional steps ...

# ── Expected outcomes ─────────────────────────────────────────────────────────
expected_outcomes:
  - id: <EO-nnn>
    description: "<what the business expects to happen>"
    # Written as a business owner would describe it.
    # E.g.: "The operations manager receives a task to review the shipment
    #         within 4 hours of submission"
    verification:
      method: <task_assigned | instance_state | audit_event | gui_screen | api_response>
      # task_assigned:  a task exists for the specified role/actor
      # instance_state: the instance's variable map contains expected values
      # audit_event:    the audit log contains an event of the specified type
      # gui_screen:     a Playwright screenshot shows the described UI state
      # api_response:   a direct API call returns the expected value
      detail: "<what specifically to check>"
      # For task_assigned:   "task type 'ops-review' assigned to role-ops-manager"
      # For instance_state:  "variable ops_decision == 'approve'"
      # For audit_event:     "event type TASK_COMPLETED for node ops-review"
      # For gui_screen:      "screen shows 'Shipment Approved' status badge"
      # For api_response:    "GET /api/v1/instances/:id → status == COMPLETED"
    on_fail:
      severity: <BLOCKER | MAJOR | MINOR>
      business_impact: "<plain language: what breaks for the business if this fails>"
      suggested_action: <route_to_wf03 | route_to_backend_dev | route_to_req_analyst | none>

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup:
  cancel_open_instances: true
  # If true: UAT-RUNNER cancels any process instances created during this
  # scenario after the run completes (success or failure).
  # Set to false only for scenarios that intentionally leave state for the
  # next scenario in a chain.
  description: "<any additional cleanup needed>"
```

---

## Example 1 — SwiftRoute: High-value shipment (happy path)

```yaml
id: swiftroute-shipment-high-value-happy
company_id: swiftroute
process_id: proc-swiftroute-shipment-approval
title: High-value shipment correctly routed to CEO for co-sign
version: "1.0"
tags: [happy_path]

description: >
  A dispatcher submits a shipment request with declared value above €500.
  The business rule requires the CEO to co-sign after the operations manager
  approves. This scenario verifies the full sequential approval chain works
  correctly end-to-end, including that the shipment is released to the
  driver pool only after both approvals are given.

actors:
  dispatcher:  actor-swiftroute-lena
  ops_manager: actor-swiftroute-marco
  ceo:         actor-swiftroute-alice

preconditions:
  - description: Shipment approval process definition is active
    check: process_definition_active
  - description: No open shipment approval instances for SwiftRoute
    check: no_pending_instances

steps:
  - step: 1
    actor: dispatcher
    action: >
      Submits a shipment request for 20 packages to Munich,
      declared value €750, cargo type standard
    via: api
    input:
      shipment_id: sim-ship-001
      destination: Munich
      declared_value: 750
      cargo_type: standard
      requesting_actor_id: actor-swiftroute-lena
    produces:
      instance_id: "the process instance ID for this shipment request"
    sla_context:
      expected_within_hours: 4

  - step: 2
    actor: ops_manager
    action: Reviews the shipment and approves it
    via: gui
    input:
      ops_decision: approve
      ops_notes: "Capacity available, standard cargo, approved."
    sla_context:
      expected_within_hours: 4

  - step: 3
    actor: ceo
    action: Co-signs the shipment approval
    via: gui
    input:
      ceo_decision: approve
      ceo_notes: "Value within policy limit, co-signed."

expected_outcomes:
  - id: EO-001
    description: >
      After dispatcher submits, the operations manager receives a
      review task within 4 hours
    verification:
      method: task_assigned
      detail: task type 'ops-review' assigned to role-ops-manager
    on_fail:
      severity: BLOCKER
      business_impact: >
        Shipments are not being routed for approval. Operations manager
        cannot see or act on incoming shipment requests.
      suggested_action: route_to_wf03

  - id: EO-002
    description: >
      After ops manager approves a shipment worth more than €500,
      the CEO receives a co-sign task (not just auto-approved)
    verification:
      method: task_assigned
      detail: task type 'ceo-approval' assigned to role-ceo
    on_fail:
      severity: BLOCKER
      business_impact: >
        High-value shipments are being approved without CEO co-sign,
        violating the company's financial control policy.
      suggested_action: route_to_wf03

  - id: EO-003
    description: >
      After CEO approves, the shipment is released to the driver pool
      and the process completes successfully
    verification:
      method: instance_state
      detail: instance status == COMPLETED and end node is 'end-approved'
    on_fail:
      severity: MAJOR
      business_impact: >
        Approved shipments are not being released to drivers. Deliveries
        are stuck in the approval system after sign-off.
      suggested_action: route_to_backend_dev

  - id: EO-004
    description: >
      The full approval journey (submit → ops approve → CEO approve →
      release) completes within the 8-hour SLA
    verification:
      method: audit_event
      detail: >
        Time between instance CREATED event and COMPLETED event is
        less than 8 hours (based on audit log timestamps)
    on_fail:
      severity: MINOR
      business_impact: >
        SLA reporting will show the approval took longer than the agreed
        8-hour window. Not an operational blocker but a contractual risk.
      suggested_action: none

cleanup:
  cancel_open_instances: true
  description: Cancel the sim-ship-001 instance if not already completed
```

---

## Example 2 — SwiftRoute: Shipment escalation on ops timeout

```yaml
id: swiftroute-shipment-ops-timeout-escalation
company_id: swiftroute
process_id: proc-swiftroute-shipment-approval
title: Shipment escalates to CEO when ops manager does not respond in time
version: "1.0"
tags: [escalation, timeout]

description: >
  When an operations manager does not act on a shipment approval request
  within 4 hours, the process must automatically escalate to the CEO.
  This scenario verifies the timer escalation path works correctly —
  the CEO receives the task and can approve or reject directly, without
  waiting for the ops manager.

actors:
  dispatcher:  actor-swiftroute-tobias
  ceo:         actor-swiftroute-alice

preconditions:
  - description: Shipment approval process definition is active
    check: process_definition_active

steps:
  - step: 1
    actor: dispatcher
    action: >
      Submits a shipment request for 5 packages to Berlin,
      declared value €200, cargo type standard.
      The operations manager is NOT asked to approve in this scenario —
      we are simulating them being unavailable.
    via: api
    input:
      shipment_id: sim-ship-002
      destination: Berlin
      declared_value: 200
      cargo_type: standard
      requesting_actor_id: actor-swiftroute-tobias
    produces:
      instance_id: "the process instance ID for this shipment"

  - step: 2
    actor: ceo
    action: >
      After the timer fires, the CEO receives the escalated task and approves
    via: gui
    input:
      capacity_decision: approve
      assigned_line: null
    note: >
      In a real-time test the timer would need to fire (4 h). UAT-RUNNER
      advances the timer by injecting a timer-fire event via the API
      (POST /api/v1/instances/:id/advance-timer) rather than waiting.

expected_outcomes:
  - id: EO-001
    description: >
      After the timer fires, the CEO receives an escalated approval task
      (not the ops manager)
    verification:
      method: task_assigned
      detail: >
        task type 'escalate-to-ceo' or 'ops-review' assigned to role-ceo
        (not role-ops-manager) after timer event injected
    on_fail:
      severity: BLOCKER
      business_impact: >
        Shipments can stall indefinitely if an ops manager is unavailable.
        The escalation path is broken — the CEO has no way to unblock
        time-sensitive deliveries.
      suggested_action: route_to_wf03

  - id: EO-002
    description: >
      After CEO approves, the shipment is released and the process
      completes successfully (the low value means no additional CEO
      co-sign step is needed — just the escalation approval)
    verification:
      method: instance_state
      detail: instance status == COMPLETED and end node is 'end-approved'
    on_fail:
      severity: MAJOR
      business_impact: >
        Even after CEO escalation approval, the shipment is not being
        released. Escalated deliveries are permanently stuck.
      suggested_action: route_to_wf03

cleanup:
  cancel_open_instances: true
  description: Cancel the sim-ship-002 instance if not already completed
```

---

## Naming conventions

| Field | Convention |
|---|---|
| `id` | `<company>-<process-short-name>-<scenario-variant>` |
| `actors` keys | Business role names, not technical IDs (dispatcher, ceo, ops_manager) |
| `input` keys | Process variable names from `process_*.yaml` |
| Outcome IDs | `EO-001`, `EO-002`, ... per scenario (not globally unique) |
| File name | `<id>.yaml` — matches `id` field exactly |

## What scenarios must NOT contain

- Stack traces, line numbers, or file paths
- Playwright selector strings or `data-testid` values
- Zig function names or SQL query details
- Technical implementation assumptions
- Instructions to UAT-RUNNER on how to verify (only what to verify)
