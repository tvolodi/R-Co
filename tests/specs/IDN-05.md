# Test Specification: IDN-05 — Named Role Registry and ROLE Assignee Resolution

**Requirement:** IDN-05  
**Design artefact:** src/design/idn05-role-registry.md  
**Implementation:** src/identity/role_registry.zig, src/api/routes/identity.zig (handleListRoles, handleUpsertRole), src/engine/instance.zig (applyTransition ROLE resolution)  
**Migration:** migrations/1154_idn05_tenant_role_registry.sql  
**Test file:** tests/integration/idn05_role_registry_test.zig  
**Test step:** `zig build test-integration-idn05`

---

## Test case inventory

| TC ID | Title | Layer | MUST/SHOULD |
|---|---|---|---|
| TC-IDN05-01 | POST /roles creates binding (201, correct body) | Integration | MUST |
| TC-IDN05-02 | POST /roles with unknown group_id → 404 GROUP_NOT_FOUND | Integration | MUST |
| TC-IDN05-03 | POST /roles upserts — same name, different group_id → 200 | Integration | MUST |
| TC-IDN05-04 | GET /roles lists all bindings for calling tenant | Integration | MUST |
| TC-IDN05-05 | Tenant isolation — role in tenant A invisible to tenant B | Integration | MUST |
| TC-IDN05-06 | ROLE assignee resolved at task activation → GROUP semantics | Integration | MUST |
| TC-IDN05-07 | ROLE assignee unresolved → Task in PENDING (not ERROR) | Integration | MUST |

**Total test cases: 7 (MUST: 7, SHOULD: 0)**

---

## TC-IDN05-01: POST /roles creates a binding — 201 with correct body

**Preconditions:**
- A group exists in the tenant schema (created via handleCreateGroup).
- No tenant_role row with name "Finance Approver" exists.

**Steps:**
1. Create a group: POST via handleCreateGroup → capture group_id.
2. Call handleUpsertRole with `{"name":"Finance Approver","group_id":"<captured group_id>"}` as PLATFORM_ADMIN.
3. Assert response status = 200 (upsert on new row — no existing binding; design returns 200 for both create and update).

**Assertions:**
- `result.status_code` is 200.
- Response body is valid JSON with fields: `id` (UUID-shaped), `name` = "Finance Approver", `group_id` = captured group_id, `created_at` non-empty string.

**Cleanup:** DELETE tenant_role WHERE name = 'Finance Approver'; DELETE group.

---

## TC-IDN05-02: POST /roles with unknown group_id → 404 GROUP_NOT_FOUND

**Preconditions:**
- The supplied group_id is a valid UUID v4 format but does not exist in the tenant's groups table.

**Steps:**
1. Generate a fresh UUID that is known to not exist in the database.
2. Call handleUpsertRole with `{"name":"Unknown Group Role","group_id":"<nonexistent-uuid>"}` as PLATFORM_ADMIN.

**Assertions:**
- `result.status_code` is 404.
- Response body contains `"GROUP_NOT_FOUND"`.

**Cleanup:** None (no rows inserted on 404).

---

## TC-IDN05-03: POST /roles upserts — same name, different group_id → 200

**Preconditions:**
- Two groups exist: group_a and group_b.
- A tenant_role binding for "IT Reviewer" → group_a exists (created in step 1).

**Steps:**
1. Create group_a and group_b via handleCreateGroup.
2. Call handleUpsertRole `{"name":"IT Reviewer","group_id":"<group_a_id>"}` → assert 200.
3. Call handleUpsertRole `{"name":"IT Reviewer","group_id":"<group_b_id>"}` → assert 200.
4. Assert second response body has group_id = group_b_id (binding updated).

**Assertions:**
- Both calls return status 200.
- Second call response has `group_id` = group_b_id, confirming rebind.

**Cleanup:** DELETE tenant_role WHERE name = 'IT Reviewer'; DELETE both groups.

---

## TC-IDN05-04: GET /roles lists all bindings for calling tenant

**Preconditions:**
- Two distinct role bindings exist: "Role Alpha" and "Role Beta" with two separate groups.

**Steps:**
1. Create two groups.
2. Create binding "Role Alpha" → group_a.
3. Create binding "Role Beta" → group_b.
4. Call handleListRoles as PLATFORM_ADMIN.

**Assertions:**
- `result.status_code` is 200.
- Response body contains a `"roles"` array.
- Both "Role Alpha" and "Role Beta" appear in the array.
- Each entry has fields: id, name, group_id, created_at.

**Cleanup:** DELETE both tenant_role rows; DELETE both groups.

---

## TC-IDN05-05: Tenant isolation — role in tenant A invisible to tenant B

**Preconditions:**
- Two separate tenant schemas (with different search_path contexts).

**Steps:**
1. Set pool search_path to tenant A context.
2. Create a group in tenant A; register role "Shared Name" → group_A.
3. Verify listRoles in tenant A context returns the binding.
4. Switch pool search_path to tenant B context.
5. Directly query `SELECT COUNT(*) FROM tenant_role WHERE name = 'Shared Name'` in tenant B.

**Assertions:**
- Count in tenant B = 0 (row is invisible across tenant schemas).
- listRoles in tenant A = 1 binding named "Shared Name".

**Cleanup:** DELETE tenant_role in tenant A; DELETE group in tenant A.

---

## TC-IDN05-06: ROLE assignee resolved at task activation → GROUP semantics

**Preconditions:**
- A group (e.g., "QA Team") exists in the tenant's groups table.
- A role binding "QA Reviewer" → group_id exists in tenant_role.
- A process definition with a HUMAN_TASK node where `assignee_type="ROLE"` and `assignee_ref="QA Reviewer"`.

**Steps:**
1. Create group; create role binding via upsertRole.
2. Create a process definition with a HUMAN_TASK node having attributes `{"assignee_type":"ROLE","assignee_ref":"QA Reviewer"}`.
3. Activate the definition.
4. Create an instance (triggers applyTransition → task creation).
5. Query the created task from the tasks table.

**Assertions:**
- Task exists with `assignee_type = 'GROUP'` (resolved from ROLE).
- Task `assignee_ref` = the group's UUID (as returned from role lookup).

**Cleanup:** DELETE task, instance, definition, tenant_role, group rows.

---

## TC-IDN05-07: ROLE assignee unresolved → Task in PENDING (not ERROR)

**Preconditions:**
- No tenant_role row exists for the role name used in the definition.
- A process definition with a HUMAN_TASK node where `assignee_type="ROLE"` and `assignee_ref="Nonexistent Role"`.

**Steps:**
1. Create a process definition with HUMAN_TASK having `{"assignee_type":"ROLE","assignee_ref":"Nonexistent Role"}`.
2. Activate the definition.
3. Create an instance.
4. Query the created task from the tasks table.

**Assertions:**
- Task exists (instance does not transition to ERROR).
- Task `assignee_type` is `'ROLE'` or `'PENDING'` (unresolved — not converted to GROUP).
- Instance status remains ACTIVE.

**Cleanup:** DELETE task, instance, definition rows.

---

## Requirement traceability

| Requirement AC | Covered by |
|---|---|
| IDN-05 AC-1: tenant_role table provisioned per tenant | TC-IDN05-01 (insert succeeds), TC-IDN05-05 (isolation) |
| IDN-05 AC-2: POST /roles creates or updates binding | TC-IDN05-01, TC-IDN05-03 |
| IDN-05 AC-3: unknown group_id → 404 | TC-IDN05-02 |
| IDN-05 AC-4: GET /roles returns all bindings for tenant | TC-IDN05-04 |
| IDN-05 AC-5: tenant isolation | TC-IDN05-05 |
| IDN-05 AC-6: ROLE resolved to GROUP at task activation | TC-IDN05-06 |
| IDN-05 AC-7: unresolved ROLE → PENDING task, not ERROR | TC-IDN05-07 |
