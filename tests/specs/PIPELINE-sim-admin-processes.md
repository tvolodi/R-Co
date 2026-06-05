---
pipeline_id: sim-admin-processes
spec_version: "1.0"
test_file: web/tests/e2e/pipelines/sim-admin-processes.pipeline.e2e.spec.ts
---

# Pipeline Spec: Simulation — Admin Business Processes

## Purpose

Verifies the admin operational workflows a platform administrator runs
day-to-day: monitoring system health, reading audit logs, assigning roles
to users, and managing the API token lifecycle (issue → verify → revoke).
All steps drive the real GUI with no human interaction.

## Requirements covered

| Step | Screen shows | Requirement |
|------|-------------|-------------|
| 01 | Health dashboard with ≥1 "ok/healthy/up" status | ADM-UI (health) |
| 02 | Metrics page renders metric content | ADM-UI (metrics) |
| 03 | Audit log table is visible | ADM-UI (audit) |
| 04 | Audit log filtered by actor term | ADM-UI (audit) |
| 05 | New user detail page after creation | ADM-UI-02 |
| 06 | "Saved" after PROCESS_DESIGNER role assigned | ADM-UI-03 |
| 07 | Roles column non-empty in user list row | ADM-UI-01 |
| 08 | "Issued token" dialog with "will not be shown again" warning | ADM-UI-07 |
| 09 | Token row with ACTIVE status in token list | ADM-UI-06 |
| 10 | Token row shows REVOKED after revoke confirmation dialog | ADM-UI-08 |
| 11 | User status shows INACTIVE after deactivation dialog | ADM-UI-04 |

## Chain topology

```
pre-check-services
→ login-as-platform-admin
→ 01: health-dashboard                    [asserts: ≥1 status indicator]
→ 02: metrics-page                        [asserts: metric content present]
→ 03: audit-log-table                     [asserts: table/list renders]
→ 04: audit-log-filter-by-actor           [asserts: filtered view renders]
→ 05: create-test-user                    [produces: targetUserId]
→ 06: assign-PROCESS_DESIGNER-role        [reads: targetUserId]
→ 07: verify-role-in-user-list            [asserts: Roles column non-empty]
→ 08: issue-api-token                     [reads: targetUserId, produces: tokenId]
→ 09: verify-token-in-list                [asserts: ACTIVE status visible]
→ 10: revoke-token                        [asserts: REVOKED status visible]
→ 11: deactivate-user                     [asserts: INACTIVE status visible]
→ cleanup: deactivate-user-via-api
```

## Verdict criteria

- Step 01: any element with text matching `/ok|healthy|up/i` is visible
- Step 02: a `<pre>`, `<table>`, or `[data-testid*="metric"]` element is present
- Step 03: a table or `[role="table"]` element is present
- Step 05: URL becomes `/admin/users/<id>` and form renders
- Step 06: `data-testid="admin-user-submit-message"` contains "Saved"
- Step 07: Roles cell (column index 3) has non-empty text
- Step 08: dialog with `/issued token/i` heading appears; "will not be shown again" visible
- Step 09: token row for test user shows "ACTIVE" badge
- Step 10: token row shows "REVOKED" (with strikethrough per UI convention)
- Step 11: `data-testid="admin-user-status"` contains "INACTIVE"

## Cleanup

`pl.onCleanup` deactivates the test user via `PATCH /api/v1/users/:id` regardless
of chain outcome.

## Known gaps

- **No TENANT_ADMIN role**: all operations run as PLATFORM_ADMIN.
  When a tenant-scoped admin role is added, a separate pipeline should verify
  that TENANT_ADMIN can manage their own tenant's users/groups but cannot
  access other tenants' data or the audit log outside their scope.
- Health and metrics pages use text-content selectors. Once those pages add
  `data-testid` attributes the selectors should be updated for robustness.
- Audit log filter step is best-effort: if no filter input is found on the
  page, the step passes without filtering (logs a warning). Update once
  the audit log page adds a stable filter `data-testid`.
