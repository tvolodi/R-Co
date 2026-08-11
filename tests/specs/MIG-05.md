# Test Spec: MIG-05 — Idempotent migration re-run

**Requirement:** MIG-05 — The platform SHALL make a migration run idempotent through
`ON CONFLICT (migration_id, tenant_id) DO UPDATE ... WHERE status != 'done'`. Re-running a
completed migration is a no-op for tenants already `done`, and opens no transaction against
their schemas. A migration file is frozen once any tenant holds a `done` row for its
`migration_id`.

**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `bpm.pool.Pool` and `runFanout`, no mocks) for
AC1–AC4; AC5 is a process/tooling constraint outside the running application — see the
Structural verification note below.
**Test-tier score (test_developer_guide.md §2.1):** Tenant isolation (2, the `done`/`pending`/
`failed` upsert guard is entirely about per-tenant control-row state) + transactional boundary
(1, the seed upsert and the fanout loop's skip-check both sit inside/around `applyToTenant`'s
transaction) = **3 points → sandbox tier** per the rubric. No Wasm surface — consistent with
MIG-02/MIG-04's own reasoning; unit + integration is what AC1–AC4's actual content needs.
**Design:** `src/design/mig-04-mig-05-mig-06-resume-idempotency-admin-surface.md`
**Implementation:** `src/platform/migration_fanout.zig` (`seedPendingRow`'s
`ON CONFLICT ... DO UPDATE ... WHERE status != 'done'`, `isAlreadyDone`, the fanout loop's
skip-done guard)

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a migration completed for a tenant, WHEN the migration is run again, THEN no DDL executes for that tenant and its `completed_at` is unchanged. | `TC-MIG-05-01` |
| AC2 | GIVEN a tenant row in `failed`, WHEN the migration is run again, THEN the tenant is re-attempted and its row is updated. | `TC-MIG-05-02` |
| AC3 | GIVEN a tenant row in `done`, WHEN the seeding step of a re-run executes, THEN the conflict clause leaves `status`, `completed_at` and `error_msg` untouched and does not move the row back to `pending`. | `TC-MIG-05-03` |
| AC4 | GIVEN a tenant row in `done`, WHEN the fanout loop reaches that tenant, THEN it is skipped without opening a transaction against that tenant schema. | `TC-MIG-05-04` |
| AC5 | GIVEN any tenant holds a `done` row for `migration_id`, WHEN the migration file content changes, THEN the change is rejected and a new `migration_id` is required. | **No runtime test — see Structural verification note below.** This AC is satisfied by process/tooling discipline outside the running application, by explicit, reviewed design decision (not an oversight). |

---

## Structural verification note: AC5 (migration file content immutability)

AC5 ("GIVEN any tenant holds a `done` row for `migration_id`, WHEN the migration file content
changes, THEN the change is rejected and a new `migration_id` is required") has **no runtime
code in `migration_fanout.zig`, and correspondingly no test asserting runtime behavior for it in
`tests/integration/migration_resume_test.zig`**. This is a deliberate, already-reviewed design
decision, not a coverage gap:

- **The design doc explicitly names two candidate implementations and explicitly does not
  choose (a).** `src/design/mig-04-mig-05-mig-06-resume-idempotency-admin-surface.md`'s Open
  Question 1 lays out option (a) — a `content_hash` column plus a call-site rejection check
  (a Type C schema change) — and option (b) — "a PURELY PROCESS/tooling constraint enforced
  outside the running application entirely (a pre-commit or CI check on migration file diffs,
  comparing against already-shipped `migration_id`s), with NO runtime code in
  `migration_fanout.zig` at all." The design doc reasons that MIG-01's `migration_id` field is
  "caller-supplied free text with no uniqueness constraint of its own beyond the
  `(migration_id, tenant_id)` pair, implying `migration_id` uniqueness-of-CONTENT was always
  meant to be a human/tooling discipline, not a database-enforced one."
- **CODE-DESIGN-VALIDATOR already reviewed and accepted this at Step 1b** (per this handoff's
  own task instructions) as satisfied by process/tooling discipline, not runtime code — this is
  a reviewed, accepted design decision for this batch, not an unresolved open question left for
  TEST-DESIGNER to silently paper over.
- **No code path in `src/platform/migration_fanout.zig` reads, hashes, or compares migration
  file CONTENT at all.** `seedPendingRow`'s `ON CONFLICT ... DO UPDATE ... WHERE status !=
  'done'` guard (AC1/AC3's mechanism) operates purely on the `(migration_id, tenant_id)` key and
  `status` column — it has no concept of "the file that produced this `migration_id`" and
  therefore cannot detect whether that file's content has changed since the `done` row was
  written. Verified by inspection: `platform.platform_migrations`
  (`migrations/1144_platform_migrations_control_table.sql`) has no `content_hash` or
  `file_checksum` column, and no function in `migration_fanout.zig` computes or compares one.

**Why no test exists, and why writing one would be wrong.** Per this guide's directive
(`docs/guides/test_developer_guide.md §1`, "Tests are specifications — every MUST requirement
must have at least one test that would fail if the requirement were violated") and DIRECTIVE T-1
("no mocks or stubs... `error.SkipZigTest` does not constitute a passing test result"), a test
asserting AC5 would have to exercise SOME runtime behavior that rejects a changed migration file.
No such behavior exists in this batch by design — writing a test that calls
`runFanout`/`resumeFanout`/`seedPendingRow` and asserts a rejection would either (a) assert
behavior the implementation does not have, and therefore fail honestly (correct, but then this
handoff could not claim AC5 covered — it would have to be filed as a genuine implementation gap
against an intentionally deferred design, which is not what happened here), or (b) be
constructed to vacuously pass regardless of the module's real behavior (e.g. asserting a tautology,
or asserting something unrelated to file-content changes and labeling it AC5), which is exactly
the "fake/vacuous test to make an AC look covered" this handoff's own instructions forbid. Neither
is acceptable. The correct action — taken here — is to document AC5 as verified by inspection of
the design decision and the absence of any runtime mechanism it could otherwise attach to,
mirroring `tests/specs/MIG-02.md`'s AC5 (no cross-connection control-row writes), which the same
guide convention already documents as "Verified instead by direct code inspection... when no
runtime assertion can distinguish compliant from non-compliant code."

**Difference from MIG-02's AC5 pattern, stated precisely:** MIG-02's AC5 is a structural
invariant ABOUT existing runtime code (which connection object a given write uses) that happens
to produce no distinguishing runtime signal a test could observe — the code exists, the property
is real, but no black-box test can tell compliant from non-compliant. MIG-05's AC5 is different
in kind: no runtime code implementing the invariant exists AT ALL, by an explicit, reviewed
choice to satisfy it entirely outside the running application (process/tooling discipline — e.g.
a future pre-commit or CI check on migration file diffs, not yet built and not part of this
batch's scope). Both are legitimately "no test" for the same underlying reason (nothing runtime-
observable to assert against), but MIG-05's is a scoping decision rather than an inherent
property of already-written code. If a future batch implements option (a) or a CI-side check for
option (b), THIS note should be revisited and a real test added against whatever runtime
mechanism results.

**What this means for MIG-05's overall status.** AC1–AC4 are fully covered by real, passing
integration tests below. AC5 is intentionally out of runtime-test scope per an explicit,
already-reviewed design decision. This requirement's test coverage is complete relative to what
this batch was scoped to implement.

---

## Test cases

### TC-MIG-05-01: re-run of a done tenant executes no DDL and completed_at is unchanged
**Given:** One fixture ACTIVE tenant, seeded to `done` via a normal `runFanout` run.
**When:** `runFanout` is called again with `mustNotBeCalledStep` (a step that fails loudly if ever invoked).
**Then:** `result.done >= 1`, `result.failed == 0`, `result.pending == 0`; the tenant's row is still `done` with byte-identical `completed_at` to before the re-run — proving the seed step's `ON CONFLICT ... WHERE status != 'done'` guard left the row untouched AND the fanout loop's `isAlreadyDone()` pre-check skipped calling `step()` entirely (if it had been called, the propagated `StepMustNotHaveBeenCalled` error would surface as a failed count, which the assertions rule out).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `"TC-MIG-05-01: re-run of a done tenant executes no DDL and completed_at is unchanged"` (`tests/integration/migration_resume_test.zig`)

### TC-MIG-05-02: re-run of a failed tenant re-attempts and updates the row
**Given:** One fixture ACTIVE tenant, seeded to `failed` via a `runFanout` run using `failingStep`.
**When:** `runFanout` is called again with `succeedingStep`.
**Then:** `result.done >= 1`, `result.pending == 0`; the tenant's row is now `done` with `error_msg == null` and `completed_at` set — proving the failed row was genuinely reset to `pending` (by the `ON CONFLICT ... DO UPDATE` firing, since its guard condition `status != 'done'` is true for a `failed` row) and re-attempted by the fanout loop.
**Layer:** integration
**Acceptance criterion mapped:** AC2
**Zig test:** `"TC-MIG-05-02: re-run of a failed tenant re-attempts and updates the row"`

### TC-MIG-05-03: seed step's conflict clause leaves a done row's status, completed_at, and error_msg untouched
**Given:** One fixture ACTIVE tenant, seeded to `done` via `runFanout`.
**When:** The exact seed-step SQL `seedPendingRow` issues (`INSERT ... ON CONFLICT (migration_id, tenant_id) DO UPDATE SET status = 'pending', run_id = EXCLUDED.run_id WHERE status != 'done'`) is issued directly against the already-`done` row, with a different `run_id`.
**Then:** `status`, `completed_at`, and `error_msg` are all identical before and after — not merely `completed_at` (AC1's explicit claim) but all three fields (AC3's stronger claim), proving the conflict-action predicate genuinely short-circuits the `DO UPDATE` for a `done` row rather than partially applying it.
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `"TC-MIG-05-03: seed step's conflict clause leaves a done row's status, completed_at, and error_msg untouched"`

### TC-MIG-05-04: fanout loop skips a done tenant without opening a transaction against its schema
**Given:** Two fixture ACTIVE tenants, both seeded to `done` via a first `runFanout` run; `tenant_pending` is then manually flipped back to `pending` (simulating a crash mid-run) while `tenant_done` stays legitimately `done`.
**When:** `runFanout` is called again with `failingStep` — a step that raises for ANY tenant it is actually invoked on, so which tenants trigger it directly reveals which tenants `applyToTenant` was called for.
**Then:** `tenant_done`'s row is still `done` with unchanged `completed_at` (no transaction was opened for it — `isAlreadyDone()`'s pre-check short-circuited before `pool.acquire()`/`BEGIN`); `tenant_pending`'s row is now `failed` (its transaction WAS opened and `failingStep` genuinely ran inside it) — the two outcomes together prove the skip-path is selective, not a blanket skip of the whole run.
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `"TC-MIG-05-04: fanout loop skips a done tenant without opening a transaction against its schema"`

---

## Fixtures and isolation

All tests use `bpm.pool.Pool` (`pool_size = 5`, shared with MIG-04's tests in the same file) with
fixture tenants inserted via `insertActiveTenant` (autocommitted) and torn down via
`defer cleanupTenant`. Every `tenant_id`/`migration_id`/`run_id` is a fresh random value per test
(`randomUuidStr`, `randomToken`); `defer cleanupControlRows` removes this test's control rows
regardless of pass/fail. `mustNotBeCalledStep`/`failingStep`'s distinct error names let each test
prove exactly which tenants triggered a real DDL step, rather than relying on an assumption about
call counts.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-MIG-05-01 | `TC-MIG-05-01: re-run of a done tenant executes no DDL and completed_at is unchanged` | AC1 |
| TC-MIG-05-02 | `TC-MIG-05-02: re-run of a failed tenant re-attempts and updates the row` | AC2 |
| TC-MIG-05-03 | `TC-MIG-05-03: seed step's conflict clause leaves a done row's status, completed_at, and error_msg untouched` | AC3 |
| TC-MIG-05-04 | `TC-MIG-05-04: fanout loop skips a done tenant without opening a transaction against its schema` | AC4 |
| *(structural, not a test block — see note above)* | — | AC5, satisfied by process/tooling discipline outside the running application; no runtime code exists to test |

**Implemented case count: 4 test blocks** in `tests/integration/migration_resume_test.zig`,
covering AC1–AC4 directly. AC5 is a deliberate design-scope exclusion, not a gap. No
`error.SkipZigTest` in this file (verified by grep — zero matches). **No fake/vacuous test was
written for AC5** — per this handoff's explicit instruction, this spec documents the absence
instead.

Run: `zig build test-integration-mig04-mig05` — 9/9 passing (this file also carries MIG-04's 5
test cases; see `tests/specs/MIG-04.md`).

**Coverage gap check:** AC1–AC4 all map to a specific, independently meaningful test case; no
gap-filling test was needed for those four. AC5 is intentionally untested per the Structural
verification note — this is not treated as a gap to close, consistent with this handoff's
explicit instruction not to fabricate coverage for it.

---

## Traceability

- MIG-05 acceptance: AC1–AC4 directly tested; AC5 documented as a reviewed, non-runtime-testable
  design decision (process/tooling discipline).
- See MIG-04 (`tests/specs/MIG-04.md`) for the resume requirement sharing this same test file.
- See MIG-02 (`tests/specs/MIG-02.md` AC5) for the precedent this note's structural-verification
  technique follows, and for the one meaningful distinction between the two AC5 cases (existing-
  code-with-no-observable-signal vs. no-runtime-code-by-design) spelled out above.
