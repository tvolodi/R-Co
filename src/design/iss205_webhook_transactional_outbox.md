# Module: ISS-205 — Webhook Transactional Outbox (True At-Least-Once)

**Requirement:** ISS-205 · EPIC-2  
**Design date:** 2026-06-11  
**Touchpoints:** `src/webhook/dispatcher.zig`, route handlers, `migrations/` (ISS-106 table)

---

## Module Purpose

Upgrade webhook delivery from at-most-once (post-commit in-process signal) to true
at-least-once by inserting `webhook_deliveries` outbox rows inside the same DB transaction
as the triggering event. A background worker drains pending rows using `FOR UPDATE SKIP LOCKED`,
applying an exponential back-off ladder and pausing subscriptions after exhausted retries.

---

## Error Taxonomy

| Error | HTTP / log | Cause |
|---|---|---|
| `OutboxInsertError.PersistenceFailed` | 500 | INSERT into `webhook_deliveries` failed inside event tx |
| `OutboxInsertError.OutOfMemory` | 500 | Allocator returned `OutOfMemory` |
| `DispatchError.PoolExhausted` | log WARN | Worker could not acquire a pool connection |
| `DispatchError.PersistenceFailed` | log ERR | Worker DB write (status update) failed |
| `DispatchError.RetryStateWriteFailed` | log ERR | Back-off or success row update failed |
| `DispatchError.PauseTransitionFailed` | log ERR | Subscription `PAUSED` update failed |
| `DispatchError.AlertEmitFailed` | log WARN | OBS-06 alert hook call failed |

---

## Background

The prior delivery path triggered HTTP dispatch from a post-commit in-process signal. If the
process died after the commit but before the HTTP call, the webhook was silently dropped
(at-most-once). ISS-205 moves to a true at-least-once model using a transactional outbox:
`webhook_deliveries` rows are inserted IN THE SAME TRANSACTION as the triggering event, so
the delivery row is always present when the event is durable.

The `webhook_deliveries` table was formalised in ISS-106 (migration already applied).

---

## Public interface

```
// Outbox insert — called INSIDE the event-insert transaction in every route handler
pub fn insertWebhookDeliveriesInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,               // already-open transaction connection
    event_type: sub_store.WebhookEventType,
    instance_id: []const u8,
    event_id: []const u8,         // UUID of the just-inserted event row
    trace_id: []const u8,
    payload_json: []const u8,     // serialised envelope body
) OutboxInsertError!u32           // number of deliveries queued

// Worker — called by the background scheduler loop and at startup sweep
pub fn dispatchDueWebhookAttempts(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
) DispatchError!void

// Startup sweep — same as dispatchDueWebhookAttempts but uses SKIP LOCKED
// (already the case in dispatchDueWebhookAttempts; startup calls this too)
pub fn sweepOrphanedDeliveries(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
) DispatchError!void
```

---

## Data types

```
pub const OutboxInsertError = error{
    PersistenceFailed,
    OutOfMemory,
};

// Back-off ladder (attempt index → delay)
// attempt 1 → 5 000 ms
// attempt 2 → 30 000 ms
// attempt 3 → 120 000 ms  (2 min)
// attempt 4 → 600 000 ms  (10 min)
// attempt 5 → 1 800 000 ms (30 min)
// attempt > 5 → pause subscription + emit OBS-06
pub const BACKOFF_MS = [_]u32{ 5_000, 30_000, 120_000, 600_000, 1_800_000 };
pub const MAX_ATTEMPTS: u8 = 5;
```

---

## Key invariants

1. **Outbox insert in the same transaction:** Every route handler that inserts an event MUST
   call `insertWebhookDeliveriesInTx` BEFORE calling `COMMIT` on the same connection. The
   insert uses the same open transaction object. If the outbox insert fails, the whole
   transaction is rolled back — no event is committed without a corresponding delivery row.

2. **Worker uses SKIP LOCKED:** The worker SELECT that claims delivery rows MUST use
   `SELECT ... FOR UPDATE SKIP LOCKED` so that multiple worker instances on different nodes
   never process the same delivery concurrently.

3. **Delivery row schema:** `webhook_deliveries` rows track:
   - `status` ∈ `{pending, failed, success, exhausted}`
   - `attempt_count` — number of attempts made so far
   - `max_attempts` — configurable ceiling (default 5)
   - `next_attempt_at` — absolute timestamp; worker only processes rows where
     `next_attempt_at <= NOW()`
   - `event_id` — FK to `events.id` (provenance)
   - `last_error` — last error string

4. **Back-off ladder:** On each failure the worker updates `next_attempt_at` according to the
   ladder: attempt 1→5s, 2→30s, 3→2m, 4→10m, 5→30m. After the 5th attempt fails, the row is
   marked `exhausted` and the subscription is set to `PAUSED`. The OBS-06 observability event
   is emitted (alert hook call).

5. **Idempotent delivery body:** The payload JSON is constructed at outbox-insert time and
   stored in `webhook_deliveries.payload_json`. All retry attempts use the same stored payload,
   guaranteeing identical HMAC signatures on retries. The receiver can deduplicate using the
   `x-bpm-delivery-id` header.

6. **In-process NOTIFY is latency only:** After the transaction commits, an optional
   `NOTIFY webhook_deliveries_due` may be sent to wake a sleeping worker early. If the
   notification is lost or never sent, the periodic poll sweep (every configurable interval)
   and the startup sweep MUST drain all pending rows. Neither the correctness of delivery nor
   the at-least-once guarantee depends on NOTIFY.

7. **Startup sweep:** On process startup, call `sweepOrphanedDeliveries` once before entering
   the poll loop. This drains any rows left `pending` from a prior crashed process. The startup
   sweep uses the same `FOR UPDATE SKIP LOCKED` query.

8. **Security:** All SQL values bound as `$N` positional parameters. No string interpolation
   of user data.

---

## Algorithm — outbox insert (`insertWebhookDeliveriesInTx`)

1. Query matching active subscriptions (same WHERE clause as the existing `enqueueDeliveryAttempts`):
   `SELECT id::text FROM webhook_subscriptions WHERE status='ACTIVE' AND is_active=true
    AND (event_types IS NULL OR ... OR $1=ANY(event_types))`.
2. For each matching subscription, INSERT a `webhook_deliveries` row:
   ```
   INSERT INTO webhook_deliveries
     (subscription_id, event_id, status, attempt_count, max_attempts,
      next_attempt_at, event_type, instance_id, payload_json, trace_id, created_at, updated_at)
   VALUES
     ($1::uuid, $2::uuid, 'pending', 0, 5,
      NOW() + '5 seconds'::interval,
      $3, NULLIF($4,'')::uuid, $5::jsonb, $6, NOW(), NOW())
   ```
   This INSERT is on the SAME `conn` that has the event insert open.
3. Return the count of rows inserted.

---

## Algorithm — worker dispatch (`dispatchDueWebhookAttempts`)

1. Acquire connection from pool. BEGIN.
2. ```
   SELECT d.id::text, d.subscription_id::text, d.payload_json::text,
          d.trace_id, d.event_type, d.attempt_count::text, d.max_attempts::text,
          s.url, COALESCE(s.secret,'')
   FROM webhook_deliveries d
   JOIN webhook_subscriptions s ON s.id = d.subscription_id
   WHERE d.status IN ('pending','failed')
     AND d.next_attempt_at <= NOW()
     AND s.status = 'ACTIVE'
   ORDER BY d.next_attempt_at ASC
   LIMIT 50
   FOR UPDATE OF d SKIP LOCKED
   ```
3. For each claimed row call `dispatchOne` (existing logic).
4. COMMIT.

---

## Algorithm — `dispatchOne` (failure path changes)

On failure of the HTTP call:

- Compute `next_attempt: u8 = prev_attempt + 1`.
- Look up `BACKOFF_MS[next_attempt - 1]` (clamped to array length).
- If `next_attempt < MAX_ATTEMPTS`:
  - UPDATE delivery: `status='failed'`, `attempt_count=$next_attempt`,
    `next_attempt_at=NOW() + ($delay_ms || ' milliseconds')::interval`.
  - UPDATE subscription: `consecutive_failures = consecutive_failures + 1`.
- If `next_attempt >= MAX_ATTEMPTS`:
  - UPDATE delivery: `status='exhausted'`, `attempt_count=$next_attempt`.
  - UPDATE subscription: `status='PAUSED'`, `paused_at=NOW()`, `consecutive_failures=consecutive_failures+1`.
  - After COMMIT: call `emitWebhookSubscriptionPausedAlert` (OBS-06).

---

## Route handler integration

Every route handler that currently calls `enqueueDeliveryAttempts` (or post-commit dispatch)
MUST instead call `insertWebhookDeliveriesInTx` INSIDE the event-insert transaction.
Specifically:

- `src/api/routes/instances.zig` — on successful `startInstance` or `cancelInstance`
- `src/api/routes/tasks.zig` — on successful `completeTask`
- Any other handler that appends to the `events` table

The old `enqueueDeliveryAttempts` (which opens its own connection) is retained for backward
compatibility but should no longer be the primary path.

---

## External dependencies

- `webhook_deliveries` table (migration from ISS-106) — `(id, subscription_id, event_id, status, attempt_count, max_attempts, next_attempt_at, event_type, instance_id, payload_json, trace_id, last_error, created_at, updated_at)`
- `webhook_subscriptions` table — reads `status`, `is_active`, `event_types`, `url`, `secret`
- `events` table — outbox insert runs in the same transaction
- OBS-06 alert hook — called after subscription pause

---

## Open questions

- None. All edge cases covered by the ISS-205 acceptance criteria.
