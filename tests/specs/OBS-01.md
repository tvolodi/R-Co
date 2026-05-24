# Test Spec: OBS-01 — Structured logging

**Requirement:** OBS-01 — All platform components SHALL emit structured JSON log entries to stdout. Each entry SHALL include: `timestamp`, `level`, `trace_id`, `component`, `message`, and optional key-value context.
**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OBS-01-01: Invalid BPM_LOG_LEVEL fails startup validation
**Given:** `BPM_DB_URL` is set and `BPM_LOG_LEVEL` is set to an invalid value such as `TRACE`
**When:** startup configuration is loaded
**Then:** configuration loading returns `InvalidLogLevel` before the server or scheduler starts
**Layer:** unit
**Acceptance criterion mapped:** Invalid `BPM_LOG_LEVEL` MUST cause fatal startup error

### TC-OBS-01-02: Structured log line includes required fields and stays single-line
**Given:** a logger call with a component, message, and non-sensitive context fields
**When:** the log line is serialized
**Then:** the output is a single-line JSON object containing `timestamp`, `level`, `trace_id`, `component`, and `message`
**Layer:** unit
**Acceptance criterion mapped:** Every emitted log entry MUST be a single-line JSON object with the required field set

### TC-OBS-01-03: Sensitive context fields are redacted in emitted JSON
**Given:** a logger call includes sensitive fields such as `Authorization`, `session_token`, or `password`
**When:** the log line is serialized
**Then:** each sensitive value is replaced with `[REDACTED]` while non-sensitive siblings remain unchanged
**Layer:** unit
**Acceptance criterion mapped:** Structured logs MUST NOT include sensitive data

### TC-OBS-01-04: Request logs propagate the request trace ID into structured output
**Given:** an HTTP request to `/health/live` includes an `X-Trace-Id` header and server log capture is enabled
**When:** the request is processed successfully
**Then:** the response echoes the same `X-Trace-Id`, and the emitted structured log line contains the identical `trace_id` plus the expected request log fields
**Layer:** integration
**Acceptance criterion mapped:** All log entries within a request MUST carry the same `trace_id` as the response `X-Trace-Id` header

### TC-OBS-01-05: Background operations generate UUID trace IDs
**Given:** a scheduler or timer background operation begins without a request trace context
**When:** the background trace scope is created
**Then:** the generated `trace_id` is a UUID v4 and is available for background log emission
**Layer:** unit
**Acceptance criterion mapped:** Background task log entries MUST use an internally generated UUID trace ID
