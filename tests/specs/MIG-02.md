# Test Spec: MIG-02 — Control row commits with the DDL

**Requirement:** MIG-02 — The platform SHALL upsert a tenant's `platform.platform_migrations`
row to `done` inside the same transaction that applies that tenant's DDL steps, so a `done`
row proves the DDL committed. A per-tenant failure is recorded as `status = 'failed'` with
`error_msg` in a separate transaction opened after the tenant transaction has rolled back.

**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `bpm.pool.Pool` and `runFanout`, no mocks)
**Test-tier score (test_developer_guide.md §2.1):** Tenant isolation (2, per-tenant control
row) + transactional boundary (1, commit-with-DDL is the entire point of this requirement) =
**3 points → sandbox tier** per the rubric. No Wasm surface exists in this requirement; unit
+ integration is what the requirement's actual content needs and is what is provided below —
consistent with MIG-01's spec header, which notes the same "table has no sandbox-layer
content to test" reasoning.
**Design:** `src/design/mig-02-mig-03-platform-migration-fanout.md`
**Implementation:** `src/platform/migration_fanout.zig` (`applyToTenant`, `markDone`,
`recordFailureSeparately`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a tenant's DDL commits, WHEN the transaction ends, THEN the `done` row committed in that same transaction. | `TC-MIG-02-01` |
| AC2 | GIVEN a DDL statement raises, WHEN the transaction ends, THEN it rolls back and neither partial DDL nor a `done` row survives in that schema. | `TC-MIG-02-02/03` |
| AC3 | GIVEN the tenant transaction rolled back, WHEN the failure is recorded, THEN `status = 'failed'` and `error_msg` are written in their own transaction. | `TC-MIG-02-02/03` |
| AC4 | GIVEN the failure-recording transaction itself fails, WHEN the fanout continues, THEN the row remains `pending` and the MIG-04 resume query covers it. | `TC-MIG-02-04` |
| AC5 | No code path writes a tenant's control row on a connection other than the one applying that tenant's DDL. | Verified structurally (see Structural verification note below) — not a runtime-observable behavior a test can assert on directly |

---

## Coverage note: AC4 (failure-recording transaction itself fails)

AC4 describes a **double-failure** scenario: the tenant's DDL transaction has already rolled
back (a normal MIG-02 AC2/AC3 failure), and THEN the *separate* failure-recording transaction
(`recordFailureSeparately` in `src/platform/migration_fanout.zig`) also fails. This is closed
by `TC-MIG-02-04`, using a genuine, non-mock fault-injection technique that requires no
change to `src/db/pool.zig` or `src/platform/migration_fanout.zig`: `Pool.init()` already
takes a real `PoolConfig.pool_size` parameter (minimum 2 — `pool.zig`'s
`config.pool_size < 2 ... return PoolError.InvalidPoolSize`), and building a **dedicated**
`Pool` with `pool_size = 2` for this one test creates genuine resource exhaustion at exactly
the failure-recording step, with no mock, stub, or fault-injection hook added anywhere
(DIRECTIVE T-1 compliant).

**Mechanism.** With `pool_size = 2` and a single fixture tenant driven through `failingStep`:
1. `runFanout` acquires `lock_conn` for the advisory lock and holds it for the entire run
   (1 of 2 connections in use).
2. `applyToTenant` acquires a second connection for this tenant's DDL transaction (2 of 2 —
   the pool now has 0 idle connections).
3. `failingStep` raises `SimulatedDdlFailure`; `applyToTenant` rolls back the DDL transaction
   on its own connection and calls `recordFailureSeparately` — but `applyToTenant`'s
   `defer pool.release(conn)` has not fired yet (it only fires when `applyToTenant` itself
   returns, which is *after* `recordFailureSeparately` returns). So when
   `recordFailureSeparately` calls `pool.acquire()` for its own fresh connection, the pool
   genuinely has 0 idle connections and returns `PoolError.ExhaustedPool` — a real error from
   real resource exhaustion — exercising `logSwallowedFailure`'s
   `"migration_fanout.failure_record_acquire_failed"` component exactly.

Note this means holding both connections *externally, before* calling `runFanout` is the
wrong construction: it would instead starve `runFanout`'s own *first* acquire (the
advisory-lock connection at the top of `runFanout`), short-circuiting with
`FanoutError.PoolExhausted` before `applyToTenant`/`recordFailureSeparately` are ever reached
— a different error path than AC4 describes. The test instead uses `runFanout`'s own natural,
real, in-flight connection accounting to exhaust a 2-connection pool at exactly the right
moment.

**Isolation.** `TC-MIG-02-04` builds its own dedicated `pool_size = 2` `Pool`, entirely
separate from the shared `pool_size = 5` pool `makePool` gives every other test in this file
— it can never starve, and is never starved by, the other 8 tests' connection usage.

**What is asserted.** `logSwallowedFailure`'s own log line is not observable from within a
test: `src/obs/logger.zig`'s `logWithTrace` short-circuits with `if (builtin.is_test) return;`
before ever writing a line, so there is no way to capture its output without adding a
test-only hook to the logger itself (out of scope, and its own violation of not modifying
production code just to make a gap observable). Per AC4's own wording — "the row remains
pending and the MIG-04 resume query covers it" — the row's final state is what AC4 actually
requires, and that IS directly observable: `TC-MIG-02-04` fetches the control row by its
exact `(migration_id, tenant_id)` key immediately after `runFanout` returns and asserts
`status = 'pending'`, `error_msg IS NULL`, `completed_at IS NULL` — proving
`recordFailureSeparately`'s own `pool.acquire()` failure left the row exactly where the seed
step put it, with `runFanout` returning normally (no panic, no crash, no escalation into a
`FanoutError`). This row-state assertion is sufficient runtime evidence for AC4 as written;
the log line itself is not part of AC4's observable contract.

Fail-first verified: temporarily changing this test's dedicated pool from `pool_size = 2` to
`pool_size = 5` (removing the exhaustion) makes `recordFailureSeparately` succeed normally,
and the row correctly becomes `status = 'failed'` instead of `'pending'` — the test's
`expectEqualStrings("pending", ...)` then fails as expected, confirming the assertion
genuinely discriminates the AC4 double-failure path from ordinary single-failure recording
rather than passing vacuously.

## Structural verification note: AC5 (no cross-connection control-row writes)

AC5 ("No code path writes a tenant's control row on a connection other than the one applying
that tenant's DDL") is a **structural invariant about the source code**, not a runtime
behavior distinguishable by any external observation — both a compliant and a
hypothetically non-compliant implementation could produce identical `done`/`failed` rows
from a test's point of view, since the row's *content* does not reveal which connection
wrote it. Verified instead by direct code inspection of every control-row write site in
`src/platform/migration_fanout.zig`:
- `markDone` (called from `applyToTenant`'s success path) takes `conn: *Conn` as a parameter
  and is called with the exact same `conn` that `step(conn, schema_name)` just ran on —
  no second connection is acquired for this write.
- `recordFailureSeparately` acquires its OWN connection (`pool.acquire()`) — but this is
  correct per MIG-02 AC3's own text ("in their own transaction"), which the requirement body
  itself distinguishes from AC5's "the one applying that tenant's DDL": AC5 governs the
  success path's `done` write (must be same-connection, proving the DDL and the row commit
  atomically), while AC3 requires the failure path's write to be a *different*,
  later-opened transaction (by construction, on whatever connection the pool hands back,
  since the earlier connection's transaction already rolled back and cannot be reused for a
  new transaction in this pool's connection-per-transaction model).
- No other function in the file writes to `platform.platform_migrations`.

This structural check is recorded here as the spec's answer to AC5, per this guide's
existing convention of documenting statement-form / structural acceptance criteria as
verified-by-inspection when no runtime assertion can distinguish compliant from
non-compliant code (the same technique `docs/guides/test_developer_guide.md`'s own AC5
DDL-05 case and this repo's design docs use for structural claims).

---

## Test cases

### TC-MIG-02-01: successful DDL step commits and the control row is done with completed_at set
**Given:** One fixture ACTIVE tenant; `succeedingStep` (a `DdlStep` that runs `SELECT 1` inside the tenant's transaction).
**When:** `runFanout` is called.
**Then:** `result.pending == 0`, `result.done >= 1`; the tenant's control row has `status = 'done'`, `error_msg IS NULL`, `completed_at IS NOT NULL`.
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `"TC-MIG-02-01: successful DDL step commits and the control row is done with completed_at set"` (`tests/integration/migration_fanout_test.zig`)

### TC-MIG-02-02/03: failing DDL step rolls back and records a separate failed row with error_msg
**Given:** One fixture ACTIVE tenant; `failingStep` (a `DdlStep` that always returns `error.SimulatedDdlFailure`).
**When:** `runFanout` is called.
**Then:** `result.pending == 0`, `result.failed >= 1`; the tenant's control row has `status = 'failed'`, `error_msg == "SimulatedDdlFailure"`, and — critically — `completed_at` is still null (proving no `done` row ever committed for the rolled-back transaction, and that the failure record came from the separate transaction, not a partial write inside the rolled-back one).
**Layer:** integration
**Acceptance criterion mapped:** AC2 (no done row survives a rollback) and AC3 (failure recorded separately with error_msg) in one test, since both are proven by the same single assertion sequence — the row's final state is the only externally observable evidence for either claim, and they are two properties of that one row.
**Zig test:** `"TC-MIG-02-02/03: failing DDL step rolls back and records a separate failed row with error_msg"`

### TC-MIG-02-04: failure-recording transaction itself fails under genuine pool exhaustion -- row stays pending
**Given:** A dedicated `pool_size = 2` `Pool` (separate from the shared `pool_size = 5` pool the other tests in this file use); one fixture ACTIVE tenant; `failingStep`.
**When:** `runFanout` is called. `runFanout`'s own `lock_conn` (held for the whole run) plus `applyToTenant`'s own DDL connection (held until `recordFailureSeparately` returns) already consume both of the pool's 2 connections by the time `recordFailureSeparately` tries to acquire a third connection for the failure-recording transaction — genuinely exhausting the pool (`PoolError.ExhaustedPool`) at exactly that step, with no mock or fault-injection hook.
**Then:** `runFanout` returns normally (no panic/crash/escalation) with `result.pending == 0`, `result.failed >= 1`; the tenant's control row is unchanged from its seeded state — `status = 'pending'`, `error_msg IS NULL`, `completed_at IS NULL` — proving `recordFailureSeparately`'s own `pool.acquire()` failure left the row exactly where the seed step put it.
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `"TC-MIG-02-04: failure-recording transaction itself fails under genuine pool exhaustion -- row stays pending"`

---

## Fixtures and isolation

All tests use `bpm.pool.Pool` with fixture tenants inserted via `insertActiveTenant`
(autocommitted, so `runFanout`'s independently-acquired connections can see them) and torn
down via `defer cleanupTenant`. `migration_id`/`run_id` are random per-test tokens
(`randomToken`), never static literals, so repeated runs against a long-lived `bpm_test`
container never collide. `defer cleanupControlRows` removes this test's control rows
regardless of pass/fail. No fixture state is shared across test blocks — see the file's own
header comment on why assertions target this test's own fixture rows by exact
`(migration_id, tenant_id)` key rather than any aggregate/global count, given concurrent
sibling binaries under `zig build test-integration`.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-MIG-02-01 | `TC-MIG-02-01: successful DDL step commits and the control row is done with completed_at set` | AC1 |
| TC-MIG-02-02/03 | `TC-MIG-02-02/03: failing DDL step rolls back and records a separate failed row with error_msg` | AC2, AC3 |
| TC-MIG-02-04 | `TC-MIG-02-04: failure-recording transaction itself fails under genuine pool exhaustion -- row stays pending` | AC4 |
| *(structural, not a test block)* | — | AC5, verified by code inspection above |

**Implemented case count: 3 test blocks** in `tests/integration/migration_fanout_test.zig`,
covering AC1-AC4 directly. AC5 is a structural invariant verified by inspection (no runtime
test can distinguish it). No `error.SkipZigTest` in this file (verified by grep — zero
matches).

Run: `zig build test-integration-mig02-mig03` — 9/9 passing (includes MIG-03's tests and the
MIG-01 AC1 test in the same file; see `tests/specs/MIG-01.md` and `tests/specs/MIG-03.md`).

---

## Traceability

- MIG-02 acceptance: AC1-AC4 directly tested; AC5 structurally verified.
- See MIG-01 (`tests/specs/MIG-01.md`) for the control table's own shape/constraint tests.
- See MIG-03 (`tests/specs/MIG-03.md`) for the fanout-loop requirement sharing this same test
  file and the same `runFanout` entry point.
