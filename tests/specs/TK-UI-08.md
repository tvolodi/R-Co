# Test Spec: TK-UI-08 — Badge count

**Requirement:** TK-UI-08 — The navigation item for Task Inbox SHALL display a live badge count of pending tasks assigned to the current user or their groups. The count polls every 30 seconds.

**Priority:** SHOULD

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Badge displays task count | TC-TK-UI-08-E2E-01 |
| Badge updates when new task is assigned | TC-TK-UI-08-E2E-02 |
| Badge polls for updates | TC-TK-UI-08-E2E-03 |

## Test Cases

### TC-TK-UI-08-E2E-01: Navigation badge displays current task count
**Given:** a user with 3 pending tasks
**When:** user views the sidebar/navigation
**Then:** the Task Inbox navigation item displays a badge with the number "3"
**Layer:** e2e
**Acceptance criterion mapped:** badge count display

### TC-TK-UI-08-E2E-02: Badge updates when new task is assigned
**Given:** a user viewing the navigation with a badge count
**When:** a new task is assigned to the user via API
**Then:** the badge count updates to reflect the new total within 30 seconds (the polling interval)
**Layer:** e2e
**Acceptance criterion mapped:** badge update on task assignment

### TC-TK-UI-08-E2E-03: Badge count reflects group assignments
**Given:** a user belonging to a group with pending group-assigned tasks
**When:** user views the Task Inbox badge
**Then:** the badge count includes both user-assigned and group-assigned pending tasks
**Layer:** e2e
**Acceptance criterion mapped:** badge includes group tasks
