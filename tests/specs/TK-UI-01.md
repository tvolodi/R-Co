# Test Spec: TK-UI-01 — Task inbox (list, filtering, pagination)

**Requirement:** TK-UI-01 — The inbox SHALL show a list of tasks filterable by: My Tasks (assigned to me), My Group Tasks (assigned to a group I belong to), All Tasks (operator+). Columns: task name, instance ID, status, assignee, created time.

**Priority:** MUST

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Task inbox displays user's assigned tasks | TC-TK-UI-01-E2E-01 |
| Task inbox displays user's group-assigned tasks | TC-TK-UI-01-E2E-02 |
| Filtering by "My Tasks" shows only user-assigned | TC-TK-UI-01-E2E-03 |
| Filtering by "My Group Tasks" shows group-assigned | TC-TK-UI-01-E2E-04 |
| Filtering by "All Tasks" available to operators only | TC-TK-UI-01-E2E-05 |
| Task columns display correctly (name, instance, status, assignee, created) | TC-TK-UI-01-E2E-06 |
| Pagination works for large task lists | TC-TK-UI-01-E2E-07 |

## Test Cases

### TC-TK-UI-01-E2E-01: Task inbox displays user's directly assigned tasks
**Given:** a logged-in TASK_WORKER with pending tasks assigned to their user ID
**When:** user navigates to the Task Inbox
**Then:** screen shows a list containing all tasks with that user's ID in the assignee column
**Layer:** e2e
**Acceptance criterion mapped:** task inbox displays user tasks

### TC-TK-UI-01-E2E-02: Task inbox displays user's group-assigned tasks
**Given:** a logged-in TASK_WORKER belonging to a group with pending tasks assigned to the group
**When:** user navigates to the Task Inbox
**Then:** screen shows tasks assigned to the user's groups in the task list
**Layer:** e2e
**Acceptance criterion mapped:** task inbox displays group tasks

### TC-TK-UI-01-E2E-03: "My Tasks" filter shows only user-assigned tasks
**Given:** a user with both direct and group-assigned tasks visible
**When:** user clicks the "My Tasks" filter
**Then:** screen shows only tasks assigned directly to the user, group tasks are hidden
**Layer:** e2e
**Acceptance criterion mapped:** filtering by personal assignment

### TC-TK-UI-01-E2E-04: "My Group Tasks" filter shows only group-assigned tasks
**Given:** a user with both direct and group-assigned tasks visible
**When:** user clicks the "My Group Tasks" filter
**Then:** screen shows only tasks assigned to groups the user belongs to, personal assignments are hidden
**Layer:** e2e
**Acceptance criterion mapped:** filtering by group assignment

### TC-TK-UI-01-E2E-05: "All Tasks" filter available only to operators
**Given:** a logged-in TASK_WORKER user
**When:** user views the Task Inbox filter options
**Then:** "All Tasks" filter is not visible/disabled for a TASK_WORKER
**Layer:** e2e
**Acceptance criterion mapped:** role-based filter availability

### TC-TK-UI-01-E2E-06: Task list displays all required columns
**Given:** task inbox with populated tasks
**When:** user views the task list
**Then:** each row displays task name, instance ID, status badge, assignee name/group, and created timestamp
**Layer:** e2e
**Acceptance criterion mapped:** column display requirements

### TC-TK-UI-01-E2E-07: Pagination controls work for task lists with many items
**Given:** a task inbox with more than one page of tasks
**When:** user navigates to the next page using pagination controls
**Then:** screen shows the next set of tasks without duplicates, and previous/next buttons are in correct state
**Layer:** e2e
**Acceptance criterion mapped:** pagination functionality
