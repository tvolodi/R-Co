---
id: API-04
title: Task operations
stage: 4
priority: MUST
status: RELEASED
---

# API-04 — Task operations `[MUST]`

> The API SHALL expose: `GET /tasks` (list, filterable by assignee/status/instance), `GET /tasks/:id`, `POST /tasks/:id/complete`, `POST /tasks/:id/assign`, `POST /tasks/:id/reassign`.

**Acceptance Criteria:**
- `GET /tasks`: lists tasks, paginated, filterable by `assignee_id`, `status`, `instance_id`. TASK_WORKER sees only their own tasks; PROCESS_OPERATOR and above see all.
- `GET /tasks/:id`: returns task including `status`, `instance_id`, `node_id`, `assignee_type`, `assignee_ref`, `created_at`. HTTP 404 if not found.
- `POST /tasks/:id/complete`: completes task per EE-04. Body: `{ "output_variables": {...} }`. HTTP 409 if already completed or cancelled.
- `POST /tasks/:id/assign`: assigns an unassigned task to a specific user. Body: `{ "user_id": "..." }`. HTTP 409 if task already assigned.
- `POST /tasks/:id/reassign`: changes the assignee of an already-assigned task. Requires PROCESS_OPERATOR or above.

**See:** EE-03 (task creation), EE-04 (completion logic), IDN-03 (role permission matrix), API-06 (pagination for task list)

**Edge cases:**
- TASK_WORKER attempts to complete a task assigned to a different user: HTTP 403.
- Task for a CANCELLED instance: task is already CANCELLED; completion returns HTTP 409.
