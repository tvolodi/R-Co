# WF-05 — UAT Run

**Version:** 1.0 · 2026-06-04  
**Trigger:** After a WF-02 or WF-04 run completes with all technical tests
passing, OR on-demand when the business owner requests UAT validation.  
**Owner:** ORCH

---

## 1. Purpose

WF-05 executes the business acceptance test suite. It answers the question
_"does the system do what the business expects?"_ in language a business
owner can read and act on.

WF-05 is explicitly separate from WF-04 (Full Technical Test Run) because:

- **Different vocabulary.** WF-04 talks about unit tests, compile errors, and
  NFR benchmarks. WF-05 talks about approval flows, SLA breaches, and
  wrong actors receiving tasks.
- **Different authority.** WF-04 is owned by engineering. WF-05 speaks for
  the business owner. Its scenarios are written and approved by business
  stakeholders, not by developers.
- **Different failure routing.** A WF-04 failure routes to BACKEND-DEV or
  FRONTEND-DEV for a code fix. A WF-05 BLOCKER failure may also route to
  REQ-ANALYST if the expectation itself turns out to be underspecified.

---

## 2. Prerequisites

Before ORCH dispatches WF-05:

1. The current `main` branch has passed WF-04 (all unit, integration, E2E,
   and NFR checks green).
2. `tests/simulation/scenarios/` contains at least one `.yaml` scenario file.
3. The system is running (backend + Keycloak + database) and reachable.
4. Seed data has been applied: `python tests/simulation/seed.py` exited 0.

ORCH MUST verify items 1 and 2 before dispatching Step 1. Items 3 and 4 are
verified by UAT-RUNNER itself in its pre-flight check (Step 1).

---

## 3. Pipeline

| Step | Agent | Gate | Description |
|---|---|---|---|
| **00** | `BACKEND-DEV` | Hard gate | `fn:git-setup` — create feature branch (if UAT results in fixes) |
| **1** | `UAT-RUNNER` | — | Pre-flight + scenario execution + UAT report |
| **2a-sr** | `BO-SWIFTROUTE` | — | Domain sign-off: SwiftRoute scenarios + authored fixes if needed |
| **2a-vx** | `BO-VORTEX` | — | Domain sign-off: Vortex scenarios + authored fixes if needed |
| **2a-mc** | `BO-MERIDIAN` | — | Domain sign-off: Meridian scenarios + quorum vote |
| **2b** | `PRODUCT-OWNER` | **Hard gate** | Cross-tenant coherence + MUST coverage + final release recommendation |
| **2c** | `ORCH` | Routing gate | APPROVED → Step 3; BLOCKED → file each issue + forward to the global queue, record in the report, then Step 3 (which gates the release on them) |
| **3** | `RELEASE-VALIDATOR` | — | NFR + UAT combined sign-off check |
| **4** | `DOC-UPDATER` | — | Update requirement status + changelog; mark UAT-verified requirements |
| **Final** | `BACKEND-DEV` | Hard gate | `fn:git-merge` — PR, squash-merge, cleanup |

> **Steps 2a-sr, 2a-vx, 2a-mc run in parallel.** ORCH dispatches all three BO
> agents simultaneously after Step 1 completes. Step 2b (PRODUCT-OWNER) waits
> for all three sign-offs before running.

> **Note on Step 00:** Step 00 is only required if UAT failures will result in
> code changes (the common case). If WF-05 is run purely as a verification
> pass with no expected changes (e.g. a scheduled UAT run against main), ORCH
> may skip Step 00 with a log entry: `SKIP-GIT | WF05 read-only UAT run`.

---

## 4. Step-by-step

### Step 00 — Git setup (BACKEND-DEV, `fn:git-setup`)

Standard git setup. Branch name: `feature/<run_id>` (e.g. `feature/WF05-uat-stage3`).

Required when the run will commit UAT reports and sign-off artifacts (the normal case).
Log the skip explicitly if omitted for a purely read-only run.

WF-05 does **not** fix what it finds: every BLOCKER/MAJOR issue is filed and forwarded to
the global queue per `docs/agents/protocols/ISSUE_QUEUE.md`, and fixed later in its own
WF-03 run. This branch carries reports and sign-offs, not fixes. Do **not** create a
`handoffs/<run_id>/issue_queue.json` — per-run issue queues were removed on 2026-08-06.

---

### Step 1 — UAT execution (UAT-RUNNER)

Handoff task:
```json
{
  "description": "Execute all UAT scenarios under tests/simulation/scenarios/. Evaluate each outcome against business expectations. Produce a UAT report in tests/uat-reports/.",
  "acceptance_criteria": [
    "Pre-flight check passes (backend + Keycloak + seed data present)",
    "Every scenario file in tests/simulation/scenarios/ is executed or skipped with justification",
    "UAT report written to tests/uat-reports/uat-<date>-<run_id>.yaml",
    "Report uses business language throughout — no stack traces, no line numbers",
    "Every FAIL issue has a severity (BLOCKER|MAJOR|MINOR) and a suggested_action"
  ],
  "functions_to_call": [
    "fn:run-uat-scenarios",
    "fn:write-uat-report",
    "fn:register-inner-report",
    "fn:complete-handoff"
  ]
}
```

UAT-RUNNER result determines Step 2 routing:
- `PASS` → proceed to Step 3
- `FAIL` (any BLOCKER or MAJOR) → ORCH files each failing scenario's issue and forwards
  it to the global queue, then proceeds to Step 3 with the failures recorded (see Step 2)
- `PARTIAL` → same handling per severity; MINORs are logged only

---

### Step 2 — ORCH routing gate

ORCH reads `tests/uat-reports/uat-<date>-<run_id>.yaml` and:

```python
import subprocess, yaml

with open(f"tests/uat-reports/uat-{date}-{run_id}.yaml") as f:
    report = yaml.safe_load(f)

blockers = [i for i in report.get("issues", []) if i["severity"] == "BLOCKER"]
majors   = [i for i in report.get("issues", []) if i["severity"] == "MAJOR"]
minors   = [i for i in report.get("issues", []) if i["severity"] == "MINOR"]

# File one issue per distinct affected_process and FORWARD it to the global queue.
# Each still needs its ISS file + GitHub issue first (fn:register-issue) - unchanged.
for proc in {i["affected_process"] for i in blockers + majors}:
    # fn:register-issue -> docs/issues/ISS-NNNN.json + gh issue create
    subprocess.run(["python3", "tools/queue_add.py", "ISS-NNNN",
                    "--severity", "BLOCKER",
                    "--title", f"UAT failure in {proc}",
                    "--github-issue", "<url>"])

# WF-05 does NOT stop to fix these and does NOT re-run UAT-RUNNER.
# It proceeds to Step 3 carrying the findings; the release decision there is still
# BLOCKED while any BLOCKER is open.
```

**No UAT re-run loop.** WF-05 runs its scenarios once. Fixes for what it finds happen in
their own WF-03 runs later; the *next* WF-05 run verifies them. This is what removing the
in-run drain loop means for UAT: a WF-05 run reports the business's verdict on the system
as it is now, rather than iterating until the verdict is favourable.

ORCH log entries:
```
<ts> | UAT_PASS | <run_id> | --- | ORCH | All scenarios passed → routing to RELEASE-VALIDATOR
<ts> | UAT_FAIL | <run_id> | --- | ORCH | <n> BLOCKER/MAJOR issues → forwarded to global queue
```

---

### Step 3 — Release sign-off (RELEASE-VALIDATOR)

RELEASE-VALIDATOR runs its standard NFR check AND reads the UAT report to
confirm no UAT BLOCKER/MAJOR issues remain. It adds a `uat_evidence` field
to the release decision:

```yaml
uat_evidence:
  report_ref: tests/uat-reports/uat-<date>-<run_id>.yaml
  scenarios_passed: <n>
  scenarios_total: <n>
  uat_verdict: PASS
```

If UAT report shows any open BLOCKER: RELEASE-VALIDATOR returns FAIL even if
all NFRs pass.

---

### Step 4 — Documentation (DOC-UPDATER)

In addition to the standard changelog and requirement status updates,
DOC-UPDATER:

1. Marks all successfully UAT-verified requirements with status `UAT-VERIFIED`
   in `docs/status/requirement_status.yaml` (in addition to `TESTED`/`RELEASED`).
2. Appends a UAT summary section to `CHANGELOG.md` under the relevant version:
   ```markdown
   ### UAT — <date>
   - Scenarios executed: N
   - Companies tested: SwiftRoute, Vortex, Meridian
   - All business process expectations met
   ```

---

### Step Final — Git merge (BACKEND-DEV, `fn:git-merge`)

Standard squash merge. Only required if Step 00 ran. If Step 00 was skipped (read-only UAT
run producing no committed artifacts), Step Final is also skipped.

**Runs exactly once**, directly after Step 4. There is no queue check between them. The
branch carries this run's UAT reports, BO sign-offs, and requirement-status updates — not
fixes for the issues the run found; those were forwarded to the global queue. List every
forwarded `ISS-NNNN` in the PR body.

Log: `<ts> | SKIP-FINAL | WF05 | --- | ORCH | Read-only UAT run — no merge needed`

---

## 5. Trigger recognition

ORCH launches WF-05 when:

1. **Explicit user request:** "run UAT", "run acceptance tests", "check business
   scenarios", "validate against business expectations", "UAT run"
2. **Automatic post-WF-02:** After a WF-02 run completes with all tests green
   AND the affected process has scenario files in `tests/simulation/scenarios/`
3. **Scheduled:** A periodic UAT run on the main branch (not yet implemented —
   see future work)

WF-05 vs WF-04 rule:
- If the question is _"does the code work?"_ → WF-04
- If the question is _"does the system do what the business expects?"_ → WF-05
- Both questions are asked at every release — WF-04 first, WF-05 second

---

## 6. Batch cap

No batch cap. UAT-RUNNER runs all available scenarios in a single step.
If the scenario suite grows beyond ~20 scenarios, ORCH may split by company:
one WF-05 run per company, all dispatched in parallel.

---

## 7. ORCH forbidden actions in WF-05

- Marking a UAT issue as MINOR to avoid filing and forwarding it
- Treating "the issue was forwarded to the queue" as grounds to call a BLOCKED release APPROVED
- Skipping UAT-RUNNER because "the technical tests already passed"
- Editing scenario YAML files to lower expectations and make scenarios pass
- Treating a UAT PARTIAL result as a PASS without reading the per-outcome details

---

## 8. Future work

- **Scheduled UAT runs:** A nightly ORCH cron that runs WF-05 against `main`
  without requiring a manual trigger
- **Business owner notification:** After UAT-RUNNER completes, send the UAT
  report summary to a configured webhook (email / Slack)
- **Scenario authoring workflow:** A WF-06 (Scenario Development) that takes a
  business owner's natural-language description of a new scenario and produces
  the scenario YAML via ORCH → REQ-ANALYST → scenario file
