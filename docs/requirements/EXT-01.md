---
id: EXT-01
title: Service task node type
stage: 6
priority: MUST
status: RELEASED
---

# EXT-01 — Service task node type `[MUST]`

> The platform SHALL support a SERVICE_TASK node type that invokes an external HTTP endpoint (URL, method, and optional headers defined in the node configuration) as part of process execution. Response payload (on HTTP 2xx) is merged into instance variables. **Failure handling:** configurable timeout (default 30s); on timeout, non-2xx response, or network error, the platform SHALL retry up to N times (configurable per node, default 3) with exponential back-off. After exhausting retries, the failed invocation is moved to the DLQ (OBS-05) and the instance transitions to ERROR status (EE-10).

**Acceptance Criteria:**
- GIVEN execution reaches a SERVICE_TASK node, WHEN the HTTP call receives an HTTP 2xx response, THEN the JSON response body is merged into instance variables per EE-09.
- GIVEN an HTTP 2xx response body that is not a JSON object, THEN it is NOT merged; instance transitions to ERROR (EE-10).
- Timeout default is 30 seconds; configurable per node via `timeout_ms`. On timeout: counted as a failure, retry logic applies.
- GIVEN N retries are exhausted, THEN the failed invocation is moved to OBS-05 DLQ and the instance transitions to ERROR per EE-10.
- The platform MUST NOT follow HTTP redirects automatically. Redirect responses (3xx) MUST be treated as failures.

**See:** EE-09 (response merge into variables), EE-10 (ERROR path on exhausted retries), OBS-05 (DLQ storage), API-09 (trace_id included in outgoing request headers)

**Edge cases:**
- SERVICE_TASK URL containing a template variable that resolves to an empty string: rejected at node activation with EE-10.
- HTTP 429 from the external service: treated as a failure; retry logic applies.
