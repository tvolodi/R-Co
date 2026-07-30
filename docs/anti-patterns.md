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
| Guarding a migration's `DO` block with `to_regclass('some_table') IS NULL` to detect a prerequisite, when that prerequisite only exists under a per-tenant schema (not `public`) | The guard's implicit `search_path` at migration-apply time may not include the tenant schema, so `to_regclass` returns NULL even though the table exists elsewhere — the guard silently no-ops and the migration is marked applied without ever running its body (see [GitHub #335](https://github.com/tvolodi/R-Co/issues/335) / ISS-0076: `GBL-100_exp501_secrets.sql` never created the `secrets` table because its guard checked `instance_projections`, which only exists under `tenant_default`) | Query `pg_tables`/`pg_namespace` explicitly with the target schema, or set `search_path` explicitly inside the `DO` block before calling `to_regclass`; never rely on the ambient search_path for a prerequisite check in a multi-schema (per-tenant) database |

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
| **ORCH stopping the pipeline and reporting "services not running" to the user** | User is asked to manually start Docker services; Zero Manual Work violated; pipeline stalls until user intervenes | Service downtime (PostgreSQL, Keycloak) is a standard technical obstacle. ORCH immediately creates an ADHOC BACKEND-DEV handoff (`docker-compose up -d db db_test keycloak`), waits for PASS, then redispatches the blocked step — all within the same autonomous run. No user interaction. |
| **BACKEND-DEV starting services itself during an implementation or test handoff** | Side-effects bleed across runs; if services are already running a second `up` does nothing harmful, but the agent has overstepped its remit; infra state is undocumented | BACKEND-DEV returns FAIL with severity BLOCKER and a message naming the missing service. ORCH handles the INFRA_BLOCK by creating an ADHOC. The ADHOC BACKEND-DEV handoff is the only valid place to run `docker-compose up`. |
| **ORCH skipping a standard workflow (WF-01–WF-04) to solve a problem directly** | No git tracking (branch, PR, merge); no design artefact or validation gate; no test coverage; no documentation updates; no work metrics; no audit trail. Even if the fix is correct, the project loses all traceability and regression protection. | ORCH must follow the matched workflow. If ORCH believes skipping is justified, it must ask the user for explicit confirmation first via the §11 Workflow Skip Gate (`docs/agents/ORCHESTRATOR.md §11`). The user must be informed what overhead will be lost. ORCH must log the decision in `handoffs/orchestrator.log`. |
| **Any code or migration change pushing directly to `origin/main` without git-setup → implementation → git-merge workflow** | Changes appear on main without a feature branch, PR, or audit trail. If a problem is discovered later, there is no PR review history, no isolation point, and no clean way to revert. CI/CD cannot gate the merge. | Every workflow that produces code or migrations (WF-02, WF-03, WF-04, ADHOC) MUST include Step 00 (git-setup) and Step Final (git-merge). ORCH MUST REJECT any workflow that skips these steps. Branch → implement → PR → merge is mandatory. This is enforced in `CLAUDE.md` and `ORCHESTRATOR.md §8`. |
| **Placing DB-backed tests in the unit test layer (`tests/unit/`)** | Unit tests run without `BPM_TEST_DB_URL`; DB-backed tests crash (exit code 3) instead of skipping; `zig build test` reports false failures; CI fails on clean machines with no database. | Tests that require a PostgreSQL connection belong in `tests/integration/`. The unit layer (`tests/unit/`) is **pure only** — no network I/O, no database connections. If a test calls `Pool.init`, `Store.append`, or any function that acquires a DB connection, it is an integration test. Place it in `tests/integration/` and ensure it checks for `BPM_TEST_DB_URL` via `std.process.getEnvVarOwned`. Never add a `bpm` module import to unit test targets just to wire in DB helpers. |

---

*Add new entries as issues are resolved. Each entry should link to the ISS-NNN that produced it once the KB is populated.*
