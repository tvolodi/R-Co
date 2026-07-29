# UAT Scenario Schema — v1.1 Addendum: Platform Workflows

**Version:** 1.1 · 2026-07-29
**Extends:** `docs/agents/uat-scenario-schema.md` (v1.0, 2026-06-04)
**Status:** additive — every v1.0 scenario file remains valid unchanged
**Read by:** `UAT-RUNNER`, `PRODUCT-OWNER`
**Written by:** business owner agents (`BO-*`) via WF-06, or `REQ-ANALYST` for platform workflows

---

## Why this addendum exists

v1.0 assumes every scenario belongs to one of the three simulated tenant
companies and that every step is performed by a business user in a browser:

```yaml
company_id: <swiftroute | vortex | meridian>   # required
via: gui                                        # the only permitted step type
verification.method: gui_screen | task_assigned | instance_state | audit_event
```

That holds for tenant business processes. It does not hold for **platform
workflows** (`PW-nn` in `docs/workflows.yaml`) — capabilities the platform
itself executes, such as applying a migration across every tenant schema,
dropping an aged event-log partition, or serialising effect completions within
a correlation. No business user performs those steps, and several have no
screen at all.

Without this addendum such a workflow could only be marked `no-uat`, which
means a platform workflow could be declared complete with no business-readable
sign-off. v1.1 closes that hole while keeping v1.0's discipline everywhere it
still applies.

---

## 1. `company_id: platform`

`company_id` gains one additional value:

```yaml
company_id: platform
```

**Meaning.** The scenario exercises the platform itself rather than a tenant's
business process. `UAT-RUNNER` does not resolve a tenant UUID or Keycloak realm
from `GET /api/v1/tenants/{company_id}`; it authenticates with the platform
operator identity from `BPM_UAT_TOKEN` and treats `BPM_API_URL` as the target.

**When a scenario belongs to a company instead.** If a business user of
SwiftRoute, Vortex or Meridian would notice the behaviour, the scenario keeps
its company. Attaching a delivery note to a shipment task (PW-09) is a
SwiftRoute scenario even though the attachment subsystem is platform code. Use
`platform` only when the actor is the platform operator or the platform itself.

**Business owner routing.** A `company_id: platform` scenario is evaluated by
`PRODUCT-OWNER` directly. The three `BO-*` agents are not asked to sign off on
a process none of their people perform. `PRODUCT-OWNER` remains the hard gate.

---

## 2. `platform_workflow` — the link back to the catalogue

A new **required** field for platform workflow scenarios, optional for tenant
scenarios:

```yaml
platform_workflow: PW-04           # must resolve in docs/workflows.yaml
process_id: sys-tenant-migration-fanout
```

`tools/wfctl.py uat-ready <PW-nn>` will not release a workflow to WF-05 unless
every scenario named in the catalogue exists as a file. This field is the
reverse link, so a scenario file on its own says which workflow it signs off.

---

## 3. `via: system` — a step no human performs

`via` gains one additional value beyond `gui`:

```yaml
via: system
```

**Meaning.** The step is performed by a platform component — the scheduler, the
migration runner, the effects worker, the reaper — with no human actor.
`UAT-RUNNER` drives it through the platform operator API or by advancing the
virtual clock, and records what it invoked as evidence.

**`via: api` remains forbidden.** v1.0 removed it because a missing UI is a
BLOCKER, not a reason to bypass the browser. That rule is unchanged. `system`
is not a rehabilitation of `api`: it is only valid where **no** user interface
could exist, because no user performs the step.

**The test that decides.** Ask: *would a person ever do this?* If yes, it is
`gui`, and if there is no screen for it, register a missing-UI BLOCKER exactly
as v1.0 requires. If no — a scheduler creating next month's partition, a
consumer taking an advisory lock — it is `system`.

**Hard constraint.** A scenario whose workflow has `uat_surface: gui` in
`docs/workflows.yaml` may not contain a `via: system` step. `UAT-RUNNER`
rejects the scenario as malformed rather than silently downgrading it.

Permitted step types by `uat_surface`:

| `uat_surface` | `via: gui` | `via: system` |
|---|---|---|
| `gui` | required | forbidden |
| `mixed` | at least one step | permitted |
| `system` | permitted | permitted |

---

## 4. `verification.method: system_state`

One additional verification method:

```yaml
verification:
  method: system_state
  detail: >
    <what specifically to check, in business language>
  evidence: >
    <what UAT-RUNNER captures to prove it: an operator screen, a status
     endpoint payload, a log line, a row count>
```

**When it is allowed.** Only for an outcome with no possible screen
representation. If the platform has an operator console that shows the state,
the correct method is `gui_screen` against that console — `system_state` is not
a shortcut around building the admin UI.

**`evidence` is required** for `system_state` (it is optional elsewhere).
Without a screenshot, the evidence trail is whatever the runner captured, so it
must be named up front. `PRODUCT-OWNER` rejects a `system_state` outcome whose
`evidence` field is empty.

**The report-language rule still applies, unchanged.** `description`,
`detail` and every `business_impact` must be readable by a non-technical
stakeholder. Stack traces, selector strings, Zig function names, SQL and line
numbers remain forbidden in the UAT report.

Correct: *"Tenants that failed the first migration attempt were retried on
resume, and no tenant that already succeeded was touched a second time."*

Forbidden: *"platform_migrations rows WHERE status='failed' re-processed by
ResumeAllTenants; xmax=0 on 3 rows."*

---

## 5. `operator` as an actor

Platform scenarios may name the platform operator without an entry in any
company's `org_structure.yaml`:

```yaml
actors:
  operator: actor-platform-admin      # resolved from BPM_UAT_TOKEN
  scheduler: actor-system-scheduler   # a platform component, not a person
```

Actor IDs beginning `actor-system-` denote platform components. They can only
appear on `via: system` steps. `UAT-RUNNER` does not attempt to obtain a
credential for them.

---

## 6. Full example — a `system` surface scenario

```yaml
---
id: platform-partition-retention-drop
company_id: platform
platform_workflow: PW-06
process_id: sys-event-log-partitioning
title: Aged event history is retired without a long-running database operation
version: "1.0"
tags: [retention, regression]

description: >
  The platform keeps a complete history of everything that happened in every
  process. That history has to be retired on a schedule, and until now retiring
  it meant moving records one at a time, which locks the history table for as
  long as it takes. This scenario checks that a month of expired history is
  retired in a single step, that protected records are never removed, and that
  older process instances can still be replayed afterwards.

actors:
  operator:  actor-platform-admin
  scheduler: actor-system-scheduler

preconditions:
  - description: The platform holds event history spanning at least three months
    check: custom
    detail: >
      Confirm that history exists for the current month and the two months
      before it, so there is something old enough to retire.
  - description: At least one completed process instance exists in the oldest month
    check: custom
    detail: >
      The scenario replays this instance after retirement to prove history
      remains usable.

steps:
  - step: 1
    actor: scheduler
    action: >
      Creates the storage area for next month's history ahead of time, so no
      process ever waits for storage to be prepared while it is running.
    via: system
    produces:
      next_period: the storage area prepared for the coming month
    sla_context:
      expected_within_hours: null

  - step: 2
    actor: operator
    action: >
      Retires the oldest month of expired history from the operator console.
    via: gui
    input:
      period: the oldest month held
    produces:
      retirement_id: the record of this retirement shown on screen

expected_outcomes:
  - id: EO-001
    description: >
      The month of expired history is retired in one step rather than record by
      record, and the platform stays responsive to other work throughout.
    verification:
      method: system_state
      detail: >
        The retirement completes as a single operation and the platform
        continues to accept new work while it runs.
      evidence: >
        The operator console retirement record, plus the platform health screen
        showing the service responsive for the duration.
    on_fail:
      severity: MAJOR
      business_impact: >
        Retiring old history would slow or stall the whole platform for every
        company at once, on a schedule.
      suggested_action: route_to_wf03

  - id: EO-002
    description: >
      No protected record is removed. Everything the platform is required to
      keep for audit is still there after the retirement.
    verification:
      method: system_state
      detail: >
        The count of protected records is identical before and after.
      evidence: >
        The operator console retention summary, captured before and after.
    on_fail:
      severity: BLOCKER
      business_impact: >
        Records the platform is obliged to retain for audit would be destroyed.
        This is a compliance failure that cannot be undone.
      suggested_action: route_to_wf03

  - id: EO-003
    description: >
      A process that ran in an older month can still be opened and its full
      history reviewed after the retirement.
    verification:
      method: gui_screen
      detail: >
        Opening that process instance shows its complete step history on screen,
        with no gap and no error.
    on_fail:
      severity: BLOCKER
      business_impact: >
        Historical processes would become unreadable, so nobody could review
        what happened or why a decision was taken.
      suggested_action: route_to_wf03

cleanup:
  cancel_open_instances: false
  description: >
    Retirement is not reversible. Run this scenario only against a test
    environment holding disposable history.
```

---

## 7. Changes required in consuming agents

| Agent / file | Change |
|---|---|
| `UAT-RUNNER` (`docs/agents/UAT_RUNNER.md`) | Accept `company_id: platform`; resolve credentials from `BPM_UAT_TOKEN` instead of the company lookup. Accept `via: system` and `system_state`. Enforce the `uat_surface` table in §3. Require `evidence` on every `system_state` outcome. |
| `PRODUCT-OWNER` (`docs/agents/PRODUCT_OWNER.md`) | Evaluate `company_id: platform` scenarios directly; do not wait for `BO-*` sign-off files for those. Reject any `system_state` outcome with an empty `evidence` field. |
| `BO-SWIFTROUTE` / `BO-VORTEX` / `BO-MERIDIAN` | No change. They never receive a `platform` scenario. |
| `ORCH` (`docs/agents/ORCHESTRATOR.md`) | Before dispatching WF-05, run `python3 tools/wfctl.py uat-ready <PW-nn>`; a non-zero exit means the workflow is not eligible. Use the printed dispatch block as the handoff context. |
| `WF-05` (`docs/agents/workflows/WF-05_uat_run.md`) | Add `platform_workflow` to the run context. When it is set and `company_id` is `platform`, skip steps 2a-sr / 2a-vx / 2a-mc and go straight to 2b (`PRODUCT-OWNER`). |
| `WF-06` (`docs/agents/workflows/WF-06_scenario_authoring.md`) | Allow `REQ-ANALYST` as an author for `company_id: platform` scenarios, since no `BO-*` persona owns them. |

---

## 8. Validation rules a scenario must satisfy

`UAT-RUNNER` rejects a scenario file as malformed, with a MAJOR issue, when:

1. `company_id` is not one of `platform`, `swiftroute`, `vortex`, `meridian`.
2. `company_id: platform` and `platform_workflow` is absent.
3. `platform_workflow` does not resolve in `docs/workflows.yaml`.
4. `platform_workflow` is set and the scenario id is not listed in that
   workflow's `uat_scenarios`.
5. A `via: system` step appears in a workflow whose `uat_surface` is `gui`.
6. A workflow whose `uat_surface` is `gui` or `mixed` has no `via: gui` step.
7. A `system_state` outcome has an empty or missing `evidence` field.
8. An `actor-system-*` actor appears on a `via: gui` step.
9. Any `description`, `detail`, `evidence` or `business_impact` contains a
   stack trace, a selector string, a file path with a line number, a SQL
   statement, or a Zig or TypeScript function name.
