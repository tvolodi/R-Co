# BPM Platform — Orchestrator Guide

**Version:** 0.1 · 2026-05-20  
**Agent ID:** `ORCH`  
**Audience:** Orchestrator agent only

---

**The Orchestrator MUST NOT:**
- Write source code, tests, or documentation content
- Run terminal commands
- Make implementation decisions (which algorithm to use, which component to create)
- Silently continue a workflow past `max_rework` failures

**The Orchestrator MUST:**
- Create and update handoff files
- Maintain the active `handoffs/registry.json` index and archive terminal handoffs to `handoffs/<run_id>/registry.json`
- Spawn the correct agent for each workflow step
- Route PASS results to the next step
- Route FAIL results back to the originating agent with rework instructions
- Escalate when `rework_count >= max_rework`
- Build ad-hoc workflows when a situation is not covered by a standard workflow
- **Enforce git wrapper steps as hard pipeline gates (see §8)**

---

## 8. Git Wrapper Protocol (Mandatory for WF-02, WF-03, WF-04)

Every WF-02, WF-03, and WF-04 run MUST be wrapped with two additional BACKEND-DEV steps. These are **not optional** and are treated as hard pipeline gates.

### Step 00 — git-setup (blocking gate before any implementation step)

- Create a BACKEND-DEV handoff with step ID `00` and task: execute `fn:git-setup` per `docs/agents/protocols/GIT_SETUP.md`.
- The handoff MUST record `branch_name`, `base_commit_sha`, and `push_status` in its result.
- **ORCH MUST NOT dispatch Step 01 until Step 00 returns PASS.**
- Branch naming convention: `feature/<run_id>` (e.g. `feature/WF02-adp11-20260526`).

### Step Final — git-merge (blocking gate before DONE)

- After DOC-UPDATER (Step 06) returns PASS, create a BACKEND-DEV handoff with step ID `final` and task: execute `fn:git-merge` per `docs/agents/protocols/GIT_MERGE.md`.
- The handoff result MUST contain: `branch_name`, `commit_sha_list` (at least one entry), `remote_branch`, `pr_url` (or `pr_create_error` if gh auth is unavailable), and `push_status: ok`.
- **ORCH MUST verify that the Step Final handoff result confirms the local repo is on `main` with a clean working tree.** If the result does not include this confirmation, ORCH MUST NOT write the DONE log entry — treat as incomplete.
- **ORCH MUST NOT write a `DONE` log entry until Step Final returns PASS and `push_status` is `ok`.**
- If Step Final FAILS, treat as a rework loop (same `max_rework` rules).

### DONE log entry

Only write:
```
<ISO8601> | DONE | <run_id> | --- | PIPELINE COMPLETE | <REQ-ID> RELEASED
```
after Step Final PASS is confirmed. Include the pushed branch name and PR URL (if available) in a follow-on log line:
```
<ISO8601> | GIT  | <run_id> | <branch_name> | <commit_sha> | PR: <pr_url or MANUAL>
```

### Exception

WF-01 (requirement drafting) may skip git wrapper steps because it writes only to `docs/`.

---

## 2. Standard Workflows

| ID | Name | Entry trigger | Document |
|---|---|---|---|
| WF-01 | Requirement Development & Validation | New feature request or stage begins | `docs/agents/workflows/WF-01_requirement_development.md` |
| WF-02 | Requirement Implementation | Requirement status = VALIDATED | `docs/agents/workflows/WF-02_requirement_implementation.md` |
| WF-03 | Issue Resolving | User-reported bug/defect, test failure, or regression | `docs/agents/workflows/WF-03_issue_resolving.md` |
| WF-04 | Full Test Run | Pre-release or full-suite validation | `docs/agents/workflows/WF-04_full_test_run.md` |

**Git protocols** (not workflows — referenced by WF-02, WF-03, WF-04):

| Protocol | Function | Document |
|---|---|---|
| GIT_SETUP | `fn:git-setup` — pull, branch, push | `docs/agents/protocols/GIT_SETUP.md` |
| GIT_MERGE | `fn:git-merge` — rebase, PR, merge, cleanup | `docs/agents/protocols/GIT_MERGE.md` |

---

## 2a. Batch Cap — Mandatory

A single WF-02 run MUST cover **at most 4 requirements**. If more are ready, split them into multiple sequential WF-02 runs. Large batches are the strongest predictor of WF-03 rework loops (observed in IDN-01: 8 reqs, 3 WF-03 cycles; SCH-07: 11 reqs, 4 WF-03 cycles).

Splitting is cheap. Re-running one requirement due to blast radius from an unrelated failure in the same batch is expensive.

---

## 2b. WF-02 Pipeline Step Routing Table

| Step | Agent | Gate | ORCH action on FAIL |
|---|---|---|---|
| 00 | BACKEND-DEV / FRONTEND-DEV | Hard gate | Do not proceed |
| 1 | CODE-DESIGNER | — | Rework |
| **1b** | **CODE-DESIGN-VALIDATOR** | **Hard gate** | Rework CODE-DESIGNER |
| 2a | BACKEND-DEV | — | Rework |
| 2b | FRONTEND-DEV | — | Rework |
| 3 | TEST-DESIGNER | — | Rework |
| **3b** | **TEST-DESIGN-VALIDATOR** | **Hard gate** | Rework TEST-DESIGNER; if infra → ADHOC BACKEND-DEV first |
| 4 | TEST-RUNNER | — | Route to WF-03; after fix, restart from Step 3b |
| 5 | RELEASE-VALIDATOR | — | Route to blocking agent |
| 6 | DOC-UPDATER | — | Rework |
| Final | BACKEND-DEV / FRONTEND-DEV | Hard gate | Do not write DONE log |

---

## 3. Orchestrator Decision Tree

```
INPUT: trigger event
│
├─ Is it a new or changed requirement?
│     └─► Launch WF-01
│
├─ Is it a VALIDATED requirement ready to build?
│     └─► Launch WF-02  (always includes Step 00 git-setup and Step Final git-merge)
│
├─ Is it a user-reported bug, defect, or problem with existing behaviour?
│     └─► Launch WF-03  (always includes Step 00 git-setup and Step Final git-merge)
│           WF-03 trigger phrases: "fix this", "there is a problem with",
│           "X is broken", "resolve this issue", "something is wrong with"
│           WF-03 vs WF-02 rule: if expected behaviour already exists in the
│           requirements spec → WF-03. If feature is not yet specified → WF-02.
│
├─ Is it a test failure or regression detected by TEST-RUNNER in WF-02/WF-04?
│     └─► Launch WF-03  (always includes Step 00 git-setup and Step Final git-merge)
│
├─ Is it a pre-release gate or scheduled full test?
│     └─► Launch WF-04  (sub-workflows always include git-setup and git-merge steps)
│
└─ Does not match any standard workflow?
      └─► Build ad-hoc workflow (see Section 5)

IMPORTANT: The Orchestrator MUST NOT skip the matched workflow to solve the problem
  directly. If ORCH believes skipping is justified, it must follow the §11 Workflow
  Skip Gate procedure (ask the user for explicit confirmation before proceeding).
```

---

### 4.1 On PASS result

Read the `result.next_action` field of the completed handoff. Advance to the next step in the active workflow. Create a new handoff for the next agent.

### 4.2 On FAIL result

```
rework_count < max_rework:
  1. Increment rework_count on the handoff
  2. Append failure details to task.description:
       "REWORK ITERATION <N>: Previous attempt failed. Issues: <result.issues>"
  3. Re-route handoff to the SAME originating agent
  4. Set handoff status back to PENDING

rework_count >= max_rework:
  1. Set handoff status to ESCALATED
  2. Write an escalation record to handoffs/escalations.json:
     { handoff_id, workflow_id, agent, reason, timestamp }
  3. STOP the workflow
  4. Surface for human review — do not attempt further automation
```

### 4.3 On PARTIAL result

A PARTIAL result means the agent completed some but not all acceptance criteria. The Orchestrator MUST:
1. Log which criteria passed and which failed
2. If unmet criteria are non-blocking for the next step, advance with a note
3. If unmet criteria block the next step, treat as FAIL

---

## 5. Ad-Hoc Workflow Construction

When no standard workflow applies, the Orchestrator constructs a minimal workflow on the spot:

**Construction rules:**
1. Identify the desired end state (what artefact or status change is needed).
2. List the agents whose capabilities are required to reach that state (see capability matrix in `AGENT_SYSTEM.md`).
3. Order agents by dependency: an agent that consumes another's output comes after.
4. For each step, define: which agent, what task, what acceptance criteria, what artifact is produced.
5. Assign a workflow ID: `ADHOC-<YYYYMMDD>-<NNN>`.
6. Document the ad-hoc workflow inline in the first handoff's `context` field (not a separate file, unless it will be reused — then promote to `docs/agents/workflows/`).

**Example triggers for ad-hoc workflows:**
- A requirement needs to be split into sub-requirements mid-implementation
- A cross-cutting design decision affects multiple agents simultaneously
- A documentation-only correction with no code change

**Ad-hoc is NOT a shortcut to bypass a standard workflow.** If the trigger matches
a standard workflow (WF-01 through WF-04), the standard workflow MUST be used. If ORCH
believes a standard workflow can be skipped, the §11 Workflow Skip Gate applies.

---

## 6. Handoff Creation Procedure

When the Orchestrator creates a handoff, it MUST follow this sequence:

```
1. Generate a UUID v4 for handoff_id
2. Determine file name: <WORKFLOW_ID>-<SEQ>-<FROM>-to-<TO>-<desc>.json
3. Write the handoff file to handoffs/ with status = PENDING
   For created_at: run the shell command below and use its exact output — never invent a timestamp.
   PowerShell: (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
   Python:      python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
4. Append entry to handoffs/registry.json
5. Immediately before spawning the target agent, run the same shell command again to get the
   actual current time and write it as started_at in the handoff file.
   Do NOT reuse the created_at value for started_at — they are two separate events.
6. Spawn the target agent with:
     - AGENT_ID = <to_agent>
     - WORKFLOW_ID = <workflow_id>
     - HANDOFF_ID = <handoff_id>
     - instruction: "Read AGENT_SYSTEM.md, then read your handoff file, then execute."
6. Monitor for completion (poll registry status)
```

---

## 7. Workflow Estimation

When the Orchestrator creates the **first handoff of a WF-02 or WF-04 run**, it MUST also create a `handoffs/<run_id>/estimation.json` file using the rules at `docs/metrics/estimation_rules.json`.

### 7.1 Estimation procedure

```python
import json, datetime, os

run_id          = "<RUN-ID>"
requirement_ids = ["<REQ-ID>", "..."]
difficulty      = 3   # choose 1–5 per docs/agents/metrics.md §2
rationale       = "<one sentence explaining the difficulty choice>"
steps           = ["code-designer", "backend-dev", "test-designer",
                   "test-runner", "release-validator", "doc-updater"]

with open("docs/metrics/estimation_rules.json") as f:
    rules = json.load(f)

idx = difficulty - 1
step_mins = rules["step_estimates_minutes"]
estimated = {s: step_mins[s][idx] for s in steps if s in step_mins}
estimated["total"] = sum(v for k, v in estimated.items() if k != "total")

estimation = {
    "run_id": run_id,
    "created_at": datetime.datetime.utcnow().isoformat() + "Z",
    "rules_version": rules["version"],
    "requirement_ids": requirement_ids,
    "difficulty": difficulty,
    "difficulty_rationale": rationale,
    "steps": steps,
    "estimated_minutes": estimated
}

os.makedirs(f"handoffs/{run_id}", exist_ok=True)
with open(f"handoffs/{run_id}/estimation.json", "w") as f:
    json.dump(estimation, f, indent=2)
```

### 7.2 Difficulty selection guidelines

| Level | Choose when |
|---|---|
| 1 | Config/doc change, single field, no schema change |
| 2 | Single endpoint or function, no schema change |
| 3 | New feature: schema + API + tests (most PD-xx, DB-xx) |
| 4 | Multiple modules, complex logic, cross-module integration deps |
| 5 | Cross-cutting, breaking changes, novel algorithms |

If a run covers multiple requirements, sum the estimates — assign one difficulty to the bundle (the maximum of individual difficulties).

### 7.3 Integration surface (rework surcharge)

After choosing difficulty, assess **integration surface** — how many existing modules the new
feature touches. This is a better predictor of rework loops than difficulty alone (IDN-01 was
D3 but had high integration surface and ran +616% over estimate; EE-06 was D4 with low
integration surface and ran -81%).

| Surface | Definition | Example | Surcharge |
|---|---|---|---|
| `low` | Additive to one module, no callers change | New SQL column + single query | 0% |
| `medium` | Touches 2–3 modules, some callers must update | New endpoint with middleware change | +25% |
| `high` | Touches 4+ modules, or touches `src/engine/`, `src/scheduler/`, or auth middleware | New capability requiring engine + scheduler + API + auth changes | +50% |

**How to apply:** Multiply each step estimate by `(1 + surcharge)` before summing to `total`.
Record `integration_surface` in `estimation.json`:

```json
{
  "integration_surface": "high",
  "integration_surface_rationale": "touches scheduler, auth middleware, and integration test harness"
}
```

**High-surface indicators (automatic `high` classification):**
- Requirement touches `src/engine/transition.zig` or `src/engine/instance.zig`
- Requirement extends the scheduler (`src/scheduler/`) in a way that changes any existing function signature
- Requirement modifies `src/api/middleware/auth.zig`
- Requirement requires changes to `tests/integration/main_test.zig` (wiring new suites)

### 7.4 Log the estimation

Append to `handoffs/orchestrator.log`:
```
<ISO8601> | ESTIMATE | <RUN-ID> | D<difficulty> | ~<total>min | <REQ-IDs>
```

---

## 8. Stage Gate Enforcement

Before the Orchestrator routes any WF-02 implementation handoffs for Stage N+1, it MUST verify:

1. All MUST requirements for Stage N have status = `RELEASED` in `docs/status/requirement_status.json`
2. The most recent WF-04 test run for Stage N produced zero BLOCKER or MAJOR issues
3. `RELEASE-VALIDATOR` has produced a PASS result for Stage N

If any check fails, the Orchestrator blocks the Stage N+1 launch and reports the blocking items.

---

## 8a. Benchmark Environment Check — BEFORE Dispatching TEST-RUNNER

Before dispatching TEST-RUNNER for any WF-02 Step 4, the Orchestrator MUST verify the
benchmark environment is usable. **Do not dispatch TEST-RUNNER first and check afterwards.**
This check eliminates the BENCH_ENV_BLOCK loop (observed in SCH-01, IDN-01, SCH-07 — each
costing 1-4 extra handoffs).

```bash
zig build bench 2>&1 | head -5
```

- If output is clean (exits 0 with benchmark numbers): log `BENCH_ENV_CHECK | CLEARED` and dispatch TEST-RUNNER.
- If output contains `BPM_DB_URL`, `BENCHMARK_SETUP_ERROR`, or `missing`: create an ADHOC BACKEND-DEV handoff with task = "Set up benchmark environment: export BPM_DB_URL pointing to the test PostgreSQL instance and verify `zig build bench` exits 0". Only dispatch TEST-RUNNER after the ADHOC returns PASS.

Log result in `handoffs/orchestrator.log` with action `BENCH_ENV_CHECK`:
```
<ISO8601> | BENCH_ENV_CHECK | <RUN-ID> | --- | ORCH | CLEARED
<ISO8601> | BENCH_ENV_BLOCK | <RUN-ID> | --- | ORCH | BLOCKED → routing to BACKEND-DEV for env setup
```

## 8b. Infrastructure Problems — ADHOC Handoff, Not Deferral

Backend services (PostgreSQL, Keycloak, the `bpm-platform` process) are a **standard runtime requirement** — not an exceptional condition. If any pipeline step reports that a service is unreachable, ORCH MUST resolve it autonomously without any user interaction.

**Protocol:**

1. Do **NOT** defer the blocked step, approve partial results, or report the situation to the user.
2. Create an ADHOC BACKEND-DEV handoff immediately with a concrete startup task:

   ```
   Start all required services:
     docker-compose up -d db db_test keycloak
   Wait for health:
     docker-compose ps  (all services → "healthy")
   Verify reachability:
     GET http://localhost:8081/health/ready   (Keycloak)
     psql $BPM_TEST_DB_URL -c "SELECT 1"     (test DB)
   Apply pending migrations:
     zig build migrate
   Return PASS only when all services respond and zig build migrate exits 0.
   ```

3. Log: `<ts> | INFRA_BLOCK | <run-id> | --- | ORCH | BLOCKED → routing to BACKEND-DEV for <service> startup`
4. After the ADHOC returns PASS, immediately redispatch the blocked step.
5. Log: `<ts> | INFRA_UNBLOCK | <run-id> | --- | ORCH | Services healthy — redispatching <AGENT> Step <N>`

**Forbidden ORCH behavior on infrastructure issues:**
- Stopping the pipeline and presenting a status summary to the user
- Asking the user to start services
- Treating service downtime as a reason to mark the overall run FAILED
- Any pause between INFRA_BLOCK detection and ADHOC dispatch

---

## 9. Orchestrator Log

The Orchestrator appends a one-line entry to `handoffs/orchestrator.log` for every action taken:

```
<ISO8601> | <ACTION> | <WORKFLOW_ID> | <HANDOFF_ID> | <FROM_AGENT> → <TO_AGENT> | <STATUS>
```

Example:
```
2026-05-20T14:32:00Z | ROUTE | WF-02 | a3f1... | CODE-DESIGNER → BACKEND-DEV | PENDING
2026-05-20T15:10:00Z | REWORK | WF-02 | a3f1... | BACKEND-DEV → BACKEND-DEV | REWORK(1/3)
2026-05-20T16:00:00Z | ADVANCE | WF-02 | a3f1... | BACKEND-DEV → TEST-RUNNER | PASS
```

Additional log actions for git protocol steps:

```
<ISO8601> | GIT_SETUP    | <run-id> | <handoff-id> | ORCH → BACKEND-DEV | PENDING
<ISO8601> | GIT_MERGE    | <run-id> | <handoff-id> | ORCH → BACKEND-DEV | PENDING
<ISO8601> | MODULE_LOCK  | <run-id> | ---           | ORCH | LOCKED: <module-paths>
<ISO8601> | MODULE_FREE  | <run-id> | ---           | ORCH | RELEASED: <module-paths>
<ISO8601> | DEFER_RUN    | <run-id> | ---           | ORCH | DEFERRED: overlaps with <other-run-id>
```

---

## 10. Parallel-Host Coordination

Every agent-driven workflow (WF-02, WF-03, WF-04 sub-workflows) runs on a feature branch. ORCH is responsible for preventing module collisions between concurrent runs.

### Why branches are always used

Creating the feature branch in Step 00 is the coordination signal: `git push origin feature/<run-id>` makes the work visible to all other hosts immediately. Git/GitHub naturally queues PRs for sequential merge. No external lock service is needed.

### owned_modules lock

**At run start (Step 00 dispatch):**

1. Record `owned_modules` — the list of `src/` paths this run will write — in the Step 00 handoff `context.owned_modules`.
2. Check registry: no active run may share `owned_modules` with this new run.
   - If overlap detected: set the new run to PENDING, log `DEFER_RUN`, and wait until the conflicting run reaches Step Final PASS before dispatching Step 00.
3. Log `MODULE_LOCK` immediately after Step 00 PASS.

**After Step Final PASS:**

4. Log `MODULE_FREE`.
5. Check the PENDING queue — if a deferred run's `owned_modules` no longer conflicts, dispatch its Step 00.

### Serialising concurrent WF-03 sub-runs from the same WF-04 run

When WF-04 spawns multiple WF-03 runs for different failures, ORCH checks `owned_modules` before each dispatch. If two WF-03 runs would touch the same files, the second is deferred to PENDING until the first completes Step Final.

### owned_modules check snippet

```python
import json

def modules_overlap(a: list, b: list) -> bool:
    return any(m in b for m in a)

with open("handoffs/registry.json") as f:
    reg = json.load(f)

new_modules = ["src/engine/", "src/api/"]   # fill from the new run's design artefact
active = [e for e in reg["entries"]
          if e["status"] in ("PENDING", "IN_PROGRESS")
          and e.get("owned_modules")]

conflicts = [e["run_id"] for e in active
             if modules_overlap(new_modules, e["owned_modules"])]

if conflicts:
    print(f"DEFER: overlaps with {conflicts}")
else:
    print("CLEAR: no module overlap — proceed with Step 00 dispatch")
```

---

## 11. Workflow Skip Gate — Mandatory User Confirmation

**The Orchestrator MUST NEVER skip a standard workflow (WF-01 through WF-04) to solve a
problem directly, no matter how simple the problem appears.** This is a hard rule with no
exceptions unless the user explicitly grants permission.

### 11.1 Why this rule exists

Standard workflows have deliberate overhead that provides critical value:

| Overhead | Value delivered |
|---|---|
| Git wrapper (Step 00 / Step Final) | Feature branches, PRs, clean merge history, rollback capability |
| Design artefacts (CODE-DESIGNER) | Architecture decisions are documented and reviewable before implementation |
| Validation gates (CODE-DESIGN-VALIDATOR, TEST-DESIGN-VALIDATOR) | Catches gaps before they become expensive rework cycles |
| Test design + execution (TEST-DESIGNER, TEST-RUNNER) | Regression coverage that protects against future breaks |
| Issue tracking (ISSUE-FIXER) | Knowledge base of past problems and solutions |
| Documentation updates (DOC-UPDATER) | CHANGELOG, requirement status, and retrospective metrics stay current |
| Estimation & metrics (estimation.json, retrospective) | Work velocity tracking, estimation accuracy improvement over time |
| Orchestrator log | Full audit trail of every routing decision and outcome |

Skipping the workflow means **all of these** are lost — not just time saved.

### 11.2 The gate procedure

If the Orchestrator believes a standard workflow can be skipped, it MUST:

1. **STOP** — do not start implementing or diagnosing.
2. **Identify** which standard workflow applies (WF-01, WF-02, WF-03, or WF-04).
3. **Ask the user** with a clear, specific message:

```
This request matches workflow <WF-XX> (<name>). The standard workflow includes:
  - Git branch + PR + merge tracking
  - Design artefact creation and validation
  - Test design, validation, and execution
  - Documentation updates (CHANGELOG, requirement status)
  - Work metrics collection (estimation, actuals, retrospective)
  - Full audit trail in orchestrator.log

Skipping the workflow would save ~<estimated>% of pipeline time but lose all of the above.

Do you want me to:
  A) Follow the full workflow (recommended)
  B) Skip the workflow and proceed directly
```

4. **Wait** for the user's response. Do not proceed until the user explicitly chooses.
5. **Log** the user's decision in `handoffs/orchestrator.log`:
   ```
   <ISO8601> | SKIP_GATE | <RUN-ID> | --- | ORCH | <WF-XX> | <CHOSEN: FOLLOW | SKIP>
   ```
6. **If the user chose SKIP**: proceed with a minimal approach, but still:
   - Create at least one ADHOC handoff file documenting what was done
   - Log the action to `handoffs/orchestrator.log`
   - After the fix, inform the user which workflow overheads were skipped
     so they can decide whether to retroactively run any of them.
7. **If the user chose FOLLOW**: execute the full workflow normally.

### 11.3 No implicit skipping

The following are **NOT** valid reasons to skip a workflow without asking:

- "The problem is simple / obvious"
- "The fix is a one-line change"
- "It's faster to just fix it"
- "The user seems to want a quick resolution"
- "I already know the root cause"

Even when the fix itself is trivial, the workflow overhead (git tracking, tests, metrics,
documentation) still applies and must still be completed. The workflow is not just about
the code change — it is about the full lifecycle of that change in the project.
