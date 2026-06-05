---
pipeline_id: sim-company-onboarding
spec_version: "1.0"
test_file: web/tests/e2e/pipelines/sim-company-onboarding.pipeline.e2e.spec.ts
company_fixture: tests/simulation/companies/swiftroute/
---

# Pipeline Spec: Simulation — Company Onboarding

## Purpose

Verifies the end-to-end flow a platform admin follows to set up a new company
(tenant) in the BPM system: creating users, organising them into department groups,
and assigning platform roles. Exercises the Users and Groups admin UI pages.

## Requirements covered

| Step | Screen shows | Requirement |
|------|-------------|-------------|
| 01 | Users page table renders | ADM-UI-01 |
| 02 | CEO user detail page after creation | ADM-UI-02 |
| 03 | Ops Manager user detail page after creation | ADM-UI-02 |
| 04 | Driver user detail page after creation | ADM-UI-02 |
| 05 | Group row appears in Groups table | ADM-UI-05 |
| 06 | CEO added to group via manage dialog | ADM-UI-05 |
| 07 | API confirms Ops Manager added to group | ADM-UI-05 |
| 08 | Members column shows ≥1 in Groups table | ADM-UI-05 |
| 09 | "Saved" message after PROCESS_OPERATOR role assigned | ADM-UI-03 |
| 10 | "Saved" message after TASK_WORKER role assigned | ADM-UI-03 |
| 11 | All three users appear in search results | ADM-UI-01 |

## Chain topology

```
pre-check-services
→ login-as-platform-admin
→ 01: users-page-sanity-check
→ 02: create-ceo-user                 [produces: ceoUserId]
→ 03: create-ops-manager-user         [produces: opsUserId]
→ 04: create-driver-user              [produces: workerUserId]
→ 05: create-operations-group         [produces: groupId]
→ 06: add-ceo-to-group                [reads: groupId, ceoUserId]
→ 07: add-ops-manager-to-group        [reads: groupId, opsUserId]
→ 08: verify-group-member-count       [asserts: count ≥ 1]
→ 09: assign-PROCESS_OPERATOR-to-ops  [reads: opsUserId]
→ 10: assign-TASK_WORKER-to-driver    [reads: workerUserId]
→ 11: verify-all-users-in-list        [reads: fixtureId]
→ cleanup: deactivate-all-users
```

## Fixture data

Uses SwiftRoute Ltd (small logistics company). People created:
- Alice Bauer — CEO → no platform role (PLATFORM_ADMIN is not assigned in this test)
- Marco Stein — Ops Manager → PROCESS_OPERATOR
- Jan Müller  — Driver → TASK_WORKER

## Verdict criteria

Each step verdict is visual: "screen shows X after action Y".
- Step 02–04: URL changes to `/admin/users/<id>` and detail form renders
- Step 05: group row with fixture name appears in Groups table
- Step 08: Members column integer ≥ 1
- Step 09–10: `data-testid="admin-user-submit-message"` contains text "Saved"
- Step 11: search returns at least one row per username

## Cleanup

`pl.onCleanup` deactivates all three users via `PATCH /api/v1/users/:id`
regardless of whether the chain completed or aborted.

## Known gaps

- No tenant-level isolation: all users are created in the default realm.
  A future `TENANT_ADMIN` role and multi-tenant onboarding UI will require
  a separate pipeline once those features are implemented.
- Group management dialog interaction is UI-fragile (relies on placeholder text).
  Update selector to use `data-testid` once groups page adds test IDs.
