# Test Spec: IDN-03 — Role-based access

**Requirement:** IDN-03 — The platform SHALL enforce the role permission matrix. Roles are additive.
**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-IDN-03-01: TASK_WORKER-only caller is denied definition create
**Given:** An authenticated caller with only `TASK_WORKER`
**When:** access is evaluated for `POST /definitions` (`DefinitionsCreate`)
**Then:** authorization returns deny (HTTP 403 semantics)
**Layer:** unit
**Acceptance criterion mapped:** GIVEN a user holds role TASK_WORKER only, WHEN they attempt to create a definition, THEN HTTP 403 is returned.

### TC-IDN-03-02: TASK_WORKER + PROCESS_OPERATOR can cancel instances
**Given:** An authenticated caller with roles `TASK_WORKER` and `PROCESS_OPERATOR`
**When:** access is evaluated for `POST /instances/:id/cancel` (`InstancesCancel`)
**Then:** authorization allows the operation
**Layer:** unit
**Acceptance criterion mapped:** GIVEN a user holds roles TASK_WORKER and PROCESS_OPERATOR, WHEN they attempt to cancel an instance, THEN the operation is permitted.

### TC-IDN-03-03: TASK_WORKER GET /tasks applies own-or-group row filtering
**Given:** A TASK_WORKER user with one task directly assigned to them, one task assigned to a group they are in, and one task assigned to another user
**When:** `GET /tasks` is executed via `handleList()`
**Then:** HTTP 200 is returned and only the directly assigned and group-member task rows are returned
**Layer:** integration
**Acceptance criterion mapped:** GIVEN a user holds TASK_WORKER only, WHEN they call `GET /tasks`, THEN only tasks assigned to them are returned (row-level filtering, not HTTP 403).

### TC-IDN-03-04: Unmapped endpoints default to PLATFORM_ADMIN-only
**Given:** A non-admin caller and a PLATFORM_ADMIN caller
**When:** access is evaluated for an endpoint not present in the permission matrix (`Unknown`)
**Then:** non-admin is denied and PLATFORM_ADMIN is allowed
**Layer:** unit
**Acceptance criterion mapped:** The permission matrix in Stage 5 is authoritative; any endpoint not covered by the matrix defaults to PLATFORM_ADMIN only.