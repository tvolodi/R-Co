# Test Spec: TK-UI-09 — Escalation indicator

**Requirement:** TK-UI-09 — Tasks that have exceeded their `escalation_timer_duration` (status: escalated) SHALL show a visual indicator (e.g. amber warning icon) in the inbox list and on the task detail panel.

**Priority:** SHOULD

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Escalated tasks show visual indicator in list | TC-TK-UI-09-E2E-01 |
| Escalated tasks show visual indicator in detail | TC-TK-UI-09-E2E-02 |
| Non-escalated tasks do not show indicator | TC-TK-UI-09-E2E-03 |

## Test Cases

### TC-TK-UI-09-E2E-01: Escalated task displays warning indicator in inbox list
**Given:** a task with status "escalated" in the task inbox
**When:** user views the task list
**Then:** screen shows a visual indicator (e.g. amber warning icon) next to the escalated task
**Layer:** e2e
**Acceptance criterion mapped:** escalation visual indicator in list

### TC-TK-UI-09-E2E-02: Escalated task displays warning indicator in detail panel
**Given:** a task with status "escalated" opened in detail panel
**When:** task detail panel is rendered
**Then:** screen shows a visual escalation indicator (e.g. warning icon, amber badge) in the panel
**Layer:** e2e
**Acceptance criterion mapped:** escalation indicator in detail view

### TC-TK-UI-09-E2E-03: Non-escalated tasks do not display escalation indicator
**Given:** a task with status "pending" (not escalated)
**When:** user views the task in list or detail
**Then:** screen does not show an escalation indicator for that task
**Layer:** e2e
**Acceptance criterion mapped:** indicator only shown for escalated tasks
