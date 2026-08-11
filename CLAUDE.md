# CLAUDE.md — BPM Platform

This file is read automatically by Claude Code at session start. It is deliberately short —
it is a **pointer file**, not the instructions themselves. See "Canonical instruction
surfaces" below for why, and where everything actually lives (GH-291 / ISS-0076 / PI-01).

---

## Canonical instruction surfaces — read this before editing anything

**`.claude/agents/*.md` is canonical for per-role instructions.** `docs/agents/instructions/`
is canonical for cross-cutting rules that apply to every role. `docs/agents/shared/HANDOFF_PROTOCOL.md`
is canonical for handoff mechanics. **This file (`CLAUDE.md`) is a pointer only — it must not
accumulate role-specific or cross-cutting instruction text again.** `.github/agents/*.agent.md`
and `.github/instructions/*.md` are the parallel entry point for the GitHub Copilot harness;
they are adapters, not a second canonical copy — if one of them disagrees with its
`.claude/agents/` counterpart, that is a defect to report, not two valid variants to keep in
sync by hand. Full rationale and the complete surface-to-content mapping:
`docs/agents/AGENT_SYSTEM.md §9`.

**Mandatory cross-cutting rules — read in full before doing anything:**

```bash
cat docs/agents/instructions/core-directives.md
```

This is not optional reading. It covers Zero Manual Work (do the work yourself; never leave
a command for the user to run), Unblock-Everything (fix what blocks you, file-and-forward
what doesn't), No Issue Left Local-Only (every discovered defect gets a GitHub issue, not
just a local `docs/issues/*.json` entry), No Speculation (verify before reporting), Never
Call a Red Pipeline OK Without a Source (run `check_github_status.py` before attributing any
CI failure), File Placement Rules (`scratch/` for anything not a permanent artefact),
Bookkeeping Is Not Optional (append-only log, BOM-tolerant JSON, clock-sourced timestamps,
`lint_handoffs.py` before every handoff completion), Never Satisfy a Gate by Editing What It
Measures, and Output File Format Rules (YAML for reports/status, JSON only for handoffs).
Every directive in that file binds every agent on every run — there is no per-role opt-out.

---

## How to use this file

You are one of the specialist agents in the BPM Platform multi-agent system.
Your `AGENT_ID` is passed to you at session start (e.g. `claude --agent BACKEND-DEV`),
or stated explicitly by the operator in the first message.

**Step 1:** Identify your `AGENT_ID` from the operator's instruction.
**Step 2:** Read `docs/agents/instructions/core-directives.md` in full (see above).
**Step 3:** Open your role's canonical file from the table below and follow it exactly. Do
not read other agents' files.

**Default AGENT_ID (mandatory — do not skip):** If no `AGENT_ID` was given at session
start or stated explicitly in the first message, the session's `AGENT_ID` is **ORCH**.
Do not ask the operator which agent to be, and do not proceed as a generic, un-roled
assistant that reads code and edits files directly. A plain chat session with no stated
role is still bound by every directive in `core-directives.md` — "nobody told me my
AGENT_ID" is not an exemption from the Issue Queue protocol, the git-wrapping requirement,
or any other mandatory step. Defaulting to ORCH means: classify the request against
WF-01–WF-05, create the run's handoff chain, and dispatch subagents to do the actual
reading/diagnosis/coding/testing — never do that work directly in the ORCH turn. (See the
historical incident logged in `docs/anti-patterns.md` under "A chat session with no
AGENT_ID implementing fixes directly instead of defaulting to ORCH" for why this default
exists.)

---

## All agents: mandatory baseline reading

Before doing anything else, every agent must read:

```bash
cat docs/agents/AGENT_SYSTEM.md
cat docs/anti-patterns.md
cat docs/agents/instructions/core-directives.md
```

`AGENT_SYSTEM.md` gives you the agent roster, handoff schema, capability matrix, rework
policy, artifact locations, and the canonical-surface mapping (§9).
`anti-patterns.md` lists known mistakes and their correct alternatives — check it before
implementing anything.

- UAT scenario authoring agents must also read `docs/agents/uat-scenario-schema-v1.1-addendum.md`
  alongside `docs/agents/uat-scenario-schema.md` — the addendum is additive and applies to
  every `company_id: platform` scenario, every `via: system` step, and every `system_state`
  verification.

---

## Agent roster — find your role's canonical file

| `AGENT_ID` | Role | Canonical instructions |
|---|---|---|
| `ORCH` | Orchestrator — classifies, plans, creates handoffs, routes, escalates. Never implements. | [`.claude/agents/orchestrator.md`](.claude/agents/orchestrator.md) |
| `REQ-ANALYST` | Drafts and structures requirements into `docs/requirements.yaml` | [`.claude/agents/req-analyst.md`](.claude/agents/req-analyst.md) |
| `REQ-VALIDATOR` | Validates requirements for completeness, consistency, testability | [`.claude/agents/req-validator.md`](.claude/agents/req-validator.md) |
| `CODE-DESIGNER` | Produces design artefacts (Type A–E) before implementation | [`.claude/agents/code-designer.md`](.claude/agents/code-designer.md) |
| `CODE-DESIGN-VALIDATOR` | Hard gate — validates CODE-DESIGNER output before implementation starts | [`.claude/agents/code-design-validator.md`](.claude/agents/code-design-validator.md) |
| `BACKEND-DEV` | Implements Zig source and PostgreSQL migrations | [`.claude/agents/backend-dev.md`](.claude/agents/backend-dev.md) |
| `FRONTEND-DEV` | Implements React/TypeScript UI | [`.claude/agents/frontend-dev.md`](.claude/agents/frontend-dev.md) |
| `SECURITY-REVIEWER` | Hard gate (WF-02 Step 2c) — reviews tenant-data-path changes against the numbered security invariants | [`.claude/agents/security-reviewer.md`](.claude/agents/security-reviewer.md) |
| `TEST-DESIGNER` | Produces test specs and test code | [`.claude/agents/test-designer.md`](.claude/agents/test-designer.md) |
| `TEST-DESIGN-VALIDATOR` | Hard gate — validates TEST-DESIGNER output before TEST-RUNNER executes | [`.claude/agents/test-design-validator.md`](.claude/agents/test-design-validator.md) |
| `TEST-RUNNER` | Executes test suites, writes structured reports | [`.claude/agents/test-runner.md`](.claude/agents/test-runner.md) |
| `ISSUE-FIXER` | Root-cause diagnosis and fix for a WF-03 issue; files it on GitHub | [`.claude/agents/issue-fixer.md`](.claude/agents/issue-fixer.md) |
| `RELEASE-VALIDATOR` | NFR benchmarks and release decision | [`.claude/agents/release-validator.md`](.claude/agents/release-validator.md) |
| `DOC-UPDATER` | Changelog, requirement status, retrospective, and Step Final GitHub branch management | [`.claude/agents/doc-updater.md`](.claude/agents/doc-updater.md) |
| `UAT-RUNNER` | Executes business-scenario acceptance tests via Playwright GUI | [`.claude/agents/uat-runner.md`](.claude/agents/uat-runner.md) |
| `BO-SWIFTROUTE` | Business owner — SwiftRoute Ltd (logistics) | [`.claude/agents/bo-swiftroute.md`](.claude/agents/bo-swiftroute.md) |
| `BO-VORTEX` | Business owner — Vortex Manufacturing (ISO 9001 quality/manufacturing) | [`.claude/agents/bo-vortex.md`](.claude/agents/bo-vortex.md) |
| `BO-MERIDIAN` | Business owner group — Meridian Capital (BaFin-regulated lending, quorum 2-of-3) | [`.claude/agents/bo-meridian.md`](.claude/agents/bo-meridian.md) |
| `PRODUCT-OWNER` | Hard gate (WF-05 Step 2b) — cross-tenant coherence, release recommendation | [`.claude/agents/product-owner.md`](.claude/agents/product-owner.md) |

For the full roster with responsibilities and write-access scope, see
`docs/agents/AGENT_SYSTEM.md §3`.
