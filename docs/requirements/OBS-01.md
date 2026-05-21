---
id: OBS-01
title: Structured logging
stage: 6
priority: MUST
status: VALIDATED
---

# OBS-01 — Structured logging `[MUST]`

> All platform components SHALL emit structured JSON log entries to stdout. Each entry SHALL include: `timestamp`, `level`, `trace_id`, `component`, `message`, and optional key-value context.

**Acceptance Criteria:**
- Every log entry emitted by the platform MUST be a single-line JSON object containing at minimum: `timestamp` (ISO 8601), `level` (DEBUG/INFO/WARN/ERROR), `trace_id` (UUID or empty string), `component` (module or subsystem name), `message` (human-readable string).
- Log level is configurable via `BPM_LOG_LEVEL` environment variable. Valid values: DEBUG, INFO, WARN, ERROR. Invalid value MUST cause a fatal startup error.
- Structured logs MUST NOT include sensitive data: no token values, no plaintext credentials, no password fields.
- All log entries within a request's processing MUST carry the same `trace_id` as the response `X-Trace-Id` header (API-09).

**See:** API-09 (trace_id propagation), OBS-03 (audit log is a separate concern)

**Edge cases:**
- Log entry for a background task (scheduler, timer poller): `trace_id` is an internally generated UUID for that background operation.
- A log entry that would include a sensitive field: the value MUST be replaced with `"[REDACTED]"`.
