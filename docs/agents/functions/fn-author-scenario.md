# fn:author-scenario

**Used by:** `BO-SWIFTROUTE`, `BO-VORTEX`, `BO-MERIDIAN`
**Called at:** WF-06 Step 1

---

## Purpose

Guides a BO agent through authoring a well-formed scenario YAML file.
Provides the checklist the agent must satisfy before completing the handoff.

---

## Authoring checklist

The BO agent MUST satisfy all of the following before writing the file:

**Identity**
- [ ] `id` is kebab-case, starts with `<company>-`, matches the filename
- [ ] `company_id` matches the agent's company
- [ ] `process_id` exists in `tests/simulation/companies/<company>/process_*.yaml`
- [ ] `title` is a plain English sentence a business owner would write

**Actors**
- [ ] All actor IDs are taken from `org_structure.yaml` — no invented IDs
- [ ] Role labels (keys) are business-readable, not technical
- [ ] The actors referenced in `steps` are all present in the `actors` map

**Steps**
- [ ] Steps are numbered sequentially from 1
- [ ] Each step has `actor`, `action` (plain English), and `via` (gui | api | system)
- [ ] Input variable names match those defined in the process YAML `variables` section
- [ ] No Playwright selectors, API paths, or technical field names in `action` text

**Expected outcomes**
- [ ] At least one outcome with `severity: BLOCKER` covering the core happy path
- [ ] All `verification.method` values are valid (task_assigned | instance_state | audit_event | gui_screen | api_response)
- [ ] `business_impact` is plain language — what breaks for the business, not what assertion fails
- [ ] `on_fail.suggested_action` is one of: route_to_wf03 | route_to_req_analyst | none

**Cleanup**
- [ ] `cleanup.cancel_open_instances` is set (true unless explicitly chained)

---

## Output

Write the scenario to:
```
tests/simulation/scenarios/<company>-<descriptive-id>.yaml
```

Where `<descriptive-id>` describes the business situation in kebab-case:
- Good: `swiftroute-shipment-high-value-happy`
- Good: `meridian-loan-kyc-hit-manual-review`
- Bad: `test-scenario-1`
- Bad: `proc-swiftroute-shipment-approval-test`
