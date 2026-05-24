# Test Spec: OBS-02 — Prometheus metrics

**Requirement:** OBS-02 — The platform SHALL expose `GET /metrics` in Prometheus text format. Core metrics SHALL include: active instances count, task completion rate, event append latency (p50/p95/p99), DB query latency, HTTP request rate and error rate.
**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OBS-02-01: `/metrics` returns Prometheus contract without authentication
**Given:** the BPM API server is running
**When:** a client sends `GET /metrics` without an `Authorization` header
**Then:** the response is HTTP `200` with `Content-Type: text/plain; version=0.0.4`
**Layer:** integration
**Acceptance criterion mapped:** `/metrics` endpoint contract and no-auth access

### TC-OBS-02-02: Required metric families and label shapes are emitted
**Given:** metrics have recorded representative observations for task completion, DB query latency, and HTTP requests
**When:** Prometheus text is collected
**Then:** output includes required families and expected labels: `definition_id`, `query_type`, `method`, `path`, `status`
**Layer:** unit
**Acceptance criterion mapped:** required metric families and labels are present

### TC-OBS-02-03: Histogram exposition supports p50/p95/p99 queries
**Given:** histogram observations are recorded
**When:** Prometheus text is collected
**Then:** each histogram emits `_bucket` series with `le` labels plus `_sum` and `_count`, including `+Inf`
**Layer:** unit
**Acceptance criterion mapped:** event append and DB query latency histogram emission behavior

### TC-OBS-02-04: Scrape path remains non-blocking for normal request handling
**Given:** repeated metrics scrapes are in progress
**When:** a liveness endpoint request is made
**Then:** the liveness request still completes successfully and scrape output remains available
**Layer:** integration
**Acceptance criterion mapped:** slow/frequent scrape behavior does not block request processing

### TC-OBS-02-05: DB-outage stale gauge behavior keeps metrics endpoint available
**Given:** active-instance gauge has a previously published value and is marked stale due to refresh failure
**When:** `/metrics` is rendered
**Then:** response remains HTTP `200` with in-memory metrics; `bpm_active_instances_total` is still emitted with last known value
**Layer:** unit
**Acceptance criterion mapped:** DB outage edge case returns available in-memory metrics with potentially stale active-instance gauge
