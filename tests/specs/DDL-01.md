# Test Spec: DDL-01 — Pure platform DDL validator

**Requirement:** DDL-01 — The platform SHALL validate every migration statement through
`ValidatePlatformDDL`, a pure function over parsed statement descriptors that holds no
database handle, opens no connection, reads no clock, and reads no environment variable. It
SHALL reject the statement classes that hold `ACCESS EXCLUSIVE` for a duration proportional to
table size — `DROP COLUMN`, `CLUSTER`, `VACUUM FULL`, `REINDEX` without `CONCURRENTLY`, and
`ALTER COLUMN ... SET DATA TYPE` — and index statements written without `CONCURRENTLY`.
Validation SHALL complete before the fanout of MIG-01 opens a connection to any tenant schema,
so a rejected file set touches zero schemas.

**Priority:** MUST
**Test layer:** unit (pure function — `validatePlatformDDL` takes no allocator, opens no
connection, reads no clock; see purity contract in `src/design/ddl-01-validate-platform-ddl.md`)
**Test-tier score (test_developer_guide.md §2.1):** 0 dimensions touched — no DB schema change
(no migration file), no tenant-isolation logic (the module doesn't read `Actor`-specific
per-tenant state, it only trusts a caller-supplied `Actor` value), no Wasm surface, single
module (`src/platform/ddl_validate.zig` composing `ddl_namespace.zig`, both pure), no
transactional boundary (the function opens no transaction). **0 points → unit only**, matching
the actual test layer used below — this is the correct proportionate tier for a pure
classifier function.
**Design:** `src/design/ddl-01-validate-platform-ddl.md`
**Implementation:** `src/platform/ddl_validate.zig` (`validatePlatformDDL`)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a file set containing `ALTER TABLE events DROP COLUMN legacy_flag`, WHEN the migration plan runs, THEN `ValidatePlatformDDL` returns `UnboundedExclusiveLock` naming that statement, the plan exits with status 2, and zero connections are opened to any tenant schema. | `TC-DDL-01-AC1` (verdict + statement naming); see Structural verification note below for "plan exits status 2" / "zero connections opened," which are caller-side (not this module's) behavior |
| AC2 | GIVEN a file set containing `CREATE INDEX idx_events_actor ON events (actor_id)` without `CONCURRENTLY`, WHEN validated, THEN `NonConcurrentIndexBuild` is returned and the file set is REJECTED. | `TC-DDL-01-AC2` |
| AC3 | GIVEN a file set containing `ALTER TABLE events ALTER COLUMN payload SET DATA TYPE JSONB`, WHEN validated, THEN `UnboundedExclusiveLock` is returned. | `TC-DDL-01-AC3` |
| AC4 | GIVEN one descriptor list, WHEN `ValidatePlatformDDL` is called from a unit test with no database reachable and no `BPM_DB_URL` set, THEN the call succeeds and returns the same verdict as the in-process call made during a real migration plan. | `TC-DDL-01-AC4` |
| AC5 | GIVEN a file set of 200 accepted statements, WHEN validated, THEN the verdict is returned in under 100 ms. | `TC-DDL-01-AC5` |
| AC6 | The verdict and the offending statement text are written to `plat_migration_plan`, and `EXECUTION_MIGRATION_VALIDATED` is appended to the event log. | Not testable against this module — see Structural verification note below |

---

## Structural verification note: AC1's "plan exits with status 2" / "zero connections opened," and AC6's persistence

Two clauses in DDL-01's acceptance criteria describe behavior that belongs to the **caller** of
`validatePlatformDDL`, not to the pure function itself, per `src/design/ddl-01-validate-platform-ddl.md`'s
own "Error taxonomy" and "State transitions" sections:

- **AC1's "the plan exits with status 2, and zero connections are opened to any tenant
  schema."** `validatePlatformDDL` raises no `error{...}` set and never returns a process exit
  code — every outcome, including rejection, is a normal `ValidationVerdict` return value (the
  design doc: "DDL-01 AC1's 'the plan exits with status 2' ... describe[s] the CALLER's response
  to a non-accept verdict... not this module's own behavior"). "Zero connections opened" is
  witnessed structurally by the module's own dependency list: `ddl_validate.zig` imports
  nothing from `src/db/pool.zig`, `src/db/provisioning.zig`, `src/db/migrations.zig`, or
  `src/platform/migration_fanout.zig` (confirmed by inspection of the file's imports — only
  `std` and `ddl_namespace.zig`), so it is structurally incapable of opening a connection
  regardless of input. The exit-code mapping itself has no call site yet — DDL-01's own Open
  Question 1 states the migration-plan CLI that would call `validatePlatformDDL` and translate
  its verdict into a process exit code is not yet built ("a SQL-statement parser producing
  `StatementDescriptor` values... is out of scope for this batch"). There is no code to test
  for this half of AC1 until that CLI exists; what IS tested here is the verdict
  `validatePlatformDDL` returns, which is the input the (future) CLI's exit-code logic would
  switch on.
- **AC6 ("written to `plat_migration_plan`... `EXECUTION_MIGRATION_VALIDATED` appended to the
  event log").** The design doc is explicit this is caller-side persistence, not
  `validatePlatformDDL`'s own behavior: "AC6's write to `plat_migration_plan` and the event log
  append are the CALLER's responsibility... this module returns a verdict value and nothing
  more; it does not itself touch a database, matching its stated purity constraint." A
  persistence side effect inside a function DDL-01's own body requires to be
  database-handle-free (AC4) would be a direct contradiction — `validatePlatformDDL` takes no
  allocator and no connection, so it cannot write to any table. Verified by inspection: the
  function signature `pub fn validatePlatformDDL(file_set: FileSet) ValidationVerdict` takes no
  `pool`/`conn`/`allocator` parameter anywhere in `src/platform/ddl_validate.zig`. The write
  itself belongs to the same not-yet-built migration-plan CLI referenced above (DDL-01 Open
  Question 1); there is no code in this batch to write a test against for AC6's persistence
  half.

Both notes are recorded here per this guide's existing convention for documenting statement-form
/ structural acceptance criteria as verified-by-inspection when the runtime code that would make
them independently testable does not exist yet in this batch (compare `tests/specs/MIG-02.md`'s
AC5 structural note using the same technique for a different, already-fully-implemented case).
This is **not** the same situation as MIG-05 AC5 (a deliberate, permanent design decision that no
runtime code will ever exist) — DDL-01's caller (the migration-plan CLI) is explicitly flagged in
the design doc as a near-term follow-up once DDL-02/DDL-03 land, at which point AC1's exit-code
half and AC6's persistence half become testable against real code and this note should be
revisited.

---

## Test cases

### TC-DDL-01-AC1: DROP COLUMN statement is refused as UnboundedExclusiveLock
**Given:** A file set with one statement, `ALTER TABLE events DROP COLUMN legacy_flag`, classed `drop_column`.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.unbounded_exclusive_lock` naming `statement_order = 1`, `statement_text = "ALTER TABLE events DROP COLUMN legacy_flag"`, `class = .drop_column`.
**Layer:** unit
**Acceptance criterion mapped:** AC1
**Zig test:** `"TC-DDL-01-AC1: DROP COLUMN statement is refused as UnboundedExclusiveLock"` (`src/platform/ddl_validate.zig`)

### TC-DDL-01-AC2: CREATE INDEX without CONCURRENTLY is refused as NonConcurrentIndexBuild
**Given:** A file set with one statement, `CREATE INDEX idx_events_actor ON events (actor_id)`, classed `create_index_non_concurrent`.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.non_concurrent_index_build` naming `statement_order = 1` and the exact statement text.
**Layer:** unit
**Acceptance criterion mapped:** AC2
**Zig test:** `"TC-DDL-01-AC2: CREATE INDEX without CONCURRENTLY is refused as NonConcurrentIndexBuild"`

### TC-DDL-01-AC3: ALTER COLUMN SET DATA TYPE is refused as UnboundedExclusiveLock
**Given:** A file set with one statement, `ALTER TABLE events ALTER COLUMN payload SET DATA TYPE JSONB`, classed `alter_column_set_data_type`.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.unbounded_exclusive_lock` with `class = .alter_column_set_data_type`.
**Layer:** unit
**Acceptance criterion mapped:** AC3
**Zig test:** `"TC-DDL-01-AC3: ALTER COLUMN SET DATA TYPE is refused as UnboundedExclusiveLock"`

### TC-DDL-01-AC4: validatePlatformDDL is deterministic and requires no database
**Given:** A file set with one accepting statement (`CREATE TABLE orders ...`, classed `other`), run entirely inside a plain Zig unit test with no `TestHarness`, no pool, no `BPM_DB_URL` env var read anywhere in the test.
**When:** `validatePlatformDDL` is called twice with the identical input.
**Then:** Both calls return `.accept`, proving both "no database is needed" (the test itself never opens one) and "the same verdict" (determinism — same input, same output across two calls).
**Layer:** unit
**Acceptance criterion mapped:** AC4
**Zig test:** `"TC-DDL-01-AC4: validatePlatformDDL is deterministic and requires no database"`

### TC-DDL-01-AC5: 200 accepted statements validate in under 100ms
**Given:** A file set of 200 statements, all classed `other` (unconditionally accepting), each a distinct `CREATE TABLE orders (id uuid PRIMARY KEY)` text with ascending `order`.
**When:** `validatePlatformDDL` is called, wall-clock time measured immediately before and after the call using a platform-appropriate nanosecond timer (see the note on `testTimeNanos` below).
**Then:** The verdict is `.accept`, and elapsed time is under 100 ms.
**Layer:** unit
**Acceptance criterion mapped:** AC5
**Zig test:** `"TC-DDL-01-AC5: 200 accepted statements validate in under 100ms"`

**Note on timing mechanism:** `validatePlatformDDL` itself takes no clock dependency (DDL-01's
own AC4/purity contract forbids one). The 100ms measurement is taken entirely in the TEST, using
a small platform-appropriate wall-clock helper (`testTimeNanos`, scoped to the test file only)
that follows the exact same pattern this codebase already uses in two other places for the
identical reason — Zig 0.16 removed `std.time.Timer`/`nanoTimestamp()` from the public API:
`src/api/routes/instances.zig::currentMicrosecondTimestamp` and
`src/expr/benchmark.zig::getTimeNanos`. The module under test remains clock-free; only the test
harness measures elapsed time around it. A 100ms budget against a pure, allocation-free, O(n)
loop over 200 elements has large headroom over realistic execution time (observed well under 1ms
locally), so this is not a flake-prone tight timing assertion.

### TC-DDL-01-order: first failing statement in order is reported, earlier accepts are skipped
**Given:** A file set of three statements: statement 1 (`order=1`) accepts, statement 2 (`order=2`) is `drop_column` (fails lock-class), statement 3 (`order=3`) is `create_index_non_concurrent` (would also fail, but is never reached).
**When:** `validatePlatformDDL` is called.
**Then:** The verdict names `statement_order = 2` — the first failing statement, not the third, proving earlier accepts are correctly skipped and later violations are never inspected once an earlier one fails.
**Layer:** unit
**Acceptance criterion mapped:** Supports AC1/AC2/AC3's "naming that statement" wording — proves the validator reports the FIRST failure in file order, not merely A failure, which is implicit in every worked AC's "naming that statement" phrasing (each AC's example is a single-statement file set, so this test is what proves the "first" part of that promise for a multi-statement file set).
**Zig test:** `"TC-DDL-01-order: first failing statement in order is reported, earlier accepts are skipped"`

> Naming note: this Zig test was originally labeled `TC-DDL-01-AC5` by BACKEND-DEV, for the
> "ordering" property — a DIFFERENT thing from `docs/requirements.yaml`'s own AC5 (the
> 200-statement/100ms performance criterion). TEST-DESIGNER renamed it to `TC-DDL-01-order`
> (test name string only, no logic change) when adding the genuine AC5 performance test below,
> to remove the resulting name collision (two tests both starting `TC-DDL-01-AC5:`) before it
> could confuse traceability tooling or TEST-DESIGN-VALIDATOR's review.

### TC-DDL-01-order-b: a later statement's violation is never reported once an earlier one fails
**Given:** A file set of two statements: statement 1 (`order=1`) is `vacuum_full` (fails lock-class), statement 2 (`order=2`) would fail the namespace check (`plat_hijacked` created by a tenant actor).
**When:** `validatePlatformDDL` is called.
**Then:** The verdict names `statement_order = 1` — statement 2's namespace violation is never reported, proving the function short-circuits on the first failure and does not continue scanning.
**Layer:** unit
**Acceptance criterion mapped:** Same "first failure in order" property as TC-DDL-01-order, from the opposite direction (proves the search stops, not just that it starts correctly).
**Zig test:** `"TC-DDL-01-order-b: a later statement's violation is never reported once an earlier one fails"` (renamed from `TC-DDL-01-AC5b` for the same collision-avoidance reason as TC-DDL-01-order above)

### TC-DDL-01-composition: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace via composed checkNamespace
**Given:** A file set with a tenant-actor `CREATE TABLE plat_outbox (...)` statement.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.reserved_namespace` naming `plat_outbox` — proving DDL-05's `checkNamespace` is genuinely composed into this module's pipeline (not re-derived), per the design doc's explicit requirement that DDL-01 "MUST call `ddl_namespace.checkNamespace` rather than re-deriving the `plat_` prefix rule."
**Layer:** unit
**Acceptance criterion mapped:** DDL-05 composition proof (referenced by DDL-01's design doc as a required dependency; not itself one of DDL-01's numbered ACs, but proves the module's own stated composition contract).
**Zig test:** `"TC-DDL-01-composition: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace via composed checkNamespace"`

### TC-DDL-01-composition-b: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject
**Given:** A file set with a platform-actor `CREATE TABLE correlation_cursor (...)` statement (no `plat_` prefix).
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.unreserved_platform_object` naming `correlation_cursor`.
**Layer:** unit
**Acceptance criterion mapped:** DDL-05 composition proof (platform side).
**Zig test:** `"TC-DDL-01-composition-b: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject"`

### TC-DDL-01-empty: empty statement list is ACCEPT
**Given:** A file set with zero statements.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.accept`.
**Layer:** unit
**Acceptance criterion mapped:** Baseline/edge case — an empty file set trivially satisfies every AC (there is no statement to violate anything), and this guards against an off-by-one or unconditional-reject bug in the loop.
**Zig test:** `"TC-DDL-01-empty: empty statement list is ACCEPT"`

### TC-DDL-01-positive: CONCURRENTLY index and reindex classes are ACCEPT
**Given:** A file set of three statements using `CREATE INDEX CONCURRENTLY`, `REINDEX INDEX CONCURRENTLY`, and `DROP INDEX CONCURRENTLY` — the CONCURRENTLY-safe counterparts of AC2's rejected cases.
**When:** `validatePlatformDDL` is called.
**Then:** The verdict is `.accept` — proves the lock-class/index checks do not over-trigger on the safe, concurrent variants (a false positive here would incorrectly block every legitimate concurrent index operation).
**Layer:** unit
**Acceptance criterion mapped:** Negative-space coverage for AC1/AC2 (proves the checks discriminate correctly rather than rejecting everything in the same statement family).
**Zig test:** `"TC-DDL-01-positive: CONCURRENTLY index and reindex classes are ACCEPT"`

---

## Fixtures and isolation

All tests are pure unit tests with zero database dependency — no `TestHarness`, no `Pool`, no
`BPM_TEST_DB_URL` read anywhere in `src/platform/ddl_validate.zig`'s test block. Each test builds
its own local `[]StatementDescriptor` array; no fixture state is shared across test blocks. This
matches DDL-01's own AC4, which requires the function to work identically with no database
reachable — the tests prove this by construction (they never attempt to reach one).

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-DDL-01-AC1 | `TC-DDL-01-AC1: DROP COLUMN statement is refused as UnboundedExclusiveLock` | AC1 |
| TC-DDL-01-AC2 | `TC-DDL-01-AC2: CREATE INDEX without CONCURRENTLY is refused as NonConcurrentIndexBuild` | AC2 |
| TC-DDL-01-AC3 | `TC-DDL-01-AC3: ALTER COLUMN SET DATA TYPE is refused as UnboundedExclusiveLock` | AC3 |
| TC-DDL-01-AC4 | `TC-DDL-01-AC4: validatePlatformDDL is deterministic and requires no database` | AC4 |
| TC-DDL-01-AC5 | `TC-DDL-01-AC5: 200 accepted statements validate in under 100ms` | AC5 (added by TEST-DESIGNER — see Coverage gap note below) |
| TC-DDL-01-order | `TC-DDL-01-order: first failing statement in order is reported, earlier accepts are skipped` | First-in-order property supporting AC1/AC2/AC3 (renamed from `TC-DDL-01-AC5` to avoid colliding with the genuine AC5 test above) |
| TC-DDL-01-order-b | `TC-DDL-01-order-b: a later statement's violation is never reported once an earlier one fails` | Same property, opposite direction (renamed from `TC-DDL-01-AC5b`) |
| TC-DDL-01-composition | `TC-DDL-01-composition: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace via composed checkNamespace` | DDL-05 composition proof |
| TC-DDL-01-composition-b | `TC-DDL-01-composition-b: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject` | DDL-05 composition proof |
| TC-DDL-01-empty | `TC-DDL-01-empty: empty statement list is ACCEPT` | Edge case |
| TC-DDL-01-positive | `TC-DDL-01-positive: CONCURRENTLY index and reindex classes are ACCEPT` | Negative-space for AC1/AC2 |
| *(structural, not a test block)* | — | AC1's exit-code/zero-connections half, AC6 — verified by inspection above |

**Implemented case count: 11 test blocks** in `src/platform/ddl_validate.zig` (up from 10 at
BACKEND-DEV handoff — TEST-DESIGNER added `TC-DDL-01-AC5` to close the AC5 performance-coverage
gap described below). No `error.SkipZigTest` in this file (verified by grep — zero matches).

Run: `zig build test-ddl-validate` — 21/21 passing.

---

## Coverage gap found and closed: AC5 (200 statements / under 100ms)

BACKEND-DEV's original test file covered AC1–AC4 directly but had no test for the fifth bullet
of DDL-01's acceptance criteria (`docs/requirements.yaml` line 11096: "GIVEN a file set of 200
accepted statements, WHEN validated, THEN the verdict is returned in under 100 ms"). The
existing in-file test labeled `TC-DDL-01-AC5` covers a DIFFERENT property (first-failure-in-
statement-order, mirroring the design doc's own internal "AC5" shorthand for that ordering rule
— see the design doc's "Within-statement check order" section, which uses "AC5" to mean
ordering throughout) — not the performance criterion `docs/requirements.yaml` actually numbers
as AC5. This is a genuine, testable AC (the function is pure, deterministic, and a 200-element
loop is trivially fast) with no prior test, so TEST-DESIGNER added
`TC-DDL-01-AC5: 200 accepted statements validate in under 100ms` directly to
`src/platform/ddl_validate.zig`, using a small platform-appropriate wall-clock timer scoped to
the test file only (see the timing-mechanism note above). Confirmed passing: 21/21,
`zig build test-ddl-validate`.

**Fail-first check:** N/A in the traditional sense — this is new coverage for a previously
untested AC, not a regression fix for already-passing code, so there is no "pre-change" state to
fail against (the AC's behavior was never asserted before this test existed, but the underlying
implementation already satisfied it — verified by removing the test locally and confirming
`zig build test-ddl-validate` still built and the other 20 tests still passed; re-adding it and
confirming it passes on the very first run against unmodified `validatePlatformDDL` is the
practical equivalent of fail-first for a coverage-gap addition: the test method itself was
verified to correctly discriminate by temporarily lowering the loop to 200 `drop_column`-classed
statements (would return `.unbounded_exclusive_lock`, not `.accept`) and confirming the
`expectEqual(ValidationVerdict.accept, verdict)` assertion fails as expected, then reverting).

---

## Traceability

- DDL-01 acceptance: AC1–AC5 directly tested (11 test blocks total, including composition and
  edge-case coverage beyond the numbered ACs); AC1's exit-code/connection-count half and AC6
  structurally verified by inspection (no runtime code exists yet to test against — see the
  Structural verification note above).
- See `src/design/ddl-01-validate-platform-ddl.md` for the full design rationale, including Open
  Question 1 (the not-yet-built migration-plan CLI that will eventually make AC1's exit-code half
  and AC6's persistence half independently testable).
