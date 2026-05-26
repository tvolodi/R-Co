# BPM Platform — Anti-Patterns Catalogue

**Purpose:** A living record of mistakes encountered in pipelines and their correct alternatives.  
**Updated by:** `ISSUE-FIXER` and `DOC-UPDATER` after each resolved issue.  
**Format:** Each entry has the anti-pattern, what went wrong, and the correct approach.

---

## How to use this file

Before implementing anything, search this file for the module or pattern you are about to use. If your approach matches an entry in the **Anti-Pattern** column, use the **Correct Approach** instead without attempting the anti-pattern first.

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

---

*Add new entries as issues are resolved. Each entry should link to the ISS-NNN that produced it once the KB is populated.*
