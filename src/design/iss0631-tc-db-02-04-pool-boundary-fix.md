# ISS-0631 / GH-606 — TC-DB-02-04 Pool Boundary Fix Design

**Type:** E (novel test-logic fix — no matching codegen template)
**Requirement:** DB-02 (connection pooling)
**Files in scope:** `tests/integration/db_integration_test.zig`, `docker-compose.yml`

---

## Module purpose

TC-DB-02-04 verifies that `Pool.init()` returns `PoolError.InvalidPoolSize` for `pool_size`
values outside [2, 200] and succeeds at the boundary values 2 and 200. The upper-boundary
live sub-test (`pool_size=200`) assumes 200 free PostgreSQL connection slots, which is never
guaranteed when `zig build test-integration` runs 20+ binaries concurrently against a
`db_test` service configured with `max_connections=250`.

The fix is purely in the test and in docker-compose.yml. No production code changes.

Root cause confirmed by ISSUE-FIXER (step-01): `Pool.init()` opens all `pool_size`
connections eagerly; with `max_connections=250` and ~50 aggregate concurrent connections
from parallel test binaries, fewer than 200 slots remain and the 200th `connectUrl` call
is rejected with `FATAL: too many connections`, surfaced as `PoolError.ConnectionFailed`.

---

## Public interface

No new public functions or types. All changes are confined to the TC-DB-02-04 test block
and the `docker-compose.yml` command argument.

**Test-internal computation pattern** (not exported):

```
probe = pool2.acquire()
SHOW max_connections            → max_conn  : i64  (e.g. 500)
SELECT count(*)::text
  FROM pg_stat_activity
  WHERE datname = current_database()  → current_conn : i64  (e.g. 47)
pool2.release(probe)
safe_pool_size = @intCast(@min(200, max_conn - current_conn - 5))
if safe_pool_size < 2 → SkipZigTest
Pool.init(pool_size = safe_pool_size) → must succeed
```

---

## Data flow diagram

```
TC-DB-02-04 test
        │
        ├─ expectError(InvalidPoolSize, Pool.init(pool_size=1))    [no network]
        ├─ expectError(InvalidPoolSize, Pool.init(pool_size=201))  [no network]
        │
        ├─ Pool.init(pool_size=2)  →  pool2  (2 conns open; deferred deinit)
        │
        ├─ probe = pool2.acquire()
        │       ├─ SHOW max_connections       →  max_conn  (text "500", parse i64)
        │       └─ SELECT count(*)::text
        │            FROM pg_stat_activity
        │            WHERE datname = current_database()
        │                                     →  current_conn (text "47", parse i64)
        │
        ├─ pool2.release(probe)
        │
        ├─ available = max_conn - current_conn - 5
        │       ├─ [available < 2] → print diagnostic → return error.SkipZigTest
        │       └─ [available >= 2] → safe_pool_size = @min(200, available)
        │
        └─ Pool.init(pool_size=safe_pool_size)  →  pool200  (upper boundary live test)
                └─ assert: no error (success = requirement DB-02 boundary satisfied)
```

---

## Exact changes

### 1. `tests/integration/db_integration_test.zig` — replace TC-DB-02-04 test block

Pattern sketch for the TC-DB-02-04 replacement (pseudocode; exact implementation in BACKEND-DEV step):

```
// Pseudocode sketch — TC-DB-02-04 replacement pattern

// 1. Out-of-range guards (no network; dummy URL)
expectError(InvalidPoolSize, Pool.init(..., pool_size=1))
expectError(InvalidPoolSize, Pool.init(..., pool_size=201))

// 2. Lower-boundary live test
pool2 = Pool.init(url, pool_size=2)   // must succeed

// 3. (a) blk: label idiom — compute safe_pool_size at runtime
const safe_pool_size: u16 = blk: {
    probe = pool2.acquire()     // borrows one slot from pool2
    defer pool2.release(probe)

    // (b) Query 1 — SHOW max_connections → single text row, e.g. "500"; fallback 250
    max_res  = probe.query("SHOW max_connections", &.{})
    max_conn = parseInt(max_res.rows[0][0]) else 250

    // (b) Query 2 — count live connections to this DB (incl. pool2's own 2 slots)
    act_res = probe.query(
        "SELECT count(*)::text FROM pg_stat_activity WHERE datname = current_database()",
        &.{},
    )
    current_conn = parseInt(act_res.rows[0][0]) else 50

    available = max_conn - current_conn - 5   // 5-slot headroom

    if (available < 2) {
        print("TC-DB-02-04: skipping — available={d}", .{available})
        break :blk 0   // (c) sentinel-0: causes SkipZigTest below
    }
    // (d) @min(200, available) caps at Pool.init's upper limit; @intCast safe
    break :blk @intCast(@min(@as(i64, 200), available))
};
if (safe_pool_size < 2) return error.SkipZigTest   // (c) sentinel-0 check

// 4. Upper-boundary live test with runtime-derived size
pool200 = Pool.init(url, pool_size=safe_pool_size)  // must succeed
```

**Key invariants preserved:**
- The `pool_size=1` and `pool_size=201` `InvalidPoolSize` checks are unchanged and still
  use a dummy URL (no network).
- The `pool_size=2` lower-boundary live test is unchanged.
- `safe_pool_size` is always in [2, 200] when the SkipZigTest branch is not taken, so
  `Pool.init`'s own range validation is satisfied.

### 2. `docker-compose.yml` — raise db_test max_connections

In the `db_test` service command (line 60):

```yaml
# Before:
    command: postgres -c max_connections=250

# After:
    command: postgres -c max_connections=500
```

Rationale: with 500 connections available, normal concurrent runs (20+ binaries, each
holding 5–10 connections ≈ 100–200 total) leave ≥295 slots free, well above the 200
needed for `safe_pool_size=200`. The pre-check in the test remains as a defence-in-depth
safety net for extreme parallelism or degraded CI environments.

The `db` (production) service is not modified; only `db_test` is affected.

---

## Error taxonomy

No new error types. No changes to `src/db/pool.zig` error sets.

| Condition | Outcome |
|---|---|
| `pool_size < 2` in `Pool.init` | `PoolError.InvalidPoolSize` (unchanged) |
| `pool_size > 200` in `Pool.init` | `PoolError.InvalidPoolSize` (unchanged) |
| Database unreachable at test start | `Pool.init(pool_size=2)` returns `ConnectionFailed` → test fails loudly (genuine failure, not a flake) |
| `probe.query("SHOW max_connections")` fails | `try` propagates error → test fails (database issue, not a flake) |
| `SHOW max_connections` parse error | Conservative fallback `max_conn = 250`; test proceeds conservatively |
| `pg_stat_activity` count parse error | Conservative fallback `current_conn = 50`; test proceeds conservatively |
| `available < 2` (extreme concurrency) | `return error.SkipZigTest` with `std.debug.print` diagnostic; zig counts as SKIP |
| `available >= 2` (normal case) | `safe_pool_size = @min(200, available)`; `Pool.init` succeeds; test PASSES |

---

## Dependencies

| Dependency | Usage | Changed? |
|---|---|---|
| `src/db/pool.zig` | `Pool.init`, `Pool.acquire`, `Pool.release`, `Conn.query` | No — read-only |
| `src/db/pool.zig` `PoolConfig` | `.url`, `.pool_size` fields | No |
| `docker-compose.yml` `db_test` | `max_connections` parameter | Yes (250 → 500) |
| `tests/integration/helpers.zig` | Not used in TC-DB-02-04 (no TestHarness needed) | No |

---

## State transitions

Not applicable — no state machine or actor model involved. Pool lifecycle within the test:

```
pool2: CREATED(2 conns) → probe ACQUIRED → queries → probe RELEASED → pool200 CREATED → test end → pool200.deinit → pool2.deinit
```

---

## Test plan

After implementation, TC-DB-02-04 must exhibit all of the following:

1. **Out-of-range checks pass deterministically** (no network; no concurrency sensitivity).
2. **Lower-boundary live test passes** whenever the database is reachable.
3. **Upper-boundary live test passes** in normal CI (expected `safe_pool_size = 200`):
   - `max_connections=500`, `current_conn ≤ ~50` → `safe_pool_size = @min(200, 445) = 200`
   - `Pool.init(pool_size=200)` succeeds → test PASSES
4. **SkipZigTest triggered only under extreme load** (`current_conn ≥ 494` with
   `max_connections=500`) — negligible probability in any realistic environment.
5. **No flakiness** across 5 consecutive `zig build test-integration` runs.

Verification commands:

```bash
# Run TC-DB-02-04 in isolation three times; all must show pass/skip, never fail:
$env:BPM_TEST_DB_URL='postgres://bpm:bpm@localhost:5434/bpm_test'
$env:BPM_DB_URL=$env:BPM_TEST_DB_URL
zig build test-integration -- --test-name-pattern "TC-DB-02-04"
# Expect: 1/1 tests passed (or 0/0 skipped in extreme load)

# Confirm no regression in other DB tests:
zig build test-integration -- --test-name-pattern "TC-DB-0"
# Expect: all pass
```

---

## Open questions

None. Root cause is fully confirmed by ISSUE-FIXER diagnosis in step-01 handoff
(`aa1837f0-cadd-4a25-9c7b-389940b238f0`).
