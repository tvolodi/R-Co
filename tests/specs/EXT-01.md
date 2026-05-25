# Test Spec: EXT-01 — Service task node type

**Requirement:** EXT-01 — The platform SHALL support a SERVICE_TASK node type that invokes an external HTTP endpoint (URL, method, and optional headers defined in the node configuration) as part of process execution. Response payload (on HTTP 2xx) is merged into instance variables. Failure handling: configurable timeout (default 30s); on timeout, non-2xx response, or network error, the platform SHALL retry up to N times (configurable per node, default 3) with exponential back-off. After exhausting retries, the failed invocation is moved to the DLQ (OBS-05) and the instance transitions to ERROR status (EE-10).
**Priority:** MUST
**Test layer:** unit, integration

---

## Requirement Traceability

| Acceptance criterion / edge case | Test case IDs | Layer | Module touchpoints |
|---|---|---|---|
| 2xx JSON object response is merged into instance variables per EE-09 | TC-EXT-01-U09, TC-EXT-01-INT-02 | unit, integration | `src/engine/service_task.zig`, `src/engine/transition.zig`, `src/definition/graph.zig` |
| 2xx response body that is not a JSON object is not merged and transitions to ERROR | TC-EXT-01-U10, TC-EXT-01-INT-03 | unit, integration | `src/engine/service_task.zig`, `src/engine/transition.zig`, `src/engine/retry_policy.zig` |
| Timeout defaults to 30s and `timeout_ms` override is honored; timeout counts as failure and retries apply | TC-EXT-01-U01, TC-EXT-01-U04, TC-EXT-01-INT-04 | unit, integration | `src/engine/service_task.zig`, `src/engine/retry_policy.zig` |
| Exhausted retries move item to OBS-05 DLQ and transition instance to ERROR per EE-10 | TC-EXT-01-U06, TC-EXT-01-U07, TC-EXT-01-INT-07 | unit, integration | `src/engine/service_task.zig`, `src/dlq/store.zig`, `src/engine/transition.zig` |
| Redirect responses (3xx) are treated as failures and are not auto-followed | TC-EXT-01-U07, TC-EXT-01-INT-05 | unit, integration | `src/engine/service_task.zig` |
| HTTP 429 is treated as a failure and retry logic applies | TC-EXT-01-U07, TC-EXT-01-INT-06 | unit, integration | `src/engine/service_task.zig`, `src/engine/retry_policy.zig` |
| Empty rendered URL is rejected at activation with EE-10 | TC-EXT-01-U02, TC-EXT-01-INT-01 | unit, integration | `src/engine/service_task.zig`, `src/engine/transition.zig` |
| Trace ID is propagated to outbound headers and idempotency header remains stable across retries | TC-EXT-01-U08, TC-EXT-01-INT-02, TC-EXT-01-INT-04, TC-EXT-01-INT-06, TC-EXT-01-INT-07 | unit, integration | `src/api/middleware/trace.zig`, `src/engine/service_task.zig` |

---

## Unit Test Cases

Unit tests target the pure request-construction, validation, retry-policy, and classification helpers in `tests/unit/service_task_test.zig`.

### TC-EXT-01-U01: Activation config applies default timeout and retry limit
**Given:** A SERVICE_TASK config with a valid URL template and method, but no explicit `timeout_ms` or `retry_limit`
**When:** The activation/config parsing helper renders the node configuration
**Then:**
- `timeout_ms` resolves to `30000`
- `retry_limit` resolves to `3`
- The method remains the configured method
- The URL template is preserved for rendering
**Layer:** unit
**Acceptance criterion mapped:** Default timeout is 30 seconds; default retry count is 3

### TC-EXT-01-U02: Empty rendered URL is rejected immediately
**Given:** A SERVICE_TASK URL template that renders to an empty string after variable substitution
**When:** The activation validation helper checks the rendered URL
**Then:** The helper returns `EmptyRenderedUrl` (or the module equivalent), and no outbound request is built
**Layer:** unit
**Acceptance criterion mapped:** Edge case: empty resolved URL template is rejected at activation with EE-10

### TC-EXT-01-U03: Header rendering rejects empty names or values
**Given:** A SERVICE_TASK config whose rendered header map contains either an empty key or an empty value
**When:** The activation validation/request-construction helper processes headers
**Then:** The helper returns `InvalidConfig` (or the module equivalent)
**Layer:** unit
**Acceptance criterion mapped:** URL/method/header construction is explicit and invalid rendered headers are rejected

### TC-EXT-01-U04: Timeout override is honored and visible to the attempt context
**Given:** A SERVICE_TASK config with `timeout_ms = 5000`
**When:** The request/attempt preparation helper builds the execution context
**Then:** The prepared request uses the override value rather than the default
**Layer:** unit
**Acceptance criterion mapped:** Configurable timeout via `timeout_ms`

### TC-EXT-01-U05: Exponential backoff grows predictably and is capped
**Given:** Base backoff `500ms` and cap `30000ms`
**When:** `computeServiceTaskBackoffMs()` is called for attempt indexes `1`, `2`, `3`, and a high attempt index that would exceed the cap
**Then:** The returned delays are `500`, `1000`, `2000`, and `30000` respectively
**Layer:** unit
**Acceptance criterion mapped:** Retry logic uses exponential back-off

### TC-EXT-01-U06: Retry limit zero means single-shot execution
**Given:** A retriable failure kind with `retry_limit = 0`
**When:** The failure classification helper decides the terminal action for attempt index `1`
**Then:** The decision is terminal and no second attempt is scheduled
**Layer:** unit
**Acceptance criterion mapped:** Retry limit is configurable per node and may disable retries beyond the initial attempt

### TC-EXT-01-U07: Failure classification distinguishes retriable and terminal conditions
**Given:** Representative HTTP outcomes and execution errors
**When:** The failure classifier evaluates `302`, `429`, non-2xx status codes, invalid 2xx body, and request-build errors
**Then:**
- `302` is classified as retriable redirect failure
- `429` is classified as retriable rate-limit failure
- Non-2xx responses are classified as retriable HTTP failure
- Invalid 2xx body is classified as terminal/non-retriable
- Request-build errors are classified as terminal/non-retriable
**Layer:** unit
**Acceptance criterion mapped:** Redirects and 429 are failures; invalid 2xx body is immediate ERROR; request-build errors are immediate ERROR

### TC-EXT-01-U08: Trace and idempotency headers are injected and idempotency key is stable
**Given:** A fixed `trace_id`, `instance_id`, `node_id`, and `token_id`
**When:** The request builder constructs outbound headers for multiple attempts of the same activation
**Then:**
- `X-Trace-Id` is present and equals the supplied trace ID
- `X-BPM-Idempotency-Key` is present
- The idempotency key is identical across retries for the same activation
**Layer:** unit
**Acceptance criterion mapped:** API-09 trace propagation and stable retry idempotency header

### TC-EXT-01-U09: HTTP 2xx object response merges into instance variables
**Given:** A 2xx attempt result with a JSON object body
**When:** The merge helper applies the response payload to the instance variable map
**Then:**
- New keys are inserted
- Existing keys are overwritten per EE-09 semantics
- The helper returns a success decision for continuing execution
**Layer:** unit
**Acceptance criterion mapped:** 2xx JSON object body is merged into instance variables per EE-09

### TC-EXT-01-U10: HTTP 2xx non-object body is rejected as invalid
**Given:** A 2xx attempt result with a JSON array, scalar, null, or plain-text body that does not parse to a JSON object
**When:** The success-path evaluator inspects the body
**Then:** The result is classified as invalid 2xx body and not merged
**Layer:** unit
**Acceptance criterion mapped:** 2xx body that is not a JSON object is not merged and transitions to ERROR

---

## Integration Test Cases

Integration tests use a real PostgreSQL-backed instance and a deterministic local HTTP test server that returns fixed responses per route.

### TC-EXT-01-INT-01: Empty rendered URL rejects activation and transitions instance to ERROR
**Given:**
- A persisted definition containing a SERVICE_TASK node whose URL template renders to an empty string
- An ACTIVE instance positioned at that node
**When:** The engine attempts to activate the SERVICE_TASK
**Then:**
- The instance transitions to `ERROR`
- An `EXECUTION_ERROR` event is appended with the activation failure reason
- No outbound HTTP request is issued to the test server
**Layer:** integration
**Acceptance criterion mapped:** Edge case: empty resolved URL template is rejected at activation with EE-10

### TC-EXT-01-INT-02: 2xx JSON object response merges variables and preserves outbound headers
**Given:**
- A SERVICE_TASK configured with POST, optional headers, a JSON body template, `timeout_ms`, and `retry_limit`
- A local HTTP route that returns HTTP 200 with a JSON object body
- A seeded ACTIVE instance with existing variables and a fixed trace ID
**When:** The instance reaches the SERVICE_TASK node
**Then:**
- The outbound request uses the configured method
- The outbound request includes configured headers plus `X-Trace-Id` and `X-BPM-Idempotency-Key`
- The response object is merged into instance variables
- Existing variables are overwritten according to EE-09 rules
- The instance continues past the SERVICE_TASK path without entering ERROR
**Layer:** integration
**Acceptance criterion mapped:** 2xx JSON object merge; trace/idempotency propagation; URL/method/header construction

### TC-EXT-01-INT-03: 2xx non-object body transitions to ERROR without merge
**Given:** A SERVICE_TASK pointing at a route that returns HTTP 200 with a JSON array, scalar, null, or plain-text body
**When:** The instance reaches the SERVICE_TASK node
**Then:**
- The instance transitions to `ERROR`
- An `EXECUTION_ERROR` event is appended
- The response body is not merged into instance variables
- No retry is scheduled because the body is terminally invalid
**Layer:** integration
**Acceptance criterion mapped:** Invalid 2xx body is not merged and transitions to ERROR (EE-10)

### TC-EXT-01-INT-04: Timeout override triggers retry and preserves outbound headers across attempts
**Given:**
- A SERVICE_TASK configured with a short `timeout_ms` override and `retry_limit >= 1`
- A local HTTP route that intentionally delays longer than the timeout on the first attempt, then returns HTTP 200 on the retry
**When:** The instance reaches the SERVICE_TASK node
**Then:**
- The first attempt times out and is counted as a failure
- A retry is scheduled using exponential backoff
- The second attempt uses the same `X-BPM-Idempotency-Key` and the same `X-Trace-Id`
- The instance succeeds after the retry
**Layer:** integration
**Acceptance criterion mapped:** Timeout handling, retry logic, trace propagation, idempotency header stability

### TC-EXT-01-INT-05: Redirect responses are not auto-followed and count as failures
**Given:** A SERVICE_TASK pointing at a route that returns HTTP 302 with a Location header to a separate success route
**When:** The instance reaches the SERVICE_TASK node
**Then:**
- The engine does not follow the redirect automatically
- The redirect response is treated as a failure kind
- If retry budget remains, a retry is scheduled; otherwise the invocation proceeds to terminal failure handling
- The redirect target route is never invoked as a side effect of auto-following
**Layer:** integration
**Acceptance criterion mapped:** Redirects are failures and MUST NOT be auto-followed

### TC-EXT-01-INT-06: HTTP 429 is treated as a retriable failure
**Given:** A SERVICE_TASK pointing at a route that returns HTTP 429 on the first attempt and HTTP 200 on the retry
**When:** The instance reaches the SERVICE_TASK node
**Then:**
- The 429 response is treated as a failure
- The engine retries according to the configured retry policy
- The retry uses the same trace and idempotency headers as the first attempt
- The instance succeeds after the retry
**Layer:** integration
**Acceptance criterion mapped:** HTTP 429 is treated as a failure; retry logic applies

### TC-EXT-01-INT-07: Exhausted retries move the failure to OBS-05 DLQ and ERROR atomically
**Given:**
- A SERVICE_TASK configured with a finite retry limit
- A local HTTP route that keeps returning a retriable failure until the retry limit is exhausted
- A seeded ACTIVE instance with deterministic trace and request context
**When:** The instance reaches the SERVICE_TASK node and all retries fail
**Then:**
- The invocation is written to the OBS-05 DLQ with full context
- The instance transitions to `ERROR`
- An `EXECUTION_ERROR` event is recorded
- The DLQ write and ERROR transition are visible together after commit
**Layer:** integration
**Acceptance criterion mapped:** Exhausted retries move item to DLQ and transition instance to ERROR per EE-10

---

## Fixture Plan

Integration tests require the following deterministic fixtures:

| Fixture | Purpose | Used by |
|---|---|---|
| `service_task_definition_base` | Active definition with a SERVICE_TASK node, POST method, headers, body template, `timeout_ms`, and `retry_limit` | TC-EXT-01-INT-02, TC-EXT-01-INT-04, TC-EXT-01-INT-05, TC-EXT-01-INT-06, TC-EXT-01-INT-07 |
| `service_task_definition_empty_url` | Definition whose URL template resolves to an empty string | TC-EXT-01-INT-01 |
| `service_task_definition_non_object_body` | Definition pointed at a route returning array/scalar/null/plain text | TC-EXT-01-INT-03 |
| `http_server_ok_object` | Returns HTTP 200 with a JSON object body | TC-EXT-01-INT-02, TC-EXT-01-INT-04, TC-EXT-01-INT-06 |
| `http_server_redirect` | Returns HTTP 302 to a separate target route | TC-EXT-01-INT-05 |
| `http_server_rate_limit` | Returns HTTP 429 on the first attempt | TC-EXT-01-INT-06 |
| `http_server_slow` | Delays longer than the configured timeout for timeout tests | TC-EXT-01-INT-04 |
| `http_server_failure_loop` | Repeats a retriable failure until retry budget is exhausted | TC-EXT-01-INT-07 |
| `instance_fixture_active_service_task` | Seeded ACTIVE instance positioned on the SERVICE_TASK node with known variables | All integration cases except TC-EXT-01-INT-01 when the failure occurs during activation before request dispatch |
| `trace_id_fixture` | Fixed trace identifier for header propagation assertions | TC-EXT-01-INT-02, TC-EXT-01-INT-04, TC-EXT-01-INT-06, TC-EXT-01-INT-07 |
| `db_transaction_rollback` | Per-test rollback wrapper for PostgreSQL isolation | All integration cases |

---

## Coverage Notes

- Every EXT-01 acceptance criterion is mapped to at least one unit and one integration test case.
- The empty URL edge case and invalid 2xx body edge case are both explicit and non-skipped.
- The DLQ + ERROR terminal path is covered by a real database-backed integration case so the state transition and DLQ write can be observed together.
- No test case depends on wall-clock time beyond deterministic timeout overrides in the local HTTP server fixture.

## Rework Addendum

The following explicit cases close the coverage gaps reported in the EXT-01 rework handoff:

| Missing scenario from prior run | Test case IDs | Test source |
|---|---|---|
| Empty rendered header names/values are rejected | TC-PD-05-09f | `tests/unit/graph_node_attributes_test.zig` |
| Retry limit zero is single-shot / terminal on the first retriable failure | TC-EXT-01-U06a | `tests/unit/service_task_test.zig` |
| Trace header and idempotency header are injected on outbound requests | TC-EXT-01-U08a, TC-EXT-01-INT-02, TC-EXT-01-INT-04, TC-EXT-01-INT-06, TC-EXT-01-INT-07 | `tests/unit/service_task_test.zig`, `tests/integration/ext01_service_task_test.zig` |
| Successful 2xx object merge into instance variables | TC-EXT-01-U09, TC-EXT-01-INT-02 | `tests/unit/service_task_test.zig`, `tests/integration/ext01_service_task_test.zig` |
| Invalid 2xx body is terminal and does not merge | TC-EXT-01-U10, TC-EXT-01-INT-03 | `tests/unit/service_task_test.zig`, `tests/integration/ext01_service_task_test.zig` |
| Dedicated EXT-01 integration suite with seven explicit scenarios | TC-EXT-01-INT-01 through TC-EXT-01-INT-07 | `tests/integration/ext01_service_task_test.zig` |