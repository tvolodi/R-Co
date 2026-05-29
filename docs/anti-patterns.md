# BPM Platform — Anti-Patterns Catalogue

**Purpose:** A living record of mistakes encountered in pipelines and their correct alternatives.  
**Updated by:** `ISSUE-FIXER` and `DOC-UPDATER` after each resolved issue.  
**Format:** Each entry has the anti-pattern, what went wrong, and the correct approach.

---

## How to use this file

Before implementing anything, search this file for the module or pattern you are about to use. If your approach matches an entry in the **Anti-Pattern** column, use the **Correct Approach** instead without attempting the anti-pattern first.

## Automated checks

Several of the anti-patterns below are now enforced by linters under `tools/`. Run them as part of self-review or in CI:

| Linter | Catches |
|---|---|
| `python3 tools/lint_design_artefact.py <file>` | Schema-qualified table names, oversized code blocks, malformed requirement IDs, real assertions in CUSTOM blocks, migration-number collisions, Lego YAML schema violations |
| `python3 tools/lint_frontend_conventions.py` | Raw `fetch`/`axios` outside `web/src/api/client.ts`, MSW / `axios-mock-adapter` references, inline query keys, `test.skip` in Playwright specs, role-gated `disabled` instead of hidden |
| `python3 tools/lint_test_isolation.py` | Hardcoded UUIDs, module-level mutable `var` in integration tests, allocations without `defer` cleanup, `error.SkipZigTest` on tests that cover a requirement, missing `BPM_TEST_DB_URL` reference |

A linter emits BLOCKER for "design or test is broken" issues, MAJOR for "fix before merge", MINOR for "cosmetic". CODE-DESIGN-VALIDATOR and TEST-DESIGN-VALIDATOR run these gates before passing handoffs downstream.

See also `templates/lego-catalog.md` for the standard-pattern templates that lower-capability models should instantiate instead of re-deriving from prose.

---

## Backend (Zig)

| Anti-Pattern | Consequence | Correct Approach |
|---|---|---|
| `catch unreachable` on realistic failure paths (DB errors, I/O) | Panics in production on normal error conditions | Use typed error sets; propagate with `!` or return the error |
| SQL string interpolation (`std.fmt.allocPrint` + query) | SQL injection vulnerability | Always use `$1`, `$2` placeholders via `pg.zig` prepared statements |
| I/O inside `src/engine/transition.zig` | Breaks pure-function contract; untestable without a database | All I/O belongs in the handler layer; transition functions receive data, not connections |
| Global error set across all modules | Error types become meaningless; callers cannot match them | Per-module error sets defined in each module's root file |
| `zig build test` to validate a single module fix | Runs the entire test suite; slow feedback loop | `zig build test-<module>` for focused validation |

---

## Database / Migrations

| Anti-Pattern | Consequence | Correct Approach |
|---|---|---|
| Schema-qualified names in migrations (`public.table_name`) | Migration fails if `search_path` differs between environments | Use unqualified table names; let `search_path` resolve |
| `DROP TABLE` or `DROP COLUMN` in a migration without a matching data-preservation migration | Irreversible data loss in production | Only append-only migrations; schema removals require an explicit archival step first |
| Checking `information_schema.tables` without `AND table_schema = 'public'` | False positives from shadow tables in other schemas | Always filter by `table_schema` |

---

## Frontend (React / TypeScript)

| Anti-Pattern | Consequence | Correct Approach |
|---|---|---|
| Calling `fetch()` or `axios` directly in a component | Bypasses auth interceptors and error normalization | Route all API calls through `src/api/client.ts` |
| Inline query keys (`useQuery(['processes', id])`) | Key collisions; cache invalidation bugs | Use the factory in `src/api/queryKeys.ts` |
| Hard-coded user-visible strings in `.tsx` files | i18n gaps surface as untranslatable text | Use `t('key')` from the i18n hook for all user-visible text |
| Disabling a UI element based on role (vs hiding it) | Element is still in the DOM; screen readers expose it | Hide elements entirely with conditional rendering; never just `disabled` |

---

## Agent Workflows

| Anti-Pattern | Consequence | Correct Approach |
|---|---|---|
| Skipping `fn:search-issues` before starting a fix | Re-diagnosing known problems from scratch; wasted cycles | Always call `fn:search-issues` first; apply proven resolution if one exists |
| Completing a handoff without `fn:register-inner-report` | Context loss; next agent has no audit trail | The completion order is always: `fn:validate-completeness → fn:register-inner-report → fn:complete-handoff` |
| Retrying the same implementation approach after 2 failures | Infinite rework loop; escalation delayed | After 2 identical failures, change the root approach before the third attempt |
| Embedding large context in handoff JSON `context` fields | Prompt truncation in downstream agents | Write context to a file in `docs/` and reference the path in the handoff |
| Treating unrelated pre-existing workspace changes as blockers | Pipeline stalls and token waste on non-blocking noise | Ignore pre-existing unrelated changes; only raise when there is direct file overlap/conflict or acceptance criteria are blocked |
| **ORCH writing `created_at` / `started_at` from the session context date or a manually chosen round number** | `completed_at` (set from the real host clock) precedes `started_at`; step durations become negative; retrospectives are corrupted | Run `(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")` (PowerShell) immediately and use the exact printed string. Never derive timestamps from "current date is …" in the session context. |
| **Completing a WF-02/WF-03/WF-04 pipeline without git wrapper steps (no branch, no commit, no push)** | Implementation exists only in the working tree; changes are never persisted to VCS; branch-based coordination with other agents/hosts is impossible; the DONE log entry is false | Always dispatch a BACKEND-DEV Step 00 (git-setup) handoff before Step 01, and a BACKEND-DEV Step Final (git-merge) handoff after Step 06/DOC-UPDATER. Block DONE log entry until Step Final returns PASS with non-empty `branch_name`, `commit_sha_list`, and `push_status: ok`. |
| **`error.SkipZigTest` on a MUST requirement test without a separately passing integration test** | Requirement stays at TEST-DESIGNED forever; never reaches TEST-DESIGN-REVIEWED; TEST-RUNNER run is invalid; RELEASE-VALIDATOR cannot approve | Write a real integration test for every MUST requirement. If infra is missing, ORCH creates an ADHOC handoff to fix it — not a reason to skip. Remove the skip only after the integration test passes. |
| **RELEASE-VALIDATOR approving a stage with deferred test coverage on MUST requirements** | Open coverage gaps are blessed into "released" status; technical debt locks in permanently | RELEASE-VALIDATOR MUST return FAIL if any MUST requirement has no passing integration test evidence in the current test report. "Will be addressed later" is not an acceptance criterion. |
| **Checking benchmark environment AFTER dispatching TEST-RUNNER (instead of before)** | TEST-RUNNER returns FAIL on a bench-env error; ORCH must create ADHOC BACKEND-DEV handoff; then redispatch TEST-RUNNER; extra round-trip costs 2–4 handoffs | ORCH runs `zig build bench 2>&1 \| head -5` before dispatching TEST-RUNNER. If bench env fails: fix first, then dispatch TEST-RUNNER. |
| **Batching more than 4 requirements into one WF-02 run** | Any WF-03 issue in the batch blocks all requirements; blast radius amplified; retrospective timing data is meaningless | Cap at 4 requirements per WF-02 run. Split larger groups into sequential runs. |
| **Deferring a pipeline step because infrastructure is unavailable** | Coverage gap created; requirement never reaches RELEASED; repeated deferrals pile up until a full WF-04 is required to clear them | ORCH creates an ADHOC BACKEND-DEV handoff to fix the infrastructure immediately. No pipeline step may be skipped because of environment problems. |
| **Shared mutable tenant or fixture state across integration test blocks** | Tests interfere with each other; results differ depending on execution order; debug time spikes | Every integration test creates its own fixtures with per-test UUIDs and cleans up via `defer` even on failure. No fixture created by one test block is read or modified by another. |

---

*Add new entries as issues are resolved. Each entry should link to the ISS-NNN that produced it once the KB is populated.*
