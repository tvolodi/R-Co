# Test Spec: OIDC-26 — Provider metrics

**Requirement:** OIDC-26 — Prometheus metrics expose verification rate/latency, JWKS cache ratio, adapter call/error rates with realm and method labels.

**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-OIDC-26-01: Metrics families are emitted for all required IDP counters and histograms
**Given:** Registry receives token verification, JWKS, adapter call/error, and readiness observations
**When:** Prometheus text is collected
**Then:** Required metric family names are present
**Layer:** unit
**Acceptance criterion mapped:** Metrics are present at scrape output

### TC-OIDC-26-02: Metrics include realm and method labels for distinction
**Given:** Events recorded for specific realm_id and method
**When:** Prometheus text is collected
**Then:** Output includes labeled series for realm_id and method dimensions
**Layer:** unit
**Acceptance criterion mapped:** Labeling distinguishes realm and method traffic

### TC-OIDC-26-03: Error counter increments only on error-path recordings
**Given:** Successful and failing adapter observations
**When:** Error metric is inspected
**Then:** idp_adapter_error_total series only reflects failing paths
**Layer:** unit
**Acceptance criterion mapped:** Adapter error rate metric reflects actual failures
