# backlog/ — frozen, migrated to docs/requirements.yaml (2026-08-07)

All 92 requirements previously staged in `backlog/meta-*.yaml` +
`backlog/bodies/*.md` have been migrated into `docs/requirements.yaml`
(status: `DRAFT`) via `scratch/migrate_backlog.py`. `docs/requirements.yaml`
is the canonical requirements store — see `tools/reqctl.py`'s own docstring.

This directory is now a **historical reference only**, same treatment as
`docs/BPM_Platform_Functional_Requirements.md` and the ~150 files under
`docs/requirements/` after the 2026-07-22 consolidation. Do not add new
requirements here — use `python3 tools/reqctl.py add`. Do not edit these
files expecting the change to reach the pipeline — nothing reads
`backlog/` anymore.

To see the migrated requirements: `python3 tools/reqctl.py list --status DRAFT`
(or filter further by `--stage`/`--priority`).

To see their implementation order: `python3 tools/reqctl_batch_plan.py`.

See `docs/agents/protocols/LOOP_PROTOCOL.md` "Requirement batch loop mode"
for how they get picked up and implemented automatically.
