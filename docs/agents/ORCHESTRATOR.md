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

---

## 2. Standard Workflows

| ID | Name | Entry trigger | Document |
|---|---|---|---|
| WF-01 | Requirement Development & Validation | New feature request or stage begins | `docs/agents/workflows/WF-01_requirement_development.md` |
| WF-02 | Requirement Implementation | Requirement status = VALIDATED | `docs/agents/workflows/WF-02_requirement_implementation.md` |
| WF-03 | Issue Resolving | Test failure or bug report | `docs/agents/workflows/WF-03_issue_resolving.md` |
| WF-04 | Full Test Run | Pre-release or scheduled CI run | `docs/agents/workflows/WF-04_full_test_run.md` |

---

## 3. Orchestrator Decision Tree

```
INPUT: trigger event
│
├─ Is it a new or changed requirement?
│     └─► Launch WF-01
│
├─ Is it a VALIDATED requirement ready to build?
│     └─► Launch WF-02
│
├─ Is it a test failure or bug report?
│     └─► Launch WF-03
│
├─ Is it a pre-release gate or scheduled full test?
│     └─► Launch WF-04
│
└─ Does not match any standard workflow?
      └─► Build ad-hoc workflow (see Section 5)
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
- An urgent hotfix bypasses the standard WF-03 sequence
- A documentation-only correction with no code change

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

### 7.3 Log the estimation

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
