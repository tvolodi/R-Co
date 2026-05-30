# Test Spec: ADM-UI-11 — Audit log viewer

**Requirement:** ADM-UI-11 — The Admin section includes a paginated, filterable audit log page (actor, resource type, time range). Each row expands to show a before/after state diff rendered as a JSON diff view.
**Priority:** MUST
**Test layer:** integration, e2e

## Test Cases

### TC-ADM-UI-11-01: audit page filters by actor/resource/time and expands rows into JSON diff view
**Given:** a PLATFORM_ADMIN session and fresh state-changing fixtures that create audit entries
**When:** the admin opens `/admin/audit`, applies actor/resource/time filters, and expands a matching row
**Then:** filtered audit rows are shown, pagination controls remain visible, and the expanded row renders a JSON diff table with before/after columns
**Layer:** e2e
**Acceptance criterion mapped:** paginated filterable audit view, actor/resource/time filters, expandable row with JSON diff
**Implemented by:** `tests/integration/obs03_audit_log_test.zig` (`TC-OBS-03-INT-01`) and `web/tests/e2e/f5-admin-observability.e2e.spec.ts` (`TC-ADM-UI-11-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADM-UI-11: actor filter narrows results | `TC-ADM-UI-11-01` |
| ADM-UI-11: resource type filter narrows results | `TC-ADM-UI-11-01` |
| ADM-UI-11: time-range filter narrows results | `TC-ADM-UI-11-01` |
| ADM-UI-11: pagination controls are present on filtered view | `TC-ADM-UI-11-01` |
| ADM-UI-11: row expansion renders JSON before/after diff | `TC-ADM-UI-11-01` |

## Execution Notes For TEST-RUNNER

- Test seeds a real audit fixture by creating a process definition through `/api/v1/definitions` before opening the audit page, then cleans up the fixture definition after assertions.
- Test uses the live audit list in the running environment (no mocks/stubs) and validates actor/resource/time filtering behavior from the UI controls.
- Time-range filter behavior is verified via ISO8601 validation feedback (`from` must be <= `to`) before applying actor/resource filters.
- Captures screenshots for filtered results and expanded JSON diff (or empty diff fallback message).
