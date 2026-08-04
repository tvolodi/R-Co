# Module: ISS-0602 Fix — Per-Process Owner Tag for `killIdleConnections()`

Local issue identifier: ISS-0602. GitHub: https://github.com/tvolodi/R-Co/issues/414

## Revision history

- **Original (this run's Step 2, REWORK 0):** LIKE-prefix scoping with
  `application_name LIKE 'bpm-test-%'`. Validator rejected because the
  prefix matches *every* bpm-test connection regardless of owner, so
  harness A still terminates harness B; the cross-process regression
  was deferred to backlog; the SET literal vs `set_config` choice was
  left open; the artefact contained implementation code; error
  taxonomy did not cover an ownership-mismatch guard; no data-flow
  diagram.
- **REWORK 1 (this revision):** one opaque owner tag generated **per
  process** at startup (12 hex chars, `uid_<12hex>`). The tag is
  stamped on every direct connection that process opens via
  `SELECT set_config('application_name', $1, false)` with the value
  bound as a parameter (no SQL string interpolation anywhere).
  `killIdleConnections()` filters `pg_stat_activity` by
  `application_name = payload.id` (exact equality on the caller's own
  tag — *not* LIKE) so it cannot terminate a sibling process's
  connection. The cross-process regression test is in-scope: a real
  two-OS-process test that uses `std.process.Child` to spawn two
  binaries. Error taxonomy defines the ownership-guard failure
  contract explicitly.

## Summary

GitHub #414 (BLOCKER). Local issue identifier ISS-0602. The full
integration suite fails non-deterministically with PostgreSQL
connection-termination errors (SQLSTATE 57P01 `terminating connection
due to administrator command` and `error.ConnectionFailed`) whenever
two or more test binaries run concurrently against the shared
`bpm_test` database. Source-verified root cause
(`docs/issue-reports/ISS-0602-diagnosis.yaml`): `killIdleConnections()`
at `tests/integration/helpers.zig:322` issues an unscoped
`pg_terminate_backend(pid)` against every `state = 'idle in
transaction'` row in `pg_stat_activity`, with only the
`pid != pg_backend_pid()` guard. Because every concurrently-running
test binary shares the same `bpm_test` database, `pg_stat_activity`
contains entries from all of them, so harness A's
`killIdleConnections()` terminates harness B's idle connection.

The REWORK 1 fix partitions the kill-broadcast by a per-process
owner tag. The tag is an opaque 16-byte value (`uid_<12hex>`)
generated **once per test process** at the first
`TestHarness.init()` call (via `std.crypto.random` or
`std.posix.getrandom`, see §Public interface). Every direct
connection that this process opens receives a
`SELECT set_config('application_name', payload.id, false)` statement
binding the same tag as a parameter, so `pg_stat_activity` shows the
exact same `application_name` value for every backend owned by this
process and only this process. `killIdleConnections()` then filters by
`application_name = payload.id` (exact equality on the caller's tag,
**not** LIKE — see §Why exact equality, not LIKE-prefix), terminating
only the caller's own idle connections. The
`pid != pg_backend_pid()` guard is retained as defense in depth.

## Fix scope confirmation

Exactly the 1 file the diagnosis identified for change (well under the
≤5 source-file constraint), plus 2 new test files:

- `tests/integration/helpers.zig` — three additions, all in one file:
  (a) one new file-private helper `generateOwnerTag(allocator)
  !Tag` that produces one opaque `uid_<12hex>` per process, with the
  result cached in a file-private `std.atomic.Value(?Tag)` so every
  subsequent `init()` call within the same process receives the
  *same* tag, (b) one new file-private helper
  `setTestApplicationName(conn, payload)` that binds the tag as a
  parameter to `SELECT set_config('application_name', $1, false)`
  after validating it against `[A-Za-z0-9_-]+`, called from
  `TestHarness.init()` immediately after `pg.Conn.connectUrl` and
  before `configureSessionTimeouts`, and (c) the SQL-string
  replacement inside `killIdleConnections(conn, payload)` to filter
  `pg_stat_activity` by `application_name = $1` with the caller's
  tag bound as a parameter.
- `tests/integration/iss0602_cross_test_isolation_test.zig` — new
  single-process regression test (two harnesses, same cached tag).
- `tests/integration/iss0602_cross_process_isolation_test.zig` — new
  two-process regression test (uses `std.process.Child` to spawn two
  child binaries; see §Test plan).

No production code path changes. No production `application_name` is
ever set by the platform on real database connections — this is a
test-harness-only tag, and `killIdleConnections()` is a
test-harness-only function (file-private, not exported).

## Why exact equality, not LIKE-prefix (this is the BLOCKER fix)

The REWORK 0 design used `application_name LIKE 'bpm-test-%'`. That
predicate matches every test connection in the database — harness B's
distinct `bpm-test-<uuid-b>` session still satisfies
`LIKE 'bpm-test-%'`, so harness A's `killIdleConnections()` still
terminates harness B. The bug is identical to the unscoped form:
LIKE on a shared prefix is **broadcast**, not partition.

The correct predicate is `application_name = payload.id` — exact
equality on the caller's own tag. Two test processes generate two
distinct tags at startup; neither tag matches the other's
`application_name`; neither process terminates the other's idle
connections. The predicate is also safe under the prepared-statement
rule because the value is bound as `$1`, never interpolated into the
SQL string.

The tag-generation rule (`uid_` + 12 hex chars from a CSPRNG, see
§Public interface) guarantees collision probability is negligible
across the ~19+ concurrent test binaries: 12 hex chars = 48 bits =
~2.8 × 10^14 values; collision after 19 draws is
~6.4 × 10^-13. If a collision ever does happen (vanishingly
unlikely), the affected pair would erroneously terminate each other
under the OLD LIKE-prefix behavior too — the new exact-equality
design is at minimum as safe and at best vastly safer.

## Why this is the right isolation axis (not a workaround)

This fix is not a retry/timeout/exception-swallowing workaround. It
does not retry the kill, does not sleep, does not mask errors, and
does not introduce a new lock. It restricts the *existing* one-shot
`pg_terminate_backend` to the connection set the caller actually owns
— the single set of backends this test process *knows* it created.
The diagnosis explicitly enumerated and rejected the other isolation
axes (`datname`, `client_addr`, `pid-set`) with source references;
`application_name` is the only column that satisfies all three
requirements (settable per-process, partitionable, single-DB-safe)
when paired with per-process tag generation and exact-equality
filtering.

`pid != pg_backend_pid()` is retained, not removed, because it is a
correctness guard against any future harness that might omit the
`SET application_name` (a regression of this very fix). It costs
nothing and gives the test a guaranteed floor of "never kill
yourself" even if the `application_name` filter were accidentally
dropped or mis-tagged.

## Module purpose

Partition concurrent-test interference at the only layer that can
distinguish per-process connection sets on a shared database: a
per-process opaque owner tag stamped into the PostgreSQL
`application_name` GUC and matched by exact equality in
`killIdleConnections`. Production code is unaffected — this file is
test-harness-only and `killIdleConnections` is not exported.

## Public interface changes

All changes are inside `tests/integration/helpers.zig`; the file
already imports `bpm`, `pg`, `std`. New symbols and the one changed
signature (Type E prose — signatures only; no function bodies in this
artefact):

1. `const Tag = opaque {};` — new file-private type. The opaque
   type ensures the tag cannot be confused with any other
   `[]const u8` and forces every use through the helper functions
   below.

2. `const TEST_OWNER_TAG_PREFIX: []const u8 = "uid_";` — module-level
   string constant. The tag is the prefix concatenated with 12 hex
   chars, e.g. `"uid_a3b9d2e7f4c1"`. The prefix makes it visually
   distinct from any production `application_name` (production code
   never sets `application_name`; the few places that do use strings
   like `"bpm-platform"` or `""`, never `"uid_*"`).

3. `fn generateOwnerTag(allocator: std.mem.Allocator) !Tag` — new
   file-private helper. Behavior:
   (a) Check a process-local cached tag in a
       `std.atomic.Value(?Tag)`. If non-null, return the cached
       value — every call after the first in this process receives
       the *same* tag. This is the property the fix relies on: one
       tag per process, stable for the process lifetime.
   (b) If the cache is empty, generate 12 hex chars from
       `std.crypto.random` (with `std.posix.getrandom` as fallback on
       platforms where `std.crypto.random` is not seeded yet) and
       build a `Tag` whose string representation is
       `"uid_" ++ <12hex>`. The hex chars must come from
       `[0-9a-f]` only.
   (c) Validate the resulting tag against the regex
       `[A-Za-z0-9_-]+` before returning. The tag's stored
       representation is the validated string.
   (d) Store the new tag in the atomic cache. Subsequent
       `generateOwnerTag` calls in this process see it and return
       it unchanged.

4. `fn validateOwnerTag(tag_repr: []const u8) !Tag` — new
   file-private helper. Validates `tag_repr` against
   `[A-Za-z0-9_-]+` (must start with `TEST_OWNER_TAG_PREFIX`),
   returning a `Tag` whose stored representation is the validated
   slice. Returns `error.InvalidTestOwnerTag` on validation failure.
   All call sites that accept a tag from outside the helper chain
   (e.g. `killIdleConnections(conn, payload)` callers, the
   two-process regression test that needs to pass the tag through an
   env var) must route their input through `validateOwnerTag`
   before binding.

5. `fn setTestApplicationName(conn: *pg.Conn, payload: Tag) !void`
   — new file-private helper. Behavior:
   (a) obtain the validated string representation of `payload` (the
       validation happened at tag generation time or in
       `validateOwnerTag` at the call site);
   (b) issue the literal SQL string

   ```sql
   SELECT set_config('application_name', $1, false)
   ```

   via `conn.exec(sql, .{tag_repr})` — the value is bound as a
   parameter, **never** interpolated into the SQL string;
   (c) any error from `conn.exec` propagates to the caller (see
   §Error taxonomy for the contract).

6. `fn killIdleConnections(conn: *pg.Conn, payload: Tag) !void` —
   signature gains a `Tag` parameter (callers must supply the
   process's own tag). The SQL string literal becomes:

   ```sql
   SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE state = 'idle in transaction'
     AND application_name = $1
     AND pid != pg_backend_pid()
   ```

   bound with `conn.exec(sql, .{tag_repr})`. The behavior contract
   on a zero-row result and on an accidental cross-owner match is
   defined in §Error taxonomy.

   Call sites:
   - `resetTestData()` (line 347) — change to
     `try killIdleConnections(conn, payload)` where `payload` is
     obtained via `generateOwnerTag` (or, if `resetTestData` is
     reshaped to accept `payload` as a parameter, from
     `TestHarness` itself).
   - `tests/integration/iss0602_cross_test_isolation_test.zig` and
     `tests/integration/iss0602_cross_process_isolation_test.zig`
     (new regression tests) — call
     `try killIdleConnections(&h.conn, h.tag)`.

7. `TestHarness.init()` (line 421) — adds the single call to
   `setTestApplicationName(&conn, try generateOwnerTag(allocator))`
   immediately after `errdefer conn.close();` (line 428) and
   immediately before `configureSessionTimeouts(&conn)` (line 433).
   The generated tag is stored on the `TestHarness` value
   (`h.tag: Tag`) so `deinit` and the kill-broadcast can pass it on
   without re-generating. The existing
   `catch |err| { std.debug.print(...); return err; }` pattern is
   preserved at the new call site so the harness's existing
   diagnostics surface continue to work. No new error type — the
   error union reuses any `std.crypto.random` /
   `std.process.Environ` / `pg.Conn.exec` error already in scope.

8. `TestHarness` gains one new field:

   ```zig
   tag: Tag,
   ```

   populated by `init()` and read by `deinit()` and any future
   test that needs to identify its harness's tag (notably the two
   new regression tests).

9. No new exports outside this file. `Tag`, `generateOwnerTag`,
   `validateOwnerTag`, `setTestApplicationName`, and
   `killIdleConnections` are all file-private or, in the case of
   `TestHarness.tag`, exported only because the regression tests
   in the same directory need it.

## Error taxonomy

`generateOwnerTag(allocator) !Tag`:

- `error.OutOfMemory` — propagated from the allocator. The fix
  does not introduce a new fall-back path; this surfaces as
  `init()` failing the test, which is the right behavior (the
  harness cannot safely proceed without an owner tag).
- `error.RandomSourceUnavailable` — the design specifies
  `std.crypto.random` with a `std.posix.getrandom` fallback; if
  both fail (which only happens on a broken kernel), the helper
  returns this error. The harness's existing
  `catch |err| { std.debug.print(...); return err; }` pattern in
  `init()` propagates the error and aborts the test. A literal
  fallback tag (e.g. the rejected `bpm-test-unknown` from the
  REWORK 0 design) is **explicitly not allowed** because a shared
  literal would collapse every failed-tag harness into one tag
  and reintroduce exactly the cross-termination the fix eliminates.
- `error.InvalidTestOwnerTag` — raised by the internal validation
  step if the generated string somehow fails the `[A-Za-z0-9_-]+`
  regex (defensive — should never happen because
  `generateOwnerTag` controls every byte). Propagated to `init()`
  which surfaces it via the same diagnostics-and-return-err
  pattern.

`validateOwnerTag(tag_repr) !Tag`:

- `error.InvalidTestOwnerTag` — the supplied string fails the
  `[A-Za-z0-9_-]+` regex, or does not start with
  `TEST_OWNER_TAG_PREFIX`. Caller MUST propagate.

`setTestApplicationName(conn, payload) !void`:

- `error.InvalidTestOwnerTag` — the supplied `Tag`'s stored
  representation fails validation (only reachable if `payload`
  came from an untrusted source and bypassed `validateOwnerTag`).
  Defensive — `TestHarness.init` always calls
  `generateOwnerTag` which validates internally.
- `error.ServerError`, `error.ConnectionFailed`, etc. — propagated
  from `conn.exec`. The harness's existing
  `catch |err| { std.debug.print("setTestApplicationName failed:
  {}\n", .{err}); return err; }` block in `init()` surfaces these.
  A failed `SET`/`set_config` means the harness cannot guarantee
  the kill-broadcast scoping; failing fast here is preferable to
  silently running the test with the old unscoped behavior.

`killIdleConnections(conn, payload) !void`:

- The `conn.exec(sql, .{tag_repr})` itself: any
  `error.ServerError` / `error.ConnectionFailed` propagates via
  the existing `catch |err| { std.debug.print(...) }` at line 324.
  Unchanged from current behavior.
- **Ownership-guard failure contract (NEW, §MAJOR-05):**
  - **Zero rows terminated (no idle connections to kill):** the
    call is a successful no-op. The existing `catch`-block at
    line 324 must not be triggered. Optionally, the call site may
    emit a `std.log.debug` line at the caller (the
    `resetTestData` site or the regression-test site) noting
    "killIdleConnections: 0 backends matched tag <tag>" — but
    this is debug-only and does not affect the success contract.
  - **Non-zero rows terminated where `application_name` does
    not equal `payload` (defensive verification):** This MUST NOT
    happen under correct behavior because the predicate is
    `application_name = $1` with `tag_repr` as `$1`. PostgreSQL
    guarantees no row with a different `application_name` will
    satisfy the predicate. The defensive post-check is:
    after the `pg_terminate_backend` returns, the helper issues

    ```sql
    SELECT count(*) FROM pg_stat_activity
    WHERE state = 'idle in transaction'
      AND application_name <> $1
      AND pid <> pg_backend_pid()
    ```

    bound with `tag_repr`. If the count is non-zero, the helper
    logs a warning (`std.log.warn("killIdleConnections: unexpected
    cross-owner idle connections remain, count={d}",
    .{unexpected_count})`) and returns `error.OwnerTagMismatch`.
    This is defense in depth — it cannot fire under correct
    SQL — and exists to surface a future regression where
    someone replaces `=` with `LIKE` or drops the predicate.
  - **`pid != pg_backend_pid()` guard trips** (the kill SQL
    would have terminated the caller's own backend but the guard
    excluded it): the SQL is a no-op for that row, no error
    surfaces, no log line. Defense in depth — the tag-exact-match
    predicate already excludes any other process's backend, so
    this guard can only trip on the caller's own backend, which
    is also excluded by the `pid != pg_backend_pid()` predicate.
    The helper MUST NOT log a warning when this guard trips
    because it is the expected behavior. (If a future hardening
    wants to log it, it is acceptable as a `std.log.debug` line,
    but not as a warning.)

## State transitions

None in the `application_name` value itself (it is a session-level
GUC, not a state machine). The lifecycle relevant to this fix is:

```
process startup
  -> generateOwnerTag() caches one Tag in std.atomic.Value(?Tag)
  -> TestHarness.init() #1:
       pg.Conn.connectUrl() -> conn (untagged)
       setTestApplicationName(conn, tag) -> conn tagged
       configureSessionTimeouts() ...
  -> TestHarness.init() #2 (same process):
       generateOwnerTag() returns the CACHED tag (same Tag value)
       pg.Conn.connectUrl() -> conn (untagged)
       setTestApplicationName(conn, same_tag) -> conn tagged
  -> ... (all connections in this process share the same tag)
  -> process exit -> pg_stat_activity entries disappear
```

Two concurrent processes (process A, process B) generate two distinct
tags (the atomic cache is per-process); their backends' tags never
match each other's `application_name`; neither process's
`killIdleConnections` predicate matches the other process's
backends. See §Data flow diagram for the full trace.

## Data flow diagram

The flow is split across five stages. ASCII only; no unicode characters.

### Stage 1 -- Tag generation (per process)

```
+-------------------+              +-------------------+
|  PROCESS A        |              |  PROCESS B        |
|  TestHarness.init |              |  TestHarness.init |
+---------+---------+              +---------+---------+
          |                                  |
          v                                  v
+---------+---------+              +---------+---------+
| generateOwnerTag  |              | generateOwnerTag  |
| (first call: new  |              | (first call: new  |
|  uid_<12hex-a>)   |              |  uid_<12hex-b>)   |
| (later calls:     |              | (later calls:     |
|  cached tag)      |              |  cached tag)      |
+---------+---------+              +---------+---------+
```

Each process generates its own tag on first call; subsequent calls in the same process return the cached value.

### Stage 2 -- Connect and stamp (parameterised)

```
          |                                  |
          v                                  v
+---------+---------+              +---------+---------+
| pg.Conn.connectUrl|              | pg.Conn.connectUrl|
+---------+---------+              +---------+---------+
          |                                  |
          v                                  v
+---------+---------+              +---------+---------+
| setTestApplication|              | setTestApplication|
| Name(conn, tag_A) |              | Name(conn, tag_B) |
+---------+---------+              +---------+---------+
```

`setTestApplicationName` issues `SELECT set_config('application_name', $1, false)` with the tag bound as `$1` (no interpolation).

### Stage 3 -- Visible in pg_stat_activity

```
          |                                  |
          v                                  v
+---------+---------+              +---------+---------+
|  conn_A in        |              |  conn_B in        |
|  pg_stat_activity |              |  pg_stat_activity |
|  application_name |              |  application_name |
|  = tag_A          |              |  = tag_B          |
+---------+---------+              +---------+---------+
```

The two processes' backends now carry distinct `application_name` values in `pg_stat_activity`.

### Stage 4 -- killIdleConnections (process A is the caller)

```
          |                          (park conn_B in
          |                           'idle in
          v                           transaction')
+-------+-------+                    +-------+-------+
| killIdle      |                    | state =       |
| Connections   |                    | 'idle in      |
| (conn_A,      |                    | transaction'  |
|  tag_A)       |                    +---------------+
+-------+-------+
          |
          v
+-------+-------+
| SELECT        |
| pg_terminate_ |
| backend(pid)  |
| FROM          |
| pg_stat_      |
| activity      |
| WHERE state = |
| 'idle in      |
| transaction'  |
|   AND app_    |
|   name = $1   |
|   [tag_A]     |
|   AND pid !=  |
|   pg_backend_ |
|   pid()       |
+-------+-------+
```

Process A's `killIdleConnections` predicate binds `tag_A` as `$1`; the `application_name = $1` exact-equality filter excludes every backend whose `application_name` is `tag_B`.

### Stage 5 -- Outcome (B survives; only A's own other backends match)

```
+-------+-------+
| Result:       |
|   row 0..N:   |
|     pid=A's   |  <- ONLY A's conn terminated
|     other     |     (A's own pid excluded
|     backend   |      by pid != pg_backend_pid())
|     (if any)  |     B's conn NOT terminated
|   no rows:    |     because tag_A <> tag_B
|     B's conn  |
|     (NOT      |
|     matched)  |
+-------+-------+
          |                                  |
          v                                  v
+-------+-------+                    +-------+-------+
| conn_B        |  STILL ALIVE      | conn_B        |
| survives      |  (unchanged pid,  | survives      |
|               |   application_    |               |
|               |   name = tag_B,   |               |
|               |   state = 'idle   |               |
|               |   in transaction')|               |
+---------------+                    +---------------+
```


Cross-process verification of the same flow is in
`tests/integration/iss0602_cross_process_isolation_test.zig`; the
single-process verification is in
`tests/integration/iss0602_cross_test_isolation_test.zig`. Both
tests assert that the diagram's predicted behavior actually
happens.

## Dependencies

- `std.crypto.random` (preferred) and `std.posix.getrandom`
  (fallback) — both already part of Zig's standard library; no new
  external dependency. Used to source the 12 hex chars of the
  owner tag. `std.crypto.random` is a CSPRNG seeded at process
  startup; the fallback handles early-init edge cases.
- `std.atomic.Value(?Tag)` — Zig std, used to cache the per-process
  tag. No new dependency.
- `std.process.Environ.getAlloc` — already used at line 423 to
  read `BPM_TEST_DB_URL`. Reused by the two-process regression
  test to read `BPM_TEST_OWNER_TAG_<pid>` for the child-side
  binding. No new dependency.
- `pg.Conn.exec` — already the only SQL-execution surface in this
  file. Used by both `setTestApplicationName` (parameterised
  `set_config`) and `killIdleConnections` (parameterised
  `pg_terminate_backend` predicate). No new dependency.
- `pg.Conn.connectUrl` — already used at line 427. The new
  `setTestApplicationName` runs **after** the connect and uses the
  returned `*pg.Conn` directly. No new dependency.
- `std.process.Child` — Zig std, used **only** by
  `tests/integration/iss0602_cross_process_isolation_test.zig` to
  spawn the two child binaries. No new dependency.

Out-of-dependency (must NOT be added): any pool reuse, any
`bpm.migrations.Migrations.*` call (untouched), any
`bpm.api_tenant_context.*` (untouched), any production module under
`src/api/**` or `src/engine/**`. The fix is hermetic to
`tests/integration/helpers.zig` plus the two new test files.

## Out of scope

- **Production code paths.** No `src/**` file is modified.
  Production connections do not set `application_name` and would
  not match `uid_<12hex>` if they did. The fix cannot affect
  production behavior.
- **`bpm.pool.Pool`** connections opened by
  `runMigrations`/`runMigrationsForSchema`. Those are short-lived
  workers; they close with the process and are not visible in
  `pg_stat_activity` as `'idle in transaction'` long enough to
  matter. Even if they were, the new owner-tag filter is per-tag,
  not per-prefix, so they would only be terminated if they
  happened to share the tag — which is impossible because the
  migration pool opens its own connections with the default
  `application_name = ""`, not `uid_<12hex>`.
- **Removing `killIdleConnections()` from `resetTestData()`.** The
  diagnosis's optional Part 3 (drop the call entirely and rely on
  per-test rollback) is explicitly **deferred**. The kill-broadcast
  remains the correct recovery mechanism for any `'idle in
  transaction'` row that survives a crashed test process.
- **A new env var `BPM_TEST_RUN_ID`.** Removed by REWORK 1 — the
  exact-tag design does not need a deterministic shared tag. If
  two test binaries need to coordinate a shared tag (which is no
  longer required by the fix), they can use the env var to pass
  the tag from parent to child via `std.process.Child.env_map`.
  This is an affordance for the two-process regression test only.
- **Changing the `lock_timeout = '5s'` semantics.** The widened
  critical section from ISS-0107 is unrelated to this fix; this
  design does not touch `configureSessionTimeouts`.

## Acceptance criteria

1. `src/design/iss0602_test_isolation.md` exists with all required
   sections (this file).
2. `tests/integration/helpers.zig::killIdleConnections` SQL filters
   by `application_name = $1` (exact equality, parameterised) with
   the caller's tag bound as a parameter; the
   `pid != pg_backend_pid()` guard is retained; the
   post-check ownership-verification query exists and returns
   `error.OwnerTagMismatch` on a non-zero cross-owner count.
3. `tests/integration/helpers.zig::TestHarness.init` invokes
   `setTestApplicationName(conn, generateOwnerTag(allocator))`
   immediately after `pg.Conn.connectUrl` and before
   `configureSessionTimeouts`.
4. `tests/integration/helpers.zig::TestHarness` exposes a
   `tag: Tag` field populated by `init()`.
5. `tests/integration/iss0602_cross_test_isolation_test.zig`
   passes (single process): two `TestHarness` instances, each
   calls `setTestApplicationName` with the same cached tag (both
   `application_name` values are equal), harness B parked in
   `'idle in transaction'`, harness A's
   `killIdleConnections(conn, payload)` called, both `SELECT 1`
   succeed on both connections, both `pg_backend_pid()` values
   unchanged. **Note**: under the exact-equality design, two
   harnesses in the same process share one tag (because
   `generateOwnerTag` caches per-process), so the single-process
   test verifies (a) the tag is set, (b) the
   `killIdleConnections` zero-row no-op contract is correct, and
   (c) the `pid != pg_backend_pid()` self-exclusion guard still
   works. The cross-process test is the one that proves the
   isolation contract against a sibling-process `application_name`.
6. `tests/integration/iss0602_cross_process_isolation_test.zig`
   passes (two OS processes): spawns two child binaries via
   `std.process.Child`, each child generates a distinct owner tag
   (its `generateOwnerTag` cache is fresh because it is a new
   process), each child calls `killIdleConnections(conn, own_tag)`
   while the other child's connection is parked in `'idle in
   transaction'`, asserts (a) the parked connection survives (its
   `application_name` is the *other* child's tag, so the
   exact-equality predicate does not match it), (b)
   `pg_backend_pid()` of the parked connection is unchanged, and
   (c) `SELECT 1` on the parked connection returns `1`.
7. `zig build test-integration` completes without SQLSTATE 57P01
   or `error.ConnectionFailed` when run with at least two of the
   existing test-integration binaries invoked in parallel
   (e.g. `zig build test-integration-iss205 & zig build
   test-integration-iss401 & wait` — BACKEND-DEV to choose two
   representatives; the existing `zig-test-integration-cmd` task
   and `zig-test-integration` shell task definitions are the
   build-graph surface that drives this).
8. `python tools/lint_design_artefact.py
   src/design/iss0602_test_isolation.md` exits 0 with no BLOCKER or
   MAJOR.

## Test plan

### `tests/integration/iss0602_cross_test_isolation_test.zig` (new file, in-scope per §BLOCKER-02)

Single-process regression that proves the owner tag is set and the
self-exclusion guard works. Two `TestHarness` instances in the same
process; both share the same cached tag (because
`generateOwnerTag` returns the per-process cache). Behavior:

1. Initialize `TestHarness h_a` (which caches the tag on first
   `init()`) and `TestHarness h_b` (which receives the *same* cached
   tag).
2. Issue `SELECT current_setting('application_name')` on both
   harnesses; assert the returned strings are equal to each other
   AND equal to `generateOwnerTag`'s output for this process.
3. Park harness B's connection in `'idle in transaction'` (the
   harness's own transaction is already open from `init()`; an
   additional `BEGIN` is a no-op savepoint, then a `SELECT 1`
   keeps the connection actively idle-in-tx).
4. Capture `pg_backend_pid()` on harness B.
5. Call `killIdleConnections(&h_a.conn, h_a.tag)`. Under exact
   equality, this predicate matches A's own backends (which are
   `pid != pg_backend_pid()` excluded) and any other A-owned
   idle connection. Since A has no other idle connections, the
   result is zero rows terminated — a successful no-op per
   §Error taxonomy.
6. On harness B: `SELECT 1 AS alive` returns `1`.
7. On harness B: `SELECT pg_backend_pid()` returns the same pid
   captured in step 4.
8. On harness A: `SELECT 1 AS alive` returns `1` (self excluded).
9. `defer h_b.deinit(); defer h_a.deinit();` rolls back and closes.

### `tests/integration/iss0602_cross_process_isolation_test.zig` (new file, in-scope per §BLOCKER-02)

Two-OS-process regression. This is the test that proves the
isolation contract against a *different* process's
`application_name`. Uses `std.process.Child` to spawn two child
binaries; each child runs a self-test entry point
(`-DTEST_ROLE=process_a` or `-DTEST_ROLE=process_b`) controlled by a
top-of-file `comptime` switch on a build option. Pattern follows the
existing per-binary build-graph style (`build.zig` lines
1304–1330+ each declare a separate `b.step("test-integration-<id>")`
that runs a single `tests/integration/iss<ID>_*.zig` file as its own
binary).

Behavior (parent process — the file's `test` block):

1. Set `BPM_TEST_DB_URL` and other env vars required by
   `TestHarness.init` (see `tests/integration/_test_env.zig` if it
   exists, otherwise `BPM_TEST_DB_URL` from the harness's existing
   env-accessor pattern).
2. Spawn child A: `std.process.Child.init(.{
       .argv = &[_][]const u8{ "zig", "test",
         "tests/integration/iss0602_cross_process_child_a.zig" },
       .env_map = env_map_with_TEST_ROLE_process_a,
   })` and child B similarly with `TEST_ROLE=process_b`.
3. Wait for both children to exit. Capture stdout/stderr.
4. Assert both children exited 0.
5. Assert child A's stdout contains the literal
   `CROSS_PROCESS_A_OK` and child B's stdout contains the literal
   `CROSS_PROCESS_B_OK`. These markers are emitted by each child's
   self-test entry point after its assertions pass.

Behavior (child A — `iss0602_cross_process_child_a.zig` or a
comptime-switch in the parent file guarded by `TEST_ROLE=process_a`):

1. `TestHarness h = try TestHarness.init(allocator);` — note: this
   caches the tag for child A's process.
2. Issue `SELECT current_setting('application_name')`; assert the
   value matches `generateOwnerTag`'s output AND starts with
   `TEST_OWNER_TAG_PREFIX`.
3. **Do not** park the connection — child A is the *caller* of
   `killIdleConnections`. It needs an active connection.
4. Sleep briefly (e.g. `std.time.sleep(200 * std.time.ns_per_ms)`)
   to give child B time to park its connection.
5. Call `killIdleConnections(&h.conn, h.tag)`.
6. Assert the call returned `void` (no `error.OwnerTagMismatch`).
7. Issue `SELECT 1 AS alive` on `h.conn`; assert returns `1`
   (proves child A's own connection survived the self-exclusion
   guard).
8. `print("CROSS_PROCESS_A_OK\n");` and exit 0.

Behavior (child B — `iss0602_cross_process_child_b.zig` or
comptime-switch `TEST_ROLE=process_b`):

1. `TestHarness h = try TestHarness.init(allocator);` — caches a
   distinct tag (different process, different cache).
2. Issue `SELECT current_setting('application_name')`; assert it
   starts with `TEST_OWNER_TAG_PREFIX` AND is **not equal** to
   child A's tag. (Parent process reads both children's
   `application_name` via `pg_stat_activity` and asserts the
   values are distinct — belt-and-suspenders.)
3. Park the connection: the harness's `init()` already has
   `BEGIN` open; the connection is idle-in-tx after `SELECT 1`
   returns.
4. Sleep long enough that child A's `killIdleConnections` has
   definitely run (e.g. `std.time.sleep(1 * std.time.ns_per_s)`).
5. Issue `SELECT pg_backend_pid()`; record the pid.
6. Issue `SELECT 1 AS alive`; assert returns `1` (proves child B's
   connection was **not** terminated by child A).
7. Issue `SELECT pg_backend_pid()` again; assert equals the pid
   from step 5 (proves the connection was not re-established —
   which would have happened only if it had been terminated and
   the client transparently reconnected).
8. `print("CROSS_PROCESS_B_OK\n");` and exit 0.

The cross-process test is the one that *cannot* be reproduced by
the single-process test: child A's tag and child B's tag are
guaranteed distinct because they are in different processes with
different `std.atomic.Value(?Tag)` caches, and the predicate is
`application_name = $1` (exact), so child A's `killIdleConnections`
cannot match child B's backends.

### Backlog (not in-scope, recorded for transparency)

- A control test that swaps the SQL back to unscoped form to prove
  the regression test fails-on-bug / passes-on-fix. The
  cross-process test's `killIdleConnections` call returns zero
  rows terminated on the fix and would return one row terminated on
  the bug — the difference is observable from child B's `SELECT 1`
  returning an `error.ConnectionFailed` under the bug. No separate
  control test is required to assert the bug/fix inversion.
- `tests/integration/iss0602_cross_process_isolation_test.zig` is
  new and must be wired into `build.zig` as
  `b.step("test-integration-iss0602", ...)` following the existing
  per-binary pattern. BACKEND-DEV chooses the exact
  build-graph surface; the regression test itself does not depend
  on it being reachable from `zig build test-integration` (it can
  be invoked standalone with `zig test`).

## Implementation notes from CODE-DESIGNER (non-blocking, recorded for BACKEND-DEV)

1. **Single implementation, no choice.** REWORK 0 offered
   `SET application_name` vs `SELECT set_config`. REWORK 1
   specifies `SELECT set_config('application_name', $1, false)`
   with the value bound as a parameter — the only accepted
   implementation. The earlier design's "literal-vs-set_config"
   ambiguity is resolved in favour of the parameterised form, which
   is safe for any byte sequence and is the only one the
   prepared-statement rule permits.
2. **Single LIKE-free SQL form.** The earlier design allowed
   `LIKE 'bpm-test-%'` to be inlined. REWORK 1 specifies
   `application_name = $1` (exact equality) bound as a parameter.
   No string interpolation of the tag value into SQL anywhere.
3. **`generateOwnerTag` cache lifecycle.** The
   `std.atomic.Value(?Tag)` is initialised to `null` at program
   startup (the file's module-level static) and set on the first
   call. The cache lives for the entire process lifetime. There is
   no public API to reset it.
4. **Two-process test entry points.** The simplest implementation
   uses two small child source files
   (`iss0602_cross_process_child_a.zig`,
   `iss0602_cross_process_child_b.zig`). An alternative is a single
   source file with a top-of-file `comptime` switch on
   `@hasField(build_options, "test_role")` — BACKEND-DEV chooses.
   Either is acceptable; the parent regression file is identical
   in both cases.
5. **Tag validation is mandatory.** Even though `generateOwnerTag`
   controls every byte of the tag, `validateOwnerTag` is the single
   chokepoint for any caller that supplies a tag from outside the
   helper chain (e.g. the two-process regression test reading
   `BPM_TEST_OWNER_TAG_<pid>` from the env). The helper MUST be
   called before binding to `$1`.
6. **Backwards-compatibility of the `killIdleConnections`
   signature.** The signature change from
   `killIdleConnections(conn)` to
   `killIdleConnections(conn, payload)` is a compile-time break at
   every call site. Only `resetTestData()` calls it today, and that
   call site is updated alongside the helper. No other file calls
   `killIdleConnections`.

## Documentation update

Append to `tests/integration/helpers.zig` (in-place, no separate doc
file) — extend the existing module-level doc comment at line 1 with a
short paragraph:

```
// ISS-0602 (GitHub #414): every TestHarness connection is tagged
// with a per-process opaque owner tag of the form `uid_<12hex>`.
// killIdleConnections() scopes its pg_terminate_backend broadcast
// to `application_name = $1` with the caller's own tag bound as a
// parameter, so concurrent test binaries no longer terminate each
// other's idle connections on the shared `bpm_test` database.
// See src/design/iss0602_test_isolation.md for the full rationale
// and docs/issue-reports/ISS-0602-diagnosis.yaml for the
// source-verified root cause.
```

Also append a one-line cross-reference to
`docs/guides/test_infrastructure_guide.md` §3 INV-TI-1 (the existing
infrastructure-health checklist), adding: "Run two
test-integration binaries in parallel and confirm no SQLSTATE 57P01 —
this is the single-process regression covered by
`tests/integration/iss0602_cross_test_isolation_test.zig` and the
two-process regression covered by
`tests/integration/iss0602_cross_process_isolation_test.zig`."