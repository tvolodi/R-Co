# BPM Platform — Simulation & UAT Manual

**Version:** 1.0 · 2026-06-04
**Audience:** Anyone running, extending, or understanding the simulation and
acceptance-testing layer of the BPM Platform.

---

## 1. Overview

The simulation layer answers three distinct questions, each handled by a
different group of agents:

| Question | Handled by | Output |
|---|---|---|
| Does the code work? | `TEST-RUNNER` (WF-04) | Technical test report |
| Does the system do what the business expects? | `UAT-RUNNER` + BO agents + `PRODUCT-OWNER` (WF-05) | UAT report + BO sign-offs + PO sign-off |
| Is the platform ready for a new tenant? | Admin saga Playwright tests | Admin process verification |

These three questions are asked in sequence before every release. None of them
substitutes for another.

---

## 2. Agent map

```
ORCH (Orchestrator)
│
│  WF-02 / WF-03 / WF-04 — engineering pipeline
│  ├── REQ-ANALYST, REQ-VALIDATOR
│  ├── CODE-DESIGNER, CODE-DESIGN-VALIDATOR
│  ├── BACKEND-DEV, FRONTEND-DEV
│  ├── TEST-DESIGNER, TEST-DESIGN-VALIDATOR
│  ├── TEST-RUNNER
│  ├── RELEASE-VALIDATOR
│  └── DOC-UPDATER
│
│  WF-05 — UAT pipeline
│  ├── UAT-RUNNER              executes scenarios, produces UAT report
│  ├── BO-SWIFTROUTE ─┐
│  ├── BO-VORTEX      ├─ parallel domain sign-offs
│  ├── BO-MERIDIAN   ─┘
│  └── PRODUCT-OWNER           cross-tenant gate → release recommendation
│
│  WF-06 — Scenario authoring
│  └── BO-<COMPANY>            author new scenario YAML
│      └── UAT-RUNNER          schema validation (hard gate)
```

### Agent responsibilities at a glance

| Agent | Speaks for | Answers |
|---|---|---|
| `UAT-RUNNER` | The platform | Did the system behave correctly against the scenarios? |
| `BO-SWIFTROUTE` | Alice Bauer / Marco Stein (SwiftRoute) | Do the logistics flows work for our operations? |
| `BO-VORTEX` | Dirk Haas / Karl Fischer (Vortex) | Do the production and quality flows meet ISO 9001? |
| `BO-MERIDIAN` | Eva / Thomas / Julia (Meridian, quorum 2-of-3) | Do the lending flows meet BaFin obligations? |
| `PRODUCT-OWNER` | The platform product team | Is this release coherent across all tenants? |
| `ORCH` | Nobody — routes, does not judge | What runs next and in what order? |

---

## 3. The three simulation companies

Each company is a self-contained test fixture with its own org structure,
process definitions, and UAT scenarios.

### SwiftRoute Ltd — small logistics (Berlin)

- **Size:** ~15 people, flat hierarchy
- **Risk profile:** Speed-first, moderate risk tolerance
- **Domain:** Last-mile courier and delivery
- **Processes:**
  - `proc-swiftroute-shipment-approval` — sequential chain + CEL conditional
    (CEO co-sign required above €500)
  - `proc-swiftroute-incident-report` — parallel fork/join + timer escalation
- **Key business rule:** CEO co-sign on high-value shipments is non-negotiable
- **Files:** `tests/simulation/companies/swiftroute/`

### Vortex Manufacturing GmbH — mid-size manufacturer (Stuttgart)

- **Size:** ~85 people, department hierarchy
- **Risk profile:** ISO 9001 certified — process integrity before speed
- **Domain:** Discrete parts manufacturing for automotive/industrial OEMs
- **Processes:**
  - `proc-vortex-production-order-release` — sequential chain + timer escalation
    + budget authority gate (€10 000 threshold)
  - `proc-vortex-supplier-quality-deviation` — sub-process spawn + compensation
    (quarantine must precede classification — ISO 9001 hard rule)
- **Key business rule:** Batch quarantine fires BEFORE severity classification
- **Files:** `tests/simulation/companies/vortex/`

### Meridian Capital AG — corporate lender (Frankfurt)

- **Size:** ~420 people, three jurisdictions
- **Risk profile:** BaFin-regulated — regulatory failure is existential
- **Domain:** SME lending (term loans, revolving credit, trade finance)
- **Processes:**
  - `proc-meridian-loan-origination` — 3-track parallel fork/join + multi-voter
    credit committee (quorum 2-of-3, threshold €500 000)
  - `proc-meridian-regulatory-compliance-review` — timer boundary event +
    conditional sub-process + DLQ path + BaFin notification
- **Key business rule:** BaFin regulatory notice on 30-day SLA breach is a
  legal obligation — always BLOCKER if missing
- **Files:** `tests/simulation/companies/meridian/`

---

## 4. Business process sagas

Sagas are end-to-end Playwright pipeline tests that drive the real GUI with
no human interaction. Each saga is a `pl.step()` chain — state flows forward,
cleanup runs unconditionally.

### 4.1 Company onboarding saga

**File:** `web/tests/e2e/pipelines/sim-company-onboarding.pipeline.e2e.spec.ts`
**Spec:** `tests/specs/PIPELINE-sim-company-onboarding.md`
**Company fixture:** SwiftRoute Ltd

What it covers:

```
users-page visible
→ create CEO user          Alice Bauer
→ create Ops Manager       Marco Stein
→ create Driver            Jan Müller
→ create Operations group  department
→ add CEO to group         via UI dialog
→ add Ops Manager to group via API
→ verify member count ≥ 1  in Groups table
→ assign PROCESS_OPERATOR  to Ops Manager
→ assign TASK_WORKER       to Driver
→ search confirms all users exist
→ cleanup: deactivate all
```

**When to run:** After any change to the Users or Groups admin pages, or
after an identity/auth change that could affect role assignment.

**Run it:**
```bash
cd web
npx playwright test pipelines/sim-company-onboarding --headed
```

### 4.2 Admin processes saga

**File:** `web/tests/e2e/pipelines/sim-admin-processes.pipeline.e2e.spec.ts`
**Spec:** `tests/specs/PIPELINE-sim-admin-processes.md`

What it covers:

```
health dashboard           screen shows status indicators
→ metrics page             screen shows metric content
→ audit log table visible  entries render
→ audit log filter         filtered view renders
→ create test user
→ assign PROCESS_DESIGNER role   screen shows "Saved"
→ role visible in user list      Roles column non-empty
→ issue API token          "will not be shown again" warning visible
→ verify token in list     ACTIVE status badge
→ revoke token             REVOKED status visible
→ deactivate user          INACTIVE status visible
→ cleanup: deactivate via API
```

**When to run:** After any change to the admin UI (users, groups, tokens,
audit, health, metrics pages), or after auth/identity changes.

**Run it:**
```bash
cd web
npx playwright test pipelines/sim-admin-processes --headed
```

### 4.3 UAT business process scenarios

These are not Playwright tests — they are business-language YAML files
executed by `UAT-RUNNER` against the live platform. Each scenario describes
what a business actor does and what the business expects to happen.

**Current scenarios:**

| File | Process | Path tested |
|---|---|---|
| `swiftroute-shipment-high-value-happy.yaml` | Shipment approval | Happy path: dispatcher → ops approve → CEO co-sign → released |
| `swiftroute-shipment-ops-timeout-escalation.yaml` | Shipment approval | Escalation: ops timer fires → CEO receives escalated task |

**Scenarios are authored by BO agents via WF-06** — not by developers.

---

## 5. Admin saga — platform-level processes

The admin saga (§4.2) covers the *technical* admin workflows through the UI.
But there is also a *business* dimension: what does a platform administrator
need to verify from a business perspective when setting up a new tenant?

This is owned by `PRODUCT-OWNER`, not by any company BO, because it concerns
the platform itself — not a specific tenant's domain.

### What the admin business process covers

1. **Tenant provisioning** — can a new company be onboarded end-to-end?
   (`POST /api/v1/onboarding` → users → groups → process definitions active)
2. **Role integrity** — do role assignments propagate correctly to task routing?
3. **Audit completeness** — does every business action leave an audit trail?
4. **Token lifecycle** — can service accounts be issued, used, and revoked safely?
5. **Health observability** — does the health dashboard reflect the true system state?

### Current state

The Playwright saga (§4.2) covers items 3–5 through the UI.
Items 1–2 are covered by `seed.py` + the company onboarding saga (§4.1).

A `PRODUCT-OWNER`-owned UAT scenario for admin processes does not exist yet.
It belongs in `tests/simulation/scenarios/admin-tenant-provisioning.yaml` and
would be authored via WF-06 with `PRODUCT-OWNER` as the author (no company
affiliation — platform-level scenario).

**To create it:**
```
Ask ORCH: "Author a UAT scenario for the platform admin tenant provisioning process"
→ ORCH launches WF-06 routing to PRODUCT-OWNER as author
→ UAT-RUNNER validates schema
→ Committed to tests/simulation/scenarios/
```

---

## 6. How the agents relate — the full flow

### A feature is built (WF-02)

```
ORCH
 └─ CODE-DESIGNER → CODE-DESIGN-VALIDATOR (gate)
 └─ BACKEND-DEV / FRONTEND-DEV
 └─ TEST-DESIGNER → TEST-DESIGN-VALIDATOR (gate)
 └─ TEST-RUNNER
 └─ RELEASE-VALIDATOR
 └─ DOC-UPDATER
 └─ BACKEND-DEV (git merge, Step Final)

  ↓ WF-02 completes green
  ↓ ORCH checks: does this process have scenario files?

If NO → ORCH triggers WF-06 (scenario authoring)
If YES → ORCH triggers WF-05 (UAT run)
```

### Scenarios are authored (WF-06)

```
ORCH dispatches BO-<COMPANY> with brief
  ↓
BO-<COMPANY> writes YAML to tests/simulation/scenarios/
  ↓
UAT-RUNNER validates schema (hard gate — no execution)
  ↓
BACKEND-DEV commits to main
```

### UAT is run (WF-05)

```
UAT-RUNNER
  pre-flight check (backend + Keycloak + seed data)
  executes each scenario (Playwright + API)
  evaluates outcomes against expected_outcomes
  writes tests/uat-reports/uat-<date>-<run_id>.yaml
  ↓
ORCH dispatches BO agents — in PARALLEL:
  ├─ BO-SWIFTROUTE  reads SwiftRoute scenarios → bo-signoff-swiftroute-*.yaml
  ├─ BO-VORTEX      reads Vortex scenarios    → bo-signoff-vortex-*.yaml
  └─ BO-MERIDIAN    reads Meridian scenarios  → bo-signoff-meridian-*.yaml
                    (quorum 2-of-3)
  ↓
PRODUCT-OWNER (hard gate)
  reads all three BO sign-offs
  checks cross-tenant coherence
  checks MUST requirement coverage
  writes tests/uat-reports/po-signoff-*.yaml
  verdict: APPROVED or BLOCKED
  ↓
APPROVED → RELEASE-VALIDATOR → DOC-UPDATER → git merge
BLOCKED  → ORCH spawns WF-03 per issue → re-runs WF-05
```

---

## 7. When to run what

| Situation | What to run |
|---|---|
| Changed the Users or Groups admin page | `sim-company-onboarding` saga |
| Changed any admin UI (tokens, audit, health, metrics) | `sim-admin-processes` saga |
| Implemented a new process feature | WF-05 (ORCH does this automatically after WF-02) |
| New process has no scenario files yet | WF-06 (ORCH auto-triggers after WF-02) |
| Want to manually add a UAT scenario | Tell ORCH: "add a scenario for [process] [situation]" |
| Full release validation | Tell ORCH: "run UAT" → WF-05 runs the complete pipeline |
| Seeding a fresh environment | `python tests/simulation/seed.py` |
| Validating YAML only | `python tests/simulation/seed.py --dry-run` |

---

## 8. Seed data

The simulation layer requires static fixture data to be present before any
UAT scenario or saga test can run.

```bash
# Install dependencies (first time)
pip install httpx pyyaml

# Validate YAML without calling the API
python tests/simulation/seed.py --dry-run

# Seed all three companies (creates tenants, users, groups, process definitions)
BPM_API_URL=http://localhost:3000 \
BPM_API_TOKEN=<platform-admin-token> \
  python tests/simulation/seed.py

# Seed one company only
BPM_API_URL=http://localhost:3000 \
BPM_API_TOKEN=<platform-admin-token> \
  python tests/simulation/seed.py --company swiftroute

# Seed process definitions only (skip tenant/user/group creation)
BPM_API_URL=http://localhost:3000 \
BPM_API_TOKEN=<platform-admin-token> \
  python tests/simulation/seed.py --processes-only
```

Seed is **idempotent** — safe to re-run. A 409 response means the entity
already exists and is left unchanged.

### What seed.py creates

| YAML | API call | Creates |
|---|---|---|
| `company.yaml` | `POST /api/v1/onboarding` | Tenant + OIDC realm + admin user |
| `org_structure.yaml` people | `POST /api/v1/users` | User accounts |
| `org_structure.yaml` departments | `POST /api/v1/admin/groups` + members | Department groups with members |
| `process_*.yaml` | `POST /api/v1/definitions` → activate | Active process definitions |

---

## 9. Stable actor IDs

Actor IDs defined in `org_structure.yaml` are stable across seed runs.
Use them directly in integration tests and scenario YAML files.

```python
# tests/simulation/companies/*/org_structure.yaml
ACTORS = {
    "swiftroute": {
        "ceo":         "actor-swiftroute-alice",
        "ops_manager": "actor-swiftroute-marco",
        "dispatcher":  "actor-swiftroute-lena",
        "driver":      "actor-swiftroute-jan",
    },
    "vortex": {
        "ceo":         "actor-vortex-dirk",
        "qm":          "actor-vortex-karl",
        "planner":     "actor-vortex-anna",
        "pm":          "actor-vortex-sabine",
    },
    "meridian": {
        "ceo":         "actor-meridian-eva",
        "cro":         "actor-meridian-thomas",
        "credit_dir":  "actor-meridian-julia",
        "analyst":     "actor-meridian-sophie",
        "compliance":  "actor-meridian-claudia",
    },
}
```

---

## 10. File map

```
tests/simulation/
  companies/
    swiftroute/
      company.yaml                   tenant identity + BPM config
      org_structure.yaml             departments, roles, people, actor IDs
      process_shipment_approval.yaml sequential chain + conditional branch
      process_incident_report.yaml   parallel fork/join + timer escalation
    vortex/
      company.yaml
      org_structure.yaml
      process_production_order_release.yaml   timer escalation + authority routing
      process_supplier_quality_deviation.yaml sub-process + compensation
    meridian/
      company.yaml
      org_structure.yaml
      process_loan_origination.yaml           3-track parallel + multi-voter
      process_regulatory_compliance_review.yaml  timer boundary + DLQ
  scenarios/
    swiftroute-shipment-high-value-happy.yaml
    swiftroute-shipment-ops-timeout-escalation.yaml
    <future: vortex-*, meridian-*, admin-* scenarios>
  seed.py                            idempotent data seeder
  README.md                          extended documentation

tests/uat-reports/
  uat-<date>-<run_id>.yaml           UAT execution report (UAT-RUNNER)
  bo-signoff-swiftroute-*.yaml       SwiftRoute domain sign-off (BO-SWIFTROUTE)
  bo-signoff-vortex-*.yaml           Vortex domain sign-off (BO-VORTEX)
  bo-signoff-meridian-*.yaml         Meridian group sign-off (BO-MERIDIAN)
  po-signoff-*.yaml                  Platform release recommendation (PRODUCT-OWNER)

web/tests/e2e/pipelines/
  sim-company-onboarding.pipeline.e2e.spec.ts   company setup saga
  sim-admin-processes.pipeline.e2e.spec.ts      admin operational saga
  admin-user-lifecycle.pipeline.e2e.spec.ts     user CRUD lifecycle

tests/specs/
  PIPELINE-sim-company-onboarding.md   spec for company onboarding saga
  PIPELINE-sim-admin-processes.md      spec for admin processes saga

docs/agents/
  UAT_RUNNER.md            UAT-RUNNER full agent specification
  BO_SWIFTROUTE.md         SwiftRoute business owner specification
  BO_VORTEX.md             Vortex business owner specification
  BO_MERIDIAN.md           Meridian business owner specification (group)
  PRODUCT_OWNER.md         Product Owner specification
  uat-scenario-schema.md   Scenario YAML schema + annotated examples
  workflows/
    WF-05_uat_run.md        UAT run pipeline definition
    WF-06_scenario_authoring.md  Scenario authoring pipeline definition

.github/agents/
  uat-runner.agent.md       GitHub Copilot agent
  bo-swiftroute.agent.md    GitHub Copilot agent
  bo-vortex.agent.md        GitHub Copilot agent
  bo-meridian.agent.md      GitHub Copilot agent
  product-owner.agent.md    GitHub Copilot agent
  orchestrator.agent.md     Updated with WF-05 / WF-06
```

---

## 11. BPM primitive coverage across all processes

Every process in the simulation exercises a distinct BPM engine primitive.
Together they form a complete regression suite for the execution engine.

| Process | Primitive | Stage it tests |
|---|---|---|
| SwiftRoute: Shipment Approval | Sequential chain + CEL branch | Stage 3/7 |
| SwiftRoute: Incident Report | Parallel fork/join + timer escalation | Stage 4/5 |
| Vortex: Production Order Release | Sequential + timer escalation + authority routing | Stage 4/5 |
| Vortex: Supplier Quality Deviation | Sub-process spawn + compensation task | Stage 6 |
| Meridian: Loan Origination | 3-track parallel fork/join + multi-voter committee | Stage 4/6 |
| Meridian: Regulatory Review | Timer boundary event + conditional sub-process + DLQ | Stage 5/6 |

---

## 12. Stage 12 — self-developing system context

The current agent setup (ORCH + UAT-RUNNER + BO agents + PRODUCT-OWNER) is
the **prototype of Stage 12** — the AI Agent Pipeline deferred in the
requirements spec.

When Stage 12 is built:

| Now (agents running in Claude Code / GitHub Copilot) | Stage 12 (agents running inside the BPM engine) |
|---|---|
| Scenario YAML files | Process instance data in Platform Repository (Stage 10) |
| `UAT-RUNNER` calling Playwright | Service-task node calling `POST /test/run` (Stage 11) |
| `BO-MERIDIAN` quorum 2-of-3 | `multi-voter-task` node in `meridian-uat-sign-off` process |
| `PRODUCT-OWNER` sign-off | Tier 4 node in `platform-release-approval` process |
| BO agent's LLM verdict | Captured as audit event, replayed from that capture (XC-05) |
| Human checkpoint (manual review) | Hard gate before/after every Tier 4 node (Stage 12 constraint) |

The workflows you run today become the process definitions that run inside
the engine you are building.
