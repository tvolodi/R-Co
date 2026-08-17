# Test Spec: OBP-02 — External ingress refusal before transaction

**Requirement:** OBP-02 — When outbox depth is at or above the cap, external ingress SHALL be
refused with HTTP 429 and header `Retry-After: 5`, returned by middleware before `BEGIN` is
issued, before a pool connection is taken, and before the idempotency key is recorded. The
response body SHALL be `{"error":"outbox_at_capacity","depth":<n>,"cap":<n>}`. A refused request
SHALL leave the caller's idempotency key unused.

**Priority:** SHOULD
**Test layer:** unit (pure middleware `apply()` against stub response writer and stub depth cache)
+ integration (real `plat_idempotency_key` absence check; real `EXECUTION_INGRESS_REFUSED` event
append via `flushRefusalEvents`)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, `plat_idempotency_key` is a
tenant-scoped table written by the non-refused path) + tenant isolation (2, middleware is
per-tenant) + transactional boundary (1, refused requests explicitly must not open a transaction)
= **5 points → sandbox tier by rubric** — no Wasm/sandbox surface; unit + integration is
the proportionate ceiling.
**Design:** `src/design/obp-02-ingress-refusal.md`
**Implementation:** `src/api/middleware/outbox_cap.zig` (`apply`, `RefusalEventQueue`),
`src/outbox/gate.zig` (`flushRefusalEvents`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN depth is at the cap, WHEN an external caller posts to ingress with idempotency key K, THEN the response is 429 with `Retry-After: 5`, and no row for K exists in `plat_idempotency_key`. | `TC-OBP-02-AC1-429-no-idempotency-row` (integration) + `obp02: depth at cap — returns 429 with correct body` (unit in `outbox_cap.zig`) |
| AC2 | GIVEN the same caller retries with key K after the gate reopens, WHEN the request is handled, THEN it is processed as a first attempt and not as a replay. | `TC-OBP-02-AC2-key-unused-after-reopen` (integration) |
| AC3 | GIVEN a refused request, WHEN the database is inspected, THEN no transaction was opened and no connection was taken from the pool for that request. | `TC-OBP-02-AC3-no-pool-connection` (unit — stub conn never called) |
| AC4 | GIVEN outbox capacity is reached, WHEN a refusal is emitted, THEN the status code is 429 and never 400, 500, or 503. | `TC-OBP-02-AC4-status-code-429` (unit) |
| AC5 | GIVEN a 429 is emitted on this path without the `Retry-After` header, WHEN the response is validated, THEN it is recorded as a defect; the header is unconditional. | `TC-OBP-02-AC5-retry-after-unconditional` (unit) |
| AC6 | Every refusal appends `EXECUTION_INGRESS_REFUSED` carrying tenant, depth, and cap. | `TC-OBP-02-AC6-ingress-refused-event` (integration via `flushRefusalEvents`) |

---

## Test cases

### TC-OBP-02-AC1-429-no-idempotency-row: at-cap depth returns 429 with Retry-After; idempotency key K absent
**Given:** A depth cache with depth = cap (50000 = 50000). A per-test `tenant_schema` and idempotency
key K (per-test UUID). The middleware is applied with the at-cap cache.
**When:** `apply(...)` is called; the response writer captures the result.
**Then:** Response status is 429. `Retry-After` header value is "5". Body contains `"outbox_at_capacity"`,
`"depth":50000`, and `"cap":50000`. A subsequent query of `plat_idempotency_key` for key K returns 0 rows
(the key was never written because the middleware returned before any handler ran).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `TC-OBP-02-AC1-429-no-idempotency-row` (`tests/integration/obp02_ingress_refusal_test.zig`)

### TC-OBP-02-AC2-key-unused-after-reopen: the same key processes normally after the gate reopens
**Given:** The depth cache was at-cap during a prior refusal (key K absent from `plat_idempotency_key`).
The depth is now below the low-water mark; the cache is refreshed with depth = 0.
**When:** `apply(...)` is called again with the same key K.
**Then:** The inner handler runs (status is NOT 429). A row for key K now exists in
`plat_idempotency_key` (the handler created it as a first attempt, not a replay).
**Layer:** integration
**Acceptance criterion mapped:** AC2
**Zig test:** `TC-OBP-02-AC2-key-unused-after-reopen` (`tests/integration/obp02_ingress_refusal_test.zig`)

### TC-OBP-02-AC3-no-pool-connection: a refused request calls no DB functions
**Given:** A stub connection whose `exec` and `query` methods record whether they were called.
The depth cache has depth >= cap.
**When:** `apply(...)` is called.
**Then:** The stub conn's call counters are both zero — no DB function was called on the refused path.
**Layer:** unit (pure — no DB, stub conn)
**Acceptance criterion mapped:** AC3
**Zig test:** `TC-OBP-02-AC3-no-pool-connection` (`tests/integration/obp02_ingress_refusal_test.zig`) + `obp02: depth at cap — returns 429 with correct body` (unit in `outbox_cap.zig`)

### TC-OBP-02-AC4-status-code-429: status code is exactly 429, not 400/500/503
**Given:** A depth cache with depth >= cap (at-cap condition).
**When:** `apply(...)` is called and the response writer captures the status.
**Then:** `writer.status == 429`. It is never 400, 500, or 503.
**Layer:** unit (pure — no DB)
**Acceptance criterion mapped:** AC4
**Zig test:** `obp02: depth at cap — returns 429 with correct body` (in `src/api/middleware/outbox_cap.zig`)

### TC-OBP-02-AC5-retry-after-unconditional: Retry-After header is present on every 429
**Given:** An at-cap depth cache (both depth >= cap AND stale cache, tested separately).
**When:** `apply(...)` is called for each condition.
**Then:** `response_writer.headers_written == true` and the serialised body contains `"Retry-After"`:
the header write path is always taken, never omitted. Verified for both the `depth >= cap` branch
and the `is_stale` branch.
**Layer:** unit (pure — no DB)
**Acceptance criterion mapped:** AC5
**Zig test:** `obp02: stale cache — returns 429 (fail-closed)` (in `src/api/middleware/outbox_cap.zig`)

### TC-OBP-02-AC6-ingress-refused-event: EXECUTION_INGRESS_REFUSED is appended with tenant, depth, cap
**Given:** A `RefusalEventQueue` with one pushed `RefusalEvent` (tenant, depth=50000, cap=50000).
A real DB connection and the `public.events` table (or equivalent `event_log`).
**When:** `gate.flushRefusalEvents(allocator, pool, &queue, config)` is called.
**Then:** One row with `event_type = 'EXECUTION_INGRESS_REFUSED'` exists whose payload JSON contains
the tenant schema, `depth: 50000`, and `cap: 50000`.
**Layer:** integration
**Acceptance criterion mapped:** AC6
**Zig test:** `TC-OBP-02-AC6-ingress-refused-event` (`tests/integration/obp02_ingress_refusal_test.zig`)
