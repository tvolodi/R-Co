# Test Spec: API-09 — Request tracing

**Requirement:** API-09 — Each request SHALL be assigned a `trace_id` (UUID). The `trace_id` SHALL appear in the response headers (`X-Trace-Id`) and in all log entries generated during that request.  
**Priority:** MUST  
**Test layer:** unit, integration

---

## Coverage matrix

| Acceptance criterion | Test case(s) |
|---|---|
| Response includes `X-Trace-Id` header with UUID v4 | TC-API-09-01, TC-API-09-05, TC-API-09-INT-01 |
| Caller-supplied `X-Trace-Id` is propagated as-is | TC-API-09-02, TC-API-09-INT-02 |
| Trace ID appears in every log entry | TC-API-09-INT-03 |
| Trace ID appears in `trace_id` field of error response body | TC-API-09-07, TC-API-09-08, TC-API-09-09, TC-API-09-INT-04 |
| HTTP 401 still assigns and returns trace ID | TC-API-09-INT-05 |
| Non-UUID `X-Trace-Id` accepted and propagated | TC-API-09-03, TC-API-09-INT-06 |

---

## Unit test cases

All unit tests live in `tests/unit/test_api09_tracing.zig`.  
Run with: `zig build test`

### TC-API-09-01: No header → generate UUID v4
**Given:** No `X-Trace-Id` request header  
**When:** `trace.extractOrGenerate(alloc, null)` is called  
**Then:** `result.propagated == false` and `result.trace_id.len == UUID_V4_LEN (36)`  
**Layer:** unit  
**Acceptance criterion mapped:** Response includes `X-Trace-Id` containing a UUID v4  
**Status:** Covered by existing test `TC-API-09-01` in `test_api09_tracing.zig`

### TC-API-09-02: Present header propagated as-is
**Given:** A valid UUID string is supplied as the `X-Trace-Id` request header  
**When:** `trace.extractOrGenerate(alloc, "550e8400-e29b-41d4-a716-446655440000")` is called  
**Then:** `result.propagated == true` and `result.trace_id` equals the supplied value exactly  
**Layer:** unit  
**Acceptance criterion mapped:** Caller-supplied `X-Trace-Id` is used as the trace ID  
**Status:** Covered by existing test `TC-API-09-02` in `test_api09_tracing.zig`

### TC-API-09-03: Non-UUID value accepted without validation
**Given:** A non-UUID string `"not-a-uuid-at-all"` is supplied as the `X-Trace-Id` header  
**When:** `trace.extractOrGenerate(alloc, "not-a-uuid-at-all")` is called  
**Then:** `result.propagated == true` and `result.trace_id == "not-a-uuid-at-all"`  
**Layer:** unit  
**Acceptance criterion mapped:** Non-UUID incoming trace ID is accepted and propagated as-is (edge case)  
**Status:** Covered by existing test `TC-API-09-03` in `test_api09_tracing.zig`

### TC-API-09-04: Empty header → generate UUID v4
**Given:** An empty string `""` is supplied as the `X-Trace-Id` header  
**When:** `trace.extractOrGenerate(alloc, "")` is called  
**Then:** `result.propagated == false` and `result.trace_id.len == UUID_V4_LEN`  
**Layer:** unit  
**Acceptance criterion mapped:** Absent/empty header causes a fresh UUID v4 to be generated  
**Status:** Covered by existing test `TC-API-09-04` in `test_api09_tracing.zig`

### TC-API-09-05: Generated UUID v4 format is correct
**Given:** A freshly generated UUID v4 via `trace.generateUuidV4(&buf)`  
**When:** The resulting 36-character string is inspected  
**Then:**
- Dashes at positions 8, 13, 18, 23
- Version nibble at position 14 is `'4'`
- Variant nibble at position 19 is `'8'`, `'9'`, `'a'`, or `'b'`
- All non-dash characters are lowercase hexadecimal digits  
**Layer:** unit  
**Acceptance criterion mapped:** Response `X-Trace-Id` contains a correctly-formatted UUID v4  
**Status:** Covered by existing test `TC-API-09-05` in `test_api09_tracing.zig`

### TC-API-09-06: trace_context lifecycle
**Given:** A cleared trace context  
**When:** `trace_ctx.set("my-request-trace")` is called, then `trace_ctx.clear()`  
**Then:** `get()` returns `""` initially, `"my-request-trace"` after set, and `""` after clear  
**Layer:** unit  
**Acceptance criterion mapped:** Trace ID is stored per-thread and accessible within the request lifecycle  
**Status:** Covered by existing test `TC-API-09-06` in `test_api09_tracing.zig`

### TC-API-09-07: `serialise()` includes trace_id from thread-local context
**Given:** `trace_ctx` is set to `"test-trace-abc-123"` before serialisation  
**When:** `errors.serialise(alloc, pd)` is called on a `ProblemDetails` with empty `trace_id`  
**Then:** The JSON output contains both `"trace_id"` key and value `"test-trace-abc-123"`  
**Layer:** unit  
**Acceptance criterion mapped:** Trace ID appears in the `trace_id` field of every error response body  
**Status:** Covered by existing test `TC-API-09-07` in `test_api09_tracing.zig`

### TC-API-09-08: `serialise()` uses explicit `pd.trace_id` over thread-local
**Given:** Thread-local is `"thread-local-id"` but `pd.trace_id = "explicit-id-override"`  
**When:** `errors.serialise(alloc, pd)` is called  
**Then:** JSON contains `"explicit-id-override"` and does NOT contain `"thread-local-id"`  
**Layer:** unit  
**Acceptance criterion mapped:** Explicit trace_id on the struct takes precedence (test-only override path)  
**Status:** Covered by existing test `TC-API-09-08` in `test_api09_tracing.zig`

### TC-API-09-09: `serialise()` emits empty trace_id when context is clear
**Given:** `trace_ctx` is cleared and `pd.trace_id` is at its default `""`  
**When:** `errors.serialise(alloc, pd)` is called  
**Then:** JSON contains `"trace_id":""` (field always present, never omitted)  
**Layer:** unit  
**Acceptance criterion mapped:** `trace_id` field is always serialised (backward-compatible empty value)  
**Status:** Covered by existing test `TC-API-09-09` in `test_api09_tracing.zig`

### TC-API-09-10: Oversized incoming `X-Trace-Id` is truncated
**Given:** An incoming `X-Trace-Id` value longer than `MAX_TRACE_ID_LEN`  
**When:** `trace.extractOrGenerate(alloc, long_id)` is called  
**Then:** `result.propagated == true` and `result.trace_id.len == MAX_TRACE_ID_LEN`  
**Layer:** unit  
**Acceptance criterion mapped:** Platform protects itself from unbounded header lengths (edge case)  
**Status:** Covered by existing test `TC-API-09-10` in `test_api09_tracing.zig`

---

## Integration test cases

Integration tests verify the behaviour at the HTTP boundary using a real running server.  
Test file: `tests/integration/trace_test.zig`  
Requires: `BPM_TEST_DB_URL` pointing to a real PostgreSQL instance.

### TC-API-09-INT-01: X-Trace-Id response header present on successful request
**Given:** The BPM server is running; a valid API token exists in the database  
**When:** `GET /api/v1/definitions` is requested with a valid `Authorization: Bearer <token>` header and no `X-Trace-Id` header  
**Then:**
- HTTP 200 is returned
- The response includes an `X-Trace-Id` header
- The header value is exactly 36 characters long
- The header value matches the UUID v4 format: `[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}`  
**Layer:** integration  
**Acceptance criterion mapped:** Every response includes `X-Trace-Id` header with UUID v4

### TC-API-09-INT-02: Caller-supplied X-Trace-Id is echoed back
**Given:** The BPM server is running; a valid API token exists  
**When:** `GET /api/v1/definitions` is sent with `X-Trace-Id: my-custom-trace-99`  
**Then:**
- HTTP 200 is returned
- The response `X-Trace-Id` header equals `"my-custom-trace-99"` (exact match)  
**Layer:** integration  
**Acceptance criterion mapped:** Caller-supplied `X-Trace-Id` is propagated as the request trace ID

### TC-API-09-INT-03: Trace ID appears in log output for the request
**Given:** The BPM server is running with structured JSON logging enabled; a valid API token exists  
**When:** `GET /api/v1/definitions` is sent with `X-Trace-Id: log-test-trace-id-42`  
**Then:**
- HTTP 200 is returned
- At least one log line written during that request contains `"trace_id":"log-test-trace-id-42"` (or equivalent JSON field)  
**Layer:** integration  
**Acceptance criterion mapped:** Trace ID appears in every log entry during the request's processing  
**Notes:** Test reads server log output from a captured stdout/stderr stream or log file. The exact log field name must match the OBS-01 structured log format.

### TC-API-09-INT-04: Trace ID appears in error response body
**Given:** The BPM server is running; a valid API token exists  
**When:** `GET /api/v1/definitions/nonexistent-id` is sent (causes 404 error)  
**Then:**
- HTTP 404 is returned
- Response `Content-Type` is `application/problem+json`
- Response body JSON contains a `"trace_id"` field matching the `X-Trace-Id` response header value  
**Layer:** integration  
**Acceptance criterion mapped:** Trace ID appears in the `trace_id` field of any error response body

### TC-API-09-INT-05: Trace ID assigned and returned on HTTP 401
**Given:** The BPM server is running  
**When:** `GET /api/v1/definitions` is sent with no `Authorization` header (or an invalid token)  
**Then:**
- HTTP 401 is returned
- The response includes an `X-Trace-Id` header with a non-empty value
- The response body (if JSON) contains a `"trace_id"` field matching the header value  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP 401 auth failure still assigns and returns a trace ID (edge case)

### TC-API-09-INT-06: Non-UUID incoming trace ID is propagated unchanged
**Given:** The BPM server is running; a valid API token exists  
**When:** `GET /api/v1/definitions` is sent with `X-Trace-Id: totally-not-a-uuid!@#`  
**Then:**
- HTTP 200 is returned
- The response `X-Trace-Id` header equals `"totally-not-a-uuid!@#"` (exact match, no rejection)  
**Layer:** integration  
**Acceptance criterion mapped:** Non-UUID caller-supplied trace ID is accepted and propagated as-is (edge case)  
**Notes:** If the value exceeds `MAX_TRACE_ID_LEN`, it will be truncated; that length boundary case is already covered at unit level by TC-API-09-10.

---

## Gap analysis against existing unit tests

The following test cases are **fully covered** by `tests/unit/test_api09_tracing.zig`:

| TC | Status |
|---|---|
| TC-API-09-01 | ✓ exists |
| TC-API-09-02 | ✓ exists |
| TC-API-09-03 | ✓ exists |
| TC-API-09-04 | ✓ exists |
| TC-API-09-05 | ✓ exists |
| TC-API-09-06 | ✓ exists |
| TC-API-09-07 | ✓ exists |
| TC-API-09-08 | ✓ exists |
| TC-API-09-09 | ✓ exists |
| TC-API-09-10 | ✓ exists |

**Gaps requiring new integration test code** — none of the unit tests can verify HTTP-level behaviour:

| TC | Gap description |
|---|---|
| TC-API-09-INT-01 | No test verifies the `X-Trace-Id` response header over real HTTP |
| TC-API-09-INT-02 | No test verifies header propagation end-to-end over real HTTP |
| TC-API-09-INT-03 | No test captures and parses structured log output to confirm trace_id |
| TC-API-09-INT-04 | No test sends a real request and checks the error body `trace_id` field |
| TC-API-09-INT-05 | No test verifies 401 response still carries `X-Trace-Id` header |
| TC-API-09-INT-06 | No test verifies non-UUID propagation over real HTTP (only at unit level) |

**Action:** `TEST-RUNNER` (WF-02 Step 4) must implement `tests/integration/trace_test.zig` covering TC-API-09-INT-01 through TC-API-09-INT-06 before API-09 can advance to status `TESTED`.
