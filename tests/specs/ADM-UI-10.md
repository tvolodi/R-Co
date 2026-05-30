# Test Spec: ADM-UI-10 — Metrics viewer

**Requirement:** ADM-UI-10 — The Admin section includes a Metrics page that fetches raw Prometheus text from `GET /metrics` and renders a readable table grouped by metric family (metric name, labels, value, help text).
**Priority:** SHOULD
**Test layer:** integration, e2e

## Test Cases

### TC-ADM-UI-10-01: metrics page renders grouped metric-family tables from Prometheus text
**Given:** a PLATFORM_ADMIN session with metrics endpoint available
**When:** the admin opens `/admin/metrics`
**Then:** the page shows grouped metric-family sections with table columns for sample name, labels, and value, and displays family metadata (name/type/help)
**Layer:** e2e
**Acceptance criterion mapped:** `/metrics` fetch, grouping by family, readable table output
**Implemented by:** `tests/integration/obs02_metrics_test.zig` (`TC-OBS-02-INT-01`, `TC-OBS-02-INT-02`) and `web/tests/e2e/f5-admin-observability.e2e.spec.ts` (`TC-ADM-UI-10-01`)

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADM-UI-10: page consumes Prometheus text from `/metrics` | `TC-ADM-UI-10-01` |
| ADM-UI-10: metrics are grouped by family | `TC-ADM-UI-10-01` |
| ADM-UI-10: metric sample, labels, and value columns are readable | `TC-ADM-UI-10-01` |
| ADM-UI-10: family metadata is visible in section header | `TC-ADM-UI-10-01` |

## Execution Notes For TEST-RUNNER

- Uses real backend metrics endpoint; no MSW or fetch interception.
- E2E asserts visible family sections and table structure.
- Captures screenshots for grouped table rendering.
