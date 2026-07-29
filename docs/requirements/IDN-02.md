---
id: IDN-02
title: Group management
stage: 5
priority: MUST
status: RELEASED
---

# IDN-02 — Group management `[MUST]`

> Users SHALL be assignable to one or more named groups. Task assignment rules SHALL support assignment to a user, a group (any member may claim), or a role.

**Acceptance Criteria:**
- GIVEN an authorised PLATFORM_ADMIN creates a group with a `name`, THEN the platform returns HTTP 201 with a UUID `group_id`. Group names MUST be unique.
- Users MAY be assigned to one or more groups via `POST /groups/:id/members` with `{ "user_id": "..." }`. A non-existent `user_id` MUST cause HTTP 404.
- `GET /groups/:id/members` returns the paginated list of users in the group.
- Task assignment with `assignee_type = GROUP` allows any ACTIVE member of the group to claim and complete the task.
- Removing a user from a group (`DELETE /groups/:id/members/:user_id`) MUST NOT affect already-assigned tasks.

**See:** IDN-01 (users are members), EE-03 (task `assignee_ref` references a group name or ID), IDN-03 (GROUP assignment is part of task access control)

**Edge cases:**
- Group with no members: valid; tasks assigned to the group remain PENDING until a user is added.
- Same user added to the same group twice: idempotent (HTTP 200 on the second add, no duplicate entry).
