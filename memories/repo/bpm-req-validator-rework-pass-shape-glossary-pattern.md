# REQ-VALIDATOR rework PASS pattern: 3-defect batch (BLOCKER + 2 MAJOR)

## Verified end-to-end (2026-08-14, WF01-prm-batch2-20260814 rework 1)
REQ-ANALYST's rework resolved all 3 substantive defects on first attempt:

1. **BLOCKER — missing edge in state machine**: added 7th edge `applied->superseded`
   to PRM-04's enumeration; CHECK vs application-layer enforcement clarified;
   rollback AC added (mirrors RELEASED PRM-08 AC4 + shipped rollback code).
2. **MAJOR — entry shape mismatch**: PRM-03's `{type, id, changes}` replaced
   with `{type, id, change_kind, before, after}` matching RELEASED PRM-01's
   emitted shape. Cross-ref annotation in body cites PRM-01 verbatim.
3. **MAJOR — undefined package**: PRM-05's `NEEDS_REVIEW package` defined
   inline with `{marker: "NEEDS_REVIEW", assertions: [HumanReviewAssertion]}`
   shape, marker literal, empty-array convention; Glossary entry added
   distinguishing it from AGT-06's lowercase `needs_review` artifact STATE.

## Process doc mirror markers that worked
Add `<!-- REWORK-WF<id>-<date>: ... -->` HTML comments immediately before
the changed table rows in `docs/processes/system/definition-promotion.md`
so the rework is greppable and reads as a restatement of the corrected req.

## See-list hygiene (TRACEABILITY MINORs)
- PRM-04 See: must include PRM-01 (the plan producer) and PRM-08 (the
  rollback consumer). Missing PRM-01 is a recurring MINOR.
- PRM-05 See: must include PRM-01 and PRM-02. PRM-02 was a transitive ref.

## Tool gates (must exit 0)
- `python tools/reqctl.py validate` — no PRM-02..05 findings.
- `python tools/lint_handoffs.py` — 0 BLOCKER / 0 MAJOR; 1 MINOR (H010
  registry absence) is pre-existing baseline.
- Custom xref check: every See: token resolves in docs/requirements.yaml
  (22/22 across PRM-02..05).

## Handoff bookkeeping discipline that avoids H009
Set `status` to `IN_PROGRESS` immediately after `started_at` is stamped
by ORCH; never touch `started_at`; complete via Python (utf-8, no BOM);
append to `handoffs/orchestrator.log` via `scratch/orch_log_route.py`
(uses mode="a" + utf-8 — PowerShell `>>` corrupts with UTF-16).
Update `handoffs/registry.json` matching entry to COMPLETED + completed_at.