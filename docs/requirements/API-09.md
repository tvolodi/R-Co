---
id: API-09
title: Request tracing
stage: 4
priority: MUST
status: VALIDATED
---

# API-09 — Request tracing `[MUST]`

> Each request SHALL be assigned a `trace_id` (UUID). The `trace_id` SHALL appear in the response headers (`X-Trace-Id`) and in all log entries generated during that request.

**Acceptance Criteria:**
- GIVEN any request to any platform endpoint, WHEN processed, THEN the response includes an `X-Trace-Id` header containing a UUID v4 assigned at request start.
- If the caller supplies an `X-Trace-Id` request header, the platform MUST use that value as the trace ID for that request (propagation).
- The trace ID MUST appear in every log entry emitted during that request's processing.
- The trace ID MUST appear in the `trace_id` field of any error response body.

**See:** OBS-01 (structured logging carries trace_id), API-01 (error response format)

**Edge cases:**
- Request fails authentication (HTTP 401): trace ID is still assigned and returned.
- Caller supplies an `X-Trace-Id` that is not a valid UUID: platform SHOULD accept and propagate it as-is (no validation enforced on incoming trace IDs).
