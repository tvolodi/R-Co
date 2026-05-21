# WF-01 — Requirement Development & Validation

**Version:** 0.1 · 2026-05-20  
**Trigger:** New feature request, stage launch, or requirement change request  
**Owner:** `ORCH`

---

## ⛔ Mandatory Rule for All Steps

**Every agent completing a step in this workflow MUST call `fn:register-inner-report` immediately before `fn:complete-handoff`.** This is not optional. An agent that calls `fn:complete-handoff` without first calling `fn:register-inner-report` has violated the workflow. The handoff `result.summary` is not a substitute.

Step workflow chain template:
```
... (agent work) ... → fn:validate-completeness → fn:register-inner-report → fn:complete-handoff
```

---

## Overview

```
[INPUT: feature request or stage scope]
        │
        ▼
┌───────────────────┐
│  STEP 1: DRAFT    │ ← REQ-ANALYST
│  Write requirements│
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│  STEP 2: VALIDATE │ ← REQ-VALIDATOR
│  Check quality    │
└────────┬──────────┘
         │
    PASS?├─── NO ──► REWORK → back to STEP 1 (max 3 times)
         │
        YES
         │
         ▼
┌───────────────────┐
│  STEP 3: UPDATE   │ ← DOC-UPDATER
│  Set status =     │
│  VALIDATED        │
└────────┬──────────┘
         │
         ▼
[OUTPUT: VALIDATED requirements → ready for WF-02]
```

---

## Step 1 — Draft Requirements

**Agent:** `REQ-ANALYST`  
**Input handoff fields:** `context.stage`, `task.description` (feature/change request narrative)  
**Functions:** `fn:load-requirements`, `fn:load-requirement-status`

### Procedure

```
1. → fn:load-requirements (filter to the active stage or specified IDs)
2. Read the input request from the handoff task.description
3. For each new or changed requirement:
   a. Assign the next available requirement ID (format: PREFIX-NN, e.g. ES-09, EE-13)
   b. Write the requirement with:
      - Clear, single-responsibility statement
      - Priority: MUST / SHOULD / COULD (justified in comments if non-obvious)
      - Acceptance criteria: at least one concrete, verifiable statement
      - Cross-references to related requirements (by ID)
      - Stage assignment
4. For changed requirements:
   a. Note the change reason in a comment block: <!-- CHANGE: reason, date -->
   b. Check whether the change breaks any downstream requirement (cross-reference)
5. Write the updated requirements to docs/BPM_Platform_Functional_Requirements.md
   (or the frontend equivalent for UI requirements)
6. → fn:complete-handoff (status: PASS, artifacts_out: [requirements file],
                           next_action: "Route to REQ-VALIDATOR")
```

### Acceptance criteria for this step

- [ ] Every new requirement has an ID, priority, description, and at least one acceptance criterion
- [ ] No orphaned cross-references (all mentioned IDs exist)
- [ ] Stage assignment is consistent with the stage dependency order
- [ ] No contradictions with existing VALIDATED or RELEASED requirements

---

## Step 2 — Validate Requirements

**Agent:** `REQ-VALIDATOR`  
**Input handoff fields:** `context.requirement_ids` (list of new/changed IDs)  
**Functions:** `fn:load-requirements`, `fn:check-requirement-completeness`

### Procedure

```
1. → fn:load-requirements (filter to requirement_ids from context)
2. → fn:check-requirement-completeness for each requirement
3. For each requirement, also check:
   a. TESTABILITY: Can a test be written that definitively passes or fails?
      Vague words ("reasonably", "as needed", "appropriately") → FAIL
   b. CONSISTENCY: Does it conflict with any VALIDATED/RELEASED requirement?
      Scan all requirements with matching keywords for conflicts
   c. COMPLETENESS: Are all terms used in the requirement defined in the Glossary?
   d. TRACEABILITY: If this requirement changes behaviour of an existing feature,
      does it reference the original requirement ID?
   e. STAGE FIT: Is the requirement scoped to the right stage?
      (e.g., no identity management in Stage 1)
4. Produce a validation report:
   {
     requirement_id: string,
     passed: bool,
     issues: [{ severity: "BLOCKER"|"MAJOR"|"MINOR", description: string }]
   }[]
5. If ANY BLOCKER issues exist:
   → fn:complete-handoff (status: FAIL, issues: <validation report>,
                           next_action: "Rework requirements — see issues")
6. If only MINOR issues (style, suggestion):
   → fn:complete-handoff (status: PASS, summary: "Passed with minor suggestions",
                           issues: <minor issues>,
                           next_action: "Route to DOC-UPDATER to set VALIDATED status")
7. If no issues:
   → fn:complete-handoff (status: PASS, next_action: "Route to DOC-UPDATER")
```

### Acceptance criteria for this step

- [ ] All BLOCKER issues resolved (no vague language, no contradictions, all testable)
- [ ] No undefined terms in requirement text
- [ ] All cross-references valid

---

## Step 3 — Update Requirement Status

**Agent:** `DOC-UPDATER`  
**Input handoff fields:** `context.requirement_ids`  
**Functions:** `fn:update-requirement-status`

### Procedure

```
1. For each requirement_id in context.requirement_ids:
   → fn:update-requirement-status(requirement_id, "VALIDATED")
2. → fn:complete-handoff (status: PASS,
                           next_action: "Requirements ready. Orchestrator may launch WF-02.")
```

---

## Rework Loop

When Step 2 returns FAIL:

```
ORCH:
  1. Read result.issues from the Step 2 handoff
  2. Increment rework_count on the Step 1 handoff
  3. If rework_count < max_rework (3):
     - Create new Step 1 handoff with:
         task.description = original description +
           "\n\nREWORK ITERATION <N>:\n" + JSON.stringify(issues)
     - Route to REQ-ANALYST
  4. If rework_count >= max_rework:
     - Escalate (see ORCHESTRATOR.md §4.2)
```

---

## Output Artifacts

| Artifact | Location | Consumer |
|---|---|---|
| Updated requirements doc | `docs/BPM_Platform_Functional_Requirements.md` | WF-02 |
| Updated requirement status | `docs/status/requirement_status.json` | WF-02, WF-04 |
| Validation report | In handoff result.issues | `ORCH` logs |
