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

**The only valid reason to ask the user** is two or more genuinely equivalent options requiring a business/personal preference the agent cannot infer.

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
- "Out of scope" and "unrelated to current task" are **NOT** valid reasons to leave a blocker unfixed.

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

Agent-created files MUST go in the correct directory. Never create working files in the project root.

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
    "created_at": datetime.datetime.utcnow().isoformat() + "Z",
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
import json
with open("docs/status/requirement_status.json") as f:
    status = json.load(f)
must_ids = []  # fill from the requirements doc for the stage
blocking = [f"{r}: {status['requirements'].get(r, {}).get('status', 'MISSING')}"
            for r in must_ids
            if status["requirements"].get(r, {}).get("status") not in ("TESTED", "RELEASED")]
print("BLOCKED:" if blocking else "CLEARED")
for b in blocking: print(f"  {b}")
```

### ORCH forbidden actions

```
git push / git reset --hard / git rebase / rm -rf
Writing Zig, TypeScript, SQL, or test code
Filling in handoff result fields (only agents do that)
```

---

## AGENT: BACKEND-DEV

```
AGENT_ID: BACKEND-DEV
```

Also read:
```bash
cat docs/guides/backend_developer_guide.md
```

Then find your handoff:
```bash
grep -rl '"to_agent": "BACKEND-DEV"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Read the handoff file. Read the design artefact it references under `context.artifacts_in`.

### Implementation workflow

**1. Understand** — read requirement IDs from `docs/BPM_Platform_Functional_Requirements.md` and the design file at `src/design/<module>.md`.

**2. Implement** — write Zig source files and SQL migrations per the conventions in the backend guide.

**3. Validate:**
```bash
zig build
zig build test
zig build migrate
```
All three must exit 0 before completing.

**4. Self-review:**
- [ ] No SQL string interpolation of user data (prepared statements only — security critical)
- [ ] All allocating functions accept `std.mem.Allocator`
- [ ] `src/engine/transition.zig` has zero I/O if modified (pure function — absolute rule)
- [ ] Error types defined in per-module error sets
- [ ] `zig build` exits 0

**5. Complete the handoff:**
```python
import json, datetime
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
h["completed_at"] = datetime.datetime.utcnow().isoformat() + "Z"
with open("handoffs/<your-handoff>.json", "w") as f:
    json.dump(h, f, indent=2)
```
Also update the `status` field in `handoffs/registry.json` for this handoff.

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
```

### Forbidden commands

```bash
git push / git reset --hard / git rebase / rm -rf
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
cat docs/guides/frontend_developer_guide.md
cat docs/guides/frontend_design_system.md
```

Then find your handoff:
```bash
grep -rl '"to_agent": "FRONTEND-DEV"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

### Implementation workflow

**1. Understand** — read requirements from `docs/BPM_Platform_Frontend_Requirements.md` and the design artefact in `context.artifacts_in`.

**2. Implement** — write React/TypeScript under `web/src/` per the frontend guide conventions.

**3. Validate:**
```bash
cd web
npm run type-check
npm run lint
npm run test
npm run build
```
All must pass before completing.

**4. Self-review:**
- [ ] All API calls go through `src/api/client.ts`
- [ ] Query keys use the factory in `src/api/queryKeys.ts`
- [ ] Role-based UI hides elements (does not just disable them)
- [ ] No secrets or tokens in source files
- [ ] `npm run type-check` exits 0

**5. Complete the handoff** — same pattern as BACKEND-DEV section above.

### Forbidden commands

```bash
git push / git reset --hard / rm -rf
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
```

Find your handoff:
```bash
grep -rl '"to_agent": "TEST-DESIGNER"' handoffs/ | xargs grep -l '"status": "PENDING"' 2>/dev/null
```

Write test spec files to `tests/specs/<REQ-ID>.md` and test source files to the appropriate layer under `tests/` or `web/src/` per the test guide. Complete your handoff using the same pattern as BACKEND-DEV.

---

## AGENT: TEST-RUNNER

```
AGENT_ID: TEST-RUNNER
```

Also read:
```bash
cat docs/guides/test_developer_guide.md
```

Find your handoff, then run the test commands specified in `task.functions_to_call`. Write results to `tests/reports/` per the test guide §8 format. Complete your handoff with a full issue list and severity classification.

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
cat docs/guides/backend_developer_guide.md
cat docs/guides/frontend_developer_guide.md
```

Find your handoff. Produce a design artefact at `src/design/<module>.md` per the format specified in `backend_developer_guide.md §6`. Do not write implementation code.

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

Find your handoff. Update `CHANGELOG.md` and requirement status in `docs/status/requirement_status.json` per `task.description`. Use `fn:update-changelog` and `fn:update-requirement-status` as described in `docs/agents/FUNCTIONS.md`.
