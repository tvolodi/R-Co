# BPM Platform — Agent Function Library

**Version:** 0.2 · 2026-05-20  
**Audience:** All agents  
**Usage:** Agents reference functions by ID in handoff `task.functions_to_call`. Each function is a documented procedure in its own file under `docs/agents/functions/`. Agents load only the files they need.

---

## How to use this library

When a handoff lists `"functions_to_call": ["fn:check-zig-build", "fn:register-inner-report"]`, the agent:
1. Reads the corresponding file from `docs/agents/functions/`
2. Executes the described steps in order
3. Records the result in the handoff `result` field

> ⛔ **`fn:register-inner-report` is mandatory before every `fn:complete-handoff` call.**

Functions may call other functions (noted as `→ fn:name` in the individual file).

---

## Function Index

### Category: Requirements (REQ)

| Function ID | File | Used by |
|---|---|---|
| `fn:load-requirements` | [fn-load-requirements.md](functions/fn-load-requirements.md) | REQ-ANALYST, REQ-VALIDATOR, CODE-DESIGNER, TEST-DESIGNER |
| `fn:check-requirement-completeness` | [fn-check-requirement-completeness.md](functions/fn-check-requirement-completeness.md) | REQ-VALIDATOR |
| `fn:update-requirement-status` | [fn-update-requirement-status.md](functions/fn-update-requirement-status.md) | DOC-UPDATER, RELEASE-VALIDATOR |
| `fn:load-requirement-status` | [fn-load-requirement-status.md](functions/fn-load-requirement-status.md) | ORCH, RELEASE-VALIDATOR |

### Category: Issue Knowledge Base (ISS)

| Function ID | File | Used by |
|---|---|---|
| `fn:register-issue` | [fn-register-issue.md](functions/fn-register-issue.md) | ISSUE-FIXER, TEST-RUNNER, BACKEND-DEV, FRONTEND-DEV |
| `fn:search-issues` | [fn-search-issues.md](functions/fn-search-issues.md) | ISSUE-FIXER, BACKEND-DEV, FRONTEND-DEV |
| `fn:update-issue` | [fn-update-issue.md](functions/fn-update-issue.md) | ISSUE-FIXER, DOC-UPDATER |

### Category: Code (CODE)

| Function ID | File | Used by |
|---|---|---|
| `fn:read-backend-conventions` | [fn-read-backend-conventions.md](functions/fn-read-backend-conventions.md) | BACKEND-DEV, CODE-DESIGNER |
| `fn:read-frontend-conventions` | [fn-read-frontend-conventions.md](functions/fn-read-frontend-conventions.md) | FRONTEND-DEV, CODE-DESIGNER |
| `fn:check-zig-build` | [fn-check-zig-build.md](functions/fn-check-zig-build.md) | BACKEND-DEV, ISSUE-FIXER, TEST-RUNNER |
| `fn:check-frontend-build` | [fn-check-frontend-build.md](functions/fn-check-frontend-build.md) | FRONTEND-DEV, ISSUE-FIXER, TEST-RUNNER |
| `fn:check-frontend-types` | [fn-check-frontend-types.md](functions/fn-check-frontend-types.md) | FRONTEND-DEV, ISSUE-FIXER |
| `fn:check-frontend-lint` | [fn-check-frontend-lint.md](functions/fn-check-frontend-lint.md) | FRONTEND-DEV, ISSUE-FIXER |
| `fn:apply-migrations` | [fn-apply-migrations.md](functions/fn-apply-migrations.md) | BACKEND-DEV |
| `fn:check-code-coverage` | [fn-check-code-coverage.md](functions/fn-check-code-coverage.md) | TEST-RUNNER, RELEASE-VALIDATOR |
| `fn:generate-openapi` | [fn-generate-openapi.md](functions/fn-generate-openapi.md) | DOC-UPDATER |

### Category: Testing (TEST)

| Function ID | File | Used by |
|---|---|---|
| `fn:run-unit-tests` | [fn-run-unit-tests.md](functions/fn-run-unit-tests.md) | TEST-RUNNER, ISSUE-FIXER, BACKEND-DEV |
| `fn:run-frontend-unit-tests` | [fn-run-frontend-unit-tests.md](functions/fn-run-frontend-unit-tests.md) | TEST-RUNNER, ISSUE-FIXER, FRONTEND-DEV |
| `fn:run-integration-tests` | [fn-run-integration-tests.md](functions/fn-run-integration-tests.md) | TEST-RUNNER, RELEASE-VALIDATOR |
| `fn:run-e2e-tests` | [fn-run-e2e-tests.md](functions/fn-run-e2e-tests.md) | TEST-RUNNER, RELEASE-VALIDATOR |
| `fn:run-nfr-benchmarks` | [fn-run-nfr-benchmarks.md](functions/fn-run-nfr-benchmarks.md) | RELEASE-VALIDATOR |
| `fn:load-test-specs` | [fn-load-test-specs.md](functions/fn-load-test-specs.md) | TEST-DESIGNER, TEST-RUNNER |
| `fn:write-test-report` | [fn-write-test-report.md](functions/fn-write-test-report.md) | TEST-RUNNER |

### Category: Handoffs (HO)

| Function ID | File | Used by |
|---|---|---|
| `fn:create-handoff` | [fn-create-handoff.md](functions/fn-create-handoff.md) | ORCH |
| `fn:register-handoff` | [fn-register-handoff.md](functions/fn-register-handoff.md) | ORCH (via fn:create-handoff) |
| `fn:complete-handoff` | [fn-complete-handoff.md](functions/fn-complete-handoff.md) | All agents |
| `fn:load-handoff` | [fn-load-handoff.md](functions/fn-load-handoff.md) | All agents |

### Category: Documentation (DOC)

| Function ID | File | Used by |
|---|---|---|
| `fn:update-changelog` | [fn-update-changelog.md](functions/fn-update-changelog.md) | DOC-UPDATER |
| `fn:check-doc-freshness` | [fn-check-doc-freshness.md](functions/fn-check-doc-freshness.md) | RELEASE-VALIDATOR, DOC-UPDATER |

### Category: Workflow Control (CTRL)

| Function ID | File | Used by |
|---|---|---|
| `fn:validate-completeness` | [fn-validate-completeness.md](functions/fn-validate-completeness.md) | All agents — mandatory before fn:register-inner-report on impl tasks |
| `fn:register-inner-report` | [fn-register-inner-report.md](functions/fn-register-inner-report.md) | **ALL agents** — mandatory |

### Category: Git Operations (GIT)

| Function ID | File | Used by |
|---|---|---|
| `fn:git-setup` | [fn-git-setup.md](functions/fn-git-setup.md) | `BACKEND-DEV`, `FRONTEND-DEV` — Step 00 |
| `fn:git-merge` | [fn-git-merge.md](functions/fn-git-merge.md) | `BACKEND-DEV`, `FRONTEND-DEV` — Step Final |
