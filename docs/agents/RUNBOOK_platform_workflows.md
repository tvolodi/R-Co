# RUNBOOK — Platform Workflows (PW-nn)

**Version:** 1.0 · 2026-07-29
**Audience:** `ORCH`. Every other agent is reached through it.
**Entry point:** read this before dispatching any work from the ASCOA-GO borrow backlog.

---

## 1. What changed

There are now two levels of work, not one.

```
PW-nn   PLATFORM WORKFLOW   docs/workflows.yaml         (tools/wfctl.py)
  |       an end-to-end capability the platform executes
  |       documented as a process map in docs/processes/system/
  |
  +-- requirements[]        docs/requirements.yaml      (tools/reqctl.py)
  |       the implementable unit -- what WF-02 consumes
  |
  +-- uat_scenarios[]       tests/simulation/scenarios/ (UAT-RUNNER, WF-05)
          the business sign-off -- what WF-05 consumes
```

A requirement is too small to put in front of a business owner. A platform
workflow is the right size: it has a goal, a process map with actors and steps,
and scenarios someone can read and agree with. Implementation still happens one
requirement at a time through WF-02; **sign-off now happens one workflow at a
time through WF-05.**

`PW-nn` is not `WF-0n`. `WF-0n` are the development workflows this pipeline
runs. `PW-nn` are product capabilities the running platform executes. They
never appear in the same field.

**Ownership, which must not blur:**

| Tool | Owns | Never does |
|---|---|---|
| `reqctl` | requirement content and status | know anything about workflows beyond a `workflow:` field |
| `wfctl` | the workflow catalogue; derives workflow status | write to `docs/requirements.yaml` |

---

## 2. Install — run once

From the repo root, with the delivered artefacts already copied into place:

```bash
python3 tools/apply_borrow_backlog.py --dry-run   # preflight, writes nothing
python3 tools/apply_borrow_backlog.py            # registers all 92 requirements
```

The script patches `reqctl.py` for the `workflow` field, registers every
requirement through `reqctl add` (never by editing the YAML), then runs both
validators and both renderers. It is idempotent — a second run skips everything
already registered, so re-running after a partial failure is safe.

Expected end state:

```
requirements registered : 92
reqctl validate         : PASS
wfctl validate          : PASS
```

`reqctl validate` will report 4 MAJOR and 8 MINOR issues that **predate this
backlog** (`OIDC-F-06`, `TD-UI-01`, `TD-UI-02` cite unresolvable IDs;
`WH-UI-03` contains vague language; several entries have no prose body). They
are not caused by these artefacts. Do not let them block the install; register
them separately if you want them fixed.

---

## 3. The loop

### 3.1 Choose a workflow

```bash
python3 tools/wfctl.py next        # dependencies satisfied, not yet done
python3 tools/wfctl.py show PW-04  # goal, requirements, scenarios, current state
```

Read the process map named in `process_map` before dispatching anything. It is
the specification the requirements decompose; a requirement read without its
map loses the ordering constraints.

### 3.2 Implement, in batches of at most four

**The WF-02 batch cap of 4 requirements still applies.** A workflow with more
than four requirements needs more than one WF-02 run. Split by the map's own
seams, not arbitrarily:

| Workflow | Requirements | WF-02 runs |
|---|---|---|
| PW-01 | 9 | 3 — `PRM-01..04` (plan, conflict, digest, review), then `PRM-05..08` (gate, re-run, teardown, rollback), then `PRM-09` (pack update conflict resolution) |
| PW-09 | 8 | 2 — `FIL-01..04` (upload, keys, signing, isolation), then `FIL-05..08` (caps, reaper, convention, task binding) |
| PW-11 | 7 | 2 — `AGT-01..04`, then `AGT-05..07` |
| PW-16 | 7 | 2 — `GRD-UI-01..04` (guards), then `GRD-UI-05..07` (reporting, a11y, ARIA) |
| PW-06, PW-12, PW-13, PW-14 | 6 | 2 — split 3 + 3 |
| all others | 3-5 | 1 |

Carry the workflow into the handoff so the trail survives:

```json
"context": {
  "stage": "16",
  "platform_workflow": "PW-04",
  "process_map": "docs/processes/system/tenant-migration-fanout.md",
  "requirement_ids": ["MIG-01", "MIG-02", "MIG-03", "MIG-04"],
  "artifacts_in": ["docs/processes/system/tenant-migration-fanout.md"]
}
```

Everything else about WF-02 is unchanged — the hard gates at 1b and 3b, the
git-setup and git-merge bookends, DOC-UPDATER setting requirement status.

### 3.3 Watch progress

```bash
python3 tools/wfctl.py status PW-04
# PW-04  [##########..........] 3/6 MUST  IN_PROGRESS  Tenant migration fanout and resume
```

Workflow status is **derived**, never hand-set. It follows from the requirement
statuses DOC-UPDATER writes through `reqctl set-status`. Run
`python3 tools/wfctl.py render` after a WF-02 run to refresh
`docs/status/workflow_status.yaml`.

### 3.4 The UAT gate

```bash
python3 tools/wfctl.py uat-ready PW-04
```

Exit 0 means: every gating requirement is `TESTED` or `RELEASED`, every named
scenario file exists, and every dependency workflow is at least `IMPLEMENTED`.
Exit 1 prints exactly what is missing.

**ORCH must run this before dispatching WF-05.** A non-zero exit is not a
judgement call — the workflow is not eligible.

On exit 0 the command prints the dispatch block. Use it verbatim:

```
run_id           : WF05-pw-04-20260812
platform_workflow: PW-04
process_id       : sys-tenant-migration-fanout
uat_surface      : mixed
tenant_context   : platform
requirement_ids  : MIG-01, MIG-02, MIG-03, MIG-04, MIG-05, MIG-06
scenarios        :
  - tests/simulation/scenarios/platform/platform-migration-partial-failure-resume.yaml
```

### 3.5 WF-05, with one routing change

When `tenant_context` is `platform`, **skip steps 2a-sr / 2a-vx / 2a-mc and go
straight to 2b (`PRODUCT-OWNER`).** The three business-owner personas speak for
their companies; none of them performs a platform migration, and asking them to
sign off on one produces theatre rather than judgement. `PRODUCT-OWNER` remains
the hard gate.

When `tenant_context` names a company (PW-09 SwiftRoute, PW-10 Vortex), WF-05
runs unchanged — that company's BO signs off, then `PRODUCT-OWNER`.

On `APPROVED`, set `uat_status: PASS` on the workflow in `docs/workflows.yaml`
and run `wfctl render`; the workflow moves to `UAT_PASSED`. On `BLOCKED`, spawn
WF-03 per issue as usual and re-run the gate afterwards.

---

## 4. Recommended order

Dependency-correct, and ordered by the reasoning in
`docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §8.

| # | Item | Why here |
|---|---|---|
| 0 | **ISS-BRW-01** — `secrets/crypto.zig` | Not a workflow. Route to WF-03 **first**. Secrets are stored in plaintext behind envelope metadata claiming AES-256-GCM. Everything touching authenticated external calls builds on this. |
| 1 | **PW-05** DDL safety + `plat_` reservation | Smallest change on the backlog, and PW-06 depends on it. A pure validator. |
| 2 | **PW-15** tenant-scoped client cache | Small, security-relevant, no dependencies. |
| 3 | **PW-03** instance version pinning | Closes a latent correctness bug in work already specified. |
| 4 | **PW-04** migration fanout and resume | Unblocks the SPT dual-path audit finding open since 2026-06-11. |
| 5 | **PW-13** renderer state contract | Smallest step that starts paying off the written-but-unbuilt design system. |
| 6 | **PW-02** definition semantic validation | Cheap correctness win; independent. |
| 7 | **PW-01** promotion approval gate | Largest single win. Nothing currently sits between agent output and a production definition. |
| 8 | **PW-06** event log partitioning | Plan it before the table is large enough that the conversion is frightening. Depends on PW-05. |
| 9 | **PW-07**, **PW-08** ordering and backpressure | Small engine hardening. |
| 10 | **PW-14**, **PW-16** UI layer and guards | PW-14 depends on PW-13; PW-16 on PW-14. |
| 11 | **PW-09**, **PW-10** attachments and entity query | Larger product surface. Stage 17. |
| 12 | **PW-11**, **PW-12** agent artifacts and sandbox ownership | PW-11 depends on PW-03; PW-12 on PW-11. Stage 17. |

`ISS-BRW-02` (`.env.example` omits Keycloak, `BPM_UAT_TOKEN` and
`BPM_API_URL`) can go in alongside anything — it is a live onboarding defect
and a few minutes of work.

---

## 5. Work that is deliberately outside this model

`docs/workflows.yaml` has an `excluded:` block listing everything from the
borrow report that is **not** a platform workflow, so nothing is silently
dropped:

- **`defects:`** — `ISS-BRW-01` and `ISS-BRW-02`. Route to WF-03. Not
  requirements; they are broken code paths, not missing capability.
- **`development_process:`** — nine items that change the pipeline rather than
  the product: splitting `CLAUDE.md` into glob-scoped instruction files,
  numbered security invariants plus a security-reviewer agent, a Zig lint gate,
  a single command surface, the scored test-tier rubric and fail-first rule,
  test helpers applying real migrations, gate tiering and flakiness policy,
  bounded in-branch cascading fixes, an operations runbook. Route as ADHOC
  handoffs. They are not FRs and must not enter `requirements.yaml`.
- **`not_borrowed:`** — seven items examined and rejected, with the reason
  recorded. Read this before someone proposes them again.

---

## 6. Adding a workflow later

1. Write the process map into `docs/processes/system/<slug>.md` in the house
   schema — the map's Steps table carries a `| Requirement |` column, which is
   what makes it machine-linkable.
2. Add the `PW-nn` entry to `docs/workflows.yaml` with `requirements: []` and
   `status: DRAFT`.
3. Author the requirement bodies and register them:
   `python3 tools/reqctl.py add <ID> --title ... --stage ... --priority ... --body-file ... --workflow PW-nn`
4. Author the scenarios per `docs/agents/uat-scenario-schema-v1.1-addendum.md`.
5. `python3 tools/wfctl.py validate` must return `BLOCKER: 0`.

`wfctl validate` catches, as BLOCKER: a missing process map, a requirement that
is not registered, a requirement claimed by two workflows, a requirement whose
`workflow` field disagrees with the catalogue, and an unresolvable
`depends_on`. As MAJOR: a workflow with no scenarios, and a named scenario file
that does not exist.

---

## 7. Command reference

```bash
python3 tools/wfctl.py list [--status S] [--stage N] [--priority P]
python3 tools/wfctl.py show <PW-nn>
python3 tools/wfctl.py requirements <PW-nn>   # IDs only, for scripting
python3 tools/wfctl.py status [<PW-nn>]
python3 tools/wfctl.py next
python3 tools/wfctl.py uat-ready <PW-nn>      # the gate; exit 0 = dispatch WF-05
python3 tools/wfctl.py validate               # exit 1 on BLOCKER
python3 tools/wfctl.py render                 # refresh derived fields + export

python3 tools/reqctl.py add <ID> ... --workflow PW-nn
python3 tools/reqctl.py set-workflow <ID> <PW-nn>
python3 tools/reqctl.py set-status <ID> <STATUS> --implemented-in <file> ...
python3 tools/reqctl.py render-status

python3 tools/patch_reqctl_workflow.py --check   # exit 1 if the patch is absent
```

A workflow with no `MUST` requirement is gated by **all** of its requirements —
otherwise a wholly-`SHOULD` workflow would report `0/0` complete and pass the
UAT gate with nothing built. PW-08 is the only such workflow today.
