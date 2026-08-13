# ISS-0696: Serial execution of public-schema test binaries

**Type:** E (novel / cross-cutting — build.zig orchestration + documentation)
**ISS:** ISS-0696 / GH-760
**Status:** DESIGN COMPLETE — ready for CODE-DESIGN-VALIDATOR
**Author:** CODE-DESIGNER (WF03-GH760-20260813, step-02)

---

## 1. Problem statement

Five integration test binaries — `iss205_test`, `iss203_test`, `iss106_test`, `env01_test`,
and `sch02_test` — operate on shared public-schema and `tenant_default`-schema tables without
per-run schema isolation. Unlike the majority of integration test binaries (which provision a
private `bpm_test_<uuid>` schema and therefore cannot collide with siblings), these five
binaries read and write directly to the default tenant schema (`tenant_default`) and to
`public.tenant`. When the build runner schedules them in parallel with the other ~35 test
binaries under `zig build test-integration -j4`, their shared-table writes are interleaved
with each other in ways that reliably produce assertion failures.

The symptom is non-deterministic: across multiple successive runs, an individual binary may
pass or fail depending on timing. After the GH-752 advisory-lock fix (ISS-0692) eliminated
all `pg_advisory_lock`-related `ServerError` failures, this pre-existing race condition
became the sole remaining source of sporadic failures in the five-run acceptance gate (SE=6
across five runs, traced entirely to these five binaries).

---

## 2. Root cause summary

Two distinct failure modes were confirmed by ISSUE-FIXER (WF03-GH760-20260813, step-01):

### 2.1 `resetTestData()` cross-binary row-deletion race (iss106, iss203, iss205, sch02)

`TestHarness.init()` follows this sequence:
1. Acquire the `bpm_test_migrations_public` advisory lock.
2. Run `resetTestData()` — issues unrestricted `DELETE` statements on the following
   shared `tenant_default` tables: `process_definitions`, `events`, `tasks`, `timers`,
   `webhook_subscriptions`, `instance_projections`, and others.
3. **Release the advisory lock.**
4. Return to the caller; the test body begins writing rows via autocommit pool connections.

The advisory lock serialises only the `TestHarness.init()` pipeline, not the entire binary
lifetime. After step 3, a sibling binary can immediately begin its own `init()`, re-acquire
the lock, and call `resetTestData()` again — deleting in-flight rows that the first binary
wrote in step 4. The first binary's subsequent queries find no rows and fail assertions.
This race is structurally unavoidable under any positive `-j` value; the only complete remedy
is to prevent these binaries from running concurrently.

### 2.2 `public.tenant` non-deterministic row presence (env01)

`env01_test` (compiled from `tests/integration/env_test_root.zig`) acquires the
`bpm_test_migrations_public` advisory lock *per test block*, not for the binary's full
lifetime. Test case TC-ENV-01-03 (tenant visibility) reads `public.tenant` and asserts a
specific row count. When a sibling binary's `TestHarness.init()` is running concurrently,
it may insert a new tenant row while TC-ENV-01-03's `SELECT COUNT(*)` is in flight, making
the count assertion non-deterministic. No fix to `env01_test.zig` or `helpers.zig` can
eliminate this race while other binaries run concurrently; only sequential execution can.

---

## 3. Chosen approach: option (c) — build.zig serial step

Three options were evaluated:

- **(a) Per-test schema isolation** — Refactor all five binaries to provision a private
  schema and avoid shared tables entirely. Correct in principle but requires significant
  test-code changes, cannot be done without modifying `helpers.zig` (which resets shared
  tables), and would take multiple engineering sessions. Not appropriate as a bug-fix.
- **(b) Per-binary full-lifetime advisory lock** — Hold the advisory lock for the entire
  binary lifetime, not just `init()`. Requires modifying `helpers.zig` and all five test
  binaries; would also severely reduce overall integration-test parallelism by holding the
  public lock while the test body executes. Not appropriate.
- **(c) Serial ordering in `build.zig` only** — Extract the five run steps from the
  parallel barrier (`test_integration_others_step`) into a dedicated serial step that runs
  only after the parallel pool has finished. Zero changes to test source code, zero changes
  to helpers, zero changes to production code. Deterministically correct because the five
  binaries can no longer overlap with each other or with the parallel pool.

**Option (c) is chosen.** It is the minimal, safe, and fully contained fix.

---

## 4. Exact specification of `build.zig` changes

### 4.1 Background: existing step topology

The current relevant portion of the `test-integration` dependency graph is:

```
test_integration_step ("test-integration")
  └─ depends on: clean_test_db
  └─ depends on: run_iss503_integration_tests_after_others
                   └─ depends on: test_integration_others_step ("test-integration-others-internal")
                                    └─ depends on: [~35 run steps] ← INCLUDES the five affected runs
```

The five affected run steps currently inside `test_integration_others_step` are:

| Variable name in `build.zig` | Source file | Declared at approx. line |
|---|---|---|
| `run_iss106_integration_tests` | `tests/integration/iss106_webhook_outbox_test.zig` | 1974 |
| `run_iss203_integration_tests` | `tests/integration/iss203_idempotency_keys_test.zig` | 2086 |
| `run_iss205_integration_tests` | `tests/integration/iss205_webhook_outbox_test.zig` | 2119 |
| `run_sch02_integration_tests`  | `tests/integration/sch02_timer_polling_test.zig`   | 2347 |
| `run_env_integration_tests`    | `tests/integration/env_test_root.zig`             | 3267 |

### 4.2 Step 1: Remove the five run steps from `test_integration_others_step`

The following five `dependOn` calls MUST be removed from the
`test_integration_others_step` block (approximately lines 2415–2495 in `build.zig`):

```
test_integration_others_step.dependOn(&run_iss106_integration_tests.step);
test_integration_others_step.dependOn(&run_iss203_integration_tests.step);
test_integration_others_step.dependOn(&run_iss205_integration_tests.step);
test_integration_others_step.dependOn(&run_sch02_integration_tests.step);
```

And the following line near the `env_integration_tests` declaration block
(approximately line 3288, in the `ISS-0104 / GH-362` comment block):

```
test_integration_others_step.dependOn(&run_env_integration_tests.step);
```

When these lines are removed, the five compiled test artifacts remain in the build graph
(their `addTest` and `addIntegrationRun` declarations are untouched), but they are no
longer reachable from `test_integration_others_step`. The narrow dedicated steps
(`test-integration-env`, `test-integration-iss106`, etc.) that point directly to
`run_env_integration_tests`, `run_iss106_integration_tests`, etc. are NOT affected —
those variables and their narrow `b.step(...)` registrations remain as-is.

### 4.3 Step 2: Declare five new serial Run artifacts

Following the ISS-0106 precedent for `run_iss503_integration_tests_after_others`:
because `dependOn` edges are a global property of a `Step` in Zig's build graph (not
scoped to the path by which a step is reached), adding a new ordering dependency directly
onto an existing Run artifact (e.g. `run_iss106_integration_tests`) would propagate that
dependency to every other step that reaches it — including the narrow
`test-integration-iss106` step, which must remain unaffected.

Therefore, **five new Run artifacts** must be created by calling `addIntegrationRun` for
the same five compiled test artifacts (the existing `*_integration_tests` compile
artifacts). These new Run artifacts carry the serial-ordering edges. The existing Run
artifact variables (`run_iss106_integration_tests` etc.) are left entirely unchanged.

The five new Run artifacts and their dependency chain are specified as follows
(names are suggestions; BACKEND-DEV may choose shorter local variable names):

1. **`run_iss106_serial_public`** — calls `addIntegrationRun(b, iss106_integration_tests, migrations_dir, clean_test_db)`.
   After creation, add: `run_iss106_serial_public.step.dependOn(test_integration_others_step)`.
   This makes it start only after the entire parallel pool finishes.

2. **`run_iss203_serial_public`** — calls `addIntegrationRun(b, iss203_integration_tests, migrations_dir, clean_test_db)`.
   After creation, add: `run_iss203_serial_public.step.dependOn(&run_iss106_serial_public.step)`.

3. **`run_iss205_serial_public`** — calls `addIntegrationRun(b, iss205_integration_tests, migrations_dir, clean_test_db)`.
   After creation, add: `run_iss205_serial_public.step.dependOn(&run_iss203_serial_public.step)`.

4. **`run_sch02_serial_public`** — calls `addIntegrationRun(b, sch02_integration_tests, migrations_dir, clean_test_db)`.
   After creation, add: `run_sch02_serial_public.step.dependOn(&run_iss205_serial_public.step)`.

5. **`run_env_serial_public`** — calls `addIntegrationRun(b, env_integration_tests, migrations_dir, clean_test_db)`.
   After creation, add: `run_env_serial_public.step.dependOn(&run_sch02_serial_public.step)`.

The binary execution order within the serial chain is therefore:
iss106 → iss203 → iss205 → sch02 → env01.
(Rationale: webhook binaries first, then scheduler, then env/tenant; any deterministic
order is correct — what matters is that they run one at a time.)

### 4.4 Step 3: Declare the internal serial barrier step

Declare a new named step for diagnostics and internal reference:

```
b.step("test-integration-serial-public-internal",
       "Internal serial barrier for public-schema test binaries (ISS-0696) — not for direct invocation")
```

Assign this to a new local variable (e.g. `test_integration_serial_public_step`).
Add: `test_integration_serial_public_step.dependOn(&run_env_serial_public.step)`.

This step is marked "internal" (not intended for direct invocation) for the same reason
`test-integration-others-internal` is: it is an ordering artifact, not a standalone
runnable target.

### 4.5 Step 4: Wire the serial chain into the umbrella step

Add to `test_integration_step`:

```
test_integration_step.dependOn(&run_env_serial_public.step);
```

(The umbrella step may depend directly on the last run artifact rather than on the named
barrier step — following the same pattern used for
`run_iss503_integration_tests_after_others`.)

### 4.6 Resulting topology after the change

```
test_integration_step ("test-integration")
  └─ depends on: clean_test_db
  └─ depends on: run_iss503_integration_tests_after_others
  │                └─ depends on: test_integration_others_step  ← parallel pool (now minus 5)
  └─ depends on: run_env_serial_public                          ← last of serial chain
                   └─ depends on: run_sch02_serial_public
                                    └─ depends on: run_iss205_serial_public
                                                     └─ depends on: run_iss203_serial_public
                                                                      └─ depends on: run_iss106_serial_public
                                                                                       └─ depends on: test_integration_others_step
```

Under `-j4`, the build runner will run the parallel pool first (bounded at 4 concurrent
jobs). After the parallel pool finishes, both `run_iss503_integration_tests_after_others`
and `run_iss106_serial_public` become ready simultaneously. The iss503 binary and
`run_iss106_serial_public` may therefore start at the same time — but iss503 is a
single binary running DDL on the tenant schema, and the serial chain proceeds one binary
at a time regardless of iss503 concurrency.

**Open question for CODE-DESIGN-VALIDATOR:** iss503 (`test_iss503_rls_removal.zig`) uses
`AccessExclusiveLock`-level DDL on the `tenant_default` schema (DROP POLICY, DROP FUNCTION).
The serial chain's first binaries (iss106, iss203, iss205) also use `tenant_default` tables.
If iss503's DDL conflicts with the serial chain's first few binaries, a further constraint
`run_iss106_serial_public.step.dependOn(&run_iss503_integration_tests_after_others.step)`
should be added (making the serial chain start only after iss503 completes). BACKEND-DEV
should evaluate this at implementation time by checking whether iss503's migration removes
any objects that the serial chain's early binaries depend on. If in doubt, add the extra
ordering edge — it adds wall time but cannot cause a spurious failure.

### 4.7 Where in `build.zig` to place the new declarations

The five new Run artifact declarations and the serial barrier step declaration should be
placed **after** the declarations of all five compiled test artifacts and their original Run
artifacts, and **after** the `test_integration_others_step` block (since the first new Run
artifact references `test_integration_others_step`). A clear block comment identifying
`ISS-0696` and the serial-public purpose should precede the new declarations. The new block
should appear immediately before the `test_integration_step.dependOn(...)` lines at the
bottom of `build.zig`.

---

## 5. `scripts/run-test-integration.{ps1,sh}` — no changes required

Both scripts invoke:
```
zig build test-integration --summary all "-j$cap"
```

Because `test_integration_step` (the umbrella `test-integration` step) will depend on the
last serial-chain run artifact after the change, the scripts' invocation automatically
includes the five serial-public binaries with no modification. The `-j$cap` flag continues
to bound parallel execution for the remainder of the test pool; the serial chain is
constrained by its own dependency edges, not by `-j`.

**No changes to `scripts/run-test-integration.ps1` or `scripts/run-test-integration.sh`.**

---

## 6. `docs/guides/test_developer_guide.md` — section to update

Add a new subsection **§10.3 Public-schema test binaries: intentionally serial** immediately
after the existing §10.2 ("Running integration tests on resource-constrained hosts"), before
the `## 11. Pipeline Tests` heading. The content to add:

---

### 10.3 Public-schema test binaries: intentionally serial (ISS-0696 / GH-760)

Five integration test binaries operate on shared `tenant_default` and `public.tenant` tables
without per-run schema isolation. These binaries are **intentionally serialised** in the
`build.zig` dependency graph and run sequentially after the parallel integration pool
completes:

| Binary | Root source file |
|---|---|
| `iss106_test` | `tests/integration/iss106_webhook_outbox_test.zig` |
| `iss203_test` | `tests/integration/iss203_idempotency_keys_test.zig` |
| `iss205_test` | `tests/integration/iss205_webhook_outbox_test.zig` |
| `sch02_test`  | `tests/integration/sch02_timer_polling_test.zig` |
| `env01_test`  | `tests/integration/env_test_root.zig` |

**Why they are serial:** `TestHarness.init()` issues global unrestricted `DELETE` statements
on shared tables, then releases the advisory lock before the test body begins. This is safe
for isolated-schema binaries (they use their own schema) but produces row-deletion races
for binaries sharing `tenant_default`. `env01_test` additionally reads `public.tenant` row
counts that are disturbed by sibling `TestHarness.init()` calls. See ISS-0696 for the
full root-cause writeup.

**What this means for contributors adding new test binaries:** any new test file that
writes to `tenant_default` or `public.tenant` without a private per-run schema (i.e.
without a `bpm_test_<uuid>` namespace) MUST be added to this serial chain in `build.zig`
rather than to `test_integration_others_step`. Consult `src/design/iss0696_serial_public_schema_tests.md`
for the wiring pattern. `tools/lint_test_isolation.py` enforces the shared-table advisory-
lock requirement (§12.5); use it to check whether your new binary qualifies as a
public-schema binary that should go in the serial chain.

**Running the serial binaries:** they run automatically as part of
`zig build test-integration` and the wrapper scripts. To run them in isolation (after the
parallel pool), use the narrow steps: `zig build test-integration-iss106`,
`zig build test-integration-env`, etc. (existing narrow steps are unaffected by this change).

---

## 7. Files explicitly NOT to modify

The following files MUST NOT be touched by the BACKEND-DEV implementation:

| File | Reason |
|---|---|
| `tests/integration/helpers.zig` | The root cause is architectural (parallel scheduling), not a helpers bug. Modifying helpers is option (b) and was rejected. |
| `tests/integration/iss205_webhook_outbox_test.zig` | Test logic is correct; the race is external. |
| `tests/integration/iss203_idempotency_keys_test.zig` | Same. |
| `tests/integration/iss106_webhook_outbox_test.zig` | Same. |
| `tests/integration/env01_test.zig` (all env-related test files) | Same. |
| `tests/integration/sch02_timer_polling_test.zig` | Same. |
| `tools/lint_test_isolation.baseline.json` | Baseline reflects current lint state; this fix adds no new raw-pool usages. |
| `scripts/run-test-integration.ps1` | No change required; umbrella step covers the serial chain. |
| `scripts/run-test-integration.sh` | Same. |
| Any file under `src/` (production code) | This issue is test-infrastructure-only. |
| Any file under `migrations/` | No schema change required. |

---

## 8. Dependencies

This design depends on:

- **Existing `addIntegrationRun` helper** (`build.zig` lines 44–56) — already handles
  `clean_test_db` ordering edge, `setCwd`, and `BPM_MIGRATIONS_DIR`. No changes to the
  helper itself.
- **Existing compiled test artifacts** (`iss106_integration_tests`, `iss203_integration_tests`,
  `iss205_integration_tests`, `sch02_integration_tests`, `env_integration_tests`) — the new
  serial Run artifacts reuse these, following the ISS-0106 / ISS-503 pattern.
- **`test_integration_others_step`** — the existing parallel barrier. Its role is unchanged;
  only five `dependOn` calls are removed from it.

This design MUST NOT depend on any changes to production Zig source, any schema migration,
or any test-helper API.

---

## 9. Acceptance criteria for the implementation

The implementation passes when ALL of the following hold:

1. **`zig build test-integration` exits 0** in a clean environment with the five serial
   binaries running after the parallel pool. Every binary that was in
   `test_integration_others_step` before the change (except the five removed ones) must
   still be reachable from `zig build test-integration`.

2. **The five narrow steps are unaffected.** Each of `zig build test-integration-env`,
   `zig build test-integration-iss106`, `zig build test-integration-iss203`,
   `zig build test-integration-iss205`, `zig build test-integration-sch02` (and
   `test-integration-sch02` if such a step exists) must still work as standalone targets
   without pulling in the parallel pool as a prerequisite.

3. **Serial execution is enforced by the dependency graph.** `zig build test-integration
   --summary all` output must show the five serial-public artifacts starting only after
   the parallel pool artifacts have completed, and each serial artifact starting only after
   its predecessor in the chain.

4. **Five-run acceptance gate passes.** When the CI acceptance gate runs
   `zig build test-integration` five consecutive times, the SE (sporadic-error count)
   attributable to iss106, iss203, iss205, sch02, and env01 must be 0 across all five runs.

5. **No regressions in `zig build` (unit test suite).** `zig build test` must exit 0
   before and after the change.

6. **`tools/lint_test_wiring.py` exits 0.** The five run artifacts removed from
   `test_integration_others_step` must still be reachable from the `test-integration`
   umbrella step (via the serial chain). The linter must not flag any unattached run
   artifact.

7. **`tools/lint_test_isolation.py` exits 0.** No new BLOCKER or WARNING entries.

8. **`tools/lint_handoffs.py` exits 0** after the handoff is completed.

---

## 10. Open questions

1. **iss503 concurrency with the serial chain** — As noted in §4.6, iss503's
   `AccessExclusiveLock`-level DDL on `tenant_default` may conflict with the first serial
   binaries if those binaries read DDL-stable objects that iss503 is concurrently altering.
   BACKEND-DEV must check this at implementation time and add
   `run_iss106_serial_public.step.dependOn(&run_iss503_integration_tests_after_others.step)`
   if there is any doubt. The extra ordering edge costs at most a few seconds of wall time
   and cannot cause a spurious failure.

2. **`test-integration-serial-public-internal` as a named step** — The named barrier step
   described in §4.4 is useful for diagnostics but is not required for correctness.
   BACKEND-DEV may omit the named step and depend directly on `run_env_serial_public.step`
   from `test_integration_step`. If the step is omitted, the `test-integration-serial-public-internal`
   name used in this document is moot.
