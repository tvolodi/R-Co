# Module: obp-01-outbox-depth-cap

**Requirement ID:** OBP-01
**Run ID:** WF02-obp-ddl-20260817 (Stage 16)
**Type:** Type E (in-memory depth cache + drainer wiring) + Type C (add `depth_refreshed_at`
column to `plat_outbox_gate` for observability and restart recovery)
**Extends:** OBP-04 (`src/outbox/gate.zig`, already RELEASED) — OBP-04 owns the gate state
machine and the hysteresis rule; OBP-01 owns the **cached depth counter** that the gate and
the middleware consume. OBP-04's `evaluateAndDecide` already takes `depth: u64` as a caller-
supplied parameter; this design fills in the module responsible for providing that value.
**See also (referenced, not implemented here):** OBP-02 (the ingress refusal middleware that
reads the depth cache without a DB connection), OBP-03 (the `outbox.emit()` wrapper that reads
the same cache inside a step transaction), `docs/processes/system/outbox-backpressure.md`
(`sys-outbox-backpressure`, PW-08) steps 1–2 and the SLAs table.

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C — yes, for the schema.** OBP-01 AC3 requires the staleness check ("a cached value
   older than 5 s SHALL be treated as at-cap"). `plat_outbox_gate` (the OBP-04 table) stores
   `depth` and `updated_at`, but `updated_at` is advanced on every write to the row including
   gate state transitions (open ↔ closed). A distinct `depth_refreshed_at` column is required
   so the middleware can check depth staleness without mistaking a gate state transition for a
   depth refresh. One Type C migration YAML is produced alongside this document:
   `templates/specs/obp-01-plat-outbox-gate-depth-ts.migration.yaml`.
2. **Type E — yes, for the cache logic.** The in-memory per-tenant depth cache (required by
   OBP-02's constraint that refused requests must not take a pool connection — see
   `outbox-backpressure.md` step 4 and OBP-02 AC3), the 250 ms drainer refresh wiring, and
   the staleness evaluation are genuinely novel coordination logic with no template shape.
   The precedent is `src/ordering/observability.zig` (per-tenant `std.atomic.Value` counters
   for the ordering family).

So this batch produces: **1 Type C migration YAML + 1 Type E design document** (this file).

## Existing pattern found and followed

| Aspect | Precedent | OBP-01 (this design) |
|---|---|---|
| Per-tenant atomic counters | `src/ordering/observability.zig` — `std.atomic.Value(u64)` counters behind a `std.HashMap` for the ordering family | Followed for the per-tenant `{depth, refreshed_at_ms}` atomic pair |
| Drainer poll loop | `src/effects/worker.zig` `sweepOnce` — each sweep executes a batch and returns before sleeping | Followed: depth refresh is appended at the END of each `sweepOnce` call so depth reflects published rows, not pending rows yet to be published |
| In-process config from environment | `src/outbox/gate.zig` `OutboxGateConfig` — env-sourced cap/low-water at startup, never re-read | Followed: `BPM_OUTBOX_DEPTH_CAP` is read into `OutboxGateConfig.depth_cap` at startup and passed into the cache; no per-request env read |
| `plat_` table augmentation | `1164_obp04_plat_outbox_gate.sql` — codegen YAML → migration, add columns with CHECK constraints | Followed for `depth_refreshed_at`: one column added via the Type C YAML codegen path |

**Deliberately NOT introduced:** an extra DB SELECT on the request path. OBP-02 AC3 requires no
pool connection to be taken on a refused request. Therefore the depth check on the request path
reads ONLY the in-memory cache. The DB record (`plat_outbox_gate.depth` + `depth_refreshed_at`)
is updated by the drainer and is used for observability, the OBP-04 gate state machine, and
restart recovery — not for the per-request check.

## Module purpose

`src/outbox/depth.zig` (new) owns the per-tenant in-memory depth cache that OBP-02's middleware
and OBP-03's `outbox.emit()` read without taking a pool connection. The drainer writes to this
cache at the end of every 250 ms sweep; the cache entry carries both the depth and the
millisecond-precision timestamp of the last write. A read that finds the last write older than
`stale_depth_timeout_ms` (default 5 000 ms) returns `is_stale = true`, so the gate closes
without polling the database.

The module is a thin coordination layer: it does NOT count outbox rows (that is the drainer's
job), does NOT decide to open or close the gate (that is `gate.zig`'s job), and does NOT refuse
requests (that is the middleware's job). It only provides a lockless read of the most recently
published depth value.

## Public interface

### `src/outbox/depth.zig` — in-memory depth cache

```zig
const std = @import("std");

/// One per-tenant depth entry. The two atomics are written together by a
/// single call to `writeFresh()`; readers may observe a stale refreshed_at_ms
/// relative to depth, but never an intermediate state where depth is from
/// one cycle and refreshed_at_ms is from a different one, because writeFresh
/// serialises on a per-tenant mutex before updating both atomics.
pub const DepthEntry = struct {
    depth: std.atomic.Value(u64),
    refreshed_at_ms: std.atomic.Value(i64),
    /// per-entry mutex guards the two-field write in writeFresh so readers
    /// never see a torn update (depth written, refreshed_at not yet written).
    mu: std.Thread.Mutex,
};

/// A read result from the cache.
pub const CachedDepth = struct {
    depth: u64,
    /// True when the last write was more than `stale_depth_timeout_ms` ago.
    /// A stale read SHALL be treated as at-cap by both OBP-02 and OBP-03.
    is_stale: bool,
};

pub const DepthCacheError = error{
    OutOfMemory,
};
```

```zig
/// Global per-tenant depth cache. Callers initialise exactly one instance at
/// startup (inside the server's allocator lifetime) and share a pointer to it.
/// All functions are safe to call from multiple threads without external
/// synchronisation.
pub const DepthCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(*DepthEntry),
    map_mu: std.Thread.RwLock,  // guards entries HashMap mutations
    stale_timeout_ms: i64,      // default 5_000 (OBP-01 AC3)

    pub fn init(allocator: std.mem.Allocator, stale_timeout_ms: i64) DepthCache;

    pub fn deinit(self: *DepthCache) void;
};
```

```zig
/// Write a freshly-counted depth for one tenant. Called by the drainer after
/// each sweep completes. Also updates plat_outbox_gate.depth_refreshed_at via
/// `conn` so the DB record reflects the same refresh (for observability and
/// recovery after restart). The DB write is fire-and-forget: if it fails the
/// in-memory cache is still updated and the caller receives no error.
pub fn writeFresh(
    cache: *DepthCache,
    conn: anytype,
    tenant_schema: []const u8,
    depth: u64,
) DepthCacheError!void;

/// Read the cached depth for one tenant. Lockless on the hot path. Returns
/// `is_stale = true` if the last writeFresh call for this tenant was more
/// than `stale_timeout_ms` ago or if no entry exists (drainer has never run).
/// No allocator, no DB access, safe to call from the request path before
/// taking a pool connection.
pub fn readCached(
    cache: *const DepthCache,
    tenant_schema: []const u8,
) CachedDepth;
```

### `src/effects/worker.zig` — drainer wiring (modification, not new file)

The `sweepOnce` function gains a call to `writeFresh` at the end of its publish-and-delete
cycle, after computing `rows_published` and before sleeping. Signature of the wired call site:

```zig
// Pseudocode for the drainer wiring (inside sweepOnce, after delete):
const pending_depth = countPending(conn, tenant_schema);    // new helper, SELECT COUNT(*)
try depth.writeFresh(depth_cache, conn, tenant_schema, pending_depth);
try gate.evaluateAndDecide(allocator, conn, tenant_schema, pending_depth, gate_config);
```

`countPending` is a new private helper inside `worker.zig`:

```zig
fn countPending(conn: anytype, tenant_schema: []const u8) u64;
// SELECT COUNT(*) FROM effects_outbox WHERE tenant_schema = $1 AND status = 'pending'
```

This is the ONLY call site that may issue `COUNT(*)` on the outbox table. No other path
may do so (OBP-01 AC2).

### `.env.example` additions (OBP-01 AC5)

Two new entries in `.env.example`:

```
# Outbox depth cap — maximum pending effects_outbox rows before ingress is refused (OBP-02) or
# outbox.emit() returns OutboxOverflow (OBP-03). Default: 50000. An empty value is treated as
# the default (the cap is never derived from disk, memory, or observed throughput — OBP-01).
BPM_OUTBOX_DEPTH_CAP=50000

# Outbox low-water mark — the gate reopens only when depth falls here (80% of the cap, default
# 40000). If empty or unset, derived from BPM_OUTBOX_DEPTH_CAP * 0.8, floor division.
# NEVER set equal to BPM_OUTBOX_DEPTH_CAP; that disables hysteresis (OBP-04 AC3, GateFlapping).
BPM_OUTBOX_LOW_WATER=40000
```

## Data flow diagram

```
  effects_outbox table          plat_outbox_gate (DB)
  (per-tenant, status=pending)        |
             |                        |
             | COUNT(*) every 250ms   | depth / depth_refreshed_at (persisted)
             ↓                        ↑
   [drainer: sweepOnce]  → depth.writeFresh() → gate.evaluateAndDecide()
             |                        |
             | depth+refreshed_at_ms  |
             ↓                        |
   [DepthCache in-memory] ← (update)  |
             |
             | readCached() — NO DB connection
             ↓
   [OBP-02 middleware / OBP-03 outbox.emit()]
```

## Error taxonomy

| Error | Origin | Handling |
|---|---|---|
| `DepthCacheError.OutOfMemory` | `writeFresh` allocating a new `DepthEntry` for a first-seen tenant | Propagated to the drainer's sweep loop; the sweep is retried on the next 250 ms cycle; the existing cache entry (if any) remains valid |
| Stale read (`is_stale = true`) | `readCached` finding `refreshed_at_ms` older than `stale_timeout_ms` | Treated as `depth = cap` by OBP-02 and OBP-03; the caller MAY log `StaleDepthCounter` but does not propagate an error — the gate closes silently (fail-closed) |
| DB write failure in `writeFresh` | `UPDATE plat_outbox_gate ... depth_refreshed_at` fails | Ignored; the in-memory cache is still updated; the DB record recovers on the next successful drainer sweep |

## State transitions

```
DepthEntry lifecycle per tenant:

  (absent) — first writeFresh() → entry created, depth=N, refreshed_at=now
       |
       | writeFresh() every ~250ms
       ↓
  (fresh: age < 5s) — readCached() returns {depth=N, is_stale=false}
       |
       | drainer stops / fails
       ↓
  (stale: age ≥ 5s) — readCached() returns {depth=cap, is_stale=true}
       |
       | drainer resumes, writeFresh() called
       ↓
  (fresh: age < 5s)
```

## Dependencies

Calls:
- `src/outbox/gate.zig` — `evaluateAndDecide` (wired from the drainer, not from this module)
- `plat_outbox_gate` table — write-only from this module (the `depth_refreshed_at` update)

Must NOT depend on:
- `src/api/` — no HTTP handler imports
- `src/engine/transition.zig` — no engine coupling
- `std.time` on the read path (refreshed_at_ms is a stored integer, not re-read from the clock
  on every `readCached` call; clock is read once inside `writeFresh` via the Postgres server
  clock for the DB write, and once from `std.time.milliTimestamp()` for the in-memory timestamp)

## Test stub expectations

Integration tests must verify:

1. **TC-OBP-01-AC1:** After the drainer completes a publish cycle, `readCached(tenant)` returns
   a non-stale entry with `depth` equal to the actual count of `status='pending'` rows.
2. **TC-OBP-01-AC2:** A read via `readCached` is not preceded by any `COUNT(*)` query on
   `effects_outbox` (verifiable by query-log inspection in the test DB).
3. **TC-OBP-01-AC3:** Given the drainer is paused for 6 000 ms, `readCached` returns
   `is_stale = true`.
4. **TC-OBP-01-AC4:** Given two tenants A and B, writing `writeFresh(A, depth=49999)` does NOT
   change `readCached(B)`.

## Migration SQL (Type C context)

The `depth_refreshed_at` column is added via a Type C YAML (see
`templates/specs/obp-01-plat-outbox-gate-depth-ts.migration.yaml`). The generated SQL is:

```sql
-- Adds depth_refreshed_at to plat_outbox_gate (OBP-01 AC3: staleness tracking).
-- NOT NULL with a default so the existing OBP-04 row is not orphaned.
ALTER TABLE plat_outbox_gate
    ADD COLUMN IF NOT EXISTS depth_refreshed_at timestamptz NOT NULL DEFAULT now();
```

No index is needed: this column is written once per 250 ms drainer cycle and read once per
request; it is never used in a range scan.

## Open questions

1. **`effects_outbox` vs `plat_outbox`:** OBP-01's body uses `plat_outbox` as the table name.
   The codebase uses `effects_outbox`. This design assumes they are the same table. If a rename
   or alias is intended, REQ-ANALYST should clarify before BACKEND-DEV implements `countPending`.
2. **Per-tenant schema vs shared-schema outbox:** `effects_outbox` currently lives in a
   single (public or platform) schema and uses a `tenant_schema` FK column. The per-tenant
   keying in `countPending` is `WHERE tenant_schema = $1`. If the table is partitioned per
   tenant schema, the query may need schema-qualified table names. REQ-ANALYST / BACKEND-DEV
   should confirm the schema layout before implementing `countPending`.

## Resolved Open Questions

1. **`effects_outbox` vs `plat_outbox` naming convention** — The codebase uses
   `effects_outbox` (the table defined in `src/effects/queue.zig` and consumed by the drainer).
   The term `plat_outbox` does not appear in the codebase; any references in OBP-01's
   requirement body used a deprecated working name. This design uses `effects_outbox`
   throughout. No rename is intended or required.
   **Decision: closed — `effects_outbox` is the authoritative table name; BACKEND-DEV
   implements `countPending` against `effects_outbox` without further REQ-ANALYST input.**

2. **Per-tenant schema vs shared-schema outbox** — `effects_outbox` lives in the shared
   (public/platform) schema with a `tenant_schema` FK column, matching the layout confirmed
   by `1164_obp04_plat_outbox_gate.sql` which also keys by `tenant_schema`. The query
   `WHERE tenant_schema = $1` is correct as written; no schema-qualification of the table
   name is required.
   **Decision: closed — shared schema with `tenant_schema` column; `countPending` query
   is correct without modification.**
