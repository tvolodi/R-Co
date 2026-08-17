# Module: obp-03-outbox-overflow

**Requirement ID:** OBP-03
**Run ID:** WF02-obp-ddl-20260817 (Stage 16)
**Type:** Type E (typed error on internal emit path) — no new schema objects.
**Extends:** OBP-01 (`src/outbox/depth.zig` — the depth cache this reads), OBP-04
(`src/outbox/gate.zig` — the gate state the drainer maintains), `src/effects/queue.zig`
(`insertEffectInTx` — the insert function this wraps), OBS-05 (dead letter queue — the
destination when `OutboxOverflow` exhausts its retry budget), PD-08 (the pinned definition
version used on retry after the gate reopens).
**Authoritative process source:** `docs/processes/system/outbox-backpressure.md`
(`sys-outbox-backpressure`, PW-08) steps 7–11, Business Rules (Internal emit cannot be
refused with a code; `OutboxOverflow` is a typed error; Overflow reuses the existing
failure path; Self-throttling), and Error/Exception Paths (`DeadLetteredOnOverflow`).
**See also (referenced, not implemented here):** OBP-02 (the external counterpart),
OBP-04 (gate state and the hysteresis rule), PD-08 (pinned definition version on retry).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No table/column is added by OBP-03. The `OutboxOverflow` variant in the
   DLQ entry (`obs-05`) is carried as a text field in the existing `plat_dlq` row's
   `reason` or `error_detail` column — no schema change. Event-type registry seeding is
   not required: `OutboxOverflow` does not produce a new `EXECUTION_*` event; it causes a
   step rollback, and the existing dead-letter path's event types cover the dead-letter entry.
2. **Type E — yes.** A typed error variant threaded through the call graph of
   `outbox.emit()` and every Zig caller in the engine. This is the same class of
   "error-set propagation + semantic constraint" work that `iss0206-rowtodefinition-errdefer.md`
   (already in `src/design/`) covers — novel cross-cutting error discipline requiring
   explicit propagation at every call site.

## Existing pattern found and followed

| Aspect | Precedent | OBP-03 (this design) |
|---|---|---|
| Typed error from a transactional insert | `src/effects/queue.zig` `EffectQueueError` — `PersistenceFailed`, `OutOfMemory` — already part of the error set callers declare | Followed: `OutboxOverflow` is added to `EffectQueueError` (the same error union) so all existing callers are affected at compile time, which is the desired compile-time enforcement (OBP-03 AC2) |
| Depth check before DB insert (no extra connection) | `src/api/middleware/outbox_cap.zig` (OBP-02) reads `depth.readCached` before taking a connection | Followed: `emit()` reads `depth.readCached` at the top of its body, before calling `insertEffectInTx`, using the same in-memory cache; no extra connection, no `COUNT(*)` |
| Retry policy and dead-letter path | `src/engine/transition.zig` + `src/dlq/` — existing step failure path that re-arms the node under its retry policy and dead-letters on exhaustion | Followed: `OutboxOverflow` is propagated out of `emit()` → out of the step body → handled identically to any other step error; no new retry mechanism, no new rate limiter (OBP-03 AC3) |
| DLQ entry with failure detail | `src/dlq/` — existing dead-letter queue records `reason`, `attempt_count`, and contextual detail | Extended: the DLQ entry for `OutboxOverflow` carries `OutboxOverflow`, the attempt count, and the depth observed at each attempt (OBP-03 AC5); see "DLQ entry shape" below |

## Module purpose

`src/outbox/emit.zig` (new) is a thin wrapper around `effects/queue.zig::insertEffectInTx`
that adds the capacity pre-check. It is the **only** call site for `insertEffectInTx` within
step-executing code; all BPM engine paths that emit an effect must go through `emit.zig`'s
`emit()` function, not call `insertEffectInTx` directly. (Callers that already use
`insertEffectInTx` outside the step-execution context — e.g. replay utilities — are not
affected by this design.)

`emit()` runs inside the step transaction opened by the engine. If the cached outbox depth is
at or above `BPM_OUTBOX_DEPTH_CAP`, or if the depth cache entry is stale, `emit()` returns
`error.OutboxOverflow` without inserting any row. The calling step body propagates the error
upward; the engine rolls back the step transaction (discarding every write of that step) and
schedules a retry under the node's existing retry policy. When retries are exhausted, the
existing dead-letter path fires, producing a DLQ entry that carries the `OutboxOverflow`
reason and the depths observed at each attempt.

The module does NOT introduce a new retry mechanism: `OutboxOverflow` is just another step
error, and the engine's existing failure path handles it identically to `PersistenceFailed`.
The self-throttling effect (OBP-03 AC4) emerges naturally: the failing step backs off under
the node's own policy, reducing the instance's emit rate until the drainer catches up.

## Public interface

### `src/outbox/emit.zig` — the emit wrapper

```zig
const std = @import("std");
const depth_mod = @import("depth.zig");
const queue = @import("../effects/queue.zig");

/// Emits one outbox effect from within a step transaction. Must be called
/// inside an already-open transaction on `conn` (same contract as
/// insertEffectInTx).
///
/// Checks the in-memory depth cache BEFORE calling insertEffectInTx. If
/// depth is at or above the cap, or if the cache entry is stale, returns
/// error.OutboxOverflow without inserting any row and without touching conn.
/// The caller MUST declare OutboxOverflow in its error set (OBP-03 AC2); a
/// missing declaration is a compile error.
pub fn emit(
    allocator: std.mem.Allocator,
    conn: anytype,
    depth_cache: *const depth_mod.DepthCache,
    cap: u64,
    spec: queue.EffectSpec,
) (queue.EffectQueueError || error{OutboxOverflow})![]const u8;
```

### `src/effects/queue.zig` — error set extension (modification, not new file)

`EffectQueueError` gains `OutboxOverflow`:

```zig
pub const EffectQueueError = error{
    PersistenceFailed,
    OutOfMemory,
    OutboxOverflow,   // NEW (OBP-03): depth at or above cap, or depth cache stale
};
```

Adding `OutboxOverflow` to `EffectQueueError` causes a **compile error at every call site
that does not include `OutboxOverflow` in its own error set** — this is the AC2 enforcement
mechanism. BACKEND-DEV MUST update every call site's declared error set before the build
passes. The list of affected call sites is determined by the Zig compiler; no manual search
is required.

**Why `EffectQueueError` and not a separate error union:**
`queue.zig` callers already handle `EffectQueueError` variants. Adding `OutboxOverflow` to
the existing union is the minimal change that propagates the error to all callers at compile
time without introducing a new union type that requires call-site wrapping.

### DLQ entry shape (extension to existing dead-letter path)

When a step fails with `OutboxOverflow` and exhausts its retry budget, the dead-letter entry
(in `plat_dlq` or equivalent) MUST carry (OBP-03 AC5):
- `reason: "OutboxOverflow"`
- `attempt_count: <n>` (total attempts, 1-based)
- `depth_per_attempt: [<d1>, <d2>, ..., <dn>]` (the depth observed at each attempt,
  captured from `depth_mod.readCached` at the time of the emit call)

The `depth_per_attempt` array is accumulated by the engine's step retry loop. BACKEND-DEV
should extend the retry loop's failure-context struct to carry `Option<[]u64> overflow_depths`.
When `OutboxOverflow` is the failure reason, the current depth is appended. When the DLQ
entry is written, the accumulated array is serialised as JSON and written to the entry's
detail column.

## Data flow diagram

```
  BPM engine step transaction (already open)
             |
             | engine calls outbox.emit(conn, depth_cache, cap, spec)
             ↓
  [emit.zig: depth_mod.readCached(tenant_schema)]  — NO DB access
             |
   stale OR depth >= cap?
             |
         YES |                          NO
             |                          |
             ↓                          ↓
  return error.OutboxOverflow    queue.insertEffectInTx(conn, spec)
             |                          |
             ↑ (propagated up)          ↓
  engine rolls back step txn     effect row inserted, txn continues
  (all step writes discarded)
             |
  engine applies retry policy
  (existing path, OBP-03 AC3)
             |
  retries exhausted?
             |
         YES |
             ↓
  dead-letter entry written:
    reason: OutboxOverflow
    attempt_count: N
    depth_per_attempt: [d1..dN]
  instance transitions to `failed`
```

## Error taxonomy

| Error | Origin | Handling |
|---|---|---|
| `error.OutboxOverflow` | `emit()`: depth >= cap OR depth cache stale | Propagated out of the step body; step transaction rolled back by engine; retry policy applied; dead-lettered on exhaustion |
| `error.PersistenceFailed` | `insertEffectInTx` DB failure (path taken only when depth < cap) | Unchanged behaviour from pre-OBP-03; already in `EffectQueueError` |
| `error.OutOfMemory` | allocator failure inside `insertEffectInTx` | Unchanged behaviour from pre-OBP-03 |
| `ErrorSetGap` (compile-time) | A caller of `emit()` or `insertEffectInTx` does not include `OutboxOverflow` in its error set | Compile error surfaced by Zig's error-set exhaustiveness check; caller MUST add `OutboxOverflow` before the build passes (OBP-03 AC2) |

## State transitions

OBP-03 introduces no new persistent state. The DLQ entry records the overflow history as
described above. The gate state (open/closed) is unchanged by OBP-03; it is owned by OBP-04.

```
Step execution:
  emit() called →
    depth < cap AND not stale → insert → step continues
    depth >= cap OR stale →
      error.OutboxOverflow → step rollback → retry re-arm
        attempts remain → wait backoff → retry
        attempts exhausted → dead-letter → instance failed
```

## Dependencies

Calls:
- `src/outbox/depth.zig` — `readCached` (no I/O, no connection)
- `src/effects/queue.zig` — `insertEffectInTx` (only when depth < cap)

Must NOT call:
- `src/outbox/gate.zig` — `emit()` does not modify the gate state or record refusals; the
  gate is managed by the drainer (which calls `gate.evaluateAndDecide`)
- `db.Pool.acquire()` — `emit()` runs inside the step's already-open transaction; it must
  not acquire a second connection

## Test stub expectations

Integration tests must verify:

1. **TC-OBP-03-AC1:** Given depth cache at cap, a SERVICE_TASK step calling `emit()` returns
   `error.OutboxOverflow`, no row is inserted in `effects_outbox`, and all other writes of
   that step are absent from the DB (rollback confirmed).
2. **TC-OBP-03-AC2-compile:** A call to `emit()` or `insertEffectInTx` that omits
   `OutboxOverflow` from its declared error set must not compile. (Verified by build test;
   not a runtime assertion.)
3. **TC-OBP-03-AC3:** `OutboxOverflow` does not alter the node's retry schedule; backoff
   intervals match those of any other step error under the same retry policy.
4. **TC-OBP-03-AC4:** A step that repeatedly fails with `OutboxOverflow` does not add any
   new row to `effects_outbox` during the retry cycle.
5. **TC-OBP-03-AC5:** When retry attempts are exhausted, the DLQ entry carries `reason =
   "OutboxOverflow"`, `attempt_count = N`, and `depth_per_attempt` length equals `N`.
6. **TC-OBP-03-AC6:** After the gate reopens, a DLQ-retried instance resumes against the
   definition version recorded at instance start (PD-08).

## Open questions

1. **`insertEffectInTx` call sites outside the step-execution context:** Some callers of
   `insertEffectInTx` (e.g. replay utilities, test helpers) may legitimately bypass the
   depth check. BACKEND-DEV should audit call sites after adding `OutboxOverflow` to
   `EffectQueueError` and determine which callers should use `emit()` (with the depth check)
   vs. call `insertEffectInTx` directly (without). The design says "all BPM engine paths that
   emit an effect must go through `emit()`"; other callers are at BACKEND-DEV's discretion.
2. **`depth_per_attempt` accumulation:** The retry loop's failure-context struct does not
   currently carry a `depth_per_attempt` accumulator. BACKEND-DEV must extend it. The exact
   type depends on the engine's internal retry-context representation; see the engine
   module's design doc for the relevant struct.
