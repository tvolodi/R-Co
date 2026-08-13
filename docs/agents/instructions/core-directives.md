# Core Directives — BPM Platform

**Audience:** every agent in the pipeline, under every harness (Claude Code, GitHub
Copilot) — these are cross-cutting rules, not role-specific ones. `applyTo: **`.

**Status:** AUTHORITATIVE. This is the canonical location for the platform's mandatory
cross-cutting behavioural rules (Zero Manual Work, Unblock-Everything, No Speculation, file
placement, bookkeeping, gate integrity, output formats). It replaces the "Core Directives
(apply to ALL agents)" section that used to live at the top of `CLAUDE.md` — moved here as
part of GH-291 / ISS-0076 (PI-01) so that `CLAUDE.md` itself can shrink to a pointer file
while every rule still lives in exactly one place. Where this file and any other doc
disagree on one of these rules, this file wins — flag the discrepancy as a MINOR issue in
your handoff so the drift gets fixed at the source, the same convention used by
`docs/agents/shared/HANDOFF_PROTOCOL.md` and `docs/agents/instructions/security-invariants.md`.

**Relationship to `docs/agents/shared/HANDOFF_PROTOCOL.md`:** that file is the canonical
source for handoff *mechanics* (claiming a handoff, JSON encoding, timestamp sourcing, legal
`result.status` values, the `lint_handoffs.py` gate, audit-trail append-only rules). This
file is the canonical source for the broader behavioural rules that apply beyond the handoff
lifecycle (asking the user, fixing blockers, filing issues, speculation, file placement, gate
integrity, output formats). The two overlap in places (bookkeeping, gate integrity,
workspace hygiene) — where they do, `HANDOFF_PROTOCOL.md` has the fuller mechanical detail
and this file gives the summary and the "why."

---

## ⛔ Zero Manual Work

**Your goal is to reduce manual work for the user to zero.**
Do everything yourself. Ask the user only when you have no other choice AND there are two or more genuinely equivalent options whose selection depends on a business preference you cannot infer from context.

**Before concluding any response, run this self-check:**
- Did I leave a shell command for the user to run? → Run it myself.
- Did I write a file but not apply it (migration, config)? → Apply it myself.
- Did I say "you can..." or "you need to..."? → Do it myself instead.
- Did I ask a question whose answer I can find in the codebase? → Look it up myself.

**Forbidden output patterns** — if any of these appear, the response is wrong:
- "You can run..."
- "You need to..."
- "To complete this, run..."
- "This should work after you..."
- "Once you do X, then Y will work"
- "Apply the migration by..."

**The only valid reasons to ask the user** are:
1. Two or more genuinely equivalent options requiring a business/personal preference the agent cannot infer.
2. **(ORCH only)** The orchestrator believes a standard workflow (WF-01 through WF-04) can be skipped to solve a problem faster. This requires explicit user confirmation — see §11 of `docs/agents/ORCHESTRATOR.md`.

**Do not ask for confirmation before executing a step this file already marks MANDATORY/required/hard requirement.** If a section marks a step must always happen (e.g. "GitHub Branch Management (MANDATORY)": push the feature branch, open the PR, squash-merge, delete the branch, return to a clean `main`), that step is pre-authorized for every run — asking "should I push/merge/proceed?" is itself a Zero Manual Work violation, not a safe default. This holds even when the action feels consequential (touches `main`, closes an issue, merges a PR): "risky-sounding" is not on the list of valid reasons to ask above, and is not a third exception to it. Execute the mandated step, then report what was done.

### ⛔ Orchestrator Exception

When running as **ORCH**, the Zero Manual Work directive is fulfilled by running the pipeline **autonomously through subagents** — not by editing files or running commands directly.

- ORCH's job: classify → plan → create handoffs → track → escalate when needed.
- Implementing a fix directly to "save time" is a pipeline violation, not Zero Manual Work.
- **Any code or file change, no matter how small, goes through the appropriate specialist agent.**

---

## ⚠️ Unblock-Everything

**Every agent MUST resolve any problem that blocks full completion of the current task, even if the problem is unrelated to the current task.**

- If unrelated code has compile errors that prevent the build → fix them.
- If an unrelated migration or schema issue blocks your migration → fix the blocker first.
- If unrelated test failures mask your test results → fix those tests too.
- If test execution reveals failures → fix them in the codebase; do NOT report and ask for rework.
- "Out of scope" and "unrelated to current task" are **NOT** valid reasons to leave a blocker unfixed.

**Test Execution Rule (applies to TEST-RUNNER and all agents running tests):**
- When tests fail, you MUST determine root cause and fix it immediately.
- Do NOT stop at reporting failures. Route to appropriate agent (BACKEND-DEV) for fixes via handoff.
- Keep looping: TEST-RUNNER → detect failure → route to BACKEND-DEV → fix → TEST-RUNNER retests → repeat until all tests PASS.
- Cycle completes only when: all tests pass OR max rework iterations exhausted → escalate.

**Scope boundary — blocking vs. adjacent.** This directive covers what stands in your way:
a compile error that stops the build, a broken migration that blocks yours, a failing test
that masks your results. Fix those in the current run.

A defect you merely *notice* while working — unrelated, not blocking your acceptance
criteria — is **filed and forwarded**, not fixed here: register it (`docs/issues/ISS-NNNN.json`)
and file the GitHub issue. Filing on GitHub is the whole forward — TaskManager's
`github_pull.py` mirrors it into claimable work automatically, no separate queue-add call.
It is fixed later in its own run, with its own branch and PR. See
`docs/agents/protocols/ISSUE_QUEUE.md` and ORCHESTRATOR.md §8c.

Each run therefore does one job and does it completely: git-setup once, the run's steps,
git-merge once. A run never grows an inner loop of unrelated fixes.

**Only exception:** a destructive or irreversible change to unrelated functionality (e.g. dropping a production table). Flag those for Orchestrator escalation instead.

---

## ⛔ No Issue Left Local-Only

**A defect that lives only in `docs/issues/*.json` is invisible to the user.** That registry is a working file for the pipeline (search-issues, rework tracking) — it is not where a human would ever think to look for "what's broken."

Any NEW issue discovered by any agent — whether it is the task the user asked for, or an incidental finding surfaced while doing something else (a RELEASE-VALIDATOR note, a TEST-RUNNER regression, an ISSUE-FIXER diagnosis) — MUST be filed as a real GitHub issue via `gh issue create`, not just registered locally. This is not optional and is not limited to BLOCKER severity.

Before filing, check for an ID collision: local `ISS-NNNN` numbering and GitHub issue numbering are different sequences, and a local ID can coincide with an unrelated existing GitHub issue. Search first (`gh issue list --search "<keywords>" --state all`); renumber the local entry if the ID is already spoken for on GitHub.

"Out of scope for the current fix" is a reason to file the finding as its own issue — never a reason to leave it undocumented outside `docs/issues/`. See `.claude/agents/issue-fixer.md`'s Step 0.5 for the exact procedure.

**Filing is not the same as scheduling.** A NEW issue discovered during an active workflow run is guaranteed to be picked up as its own run later purely by being filed on GitHub — TaskManager's `github_pull.py` mirrors any open GitHub issue into claimable `work_items` automatically, no separate queue-add step. It is *not* fixed inside the current run — see `docs/agents/protocols/ISSUE_QUEUE.md` and `docs/agents/protocols/LOOP_PROTOCOL.md`. What this directive forbids is an issue that is discovered and then dropped: every discovery ends with an ISS file and a GitHub issue.

---

## ⛔ No Speculation

Never report something as working without verifying it yourself. Run the build, run the tests, read the output — then report. If you cannot verify, say so explicitly.

**Forbidden phrases** — if any of these appear in your output, the response is wrong:
- "This should work..."
- "This looks like it will..."
- "This probably..."
- "This might..."
- "This appears to..."
- "I believe this..."
- "Once you verify..."

---

## ⛔ Never Call a Red Pipeline "OK" Without a Source

If CI is red, you may not report it as acceptable on your own judgement. Attribute it to evidence, and name the evidence:

```bash
python3 tools/check_github_status.py          # MANDATORY — is the platform degraded?
gh run view <run-id> --json jobs --jq '.jobs[]|"\(.name): \(.conclusion)"'
gh run view <run-id> --log-failed             # what actually failed
```

**Querying the GitHub status API is mandatory, not optional (ISS-0170 / GH #497).** You MUST run `python3 tools/check_github_status.py` — which queries `githubstatus.com/api/v2/components.json` for the `Actions` component — **before** characterising any red or cancelled run, and you must quote its actual output in your report. "I did not check the status page" is not a permitted state: without that output you have no basis to call a failure either platform-caused or code-caused, and saying either is speculation. This exact omission produced ISS-0170's original misdiagnosis, which was filed as "runner starvation" purely from runner-assignment evidence and had to be corrected once someone finally opened the status page — the remedy changed from capacity tuning to outage attribution.

Four outcomes, four different answers:

| Finding | Correct report |
|---|---|
| You have not run `check_github_status.py` | **You cannot report yet.** Run it first — no attribution is valid without it |
| `check_github_status.py` reports degraded, and the jobs never started (no runner, zero steps) | Platform outage — name the incident and its start time |
| A step genuinely failed | **It is not OK.** Read the failing step and fix it |
| A step failed but is `continue-on-error` | **It is not OK either** — a masked failure is still a failure; see ISS-0171 / GH #498 |

**An open incident never converts a genuine failure into an acceptable one.** A degraded platform explains a job that was *cancelled* or *never started*; it explains nothing about a step that *ran and failed*. A real assertion failure during an outage is still a real assertion failure — report it as a failure and fix it. Treating "an incident was open" as grounds to dismiss a red step would recreate ISS-0171 / GH #498, where `continue-on-error` hid genuine failures for months. The status check is there to sharpen attribution, never to launder a defect.

CI publishes this same signal automatically: the `Platform status` job and a diagnostic pre-flight step in the `Build and unit tests` job both emit a `::warning::` annotation naming the incident and write a section to the run's step summary. Both are diagnostic only and cannot fail or pass any job. Read them — but still run the check yourself when reporting, because during a webhook-throttling outage those jobs are themselves liable to be cancelled.

Checking the job list is not enough. On 2026-08-06 the `Source linters` job reported `success` through the GitHub API while its own log contained `##[error]Process completed with exit code 1`, because the failing step was `continue-on-error`. A green check meant nothing had been verified.

This directive exists because the opposite happened repeatedly: agents told the maintainer that red workflows were fine, without checking anything, until the maintainer pushed back. "In this project every second workflow fails but agents say me that it is OK" is a bug report about agent behaviour, and this is the fix. If you cannot determine the cause, say that you could not determine it — never that it is fine.

---

## ⛔ File Placement Rules

Agent-created files MUST go in the correct directory. **Never create working files in the project root.**

| File type | Directory |
|---|---|
| Inner reports | `docs/issue-reports/` |
| Test reports | `docs/test-reports/` |
| Handoff files | `handoffs/<RUN-ID>/` |
| Handoff registry | `handoffs/registry.json` |
| Design artefacts | `src/design/` |
| Test specs | `tests/specs/` |
| Test run reports | `tests/reports/` |
| Requirement status | `docs/status/` |
| Release decisions | `docs/status/` |
| Scratch scripts, one-off test files, temp output | `scratch/` (git-ignored) |

**Scratch rule:** Any file that is not a permanent project artefact — one-off Python scripts, debug `.txt` dumps, `.tmp` files, intermediate `.exe`/`.pdb` build outputs — goes in `scratch/`. Never place these in the project root, `src/`, `tests/`, or any other tracked directory. The `scratch/` directory is git-ignored; nothing in it is committed.

**Scratch enforcement (hard rule — applies to every agent, every step):**

The following file types MUST always be written to `scratch/` and nowhere else:

| File type | Examples |
|---|---|
| One-off Python scripts | `_create_*.py`, `_test_*.py`, `_fix_*.py`, `check_*.py`, `verify_*.py` |
| One-off PowerShell scripts | `_run_*.ps1`, `start-*.ps1` (unless it is a committed project tool) |
| Log files from test runs or builds | `*.log`, `*-test-result.log`, `*-final.log` |
| Debug JSON / text dumps | `curl_out.txt`, `*-output.txt`, `min-body.json` |
| Compiler build artefacts | `*.pdb`, `*.exe` outside `zig-out/` |
| Stray SQL backups / snapshots | `original_*.sql`, `migration-*-old.sql` |
| Any file you would not commit to `main` | if in doubt → `scratch/` |

**Workflow artifacts are committed to git (mandatory).** The following directories are tracked in the repository and must be committed at the end of every workflow step that produces or modifies files in them:

| Directory | Must commit |
|---|---|
| `handoffs/` | After every step that creates or updates a handoff file |
| `handoffs/registry.json` | After every routing decision |
| `handoffs/orchestrator.log` | After every log append |
| `docs/issue-reports/` | After every ISSUE-FIXER step that writes a report |
| `docs/issues/` | After every ISS-*.json create/update |
| `src/design/` | After every CODE-DESIGNER step |

These files are the audit trail of the project. Leaving them uncommitted means losing the record of what was done and why.

**Before completing any handoff, run this self-check:**
- Is any new file sitting in the project root that is not `build.zig`, `build.zig.zon`, `CLAUDE.md`, `CHANGELOG.md`, `README.md`, `docker-compose.yml`, `.gitignore`, `.env.example`, or `start-backend.ps1`? → Move it to the correct directory or `scratch/` immediately.
- Did I write a `.log` file anywhere other than `scratch/`? → Move it.
- Did I write a one-off `.py` or `.ps1` script anywhere other than `scratch/`? → Move it.
- Did I create or update any file in `handoffs/`, `docs/issue-reports/`, `docs/issues/`, or `src/design/`? → Stage and commit it before completing the handoff.

**Forbidden:** Leaving any scratch file in the project root. If the file cannot go in a tracked directory and is not one of the permanent root files listed above, it belongs in `scratch/`.

---

## ⛔ Bookkeeping Is Not Optional (applies to ALL agents)

> **Canonical source for handoff mechanics: [`docs/agents/shared/HANDOFF_PROTOCOL.md`](../shared/HANDOFF_PROTOCOL.md).**
> That file is shared by every agent under both harnesses (Claude Code `.claude/agents/`, `.github/agents/`, GitHub Copilot `.github/instructions/`). Read it once at session start. If it and this section ever disagree on handoff mechanics, **the shared protocol wins** — and the disagreement is itself a defect worth reporting.

The 2026-08-05 pipeline audit measured every directive in this file against 1963 handoffs. The result was unambiguous: **directives about the work product were followed; directives about recording the work were not** (log 44%→0.4%, registry 3.4%, timestamps 8.6% impossible). The rules below are summarised here because they bind *every* agent — not only ORCH.

**1. `handoffs/orchestrator.log` is append-only.** Every agent that routes, completes, reworks, validates, or merges appends one line. Open it with mode `"a"` — **never** `"w"`, and never rewrite it wholesale.

```python
# The ONLY correct way to write the log, from any agent:
with open("handoffs/orchestrator.log", "a", encoding="utf-8") as f:
    f.write(f"{ts} | {event} | {run_id} | {handoff_id[:8]} | {agent} | {detail}\n")
```

On Windows, **never** use PowerShell `>>` to append to this file — it writes UTF-16 into a UTF-8 file and corrupts the line. (This already happened: `  R O U T E  ` appears 17 times in the historical log.) If you must append from PowerShell, use `Out-File -Encoding utf8 -Append`.

A commit that reduces the line count of `orchestrator.log` is a defect, not a cleanup. On 2026-08-04 a single squash-merge destroyed 1340 lines of audit history (`84fe72e` 1357 lines → `ba8f3b9` 17 lines); `registry.json` lost 714 entries the same way. Both were recoverable only from git blobs.

**2. Read and write handoff JSON with BOM tolerance.** 88 handoff files in this repo carry a UTF-8 BOM, and a bare `json.load(open(f))` raises on every one of them — making those handoffs invisible to whoever reads them.

```python
with open(path, encoding="utf-8-sig") as f:   # utf-8-sig, not utf-8
    handoff = json.load(f)
```

**3. Timestamps come from the clock, never from memory or session context.** Run the command, use its exact output:

```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```

**Prefer `python3 tools/utcnow.py`** — it cannot be silently downgraded to local time.
`(Get-Date).ToString(...)` without `.ToUniversalTime()`, and `datetime.now()` without the
UTC form, both emit **local time labelled `Z`**: identical in shape, wrong by the host's
offset. That is the cause of 149 inverted timestamps in this repo (`lint_handoffs.py` H013).

`completed_at` must never precede `started_at`. 148 handoffs currently violate this — one by 30 hours — which silently corrupts every retrospective built on step durations.

**4. Verify before completing any handoff:**

```bash
python3 tools/lint_handoffs.py
```

Exit 0 is required. This checks schema conformance, timestamp monotonicity, orphaned steps, registry coverage, encoding defects, and log truncation. If it reports a BLOCKER against a file you touched, fix it before completing — the same way you would fix a failing `zig build`.

---

## ⛔ Never Satisfy a Gate by Editing What It Measures

If a gate blocks you, fix the condition it is detecting. **Never make the detector stop reporting.**

Forbidden, regardless of how the task is phrased:
- Renaming or reformatting output tokens so a string-matching gate stops matching.
- Deleting, defaulting, or making unreachable the error path a gate looks for.
- Redirecting diagnostic output away from where the gate reads it.
- Wrapping a failing command so its exit code or output is masked.

This has already happened in this repo. ORCH's benchmark pre-check greps `zig build bench` output for `BPM_DB_URL` / `BENCHMARK_SETUP_ERROR` / `missing`. On 2026-05-30 the ADHOC task was written as *"no BPM_DB_URL/missing/BENCHMARK_SETUP_ERROR token in head output"*, and BACKEND-DEV complied by **renaming the labels** (`tests/bench/bench.zig` `dbUrlSourceLabel`) rather than fixing the environment. `resolveDbUrl` later gained a hardcoded fallback that made its `MissingDbUrl` error unreachable — so the benchmark can no longer report a missing DB URL at all. Nine separate ADHOC runs chased this symptom; none fixed the cause.

**If a gate is wrong, escalate to change the gate's definition** — do not quietly satisfy it. And when writing a gate: prefer an exit code over a string match, because an agent cannot satisfy an exit code by renaming a label.

---

## ⛔ Output File Format Rules

**YAML is the required format for all agent-produced output artefacts.** JSON is only used for handoff files (which agents read/write as structured data via Python/shell). Everything else must be YAML.

| Artefact type | Required format |
|---|---|
| Test run reports (`tests/reports/`) | `.yaml` |
| Requirement status (`docs/status/requirement_status.yaml`) | `.yaml` |
| Release decisions (`docs/status/`) | `.yaml` |
| Inner reports (`docs/issue-reports/`) | `.yaml` |
| Retrospective files (`docs/metrics/retrospectives/`) | `.yaml` |
| Estimation files (`handoffs/<run-id>/estimation.yaml`) | `.yaml` |
| Handoff files (`handoffs/<run-id>/step-*.json`) | `.json` (exception — machine-read by ORCH) |
| Registry (`handoffs/registry.json`) | `.json` (exception — machine-read by ORCH) |

**Forbidden:** Creating `.json` output artefacts where `.yaml` is required above. If a function definition says `.json` for a report or status file, treat that as outdated — write `.yaml`.
