# Test Spec: TK-UI-05 — Claim task (claim operation)

**Requirement:** TK-UI-05 — For tasks assigned to a group or role (not yet personally assigned), a "Claim" button SHALL call `POST /tasks/:id/assign` with the current user's ID. Claimed tasks appear in "My Tasks".

**Priority:** MUST

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Claim button visible for group-assigned tasks | TC-TK-UI-05-E2E-01 |
| Claim button not visible for already-assigned tasks | TC-TK-UI-05-E2E-02 |
| Claim button calls POST /tasks/:id/assign | TC-TK-UI-05-E2E-03 |
| Claimed task moves to "My Tasks" filter | TC-TK-UI-05-E2E-04 |
| Claim button is disabled after successful claim | TC-TK-UI-05-E2E-05 |
| Success feedback shown on task claim | TC-TK-UI-05-E2E-06 |

## Test Cases

### TC-TK-UI-05-E2E-01: Claim button visible for group-assigned tasks
**Given:** a task assigned to a group (e.g. "approval-team") that the user belongs to
**When:** task detail panel is opened
**Then:** screen shows a visible "Claim" button
**Layer:** e2e
**Acceptance criterion mapped:** claim button visibility for claimable tasks

### TC-TK-UI-05-E2E-02: Claim button not visible for already-assigned tasks
**Given:** a task assigned directly to the current user
**When:** task detail panel is opened
**Then:** screen does not show a Claim button (task is already claimed)
**Layer:** e2e
**Acceptance criterion mapped:** claim button hidden for assigned tasks

### TC-TK-UI-05-E2E-03: Claim button sends POST request to assign endpoint
**Given:** a group-assigned task with a visible Claim button
**When:** user clicks the Claim button
**Then:** an HTTP POST request is sent to /api/v1/tasks/:id/assign with the current user's ID
**Layer:** e2e
**Acceptance criterion mapped:** claim API call

### TC-TK-UI-05-E2E-04: Claimed task appears in "My Tasks" filter
**Given:** a user has claimed a group task
**When:** user navigates to "My Tasks" filter in the inbox
**Then:** screen shows the claimed task in the "My Tasks" list
**Layer:** e2e
**Acceptance criterion mapped:** claimed task appears in personal assignment

### TC-TK-UI-05-E2E-05: Claim button is disabled after successful claim
**Given:** a task has been successfully claimed
**When:** the task detail remains open after claim
**Then:** screen shows the Claim button as disabled or hidden
**Layer:** e2e
**Acceptance criterion mapped:** claim button state after claim

### TC-TK-UI-05-E2E-06: Feedback shown on successful task claim
**Given:** a task is successfully claimed
**When:** the claim API call returns HTTP 200
**Then:** screen displays success feedback (toast, message) indicating the task is now assigned to the user
**Layer:** e2e
**Acceptance criterion mapped:** user feedback on claim success
