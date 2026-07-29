---
id: SCH-04
title: Escalation timer
stage: 5
priority: MUST
status: RELEASED
---

# SCH-04 — Escalation timer `[MUST]`

> HUMAN_TASK nodes SHALL support an optional escalation timer (via `escalation_timer_duration` in the node spec). If the task is not completed within the defined duration, the platform SHALL append an `ESCALATION` event and optionally reassign or notify per the escalation configuration in the node definition.

**Acceptance Criteria:**
- GIVEN a HUMAN_TASK node with `escalation_timer_duration` defined, WHEN the task is activated (EE-03), THEN a timer is created per SCH-01 with `fire_at = task.created_at + escalation_timer_duration`.
- GIVEN the escalation timer fires and the task is still PENDING, THEN an `ESCALATION` event is appended to the instance event log.
- GIVEN the escalation configuration specifies a reassignment target, WHEN the escalation fires, THEN the task is reassigned in the same transaction as the `ESCALATION` event.
- GIVEN the task is completed before the escalation timer fires, WHEN the task is completed, THEN the escalation timer is cancelled atomically per SCH-03.
- `escalation_timer_duration` MUST be a valid ISO 8601 duration (validated per PD-05).

**See:** PD-05 (escalation_timer_duration on HUMAN_TASK), SCH-01 (timer creation), SCH-03 (timer cancelled on task completion), EE-03 (task activation)

**Edge cases:**
- Task completed exactly when escalation timer fires concurrently: one transaction wins; the other is rolled back.
