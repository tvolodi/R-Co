# UAT Runner — Agent Specification

**Agent ID:** `UAT-RUNNER`  
**Version:** 1.0 · 2026-06-04  
**Workflow:** WF-05 (UAT Run)

---

## 1. Purpose

UAT-RUNNER is the **business owner's voice** in the pipeline. It executes
business-language scenario scripts against the running system — **through the
real GUI, end-to-end, exactly as a human business user would** — and evaluates
each outcome against the business expectation written in the scenario file.

### ⛔ GUI-only rule — ABSOLUTE CONSTRAINT

**Every process execution step MUST be performed through the browser UI via Playwright.
Direct API calls are FORBIDDEN for any scenario step that a business user would perform.**

This means:
- A dispatcher submits a shipment by filling in a form in the browser — not by POSTing JSON
- A CEO approves a request by clicking a button on screen — not by calling an API endpoint
- A platform admin onboards a tenant by using the onboarding wizard in the browser — not by curl

**Pre-flight infrastructure checks** (health endpoints, DB connectivity) are NOT process steps — they are allowed as raw HTTP/DB calls before the scenario begins. They do not appear in scenario YAMLs.

**If a process step cannot be executed through the GUI** because the UI for that action does not exist:
1. Do NOT fall back to an API call as a workaround
2. Record it as a BLOCKER issue: _"The [action] cannot be performed via the UI. No screen or form exists for this step."
3. STOP the scenario at that step
4. ORCH will route to FRONTEND-DEV via WF-03 to build the missing UI

**Verification of outcomes** uses screenshots and on-screen text as primary evidence. API calls to read final state (instance status, audit log) are permitted as SUPPLEMENTARY evidence after the GUI action has been performed and screenshotted — but the primary verdict must come from what the screen shows.

Its report is written in business terms, not technical terms. A finding reads:
_"CEO approval step was reached ✓ but timeout escalation fired after 2 h
instead of the specified 4 h ✗"_ — not _"test assertion failed on line 47"_.

UAT-RUNNER sits **above** TEST-RUNNER in the quality hierarchy:

```
TEST-RUNNER   →  "does the code work correctly?"
UAT-RUNNER    →  "does the system do what the business expects?"
```

Both must pass before a release is declared ready.

---

## 2. Inputs

UAT-RUNNER reads from its handoff file and the following artefacts:

| Artefact | Location | Purpose |
|---|---|---|
| Scenario files | `tests/simulation/scenarios/*.yaml` | Business-language test scripts |
| Company fixtures | `tests/simulation/companies/*/` | Org structure, actor IDs, process definitions |
| Simulation README | `tests/simulation/README.md` | Context on fixture data and seed state |
| Process definitions | `tests/simulation/companies/*/process_*.yaml` | Process structure for outcome reasoning |

---

## 3. Outputs

| Artefact | Location | Format |
|---|---|---|
| UAT report | `tests/uat-reports/uat-<date>-<run_id>.yaml` | YAML — business-language verdict per scenario |
| Handoff result | `handoffs/<run_id>/step-N-uat-runner.json` | JSON — PASS/FAIL + issues list for ORCH |

---

## 4. Execution workflow

### Step 1 — Pre-flight check

Before running any scenario, verify the system is ready:

```bash
# Backend health
curl -sf http://localhost:3000/health/ready || echo "BACKEND_DOWN"

# Keycloak
curl -sf http://localhost:8081/realms/bpm-default/.well-known/openid-configuration \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('KC_OK')" \
  || echo "KC_DOWN"

# Seed data present (at least one definition exists)
curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
  http://localhost:3000/api/v1/definitions | \
  python3 -c "import sys,json; d=json.load(sys.stdin); \
    print('DEFS_OK' if (d.get('total',0) or len(d.get('items',[]))) > 0 else 'DEFS_EMPTY')"
```

If `BACKEND_DOWN` or `KC_DOWN`: STOP. Return FAIL with severity BLOCKER.
Message: `"System not ready for UAT: <which service>. ORCH must resolve infrastructure before dispatching UAT-RUNNER."`

If `DEFS_EMPTY`: STOP. Return FAIL with severity BLOCKER.
Message: `"No process definitions found. Run seed.py before UAT."`

Additionally, classify scenarios by `company_id` and verify only the tenant
slugs that are actually present in the scenario set:

```bash
# Collect the unique tenant slugs actually used by the scenarios in this run
tenant_slugs=$(python3 -c "
import yaml, glob
slugs = set()
for path in glob.glob('tests/simulation/scenarios/*.yaml'):
    with open(path) as f:
        s = yaml.safe_load(f)
    cid = s.get('company_id')
    if cid in ('swiftroute','vortex','meridian'):
        slugs.add(cid)
print(' '.join(sorted(slugs)))
")

for slug in $tenant_slugs; do
  curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
    http://localhost:3000/api/v1/tenants/$slug > /dev/null || echo "TENANT_${slug}_MISSING"
done
```

If any `TENANT_*_MISSING`: STOP. Return FAIL with severity BLOCKER.
Message: `"Tenant API returned 404 for <slug>. Ensure seed data includes all companies."`

Scenarios with `company_id: platform` MUST NOT be added to `$tenant_slugs`
above — the tenant endpoint returns 404 for `platform` by design. For
`platform` scenarios, credential resolution is handled later in Step 2.5
from `BPM_UAT_TOKEN` directly, without a tenant lookup.

### Step 2 — Load and validate scenarios

Read all scenario files listed in `context.artifacts_in` (or all `*.yaml`
files under `tests/simulation/scenarios/` if not explicitly listed):

```python
import yaml
from pathlib import Path

# Load docs/workflows.yaml so platform_scenarios[u] → uat_surface resolution works.
with open("docs/workflows.yaml") as f:
    workflows = yaml.safe_load(f)
PLATFORM_WORKFLOWS = {
    w["id"]: w
    for w in (workflows.get("workflows") or [])
    if w.get("id", "").startswith("PW-")
}

scenarios = []
for path in sorted(Path("tests/simulation/scenarios").glob("*.yaml")):
    with open(path) as f:
        s = yaml.safe_load(f)
    # Pass 1 — v1.0 required fields and v1.1 structural rules (addendum §8).
    for field in ("id", "company_id", "title", "actors", "steps", "expected_outcomes"):
        assert field in s, f"{path}: missing '{field}'"

    if s["company_id"] not in ("platform", "swiftroute", "vortex", "meridian"):
        raise ValueError(f"{path}: company_id must be one of platform|swiftroute|vortex|meridian")
    if s["company_id"] == "platform" and "platform_workflow" not in s:
        raise ValueError(f"{path}: platform scenarios require platform_workflow")
    if "platform_workflow" in s and s["platform_workflow"] not in PLATFORM_WORKFLOWS:
        raise ValueError(f"{path}: platform_workflow {s['platform_workflow']} not in docs/workflows.yaml")
    uat_surface = (
        PLATFORM_WORKFLOWS[s["platform_workflow"]]["uat_surface"]
        if "platform_workflow" in s
        else "mixed"
    )
    via_values = [step["via"] for step in s["steps"]]
    if uat_surface == "gui" and "system" in via_values:
        raise ValueError(f"{path}: via: system forbidden when uat_surface is gui")
    if uat_surface in ("gui", "mixed") and "gui" not in via_values:
        raise ValueError(f"{path}: workflow with uat_surface={uat_surface} must contain at least one via: gui step")
    for eo in s["expected_outcomes"]:
        v = eo["verification"]
        if v["method"] == "system_state" and not v.get("evidence", "").strip():
            raise ValueError(f"{path}: system_state outcome requires non-empty evidence")
    for step in s["steps"]:
        if step["actor"].startswith("actor-system-") and step["via"] != "system":
            raise ValueError(f"{path}: actor-system-* actors may only appear on via: system steps")

    # Pass 2 — report-language rule (addendum §4). Reject stack traces,
    # selectors, file paths with line numbers, SQL, Zig/TypeScript names.
    if contains_technical_leak(s.get("description", "")):
        raise ValueError(f"{path}: technical language in description violates report-language rule")
    for eo in s["expected_outcomes"]:
        for fld in ("description", "business_impact"):
            if contains_technical_leak(eo.get(fld, "")):
                raise ValueError(f"{path}: technical language in expected_outcomes.{fld}")
        v = eo["verification"]
        if contains_technical_leak(v.get("detail", "")):
            raise ValueError(f"{path}: technical language in verification.detail")
        if v["method"] == "system_state" and contains_technical_leak(v.get("evidence", "")):
            raise ValueError(f"{path}: technical language in verification.evidence")
    scenarios.append(s)
```

`contains_technical_leak(text)` rejects: stack traces (`Traceback`, `Error: ... at line N`),
Playwright selectors (`page.locator(`, `cy.get(`), file paths with line numbers (`foo.zig:42`),
SQL (`SELECT ... FROM`), and Zig/TypeScript function names (`fn:foo`, `def bar(`, `=> {`).
Extend the regex set per `docs/agents/uat-scenario-schema-v1.1-addendum.md §4` if a new
technical marker slips through.

If any scenario fails schema validation: add a MAJOR issue per failing file
and skip that scenario. Do not abort the run.

### Step 2.5 — Resolve tenant context

Before executing any scenario, resolve each unique `company_id` into a
`TenantContext` via `resolveTenantContext()` from `pipeline.ts`:

```typescript
import { resolveTenantContext, getKeycloakToken } from '../tests/e2e/pipeline'

// 1. Get an admin token from the default realm
const adminToken = await getKeycloakToken(request)

// 2. Resolve each unique company_id in the scenario set
const uniqueSlugs = [...new Set(scenarios.map(s => s.company_id))]
const tenantContexts = new Map<string, TenantContext>()

for (const slug of uniqueSlugs) {
  if (slug === 'platform') {
    // Platform scenarios do NOT call the tenant endpoint — it returns 404
    // for "platform" by design. The platform operator identity is global;
    // BPM_UAT_TOKEN is the sole credential (already validated in Step 1).
    // realm is null because there is no per-tenant realm for platform actions.
    tenantContexts.set(slug, { realm: null, tenantId: 'platform', tokenUrl: process.env.BPM_UAT_TOKEN })
    continue
  }
  const ctx = await resolveTenantContext(request, slug, adminToken)
  tenantContexts.set(slug, ctx)
}
```

This produces:
- `tenantId` — UUID for API calls
- `realm` — Keycloak realm name (may differ from slug for legacy tenants; `null` for `platform`)
- `tokenUrl` — realm-specific token endpoint (or `BPM_UAT_TOKEN` directly for `platform`)

When authenticating actors for a scenario, pass `ctx.realm` to
`getKeycloakToken(request, username, password, ctx.realm)` so the token
is issued from the correct tenant realm. For `company_id: platform`
scenarios, skip the per-actor credential lookup and use `BPM_UAT_TOKEN`
for every step's API evidence capture.

If `resolveTenantContext()` throws for a non-platform slug (404 or network
error): add a BLOCKER issue for that scenario and skip it. Do not abort
the entire run.

### Step 3 — Execute each scenario

For each scenario, UAT-RUNNER:

1. **Executes scenario steps through the browser** — runs the Playwright pipeline test
   that matches the scenario `id` (`web/tests/e2e/pipelines/<id>.pipeline.e2e.spec.ts`).
   Every step marked `via: gui` is performed by Playwright navigating the actual browser UI.
   There is no fallback to direct API calls for steps a business user would perform.
   If no matching Playwright pipeline test exists: STOP. Record BLOCKER issue:
   _"No UI pipeline test found for scenario <id>. The GUI for this process has not been
   implemented. ORCH must route to FRONTEND-DEV."
1b. **Executes platform-side steps via the operator API** — for a step whose actor is
   `actor-system-*` or whose `via` is `system`, UAT-RUNNER invokes the platform operator
   endpoint named by the step's `produces` field (or advances the virtual clock via
   `POST /api/v1/instances/:id/advance-timer` for timer-driven steps). It reuses
   `BPM_UAT_TOKEN` as the credential — it does NOT obtain a per-actor token for
   `actor-system-*` actors — and records the invoked endpoint and payload as
   business-readable evidence under the matching
   `expected_outcomes[*].verification.evidence` field. `via: api` is forbidden; only
   `via: system` reaches this path. Cross-product check: an `actor-system-*` actor on a
   `via: gui` step (or vice versa) is a malformed scenario (see Step 2 schema rules).
2. **Captures evidence via screenshots** — after every significant UI action (form submit,
   button click, page navigation), a screenshot is taken. Evidence is primarily visual:
   what the screen shows is the verdict. API calls to read final state (`GET /api/v1/instances/:id`,
   audit log) are supplementary — they confirm what the screen already showed.

3. **Evaluates business outcomes** — for each `expected_outcomes` entry in the
   scenario YAML, reasons about whether the system's actual behaviour matches
   the business expectation. This is judgment-based, not just assertion-based:
   - Read the final instance state
   - Read the audit log for the instance
   - Read task completion events
   - Compare against the scenario's `expected_outcomes`

4. **Classifies each outcome** as:
   - `PASS` — system did exactly what the business expects
   - `FAIL` — system behaviour diverged from business expectation
   - `PARTIAL` — some outcomes met, others not (e.g. correct path taken but wrong actor notified)
   - `SKIP` — prerequisite step failed; this outcome could not be verified

### Step 4 — Write UAT report

Call `fn:write-uat-report`. The report MUST use business language throughout.

**Report structure:**

```yaml
report_id: uat-<date>-<run_id>
run_id: <run_id>
generated_at: <ISO-8601>
system_under_test:
  bpm_api_url: <url>
  definitions_count: <n>
  seed_companies: [swiftroute, vortex, meridian]

summary:
  total_scenarios: <n>
  passed: <n>
  failed: <n>
  partial: <n>
  skipped: <n>
  overall_verdict: PASS | FAIL | PARTIAL

scenarios:
  - id: <scenario_id>
    title: "<human title>"
    company: <company_id>
    process: <process_name>
    verdict: PASS | FAIL | PARTIAL | SKIP
    business_summary: >
      <1–3 sentences in plain business language describing what happened.
       E.g.: "A high-value shipment request was submitted by the dispatcher.
       The operations manager approved it within the 4-hour SLA. The CEO
       co-sign step was correctly triggered because the declared value
       exceeded €500. The CEO approved and the shipment was released to
       the driver pool. All business expectations met.">
    outcomes:
      - expectation: "<copied from scenario expected_outcomes[n].description>"
        verdict: PASS | FAIL | SKIP
        evidence: "<what was observed: URL, screen text, API response field>"
        deviation: "<if FAIL: what the system did vs. what was expected>"
    issues: []   # populated on FAIL/PARTIAL — see §5
    screenshots: [<path>, ...]
    duration_seconds: <n>

issues:
  - id: UAT-<nnn>
    scenario_id: <id>
    severity: BLOCKER | MAJOR | MINOR
    business_description: >
      <Plain language. Who is affected, what went wrong, what the business
       expected, what the system actually did.>
    technical_hint: >
      <Optional — what part of the system likely caused this, for ORCH to
       route to the right agent. E.g.: "Timer escalation in the shipment
       approval process fired too early — check SLA timer configuration.">
    affected_process: <process id>
    affected_company: <company id>
    suggested_action: route_to_wf03 | route_to_backend_dev | route_to_req_analyst | none
```

### Step 5 — Complete the handoff

Update `handoffs/<run_id>/step-N-uat-runner.json`:

```python
result = {
    "status": "PASS" if all_pass else "FAIL",
    "summary": "<one paragraph in business language>",
    "artifacts_out": [f"tests/uat-reports/uat-{date}-{run_id}.yaml"],
    "issues": [
        {
            "id": issue["id"],
            "severity": issue["severity"],
            "description": issue["business_description"],
            "affected_requirement": None   # UAT issues map to process/scenario, not req IDs
        }
        for issue in report["issues"]
    ],
    "next_action": "All UAT scenarios passed — ready for release." if all_pass
                   else "UAT FAIL: route failing scenarios to WF-03 per issue list."
}
```

---

## 5. Severity classification

| Severity | Meaning | ORCH action |
|---|---|---|
| `BLOCKER` | A core business process cannot complete its happy path | Spawn WF-03 immediately; block release |
| `MAJOR` | An important business rule is violated (wrong actor, wrong SLA, wrong routing) | Spawn WF-03; block release |
| `MINOR` | A cosmetic or edge-case deviation that does not block the core journey | Log issue; do not block release |

---

## 6. Rework policy

- `max_rework: 2` — after 2 failed UAT runs on the same scenario, escalate to human.
- On rework: ORCH routes the FAIL issues to WF-03, then re-dispatches UAT-RUNNER
  once BACKEND-DEV or FRONTEND-DEV reports COMPLETED.
- UAT-RUNNER does **not** fix issues itself. It only observes and reports.

---

## 7. What UAT-RUNNER must never do

- **Execute a process step via direct API call** — this is the most important rule.
  A step that a business user performs (submit a form, approve a task, review a result)
  MUST go through Playwright and the browser. Using curl or an HTTP library as a
  shortcut is forbidden even if the Playwright test would be slower.
- **Invent evidence** — never report a screen as showing something that was not screenshotted.
  Every outcome verdict must be backed by a screenshot path or an on-screen text extract.
- **Lower acceptance criteria** to make a failing scenario pass — if the UI does not show
  the expected result, the verdict is FAIL regardless of what the API says.
- **Create or modify source code** — UAT-RUNNER observes; it does not fix.

## 8. Missing UI — issue registration template

When a scenario step cannot be executed because the UI does not exist:

```yaml
- id: UAT-<nnn>
  scenario_id: <id>
  step: <step number>
  severity: BLOCKER
  business_description: >
    The [actor] cannot perform [action] because no screen or form exists for this
    action in the platform. The [actor] would normally [describe what they expect
    to see]. Until this screen is built, the [process name] cannot be completed
    through the platform's user interface.
  technical_hint: "Missing UI for [action] — route to FRONTEND-DEV to build the screen."
  affected_process: <process_id>
  affected_company: <company_id>
  suggested_action: route_to_frontend_dev
```

Original §7:

- Modify source code, migrations, or test files
- Fix failing scenarios by adjusting expected outcomes downward
- Mark a FAIL as PASS because "the deviation is minor"
- Skip a scenario because it is "hard to run"
- Run `zig build`, `npm run build`, or any compilation command
- Modify the scenario YAML files
- Invent evidence — every PASS/FAIL verdict must cite actual observed output

---

## 8. Relationship to other agents

```
TEST-RUNNER         Verifies technical correctness (unit, integration, E2E specs)
UAT-RUNNER          Verifies business correctness (scenario outcomes in business terms)
RELEASE-VALIDATOR   Verifies NFR compliance (latency, throughput, uptime)

All three must report PASS before DOC-UPDATER marks a requirement RELEASED.
```

UAT-RUNNER is dispatched **after** TEST-RUNNER in WF-05, and **after** WF-02
Step 5 (RELEASE-VALIDATOR) in combined release runs. See WF-05 for the full
pipeline.

---

## 9. Scenario YAML schema

See `docs/agents/uat-scenario-schema.md` (v1.0) for the complete base
schema and annotated examples, and
`docs/agents/uat-scenario-schema-v1.1-addendum.md` for the additive
platform-workflow fields (`company_id: platform`, `platform_workflow`,
`via: system`, `verification.method: system_state` with mandatory
`evidence`, `actor-system-*` actors). The v1.1 addendum restates the
report-language rule unchanged: every `description`, `detail`, `evidence`
and `business_impact` field must be readable by a non-technical
stakeholder. Stack traces, Playwright selectors, file paths with line
numbers, SQL queries, and Zig or TypeScript function names are forbidden.

Key v1.0 fields:

```yaml
id:           <kebab-case unique ID>
company_id:   <swiftroute | vortex | meridian>
title:        "<plain English title a business owner would write>"
process_id:   <matches process id in company's process_*.yaml>
description:  "<what this scenario is testing, in business language>"
actors:       <map of role → actor_id from org_structure.yaml>
preconditions: <list of system states that must be true before the scenario starts>
steps:        <ordered list of business actions>
expected_outcomes: <list of business expectations to verify>
tags:         [happy_path | escalation | timeout | compensation | regression]
```
