# BPM Platform — Agent System Overview

**Version:** 0.1 · 2026-05-20  
**Audience:** All agents operating within this project

---

## 1. Purpose

This document is the root reference for the multi-agent system that develops and maintains the BPM Platform. Every agent spawned for this project MUST read this document before beginning any task.

---

## 2. Core Principle

> **The system is the documentation.** Source code, tests, and all documentation are authoritative artefacts. Agents never hold state in memory between sessions — all state lives in files.

---

## 3. Agent Roster

| Agent ID | Name | Responsibility | May write to |
|---|---|---|---|
| `ORCH` | **Orchestrator** | Spawns agents, routes handoffs, builds ad-hoc workflows. **Does no implementation work.** **Must never skip a standard workflow (WF-01–WF-04) without user confirmation — see `docs/agents/ORCHESTRATOR.md §11`.** | `handoffs/`, `docs/agents/` |
| `REQ-ANALYST` | **Requirement Analyst** | Drafts, refines, and structures requirements | `docs/`, `handoffs/` |
| `REQ-VALIDATOR` | **Requirement Validator** | Validates requirements for completeness, consistency, testability, and traceability | `handoffs/` |
| `CODE-DESIGNER` | **Code Designer** | Produces module interfaces, type definitions, data-flow diagrams, and implementation plans before any code is written | `src/design/`, `handoffs/` |
| `CODE-DESIGN-VALIDATOR` | **Code Design Validator** | Reviews design artefact produced by CODE-DESIGNER; ensures all requirement acceptance criteria are covered, design is implementation-code-free, and is complete enough for BACKEND-DEV/FRONTEND-DEV to proceed without ambiguity. **Hard gate — implementation must not start until this returns PASS.** | `handoffs/` |
| `BACKEND-DEV` | **Backend Developer** | Implements Zig source code per design artefacts | `src/`, `migrations/`, `handoffs/` |
| `FRONTEND-DEV` | **Frontend Developer** | Implements React/TypeScript source code per design artefacts | `web/`, `handoffs/` |
| `SECURITY-REVIEWER` | **Security Reviewer** | Reviews implementation produced by BACKEND-DEV/FRONTEND-DEV against the numbered invariants in `docs/agents/instructions/security-invariants.md` (tenant data isolation, field authorisation, sandbox capability gating, secrets by reference, probe indistinguishability, new-path scoping proof, SQL parameterisation, no `catch unreachable` on realistic failures). Gates any change touching a tenant-data path. **Hard gate — TEST-DESIGNER must not start until this returns PASS for in-scope changes.** | `handoffs/` |
| `TEST-DESIGNER` | **Test Designer** | Produces test plans, test case specifications, and test data factories | `tests/specs/`, `handoffs/` |
| `TEST-DESIGN-VALIDATOR` | **Test Design Validator** | Reviews test design produced by TEST-DESIGNER; verifies every MUST requirement has a runnable integration test, no SkipZigTest on MUST tests without a counterpart, fixtures are isolated, and tests are self-sufficient. **Hard gate — TEST-RUNNER must not start until this returns PASS.** | `handoffs/` |
| `TEST-RUNNER` | **Test Runner** | Executes test suites, collects results, produces a structured test report | `tests/reports/`, `handoffs/` |
| `ISSUE-FIXER` | **Issue Fixer** | Registry lookup (Step 0.5), root-cause diagnosis (Step 1). Does NOT implement fixes — implementation is delegated to BACKEND-DEV or FRONTEND-DEV after CODE-DESIGNER produces the fix design. | `docs/issues/`, `handoffs/` |
| `RELEASE-VALIDATOR` | **Release Validator** | Validates that a stage increment meets all MUST requirements and all NFRs before release | `handoffs/`, `docs/status/` |
| `DOC-UPDATER` | **Documentation Updater** | Updates all documentation (guides, requirement status, changelog, OpenAPI spec) after a successful release | `docs/`, `handoffs/` |
| `UAT-RUNNER` | **UAT Runner** | Executes business-language scenario scripts against the running system via Playwright GUI; evaluates outcomes against business expectations; produces a UAT report in business terms. | `tests/simulation/scenarios/`, `tests/uat-reports/`, `handoffs/` |
| `BO-SWIFTROUTE` | **Business Owner — SwiftRoute** | Represents SwiftRoute Ltd's business interests. Personas: Alice Bauer (CEO) + Marco Stein (Ops Manager). Authors and evaluates UAT scenarios for logistics processes. | `tests/simulation/scenarios/`, `tests/uat-reports/`, `handoffs/` |
| `BO-VORTEX` | **Business Owner — Vortex** | Represents Vortex Manufacturing's business interests. Personas: Dirk Haas (CEO) + Karl Fischer (QM). Authors and evaluates UAT scenarios for manufacturing/quality processes. ISO 9001 compliance authority. | `tests/simulation/scenarios/`, `tests/uat-reports/`, `handoffs/` |
| `BO-MERIDIAN` | **Business Owner — Meridian** | Represents Meridian Capital's business interests. **Group agent** — personas: Eva Kremer (CEO) + Thomas Reiter (CRO) + Julia Hartmann (Credit Director). Quorum 2-of-3 required for sign-off. BaFin regulatory authority. | `tests/simulation/scenarios/`, `tests/uat-reports/`, `handoffs/` |
| `PRODUCT-OWNER` | **Product Owner** | Platform-level business authority. Arbitrates cross-tenant conflicts, checks MUST requirement coverage across all companies, gives final release recommendation. Sits above all BO agents. | `tests/uat-reports/`, `handoffs/` |

### 3.1 Agent Capability Matrix

| Agent | Read files | Write files | Run terminal commands | Spawn sub-agents | Call external APIs |
|---|:---:|:---:|:---:|:---:|:---:|
| `ORCH` | ✓ | ✓ (handoffs only) | ✗ | ✓ | ✗ |
| `REQ-ANALYST` | ✓ | ✓ | ✗ | ✗ | ✗ |
| `REQ-VALIDATOR` | ✓ | ✓ (handoffs) | ✗ | ✗ | ✗ |
| `CODE-DESIGNER` | ✓ | ✓ | ✗ | ✗ | ✗ |
| `CODE-DESIGN-VALIDATOR` | ✓ | ✓ (handoffs) | ✗ | ✗ | ✗ |
| `BACKEND-DEV` | ✓ | ✓ | ✓ (build, migrate, git, gh) | ✗ | ✗ |
| `FRONTEND-DEV` | ✓ | ✓ | ✓ (build, lint, git, gh) | ✗ | ✗ |
| `SECURITY-REVIEWER` | ✓ | ✓ (handoffs) | ✓ (lints, `zig build test-*`, `git diff`) | ✗ | ✗ |
| `TEST-DESIGNER` | ✓ | ✓ | ✗ | ✗ | ✗ |
| `TEST-DESIGN-VALIDATOR` | ✓ | ✓ (handoffs) | ✗ | ✗ | ✗ |
| `TEST-RUNNER` | ✓ | ✓ (reports) | ✓ (tests only) | ✗ | ✗ |
| `ISSUE-FIXER` | ✓ | ✓ (docs/issues only) | ✗ | ✗ | ✗ |
| `RELEASE-VALIDATOR` | ✓ | ✓ (status) | ✓ (tests, benchmarks) | ✗ | ✗ |
| `DOC-UPDATER` | ✓ | ✓ | ✗ | ✗ | ✗ |
| `UAT-RUNNER` | ✓ | ✓ (uat-reports, scenarios) | ✓ (Playwright only) | ✗ | ✓ (BPM API + Keycloak) |
| `BO-SWIFTROUTE` | ✓ | ✓ (scenarios, uat-reports) | ✗ | ✗ | ✗ |
| `BO-VORTEX` | ✓ | ✓ (scenarios, uat-reports) | ✗ | ✗ | ✗ |
| `BO-MERIDIAN` | ✓ | ✓ (scenarios, uat-reports) | ✗ | ✗ | ✗ |
| `PRODUCT-OWNER` | ✓ | ✓ (uat-reports) | ✗ | ✗ | ✗ |

---

## 4. Handoff System

Agents communicate exclusively through **handoff files**. No agent passes instructions directly to another agent. The Orchestrator routes handoffs.

### 4.1 Handoff file location

All handoff files live in `handoffs/<RUN-ID>/`. Each workflow run gets its own subdirectory. `handoffs/registry.json` is the **active registry** — it contains only current and recent entries. Older COMPLETED entries are periodically archived to `handoffs/history/registry-archive-<date>.json` to keep the active file manageable. Similarly, `handoffs/orchestrator.log` retains only recent lines; older lines are in `handoffs/history/orchestrator-archive-<date>.log`.

**Benefits of per-run directories:**
- All artefacts for a single pipeline run are co-located
- Resumable: a run interrupted mid-step restarts from the last written file
- No cross-run filename collisions

ORCH owns both registry layers. Specialist agents read the run-local handoff file assigned to them and never treat the active registry as the only source of truth.

### 4.2 Handoff file naming convention

```
handoffs/<RUN-ID>/step-<NN>-<agent-slug>.json
```

- `<RUN-ID>` = workflow run identifier, e.g. `WF02-stage3`, `WF03-EE05-fix`, `ADHOC-20260520`
- `<NN>` = two-digit step number (01, 02, ...) or descriptive suffix (03a, final)
- `<agent-slug>` = receiving agent name in kebab-case

Examples:
```
handoffs/WF02-stage3/step-01-code-designer.json
handoffs/WF02-stage3/step-02a-backend-dev.json
handoffs/WF02-stage3/step-02b-frontend-dev.json
handoffs/WF03-EE05-fix/step-01-issue-fixer.json
handoffs/WF03-EE05-fix/step-02-test-runner.json
```

### 4.3 Handoff file schema

```json
{
  "handoff_id": "<uuid-v4>",
  "run_id": "<run-id>",
  "workflow_id": "<WF-01|WF-02|WF-03|WF-04|WF-05|ADHOC-nnn or null>",
  "step": "01",
  "from_agent": "<AGENT_ID>",
  "to_agent": "<AGENT_ID>",
  "file": "handoffs/<run_id>/step-01-agent.json",
  "created_at": "<ISO8601-UTC>",
  "started_at": "<ISO8601-UTC or null>",
  "completed_at": "<ISO8601-UTC or null>",
  "status": "<PENDING|IN_PROGRESS|COMPLETED|FAILED|ESCALATED|CANCELLED>",
  "priority": "<HIGH|NORMAL|LOW>",
  "context": {
    "stage": "<Stage 1..6 or null>",
    "requirement_ids": ["<REQ-ID>", "..."],
    "related_handoff_ids": ["<uuid>", "..."],
    "artifacts_in": ["<relative/path/to/file>", "..."]
  },
  "task": {
    "description": "<clear, actionable task description for the receiving agent>",
    "acceptance_criteria": ["<measurable criterion>", "..."],
    "functions_to_call": ["<fn:name>", "..."]
  },
  "result": {
    "status": "<PASS|FAIL|PARTIAL>",
    "summary": "<one paragraph>",
    "artifacts_out": ["<relative/path/to/file>", "..."],
    "issues": [
      {
        "id": "<ISSUE-nnn>",
        "severity": "<BLOCKER|MAJOR|MINOR>",
        "description": "<description>",
        "affected_requirement": "<REQ-ID or null>"
      }
    ],
    "git_evidence": {
      "branch_name": "<feature/<run_id> or null if not a git step>",
      "commit_sha_list": ["<sha>"],
      "remote_branch": "<origin/branch or null>",
      "push_status": "<ok|failed|skipped>",
      "pr_url": "<url or null>",
      "pr_create_error": "<error string or null>"
    },
    "next_action": "<suggested next step for Orchestrator>"
  },
  "rework_count": 0,
  "max_rework": 3
}
```

**`started_at` convention:** The **Orchestrator** MUST stamp `started_at` with the actual current UTC time immediately before invoking the subagent. Agents MUST NOT set `started_at` — LLM agents cannot reliably report wall-clock time and will fabricate values. Agents set only `completed_at`. This guarantees accurate metrics: queue time = `started_at − created_at`, work time = `completed_at − started_at`.

**Timestamp rule — applies to ALL agents and ORCH:** Never write a timestamp value from memory or inference. Always obtain the real system time by running a shell command and using its exact output:

**On Windows (preferred):**
```powershell
(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
```

**On Linux/macOS:**
```bash
python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
```

**On Windows with Python (fallback):**
```cmd
python -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
```

This applies to `created_at`, `started_at`, and `completed_at` in every handoff file. Invented timestamps break retrospective metrics and must be treated as a data corruption defect.

```
```

### 4.4 Rework policy

- Every handoff carries `rework_count` (starts at 0) and `max_rework` (default 3).
- When a validation step FAILS, the Orchestrator increments `rework_count` and re-routes to the originating agent with the failure details appended.
- When `rework_count` reaches `max_rework`, the handoff status is set to `ESCALATED` and the Orchestrator surfaces the issue for human review before proceeding. The Orchestrator MUST NOT silently continue past max rework.
- **Change-approach rule:** If the same failure recurs after rework (same error, same root cause), the agent receiving rework MUST change its approach — not repeat the same implementation strategy. Repeating an identical approach that has already failed twice is a workflow violation. On the third attempt, switch strategy before writing any code.

### 4.5 Handoff registry

Every created handoff MUST be recorded in the active registry and, once terminal, archived in the per-run registry:

```json
{
  "schema_version": 1,
  "created_at": "<ISO8601-UTC>",
  "last_updated": "<ISO8601-UTC>",
  "entries": [
    {
      "handoff_id": "<uuid>",
      "run_id": "<run-id>",
      "workflow_id": "<workflow-id or null>",
      "step": "01",
      "file": "handoffs/<filename>.json",
      "from_agent": "<id>",
      "to_agent": "<id>",
      "created_at": "<ISO8601>",
      "started_at": "<ISO8601 or null>",
      "completed_at": "<ISO8601 or null>",
      "status": "<status>",
      "stage": "<Stage N or null>"
    }
  ]
}
```

`handoffs/registry.json` is the active registry for open work. ORCH updates entries in place while the handoff is open and removes terminal entries from the active registry after archiving the final snapshot to `handoffs/<run_id>/registry.json`.

> Handoff directories are not committed to git by default. They can be cleaned up after the run's inner report is written and the release is confirmed. Add `handoffs/*/` to `.gitignore` if desired, but keep `handoffs/registry.json` versioned as the active index and retain per-run registries for history.

### 4.6 Registry recovery and compatibility

- If `handoffs/registry.json` is missing or stale, ORCH rebuilds the active registry from the run-local handoff files whose status is not terminal.
- If `handoffs/<run_id>/registry.json` is missing for a completed run, ORCH reconstructs it from the run-local handoff files and `handoffs/orchestrator.log`.
- During migration, compatibility readers should prefer the active registry for live routing and fall back to the run-local handoff file plus per-run registry for history.
- If the registry and handoff file disagree, the handoff file is the task-level source of truth and the mismatch is flagged for recovery.

---

## 5. Requirement Status Tracking

All requirement IDs from the functional requirements spec carry a status tracked in `docs/status/requirement_status.json`:

```json
{
  "version": 1,
  "requirements": {
    "ES-01": {
      "status": "DRAFT",
      "implemented_in": null,
      "test_ids": [],
      "released_in": null,
      "last_updated": "<ISO8601>"
    }
  }
}
```

**Status lifecycle:**

```
DRAFT → VALIDATED → DESIGNED → DESIGN-REVIEWED → IMPLEMENTED → TEST-DESIGNED → TEST-DESIGN-REVIEWED → TESTED → RELEASED
                   ↑                               ↑                                    ↑
             (rework loop)                   (rework loop)                       (rework loop)
```

| Status | Set by agent | Meaning |
|---|---|---|
| `DRAFT` | `REQ-ANALYST` | Requirement written, not yet validated |
| `VALIDATED` | `REQ-VALIDATOR` | Requirement complete, consistent, testable |
| `DESIGNED` | `CODE-DESIGNER` | Code design artefact exists |
| `DESIGN-REVIEWED` | `CODE-DESIGN-VALIDATOR` | Design artefact verified — all acceptance criteria covered; BACKEND-DEV may now start |
| `IMPLEMENTED` | `BACKEND-DEV` / `FRONTEND-DEV` | Code merged, compiles |
| `TEST-DESIGNED` | `TEST-DESIGNER` | Test spec and source files exist |
| `TEST-DESIGN-REVIEWED` | `TEST-DESIGN-VALIDATOR` | Test design verified — every MUST req has integration test, no deferred coverage; TEST-RUNNER may now start |
| `TESTED` | `TEST-RUNNER` | All test cases for this requirement pass |
| `RELEASED` | `RELEASE-VALIDATOR` | Included in a released stage increment |

---

## 6. Artifact Locations

| Type | Location | Owner agent(s) | Format |
|---|---|---|---|
| Zig source | `src/` | `BACKEND-DEV` | `.zig` |
| SQL migrations | `migrations/` | `BACKEND-DEV` | `.sql` |
| Frontend source | `web/src/` | `FRONTEND-DEV` | `.ts`/`.tsx` |
| Code design artefacts | `src/design/` | `CODE-DESIGNER` | `.md` |
| Test specs | `tests/specs/` | `TEST-DESIGNER` | `.md` |
| Test reports | `tests/reports/` | `TEST-RUNNER` | **`.yaml`** |
| UAT scenarios | `tests/simulation/scenarios/` | `BO-*` agents write; `UAT-RUNNER` reads | `.yaml` |
| UAT reports (execution) | `tests/uat-reports/uat-*.yaml` | `UAT-RUNNER` | **`.yaml`** |
| BO sign-off reports | `tests/uat-reports/bo-signoff-<company>-*.yaml` | `BO-SWIFTROUTE`, `BO-VORTEX`, `BO-MERIDIAN` | **`.yaml`** |
| PO sign-off report | `tests/uat-reports/po-signoff-*.yaml` | `PRODUCT-OWNER` | **`.yaml`** |
| Agent specs (BO family) | `docs/agents/BO_*.md`, `docs/agents/PRODUCT_OWNER.md` | Read by agents | `.md` |
| Handoff files | `handoffs/` | All (via `ORCH`) | `.json` (exception) |
| Requirement status | `docs/status/requirement_status.yaml` | `DOC-UPDATER`, `RELEASE-VALIDATOR` | **`.yaml`** |
| Release decisions | `docs/status/` | `RELEASE-VALIDATOR` | **`.yaml`** |
| Agent workflows | `docs/agents/workflows/` | `ORCH` reads only | `.md` |
| Git protocols | `docs/agents/protocols/` | `BACKEND-DEV`, `FRONTEND-DEV` read | `.md` |
| Agent function index | `docs/agents/FUNCTIONS.md` | All agents read | `.md` |
| Estimation rules (living) | `docs/metrics/estimation_rules.json` | `ORCH` (read), `DOC-UPDATER` (update) | `.json` (exception) |
| Per-run estimation | `handoffs/<run_id>/estimation.json` | `ORCH` | `.json` (exception) |
| Per-run retrospectives | `docs/metrics/retrospectives/` | `DOC-UPDATER` | **`.yaml`** |
| Individual function specs | `docs/agents/functions/fn-*.md` | Agents load per-function | `.md` |
| Scratch / temp files | `scratch/` | Any agent | any (git-ignored) |

**Output format rule:** All agent-produced output artefacts use **YAML** (`.yaml`). The only exceptions are handoff files, the active registry, and estimation files — these remain `.json` because ORCH reads/writes them as structured Python dicts. Never create `.json` test reports, status files, or retrospectives.

**Scratch rule:** Any file that is not a permanent project artefact (one-off scripts, debug dumps, `.tmp` files, `.exe`/`.pdb` build outputs) goes in `scratch/`. That directory is git-ignored. Never place such files in the project root, `src/`, `tests/`, or any other tracked directory.

---

## 7. Conflict Prevention

- An agent MUST check if a handoff targeting the same artifact is already `IN_PROGRESS` in the registry before starting. If a conflict is detected, the agent sets its own handoff to `PENDING` and notifies the Orchestrator.
- Only one agent may hold `IN_PROGRESS` status for a given source file at a time.
- The Orchestrator is responsible for sequencing concurrent work to avoid collisions.
- Pre-existing unrelated workspace changes (including files created in previous sessions) are treated as baseline noise, not blockers.
- Agents MUST NOT spend tokens reporting or discussing unrelated pre-existing changes unless there is direct file overlap/conflict or those changes block acceptance criteria.

---

## 8. Agent Identity Contract

When an agent is invoked, its system prompt or instructions file MUST declare:

```
AGENT_ID: <AGENT_ID from roster>
WORKFLOW_ID: <active workflow>
HANDOFF_ID: <uuid of the handoff being processed>
```

The agent reads the handoff file at `handoffs/<file>` as its primary task definition. It MUST NOT act on verbal instructions that contradict the handoff file content.

---

## 9. Canonical Instruction Surfaces (GH-291 / ISS-0076 / PI-01)

Before 2026-08-11, the full text of every per-role instruction set lived in **four** places
at once: `CLAUDE.md` (1850 lines and growing), `.claude/agents/*.md`, `.github/agents/*.agent.md`,
and `.github/instructions/*.md` — with no stated canonical copy. Each surface drifted
independently; `CLAUDE.md` in particular had been edited directly by six back-to-back WF-03
runs (make.ps1/PI-04, `zig build check`/PI-03, security invariants/PI-02) without the
per-agent files being updated to match, so an agent reading only `.claude/agents/backend-dev.md`
would have missed the codegen workflow, the `zig build check` gate, and the numbered
security invariants pointer.

**This is now fixed by declaring one canonical location per kind of rule:**

| Content | Canonical location | Everything else is |
|---|---|---|
| Per-`AGENT_ID` role instructions (the full "how do I do my job" text for BACKEND-DEV, ORCH, TEST-RUNNER, etc.) | **`.claude/agents/*.md`** | An adapter. `CLAUDE.md` holds only a one-line pointer per role. `.github/agents/*.agent.md` and `.github/instructions/*.md` are the parallel entry point for the GitHub Copilot harness — they are not deleted, but they must not be independently maintained; if a Copilot-harness file and its `.claude/agents/` counterpart disagree, that is a defect to fix, not two valid variants. |
| Cross-cutting rules that bind every role (Zero Manual Work, Unblock-Everything, No Speculation, file placement, bookkeeping, gate integrity, output formats) | **`docs/agents/instructions/core-directives.md`** (`applyTo: **`) | `CLAUDE.md` points here instead of restating the rules. |
| Security invariants (tenant isolation, sandbox capability gating, secrets handling, etc.) | **`docs/agents/instructions/security-invariants.md`** (PI-02, unchanged by PI-01) | Per-agent files (`backend-dev.md`, `frontend-dev.md`, `issue-fixer.md`, `security-reviewer.md`) point here rather than restating the invariants. |
| Handoff lifecycle mechanics (claiming, encoding, timestamps, legal `result.status`, the `lint_handoffs.py` gate) | **`docs/agents/shared/HANDOFF_PROTOCOL.md`** (pre-existing) | Every per-agent file opens with a pointer to this file. |
| Agent roster, capability matrix, handoff schema, artifact locations (this document) | **`docs/agents/AGENT_SYSTEM.md`** | — |

**Rule for every future change:** find the ONE canonical file for the kind of rule being
added or changed, edit it there, and — if the change is per-role — do not also edit
`CLAUDE.md`'s pointer table unless the role's existence or one-line description changed. A
change that touches only `CLAUDE.md`, or only a `.github/` adapter, without touching the
matching canonical file, is very likely wrong.

**`.github/agents/*.agent.md` and `.github/instructions/*.md` status as of PI-01:** left
untouched. They already independently reference `docs/agents/shared/HANDOFF_PROTOCOL.md`
(verified via `python tools/lint_agent_docs.py`, which checks all three surfaces) and are not
uniformly stale — some individual files there are in some respects richer than the
`.claude/agents/` files were before this reconciliation (e.g. `bo-swiftroute.agent.md` had
scenario-authoring detail `CLAUDE.md` lacked). But they are a **separately drifted set**, not
verified section-by-section against `.claude/agents/` in this pass — that full Copilot-harness
reconciliation is out of scope for PI-01 (Effort: M) and is a candidate for its own follow-up
issue if genuine content gaps are found there.
