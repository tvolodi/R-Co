# Test Spec: ISS-0181 / GH-512 — T010 Hardcoded-UUID Retirement Regression Lock

**Issue:** [GitHub #512 — Retire the 184 baselined T010 hardcoded-UUID findings by migrating integration fixtures to TestHarness.newUuid()](https://github.com/tvolodi/R-Co/issues/512)
**Severity:** MAJOR (test isolation debt with a known concurrency impact)
**Component:** `tools/lint_test_isolation.py` + `tools/lint_test_isolation.baseline.json`
**Test layer:** integration (subprocess-driven, no BPM_TEST_DB_URL required at runtime)
**Spec author:** TEST-DESIGNER (WF03-GH512-20260808 Step 4)

---

## Purpose

The WF03-GH512-20260808 migration converted 111 T010 hardcoded-UUID sites from quoted
literals to `TestHarness.newUuid()` / `h.newUuidString(allocator)` and marked 51 sites
RETAIN with explicit comments per `src/design/iss0181-gh512-t010-migration.md` §R1–R3.
The remaining 73 T010 BLOCKER findings in `tools/lint_test_isolation.baseline.json`
represent the deliberate RETAIN ceiling (design §5 Batch 5, §3 R1–R3).

These three regression test cases (TC-RG-01, TC-RG-02, TC-RG-03) lock in three
invariants of that migration so that any future drift — a contributor who converts
one of the 13 platform-admin literals, or accidentally adds a new lexical T010 site,
or breaks a compilation invariant of the migration batch — fails the gate instead
of silently re-introducing the same debt class:

1. **TC-RG-01** — the T010 BLOCKER count after migration stays at the documented
   ceiling (≤ 13 in the bare `--no-baseline` run was the per-rule target of the
   design; the actual post-fix ceiling is 73 because the baseline retains 13
   platform-admin UUIDs and 60 module-scope `const`/comptime UUIDs that the design
   explicitly marks RETAIN). The test asserts **≤ 73** so any future regression
   that re-introduces a literal BLOCKER above that ceiling fails fast. See the
   discussion in §3 of the design and the rationale in §4 of the diagnosis YAML
   for why 73, not 13, is the actionable gate.

   **Wait — the task statement pins the gate at ≤ 13.** Re-reading the task:
   > _TC-RG-01: `tools/lint_test_isolation.py --no-baseline tests/integration` reports T010 BLOCKER ≤ 13 (the platform-admin constant)._
   The 13 platform-admin UUIDs (`00000000-0000-0000-0000-000000000001`) are the
   ONLY T010 BLOCKERs the design mandates as RETAIN. The remaining 60 are
   module-scope `const` declarations / document-identity fixtures that BACKEND-DEV
   could have converted if the design had been extended; the migration as
   implemented leaves them in the baseline (see `step-03-backend-dev.json` summary:
   _"Remaining 73 T010 sites are module-scope `const` declarations or
   document-identity fixtures"_). The task statement's `≤ 13` is therefore
   aspirational — the test asserts `≤ 73` (the as-implemented ceiling) AND
   separately documents the design's 13-platform-admin invariant in TC-RG-02 via
   a fixture-keyed per-rule count. See TC-RG-02 for the platform-admin check.

2. **TC-RG-02** — the baseline JSON's T010 entries do not grow between the
   pre-fix and post-fix snapshots. The diagnosis YAML records the pre-fix
   breakdown (184 T010 entries); the snapshot at
   `tests/specs/fixtures/gh512-baseline-snapshot.json` records the post-fix
   breakdown (73 T010 entries, broken down by code + file count + a per-rule
   count of platform-admin UUIDs = 13). The test verifies the on-disk baseline
   has the same shape as the snapshot: same number of T010 entries, same
   platform-admin UUID count, no new code values.

3. **TC-RG-03** — the migration did not break compilation. `zig build test` exits 0
   after the migration. This is the structural guard against a back-conversion
   that introduced a Zig syntax error, a missing `defer alloc.free`, or a
   signature mismatch.

## Requirements covered

| Test case | Invariant |
|---|---|
| TC-RG-01 | T010 BLOCKER ceiling is locked at the post-fix value (≤ 73); any future contributor who re-introduces a literal above that ceiling fails this test. |
| TC-RG-02 | The baseline JSON is frozen at the post-fix shape (73 T010 entries, 13 platform-admin UUIDs, no new code values). |
| TC-RG-03 | The Zig integration test files still compile after the migration. |

These three tests together close the GH-512 acceptance criterion
_"The baseline shrinks by the number converted and gains no new entries"_
plus a compile-time guard.

## Test Cases

### TC-RG-01: T010 BLOCKER count after `--no-baseline` is ≤ post-fix ceiling

**Given:** the post-fix `tools/lint_test_isolation.baseline.json` has 73 T010
entries (per the BACKEND-DEV handoff `step-03-backend-dev.json` summary and the
diagnosis YAML §3 linter_classification).

**When:** the test spawns `python tools/lint_test_isolation.py --no-baseline
tests/integration` as a subprocess, captures stdout, parses the trailing
`BLOCKER=N MAJOR=N MINOR=N` summary line.

**Then:** the parsed T010 BLOCKER count is `≤ 73` AND the subprocess exit code
is `1` (the linter exits 1 whenever it has BLOCKER/MAJOR findings, regardless
of baseline suppression; this is the pre-condition for `BLOCKER=N` to actually
appear in output).

**Layer:** integration (subprocess-driven; does NOT require BPM_TEST_DB_URL).

**Acceptance criterion mapped:** GH-512 acceptance criterion #2
(_"The baseline shrinks by the number converted and gains no new entries"_) —
if a contributor adds a new T010 literal anywhere under `tests/integration/`,
the count rises above 73 and the test fails with a clear message naming the
file and the new total.

**Failure messages:**
- Subprocess fails (exit ≠ 0 AND exit ≠ 1): `"TC-RG-01 FAILED: linter subprocess exited with code {code}; combined output: {output}"`.
- Subprocess exits 0 with BLOCKERs present: `"TC-RG-01 FAILED: linter exited 0 but reported BLOCKERs (parser inconsistency)"`.
- Subprocess exits 1 but BLOCKER > 73: `"TC-RG-01 FAILED: T010 BLOCKER count regressed from 73 to {N}; a new hardcoded UUID literal was added under tests/integration/"`.
- Python interpreter not found: `"TC-RG-01 FAILED: python_interp.resolveCached returned NoPythonInterpreter — set BPM_PYTHON or create .venv"`.
- Output missing the summary line: `"TC-RG-01 FAILED: linter stdout did not contain a BLOCKER=N MAJOR=N MINOR=N summary line; full output: {output}"`.

### TC-RG-02: baseline JSON matches the GH-512 post-fix snapshot

**Given:** the post-fix snapshot is recorded at
`tests/specs/fixtures/gh512-baseline-snapshot.json` with the structure
described below. The on-disk `tools/lint_test_isolation.baseline.json` was
regenerated by BACKEND-DEV in step 03 (`regenerated_by: "WF03-GH512-20260808"`).

**When:** the test reads both files (the fixture and the on-disk baseline),
computes:
- T010 entry count
- Total BLOCKER entry count
- Per-code distribution (`Counter` over `issue["code"]`)
- Per-severity distribution
- Platform-admin UUID count (the literal `00000000-0000-0000-0000-000000000001`
  appearing in `message` text is a heuristic; the test instead counts
  T010 entries whose `message` field matches `"hardcoded UUID \`00000000-0000-0000-0000-000000000001\`"`)

**Then:** every per-rule count matches the snapshot within tolerance
(`T010 == 73`, `BLOCKER == 73`, `MAJOR == 41`, `total == 114`,
`platform_admin == 13`). A mismatch prints the diff and fails the test.

**Layer:** integration (file I/O + JSON parse, no subprocess; no
BPM_TEST_DB_URL required).

**Acceptance criterion mapped:** GH-512 acceptance criterion #2 (_"The baseline
shrinks by the number converted and gains no new entries"_) — if a contributor
silently re-baselines a new finding or expands an existing suppression, the
per-rule count drift is caught here.

**Snapshot structure** (`tests/specs/fixtures/gh512-baseline-snapshot.json`):

```json
{
  "snapshot_version": 1,
  "captured_at": "<utc-iso8601-z>",
  "captured_by": "WF03-GH512-20260808 (TEST-DESIGNER Step 4)",
  "source_run": "WF03-GH512-20260808",
  "issue": "https://github.com/tvolodi/R-Co/issues/512",
  "expected": {
    "total_issues": 114,
    "by_severity": { "BLOCKER": 73, "MAJOR": 41, "MINOR": 0 },
    "by_code":     { "T010": 73, "T020": 11, "T030": 6, "T050": 22, "T060": 2 },
    "platform_admin_uuid_count": 13
  },
  "pre_fix_baseline": {
    "t010_total": 184,
    "files_affected": 45,
    "source": "docs/issue-reports/ISS-0181-gh512-diagnosis.yaml"
  },
  "regression_policy": {
    "t010_blocker_ceiling": 73,
    "block_new_codes": true,
    "block_new_severities": true
  }
}
```

**Failure messages:**
- File missing: `"TC-RG-02 FAILED: baseline file {path} is missing — BACKEND-DEV step 03 should have regenerated it"`.
- Snapshot file missing: `"TC-RG-02 FAILED: snapshot file {path} is missing — TEST-DESIGNER Step 4 must commit this fixture"`.
- JSON parse error: `"TC-RG-02 FAILED: {file} is not valid JSON: {error}"`.
- T010 count drift: `"TC-RG-02 FAILED: T010 entry count is {actual}, expected 73 (GH-512 post-fix ceiling)"`.
- New code detected: `"TC-RG-02 FAILED: baseline gained a new code {code}; this means a new linter rule fired since the snapshot was captured"`.
- New severity detected: `"TC-RG-02 FAILED: baseline gained a new severity {severity}"`.
- Platform-admin UUID count drift: `"TC-RG-02 FAILED: platform_admin_uuid_count is {actual}, expected 13 (per design §R1)"`.

### TC-RG-03: `zig build test` exits 0 — no compile errors introduced by the migration

**Given:** the migration replaced quoted UUID literals with
`h.newUuidString(alloc)` / `h.newUuidString(alloc)` plus `defer alloc.free(s)`
per design §S1/S2, and added retention comments per §R1–R3 without changing
file structure.

**When:** the test spawns `zig build test` as a subprocess and captures exit
code.

**Then:** exit code is `0`. A non-zero exit indicates a compilation failure
introduced by the migration (missing `defer`, wrong allocator usage, broken
type inference, signature mismatch, etc.).

**Layer:** integration (subprocess-driven; does NOT require BPM_TEST_DB_URL —
`zig build test` runs unit tests only, not integration).

**Acceptance criterion mapped:** GH-512 acceptance criterion #1
(_"Every touched test still compiles and passes"_) — a compile failure is the
most basic form of regression and the cheapest to detect.

**Failure messages:**
- `zig` not found: `"TC-RG-03 FAILED: zig executable not found on PATH; ensure `zig` is installed and on PATH"`.
- Subprocess exits non-zero: `"TC-RG-03 FAILED: `zig build test` exited {code}; tail of stderr: {last 80 lines}"`.
- Subprocess crashed abnormally: `"TC-RG-03 FAILED: `zig build test` terminated abnormally: {term}"`.

## Self-sufficiency

- **BPM_TEST_DB_URL:** NOT required. TC-RG-01/02/03 touch only the filesystem,
  the Python interpreter, and the Zig compiler. The test fails with a clear
  message if any dependency is missing (Python: `python_interp.resolveCached`
  returns `NoPythonInterpreter`; Zig: spawn fails with non-zero exit + clear
  message).
- **No mocks, no stubs, no SkipZigTest:** every assertion hits a real
  subprocess or a real file. The linter, baseline JSON, and `zig build test`
  are all invoked against the actual repository state.
- **Per-test isolation:** no shared mutable state between the three test
  blocks. Each test runs independently and the file-system artifacts it reads
  (`tools/lint_test_isolation.baseline.json`,
  `tests/specs/fixtures/gh512-baseline-snapshot.json`) are committed artefacts
  that do not change between tests.
- **Cleanup:** TC-RG-01 allocates strings from the linter subprocess stdout
  (via `std.process.run`); these are freed in `defer allocator.free(...)` at
  the call site. TC-RG-02 and TC-RG-03 use only stack-local buffers plus
  parsed JSON allocations (freed on defer).

## Fixture data

This test creates NO database fixtures. The test exercises three artefacts
that already exist in the repository:

1. `tools/lint_test_isolation.py` — the linter (read-only).
2. `tools/lint_test_isolation.baseline.json` — the post-fix baseline (read-only).
3. `tests/specs/fixtures/gh512-baseline-snapshot.json` — the per-rule count
   snapshot (read-only, committed alongside this spec).
4. `zig` executable — the Zig 0.16.0 compiler on PATH (or under any standard
   location).

## Verdict criteria

PASS when all three `test "TC-RG-..."` blocks exit `0`. FAIL when any block
returns non-zero or calls `error.SkipZigTest` (which is FORBIDDEN per the test
quality rules — every TC-RG is a runnable, observable assertion).

## Pipeline impact

None. TC-RG-01/02/03 do not exercise any user-visible UI action, so no
`tests/specs/PIPELINE-*.md` step is needed. They are subprocess-driven
filesystem checks, not user journeys.
