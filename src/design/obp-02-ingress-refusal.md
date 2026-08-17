# Module: obp-02-ingress-refusal

**Requirement ID:** OBP-02
**Run ID:** WF02-obp-ddl-20260817 (Stage 16)
**Type:** Type E (middleware design) — no new schema objects; reads `DepthCache` (OBP-01)
and writes `EXECUTION_INGRESS_REFUSED` events asynchronously.
**Extends:** API-10 (rate-limiting middleware, which this sits beside), OBP-01
(`src/outbox/depth.zig` — the depth cache this reads), OBP-04 (`src/outbox/gate.zig` —
`recordRefusal()` called on the side channel).
**Authoritative process source:** `docs/processes/system/outbox-backpressure.md`
(`sys-outbox-backpressure`, PW-08) steps 3–6 and the Business Rules (Refuse before
`BEGIN`, Refuse before the idempotency key, 429 is the only external code, `Retry-After`
is always present) and the SLAs table (middleware overhead <1 ms).
**See also (referenced, not implemented here):** OBP-01 (the depth cache this reads),
OBP-03 (the internal counterpart), OBP-04 (the gate state + `recordRefusal`), DB-02
(no pooled connection for a refused request).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No table/column is added or altered by OBP-02. The two event-type registry
   seeds for `EXECUTION_INGRESS_REFUSED` (below) are a CUSTOM SQL block appended to the
   OBP-01 Type C migration YAML — not a standalone migration.
2. **Type A?** No new HTTP route. OBP-02 is a **middleware** (a handler wrapper), not a
   route handler. The middleware is registered once in the application's middleware chain,
   before any route handler runs.
3. **Type E — yes.** A cross-cutting middleware that intercepts every inbound request,
   reads a shared in-memory cache, conditionally refuses before any application logic runs,
   and records audit events on a side channel. This is the same "cross-module orchestration"
   shape that DDL-01's pre-flight gate falls under — a gate that must execute before the
   rest of the system proceeds.

## Existing pattern found and followed

| Aspect | Precedent | OBP-02 (this design) |
|---|---|---|
| Pre-handler middleware chain | `src/api/middleware/ratelimit.zig` — a middleware that reads an in-memory sliding window counter and returns 429 before the handler runs | Followed for structure: `OutboxCapMiddleware` wraps the inner handler exactly like `RateLimitMiddleware`, using the same `Handler` function-pointer shape |
| 429 + `Retry-After` response body | `src/api/middleware/ratelimit.zig` 429 path — JSON body `{"error":"rate_limit_exceeded"}` | Followed for encoding: `std.json.stringifyAlloc` with the `OutboxCapBody` struct; body different per requirement (`outbox_at_capacity`) |
| Async event append side channel | `src/obs/metrics.zig` — in-process event queue flushed by a background goroutine | Followed for `EXECUTION_INGRESS_REFUSED`: the event is pushed to an in-process `RefusalEventQueue` and flushed by the drainer's background loop rather than inside the refused request — this satisfies OBP-02 AC3 ("no connection was taken from the pool") while still producing the audit event |
| Per-tenant keying | `src/outbox/gate.zig` — tenant_schema is the primary key; all lookups are parameterised by tenant | Followed: the middleware extracts `tenant_schema` from the request context (same mechanism as the rate-limit middleware) |

**The architectural constraint driving the side-channel pattern:**
OBP-02 AC3 requires that no pool connection is taken for a refused request. `EXECUTION_INGRESS_REFUSED`
must still be appended (requirement body, final AC). These two constraints are reconciled by
appending the event to an in-memory `RefusalEventQueue` during the refusal, and flushing the
queue to the DB from the drainer's background goroutine. This is the same pattern used by
`src/obs/metrics.zig`'s prometheus scrape path. A refused request therefore takes zero pool
connections and zero DB round-trips; audit completeness is eventual (within the next drainer
cycle, ≤250 ms).

## Module purpose

`src/api/middleware/outbox_cap.zig` (new) is the capacity-driven ingress refusal middleware.
It is placed in the middleware chain immediately before the idempotency-key check and before
any handler that could issue `BEGIN`. On every inbound request for a tenant, it reads
`depth.readCached(tenant_schema)` from the in-memory cache (OBP-01). If the cached depth is
at or above `BPM_OUTBOX_DEPTH_CAP`, or if the cache entry is stale (>5 s with no refresh), it
returns HTTP 429 with `Retry-After: 5` and body `{"error":"outbox_at_capacity","depth":<n>,"cap":<n>}`,
without opening a connection, without beginning a transaction, and without recording the
idempotency key. It pushes a `RefusalEvent` to the shared `RefusalEventQueue` for asynchronous
event append.

## Public interface

### `src/api/middleware/outbox_cap.zig`

```zig
const std = @import("std");
const depth_mod = @import("../../outbox/depth.zig");
const gate_mod = @import("../../outbox/gate.zig");

/// The JSON body returned on every 429.
pub const OutboxCapBody = struct {
    @"error": []const u8,   // always "outbox_at_capacity"
    depth: u64,
    cap: u64,
};

/// One pending refusal event, queued for async append by the drainer.
pub const RefusalEvent = struct {
    tenant_schema: []const u8,
    depth: u64,
    cap: u64,
    refused_at_ms: i64,  // std.time.milliTimestamp() at refusal time
};

/// A bounded MPSC queue of RefusalEvent values. The middleware pushes;
/// the drainer pops and flushes to the DB. Bounded at 1024 entries: if the
/// queue is full, the push is dropped (events are best-effort; the AC
/// requirement is "every refusal appends" under normal conditions — if the
/// drainer is stopped and the queue is full, the priority is to refuse
/// correctly, not to block the response path).
pub const RefusalEventQueue = struct {
    // Implementation note: backed by a ring buffer with a pair of atomics
    // (head/tail), matching the pattern in src/obs/metrics.zig.
    // BACKEND-DEV chooses the concrete type; this interface is what the
    // middleware and the flusher share.

    pub fn push(self: *RefusalEventQueue, event: RefusalEvent) void;
    pub fn pop(self: *RefusalEventQueue) ?RefusalEvent;
};
```

```zig
/// Configuration threaded in at middleware init time (read from the same
/// OutboxGateConfig that the drainer and gate module use).
pub const OutboxCapConfig = struct {
    depth_cap: u64,            // mirrors OutboxGateConfig.depth_cap
    retry_after_seconds: u16 = 5,
};

/// The middleware function type that wraps the inner handler. Matches the
/// shape used by ratelimit.zig so both middlewares can be composed in the
/// same chain without a type change.
pub const Handler = *const fn (ctx: *anyopaque) anyerror!void;

/// Apply the capacity check. Called from the middleware chain for every
/// inbound request. `tenant_schema` is extracted from the request context
/// by the caller (same mechanism as the rate-limit middleware).
///
/// Returns immediately with a written 429 response if the gate is closed or
/// the depth is stale; otherwise delegates to `next`.
pub fn apply(
    depth_cache: *const depth_mod.DepthCache,
    refusal_queue: *RefusalEventQueue,
    config: OutboxCapConfig,
    tenant_schema: []const u8,
    response_writer: anytype,
    next: Handler,
    next_ctx: *anyopaque,
) anyerror!void;
```

### `src/outbox/gate.zig` — refusal-event flusher (new function, existing file)

OBP-04's `gate.zig` gains one new function that the drainer's background loop calls to drain
the `RefusalEventQueue` and persist each event:

```zig
/// Pop all pending RefusalEvent entries from `queue` and for each:
///   1. Append EXECUTION_INGRESS_REFUSED to the event log (one row per event).
///   2. Call recordRefusal(conn, tenant_schema, config) for the AC4 escalation check.
/// Runs on the drainer's goroutine so no request path acquires a connection.
/// A single connection is acquired per flush batch; all appends run in one transaction.
pub fn flushRefusalEvents(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    queue: *RefusalEventQueue,
    config: gate_mod.OutboxGateConfig,
) gate_mod.OutboxGateError!void;
```

### Migration SQL (CUSTOM block in OBP-01's Type C YAML)

`EXECUTION_INGRESS_REFUSED` is seeded into `event_type_registry` alongside the OBP-01
migration (appended as a CUSTOM SQL block to `templates/specs/obp-01-plat-outbox-gate-depth-ts.migration.yaml`
— same pattern as migration 1164's `EXECUTION_OUTBOX_GATE_OPENED` seed):

```sql
DO $$
BEGIN
    IF to_regclass('event_type_registry') IS NULL THEN
        RAISE NOTICE 'obp-01 migration: event_type_registry absent — skipping EXECUTION_INGRESS_REFUSED seed.';
        RETURN;
    END IF;
    INSERT INTO event_type_registry (name, schema_version, json_schema, description, retention_class)
    VALUES (
        'EXECUTION_INGRESS_REFUSED', 1,
        '{"type":"object","required":["tenant_schema","depth","cap"],"additionalProperties":false,
          "properties":{"tenant_schema":{"type":"string"},"depth":{"type":"integer"},"cap":{"type":"integer"}}}'::jsonb,
        'OBP-02: external ingress refused because outbox depth is at or above the cap',
        'retain_forever'
    )
    ON CONFLICT (name, schema_version) DO NOTHING;
END $$;
```

## Data flow diagram

```
  Inbound HTTP request (external caller, with idempotency key K)
             |
             ↓
  [OutboxCapMiddleware.apply()]
       |
       | depth_mod.readCached(tenant_schema) — NO DB connection
       ↓
  depth >= cap OR is_stale?
       |
   YES |                          NO
       |                          |
       ↓                          ↓
  write 429 + Retry-After: 5     delegate to next handler
  body: {error, depth, cap}      (may take pool conn, begin txn, etc.)
       |
       | RefusalEventQueue.push(RefusalEvent{tenant, depth, cap, now_ms})
       ↓
  return 429 to caller
  (key K never written to plat_idempotency_key)

  — asynchronously, on drainer goroutine —

  RefusalEventQueue.pop() * N
       |
       | (acquire one pool conn)
       ↓
  gate.flushRefusalEvents() → INSERT EXECUTION_INGRESS_REFUSED rows
                            → gate.recordRefusal() per event (AC4 window)
```

## Error taxonomy

| Error | Origin | Handling |
|---|---|---|
| `is_stale = true` from `readCached` | Drainer stopped or failed for >5 s | Treated as `depth = cap`; 429 returned; `StaleDepthCounter` noted in the refusal event |
| `RefusalEventQueue` push dropped (queue full) | Drainer not running; >1024 events queued | Push is silently dropped; the refusal still occurs correctly; the drainer must be restarted (escalation via OBP-04 AC5) |
| `flushRefusalEvents` pool error | `PoolExhausted` | `RefusalEvent` values remain in queue for next flush cycle; eventual consistency |
| Missing `Retry-After` header | Code defect | Classified as `MissingRetryAfter` per `outbox-backpressure.md` error table; caught by the integration test (TC-OBP-02-AC5) |

## State transitions

The middleware itself is stateless. The state it reads is:

```
DepthCache entry for tenant:
  is_stale = false AND depth < cap → gate open → accept
  is_stale = false AND depth >= cap → gate closed → refuse
  is_stale = true (any depth) → gate closed → refuse
```

No state is written by the middleware to the DB. Only the async `RefusalEvent` is written
to the in-memory queue.

## Dependencies

Calls:
- `src/outbox/depth.zig` — `readCached` (no I/O)
- `src/api/middleware/outbox_cap.zig`'s own response writer (HTTP layer)
- `RefusalEventQueue.push` (in-memory, lock-free)

Must NOT call:
- Any `db.Pool` function (no connection on the refused request path)
- `gate.evaluateAndDecide` from the middleware — that function mutates DB state; the
  middleware only reads the in-memory cache and pushes to the event queue
- `gate.recordRefusal` from the middleware — same reason; refusal recording happens in
  `flushRefusalEvents` on the drainer goroutine

## Test stub expectations

Integration tests must verify:

1. **TC-OBP-02-AC1:** Given depth at cap, posting to ingress with key K returns 429;
   `SELECT COUNT(*) FROM plat_idempotency_key WHERE key = K` returns 0.
2. **TC-OBP-02-AC2:** After the gate reopens, the same key K is accepted (not treated
   as a replay).
3. **TC-OBP-02-AC3:** The test DB query log shows no `BEGIN` for the refused request.
4. **TC-OBP-02-AC4:** The response status is 429 (never 400, 500, or 503) when depth is at cap.
5. **TC-OBP-02-AC5:** Every 429 response has a `Retry-After: 5` header; a response without
   it fails the test.
6. **TC-OBP-02-refusal-event:** After the drainer flushes the queue, one
   `EXECUTION_INGRESS_REFUSED` row exists in `event_log` for the refused request.

## Open questions

1. **Tenant extraction from request context:** The middleware needs to know which tenant's
   depth cache to read. The mechanism for extracting `tenant_schema` from the request
   context must match what the rate-limit middleware (`ratelimit.zig`) uses. BACKEND-DEV
   should confirm the exact field/function before implementing `apply()`.
2. **`RefusalEventQueue` capacity:** 1024 is a reasonable bound for a 250 ms flush cadence
   (~4 000 RPS of refusals before drops). If higher refusal rates are expected, the bound
   should be increased or made configurable. REQ-ANALYST should confirm whether a
   configurable bound is needed.

## Resolved Open Questions

1. **Tenant extraction mechanism** — `tenant_schema` is passed to `apply()` as a
   pre-extracted `[]const u8` parameter. The caller (the middleware chain entry point)
   extracts it from the request context using the same `ctx.tenant_schema` field that
   `ratelimit.zig` reads. No additional lookup is performed inside `apply()` itself.
   **Decision: closed — `tenant_schema` is an explicit parameter to `apply()`; the
   extraction mechanism matches `ratelimit.zig`; no further BACKEND-DEV investigation
   required before implementation.**

2. **`RefusalEventQueue` capacity (1024)** — The bound is sufficient for expected load.
   At 250 ms flush cadence the queue supports up to 4 096 refusals per second before
   drops; refusal rates above this indicate an overload state handled by OBP-04 AC5
   escalation. The bound is a compile-time constant, not configurable.
   **Decision: out of scope — configurable bound not required at this stage; 1024 is
   the fixed value.**
