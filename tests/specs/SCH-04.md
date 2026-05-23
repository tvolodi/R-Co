# Test Spec: SCH-04 — Escalation timer

**Requirement:** SCH-04 — HUMAN_TASK nodes SHALL support an optional escalation timer (via `escalation_timer_duration` in the node spec). If the task is not completed within the defined duration, the platform SHALL append an `ESCALATION` event and optionally reassign or notify per the escalation configuration in the node definition.
**Priority:** MUST
**Test layer:** integration, unit

## Test Cases

### TC-SCH-04-01: HUMAN_TASK activation creates escalation timer from task creation time
**Given:** An active process definition whose HUMAN_TASK node includes `escalation_timer_duration` and initial assignee metadata.
**When:** An instance is started and the HUMAN_TASK becomes active through the normal EE-03 activation path.
**Then:** Exactly one pending `human_task_escalation` timer is persisted, its payload references the created task, and its persisted `fire_at` equals `task.created_at + escalation_timer_duration`.
**Layer:** integration
**Acceptance criterion mapped:** GIVEN a HUMAN_TASK node with `escalation_timer_duration` defined, WHEN the task is activated, THEN a timer is created per SCH-01 with `fire_at = task.created_at + escalation_timer_duration`.

### TC-SCH-04-02: Escalation firing appends ESCALATION while task remains pending
**Given:** A pending HUMAN_TASK with a due escalation timer and no completion event.
**When:** The scheduler polls and claims the due escalation timer.
**Then:** The scheduler appends one `ESCALATION` event to the instance event log and marks the escalation timer fired.
**Layer:** integration
**Acceptance criterion mapped:** GIVEN the escalation timer fires and the task is still PENDING, THEN an `ESCALATION` event is appended to the instance event log.

### TC-SCH-04-03: Escalation reassignment occurs in the same transaction as ESCALATION
**Given:** A pending HUMAN_TASK with a due escalation timer whose configuration includes `reassign_to`.
**When:** The scheduler fires the escalation timer.
**Then:** The task assignee changes to the configured reassignment target in the same transaction that appends the `ESCALATION` event, with no intermediate committed state where one write exists without the other.
**Layer:** integration
**Acceptance criterion mapped:** GIVEN the escalation configuration specifies a reassignment target, WHEN the escalation fires, THEN the task is reassigned in the same transaction as the `ESCALATION` event.

### TC-SCH-04-04: Completing task cancels escalation timer before it can fire
**Given:** A pending HUMAN_TASK with a persisted escalation timer.
**When:** The task is completed before scheduler firing.
**Then:** The escalation timer is atomically cancelled, no pending escalation timer remains for the task, and later scheduler polling does not append `ESCALATION`.
**Layer:** integration
**Acceptance criterion mapped:** GIVEN the task is completed before the escalation timer fires, WHEN the task is completed, THEN the escalation timer is cancelled atomically per SCH-03.

### TC-SCH-04-05: Invalid escalation duration is rejected by PD-05 validation
**Given:** A HUMAN_TASK node definition whose `escalation_timer_duration` is not a valid ISO 8601 duration.
**When:** Definition validation runs through PD-05 attribute validation.
**Then:** Validation rejects the node before activation-time scheduling is possible.
**Layer:** unit, integration
**Acceptance criterion mapped:** `escalation_timer_duration` MUST be a valid ISO 8601 duration (validated per PD-05).

## Traceability Notes

- `TC-SCH-04-01` through `TC-SCH-04-04` are implemented in `tests/integration/sch02_timer_polling_test.zig` to stay aligned with the existing scheduler polling integration structure.
- `TC-SCH-04-05` is satisfied by the existing PD-05 validation suites in `tests/unit/graph_node_attributes_test.zig` and `tests/integration/pd05_node_types_test.zig`, which own ISO 8601 duration validation for node attributes.