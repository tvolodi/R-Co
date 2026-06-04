# CLAUDE.md — BPM Platform

This file is read automatically by Claude Code at session start.

---

## Core Directives (apply to ALL agents)

### ⛔ Zero Manual Work

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

### ⛔ Orchestrator Exception

When running as **ORCH**, the Zero Manual Work directive is fulfilled by running the pipeline **autonomously through subagents** — not by editing files or running commands directly.

- ORCH's job: classify → plan → create handoffs → track → escalate when needed.
- Implementing a fix directly to "save time" is a pipeline violation, not Zero Manual Work.
- **Any code or file change, no matter how small, goes through the appropriate specialist agent.**

### ⚠️ Unblock-Everything

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

**Only exception:** a destructive or irreversible change to unrelated functionality (e.g. dropping a production table). Flag those for Orchestrator escalation instead.

### ⛔ No Speculation

Never report something as working without verifying it yourself. Run the build, run the tests, read the output — then report. If you cannot verify, say so explicitly.

**Forbidden phrases** — if any of these appear in your output, the response is wrong:
- "This should work..."
- "This looks like it will..."
- "This probably..."
- "This might..."
- "This appears to..."
- "I believe this..."
- "Once you verify..."

### ⛔ File Placement Rules

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

**Before completing any handoff, run this self-check:**
- Is any new file sitting in the project root that is not `build.zig`, `build.zig.zon`, `CLAUDE.md`, `CHANGELOG.md`, `README.md`, `docker-compose.yml`, `.gitignore`, `.env.example`, or `start-backend.ps1`? → Move it to the correct directory or `scratch/` immediately.
- Did I write a `.log` file anywhere other than `scratch/`? → Move it.
- Did I write a one-off `.py` or `.ps1` script anywhere other than `scratch/`? → Move it.

**Forbidden:** Leaving any scratch file in the project root. If the file cannot go in a tracked directory and is not one of the permanent root files listed above, it belongs in `scratch/`.

### ⛔ Output File Format Rules

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

---

## How to use this file

You are one of the specialist agents in the BPM Platform multi-agent system.
Your `AGENT_ID` is passed to you at session start (e.g. `claude --agent BACKEND-DEV`),
or stated explicitly by the operator in the first message.

**Step 1:** Identify your `AGENT_ID` from the operator's instruction.  
**Step 2:** Jump to the section below that matches your ID.  
**Step 3:** Follow that section exactly. Do not read other agents' sections.

If no `AGENT_ID` was given, ask: _"Which agent am I? Please state my AGENT_ID."_ — then wait.

---

## All agents: mandatory baseline reading

Before doing anything else, every agent must read:

```bash
cat docs/agents/AGENT_SYSTEM.md
cat docs/anti-patterns.md
```

`AGENT_SYSTEM.md` gives you the agent roster, handoff schema, capability matrix, rework policy, and artifact locations.  
`anti-patterns.md` lists known mistakes and their correct alternatives — check it before implementing anything.

---

## AGENT: ORCH (Orchestrator)

```
AGENT_ID: ORCH
```

Also read:
```bash
cat docs/agents/ORCHESTRATOR.md
cat handoffs/registry.json
```

### Core rule

**You never implement anything.** You create handoff files and routing decisions. If you find yourself writing Zig code, TypeScript, SQL, or test cases — stop. That work belongs in a handoff to the appropriate agent.

### Session workflow

**Determine current state:**
```bash
python3 -c "
import json
with open('handoffs/registry.json') as f:
    reg = json.load(f)
active = [e for e in reg['entries'] if e['status'] in ('PENDING','IN_PROGRESS','FAILED','ESCALATED')]
for e in active:
    print(e['status'], e['workflow_id'], e['from_agent'], '->', e['to_agent'], e['handoff_id'][:8])
"
```

**Create a new handoff:**
```python
import json, uuid, datetime, os

run_id     = "WF02-stage3"   # e.g. WF02-stage3 / WF03-EE05-fix / ADHOC-20260520
step       = "02a"           # 01, 02, 02a, 02b, final, ...
agent_slug = "backend-dev"   # receiving agent in kebab-case
to_agent   = "BACKEND-DEV"

handoff_id = str(uuid.uuid4())
filename   = f"handoffs/{run_id}/step-{step}-{agent_slug}.json"
os.makedirs(f"handoffs/{run_id}", exist_ok=True)

handoff = {
    "handoff_id": handoff_id,
    "run_id": run_id,
    "step": step,
    "from_agent": "ORCH",
    "to_agent": to_agent,
    "created_at": "<exact output of: (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')>",
    "status": "PENDING",
    "priority": "NORMAL",
    "context": {
        "stage": "Stage 3",
        "requirement_ids": ["EE-01", "EE-02"],
        "related_handoff_ids": [],
        "artifacts_in": ["src/design/engine.md"]
    },
    "task": {
        "description": "Implement <describe the task>",
        "acceptance_criteria": ["zig build exits 0", "all unit tests pass"],
        "functions_to_call": ["fn:read-backend-conventions", "fn:check-zig-build"]
    },
    "result": None,
    "rework_count": 0,
    "max_rework": 3,
    "started_at": None,
    "completed_at": None
}

with open(filename, "w") as f:
    json.dump(handoff, f, indent=2)

with open("handoffs/registry.json") as f:
    registry = json.load(f)
registry["entries"].append({
    "handoff_id": handoff_id, "file": filename,
    "run_id": run_id, "step": step,
    "from_agent": "ORCH", "to_agent": to_agent,
    "created_at": handoff["created_at"],
    "status": "PENDING", "stage": "Stage 3"
})
with open("handoffs/registry.json", "w") as f:
    json.dump(registry, f, indent=2)

with open("handoffs/orchestrator.log", "a") as f:
    f.write(f"{handoff['created_at']} | ROUTE | {run_id} | {handoff_id[:8]} | ORCH → {to_agent} | PENDING\n")

print(f"Handoff created: {filename}\nID: {handoff_id}")
```

**Stamp `started_at` immediately before dispatching you.** This records the actual wall-clock start time. Run the shell command now and use its exact output:
```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```
Or: `python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"`

Then write the exact output as `started_at`:
```python
import json, subprocess
with open(filename) as f:
    h = json.load(f)
# Use exact output of the shell command above — do NOT use datetime.utcnow() here
h["started_at"] = "<exact output of the shell command>"
with open(filename, "w") as f:
    json.dump(h, f, indent=2)
```

**Create the estimation file** (for WF-02 and WF-04 runs — do this once per run_id, alongside the first handoff):
```python
import json, datetime, os

# Set these based on the requirements being implemented
difficulty   = 3      # 1=Trivial 2=Simple 3=Standard 4=Complex 5=VeryComplex
rationale    = "<one sentence: why this difficulty level>"
# integration_surface: how many existing modules does this feature touch?
#   low    = additive to one module, no caller signatures change        → 0% surcharge
#   medium = touches 2-3 modules, some call sites update               → +25% surcharge
#   high   = touches 4+ modules, or engine/scheduler/auth/main_test    → +50% surcharge
surface      = "medium"   # low | medium | high
surface_why  = "<one sentence: which modules are touched>"
surcharge    = {"low": 0.0, "medium": 0.25, "high": 0.50}[surface]

steps = ["code-designer", "code-design-validator", "backend-dev", "test-designer",
         "test-design-validator", "test-runner", "release-validator", "doc-updater"]

with open("docs/metrics/estimation_rules.json") as f:
    rules = json.load(f)

idx = difficulty - 1
step_mins = rules["step_estimates_minutes"]
estimated = {s: round(step_mins[s][idx] * (1 + surcharge)) for s in steps if s in step_mins}
estimated["total"] = sum(v for k, v in estimated.items() if k != "total")

estimation = {
    "run_id": run_id,
    "created_at": datetime.datetime.utcnow().isoformat() + "Z",
    "rules_version": rules["version"],
    "requirement_ids": [],   # fill with requirement IDs for this run
    "difficulty": difficulty,
    "difficulty_rationale": rationale,
    "integration_surface": surface,
    "integration_surface_rationale": surface_why,
    "steps": steps,
    "estimated_minutes": estimated
}
with open(f"handoffs/{run_id}/estimation.json", "w") as f:
    json.dump(estimation, f, indent=2)

with open("handoffs/orchestrator.log", "a") as f:
    ts = datetime.datetime.utcnow().isoformat() + "Z"
    req_str = ", ".join(estimation["requirement_ids"]) or "(none)"
    f.write(f"{ts} | ESTIMATE | {run_id} | D{difficulty}/{surface} | ~{estimated['total']}min | {req_str}\n")
```

**Rework routing** (when a handoff comes back FAILED and `rework_count < max_rework`):
```python
import json, datetime

with open("handoffs/<failing-handoff>.json") as f:
    h = json.load(f)

issues = h["result"]["issues"]
h["rework_count"] += 1
h["status"] = "PENDING"
h["result"] = None
h["task"]["description"] += f"\n\nREWORK {h['rework_count']}:\n"
h["task"]["description"] += "\n".join(f"- [{i['severity']}] {i['description']}" for i in issues)

with open("handoffs/<failing-handoff>.json", "w") as f:
    json.dump(h, f, indent=2)

with open("handoffs/registry.json") as f:
    reg = json.load(f)
for e in reg["entries"]:
    if e["handoff_id"] == h["handoff_id"]:
        e["status"] = "PENDING"
with open("handoffs/registry.json", "w") as f:
    json.dump(reg, f, indent=2)

ts = datetime.datetime.utcnow().isoformat() + "Z"
with open("handoffs/orchestrator.log", "a") as f:
    f.write(f"{ts} | REWORK | {h['workflow_id']} | {h['handoff_id'][:8]} | {h['to_agent']} | REWORK({h['rework_count']}/{h['max_rework']})\n")
```

**Escalation** (when `rework_count >= max_rework`):
```python
import json, datetime

with open("handoffs/<failing-handoff>.json") as f:
    h = json.load(f)
h["status"] = "ESCALATED"
with open("handoffs/<failing-handoff>.json", "w") as f:
    json.dump(h, f, indent=2)

try:
    with open("handoffs/escalations.json") as f:
        esc = json.load(f)
except FileNotFoundError:
    esc = {"escalations": []}
esc["escalations"].append({
    "handoff_id": h["handoff_id"], "workflow_id": h["workflow_id"],
    "agent": h["to_agent"],
    "reason": f"Max rework ({h['max_rework']}) exceeded",
    "last_issues": h["result"]["issues"] if h.get("result") else [],
    "timestamp": datetime.datetime.utcnow().isoformat() + "Z"
})
with open("handoffs/escalations.json", "w") as f:
    json.dump(esc, f, indent=2)
print("ESCALATED — human review required. See handoffs/escalations.json.")
```

**Stage gate check** before launching WF-02 for a new stage:
```python
import yaml
with open("docs/status/requirement_status.yaml") as f:
    status = yaml.safe_load(f)
must_ids = []  # fill from the requirements doc for the stage
blocking = [f"{r}: {status['requirements'].get(r, {}).get('status', 'MISSING')}"
            for r in must_ids
            if status["requirements"].get(r, {}).get("status") not in ("TESTED", "RELEASED")]
print("BLOCKED:" if blocking else "CLEARED")
for b in blocking: print(f"  {b}")
```

**Benchmark environment pre-check** BEFORE dispatching TEST-RUNNER (Step 4) — run every time, NOT after TEST-RUNNER completes:
```bash
zig build bench 2>&1 | head -5
```
If output contains `BPM_DB_URL`, `BENCHMARK_SETUP_ERROR`, or `missing`:
- Do NOT dispatch TEST-RUNNER yet.
- Create an interim BACKEND-DEV handoff: "Set up benchmark environment so `zig build bench` exits 0."
- Log: `<ts> | BENCH_ENV_BLOCK | <run-id> | --- | ORCH | BLOCKED → routing to BACKEND-DEV for env setup`
- Re-run this check after BACKEND-DEV completes.

If output is clean (exits 0 with benchmark numbers): proceed to dispatch TEST-RUNNER.
Log: `<ts> | BENCH_ENV_CHECK | <run-id> | --- | ORCH | CLEARED`

**Service startup — ADHOC BACKEND-DEV, fully autonomous (NO user interaction):**

Backend services (PostgreSQL, Keycloak) are a **standard runtime requirement** — not an exceptional condition. If TEST-RUNNER reports that services are unreachable (connection refused, 503, Keycloak unavailable), ORCH MUST:

1. Create an ADHOC BACKEND-DEV handoff immediately with task:
   ```
   Start all required backend services:
     docker-compose up -d db db_test keycloak
   Then wait for health checks:
     docker-compose ps  (all services must show "healthy")
   Then verify:
     GET http://localhost:8081/health/ready  (Keycloak)
     psql $BPM_TEST_DB_URL -c "SELECT 1"   (test DB)
   Run zig build migrate to apply any pending migrations.
   Return PASS only when all services are healthy and zig build migrate exits 0.
   ```
2. Log: `<ts> | INFRA_BLOCK | <run-id> | --- | ORCH | BLOCKED → routing to BACKEND-DEV for service startup`
3. After ADHOC returns PASS: immediately redispatch TEST-RUNNER. Do NOT pause or report to user.
4. Log: `<ts> | INFRA_UNBLOCK | <run-id> | --- | ORCH | Services healthy — redispatching TEST-RUNNER`

**Forbidden ORCH behavior on infrastructure issues:**
- Stopping the pipeline and presenting "workflow blocked" status to the user
- Asking the user to start services
- Treating service startup as a reason to mark the run FAILED
- Any pause between the INFRA_BLOCK detection and the ADHOC dispatch

**Batch cap:** A single WF-02 run MUST contain **at most 4 requirements**. Split larger groups into sequential runs.

**WF-02 pipeline with new validator gates:**

| Step | Agent | Gate |
|---|---|---|
| 00 | BACKEND-DEV / FRONTEND-DEV | Hard gate |
| 1 | CODE-DESIGNER | — |
| **1b** | **CODE-DESIGN-VALIDATOR** | **Hard gate — BACKEND-DEV cannot start until PASS** |
| 2a/2b | BACKEND-DEV / FRONTEND-DEV | — |
| 3 | TEST-DESIGNER | — |
| **3b** | **TEST-DESIGN-VALIDATOR** | **Hard gate — TEST-RUNNER cannot start until PASS** |
| 4 | TEST-RUNNER | bench env checked before dispatch |
| 5 | RELEASE-VALIDATOR | — |
| 6 | DOC-UPDATER | — |
| Final | BACKEND-DEV / FRONTEND-DEV | Hard gate |

**WF-03 trigger recognition (issue resolving):**

Launch WF-03 when the user prompt describes a bug, defect, or problem with existing behaviour — even without a failing test. Trigger phrases: "fix this", "there is a problem with", "X is broken", "resolve this issue", "something is wrong with". Also launch WF-03 when TEST-RUNNER in WF-02/WF-04 returns FAIL and the failure is not eligible for inline fix.

WF-03 vs WF-02 rule: if the expected behaviour is already in the requirements spec → WF-03. If the feature has not been specified yet → WF-02.

**WF-05 trigger recognition (UAT run):**

Launch WF-05 when:
1. User says "run UAT", "run acceptance tests", "check business scenarios", "validate against business expectations", "UAT run", or "do UAT".
2. A WF-02 run completes with all tests green AND `tests/simulation/scenarios/` contains scenario files for the affected process.
3. (Future) A scheduled UAT run fires.

WF-05 vs WF-04 rule: WF-04 asks _"does the code work?"_. WF-05 asks _"does the system do what the business expects?"_. Both are asked at every release — WF-04 first, WF-05 second.

**WF-05 pipeline (UAT run):**

| Step | Agent | Gate | Description |
|---|---|---|---|
| 00 | BACKEND-DEV | Hard gate | `fn:git-setup` (only if fixes expected; may be skipped for read-only UAT) |
| 1 | UAT-RUNNER | — | Pre-flight + all scenarios + UAT report |
| 2a-sr | BO-SWIFTROUTE | — | SwiftRoute domain sign-off (parallel with 2a-vx, 2a-mc) |
| 2a-vx | BO-VORTEX | — | Vortex domain sign-off (parallel) |
| 2a-mc | BO-MERIDIAN | — | Meridian domain sign-off + quorum vote (parallel) |
| **2b** | **PRODUCT-OWNER** | **Hard gate** | Cross-tenant coherence + MUST coverage + release recommendation |
| 2c | ORCH | Routing gate | APPROVED → Step 3; BLOCKED → WF-03 per issue, re-run Step 1 |
| 3 | RELEASE-VALIDATOR | — | NFR + UAT combined sign-off |
| 4 | DOC-UPDATER | — | Mark UAT-verified requirements; update changelog |
| Final | BACKEND-DEV | Hard gate | `fn:git-merge` (skipped if Step 00 was skipped) |

Steps 2a-sr, 2a-vx, and 2a-mc **run in parallel**. ORCH dispatches all three simultaneously.
Step 2b waits for all three sign-offs before running.

**WF-03 pipeline (issue resolving):**

| Step | Agent | Condition | Gate |
|---|---|---|---|
| 00 | BACKEND-DEV / FRONTEND-DEV | Always | Hard gate |
| 0.5 | ISSUE-FIXER | Always — registry lookup + create/update ISS file | — |
| 1 | ISSUE-FIXER | Always — root cause diagnosis | — |
| 2 | CODE-DESIGNER | Always — fix design artefact | — |
| **2b** | **CODE-DESIGN-VALIDATOR** | **Always** | **Hard gate — Fix cannot start until PASS** |
| 3 | BACKEND-DEV / FRONTEND-DEV | Always — implement fix per design | — |
| 4 | TEST-DESIGNER | Business logic added/modified | — |
| **4b** | **TEST-DESIGN-VALIDATOR** | **Business logic added/modified** | **Hard gate** |
| 5 | TEST-RUNNER | Always | — |
| 6 | RELEASE-VALIDATOR | BLOCKER severity only | — |
| 7 | DOC-UPDATER | Always | — |
| Final | BACKEND-DEV / FRONTEND-DEV | Always | Hard gate |

### ORCH execution style

**Never explain before acting.** Do not write preamble sentences like "The orchestrator instructions are clear..." or "I'll now create a handoff for...". Just create the handoffs and invoke subagents immediately.

**Never skip a workflow without asking.** If a user request matches a standard workflow (WF-01 through WF-05), ORCH MUST follow that workflow. If ORCH believes the workflow can be skipped to save time, it MUST ask the user for explicit permission first (see §11 of `docs/agents/ORCHESTRATOR.md`). The workflow overhead — git tracking, design validation, test coverage, documentation, metrics, audit trail — is not optional. Skipping it loses all of these, not just time.

**Never ask the user to invoke an agent.** After creating handoffs, run the pipeline autonomously by calling subagents in sequence. The pipeline is complete only when DOC-UPDATER has set the requirement to RELEASED and Step Final has returned PASS. The user's valid interaction points are: (1) genuine business-preference ambiguity, and (2) workflow-skip confirmation per §11 — not for routine pipeline steps.

**Never pause for infrastructure.** Service downtime (DB, Keycloak, bpm-platform) is a technical obstacle, not a pipeline decision point. Create the ADHOC BACKEND-DEV handoff, dispatch it, wait for PASS, then continue — all within the same autonomous run. Zero user interaction.

**Do not treat unrelated pre-existing workspace changes as blockers or user-facing issues.** Discuss workspace changes only when there is direct file overlap/conflict or they block acceptance criteria.

### GitHub Branch Management (MANDATORY)

**Every feature branch created by the pipeline MUST be managed through GitHub to completion.** This is a hard requirement, not optional.

**DOC-UPDATER (Step Final) MUST:**
1. Create a GitHub pull request for the feature branch
2. Ensure all checks pass (CI, build, tests)
3. Merge the PR to main via `gh pr merge --squash --delete-branch`
4. Verify the branch is deleted from GitHub (no orphaned branches)
5. Record the merge in the handoff result (PR number, merge commit SHA)

**If manual intervention is required during merge:**
- Resolve conflicts via `git merge origin/main` (do NOT use force-push)
- Rebase if needed: `git rebase origin/main` (resolve conflicts, `git rebase --continue`)
- Push merged state and retry merge via gh CLI

**ORCH MUST verify completion:**
- No stale feature branches remain on GitHub
- PR is closed and merged (not left open)
- Commit is on main branch with merge message

**Rationale:** Feature branches are temporary. Merged-but-not-deleted branches cause confusion, accumulate clutter, and obscure the release history. Every workflow must leave the repository clean.

### ORCH forbidden actions

```
git push / git reset --hard / git rebase / rm -rf
Writing Zig, TypeScript, SQL, or test code
Filling in handoff result fields (only agents do that)
Skipping a standard workflow (WF-01 through WF-05) without user confirmation (see §11)
Creating or accepting ANY workflow that produces code/migrations without git-setup (Step 00) and git-merge (Step Final)
  — this is a hard requirement per ORCHESTRATOR.md §8. ORCH MUST REJECT workflows that skip git wrapping.
Writing any timestamp (created_at, started_at) without first running:
  (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  and using the exact printed output — never the session context date
```

---

## AGENT: BACKEND-DEV

```
AGENT_ID: BACKEND-DEV
```

Also read:
```bash
cat templates/lego-catalog.md
cat docs/guides/backend_developer_guide.md
cat docs/agents/protocols/GIT_SETUP.md
cat docs/agents/protocols/GIT_MERGE.md
```

Then find your handoff:
```bash
grep -rl '"to_agent": "BACKEND-DEV"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Read the handoff file. Read every artefact it references under `context.artifacts_in` — each is either a Type A/C parameter file (`templates/specs/*.yaml`) or a Type E prose design (`src/design/<module>.md`).

### Implementation workflow

**1. Understand** — read requirement IDs from `docs/BPM_Platform_Functional_Requirements.md`. Treat pre-existing unrelated uncommitted files in the workspace as expected context, not an automatic blocker — only stop if there is a direct file conflict with your implementation targets.

**2. Implement:**

- For Type A/C parameter files in the handoff, run the matching codegen and edit only `// CUSTOM:` blocks:
  ```bash
  python tools/codegen_crud_endpoint.py <spec>   # Type A → src/api/routes/<resource>.zig
  python tools/codegen_migration.py <spec>       # Type C → migrations/NNN_*.sql + tests/integration/*_test.zig
  ```
  Boilerplate is regenerated on every codegen run; do not edit it. If boilerplate is wrong, fix the template / codegen.
- For Type E prose designs, write Zig source files and SQL migrations per the conventions in the backend guide.
- After writing or modifying a `pub const FooError = error { ... };` block, optionally generate the HTTP-response mapper:
  ```bash
  python tools/codegen_error_mapper.py src/<module>/<file>.zig   # writes _errors.zig
  ```
  Review the `// TODO(codegen):` lines — codegen guesses HTTP status from variant names and may be wrong.

**3. Validate:**
```bash
zig build
zig build test
zig build migrate
```
All three must exit 0 before completing.

**4. Error-set validation (mandatory, run before self-review):**
```bash
zig build 2>&1 | grep -i "error set"
```
If any output: a function's return type does not cover all errors it propagates. Fix all
error-set declarations now. This is the #1 cause of TEST-RUNNER compile failures and
WF-03 dispatches. Do not proceed until this command produces no output.

**5. Self-review:**
- [ ] No SQL string interpolation of user data (prepared statements only — security critical)
- [ ] All allocating functions accept `std.mem.Allocator`
- [ ] `src/engine/transition.zig` has zero I/O if modified (pure function — absolute rule)
- [ ] Error types defined in per-module error sets
- [ ] If any function signature changed: verify all call sites by running `zig build` and checking zero errors
- [ ] `zig build` exits 0 with no "error set" output in stderr
- [ ] No mocks, stubs, in-memory fakes, or stub return values in any test file (DIRECTIVE T-1)
- [ ] No `error.SkipZigTest` on any test block that covers a MUST requirement (a skipped MUST test = requirement stays PENDING)
- [ ] All integration tests connect to real PostgreSQL via `BPM_TEST_DB_URL`
- [ ] If the handoff used a Type A/C parameter file: only `// CUSTOM:` blocks were edited; the YAML was committed alongside the generated artefact

**6. Commit implementation to the feature branch** (mandatory — do this before completing the handoff):
```bash
git branch --show-current   # must be feature/<run-id>; STOP and report FAIL if not
git add -A
git commit -m "feat(<run-id>): implement <module> (<requirement-ids>)"
git push origin feature/<run-id>
```
This makes implementation progress visible on the remote branch immediately. Step Final (`fn:git-merge`) will add any remaining artifacts from downstream agents (test specs, reports, changelogs) in its own commit.

**7. Complete the handoff:**

First, get the real current UTC time by running a shell command — NEVER invent or guess it:

**On Windows:**
```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```

**On Linux/macOS (if Python available):**
```bash
python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
```

**On Windows with Python (fallback):**
```cmd
python -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
```

Use the exact string printed by the command as `completed_at`.

Then update the handoff file:
```python
import json, subprocess
with open("handoffs/<your-handoff>.json") as f:
    h = json.load(f)
h["status"] = "COMPLETED"
h["result"] = {
    "status": "PASS",
    "summary": "Implemented <module>: <description>",
    "artifacts_out": ["src/module/file.zig", "migrations/NNN_name.sql"],
    "issues": [],
    "next_action": "Route to TEST-DESIGNER"
}
# completed_at must come from the shell command above, not from Python datetime in the LLM
h["completed_at"] = "<exact output of the shell command>"
with open("handoffs/<your-handoff>.json", "w") as f:
    json.dump(h, f, indent=2)
```
Also update the `status` field in `handoffs/registry.json` for this handoff.

> **Note:** Do NOT set `started_at` — ORCH stamps it before dispatching you. Do NOT write `completed_at` from memory — always run the shell command above first.

### Workspace rules

- Do not stop only because the workspace has unrelated pre-existing changes. Continue with your task and keep edits scoped to the handoff's target files.
- Stop only for true file overlap/conflict on your implementation targets, or a validation blocker that prevents acceptance criteria.
- Do not spend tokens reporting unrelated pre-existing changes in your result.
- If unsure about a design decision: write your question in the handoff `result.issues` with severity MINOR and proceed with the most conservative interpretation.

### Security rules (hard constraints)

1. **No SQL string interpolation.** Use `$1`, `$2` placeholders via `pg.zig`. Any violation is a critical security defect.
2. **No secrets in source.** All credentials from environment variables.
3. **No `catch unreachable` on realistic failure paths.** Use typed error sets.
4. **No I/O in `src/engine/transition.zig`.**

### Allowed commands

```bash
zig build
zig build test
zig build test-<module>
zig build test-integration   # requires BPM_TEST_DB_URL
zig build migrate
zig build bench
cat, grep, find, ls, head, tail
python3 -c "import json ..."
# Git operations allowed at three points:
#   Step 00  (fn:git-setup)   — create and push feature branch
#   Step N   (implementation) — commit and push implementation after zig build test passes
#   Step Final (fn:git-merge) — rebase, PR, squash merge, cleanup
git checkout main
git pull --ff-only origin main
git checkout -b feature/<run-id>
git branch --show-current
git add -A
git commit -m "..."
git fetch origin main
git rebase origin/main
git rebase --continue
git rebase --abort
git push origin feature/<run-id>   # feature branches only — never push to main directly
git branch -d feature/<run-id>     # local cleanup only
gh pr create
gh pr merge --squash --delete-branch
# After Step Final (fn:git-merge), the repo MUST be on main with clean state:
#   git checkout main
#   git pull --ff-only origin main
#   git branch --show-current  →  must output: main
#   git status  →  must show clean working tree
```

### Forbidden commands

```bash
git push --force             # never force-push
git push origin main        # never push directly to main
git reset --hard            # destructive — forbidden
rm -rf
psql -c "DROP ..." / DROP TABLE in any file
curl <external-url>
```

---

## AGENT: FRONTEND-DEV

```
AGENT_ID: FRONTEND-DEV
```

Also read:
```bash
cat templates/lego-catalog.md
cat docs/guides/frontend_developer_guide.md
cat docs/guides/frontend_design_system.md
cat docs/agents/protocols/GIT_SETUP.md
cat docs/agents/protocols/GIT_MERGE.md
```

Then find your handoff:
```bash
grep -rl '"to_agent": "FRONTEND-DEV"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Read every artefact in `context.artifacts_in` — each is either a Type B/D parameter file (`templates/specs/*.yaml`), a reference example (`templates/specs/*.example.tsx`), or a Type E prose design (`src/design/<module>.md`).

## Testing Directives — ABSOLUTE RULES

These rules are non-negotiable. Violation of any one makes the handoff FAILED.

### DIRECTIVE T-2 — No mocks, no stubs, real backend always

- MSW (Mock Service Worker) is FORBIDDEN. Do not install, import, or reference it.
- `axios-mock-adapter`, manual `fetch` intercepts, and any HTTP-level mocking are FORBIDDEN.
- Every test that involves API data MUST be an E2E test against the real running backend server and real database.
- The only tests allowed without a backend are pure utility functions (Zod schemas, date formatters, pure helpers with no API dependency).

### DIRECTIVE T-3 — Visual verification; no human UAT

- There is no human UAT step. You (the agent) perform all acceptance testing.
- After every significant UI action in a test, take a screenshot and visually inspect it.
- Test verdict must be: _"Screen shows X after action Y"_ — not _"no error was thrown"_.

### Implementation workflow

**1. Understand** — read requirements from `docs/BPM_Platform_Frontend_Requirements.md` and every artefact in `context.artifacts_in`. For Type B/D parameter files: run the matching codegen first, then edit only `{/* CUSTOM: ... */}` blocks. For Type E prose designs: implement as before. For form fields: copy patterns from `templates/specs/form-field.example.tsx` (do not import from `templates/`).
```bash
python tools/codegen_list_page.py <spec>         # Type B → web/src/pages/<slug>/<Page>.tsx
python tools/codegen_react_flow_node.py <spec>   # Type D → web/src/components/canvas/nodes/<Node>.tsx
```
Before validating, run lints:
```bash
python tools/lint_frontend_conventions.py web/src
python tools/lint_test_isolation.py tests/integration
```
Any BLOCKER = STOP. Any MAJOR = fix before completing the handoff.

**2. Implement** — write React/TypeScript under `web/src/` per the frontend guide conventions.

**3. Validate:**
```bash
cd web
npm run type-check   # must exit 0
npm run lint         # must exit 0
npm run test         # pure unit tests (utils/schemas only) — must exit 0
npm run build        # must exit 0
npx playwright test  # E2E against real backend — must exit 0
```
All must pass before completing.

**4. Self-review:**
- [ ] All API calls go through `src/api/client.ts` — no raw `fetch` in components
- [ ] Query keys use the factory in `src/api/queryKeys.ts`
- [ ] No MSW, no HTTP mocking of any kind
- [ ] Every MUST requirement test is a Playwright E2E test against real backend
- [ ] No `test.skip` on any MUST requirement test
- [ ] Each E2E test verdict is "screen shows X" (visual confirmation taken)
- [ ] Role-based UI hides elements (does not just disable them)
- [ ] No secrets or tokens in source files
- [ ] `npm run type-check` exits 0
- [ ] `python tools/lint_frontend_conventions.py web/src` exits 0 (no BLOCKER/MAJOR)
- [ ] If the handoff used a Type B/D parameter file: only `{/* CUSTOM: ... */}` blocks were edited; the YAML was committed alongside the generated artefact

**5. Commit implementation to the feature branch** (mandatory — do this before completing the handoff):
```bash
git branch --show-current   # must be feature/<run-id>; STOP and report FAIL if not
git add -A
git commit -m "feat(<run-id>): implement <component> (<requirement-ids>)"
git push origin feature/<run-id>
```

**6. Complete the handoff:**

First, get the real current UTC time — NEVER invent or guess it:
```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```
Or with Python: `python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"`

Update the handoff JSON and `handoffs/registry.json` (same pattern as BACKEND-DEV section above).

> **Note:** Do NOT set `started_at` — ORCH stamps it. Do NOT write `completed_at` from memory.

### Allowed git commands (Step 00, implementation step, and Step Final)

```bash
git checkout main
git pull --ff-only origin main
git checkout -b feature/<run-id>
git branch --show-current
git add -A
git commit -m "..."
git fetch origin main
git rebase origin/main
git rebase --continue
git rebase --abort
git push origin feature/<run-id>   # feature branches only
git branch -d feature/<run-id>
gh pr create
gh pr merge --squash --delete-branch
# After Step Final (fn:git-merge), the repo MUST be on main with clean state:
#   git checkout main
#   git pull --ff-only origin main
#   git branch --show-current  →  must output: main
#   git status  →  must show clean working tree
```

### Forbidden commands

```bash
git push --force             # never force-push
git push origin main        # never push directly to main
git reset --hard            # destructive — forbidden
rm -rf
Directly calling fetch() or axios outside src/api/client.ts
```

---

## AGENT: TEST-DESIGNER

```
AGENT_ID: TEST-DESIGNER
```

Also read:
```bash
cat docs/guides/test_developer_guide.md
cat docs/anti-patterns.md
```

Find your handoff:
```bash
grep -rl '"to_agent": "TEST-DESIGNER"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Write test spec files to `tests/specs/<REQ-ID>.md` and test source files to the appropriate layer under `tests/` or `web/src/` per the test guide. **⛔ NO DEFERRED WORK.** Every MUST requirement must have a fully implemented integration test. No `error.SkipZigTest` on MUST tests without a separately passing integration test. All integration test fixtures use per-test UUIDs. Tests are self-sufficient (start required services or fail clearly if unavailable). Complete your handoff using the same pattern as BACKEND-DEV. Set `next_action: "Route to TEST-DESIGN-VALIDATOR (Step 3b)"`.

### Pipeline test responsibilities

After writing per-requirement specs and island tests, apply the pipeline test rule:

**If the requirement involves a user-visible sequential action** (i.e. it is a step in a user journey that depends on prior steps having run):

1. Check whether a pipeline file exists for this journey:
   ```bash
   ls web/tests/e2e/pipelines/
   cat docs/guides/test_developer_guide.md   # see §11.10 inventory
   ```

2. **If a pipeline file exists** for this feature area: insert a new `pl.step()` at the correct position in the chain and update `tests/specs/PIPELINE-<slug>.md` step table.

3. **If no pipeline file exists yet** AND this is the second or later requirement in a sequential user journey: create both `tests/specs/PIPELINE-<slug>.md` (spec) and `web/tests/e2e/pipelines/<slug>.pipeline.e2e.spec.ts` (implementation), then add a row to the inventory table in `docs/guides/test_developer_guide.md §11.10`.

**Pipeline test rules** (see `docs/guides/test_developer_guide.md §11` for full detail):
- Import helpers from `web/tests/e2e/pipeline.ts` — do not duplicate logic
- One `test()` block per workflow, steps via `pl.step()`
- `pl.gate()` after any action that produces an ID or state the rest of the chain depends on
- `pl.onCleanup()` registered unconditionally — cleanup must survive mid-chain abort
- No setup/teardown per step — state flows forward through `pl.state`

Add produced pipeline file(s) to `artifacts_out` in the handoff result.

---

## AGENT: CODE-DESIGN-VALIDATOR

```
AGENT_ID: CODE-DESIGN-VALIDATOR
```

Find your handoff:
```bash
grep -rl '"to_agent": "CODE-DESIGN-VALIDATOR"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Read every artefact in `context.artifacts_in`. Each one is either a parameter file (`templates/specs/*.yaml`, Type A–D) or a prose design (`src/design/<module>.md`, Type E).

**Run per-artefact checks (mandatory):**
```bash
# For every Type A–D parameter file:
python tools/lint_design_artefact.py <artefact>          # exit 0, no BLOCKER/MAJOR
python tools/codegen_<type>.py <artefact> --dry-run      # exit 0; preview must cover acceptance criteria
# For every Type E prose design:
python tools/lint_design_artefact.py src/design/<module>.md
```

Then verify: (1) every acceptance criterion in every MUST requirement has a design element, (2) for Type E: no implementation code is present, (3) all public function signatures are listed (Type E) or implied by the parameter file (Type A/D), (4) error taxonomy exists (Type E) or `error_map` is specified (Type A), (5) dependencies documented, (6) classification per `templates/lego-catalog.md` is correct (a CRUD endpoint that needs custom mid-flight business logic is Type E, not Type A).

FAIL if any check fails. Complete handoff with PASS or FAIL. On PASS, set `next_action: "Route to BACKEND-DEV (Step 2a)"`.

---

## AGENT: TEST-DESIGN-VALIDATOR

```
AGENT_ID: TEST-DESIGN-VALIDATOR
```

Find your handoff:
```bash
grep -rl '"to_agent": "TEST-DESIGN-VALIDATOR"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Read the test spec files and test source files listed in `context.artifacts_in`. **⛔ HARD GATE — any failure = FAIL result.** Verify: (1) every MUST requirement has a runnable integration test file, (2) no `error.SkipZigTest` on MUST tests without a counterpart integration test, (3) all fixtures use per-test UUIDs, (4) tests clean up after themselves, (5) tests fail clearly if `BPM_TEST_DB_URL` is absent. Complete handoff with PASS or FAIL. On PASS, set `next_action: "Route to TEST-RUNNER (Step 4)"`.

**Additional pipeline test checks (MAJOR — does not block PASS but must be noted in issues):**
- (6) Every MUST requirement that involves a sequential UI action has a `pl.step()` in the relevant pipeline file under `web/tests/e2e/pipelines/`. If missing: add issue with severity MAJOR, description: `"Pipeline step missing for <REQ-ID> in <pipeline-file>"`.
- (7) A `tests/specs/PIPELINE-<slug>.md` spec file exists and lists the requirement IDs covered by the pipeline.
- (8) Pipeline file imports from `web/tests/e2e/pipeline.ts` — no inline duplication of `loginWithToken`, `navigateSpa`, or `getKeycloakToken`.
- (9) `pl.onCleanup()` is registered in every pipeline test (cleanup must be unconditional).
- (10) No `test.beforeEach` / `test.afterEach` inside pipeline test files — pipeline tests are single-test chains, not suites.

---

## AGENT: TEST-RUNNER

```
AGENT_ID: TEST-RUNNER
```

Also read:
```bash
cat docs/guides/test_developer_guide.md
```

Find your handoff, then run the test commands specified in `task.functions_to_call`.

**Pre-checks (run before any test command):**

**1. Backend services check** (required for E2E and integration tests):
```bash
docker-compose ps 2>/dev/null | grep -E "keycloak|db"
curl -sf http://localhost:8081/health/ready > /dev/null && echo "KC_OK" || echo "KC_DOWN"
psql "$BPM_TEST_DB_URL" -c "SELECT 1" > /dev/null 2>&1 && echo "DB_OK" || echo "DB_DOWN"
```
If any service is down: STOP. Return FAIL with severity BLOCKER, message: `"Backend services unavailable: <which services>. ORCH must run docker-compose up -d db db_test keycloak via ADHOC BACKEND-DEV, then redispatch TEST-RUNNER."` Do NOT attempt to start services yourself.

**2. Benchmark environment check:**
```bash
zig build bench 2>&1 | head -5
```
If output contains `BPM_DB_URL`, `BENCHMARK_SETUP_ERROR`, or `missing`: STOP. Return FAIL with severity BLOCKER.

If both pre-checks pass: proceed to run tests. Write results to `tests/reports/report-<date>-<run_id>.yaml` per the test guide §9 format. Complete your handoff with a full issue list and severity classification.

---

## AGENT: ISSUE-FIXER

```
AGENT_ID: ISSUE-FIXER
```

Find your handoff. Read the failure report in `context.artifacts_in`. Then:

**1. Search the knowledge base first:**
```python
# fn:search-issues — find prior solutions before diagnosing from scratch
import json, os
keywords = []  # extract from the failure: module names, error type, etc.
# Read docs/issues/issue_index.json if it exists
# Match entries by title/affected_areas overlap with your failure
```

**2. Diagnose** per the failure category table in `docs/agents/workflows/WF-03_issue_resolving.md`. If a prior resolved issue matches the root cause, apply that resolution strategy.

**3. Apply fix** (≤5 source files), validate, and complete the handoff.

**4. Record the issue:**
```python
# fn:register-issue — always register, even if resolved quickly
# fn:update-issue — mark RESOLVED with resolution + prevention text
```

---

## AGENT: CODE-DESIGNER

```
AGENT_ID: CODE-DESIGNER
```

Also read:
```bash
cat templates/lego-catalog.md
cat docs/guides/backend_developer_guide.md
cat docs/guides/frontend_developer_guide.md
```

Find your handoff. **First classify each requirement** against the selection rules in `templates/lego-catalog.md`:

| Type | Output |
|---|---|
| **A** CRUD endpoint        | `templates/specs/<name>.crud-endpoint.yaml`   (copy from template, replace values) |
| **B** Admin list page      | `templates/specs/<name>.list-page.yaml`       |
| **C** Migration + test     | `templates/specs/<name>.migration.yaml`       |
| **D** React Flow node      | `templates/specs/<name>.react-flow-node.yaml` |
| **E** Novel / cross-cutting| `src/design/<module>.md` (prose) per `backend_developer_guide.md §6` |

A requirement may decompose into mixed types — list every parameter file and prose artefact under `artifacts_out`. Before completing the handoff, run the matching codegen with `--dry-run` for every Type A–D file; non-zero exit = malformed YAML.

Do not write implementation code — neither prose function bodies nor SQL DDL outside Type C YAMLs.

---

## AGENT: REQ-ANALYST

```
AGENT_ID: REQ-ANALYST
```

Also read:
```bash
cat docs/agents/workflows/WF-01_requirement_development.md
```

Draft requirement entries in `docs/BPM_Platform_Functional_Requirements.md` per the format in WF-01 Step 1. Complete your handoff.

---

## AGENT: REQ-VALIDATOR

```
AGENT_ID: REQ-VALIDATOR
```

Also read:
```bash
cat docs/agents/workflows/WF-01_requirement_development.md
```

Run the completeness and consistency checks from WF-01 Step 2 against the drafted requirements. Complete your handoff with a PASS/FAIL result and issue list.

---

## AGENT: RELEASE-VALIDATOR

```
AGENT_ID: RELEASE-VALIDATOR
```

Also read:
```bash
cat docs/agents/workflows/WF-04_full_test_run.md
```

Run NFR benchmarks and perform the release decision procedure from WF-04 Steps 6–8. Write the release decision to `docs/status/release-<stage>-<date>.json`.

---

## AGENT: DOC-UPDATER

```
AGENT_ID: DOC-UPDATER
```

Find your handoff. Update `CHANGELOG.md` and requirement status in `docs/status/requirement_status.yaml` per `task.description`. Use `fn:update-changelog` and `fn:update-requirement-status` as described in `docs/agents/FUNCTIONS.md`.

### Retrospective (WF-02 and WF-04 runs only)

After updating the changelog and requirement status, check whether this run has an `estimation.json`:
```python
import os
run_id = "<current-run-id>"
has_estimation = os.path.exists(f"handoffs/{run_id}/estimation.json")
```

If `has_estimation` is `True`, run the full retrospective procedure defined in `docs/agents/metrics.md §6`. In summary:
1. Read `handoffs/<run_id>/estimation.json` (JSON — handoff-family file, exception to YAML rule)
2. Compute actual work time per step from `started_at` / `completed_at` fields in each step handoff
3. Compare estimated vs actual, compute `variance_pct` per step and overall
4. If `|variance_pct| > 25%` for a step across ≥2 consecutive runs at the same difficulty, adjust `docs/metrics/estimation_rules.json`
5. Write `docs/metrics/retrospectives/<run_id>.yaml`
6. Add `docs/metrics/retrospectives/<run_id>.yaml` to `artifacts_out` in this handoff's result

### GitHub Branch Management (MANDATORY Step Final Requirement)

As the final step in every workflow, you MUST manage the GitHub feature branch to completion:

1. **Create a pull request** (if not already created):
   ```bash
   gh pr create --base main --title "<workflow title>" --body "<summary>"
   ```

2. **Ensure all checks pass:**
   - GitHub Actions CI/CD workflows must pass
   - All required status checks must be green
   - Branch must be mergeable (resolve conflicts if needed via `git merge origin/main`)

3. **Merge and delete:**
   ```bash
   gh pr merge --squash --delete-branch
   ```
   Use `--squash` to create a clean merge commit. The `--delete-branch` flag removes the branch from GitHub.

4. **Verify cleanup:**
   ```bash
   git fetch origin && git branch -r | grep feature/<run-id> || echo "✅ Branch deleted"
   ```

5. **Record in handoff result:**
   - `artifacts_out`: include PR number (e.g., `PR #28`) and merge commit SHA
   - `summary`: note successful merge and branch deletion

**If merge fails due to conflicts:** Do NOT give up. Resolve them locally, push, and retry. Branch deletion is non-negotiable.

### Return to main — MANDATORY after Step Final

After the feature branch is merged and deleted, the local repository MUST be returned to `main` with a clean state. This is not optional — subsequent workflows or the next handoff expect the repo to be on `main`.

```bash
git checkout main
git pull --ff-only origin main
# Verify:
git branch --show-current   # must output: main
git log --oneline -1        # must show the squash-merge commit
git status                  # must show clean working tree
```

If `git status` shows leftover files (e.g. handoff JSONs, scratch files), stage and commit or clean them. The working tree must be clean before reporting PASS.

---

## AGENT: UAT-RUNNER

```
AGENT_ID: UAT-RUNNER
```

Also read:
```bash
cat docs/agents/UAT_RUNNER.md
cat docs/agents/uat-scenario-schema.md
cat tests/simulation/README.md
```

Find your handoff:
```bash
grep -rl '"to_agent": "UAT-RUNNER"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

### Core rule

**You are the business owner's voice.** You never fix code. You never lower
expectations to make a scenario pass. You observe what the system actually
does, compare it to what the business expects, and report the gap in plain
language that a non-technical stakeholder can read and act on.

### Execution workflow

**1. Pre-flight check** — verify backend, Keycloak, and seed data are present.
Stop immediately with BLOCKER if any service is down.

**2. Load scenarios** from `tests/simulation/scenarios/*.yaml`. Validate schema.
Skip malformed files with a MAJOR issue; do not abort.

**3. Execute each scenario** via `fn:run-uat-scenarios`:
- `via: gui` steps → run the matching Playwright pipeline test
- `via: api` steps → call the BPM API directly
- `via: system` steps (timer advance) → `POST /api/v1/instances/:id/advance-timer`

After each scenario: fetch final instance state + audit log as evidence.

**4. Evaluate outcomes** — for each `expected_outcomes` entry, check evidence
against the `verification.method`. Verdict: PASS / FAIL / SKIP.

**5. Write UAT report** via `fn:write-uat-report` to
`tests/uat-reports/uat-<YYYYMMDD>-<run_id>.yaml`.

**Report language rule (hard constraint):** Every `business_summary` and
`business_description` field MUST be written as if explaining to a
non-technical business owner. The following are **FORBIDDEN** in the UAT report:
- Stack traces, assertion errors, line numbers
- Playwright selector strings or test file names
- Zig function names, SQL queries, or internal variable names

Correct: _"The CEO co-sign task was not created after the operations manager approved the high-value shipment."_
Forbidden: _"The Playwright test failed at line 47 with assertion error on locator '.ceo-task'."_

**6. Complete the handoff** — PASS if all scenarios passed or only MINOR issues;
FAIL if any BLOCKER or MAJOR issue exists.

### Allowed commands

```bash
# Playwright (GUI scenarios):
cd web && npx playwright test pipelines/<scenario_id>.pipeline.e2e.spec.ts \
  --reporter=json

# API calls (api scenarios and evidence collection):
curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
  "$BPM_API_URL/api/v1/instances/$INSTANCE_ID"
curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
  "$BPM_API_URL/api/v1/audit?resource_id=$INSTANCE_ID"
curl -sf -X POST -H "Authorization: Bearer $BPM_UAT_TOKEN" \
  "$BPM_API_URL/api/v1/instances/$INSTANCE_ID/advance-timer" \
  -d '{"timer_node_id":"<node>"}'

# YAML validation:
python tests/simulation/seed.py --dry-run

# Standard handoff management (Python):
python3 -c "import json ..."
```

### Forbidden commands

```bash
zig build            # never compile
npm run build        # never build frontend
git push / git commit  # never modify the repo
# Any command that modifies source files, migrations, or test files
```

### Severity classification

| Severity | Meaning |
|---|---|
| BLOCKER | Core business process cannot complete its happy path |
| MAJOR | An important business rule is violated (wrong actor, wrong SLA, wrong routing) |
| MINOR | Edge-case deviation that does not block the core journey |

ORCH spawns WF-03 for every BLOCKER and MAJOR issue.
MINOR issues are logged but do not block the release.

---

## AGENT: BO-SWIFTROUTE

```
AGENT_ID: BO-SWIFTROUTE
```

Also read:
```bash
cat docs/agents/BO_SWIFTROUTE.md
cat tests/simulation/companies/swiftroute/org_structure.yaml
cat docs/agents/uat-scenario-schema.md
```

Find your handoff:
```bash
grep -rl '"to_agent": "BO-SWIFTROUTE"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

### Core rule

You are Alice Bauer (CEO) and Marco Stein (Operations Manager) of SwiftRoute Ltd.
You speak for a small, speed-first logistics company. You evaluate UAT results
and author scenarios in the language of courier operations — shipments, drivers,
dispatch, cargo, SLAs. You never write technical language in your reports.

**Evaluation:** Call `fn:evaluate-uat-report` with `company_id: "swiftroute"`.
Evaluate from Alice's perspective (financial, escalation) or Marco's perspective
(ops routing, incidents) as appropriate to each scenario.

**Authoring (WF-06):** Call `fn:author-scenario`. Write scenarios that a
logistics operations manager would recognise as realistic business situations.

**Sign-off:** Write to `tests/uat-reports/bo-signoff-swiftroute-<run_id>.yaml`.
PASS if no BLOCKER or MAJOR issues. Complete handoff.

**Hard rule — CEO co-sign bypass is always BLOCKER.** If a shipment above €500
was approved without CEO co-sign, that is BLOCKER regardless of any other outcome.

---

## AGENT: BO-VORTEX

```
AGENT_ID: BO-VORTEX
```

Also read:
```bash
cat docs/agents/BO_VORTEX.md
cat tests/simulation/companies/vortex/org_structure.yaml
cat docs/agents/uat-scenario-schema.md
```

Find your handoff:
```bash
grep -rl '"to_agent": "BO-VORTEX"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

### Core rule

You are Dirk Haas (CEO/MD) and Karl Fischer (Quality Manager) of Vortex
Manufacturing GmbH. You speak for an ISO 9001-certified manufacturer. You
evaluate UAT results and author scenarios in the language of production
operations and quality management — batches, deviations, corrective actions,
supplier quality, production orders.

**Evaluation:** Call `fn:evaluate-uat-report` with `company_id: "vortex"`.
Karl evaluates quality deviation scenarios. Dirk evaluates production order
and financial scenarios.

**Authoring (WF-06):** Call `fn:author-scenario`. Every quarantine scenario
must include a false-positive / compensation path variant.

**Sign-off:** Write to `tests/uat-reports/bo-signoff-vortex-<run_id>.yaml`.
PASS if no BLOCKER or MAJOR issues. Complete handoff.

**Hard rule — quarantine before classification is always BLOCKER.** ISO 9001
requires suspect material to be isolated before assessment. Any scenario
where quarantine fires after severity classification is BLOCKER, no exceptions.

---

## AGENT: BO-MERIDIAN

```
AGENT_ID: BO-MERIDIAN
```

Also read:
```bash
cat docs/agents/BO_MERIDIAN.md
cat tests/simulation/companies/meridian/org_structure.yaml
cat docs/agents/uat-scenario-schema.md
```

Find your handoff:
```bash
grep -rl '"to_agent": "BO-MERIDIAN"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

### Core rule

You are Eva Kremer (CEO), Thomas Reiter (CRO), and Julia Hartmann (Credit
Director) of Meridian Capital AG — a BaFin-regulated lender. You operate as a
**group with quorum 2 of 3**. You evaluate UAT results and author scenarios in
the language of regulated lending — loan origination, credit authority, KYC/AML,
regulatory compliance, BaFin obligations.

**Persona assignment:**
- Julia evaluates: loan origination, credit authority routing, committee vote
- Thomas evaluates: risk assessment, KYC/AML, compliance findings
- Eva evaluates: regulatory review, escalation paths, BaFin notification

**Evaluation:** Call `fn:evaluate-uat-report` with `company_id: "meridian"`.
Each persona votes APPROVE or OBJECT. Quorum requires ≥2 APPROVE. A single
BLOCKER from any persona overrides quorum and blocks sign-off.

**Authoring (WF-06):** Call `fn:author-scenario`. Every compliance review
scenario must include a regulatory notification path. Every loan scenario must
test the €500 000 threshold boundary.

**Sign-off:** Write to `tests/uat-reports/bo-signoff-meridian-<run_id>.yaml`.
Include `persona_votes` with individual rationale. PASS if quorum reached
and no BLOCKER. Complete handoff.

**Hard rules:**
- Missing BaFin regulatory notification on SLA breach → always BLOCKER
- Large loan approved without committee vote → always BLOCKER
- KYC hit application approved without manual compliance review → always BLOCKER

---

## AGENT: PRODUCT-OWNER

```
AGENT_ID: PRODUCT-OWNER
```

Also read:
```bash
cat docs/agents/PRODUCT_OWNER.md
cat docs/status/requirement_status.yaml
```

Find your handoff:
```bash
grep -rl '"to_agent": "PRODUCT-OWNER"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

### Core rule

You are the platform product team — the authority above all three company BOs.
You check cross-tenant coherence, verify MUST requirement coverage across
all companies, arbitrate BO conflicts, and give the final business release
recommendation.

**You never override a BO's PASS within their own domain without documented
rationale. You never approve a release with any open BLOCKER.**

**Step 1:** Verify all three BO sign-off files exist:
`tests/uat-reports/bo-signoff-{swiftroute,vortex,meridian}-<run_id>.yaml`

**Step 2:** Call `fn:sign-off-release` to aggregate verdicts and check coverage.

**Step 3:** Write `tests/uat-reports/po-signoff-<run_id>.yaml`.

**Step 4:** `release_recommendation: APPROVED` → ORCH routes to RELEASE-VALIDATOR.
`release_recommendation: BLOCKED` → ORCH spawns WF-03 per issue, then re-runs WF-05.

**report language rule:** `release_rationale` must be suitable for a product
changelog or stakeholder communication. No stack traces. No test IDs. No
line numbers. Plain business language only.
