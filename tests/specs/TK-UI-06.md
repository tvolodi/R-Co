# Test Spec: TK-UI-06 — Reassign task (reassign operation)

**Requirement:** TK-UI-06 — Operators SHALL be able to reassign a task to another user, group, or role via `POST /tasks/:id/reassign`. The reassign action opens a user/group/role search dialog.

**Priority:** MUST

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Reassign button visible for operators | TC-TK-UI-06-E2E-01 |
| Reassign button not visible for task workers | TC-TK-UI-06-E2E-02 |
| Reassign button opens search dialog | TC-TK-UI-06-E2E-03 |
| User/group/role search works in reassign dialog | TC-TK-UI-06-E2E-04 |
| Reassign sends POST to /tasks/:id/reassign | TC-TK-UI-06-E2E-05 |
| Task assignee updates after reassignment | TC-TK-UI-06-E2E-06 |
| Success feedback shown on reassignment | TC-TK-UI-06-E2E-07 |

## Test Cases

### TC-TK-UI-06-E2E-01: Reassign button visible for operators
**Given:** a logged-in PROCESS_OPERATOR or PLATFORM_ADMIN user viewing a task
**When:** task detail panel is opened
**Then:** screen shows a visible "Reassign" button
**Layer:** e2e
**Acceptance criterion mapped:** reassign button visibility for operators

### TC-TK-UI-06-E2E-02: Reassign button not visible for task workers
**Given:** a logged-in TASK_WORKER user (no operator role)
**When:** task detail panel is opened
**Then:** screen does not show a Reassign button
**Layer:** e2e
**Acceptance criterion mapped:** reassign button hidden for non-operators

### TC-TK-UI-06-E2E-03: Reassign button opens search dialog
**Given:** a task detail panel is open for an operator user
**When:** user clicks the Reassign button
**Then:** screen displays a search/selection dialog with fields to search for users/groups/roles
**Layer:** e2e
**Acceptance criterion mapped:** reassign dialog opens

### TC-TK-UI-06-E2E-04: User/group/role search works in reassign dialog
**Given:** a reassign dialog is open
**When:** user types in the search field (e.g. "alice" or "approval-team")
**Then:** screen shows matching users, groups, or roles in a dropdown/list below the search field
**Layer:** e2e
**Acceptance criterion mapped:** search functionality in reassign dialog

### TC-TK-UI-06-E2E-05: Reassign sends POST request with new assignee
**Given:** a reassign dialog is open and user has selected a new assignee
**When:** user confirms the reassignment
**Then:** an HTTP POST request is sent to /api/v1/tasks/:id/reassign with the new assignee details
**Layer:** e2e
**Acceptance criterion mapped:** reassign API call

### TC-TK-UI-06-E2E-06: Task assignee is updated after reassignment
**Given:** a task has been reassigned to a different user/group
**When:** reassignment completes successfully
**Then:** screen shows the task's assignee field updated to reflect the new assignment
**Layer:** e2e
**Acceptance criterion mapped:** assignee update

### TC-TK-UI-06-E2E-07: Feedback shown on successful reassignment
**Given:** a task has been successfully reassigned
**When:** the reassign API call returns HTTP 200
**Then:** screen displays success feedback (toast, message) indicating the reassignment is complete
**Layer:** e2e
**Acceptance criterion mapped:** user feedback on reassignment
