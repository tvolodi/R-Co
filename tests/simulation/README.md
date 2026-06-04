# Simulation Layer

Static fixture data and pipeline saga tests for end-to-end BPM testing.
All tests are fully automated — no human interaction required.

## Structure

```
tests/simulation/
  companies/
    swiftroute/          Small logistics company (~15 people)
    vortex/              Mid-size manufacturer (~85 people)
    meridian/            Corporate lender (~420 people)
  scenarios/             Layer 2 — dynamic scenario scripts (future)
  seed.py                Seeds Layer 1 into the running platform
  README.md              This file

web/tests/e2e/pipelines/
  sim-company-onboarding.pipeline.e2e.spec.ts   Saga: company setup journey
  sim-admin-processes.pipeline.e2e.spec.ts      Saga: admin operational workflows

tests/specs/
  PIPELINE-sim-company-onboarding.md            Spec doc for company onboarding saga
  PIPELINE-sim-admin-processes.md               Spec doc for admin processes saga
```

---

## Layer 1 — Static Fixtures

Each company directory contains:

| File | Purpose |
|---|---|
| `company.yaml` | Identity, domain, BPM tenant config |
| `org_structure.yaml` | Departments, roles, people, actor IDs |
| `process_<name>.yaml` | Process definition (nodes, edges, variables, SLAs) |

### BPM primitive coverage

| Company | Process | Primitive exercised |
|---|---|---|
| SwiftRoute | Shipment Approval | Sequential chain + CEL conditional branch |
| SwiftRoute | Driver Incident Report | Parallel fork/join + timer escalation |
| Vortex | Production Order Release | Sequential chain + timer escalation + authority routing |
| Vortex | Supplier Quality Deviation | Sub-process spawn + compensation task |
| Meridian | Loan Origination | 3-track parallel fork/join + multi-voter committee |
| Meridian | Regulatory Compliance Review | Timer boundary event + conditional sub-process + DLQ path |

### Seeding

```bash
# Dry-run (validates YAML only):
python tests/simulation/seed.py --dry-run

# Seed all companies (creates tenants, users, groups, process definitions):
BPM_API_URL=http://localhost:3000 BPM_API_TOKEN=<admin-token> \
  python tests/simulation/seed.py

# Seed one company only:
BPM_API_URL=http://localhost:3000 BPM_API_TOKEN=<admin-token> \
  python tests/simulation/seed.py --company meridian

# Seed process definitions only (skip tenant/user/group creation):
BPM_API_URL=http://localhost:3000 BPM_API_TOKEN=<admin-token> \
  python tests/simulation/seed.py --processes-only
```

Seed is **idempotent** — safe to re-run after feature changes.
A 409 response means the entity already exists and is left unchanged.

The seed script maps company YAML to real API endpoints:

| YAML | API endpoint |
|---|---|
| `company.yaml` | `POST /api/v1/onboarding` |
| `org_structure.yaml` people | `POST /api/v1/users` |
| `org_structure.yaml` departments | `POST /api/v1/admin/groups` + members |
| `process_*.yaml` | `POST /api/v1/definitions` → activate |

### Using fixture actor IDs in integration tests

```zig
// Actor IDs defined in org_structure.yaml are stable across seeds:
const lena   = "actor-swiftroute-lena";
const marco  = "actor-swiftroute-marco";
const tenant = "tenant-swiftroute-001";
```

```python
ACTORS = {
    "swiftroute": {
        "dispatcher":  "actor-swiftroute-lena",
        "ops_manager": "actor-swiftroute-marco",
        "ceo":         "actor-swiftroute-alice",
    },
    "vortex": {
        "planner":     "actor-vortex-anna",
        "qm":          "actor-vortex-karl",
    },
    "meridian": {
        "analyst":     "actor-meridian-sophie",
        "cro":         "actor-meridian-thomas",
    },
}
```

---

## Layer 1b — Saga Pipeline Tests

Two Playwright pipeline tests exercise the full company setup and admin
operational journeys through the real GUI. Both are self-contained and
leave no orphaned data (cleanup runs unconditionally via `pl.onCleanup`).

### Saga 1: Company Onboarding

**File:** `web/tests/e2e/pipelines/sim-company-onboarding.pipeline.e2e.spec.ts`
**Spec:** `tests/specs/PIPELINE-sim-company-onboarding.md`

Drives a PLATFORM_ADMIN through setting up a company from scratch:

```
users-page-sanity
→ create CEO user
→ create Ops Manager user
→ create Driver user
→ create Operations department group
→ add CEO to group (via UI dialog)
→ add Ops Manager to group (via API, verified in UI)
→ verify group member count in Groups table
→ assign PROCESS_OPERATOR role to Ops Manager
→ assign TASK_WORKER role to Driver
→ verify all users visible in search
→ cleanup: deactivate all created users
```

### Saga 2: Admin Business Processes

**File:** `web/tests/e2e/pipelines/sim-admin-processes.pipeline.e2e.spec.ts`
**Spec:** `tests/specs/PIPELINE-sim-admin-processes.md`

Drives a PLATFORM_ADMIN through the day-to-day operational admin workflows:

```
health-dashboard (screen shows status indicators)
→ metrics-page (screen shows metric content)
→ audit-log table renders
→ audit-log filtered by actor
→ create test user
→ assign PROCESS_DESIGNER role (screen shows "Saved")
→ verify role visible in user list
→ issue API token (screen shows "will not be shown again" warning)
→ verify token in list with ACTIVE status
→ revoke token (screen shows REVOKED)
→ deactivate user (screen shows INACTIVE)
→ cleanup: deactivate user via API
```

### Running the sagas

```bash
cd web

# Run all simulation sagas:
npx playwright test pipelines/sim-

# Run company onboarding saga only:
npx playwright test pipelines/sim-company-onboarding

# Run admin processes saga only:
npx playwright test pipelines/sim-admin-processes

# Run with headed browser (useful for debugging):
npx playwright test pipelines/sim- --headed
```

Screenshots are saved to `tests/screenshots/pipelines/` after each step.

---

## Known Gaps

### No TENANT_ADMIN role

The current platform has a single `PLATFORM_ADMIN` role. There is no
tenant-scoped admin role. This means:

- All saga tests run as `PLATFORM_ADMIN`
- Users created in one company can be seen by admins of other companies
- A "company admin" cannot manage their own tenant independently

**Future work:** When `TENANT_ADMIN` (or equivalent) is implemented, new
sagas should be added that:
1. A PLATFORM_ADMIN creates a tenant and assigns a TENANT_ADMIN
2. The TENANT_ADMIN logs in and manages their own users/groups
3. Verify TENANT_ADMIN *cannot* see other tenants' data
4. Verify TENANT_ADMIN *cannot* access cross-tenant audit logs

Until then, these are documented in both saga spec files.

---

## Layer 2 — Scenarios (future)

Scenario scripts will live in `tests/simulation/scenarios/` and drive
ordered sequences of API calls against the seeded Layer 1 data to produce
dynamic process history. Each scenario will be a YAML file describing
steps (actor, action, variables, expected outcome), with a Python runner
that replays them against the live platform and asserts results.

Example scenarios planned:
- SwiftRoute: happy-path shipment approval (low value, no CEO sign-off)
- SwiftRoute: escalated shipment approval (high value, CEO required)
- SwiftRoute: incident report with parallel tracks and timer timeout
- Vortex: production order with finance sign-off path
- Meridian: loan origination with KYC hit and manual compliance review
- Meridian: regulatory review with critical finding and remediation sub-process
