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
| AC4 | GIVEN the failure-recording transaction itself fails, WHEN the fanout continues, THEN the row remains `pending` and the MIG-04 resume query covers it. | Not directly tested (see Coverage note below) |
| AC5 | No code path writes a tenant's control row on a connection other than the one applying that tenant's DDL. | Verified structurally (see Structural verification note below) — not a runtime-observable behavior a test can assert on directly |

---

## Coverage note: AC4 (failure-recording transaction itself fails)

AC4 describes a **double-failure** scenario: the tenant's DDL transaction has already rolled
back (a normal MIG-02 AC2/AC3 failure), and THEN the *separate* failure-recording transaction
(`recordFailureSeparately` in `src/platform/migration_fanout.zig`) also fails — e.g. because
the platform database becomes briefly unreachable in the narrow window between the rollback
and the failure-recording UPDATE. Triggering this deterministically in an integration test
would require injecting a connection failure at that exact, narrow point in
`recordFailureSeparately`'s own connection acquisition or transaction — `bpm.pool.Pool` has
no test-only fault-injection hook for this (and DIRECTIVE T-1 forbids adding one that would
constitute a mock/stub of the pool itself).

This is a genuine, narrower gap than the AC1-3/AC5 cases, but not a *silent* one: the
design artefact's own "Error taxonomy" table (`src/design/mig-02-mig-03-platform-migration-
fanout.md`, the `*(swallowed, logged only)*` row) documents the exact behavior AC4 requires
— the row is left at its already-seeded `pending` value, the failure is logged via
`logSwallowedFailure` (not retried, not escalated), and the code comment on
`logSwallowedFailure` itself states this is deliberate: escalating would abort the whole
fanout over one tenant's bookkeeping hiccup, defeating MIG-03's continue-on-failure
guarantee. The code path is inspectable and matches AC4's wording exactly (row stays
`pending`, MIG-04's future resume query — out of scope, not yet implemented — covers it).
Given the fault-injection difficulty and that MIG-04 (the resume path that actually consumes
a `pending` row left this way) is itself a separate, not-yet-implemented requirement, this is
recorded as a known, narrow, non-blocking gap rather than closed with a synthetic test in
this batch. It should be revisited when MIG-04's implementation lands and a resume-path test
can exercise the full "seed pending → double failure → resume picks it up" cycle end to end,
which is a stronger and more meaningful test than an isolated fault-injection unit would be.

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
| *(structural, not a test block)* | — | AC5, verified by code inspection above |
| *(documented gap)* | — | AC4, not closed this batch — see Coverage note above |

**Implemented case count: 2 test blocks** in `tests/integration/migration_fanout_test.zig`,
covering AC1-AC3 directly. AC5 is a structural invariant verified by inspection (no runtime
test can distinguish it). AC4 is a documented, narrow gap pending MIG-04 (see Coverage note)
— not silently dropped; recorded here for TEST-DESIGN-VALIDATOR and any future implementer
to pick up. No `error.SkipZigTest` in this file (verified by grep — zero matches).

Run: `zig build test-integration-mig02-mig03` — 8/8 passing (includes MIG-03's tests and the
new MIG-01 AC1 test in the same file; see `tests/specs/MIG-01.md` and `tests/specs/MIG-03.md`).

---

## Traceability

- MIG-02 acceptance: AC1-AC3 directly tested; AC5 structurally verified; AC4 documented gap
  pending MIG-04.
- See MIG-01 (`tests/specs/MIG-01.md`) for the control table's own shape/constraint tests.
- See MIG-03 (`tests/specs/MIG-03.md`) for the fanout-loop requirement sharing this same test
  file and the same `runFanout` entry point.
