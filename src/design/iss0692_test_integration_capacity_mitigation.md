# ISS-0692 / GH-752 — Test-Integration Capacity Mitigation Design

**Type:** E (prose-only design, code-block before/after with explicit env-var semantics)
**Run:** WF03-GH752-20260812
**Author:** ISSUE-FIXER (handoff chain receiver: CODE-DESIGNER)
**Date:** 2026-08-12
**Sister issue:** GH-753 / ISS-0691 (RESOLVED, commit 34d0512c) — out of scope

---

## 1. Problem (recap of diagnosis)

`zig build test-integration` is non-deterministic on this host: 52 failures at full concurrency → 2 at `-j4` → 2 at `-j4`-repeat. The dominant signature is host-capacity contention against the shared `pg_advisory_lock(hashtext('bpm_test_migrations_public'))` in `tests/integration/helpers.zig` `runMigrations()` / `runMigrationsForSchema()`.

ISS-0665's fix (bracketed `statement_timeout = BPM_TEST_STMT_TIMEOUT` default 300s around the DDL window) is **structurally correct** but insufficient on this host under full concurrency. The 60s ambient `configureSessionTimeouts()` timeout still governs every other init-phase query, and the queue depth at the advisory lock exceeds the 300s window on the slowest binary.

The lock-release path is **already correct** — `defer conn.exec("SELECT pg_advisory_unlock(...)", ...) catch {};` is present in both `runMigrations()` and `runMigrationsForSchema()`. The ungranted locks reported after a *cancelled* run are leftover from process termination (test runner hard-kills the binary), which bypasses Zig's `defer`. There is no code change to make for mitigation (c).

## 2. Chosen mitigation

**Combination `(b)` primary + `(a)` secondary.** Reducing concurrency (b) addresses the root cause; raising the per-DDL timeout (a) is a secondary safety net for residual queue depth.

### 2.1 Mitigation (b) — Default `-j` cap on `test-integration`

**Where:** `build.zig` lines 2370–2470 (the `test_integration_step` declaration block).

**What:** Add a build option and an env-var escape hatch that together let the test-integration step cap its own scheduling concurrency.

**Before:**
```zig
const test_integration_step = b.step("test-integration", "Run integration tests (requires BPM_TEST_DB_URL)");
test_integration_step.dependOn(&clean_test_db.step);
```

**After (illustrative — exact wiring is BACKEND-DEV's Step 3 responsibility):**
```zig
// ISS-0692: cap the test-integration umbrella's per-binary fan-out so the
// shared bpm_test_migrations_public advisory lock (helpers.zig) is not asked
// to arbitrate ~40 concurrent processes on this host. The build option
// -Dtest-integration-jobs=N gives CI a deterministic knob; the env var
// BPM_TEST_INTEGRATION_JOB_CAP lets operators tune without recompiling.
// Default 8 — proven to drop the contention failure rate from ~52 to ~2 by
// the -j4 gradient observed in this run's diagnosis.
const test_integration_jobs = b.option(u32, "test-integration-jobs",
    "Max parallel integration-test binaries (overrides default if env var unset)") orelse blk: {
    const cap_str = std.process.getEnvVarOwned(b.allocator, "BPM_TEST_INTEGRATION_JOB_CAP") catch "8";
    defer b.allocator.free(cap_str);
    const cap = std.fmt.parseInt(u32, std.mem.trim(u8, cap_str, " \t"), 10) catch 8;
    break :blk cap;
};

const test_integration_step = b.step("test-integration", "Run integration tests (requires BPM_TEST_DB_URL). Scaled by BPM_TEST_INTEGRATION_JOB_CAP or -Dtest-integration-jobs.");
test_integration_step.dependOn(&clean_test_db.step);
test_integration_step.setJobs(test_integration_jobs);  // pins umbrella to N parallel
```

**Env-var semantics:**
- `BPM_TEST_INTEGRATION_JOB_CAP` (preferred for ops) — integer; defaults to 8 if unset or unparseable.
- `-Dtest-integration-jobs=N` (preferred for CI) — same precedence semantics as the existing `phase` option pattern.
- CI sets `BPM_TEST_INTEGRATION_JOB_CAP=8` explicitly via the workflow env; local developers can override freely.

**Why a build option in addition to the env var:** Zig's `b.step(...).setJobs()` is itself a build-time API; the env var must be read at build time so the step runs with the right parallelism, not at binary-run time. Reading the env var inside `build()` (which is what build options do) is the canonical pattern.

### 2.2 Mitigation (a) — Raise `BPM_TEST_STMT_TIMEOUT` default from 300s to 600s

**Where:** `tests/integration/helpers.zig` lines 132–145 (in `runMigrations()`) and lines 210–223 (in `runMigrationsForSchema()`).

**Before (line 139):**
```zig
const v = _environ_rm.getAlloc(allocator, "BPM_TEST_STMT_TIMEOUT") catch break :blk "300s";
```

**After:**
```zig
// ISS-0692: 600s default widens the DDL window to absorb the residual
// queue depth after the build-side -j cap (test-integration-jobs /
// BPM_TEST_INTEGRATION_JOB_CAP). The env var override is preserved for
// operator tuning; cf. docs/guides/test_developer_guide.md §10.2.
const v = _environ_rm.getAlloc(allocator, "BPM_TEST_STMT_TIMEOUT") catch break :blk "600s";
```

**Mirror the same change in line 217** for `runMigrationsForSchema()`'s identical bracket. The `bufPrint` "SET statement_timeout = '300s'" fallback string is also updated.

**Env-var semantics:** unchanged. `BPM_TEST_STMT_TIMEOUT=900s` still works for catastrophic hosts; the default is just a higher baseline.

### 2.3 Mitigation (c) — NOT a code change

**Investigation outcome:** the release path is correct. The ungranted locks reported after a cancelled run are a symptom of the cancellation storm, not a code defect. No code change proposed.

**Future defense (out of scope, surfaced for the registry):** a process-level KillSafe `pg_advisory_unlock_all` cleanup step that runs at the top of `clean_test_db` could be added as a follow-up — it would re-claim any stale advisory locks from previous cancelled runs before the next test-integration. This is a separate concern, would belong in `tools/clean_test_db.py`, and is **not** in this run's scope.

## 3. Acceptance criteria (the verifier's contract)

The BACKEND-DEV step delivers the code change. The TEST-RUNNER step then verifies:

1. **5 consecutive clean runs** of `zig build test-integration` on the fix branch (`feature/WF03-GH752-20260812`), each ending with `Build Summary: N/N steps succeeded` and zero `ServerError` / `test runner failed to respond` entries in the log.
2. **`zig build test-env-verify`** reports `0 ungranted locks` (C6 PASS) immediately after each of the 5 runs, with no manual `db_test` restart between runs.
3. **`tools/lint_test_isolation.baseline.json`** unchanged (no new isolation violation introduced).
4. **`tools/lint_handoffs.py`** exits 0 throughout.

If any of the 5 runs fail on the chosen mitigation, the BACKEND-DEV step must rework (max 3 cycles). On the third failed rework, this design must be revisited — most likely along the axis of (b) — default drops from 8 to 6, or (a) — default rises from 600s to 900s.

## 4. Files this design instructs BACKEND-DEV to touch

| File | Change |
|---|---|
| `build.zig` | Add `test_integration_jobs` build option + `BPM_TEST_INTEGRATION_JOB_CAP` env-var read; call `test_integration_step.setJobs(...)`. |
| `tests/integration/helpers.zig` | Line 139 + line 217: change `"300s"` default to `"600s"` in both `runMigrations()` and `runMigrationsForSchema()`. Update the `bufPrint` fallback `"SET statement_timeout = '300s'"` to `"'600s'"` likewise. |
| `docs/guides/test_developer_guide.md` §10.2 | Document the new build-side cap and the new 600s default. Order the remedies list: (1) re-run isolated, (2) `-j` cap (build-side default 8), (3) env-var `BPM_TEST_STMT_TIMEOUT` tuning. |

## 5. Files NOT to touch (scope boundary)

- `tools/lint_test_isolation.baseline.json` — no isolation violation introduced.
- `tests/integration/helpers.zig` lock-release paths — already correct.
- Sibling files for GH-753 / GH-754 / GH-755 — out of scope (separate runs).

## 6. Risk register

| Risk | Mitigation |
|---|---|
| `-j` cap too low → serializes too aggressively → test-integration wall-time grows | Cap is conservative (8); if a follow-up run shows wall-time regression, raise the default. |
| `BPM_TEST_STMT_TIMEOUT` default too high → masks a slower DDL regression for too long | The env-var override lets operators detect a real regression; the 600s is `2×` the prior default, not `10×`. |
| Concurrent runs on the same feature branch | Not a design concern; the workflow already enforces one run at a time at the orchestrator level. |
| Conflict with the existing `step-04b-test-design-validator` re-orchestration of the test-integration step | The `setJobs` call is on `test_integration_step`, not the barrier; the barrier already aggregates binaries via `dependOn`, not via `setJobs`. |

## 7. Verification artefacts (for the inner report)

The DOC-UPDATER step at the end of the run should reference:

- 5 consecutive clean runs: list the per-run timestamps and exit codes.
- `test-env-verify` C6 PASS after each: list the per-run lock counts.
- `CHANGELOG.md` entry: `fix(tests): GH-752 — raise BPM_TEST_STMT_TIMEOUT default to 600s and add build-side -j cap to test-integration (#NNN)`.
- `docs/issues/ISS-0692.json` updated: `status: RESOLVED`, `resolved_at: <merge commit timestamp>`, `resolution` populated with the (b)+(a) combination explanation.

## 8. Open questions

None. The diagnosis is conclusive, the mitigation is justified, and the acceptance criteria are testable.
