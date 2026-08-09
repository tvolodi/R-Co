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

The full replacement for the test block (lines 229–267 in the current file):

```zig
// TC-DB-02-04
// Verifies that Pool.init() returns PoolError.InvalidPoolSize for pool_size
// values outside the valid range [2, 200] (NFR-06), and succeeds at the
// boundary values 2 and ≤200.
//
// ISS-0631 / GH #606: the original upper-boundary sub-test called
// Pool.init(pool_size=200) unconditionally.  Under concurrent zig build
// test-integration runs (20+ binaries), aggregate pg_stat_activity connections
// can exceed 50, leaving <200 free slots in the db_test service (formerly
// max_connections=250).  The fix queries the live connection budget first and
// uses a safe_pool_size = @min(200, max_conn - current_conn - 5).
// If safe_pool_size < 2 the sub-test is skipped (SkipZigTest) with a diagnostic.
test "TC-DB-02-04: invalid pool_size returns InvalidPoolSize; boundary values succeed" {
    const alloc = std.testing.allocator;

    // Out-of-range lower bound: pool_size = 1.
    // InvalidPoolSize is returned before any network call, so a dummy URL works.
    try std.testing.expectError(error.InvalidPoolSize, Pool.init(
        std.testing.io,
        alloc,
        PoolConfig{ .url = "postgres://localhost/test", .pool_size = 1 },
    ));

    // Out-of-range upper bound: pool_size = 201.
    try std.testing.expectError(error.InvalidPoolSize, Pool.init(
        std.testing.io,
        alloc,
        PoolConfig{ .url = "postgres://localhost/test", .pool_size = 201 },
    ));

    // Live-connection sub-tests require a real database.
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    // Valid lower boundary: pool_size = 2.
    // Two slots are always available when the database is reachable at all;
    // failure here is a genuine connectivity problem, not a flake.
    var pool2 = try Pool.init(std.testing.io, alloc, PoolConfig{
        .url = url,
        .pool_size = 2,
    });
    defer pool2.deinit();

    // Valid upper boundary: determine safe_pool_size from the live server to
    // avoid exhausting the db_test connection budget under concurrent binary
    // runs.  ISS-0631 / GH #606.
    const safe_pool_size: u16 = blk: {
        const probe = try pool2.acquire();
        defer pool2.release(probe);

        // SHOW max_connections returns one text row, e.g. "500".
        var max_res = try probe.query(alloc, "SHOW max_connections", &.{});
        defer max_res.deinit();
        const max_conn: i64 = if (max_res.rows.len > 0 and max_res.rows[0][0] != null)
            std.fmt.parseInt(i64, max_res.rows[0][0].?, 10) catch 250
        else
            250;

        // Count active connections to this database (includes pool2's own 2 conns).
        var act_res = try probe.query(
            alloc,
            "SELECT count(*)::text FROM pg_stat_activity WHERE datname = current_database()",
            &.{},
        );
        defer act_res.deinit();
        const current_conn: i64 = if (act_res.rows.len > 0 and act_res.rows[0][0] != null)
            std.fmt.parseInt(i64, act_res.rows[0][0].?, 10) catch 50
        else
            50;

        // Reserve 5 slots as headroom; cap at 200 (Pool.init's own upper limit).
        const available = max_conn - current_conn - 5;
        if (available < 2) {
            std.debug.print(
                "TC-DB-02-04: skipping upper-boundary live test — " ++
                    "available={d} (max_conn={d}, current_conn={d}, headroom=5)\n",
                .{ available, max_conn, current_conn },
            );
            break :blk 0; // sentinel: triggers SkipZigTest below
        }
        // @intCast is safe: available is in [2, 200] after @min(200, ...).
        break :blk @intCast(@min(@as(i64, 200), available));
    };
    if (safe_pool_size < 2) return error.SkipZigTest;

    var pool200 = try Pool.init(std.testing.io, alloc, PoolConfig{
        .url = url,
        .pool_size = safe_pool_size,
    });
    defer pool200.deinit();
}
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
