# Test Spec: IDN-02 — Group management

**Requirement:** IDN-02 — Users SHALL be assignable to one or more named groups. Task assignment rules SHALL support assignment to a user, a group (any ACTIVE member may claim), or a role.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-IDN-02-01: Create group success returns platform-assigned identifiers
**Given:** A PLATFORM_ADMIN submits a non-empty unique group name
**When:** `handleCreateGroup()` is called against the real PostgreSQL-backed identity service
**Then:** HTTP 201 is returned with a UUID `group_id`, the submitted name, and a platform-assigned `created_at`
**Layer:** integration
**Acceptance criterion mapped:** authorised PLATFORM_ADMIN creates a group with a name; platform returns HTTP 201 with UUID `group_id`; group names are unique

### TC-IDN-02-02: Duplicate group name returns conflict
**Given:** A group already exists with name `X`
**When:** Another create-group request is submitted with name `X`
**Then:** HTTP 409 is returned and no second group row is created
**Layer:** integration
**Acceptance criterion mapped:** group names MUST be unique

### TC-IDN-02-03: Add member is idempotent for duplicate membership insertion
**Given:** An existing group and ACTIVE user
**When:** `handleAddGroupMember()` is called twice with the same `(group_id, user_id)` pair
**Then:** The first call returns HTTP 201, the second returns HTTP 200, and the membership row is not duplicated
**Layer:** integration
**Acceptance criterion mapped:** users MAY be assigned to one or more groups; duplicate membership insertion is idempotent

### TC-IDN-02-04: Missing user or missing group returns HTTP 404 on membership insert
**Given:** A valid group id and a non-existent user id, then a valid user id and a non-existent group id
**When:** `handleAddGroupMember()` is called for each missing-resource case
**Then:** HTTP 404 is returned in both cases and no membership row is created
**Layer:** integration
**Acceptance criterion mapped:** non-existent `user_id` MUST cause HTTP 404; missing group MUST return HTTP 404

### TC-IDN-02-05: Group members are returned in paginated order
**Given:** A group with at least two ACTIVE members
**When:** `listGroupMemberRecords()` is called with `page_size = 1`
**Then:** The first page returns the newest record plus a lookahead record, and the next page starts after the first record's cursor values
**Layer:** integration
**Acceptance criterion mapped:** `GET /groups/:id/members` returns the paginated list of users in the group

### TC-IDN-02-06: ACTIVE group member can claim and complete a GROUP-assigned task
**Given:** A GROUP-assigned PENDING task and a group containing an ACTIVE member
**When:** `handleComplete()` is called by that ACTIVE member
**Then:** HTTP 200 is returned and the task completes successfully
**Layer:** integration
**Acceptance criterion mapped:** task assignment with `assignee_type = GROUP` allows any ACTIVE member of the group to claim and complete the task

### TC-IDN-02-07: Removing a member does not mutate an already-assigned GROUP task
**Given:** A GROUP-assigned PENDING task and a group with two ACTIVE members
**When:** One member is removed from the group and the other member completes the task
**Then:** The task remains assigned to the same group, the remaining ACTIVE member can still complete it, and the task is not rewritten or cancelled by the membership removal
**Layer:** integration
**Acceptance criterion mapped:** removing a user from a group must not affect already-assigned tasks
