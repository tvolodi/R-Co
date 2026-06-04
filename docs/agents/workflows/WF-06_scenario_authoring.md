# WF-06 — Scenario Authoring

**Version:** 1.0 · 2026-06-04
**Trigger:** When a new process is implemented (after WF-02 completes) or
when a business owner requests coverage of a new business situation.
**Owner:** ORCH

---

## 1. Purpose

WF-06 produces UAT scenario files from natural-language business briefs.
It closes the loop between engineering (who implements processes) and
business owners (who define what "correct" looks like).

Without WF-06, new processes accumulate without UAT coverage, making
WF-05 progressively less meaningful. WF-06 ensures every new process
definition gets at least one happy-path and one edge-case scenario before
it is considered UAT-ready.

---

## 2. Prerequisites

Before ORCH dispatches WF-06:

1. The target process definition exists and is ACTIVE in the platform
   (`POST /api/v1/definitions/:id/activate` has been called)
2. The company fixture exists in `tests/simulation/companies/<company>/`
3. The relevant BO agent for the company is identified

---

## 3. Pipeline

| Step | Agent | Gate | Description |
|---|---|---|---|
| **1** | `BO-<COMPANY>` | — | Author scenario YAML from brief |
| **1b** | `UAT-RUNNER` | Hard gate | Validate scenario schema; dry-run only (no execution) |
| **2** | `BO-<COMPANY>` | — | Revise if schema validation fails |
| **3** | `ORCH` | — | Commit scenario file; register in simulation README |

No git branch required — scenario files are data artefacts, not code.
ORCH commits them directly to `main` via BACKEND-DEV (a one-liner commit).

---

## 4. Step-by-step

### Step 1 — BO-\<COMPANY\> authors scenario

Handoff task example:
```json
{
  "description": "Author a UAT scenario for the SwiftRoute shipment approval process covering the ops manager timeout and CEO escalation path. The scenario must test that when ops manager does not respond within 4 hours, the CEO receives an escalated task and can approve/reject directly.",
  "acceptance_criteria": [
    "Scenario YAML written to tests/simulation/scenarios/swiftroute-<descriptive-id>.yaml",
    "Schema validates against docs/agents/uat-scenario-schema.md",
    "All actors use actor_ids from tests/simulation/companies/swiftroute/org_structure.yaml",
    "expected_outcomes written from business perspective (no technical terms)",
    "At least one BLOCKER-severity expected_outcome covering the core escalation path",
    "Cleanup section present with cancel_open_instances: true"
  ],
  "functions_to_call": [
    "fn:author-scenario",
    "fn:register-inner-report",
    "fn:complete-handoff"
  ]
}
```

### Step 1b — UAT-RUNNER schema validation (hard gate)

UAT-RUNNER validates the authored scenario against the schema WITHOUT
executing it. If schema validation fails, ORCH routes back to the BO agent
for revision (rework, not a new WF-03).

```bash
python3 -c "
import yaml
from pathlib import Path

path = Path('tests/simulation/scenarios/<scenario-id>.yaml')
with open(path) as f:
    s = yaml.safe_load(f)

required = ['id', 'company_id', 'process_id', 'title', 'actors',
            'preconditions', 'steps', 'expected_outcomes', 'cleanup']
for field in required:
    assert field in s, f'Missing: {field}'

for step in s['steps']:
    assert 'step' in step and 'actor' in step and 'action' in step and 'via' in step

for eo in s['expected_outcomes']:
    assert 'id' in eo and 'description' in eo
    assert 'verification' in eo and 'on_fail' in eo
    assert eo['on_fail']['severity'] in ('BLOCKER', 'MAJOR', 'MINOR')

print('Schema OK')
"
```

### Step 2 — Revision if needed

If Step 1b fails: ORCH adds the validation errors to the BO handoff as
`REWORK 1:` items. `max_rework: 2`. If rework 2 also fails: escalate to human.

### Step 3 — Commit scenario file

ORCH dispatches BACKEND-DEV with a minimal handoff:
```json
{
  "description": "Commit new scenario file to main. No code changes.",
  "acceptance_criteria": [
    "git add tests/simulation/scenarios/<id>.yaml",
    "git commit -m 'scenario(WF06): add <id> scenario'",
    "git push origin main"
  ]
}
```

Also update `tests/simulation/README.md` Layer 2 planned scenarios list.

---

## 5. Trigger recognition

ORCH launches WF-06 when:

1. A WF-02 run completes for a process that has no scenario files yet:
   ```python
   from pathlib import Path
   scenarios = list(Path("tests/simulation/scenarios").glob(f"{company}-*.yaml"))
   if not scenarios:
       # Launch WF-06 to author at least 2 scenarios (happy path + edge case)
       pass
   ```

2. A user says: "add a scenario for X", "write a UAT test for Y",
   "cover the Z path in UAT", "author acceptance criteria for W"

3. After WF-05 completes and PRODUCT-OWNER flags an uncovered MUST requirement:
   ```yaml
   # In PO sign-off:
   platform_coverage:
     uncovered: [PROC-05, PROC-07]
   ```
   ORCH spawns WF-06 for each uncovered requirement.

---

## 6. Minimum scenario set per process

| Process type | Minimum scenarios required |
|---|---|
| Sequential chain | 1 happy path + 1 rejection path |
| Conditional branch | 1 per branch (each `condition` in the process YAML) |
| Parallel fork/join | 1 happy path + 1 timeout/partial path |
| Sub-process | 1 with sub-process spawned + 1 without |
| Timer escalation | 1 happy path (no timeout) + 1 escalation path |
| Multi-voter | 1 approved (quorum met) + 1 rejected + 1 quorum-not-met |
| Compensation | 1 forward path + 1 compensation-triggered path |

ORCH tracks these minimums when deciding whether to auto-trigger WF-06
after WF-02.

---

## 7. ORCH forbidden actions in WF-06

- Writing scenario files directly (ORCH does no implementation)
- Accepting a scenario that uses technical language in `expected_outcomes`
- Skipping the UAT-RUNNER schema validation gate
- Committing scenario files without schema validation passing
