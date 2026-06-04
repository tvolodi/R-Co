# fn:write-uat-report

**Used by:** `UAT-RUNNER`  
**Called at:** WF-05 Step 1, after `fn:run-uat-scenarios` completes  
**Output:** `tests/uat-reports/uat-<date>-<run_id>.yaml`

---

## Purpose

Evaluates the evidence collected by `fn:run-uat-scenarios` against each
scenario's `expected_outcomes`, and writes a structured YAML report in
**business language**. No stack traces. No line numbers. No test IDs.

---

## Evaluation logic

For each `expected_outcome` in each scenario, UAT-RUNNER checks evidence
using the outcome's `verification.method`:

| Method | Evidence checked |
|---|---|
| `task_assigned` | `final_instance_state.active_tasks` — does a task of the expected type exist for the expected role? |
| `instance_state` | `final_instance_state.variables` and `.status` — do values match? |
| `audit_event` | `audit_events` list — does an event of the expected type exist? |
| `gui_screen` | Screenshot file — UAT-RUNNER visually inspects the screenshot |
| `api_response` | Captured API response body — does the field match? |

Verdict rules:
- `PASS`: evidence matches the expectation exactly
- `FAIL`: evidence contradicts the expectation, OR expected evidence is absent
- `SKIP`: the step that was supposed to produce the evidence was itself skipped
  (e.g. Playwright test aborted before reaching the relevant step)

---

## Output format

File: `tests/uat-reports/uat-<YYYYMMDD>-<run_id>.yaml`

See `docs/agents/UAT_RUNNER.md §4 Step 4` for the full YAML structure.

Key requirement: every `business_summary` field must be written as if
explaining the result to a non-technical business owner. The sentence
_"The Playwright test failed at line 47 with assertion error"_ is FORBIDDEN.
The correct form is _"The CEO co-sign task was not created after the
operations manager approved the high-value shipment."_

---

## Example output fragment

```yaml
scenarios:
  - id: swiftroute-shipment-high-value-happy
    title: High-value shipment correctly routed to CEO for co-sign
    company: swiftroute
    process: proc-swiftroute-shipment-approval
    verdict: PASS
    business_summary: >
      A €750 shipment request was submitted by the dispatcher and routed
      to the operations manager for review. The operations manager approved
      within the 4-hour window. Because the declared value exceeded €500,
      the CEO co-sign step was correctly triggered. After CEO approval,
      the shipment was released to the driver pool and the process completed
      successfully. All four business expectations were met.
    outcomes:
      - expectation: After dispatcher submits, ops manager receives a review task within 4 hours
        verdict: PASS
        evidence: task 'ops-review' found in instance active_tasks for role-ops-manager at T+0h12m
        deviation: null
      - expectation: After ops approves a >€500 shipment, CEO receives a co-sign task
        verdict: PASS
        evidence: task 'ceo-approval' found in active_tasks for role-ceo after ops_decision=approve
        deviation: null
    issues: []
    screenshots:
      - tests/screenshots/uat/swiftroute-shipment-high-value-happy/02-ops-review-task.png
      - tests/screenshots/uat/swiftroute-shipment-high-value-happy/03-ceo-cosign-task.png
    duration_seconds: 47
```
