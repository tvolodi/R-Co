# ISS-0697 — Evidence Trail (Step 1, WF03-GH759-20260813)

**Workflow:** WF03-GH759-20260813 (Step 1 — root-cause diagnosis)
**Author:** ISSUE-FIXER
**Timestamp:** 2026-08-13T10:07:01Z (from `python tools/utcnow.py`)
**Local ISS:** docs/issues/ISS-0697.json
**GitHub issue:** https://github.com/tvolodi/R-Co/issues/759

---

## 1. Live scan (BOM-tolerant)

```
$ python scratch/lint_summary.py
files_checked: 159
total live: 117
  ('BLOCKER', 'T010'): 75
  ('MAJOR', 'T020'): 11
  ('MAJOR', 'T030'): 6
  ('MAJOR', 'T050'): 23
  ('MAJOR', 'T060'): 2
```

Helper script `scratch/lint_summary.py` invokes `tools/lint_test_isolation.py --no-baseline --json tests/integration` with `subprocess.run(..., capture_output=True)`, then decodes the captured stdout via `utf-8-sig` → `utf-8` → `utf-16` fallback. (The raw stdout is UTF-16 LE BOM `ff fe 7b 00` — `wc -l` is unavailable on Windows PowerShell, but the decoded total is 117.) The platform_admin_uuid_count for the live scan (substring `00000000-0000-0000-0000-000000000001` in T010 messages) is **15** (one per integration test file's local `adminActor()` helper, including the new `tests/integration/idn05_role_registry_test.zig:70`).

## 2. Committed baseline on disk

```
$ python -c "import json; d=json.loads(open('tools/lint_test_isolation.baseline.json','rb').read().decode('utf-8-sig')); print(len(d['issues'])); ..."
T010 BLOCKER 75; T020 MAJOR 11; T030 MAJOR 6; T050 MAJOR 23; T060 MAJOR 2; total=117
```

The committed baseline is **internally consistent** with the live scan. The drift is NOT a baseline corruption — it is a snapshot-vs-baseline-and-ceiling lag.

## 3. Snapshot fixture (stale)

```
$ cat tests/specs/fixtures/gh512-baseline-snapshot.json
{
  "snapshot_version": 4,
  "captured_at": "2026-08-11T04:51:13Z",
  "captured_by": "WF02-batch-0-20260811 (ISS-0664, ...)",
  ...
  "expected": {
    "total_issues": 116,
    "by_severity": { "BLOCKER": 74, ... },
    "by_code":     { "T010": 74, ... },
    "platform_admin_uuid_count": 14
  },
  ...
}
```

`expected.total_issues=116`, `expected.by_code.T010=74`, `expected.platform_admin_uuid_count=14`. All three are stale by +1.

## 4. Test ceiling constant (stale)

```
$ grep t010_blocker_ceiling tests/integration/gh512_t010_regression_test.zig
const t010_blocker_ceiling: u32 = 74;
    if (t010 > t010_blocker_ceiling) {
            .{ t010_blocker_ceiling, t010 },
        .{ t010, t010_blocker_ceiling },
```

`const t010_blocker_ceiling: u32 = 74;` at line 35. Live T010 BLOCKER count = 75, so `75 > 74` → TC-RG-01 fails.

## 5. Drift-introducing commit

```
$ git show --stat 34d7ca13 | head -5
commit 34d7ca13171ea79792532047385275d26f4584a0
Author: Vladimir Titenko <tvolodi@gmail.com>
Date:   Wed Aug 12 18:17:56 2026 +0500

    feat: Named role registry and ROLE assignee resolution [WF02-idn05-20260812] (#746)
```

Commit `34d7ca13` (WF02-idn05-20260812, GH-746, PR #746) added `tests/integration/idn05_role_registry_test.zig`. That file's local `adminActor()` helper at line 70 reintroduces the canonical platform-admin UUID literal — the same RETAIN class as every other integration test file's `adminActor()` helper. The commit also regenerated `tools/lint_test_isolation.baseline.json` (T010: 74→75, total: 116→117), but did NOT update the snapshot fixture or the test ceiling constant in the same commit.

The new entry in the baseline is identical in pattern to all 14 other platform-admin UUID RETAIN entries; verified by:

```
$ python -c "..."   # see §1 above
platform_admin entries in LIVE (15 total):
  tests/integration/adp04_user_tenant_binding_test.zig : 53
  tests/integration/adp07_agent_role_reserved_usernames_test.zig : 50
  tests/integration/api03_instance_read_test.zig : 69
  tests/integration/ee08_cancel_instance_test.zig : 48
  tests/integration/env01_test.zig : 145
  tests/integration/ext05_sub_process_support_test.zig : 24
  tests/integration/gh512_t010_regression_test.zig : 337  (substring-search target per step_04_retain_addendum)
  tests/integration/idn01_user_registry_test.zig : 50
  tests/integration/idn02_group_management_test.zig : 63
  tests/integration/idn03_role_access_test.zig : 60
  tests/integration/idn04_api_token_management_test.zig : 47
  tests/integration/idn05_role_registry_test.zig : 70  <-- NEW from 34d7ca13
  tests/integration/instance_error_test.zig : 770
  tests/integration/sch01_timer_creation_test.zig : 31
  tests/integration/tm01_tenant_list_test.zig : 61
```

## 6. Predecessor fix (unmerged)

```
$ git show --stat 0fff689f
commit 0fff689fca79bebc268c1ff1c554252258c12f25
Author: Vladimir Titenko <tvolodi@gmail.com>
Date:   Thu Aug 13 05:34:36 2026 +0500

    fix(test-infra): resync gh512_t010_regression_test ceiling/snapshot to on-main baseline (ISS-0692/GH-757)

 docs/issues/ISS-0692.json                         | 23 ++++++++++++++
 tests/integration/gh512_t010_regression_test.zig  |  9 +++++--
 tests/specs/fixtures/gh512-baseline-snapshot.json | 33 +++++++++++++----------
 tools/lint_test_isolation.baseline.json           | 14 +++++-----
 4 files changed, 56 insertions(+), 23 deletions(-)
```

Commit `0fff689f` (branch `feature/WF03-GH752-20260812`, message: "fix(test-infra): resync gh512_t010_regression_test ceiling/snapshot to on-main baseline (ISS-0692/GH-757)") correctly applies the snapshot v4→v5 + ceiling 74→75 + baseline line-number re-sync across all three artifacts. The diff includes:

- `tests/integration/gh512_t010_regression_test.zig`: `const t010_blocker_ceiling: u32 = 74;` → `75;` plus a doc-comment expansion referencing `snapshot_v5_addendum`.
- `tests/specs/fixtures/gh512-baseline-snapshot.json`: `snapshot_version: 4 → 5`, `expected.total_issues: 116 → 117`, `by_severity.BLOCKER: 74 → 75`, `by_code.T010: 74 → 75`, `platform_admin_uuid_count: 14 → 15`, plus a new `snapshot_v5_addendum` documenting the rationale. Adds a new entry to `t010_blocker_ceiling_history` for WF02-idn05-20260812.
- `tools/lint_test_isolation.baseline.json`: re-syncs `helpers.zig` T020 entry line numbers (503→518, 508→523, 509→524) and updates `regenerated_by`/`regeneration_note`/`last_line_sync` metadata. The T010 BLOCKER count remains 75 and the total remains 117 — the baseline file itself was already correct as of `34d7ca13`.

**Why unmerged:** The squash-merge of GH-752 to main (commit `9d06bdf4`) did NOT include `0fff689f` because `0fff689f` was committed to the same feature branch *after* the PR was approved and queued for squash-merge. Verified:

```
$ git log --oneline --all -- tools/lint_test_isolation.baseline.json -20 | grep 0fff689f
(no output)
```

`0fff689f` is present only on `feature/WF03-GH752-20260812`, not on `main` or `origin/main`.

## 7. Third-recurrence classification

```
$ grep -E '(ISS-0648|ISS-0664)' docs/issues/ISS-0697.json
  "related_to": [
    "ISS-0648",
    "ISS-0664",
    ...
  ],
```

Per `related_to` cross-references, this is the third recurrence of the test-baseline-drift class:

- **First (predecessor):** ISS-0664 / GH-701 — WF03-GH681-20260810 / PR #684 line-renumbering left 3 stale T010 entries behind in the committed baseline. Resolved by ISS-0664's predecessor fix (commit `48d4add1` on main).
- **Second (predecessor):** ISS-0648 / GH-653 — second occurrence of the same drift class (snapshot-vs-baseline lag after a new test file was added by PR #636). Resolved in WF02-batch-0-20260811.
- **Third (current):** ISS-0697 / GH-759 — snapshot v4 → v5 lag after `34d7ca13` added `idn05_role_registry_test.zig`.

## 8. Pre-existing-issue identification (corrections filed in ISS-0697)

| Finding | Resolution |
|---|---|
| ISS-0697 (as authored by Step 0.5) and ISS-0692 both attribute the drift to commit `0d9041b5` "WF02-batch-0", but `git show 0d9041b5` reveals it is actually WF02-batch-2 (DDL-02/ORD-01/02/04, PR #710, 2026-08-11) and does NOT touch `tools/lint_test_isolation.baseline.json`. | Corrected in-place in `docs/issues/ISS-0697.json` Step 1 (this WF); ISS-0692 was authored before the source commit was re-identified and is now superseded. Not filed as a separate GitHub issue. |
| Structural CI guard (pre-commit hook that fails fast if committed baseline.total_issues disagrees with live scan) would prevent the drift from being merged. | Pre-existing follow-up; tracked in `docs/issues/ISS-0697.notes`. Not in scope for Step 3 of this WF. |

## 9. Decision

| Check | Result | Notes |
|---|---|---|
| Severity | **MINOR** | Test-infrastructure only; no production code path affected. |
| Blast radius | **2 files** (plus 1 follow-up evidence file) | `tests/integration/gh512_t010_regression_test.zig` (ceiling 74→75), `tests/specs/fixtures/gh512-baseline-snapshot.json` (v4→v5, expected block + snapshot_v5_addendum), `tools/lint_test_isolation.baseline.json` (helpers.zig T020 line-number re-sync + metadata refresh per `0fff689f`). |
| Schema / migration changes | **NO** | |
| HTTP / API surface changes | **NO** | |
| Auth changes | **NO** | |
| Step 2c (SECURITY-REVIEWER) required | **NO** | Tenant-data-path not affected. |
| Step 4 / 4b (TEST-DESIGNER / VALIDATOR) required | **NO** | Test fixture update, not business-logic test design. |
| Step 2 / 2b (CODE-DESIGNER / VALIDATOR) required | **RECOMMEND SKIP** | Diagnosis is unambiguous; predecessor fix `0fff689f` is a fully-specified mechanical change to three test-infra files; cherry-picking it has zero design ambiguity. The precedent precedent (ISS-0664 was also resolved without a Step 2 design pass — `48d4add1` is a single-commit direct fix). |

## 10. Recommendation to ORCH

**SKIP Step 2 (CODE-DESIGNER) and Step 2b (CODE-DESIGN-VALIDATOR).** Advance directly to **Step 3 (BACKEND-DEV)** with the implementation instructions: apply `0fff689f`'s source changes to three files (test ceiling + snapshot fixture + baseline line-number re-sync), do NOT create a new ISS-*.json file (ISS-0697 already exists and has been updated by Step 1), then advance to Step 4 (TEST-RUNNER) for verification.

ORCH decides.
