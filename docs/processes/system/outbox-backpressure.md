# Process: Outbox Backpressure

| Field | Value |
|-------|-------|
| Process ID | `sys-outbox-backpressure` |
| Platform Workflow | PW-08 |
| Requirements | OBP-01, OBP-02, OBP-03, OBP-04 |
| Owner | Platform Admin |
| Scope | System-wide (the outbox in every tenant schema) |
| Source | `docs/workflows.yaml` (PW-08) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.10 (FR-GRO-4) |

## Summary

The outbox has a depth cap. Two producers can breach it and they need two
different answers. **External ingress** -- a webhook post or an API emit -- is
refused with `429 Too Many Requests` at the middleware, before `BEGIN` and before
the idempotency key is recorded, so the caller's retry with the same key is still
a first attempt. **An internal emit** from a service task cannot be handed a
status code mid-transaction, so `outbox.emit()` returns the typed error
`error.OutboxOverflow`, the step fails, and the existing retry policy backs it
off into the dead-letter path. The result is that a runaway internal producer
throttles itself: its own steps are the ones that fail.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| External Caller | Tenant system or webhook source | Posts to ingress; receives 429 and `Retry-After` |
| Ingress Middleware | System (`plat_backpressure_filter`) | Reads cached depth and refuses before any transaction opens |
| Idempotency Store | System (`plat_idempotency_key`) | Records keys; never written on a refused request |
| BPM Engine | System | Executes service task steps that call `outbox.emit()` |
| Outbox Drainer | System (single drainer) | Publishes rows, deletes them, and refreshes the cached depth |
| Platform Admin | Human operator | Sets the cap; receives escalation when the drainer cannot recover |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `BPM_OUTBOX_DEPTH_CAP` | integer | Default 50000; the high-water mark for refusal |
| `BPM_OUTBOX_LOW_WATER` | integer | Default 40000, fixed at 80 per cent of the cap; the reopen threshold |
| `depth_refresh_interval_ms` | integer | Default 250; how often the drainer republishes the cached depth |
| `retry_after_seconds` | integer | Default 5; value of the `Retry-After` header on refusal |
| `idempotency_key` | text | Supplied by the external caller; recorded only on an accepted request |
| `step_retry_policy` | object | Per-node max attempts and backoff; governs `OutboxOverflow` retries |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Outbox Drainer | Publish pending rows, delete them, and write the new depth to the shared cached counter every 250 ms | Counter refresh fails? | -> The last value is held and marked stale; a value stale beyond 5 s is treated as at-cap and ingress closes | OBP-01 |
| 2 | Ingress Middleware | Read the cached depth counter for the tenant | Counter read costs a `count(*)`? | -> Refused at code review: depth is read from the cached counter only, never counted per request | OBP-01 |
| 3 | Ingress Middleware | Compare depth against `BPM_OUTBOX_DEPTH_CAP` before any handler runs | `depth >= cap` and the gate is open? | -> Gate closes; the request is refused at step 4 | OBP-02 |
| 4 | Ingress Middleware | Refuse the request: return `429 Too Many Requests` with `Retry-After: 5` and body `{"error":"outbox_at_capacity","depth":<n>,"cap":<n>}` | Any transaction opened? | -> No `BEGIN` was issued; no connection was taken from the pool | OBP-02 |
| 5 | Ingress Middleware | Leave the idempotency key untouched | Key already written for this request? | -> It is not: the refusal precedes the Idempotency Store write. The caller's retry with the same key is a first attempt, not a replay | OBP-02 |
| 6 | Ingress Middleware | Emit `EXECUTION_INGRESS_REFUSED` with tenant, depth, and cap | Refusal rate exceeds 100 per minute for one tenant? | -> Escalate to Platform Admin; the drainer is not keeping pace | OBP-04 |
| 7 | BPM Engine | Execute a service task step that calls `outbox.emit()` inside the step transaction | `depth >= cap`? | -> `outbox.emit()` returns `error.OutboxOverflow`; no row is inserted | OBP-03 |
| 8 | BPM Engine | Propagate `error.OutboxOverflow` out of the step body | Step declares an error set covering `OutboxOverflow`? | -> Missing coverage is a compile error, caught by the error-set check before release | OBP-03 |
| 9 | BPM Engine | Roll back the step transaction | Partial outbox rows written? | -> None: the emit failed before insert, and the rollback discards every other write of that step | OBP-03 |
| 10 | BPM Engine | Apply the node's retry policy with backoff | Attempts remaining? | -> Step is re-armed after the backoff interval; the producing instance stops adding load while the drainer catches up | OBP-03 |
| 11 | BPM Engine | Route the step to the dead-letter path when attempts are exhausted | Attempts exhausted? | -> Instance transitions to `failed`; the DLQ entry carries `OutboxOverflow` and the depth at each attempt | OBP-03 |
| 12 | Outbox Drainer | Continue draining while ingress is closed and steps back off | Depth falls to `BPM_OUTBOX_LOW_WATER` or below? | -> Gate reopens; the next ingress request is accepted | OBP-04 |
| 13 | Ingress Middleware | Hold the gate closed until the low-water mark is crossed, not the cap | Depth oscillates between 49999 and 50001? | -> The gate stays closed until 40000, so a full tenant does not flip open and closed per request | OBP-04 |
| 14 | Outbox Drainer | Emit `EXECUTION_OUTBOX_GATE_OPENED` on reopen with the closed duration | Closed longer than 300 s? | -> Escalate to Platform Admin: the drainer throughput is below the emit rate | OBP-04 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Two paths, one cap | External ingress and internal emit share `BPM_OUTBOX_DEPTH_CAP`. They differ only in how the breach is reported. |
| Refuse before `BEGIN` | The external check runs in middleware ahead of the handler. A refused request opens no transaction and takes no pool connection. |
| Refuse before the idempotency key | The key is written by the handler, not the middleware. A 429 leaves the key unused, so the caller's retry with the same key is a first attempt rather than a replay of a request that never ran. |
| 429 is the only external code | Outbox capacity is a throttling condition, not a client error and not a server fault. It is never reported as 400, 500 or 503. |
| `Retry-After` is always present | Every 429 carries `Retry-After: 5`. A refusal without the header is a defect. |
| Internal emit cannot be refused with a code | A step is mid-transaction and has no response to write. The only correct signal is a typed error out of `outbox.emit()`. |
| `OutboxOverflow` is a typed error | `error.OutboxOverflow` appears in the declared error set of `outbox.emit()` and of every caller. It is never `catch unreachable` and never mapped to a generic failure. |
| Overflow reuses the existing failure path | No new retry mechanism is introduced. The node's configured retry policy and the existing dead-letter path handle it. |
| Self-throttling | A runaway internal producer fails its own steps first. Backoff on those steps is what reduces the emit rate; no separate rate limiter is added. |
| Depth is cached, never counted | Depth comes from a counter the drainer refreshes every 250 ms. No request path issues `SELECT count(*) FROM plat_outbox`. |
| Stale counter closes the gate | A counter older than 5 s is treated as at-cap. Loss of depth visibility closes ingress rather than opening it. |
| Hysteresis | The gate closes at the cap and reopens at the low-water mark of 80 per cent. It never reopens at the cap itself. |
| Per-tenant accounting | Depth, cap, gate state, and refusal counters are per tenant schema. One tenant at capacity does not refuse another tenant's ingress. |
| Cap is operator-set, not derived | `BPM_OUTBOX_DEPTH_CAP` is read from the environment at startup. It is not inferred from disk, memory, or observed throughput. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `429 Too Many Requests` | External refusal with `Retry-After: 5` and a body carrying `depth` and `cap` |
| Unconsumed idempotency key | The caller's key remains unrecorded and reusable after a refusal |
| `error.OutboxOverflow` | Typed error returned by `outbox.emit()` to the failing step |
| Failed step | Step rolled back, re-armed under its retry policy, then dead-lettered on exhaustion |
| DLQ entry | Carries `OutboxOverflow`, the attempt count, and the observed depth per attempt |
| `plat_outbox_gate` | Per-tenant gate state: `open` or `closed`, with the timestamp of the last transition |
| `EXECUTION_INGRESS_REFUSED` | Event per refusal with tenant, depth, cap |
| `EXECUTION_OUTBOX_GATE_OPENED` | Event on reopen with the duration the gate was closed |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Depth refresh | Every 250 ms by the drainer; a value older than 5 s closes the gate |
| Middleware overhead | The cap check adds under 1 ms to a request; it reads one cached integer |
| `Retry-After` | 5 s on every refusal |
| Refusal rate escalation | More than 100 refusals per minute for one tenant escalates to Platform Admin |
| Gate closed duration | Closed longer than 300 s escalates: drainer throughput is below the emit rate |
| Step backoff | Governed by the node's retry policy; `OutboxOverflow` does not shorten or extend the configured budget |
| Dead-letter escalation | Every instance failed with `OutboxOverflow` is reported with the depth at each attempt, so the cap and the drainer rate can be reviewed together |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| `429 outbox_at_capacity` | External ingress arrives while depth is at or above the cap | Caller retries after 5 s with the same idempotency key; the key was never consumed |
| `error.OutboxOverflow` | `outbox.emit()` called from a step while depth is at or above the cap | Step transaction rolls back; retry policy backs the step off; drainer catches up |
| `DeadLetteredOnOverflow` | Step retry attempts exhausted while depth stayed at the cap | Instance set to `failed`; DLQ entry retains the depth history; the instance is retried from the pinned definition version after the gate reopens |
| `StaleDepthCounter` | Counter not refreshed for more than 5 s | Gate closes; ingress returns 429; drainer health is escalated |
| `DrainerStalled` | Depth does not fall while the gate is closed for 300 s | Platform Admin paged; the drainer is restarted and the closed duration is recorded |
| `MissingRetryAfter` | A 429 is emitted without the `Retry-After` header | Treated as a defect in the middleware; the header is unconditional |
| `IdempotencyKeyConsumedOnRefusal` | A refused request recorded a key | Treated as a defect: the check is ordered before the Idempotency Store write; the key is released and the ordering is corrected |
| `ErrorSetGap` | A caller of `outbox.emit()` omits `OutboxOverflow` from its error set | Compile error surfaced by the error-set check; the caller declares the variant before release |
| `GateFlapping` | Gate opens and closes within one refresh interval | Indicates the low-water mark equals the cap; hysteresis is restored to 80 per cent |
| `CrossTenantRefusal` | One tenant's depth refuses another tenant's ingress | Gate state keyed per tenant schema; a shared key is a defect and is corrected before release |
