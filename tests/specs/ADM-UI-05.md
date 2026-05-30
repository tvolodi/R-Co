# Test Spec: ADM-UI-05 — Group management

**Requirement:** ADM-UI-05 — A Groups sub-section lists all groups with their member counts. Admins can create groups, add/remove members, and delete empty groups.
**Priority:** MUST
**Test layer:** integration, e2e

## Test Cases

### TC-ADM-UI-05-01: groups page supports create, member updates, and delete-empty-group flow
**Given:** a PLATFORM_ADMIN session and a unique test user fixture
**When:** the admin opens `/admin/groups`, creates a group, adds the user, removes the user, and deletes the now-empty group
**Then:** the list shows the new group with member-count changes, the manage-members dialog shows the assigned user, and the empty group can be deleted only after it has no members
**Layer:** e2e
**Acceptance criterion mapped:** group listing, create group, add/remove members, delete empty groups
**Implemented by:** `tests/integration/idn02_group_management_test.zig` (`TC-IDN-02-01`..`TC-IDN-02-07`) and `web/tests/e2e/f5-admin-groups-tokens.e2e.spec.ts` (`TC-ADM-UI-05-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADM-UI-05: group list and member counts render | `TC-ADM-UI-05-01` |
| ADM-UI-05: admins can create groups | `TC-ADM-UI-05-01` |
| ADM-UI-05: admins can add and remove members | `TC-ADM-UI-05-01` |
| ADM-UI-05: empty groups can be deleted | `TC-ADM-UI-05-01` |

## Execution Notes For TEST-RUNNER

- Seeded fixtures are unique per test run and cleaned up in `finally` blocks.
- UI assertions rely on the real backend session and real database state.
- Visual confirmation is captured after list load, group creation, member add/remove, and delete confirmation.