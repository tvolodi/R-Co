# ISSUE-FIXER Inner Report — GH-752 / ISS-0692 — Step 0.5 + Step 1

**Run:** `WF03-GH752-20260812`
**Issue:** [GH-752](https://github.com/tvolodi/R-Co/issues/752) / [ISS-0692](docs/issues/ISS-0692.json)
**Severity:** BLOCKER
**Issue-Fixer session:** 2026-08-12T22:05:33Z → 2026-08-12T22:25:41Z
**Sibling status (NOT in scope):** GH-753/ISS-0691 RESOLVED in commit [34d0512c](https://github.com/tvolodi/R-Co/commit/34d0512c) (sibling WF03-GH753-20260812)

---

## 1. Registry lookup outcome (Step 0.5)

**Existing entry found** — ISS-0692.json was created at `2026-08-12T22:05:33Z` (the same timestamp as the handoff, indicating ISSUE-FIXER/ORCH co-creation at handoff dispatch). No new ISS file was created. The existing entry's `severity=BLOCKER`, `github_issue=https://github.com/tvolodi/R-Co/issues/752`, and `status=OPEN` are consistent with the handoff payload.

> **Note — separate GitHub-issue vs. local-ISS confusion.** `docs/issues/issue_index.json` also contains an entry `ISS-0211` with the same `github_issue` URL (GH-752). This is **not** a duplicate. ISS-0211 is the inbound WF02-batch-6 finding that *discovered* the failure; ISS-0692 is the local ID assigned to this WF03 fixing run. Both reference GH-752 by design — the GH-752 issue is the single source of truth on GitHub, and both local IDs converge on it. The WF-03 registry layout is intentional (one GH issue can have multiple local ISSes if it gets revisited).

## 2. Root-cause diagnosis (Step 1)

### 2.1 Concurrency-gradient signature (the dominant evidence)

The hold-pattern across consecutive clean runs of the same commit:

| Invocation | Reported failures |
|---|---|
| `zig build test-integration` (default concurrency, ~40 binaries) | 52 |
| `zig build test-integration -j4` | 2 |
| `zig build test-integration -j4` (repeat) | 2 |

Failures drop ~26× when scheduling concurrency drops ~10×, on byte-identical code. A deterministic code regression would not show this pattern. This is the textbook signature of host-CPU/IO contention driving lock-acquisition storms — every binary in the contributing pool queues on `pg_advisory_lock(hashtext('bpm_test_migrations_public'))`, and on this host, when the queue depth exceeds the ambient timeout windows, the stragglers get cancelled.

### 2.2 The bottleneck is the shared advisory lock

`tests/integration/helpers.zig` `runMigrations()` (line 121) and `runMigrationsForSchema()` (line 197) both acquire the same Postgres advisory lock for the entire DDL/migration window. The lock is the shared serialization point — every binary sits in the queue with `lock_timeout = '90s'` raised bracketed around the acquire, and even with ISS-0665's `statement_timeout = '300s'` default bracketed around the DDL work, the queue depth *during* the bracket × *parallel* DDL cost on a loaded host is what determines tail latency.

### 2.3 ISS-0665's fix is correct but insufficient for this host

ISS-0665 ([ISS-0665.json](docs/issues/ISS-0665.json), GH #702, RESOLVED 2026-08-12T03:59:12Z) is structurally sound: bracket a wider `statement_timeout` around exactly the DDL window, restore the ambient on every exit path. The 300s default was a reasonable server-class starting point. The continuation into GH-752 indicates that on this specific host, the contention window under full ~40-binary concurrency exceeds 300s on the slowest binary.

The 60s ambient `configureSessionTimeouts()` (line 304) still governs every OTHER query the harness runs during init — including the `public.tenant_schemas` / `public.schema_migrations` COUNT probes that gate the `runForSchema` fast path (lines 243-275). Under heavy contention, any of those can exceed 60s and be cancelled, which is why mitigation (a) alone — merely raising the 300s default — would still leave the harness init critical section exposed.

### 2.4 The lock-release path is already correct (mitigation (c) investigation)

```zig
// tests/integration/helpers.zig lines 121-136 (runMigrations)
try conn.exec("SET lock_timeout = '90s'", &.{});
try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
try conn.exec("SET lock_timeout = '5s'", &.{});
defer conn.exec("SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))", &.{}) catch {};
```

The `defer` runs on every Zig error path; the `catch {}` swallows any DB error during the unlock attempt itself, so the unlock cannot escalate the failure. The same pattern is in `runMigrationsForSchema()` (lines 197-212). **The release path is complete.**

The ungranted locks after a *cancelled* run are leftover from **process termination** — Zig's build runner hard-kills a binary that exceeds its per-step timeout, which bypasses Zig's `defer`. They are a consequence of the cancellation storm, not an independent defect. Mitigation (c) as a code change is not actionable without rewriting the test-runner termination semantics.

### 2.5 The build step itself has no concurrency ceiling (mitigation (b) leverage)

`build.zig` line 2371 declares `test_integration_step = b.step("test-integration", ...)` and aggregates ~40 binaries via `dependOn`. Zig's build runner defaults to N-1 jobs on N CPU cores. There is no project-level `-j` cap; the only knob is the operator remembering to pass `-j4` on every invocation. This is a host-dependent reliability hazard that the build file should not expose.

## 3. Chosen mitigation

A combination of **(b) primary + (a) secondary**:

1. **(b) — Default `-j` cap on `test-integration`.** Add a build-option knob (e.g. `-Dtest-integration-jobs=N`) with a sensible default (8) AND read an env var (`BPM_TEST_INTEGRATION_JOB_CAP`) at build time so platform operators can override without recompiling. The default must be conservative enough to keep the DB above the contention threshold on this host.

2. **(a) — Raise `BPM_TEST_STMT_TIMEOUT` default from 300s to 600s.** A secondary safety net for residual queue depth after the `-j` cap. The env-var override stays intact for operator tuning.

**Mitigation (c) is rejected as a code change.** The release path is already correct; the ungranted-lock leak is a symptom of the cancellation storm, not an independent defect.

**Why not (a) alone?** It would still schedule ~40 binaries competing for the same DB; the contention window would just be 2× larger, and a fully-loaded host would still blow through it.

**Why not (b) alone?** It reduces the queue depth but leaves the residual queue depth at the new `-j`-bound; on the slowest binary of a worst-case batch, the 300s default could still be insufficient.

## 4. Scope boundary

**In scope:**
- `tests/integration/helpers.zig` — `BPM_TEST_STMT_TIMEOUT` default raise to 600s
- `build.zig` — `test-integration` `-j` cap wiring with env-var escape hatch
- `docs/guides/test_developer_guide.md` §10.2 — update mitigation guidance to reflect BOTH knobs

**Out of scope:**
- GH-753 / ISS-0691 (TC-SIM-01-01 leak) — RESOLVED in sibling run, commit 34d0512c
- GH-754 / ISS-0694 (adp06_pipeline_run_correlation_test.zig leak) — sibling-run-deferred
- GH-755 / ISS-0695 (api03_instance_read_test.zig leak) — sibling-run-deferred
- `tools/lint_test_isolation.baseline.json` — NOT modified (no new isolation violation introduced)

## 5. Verification plan (for the downstream TEST-RUNNER step)

The 5 consecutive clean runs must be performed against the fix branch (`feature/WF03-GH752-20260812`) with the following procedure:

1. `git checkout feature/WF03-GH752-20260812 && git pull --ff-only` (one-time)
2. Before EACH of the 5 runs: `zig build test-env-verify` must exit 0 with HEALTHY 10/10
3. Run `zig build test-integration` (default commands, no manual `-j` override)
4. Immediately after EACH run: `zig build test-env-verify` must report 0 ungranted locks (C6 PASS), no manual `db_test` restart between runs
5. Confirm: every run ends with `Build Summary: N/N steps succeeded` and zero `ServerError` / `test runner failed to respond` entries in the log

If any of the 5 runs fail, the chosen mitigation is insufficient and the agent must rework via the documented handoff protocol (max 3 rework cycles before escalation).

## 6. Files this step touched

| File | Change |
|---|---|
| `handoffs/WF03-GH752-20260812/step-01-issue-fixer.json` | NEW — Step 0.5+1 handoff output |
| `handoffs/orchestrator.log` | APPEND — STEP_00_RECEIVED entry at 2026-08-12T22:25:41Z |
| `docs/issues/ISS-0692.json` | UNCHANGED — registry entry already exists; verification only |
| `docs/issue-reports/ISS-0692-step01-diagnosis.md` | NEW — this report |

No source code modified. No commits created. No branch created (Step 00 is BACKEND-DEV's responsibility).

## 7. Issues filed this step

None. The existing GH-752 / ISS-0692 is the only issue in scope. The adjacent leaks (GH-754/755) are already filed by the sibling WF03-GH753-20260812 run and are out of scope per the One-Issue-One-Run rule.

## 8. Next step

Route to **CODE-DESIGNER** (WF-03 Step 2) — produce the design artefact at `src/design/iss0692_test_integration_capacity_mitigation.md` describing the chosen (b)+(a) combination with before/after code blocks, env-var semantics, and the documented acceptance criteria for the 5 consecutive clean runs verification.
