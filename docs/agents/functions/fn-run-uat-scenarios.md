# fn:run-uat-scenarios

**Used by:** `UAT-RUNNER`  
**Called at:** WF-05 Step 1, after pre-flight check passes

---

## Purpose

Executes each scenario in `tests/simulation/scenarios/` against the running
system. For `via: gui` steps, drives the corresponding Playwright pipeline
test. For `via: api` steps, calls the BPM API directly. Captures screenshots,
API responses, and final instance state as evidence for each outcome.

---

## Execution

```bash
# For each scenario with a matching pipeline test file:
cd web && npx playwright test pipelines/<scenario_id>.pipeline.e2e.spec.ts \
  --reporter=json > scratch/uat-playwright-<scenario_id>.json

# For API-only steps within a scenario:
# UAT-RUNNER constructs and fires the API calls directly, records responses.
```

Screenshots are saved to `tests/screenshots/uat/<scenario_id>/`.

For each scenario, after Playwright (or API calls) complete, UAT-RUNNER
fetches the final instance state:

```bash
curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
  "$BPM_API_URL/api/v1/instances/$INSTANCE_ID" \
  > scratch/uat-instance-state-<scenario_id>.json

curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
  "$BPM_API_URL/api/v1/audit?resource_id=$INSTANCE_ID&page_size=100" \
  > scratch/uat-audit-<scenario_id>.json
```

---

## Timer advancement

For timeout/escalation scenarios where `step.note` mentions timer injection:

```bash
curl -sf -X POST \
  -H "Authorization: Bearer $BPM_UAT_TOKEN" \
  -H "Content-Type: application/json" \
  "$BPM_API_URL/api/v1/instances/$INSTANCE_ID/advance-timer" \
  -d '{"timer_node_id": "<node_id>"}' \
  > scratch/uat-timer-advance-<scenario_id>.json
```

If the platform does not yet support timer advancement (endpoint returns 404),
UAT-RUNNER logs: `TIMER_ADVANCE_UNSUPPORTED — timeout scenarios skipped` and
marks those scenarios as SKIP with severity MINOR.

---

## Output

Populates `pl.state` (for Playwright scenarios) and a local evidence dict
(for API scenarios) with:
- `instance_id` — created during scenario execution
- `task_ids` — list of task IDs observed during execution
- `final_instance_state` — JSON from `GET /api/v1/instances/:id`
- `audit_events` — list of audit log events for the instance
- `screenshots` — list of screenshot paths

This evidence is consumed by `fn:write-uat-report` to evaluate
`expected_outcomes`.
