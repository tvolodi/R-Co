# Test Spec: TK-UI-07 — Task sort & search

**Requirement:** TK-UI-07 — The inbox SHALL support sorting by created time (asc/desc) and free-text search by task name or instance correlation key.

**Priority:** SHOULD

**Test layer:** e2e

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| Sort by created time ascending | TC-TK-UI-07-E2E-01 |
| Sort by created time descending | TC-TK-UI-07-E2E-02 |
| Free-text search by task name | TC-TK-UI-07-E2E-03 |
| Free-text search by correlation key | TC-TK-UI-07-E2E-04 |
| Sort and search work together | TC-TK-UI-07-E2E-05 |

## Test Cases

### TC-TK-UI-07-E2E-01: Tasks can be sorted by created time ascending
**Given:** task inbox with multiple tasks created at different times
**When:** user clicks the "Sort by Created Time (Oldest First)" option
**Then:** screen shows tasks ordered from oldest to newest
**Layer:** e2e
**Acceptance criterion mapped:** ascending sort by creation time

### TC-TK-UI-07-E2E-02: Tasks can be sorted by created time descending
**Given:** task inbox with multiple tasks
**When:** user clicks the "Sort by Created Time (Newest First)" option
**Then:** screen shows tasks ordered from newest to oldest
**Layer:** e2e
**Acceptance criterion mapped:** descending sort by creation time

### TC-TK-UI-07-E2E-03: Free-text search filters by task name
**Given:** task inbox with tasks having names like "Approve Invoice", "Review Request"
**When:** user types "Approve" in the search box
**Then:** screen shows only tasks with "Approve" in the name, other tasks are hidden
**Layer:** e2e
**Acceptance criterion mapped:** task name search

### TC-TK-UI-07-E2E-04: Free-text search filters by correlation key
**Given:** task inbox with tasks in instances with correlation keys like "order-123", "order-456"
**When:** user types "order-123" in the search box
**Then:** screen shows only tasks from the instance with that correlation key
**Layer:** e2e
**Acceptance criterion mapped:** correlation key search

### TC-TK-UI-07-E2E-05: Sort and search work together
**Given:** task inbox with search results applied
**When:** user changes the sort order
**Then:** screen shows the filtered results re-sorted according to the new sort order
**Layer:** e2e
**Acceptance criterion mapped:** combined sort and search functionality
