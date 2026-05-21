---
id: IDN-03
title: Role-based access
stage: 5
priority: MUST
status: VALIDATED
---

# IDN-03 — Role-based access `[MUST]`

> The platform SHALL enforce the role permission matrix. Roles are additive.

**Acceptance Criteria:**
- GIVEN a user holds role TASK_WORKER only, WHEN they attempt to create a definition, THEN HTTP 403 is returned.
- GIVEN a user holds roles TASK_WORKER and PROCESS_OPERATOR, WHEN they attempt to cancel an instance, THEN the operation is permitted (roles are additive; effective permissions = union).
- GIVEN a user holds TASK_WORKER only, WHEN they call `GET /tasks`, THEN only tasks assigned to them are returned (row-level filtering, not HTTP 403).
- The permission matrix in Stage 5 is authoritative; any endpoint not covered by the matrix defaults to PLATFORM_ADMIN only.

**See:** IDN-01 (users who hold roles), IDN-04 (tokens carry the user's role set), API-08 (token validation extracts roles)

**Edge cases:**
- User with no roles assigned: valid token with no write permissions; read endpoints open to all roles remain accessible.
- TASK_WORKER completing a group-assigned task: any member of the group may complete it (not only the originally assigned user).
