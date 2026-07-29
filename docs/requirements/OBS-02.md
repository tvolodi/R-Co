---
id: OBS-02
title: Prometheus metrics
stage: 6
priority: MUST
status: RELEASED
---

# OBS-02 — Prometheus metrics `[MUST]`

> The platform SHALL expose `GET /metrics` in Prometheus text format. Core metrics SHALL include: active instances count, task completion rate, event append latency (p50/p95/p99), DB query latency, HTTP request rate and error rate.

**Acceptance Criteria:**
- `GET /metrics` returns HTTP 200 with `Content-Type: text/plain; version=0.0.4` (Prometheus text format). No authentication required.
- The following metrics MUST be present:
  - `bpm_active_instances_total` (Gauge): count of instances with `status = ACTIVE`.
  - `bpm_task_completions_total` (Counter): total task completions since startup, labelled by `definition_id`.
  - `bpm_event_append_duration_seconds` (Histogram): latency of event append operations (p50, p95, p99 buckets).
  - `bpm_db_query_duration_seconds` (Histogram): latency of database queries, labelled by `query_type`.
  - `bpm_http_requests_total` (Counter): HTTP requests labelled by `method`, `path`, `status`.
  - `bpm_http_errors_total` (Counter): HTTP 5xx responses labelled by `path`.
- Metrics collection MUST be non-blocking; a slow metrics scrape MUST NOT delay API request processing.

**See:** OBS-01 (logging is complementary, not a substitute for metrics), API-12 (health endpoints are a separate concern)

**Edge cases:**
- Metrics endpoint called during DB outage: returns HTTP 200 with available in-memory metrics; `bpm_active_instances_total` may be stale.
