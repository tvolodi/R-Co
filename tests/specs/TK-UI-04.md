# Test Spec: TK-UI-04 — Complete task (form submission and task completion)

**Requirement:** TK-UI-04 — A "Complete" button SHALL collect the form field values as the output variables map and call `POST /tasks/:id/complete`. On success, the task is removed from the inbox and a success toast is shown. On server-side error (e.g. variable schema violation), the error is shown inline.

**Priority:** MUST

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Complete button is visible on task detail panel | TC-TK-UI-04-E2E-01 |
| Complete button submits form data via POST /tasks/:id/complete | TC-TK-UI-04-E2E-02 |
| Task is removed from inbox after successful completion | TC-TK-UI-04-E2E-03 |
| Success toast is shown after task completion | TC-TK-UI-04-E2E-04 |
| Server error response is displayed inline | TC-TK-UI-04-E2E-05 |
| Form values are correctly mapped to output_variables | TC-TK-UI-04-E2E-06 |
| Task completion triggers instance state transition | TC-TK-UI-04-E2E-07 |

## Test Cases

### TC-TK-UI-04-E2E-01: Complete button is visible on task detail panel
**Given:** a task detail panel is open
**When:** panel is rendered with a form
**Then:** screen shows a "Complete" or "Submit" button at the bottom of the form
**Layer:** e2e
**Acceptance criterion mapped:** complete button visibility

### TC-TK-UI-04-E2E-02: Complete button submits form to backend
**Given:** a task detail panel with filled form fields
**When:** user clicks the Complete button
**Then:** an HTTP POST request is sent to /api/v1/tasks/:id/complete with form data as output_variables
**Layer:** e2e
**Acceptance criterion mapped:** form submission to API

### TC-TK-UI-04-E2E-03: Task is removed from inbox after completion
**Given:** a task in the inbox that the user just completed
**When:** completion succeeds
**Then:** screen returns to the task list and the completed task is no longer visible in the list
**Layer:** e2e
**Acceptance criterion mapped:** task removal from inbox

### TC-TK-UI-04-E2E-04: Success toast notification is displayed
**Given:** a task completion request succeeds (HTTP 200)
**When:** response is received
**Then:** screen displays a success toast/notification message indicating the task was completed
**Layer:** e2e
**Acceptance criterion mapped:** success feedback to user

### TC-TK-UI-04-E2E-05: Server validation error is shown inline in form
**Given:** a task completion request fails with HTTP 422 (e.g. variable schema violation)
**When:** error response is received
**Then:** screen shows the error message displayed on the form or in an error panel within the detail view
**Layer:** e2e
**Acceptance criterion mapped:** error message display

### TC-TK-UI-04-E2E-06: Form values are correctly collected as output variables
**Given:** a form with fields (amount=500, approver="alice", approved=true)
**When:** user completes the task
**Then:** the POST request contains output_variables with exact field values from the form
**Layer:** e2e
**Acceptance criterion mapped:** form-to-variables mapping

### TC-TK-UI-04-E2E-07: Completed task transitions instance to next node
**Given:** a task is completed successfully
**When:** the completion succeeds
**Then:** the instance advances to the next node (e.g. next task or END), which is observable via GET /instances/:id
**Layer:** e2e
**Acceptance criterion mapped:** instance state transition on task completion
