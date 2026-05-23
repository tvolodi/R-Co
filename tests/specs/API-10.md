# Test Spec: API-10 — Rate limiting

**Requirement:** API-10 — The API SHALL enforce per-token rate limits (configurable, default 1,000 req/min). Exceeded limits MUST return HTTP 429 with a `Retry-After` header.
**Priority:** SHOULD
**Test layer:** unit, integration

---

## Coverage matrix

| Acceptance criterion | Test case(s) |
|---|---|
| Requests within the 1,000 req/min limit are all allowed | TC-API-10-01, TC-API-10-02, TC-API-10-03, TC-API-10-INT-01 |
| Request N+1 returns HTTP 429 with `Retry-After` header | TC-API-10-04, TC-API-10-05, TC-API-10-INT-02, TC-API-10-INT-04 |
| `Retry-After` value is a non-negative integer (seconds until window resets) | TC-API-10-05, TC-API-10-06, TC-API-10-INT-04 |
| Requests receiving HTTP 429 do NOT invoke the route handler (no state changes) | TC-API-10-INT-03 |
| Per-token override via `BPM_RATE_LIMIT_TOKEN_<id>` is respected | TC-API-10-08 |
| Token with no configured limit uses the global default (1,000 req/min) | TC-API-10-03, TC-API-10-09 |
| After the 60-second window expires the counter resets | TC-API-10-06, TC-API-10-INT-05 |
| Rate limit is per-token; two different tokens do not share counters | TC-API-10-07, TC-API-10-INT-06 |

---

## Unit test cases

All unit tests live in `src/api/middleware/rate_limit.zig` (inline `test` blocks).
Run with: `zig build test`

---

### TC-API-10-01: init and deinit succeed without error

**Given:**
- No prior module state; `std.testing.allocator` available.

**When:**
- `init(std.testing.allocator)` is called, then `deinit()` is called.

**Then:**
- Both calls return without error.
- No memory is leaked (verified by `std.testing.allocator` leak detection).

**Layer:** unit
**Acceptance criterion mapped:** Module lifecycle — baseline sanity before any functional test.
**Status:** Covered by existing test `"init and deinit: no error"` in `rate_limit.zig`.

---

### TC-API-10-02: First request for any token is always allowed

**Given:**
- Module initialised via `init()`; token `"token-abc"` has no prior bucket.

**When:**
- `check(alloc, "token-abc", 1000)` is called for the first time.

**Then:**
- Result is `.allowed`.
- A new `TokenBucket{ .bucket_start = 1000, .count = 1 }` is inserted into the map.

**Layer:** unit
**Acceptance criterion mapped:** Requests within the limit are allowed; first-ever request for a token creates a fresh bucket at count = 1 and is never rejected.
**Status:** Covered by existing test `"check: first request is allowed"` in `rate_limit.zig`.

---

### TC-API-10-03: All 1,000 requests within the default limit return `.allowed`

**Precondition:**
- Module initialised; no per-token env var set for `"token-within"`.
- `now_unix = 2000`.

**When:**
- `check(std.testing.allocator, "token-within", 2000)` is called exactly 1,000 times (= `DEFAULT_LIMIT`).

**Then:**
- Every one of the 1,000 calls returns `.allowed`.

**Layer:** unit
**Acceptance criterion mapped:**
- Scenario 1: requests below the limit all succeed.
- Scenario 6: default limit of 1,000 is used when no per-token env var is configured.
**Status:** Covered by existing test `"check: requests within default limit are allowed"` in `rate_limit.zig`.

---

### TC-API-10-04: Request N+1 (the 1,001st) returns `.rate_limited`

**Precondition:**
- Module initialised; token `"token-exceed"` has been called 1,000 times at `t = 3000`; bucket is full.

**When:**
- `check(alloc, "token-exceed", 3000)` is called a 1,001st time.

**Then:**
- Result is `.rate_limited` (union variant `.rate_limited`).

**Layer:** unit
**Acceptance criterion mapped:** Scenario 2 — request N+1 after the limit is exceeded returns a rate-limited result (`.rate_limited` variant at unit level; HTTP 429 verified at integration level).
**Status:** Covered by existing test `"check: request exceeding limit returns rate_limited"` in `rate_limit.zig`.

---

### TC-API-10-05: `retry_after` equals seconds remaining in the window

**Precondition:**
- Module initialised; token `"token-exceed"` bucket filled at `t = 3000`; `bucket_start = 3000`; `WINDOW_SECONDS = 60`.

**When:**
- The 1,001st call `check(alloc, "token-exceed", 3000)` is evaluated.

**Then:**
- `result.rate_limited.retry_after == 60`.
  - Calculation: `bucket_start + WINDOW_SECONDS - now = 3000 + 60 - 3000 = 60`.
- `result.rate_limited.body` is non-empty and must be freed by the caller.

**Layer:** unit
**Acceptance criterion mapped:** Scenario 3 — `Retry-After` value is a positive integer equal to the number of seconds until the window resets.
**Status:** Covered by the `expectEqual(@as(u32, 60), info.retry_after)` assertion in test `"check: request exceeding limit returns rate_limited"` in `rate_limit.zig`.

---

### TC-API-10-06: Window reset at exact boundary returns `.allowed` (Retry-After: 0 edge case)

**Precondition:**
- Module initialised; token `"token-reset"` bucket filled at `t0 = 4000`.
- `t1 = t0 + WINDOW_SECONDS = 4060`.

**When:**
- `check(alloc, "token-reset", 4060)` is called (the first request in the new window).

**Then:**
- Result is `.allowed` — not `.rate_limited`.
- The bucket resets: `bucket_start = 4060`, `count = 1`.

**Layer:** unit
**Acceptance criterion mapped:**
- Scenario 7: after the 60-second window expires, the counter resets and requests succeed.
- Scenario 3 edge case (`Retry-After: 0`): the requirement edge case "Retry-After: 0 — window has just reset; client may retry immediately" is expressed in the implementation by allowing the request outright rather than returning a 0-second Retry-After header. When `now_unix >= bucket_start + WINDOW_SECONDS` the algorithm takes the window-reset branch and returns `.allowed`; the clamp `retry_after = max(0, diff)` inside the `.rate_limited` branch is unreachable at this boundary in normal single-threaded operation. The RFC 9457 "client may retry immediately" semantic is therefore satisfied: the client receives 2xx, not 429.
**Status:** Covered by existing test `"check: window reset allows requests again"` in `rate_limit.zig`. The test `"check: retry_after is clamped to 0 when diff <= 0"` also exercises this exact boundary and confirms `.allowed` is returned.

---

### TC-API-10-07: Two different tokens have independent counters

**Precondition:**
- Module initialised; `now_unix = 6000`.
- Token `"token-multi-a"` has been called 1,000 times (bucket full).

**When:**
1. `check(alloc, "token-multi-a", 6000)` is called (1,001st request for token A).
2. `check(alloc, "token-multi-b", 6000)` is called (first request for token B).

**Then:**
1. Result for token A is `.rate_limited`.
2. Result for token B is `.allowed`.
- Token B's first call allocates an independent `TokenBucket` keyed to `"token-multi-b"`; it does not read or modify token A's bucket.

**Layer:** unit
**Acceptance criterion mapped:** Scenario 8 — rate limit is per-token; two different tokens do not share counters.
**Status:** Covered by existing test `"check: multiple distinct tokens tracked independently"` in `rate_limit.zig`.

---

### TC-API-10-08: Per-token override via `BPM_RATE_LIMIT_TOKEN_<id>` env var

**Precondition:**
- Environment variable `BPM_RATE_LIMIT_TOKEN_test-token-limit` is set to `"10"`.
- Module initialised; `now_unix = 7000`; default limit is 1,000.

**Steps:**
1. Call `check(alloc, "test-token-limit", 7000)` exactly 10 times.
2. Call `check(alloc, "test-token-limit", 7000)` an 11th time.

**Expected result:**
1. All 10 calls return `.allowed`.
2. The 11th call returns `.rate_limited` with `retry_after = 60` (not the default 1,000; the custom limit of 10 applies).
3. Cleanup: `deinit()` + unset env var.

**Layer:** unit
**Acceptance criterion mapped:** Scenario 5 — a token with a custom limit (e.g. 10/min) is limited at 10, not at the global default of 1,000.
**Status:** **NEW TEST REQUIRED** — no existing test exercises the `BPM_RATE_LIMIT_TOKEN_<id>` env var path in `limitForToken()`. Add a new inline `test` block in `rate_limit.zig`.

---

### TC-API-10-09: Default fallback — unconfigured token uses `DEFAULT_LIMIT`

**Precondition:**
- No env var `BPM_RATE_LIMIT_TOKEN_never-configured` set.
- `BPM_RATE_LIMIT_DEFAULT` not set (hardcoded `DEFAULT_LIMIT = 1000` in effect).

**Steps:**
1. Call `limitForToken("never-configured")` directly (or indirectly via `check()`).

**Expected result:**
- Returned limit equals `1000` (`DEFAULT_LIMIT`).
- Explicitly distinguishable from a custom override: if the env var WERE set to `"500"`, the returned limit would be `500`.

**Layer:** unit
**Acceptance criterion mapped:** Scenario 6 — token with no configured limit uses the global default (1,000 req/min).
**Status:** Implicitly covered by TC-API-10-03 and TC-API-10-04, which run without any `BPM_RATE_LIMIT_TOKEN_*` env var. **Add an explicit unit test** that asserts `limitForToken("never-configured") == 1000` to make the coverage unambiguous.

---

## Integration test cases

Integration tests verify the full HTTP stack: rate-limit middleware wiring, HTTP response status, response headers, body shape, and route-handler isolation.
Test file: `tests/integration/rate_limit_test.zig`
Run with: `zig build test-integration` (requires `BPM_TEST_DB_URL` pointing to a real PostgreSQL instance and a valid seeded Bearer token).

---

### TC-API-10-INT-01: HTTP requests within the configured limit return 2xx

**Precondition:**
- BPM server running with `BPM_RATE_LIMIT_DEFAULT = "5"` (small limit to avoid 1,000-request loop).
- A valid Bearer token `TKN_A` exists in the database; 0 requests have been made in the current window.

**Steps:**
1. Send 5 `GET /api/v1/definitions` requests with `Authorization: Bearer TKN_A`.

**Expected result:**
- All 5 responses have HTTP status 200.
- No response contains a `Retry-After` header.

**Layer:** integration
**Acceptance criterion mapped:** Scenario 1 — requests below the limit all succeed.

---

### TC-API-10-INT-02: HTTP request N+1 returns 429 with `Retry-After` header

**Precondition:**
- BPM server running with `BPM_RATE_LIMIT_DEFAULT = "5"`.
- Valid Bearer token `TKN_A`; exactly 5 requests already sent in the current window.

**Steps:**
1. Send a 6th `GET /api/v1/definitions` request with `Authorization: Bearer TKN_A`.

**Expected result:**
- HTTP status 429.
- Response includes header `Retry-After` with a non-negative integer value.
- Response header `Content-Type` is `application/problem+json`.
- Response body is valid JSON containing:
  - `"status": 429`
  - `"title": "Too Many Requests"`
  - `"type"` ending in `/rate-limited`

**Layer:** integration
**Acceptance criterion mapped:** Scenario 2 — request N+1 returns HTTP 429 with `Retry-After` header; body conforms to RFC 9457.

---

### TC-API-10-INT-03: Route handler is NOT invoked when rate-limited (no state changes)

**Precondition:**
- BPM server running with `BPM_RATE_LIMIT_DEFAULT = "5"`.
- Valid Bearer token `TKN_B` with `PROCESS_DESIGNER` or higher role.
- Token `TKN_B` has already exhausted its 5-request limit in the current window.
- Record the current count of rows in `process_definitions` (call it `count_before`).

**Steps:**
1. Send `POST /api/v1/definitions` with a valid definition body, `Authorization: Bearer TKN_B` (6th request — would create a new definition if processed).

**Expected result:**
- HTTP status 429.
- A `SELECT COUNT(*) FROM process_definitions` query returns `count_before` (unchanged); no new definition was created.
- No new entry appears in `GET /api/v1/definitions` response.

**Layer:** integration
**Acceptance criterion mapped:** Scenario 4 — requests that receive HTTP 429 MUST NOT be processed; no state changes occur.

---

### TC-API-10-INT-04: `Retry-After` header value is a positive integer ≤ 60

**Precondition:**
- BPM server running with `BPM_RATE_LIMIT_DEFAULT = "2"`.
- Valid Bearer token `TKN_C`; 2 requests already sent at some time T within a 60-second window.

**Steps:**
1. Send a 3rd request within the same window.

**Expected result:**
- HTTP status 429.
- `Retry-After` header value `r` satisfies: `1 <= r <= 60` (positive integer, at most one window length).
- Parsing `r` as a decimal integer succeeds without error.

**Layer:** integration
**Acceptance criterion mapped:** Scenario 3 — `Retry-After` value is a positive integer equal to the seconds remaining in the current window.

---

### TC-API-10-INT-05: Counter resets after 60-second window expires

**Precondition:**
- BPM server running with `BPM_RATE_LIMIT_DEFAULT = "2"`.
- Valid Bearer token `TKN_D`; rate limit exhausted in window W0.

**Steps:**
1. Wait until window W0 has fully elapsed (>60 seconds after `TKN_D`'s first request in W0).
2. Send 2 `GET /api/v1/definitions` requests with `Authorization: Bearer TKN_D`.

**Expected result:**
- Both responses have HTTP status 200.
- No `Retry-After` header is present in either response.

**Layer:** integration
**Acceptance criterion mapped:** Scenario 7 — after the 60-second window expires, the counter resets and subsequent requests succeed.
**Notes:** This test requires a real time-wait of >60 seconds, or a server-side test clock injection hook if one is added. The test runner should mark this test as slow (`// slow: ~61s`) and ensure it is not skipped in CI runs that validate API-10.

---

### TC-API-10-INT-06: Per-token isolation — two tokens do not share a counter

**Precondition:**
- BPM server running with `BPM_RATE_LIMIT_DEFAULT = "2"`.
- Valid Bearer tokens `TKN_E` and `TKN_F` both exist in the database.
- Token `TKN_E` has exhausted its limit (2 requests sent).
- Token `TKN_F` has made 0 requests in the current window.

**Steps:**
1. Send `GET /api/v1/definitions` with `Authorization: Bearer TKN_F`.

**Expected result:**
- HTTP status 200.
- No `Retry-After` header.
- Token `TKN_F`'s counter is independent of `TKN_E`'s; it starts at 0 regardless of `TKN_E`'s exhausted limit.

**Layer:** integration
**Acceptance criterion mapped:** Scenario 8 — rate limit is per-token; two different tokens do not share counters.

---

## Gap analysis against existing unit tests

The following test cases are **fully covered** by existing inline tests in `src/api/middleware/rate_limit.zig`:

| TC | Status |
|---|---|
| TC-API-10-01 | ✓ `"init and deinit: no error"` |
| TC-API-10-02 | ✓ `"check: first request is allowed"` |
| TC-API-10-03 | ✓ `"check: requests within default limit are allowed"` |
| TC-API-10-04 | ✓ `"check: request exceeding limit returns rate_limited"` |
| TC-API-10-05 | ✓ `"check: request exceeding limit returns rate_limited"` (`retry_after == 60` assertion) |
| TC-API-10-06 | ✓ `"check: window reset allows requests again"` + `"check: retry_after is clamped to 0 when diff <= 0"` |
| TC-API-10-07 | ✓ `"check: multiple distinct tokens tracked independently"` |
| TC-API-10-08 | ✗ **MISSING** — no test sets `BPM_RATE_LIMIT_TOKEN_<id>` and verifies the custom limit |
| TC-API-10-09 | ~ Implicitly covered by TC-API-10-03/04; no explicit `limitForToken()` assertion |

**Gaps requiring new test code:**

| TC | Gap description | Target file |
|---|---|---|
| TC-API-10-08 | New inline test: set env var `BPM_RATE_LIMIT_TOKEN_test-token-limit = "10"`, verify limit enforced at 10 not 1,000 | `src/api/middleware/rate_limit.zig` |
| TC-API-10-09 | New inline test: assert `limitForToken("never-configured") == DEFAULT_LIMIT` when no matching env var is set | `src/api/middleware/rate_limit.zig` |
| TC-API-10-INT-01 through TC-API-10-INT-06 | No HTTP-level scenario has any integration test code yet | `tests/integration/rate_limit_test.zig` (new file) |
