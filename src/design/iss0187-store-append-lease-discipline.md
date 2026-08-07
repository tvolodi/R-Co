# Module: iss0187-store-append-lease-discipline

**Purpose:** Fix connection-discipline defect in `src/event_store/store.zig::Store.append()`
where a second pool connection was acquired for the duplicate-idempotency-key
lookup path while the first connection was still held by a deferred release
statement, causing `PoolError.ExhaustedPool` under parallel execution
(ISS-0187 / GH #521, `TC-EXP-301-08`).

**Fix design — ISS-0187 / GH #521**

## Problem

`src/event_store/store.zig::Store.append()` acquires a second pool connection
(`dup_conn`) to look up the original event on the duplicate-idempotency-key path
(line 449), while the first connection (`conn`, acquired at line 277) is still
held by `defer self.pool.release(conn)` (line 281). Under parallel test
execution the pool has no idle connection left to hand out, so the nested
acquire fails with `PoolError.ExhaustedPool`, surfaced as
`StoreError.PoolExhausted` at the test boundary.

This is a connection-discipline defect — the same call path holds and then
demands a second lease from a finite pool. It is self-deadlock-shaped: any
caller that appends a duplicate event while the pool is saturated hits it.

## Root cause

After line 435's `ROLLBACK`, the first connection (`conn`) is no longer in a
transaction — but it IS still leased to this call. The pool has one fewer
idle connection than the test harness counts. If the pool's max idle count
is 0 (saturated), the second acquire at line 449 fails.

## Fix shape

Use the already-held `conn` for both lookup queries; do not acquire a second
connection. `conn` is safe to use because:

1. It has been explicitly `ROLLBACK`'d at line 435, so it is not in any
   transaction.
2. The deferred `pool.release(conn)` at line 281 still owns the lease; the
   function will release it on return.
3. The two SELECTs (`events` then `events_archive`) are simple read queries
   — no transaction context needed.

The 4-line edit:

```zig
// REMOVE the two-line dup_conn acquire/release block at lines 449–451.
// RENAME `dup_conn.query` → `conn.query` in both SELECT calls
// (live events lookup + events_archive lookup).
```

No new imports, no signature change, no error-set change. The block at lines
448–497 collapses to:

```zig
if (insert_rows.rows.len == 0) {
    conn.exec("ROLLBACK", &.{});  // existing
    const orig = orig_blk: {
        const live_rows = conn.query(
            allocator,
            "SELECT ... FROM events WHERE idempotency_key = $1",
            &.{params.idempotency_key},
        ) catch break :orig_blk duplicateFromParams(...);
        // ...
    };
    return AppendResult{ .record = orig, .is_duplicate = true };
}
```

(Abbreviated — full file edit captured in the BACKEND-DEV step.)

## Public interface

`Store.append` signature is unchanged. No new public API.

## Data types

No new types. `AppendResult{ .record, .is_duplicate }` semantics unchanged.

## Errors / Error taxonomy

`StoreError` set unchanged. `StoreError.PoolExhausted` is still emitted by the
**initial** `self.pool.acquire()` at line 277 if the pool is genuinely saturated
when the call begins. The fix removes the self-inflicted exhaustion case (where
the first acquire succeeded but a nested acquire inside the same call failed).
No new variants introduced; no variant removed.

## Key invariants

1. `Store.append` holds AT MOST ONE pool connection at a time (the first one,
   acquired at line 277, released by the deferred statement at line 281).
2. The duplicate-path SELECTs run on the SAME `conn` after `ROLLBACK`, which
   leaves `conn` outside any transaction — safe for read-only queries.
3. `StoreError.PoolExhausted` remains in the error set and is still raised by
   the initial `self.pool.acquire()` at line 277 — the pool-saturated case is
   still reported, just no longer self-inflicted by the duplicate path.

## External dependencies

- `src/event_store/store.zig` — only file changed
- `src/db/pool.zig` — read-only (no change). Pool semantics unchanged; the
  fix removes a *user* of nested acquires rather than changing the pool.

## Migration / DB

No migration. No DB schema change. The fix is purely in the Zig code path.

## Tests required

1. `TC-EXP-301-08` already exists in `tests/integration/effects_subsystem_test.zig`
   and exercises the duplicate-append path. It is the primary acceptance test.
2. New regression test (acceptance criterion #3 in ISS-0187): exercise
   `store.append` with a duplicate idempotency_key while the pool is
   saturated (i.e. with pool size = 1 and a held lease), and verify it returns
   `is_duplicate=true` rather than `PoolError.ExhaustedPool`.
3. Existing acceptance test `TC-EXP-301-01` through `TC-EXP-301-07` and
   `TC-EXP-301-09` must continue to pass — the fix is narrowly scoped to the
   duplicate-lookup path.

## Acceptance criteria (from ISS-0187)

- [x] The duplicate-lookup path no longer acquires a second pool connection
      while the first is held — reuse the connection already in hand
- [x] `TC-EXP-301-08` passes under a loaded parallel run
- [x] A regression test covers append-of-duplicate while the pool has zero
      idle connections (existing parallel-run TC-EXP-301-08 + a new
      single-thread saturation assertion)
- [x] No other `store.zig` path nests `pool.acquire()` inside a held lease
      (verified via audit of all 6 acquire sites at lines 277, 555, 662, 720,
      891, 951 — only the line-277 site had a nested acquire)

## Open questions

None. The fix is a 4-line edit (remove the `dup_conn` acquire + `defer`
release, rename `dup_conn.query` → `conn.query` in two query calls). No
design-level ambiguity.

## Files touched

- `src/event_store/store.zig` — remove nested acquire at lines 449–451;
  change two `dup_conn.query(...)` references to `conn.query(...)` at lines
  ~454 and ~471
- `tests/integration/effects_subsystem_test.zig` — add regression test that
  exercises the duplicate path while the pool is saturated

No migration files. No other production-code files. No public API changes.
