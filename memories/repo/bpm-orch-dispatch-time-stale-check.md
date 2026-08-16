# BPM Orchestrator — Dispatch-time stale-check pattern

## Pattern (2026-08-16, ADHOC-prm-reqctl-status-20260816)

Before dispatching any workflow (ADHOC, WF02, etc.) that proposes to "fix" a known state
(stale status, missing file, broken import), ALWAYS run the canonical check first.

## Failure mode
DOC-UPDATER dispatched to "fix" PRM-02/03/04/05 stale DRAFT status — but
WF02-prm02-05-20260816 had ALREADY independently merged the fix via PR #795
(squash-commit 2e9d3c99 → bookkeeping ae9854f4). The DOC-UPDATER step ran to completion,
detected the duplicate work, and correctly returned BLOCKED.

## Cost
- Full ADHOC workflow run (step-00 git-setup + step-01 doc-updater)
- Two extra commits (housekeeping bookkeeping a6910f4b + 8cd7c423)
- ISS-0709 / GH #797 filed as a follow-up defect
- ~15 minutes of pipeline time

## Fix
Before dispatching ANY workflow step that depends on a precondition the orchestrator can
verify (`reqctl.py show`, `gh pr list`, file existence, etc.), call the verifier FIRST and
short-circuit if the precondition is already met.

Examples:
- Dispatching DOC-UPDATER to set status? → `python tools/reqctl.py show <ID>` first.
- Dispatching BACKEND-DEV to create a migration? → `ls migrations/` first.
- Dispatching any agent for "fix X"? → `git log --oneline | grep -i <fix>` first.

## Outcome
ADHOC housekeeping branch was pushed to origin (audit trail preserved), then deleted both
locally and remotely. Single bookkeeping commit landed on main via the housekeeping
exception (orchestrator.log only).