# INSTALL — Platform Workflow backlog for R-Co

**Generated:** 2026-07-29
**Source:** `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md`
**Contains:** 16 platform workflows, 16 process maps, 92 functional requirements,
20 UAT scenarios, and the tooling that links them.

Everything here has been executed end-to-end against a copy of the real
`docs/requirements.yaml` (359 existing entries). Both validators pass, and every
step is idempotent.

---

## For the agent running this

Two commands, from the repo root:

```bash
python3 tools/apply_borrow_backlog.py --dry-run   # preflight only, writes nothing
python3 tools/apply_borrow_backlog.py             # registers everything
```

Then read `docs/agents/RUNBOOK_platform_workflows.md` — it is the operating
procedure for ORCH, including the WF-02 batch splits and the WF-05 gate.

Expected output of the second command:

```
requirements registered : 92
reqctl validate         : PASS
wfctl validate          : PASS
```

**Do not edit `docs/requirements.yaml` by hand.** Everything goes through
`reqctl`, which the apply script drives for you.

---

## What lands where

| Path | Count | What it is |
|---|---|---|
| `docs/workflows.yaml` | 1 | The PW-nn catalogue. New canonical file. |
| `docs/processes/system/*.md` | 16 | Process maps, in the existing house schema, one per workflow. |
| `docs/agents/RUNBOOK_platform_workflows.md` | 1 | ORCH operating procedure. **Start here.** |
| `docs/agents/uat-scenario-schema-v1.1-addendum.md` | 1 | Additive schema change so platform workflows can be UAT-gated. |
| `tools/wfctl.py` | 1 | Workflow catalogue CLI. Read/verify only; never writes requirements. |
| `tools/patch_reqctl_workflow.py` | 1 | Idempotent patch teaching `reqctl` the `workflow` field. Backs up the original. |
| `tools/apply_borrow_backlog.py` | 1 | The one-shot applier. |
| `backlog/meta-*.yaml` | 4 | Title / stage / priority / workflow per requirement. |
| `backlog/bodies/*.md` | 92 | Requirement bodies in the existing SOL-01 format. |
| `tests/simulation/scenarios/platform/*.yaml` | 18 | Platform UAT scenarios. |
| `tests/simulation/scenarios/*.yaml` | 2 | Tenant UAT scenarios (SwiftRoute PW-09, Vortex PW-10). |

Nothing overwrites an existing file except `tools/reqctl.py`, which is patched
in place with a timestamped `.bak-<UTC>` backup written alongside it.

`backlog/` is input to the applier, not a permanent artefact. Once the
requirements are registered, `docs/requirements.yaml` holds the content and
`backlog/` can be deleted or left as provenance.

---

## The model, in one paragraph

A **platform workflow** (`PW-nn`) is an end-to-end capability the platform
executes — promoting a definition with approval, running a migration across
every tenant, retiring a month of event history. It is documented as a process
map, delivered by a set of functional requirements, and signed off as a whole
by a WF-05 UAT run. Requirements stay the unit WF-02 implements; workflows
become the unit a business owner signs off. `PW-nn` is deliberately distinct
from `WF-0n`, which remain the development workflows this pipeline runs.

```
PW-04  Tenant migration fanout and resume
  |-- docs/processes/system/tenant-migration-fanout.md
  |-- MIG-01 .. MIG-06                        (docs/requirements.yaml)
  +-- platform-migration-partial-failure-resume  (UAT scenario)
```

The gate you asked for:

```bash
python3 tools/wfctl.py uat-ready PW-04
```

Exit 0 means every gating requirement is `TESTED` or `RELEASED`, every scenario
file exists, and every dependency workflow is at least `IMPLEMENTED` — and it
prints the WF-05 dispatch block ready to paste into a handoff. Exit 1 prints
exactly what is missing.

---

## Three things to know before running

1. **`reqctl validate` will report 4 MAJOR and 8 MINOR issues that predate this
   backlog** — `OIDC-F-06`, `TD-UI-01` and `TD-UI-02` cite unresolvable IDs,
   `WH-UI-03` contains vague language, and several old entries have no prose
   body. None come from these artefacts. `BLOCKER` is 0 before and after.

2. **The 92 new requirements land as `DRAFT`.** They have not been through
   WF-01 validation. Run REQ-VALIDATOR over a workflow's requirements before
   dispatching WF-02 for it, or accept them as-is and let the design validators
   at WF-02 steps 1b and 3b do the catching.

3. **One defect from the report is not a requirement and should go first.**
   `src/secrets/crypto.zig` does not encrypt — `encrypt()` discards the master
   key and sets `ciphertext = dupe(plaintext)` while the envelope declares
   `aes_256_gcm`. It is recorded as `ISS-BRW-01` in the `excluded:` block of
   `docs/workflows.yaml`. Route it to WF-03 before anything else here.

---

## Quick tour once installed

```bash
python3 tools/wfctl.py list          # all 16 workflows and their derived status
python3 tools/wfctl.py next          # what can be started right now
python3 tools/wfctl.py show PW-01    # goal, requirements, scenarios, state
python3 tools/wfctl.py status        # progress bars across the whole backlog
```
