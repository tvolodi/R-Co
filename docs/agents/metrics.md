# BPM Platform — Workflow Metrics System

**Version:** 1.0 · 2026-05-21  
**Audience:** All agents, especially `ORCH` and `DOC-UPDATER`

---

## 1. Purpose

The metrics system serves two goals:

1. **Estimation** — predict the time cost of a workflow before it runs so the team has a sense of scope
2. **Retrospective** — compare actual elapsed time against the estimate after completion and improve the rules

The system is intentionally lightweight: it adds two files per workflow run (`estimation.json` and a retrospective) and two timestamps per handoff (`started_at`, already alongside `completed_at`).

---

## 2. Difficulty Scale

| Level | Label | Description |
|---|---|---|
| 1 | Trivial | Config/doc change, single field addition, no schema changes |
| 2 | Simple | Single function or endpoint, no schema change, < 50 LOC |
| 3 | Standard | New feature: schema change + API + unit tests (typical PD-xx, DB-xx) |
| 4 | Complex | Multi-module feature, complex logic, cross-module integration deps |
| 5 | Very Complex | Cross-cutting, breaking changes, novel algorithms, new workflow type |

The difficulty reflects the **implementation scope of a single requirement** (or a tightly related group of requirements). When multiple requirements are bundled into one workflow run, estimate each individually and sum the results.

---

## 3. Estimation File Schema

ORCH creates `handoffs/<run_id>/estimation.json` at the same time as the first handoff for the run.

```json
{
  "run_id": "<RUN-ID>",
  "created_at": "<ISO8601-UTC>",
  "rules_version": "1.0",
  "requirement_ids": ["<REQ-ID>", "..."],
  "difficulty": 3,
  "difficulty_rationale": "<one sentence: why this level was chosen>",
  "steps": ["code-designer", "backend-dev", "test-designer", "test-runner", "release-validator", "doc-updater"],
  "estimated_minutes": {
    "code-designer": 15,
    "backend-dev": 35,
    "test-designer": 15,
    "test-runner": 12,
    "release-validator": 12,
    "doc-updater": 10,
    "total": 99
  }
}
```

**How ORCH computes `estimated_minutes`:**
1. Look up `docs/metrics/estimation_rules.json`.
2. Read `step_estimates_minutes[<step>][difficulty - 1]` for each step that will be used.
3. If any rework is already anticipated (e.g. re-route of a known-hard area), add `rework_surcharge_pct`% to the affected step.
4. Sum to get `total`.

---

## 4. Timing Fields on Handoffs

Each handoff in `handoffs/<run_id>/step-NN-<agent>.json` now carries three timestamps:

| Field | Set by | Meaning |
|---|---|---|
| `created_at` | ORCH | When the handoff was created (agent is queued) |
| `started_at` | Receiving agent | When the agent began executing the task |
| `completed_at` | Receiving agent | When the agent finished (COMPLETED or FAILED) |

**Derived metrics:**
- **Queue time** = `started_at − created_at` (scheduling delay)
- **Work time** = `completed_at − started_at` (actual effort)

Agents MUST set `started_at` when they transition the handoff to `IN_PROGRESS`.

---

## 5. Retrospective File Schema

DOC-UPDATER writes `docs/metrics/retrospectives/<run_id>.json` as the final step of every WF-02 or WF-04 workflow run.

```json
{
  "run_id": "<RUN-ID>",
  "requirement_ids": ["<REQ-ID>", "..."],
  "difficulty": 3,
  "rules_version_used": "1.0",
  "estimated_minutes_total": 99,
  "actual_minutes_total": 120,
  "variance_pct": 21,
  "by_step": {
    "code-designer":     { "estimated": 15, "actual": 22, "variance_pct": 47 },
    "backend-dev":       { "estimated": 35, "actual": 48, "variance_pct": 37 },
    "test-designer":     { "estimated": 15, "actual": 18, "variance_pct": 20 },
    "test-runner":       { "estimated": 12, "actual": 11, "variance_pct": -8 },
    "release-validator": { "estimated": 12, "actual": 10, "variance_pct": -17 },
    "doc-updater":       { "estimated": 10, "actual": 11, "variance_pct": 10 }
  },
  "rework_steps": [],
  "rule_adjustments": [
    {
      "step": "code-designer",
      "difficulty": 3,
      "old_estimate": 15,
      "new_estimate": 18,
      "reason": "Observed over 3 runs: design phase at D3 consistently runs ~20% over"
    }
  ],
  "completed_at": "<ISO8601-UTC>"
}
```

**`rule_adjustments`** is populated only when `variance_pct` for a step exceeds **±25%** across at least **2 consecutive runs** at the same difficulty level. Single-run outliers are recorded but do not trigger a rule change.

---

## 6. DOC-UPDATER Retrospective Procedure

As the final step of WF-02 / WF-04:

**Step 1 — Read estimation**
```python
import json
with open(f"handoffs/{run_id}/estimation.json") as f:
    est = json.load(f)
```

**Step 2 — Compute actual elapsed per step**
```python
import os, json, datetime

def minutes_between(t1, t2):
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    d1 = datetime.datetime.strptime(t1[:19] + "Z", fmt)
    d2 = datetime.datetime.strptime(t2[:19] + "Z", fmt)
    return round((d2 - d1).total_seconds() / 60, 1)

actuals = {}
for step_file in sorted(os.listdir(f"handoffs/{run_id}")):
    if not step_file.endswith(".json") or step_file == "estimation.json":
        continue
    with open(f"handoffs/{run_id}/{step_file}") as f:
        h = json.load(f)
    agent_slug = h["to_agent"].lower().replace("-", "")  # normalise
    slug = h.get("to_agent", "").lower()
    # map AGENT_ID to step key
    slug_map = {
        "code-designer": "code-designer", "backend-dev": "backend-dev",
        "frontend-dev": "frontend-dev", "test-designer": "test-designer",
        "test-runner": "test-runner", "release-validator": "release-validator",
        "doc-updater": "doc-updater"
    }
    key = slug_map.get(slug.replace("_","-"))
    if key and h.get("started_at") and h.get("completed_at"):
        actuals[key] = minutes_between(h["started_at"], h["completed_at"])
```

**Step 3 — Build retrospective**
```python
by_step = {}
total_est = 0
total_act = 0
for step, est_min in est["estimated_minutes"].items():
    if step == "total":
        continue
    act_min = actuals.get(step)
    if act_min is None:
        continue
    var_pct = round((act_min - est_min) / est_min * 100, 1)
    by_step[step] = {"estimated": est_min, "actual": act_min, "variance_pct": var_pct}
    total_est += est_min
    total_act += act_min

retro = {
    "run_id": run_id,
    "requirement_ids": est["requirement_ids"],
    "difficulty": est["difficulty"],
    "rules_version_used": est["rules_version"],
    "estimated_minutes_total": total_est,
    "actual_minutes_total": round(total_act, 1),
    "variance_pct": round((total_act - total_est) / total_est * 100, 1),
    "by_step": by_step,
    "rework_steps": [],   # fill from handoffs where rework_count > 0
    "rule_adjustments": [],
    "completed_at": datetime.datetime.utcnow().isoformat() + "Z"
}
```

**Step 4 — Check for rule adjustment triggers**

For each step where `|variance_pct| > 25`, check previous retrospectives:
```python
import glob

THRESHOLD_PCT = 25
CONSECUTIVE_RUNS_REQUIRED = 2

for step, data in retro["by_step"].items():
    if abs(data["variance_pct"]) <= THRESHOLD_PCT:
        continue
    # Count consecutive runs at same difficulty with same direction of variance
    pattern = f"docs/metrics/retrospectives/*.json"
    prior_files = sorted(glob.glob(pattern))
    consecutive = 0
    for pf in reversed(prior_files):
        with open(pf) as f:
            pr = json.load(f)
        if pr.get("difficulty") != est["difficulty"]:
            continue
        prior_var = pr.get("by_step", {}).get(step, {}).get("variance_pct")
        if prior_var is None:
            break
        if (data["variance_pct"] > 0) == (prior_var > THRESHOLD_PCT):
            consecutive += 1
        else:
            break
    if consecutive >= CONSECUTIVE_RUNS_REQUIRED - 1:
        with open("docs/metrics/estimation_rules.json") as f:
            rules = json.load(f)
        old_est = rules["step_estimates_minutes"][step][est["difficulty"] - 1]
        # Adjust by half the observed variance to dampen oscillation
        adjustment_factor = 1 + (data["variance_pct"] / 100) * 0.5
        new_est = round(old_est * adjustment_factor)
        retro["rule_adjustments"].append({
            "step": step,
            "difficulty": est["difficulty"],
            "old_estimate": old_est,
            "new_estimate": new_est,
            "reason": f"Observed {consecutive + 1} consecutive runs at D{est['difficulty']} with >{THRESHOLD_PCT}% variance"
        })
```

**Step 5 — Apply rule adjustments and write files**
```python
import os

if retro["rule_adjustments"]:
    with open("docs/metrics/estimation_rules.json") as f:
        rules = json.load(f)
    for adj in retro["rule_adjustments"]:
        rules["step_estimates_minutes"][adj["step"]][adj["difficulty"] - 1] = adj["new_estimate"]
    rules["updated_at"] = retro["completed_at"]
    rules["updated_by"] = run_id
    rules["update_count"] = rules.get("update_count", 0) + 1
    with open("docs/metrics/estimation_rules.json", "w") as f:
        json.dump(rules, f, indent=2)

os.makedirs("docs/metrics/retrospectives", exist_ok=True)
with open(f"docs/metrics/retrospectives/{run_id}.json", "w") as f:
    json.dump(retro, f, indent=2)
```

---

## 7. Artifact Locations

| File | Location | Created by | Updated by |
|---|---|---|---|
| Estimation rules (living) | `docs/metrics/estimation_rules.json` | Initial (manual/ORCH) | `DOC-UPDATER` (after retrospective) |
| Per-run estimation | `handoffs/<run_id>/estimation.json` | `ORCH` | Never (read-only after creation) |
| Per-run retrospective | `docs/metrics/retrospectives/<run_id>.json` | `DOC-UPDATER` | Never (append-only record) |
