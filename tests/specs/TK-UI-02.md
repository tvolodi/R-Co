# Test Spec: TK-UI-02 — Task detail panel (rendering and display)

**Requirement:** TK-UI-02 — Clicking a task SHALL open a side panel (or navigate to a detail page on mobile) showing: node name, instance context (definition name, instance ID, correlation key), current variables available to the task, and the form schema rendered as an interactive form.

**Priority:** MUST

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Task detail panel opens on task click | TC-TK-UI-02-E2E-01 |
| Panel displays task/node name | TC-TK-UI-02-E2E-02 |
| Panel displays instance context (definition, instance ID, correlation key) | TC-TK-UI-02-E2E-03 |
| Panel displays current instance variables | TC-TK-UI-02-E2E-04 |
| Panel displays form schema if defined | TC-TK-UI-02-E2E-05 |
| Mobile view navigates to detail page instead of side panel | TC-TK-UI-02-E2E-06 |

## Test Cases

### TC-TK-UI-02-E2E-01: Clicking a task opens detail panel
**Given:** user viewing the task inbox list
**When:** user clicks on a task row
**Then:** screen shows a detail panel or page with the task's information visible
**Layer:** e2e
**Acceptance criterion mapped:** task detail panel opens

### TC-TK-UI-02-E2E-02: Task detail panel displays node name
**Given:** a task detail panel is open for a task with name "Approve Invoice"
**When:** panel is rendered
**Then:** screen shows the task/node name prominently in the panel header
**Layer:** e2e
**Acceptance criterion mapped:** node name display

### TC-TK-UI-02-E2E-03: Panel displays instance context information
**Given:** a task detail panel is open
**When:** panel is rendered
**Then:** screen shows definition name, instance ID, and correlation key all visible in the context section
**Layer:** e2e
**Acceptance criterion mapped:** instance context display

### TC-TK-UI-02-E2E-04: Panel displays current instance variables
**Given:** a task detail panel is open for a task in an instance with variables (e.g. amount=1000, status="pending")
**When:** panel is rendered
**Then:** screen shows the instance variables displayed in a readable format (JSON or table)
**Layer:** e2e
**Acceptance criterion mapped:** variables display

### TC-TK-UI-02-E2E-05: Panel displays form schema as interactive form
**Given:** a task detail panel is open for a task with a form_schema defined (contains fields like "amount", "notes")
**When:** panel is rendered
**Then:** screen shows input fields corresponding to the form schema fields and user can interact with them
**Layer:** e2e
**Acceptance criterion mapped:** form schema rendering

### TC-TK-UI-02-E2E-06: Mobile view displays task detail on a separate page
**Given:** a 375px mobile viewport with task inbox list visible
**When:** user clicks a task
**Then:** screen navigates to a task detail page (not a side panel) with all information readable without horizontal scroll
**Layer:** e2e
**Acceptance criterion mapped:** mobile detail page navigation
