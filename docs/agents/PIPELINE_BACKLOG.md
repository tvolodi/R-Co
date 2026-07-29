# Pipeline Backlog — PI-01 to PI-09

**Created:** 2026-07-29
**Source:** `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §4
**Also recorded in:** `docs/workflows.yaml` → `excluded.development_process`
**Owner:** ORCH

---

## What these are, and why they are not requirements

Nine changes to the **development pipeline**, not to the product. Nothing here
appears in a tenant's browser or in the platform's behaviour. They do not
belong in `docs/requirements.yaml`, they get no `PW-nn`, and they are never
signed off by UAT — there is no business owner to show them to.

They are dispatched as **ADHOC handoffs**, one per item.

The reason to care about them now: the platform-workflow backlog is 92
requirements, which is roughly 30 WF-02 runs. Anything that wastes context,
fails a build, or blocks a test run does so **thirty times**. Four of these
nine pay for themselves over that; the other five do not, and should wait.

---

## Do these four before starting the 92

### PI-01 — Split `CLAUDE.md` into glob-scoped instruction files

**Problem.** `CLAUDE.md` is 1,438 lines. Every agent loads all of it — BACKEND-DEV
reads the BO personas, UAT-RUNNER reads the ORCH estimation code. The same role
text also exists in `.claude/agents/` (13 files), `.github/agents/` (18 files),
`.github/instructions/` (3 files) and `docs/agents/`. Four copies, no stated
canonical. This was recommended on 2026-06-26 and not adopted.

**Do.** Pick one canonical directory (ASCOA uses `.copilot/`; `docs/agents/` is
the natural choice here since it already holds `AGENT_SYSTEM.md`, `FUNCTIONS.md`
and the workflows). Everything else becomes a thin pointer. Move the enforceable
rules into small files scoped by glob:

```
docs/agents/instructions/zig-conventions.md        applyTo: src/**/*.zig
docs/agents/instructions/react-conventions.md      applyTo: web/src/**/*.{ts,tsx}
docs/agents/instructions/migration-rules.md        applyTo: migrations/**
docs/agents/instructions/testing-rules.md          applyTo: tests/**
docs/agents/instructions/requirement-format.md     applyTo: docs/requirements.yaml
docs/agents/instructions/security-invariants.md    applyTo: **   (see PI-02)
```

**Done when:** `CLAUDE.md` is under 200 lines and contains only pointers; every
rule lives in exactly one file; a written statement names the canonical
directory and says the other surfaces are adapters that must not be edited
directly.

**Effort:** M. **Blocks:** PI-02.

---

### PI-02 — Numbered security invariants, and a security-reviewer agent

**Problem.** There are four "Security rules (hard constraints)" and they sit
*inside the BACKEND-DEV section* of `CLAUDE.md` — so FRONTEND-DEV and
ISSUE-FIXER never read them. No verification steps, no severities, and **no
security agent in the 13-agent roster**. This is a multi-tenant platform
running two untrusted runtimes.

**Why now.** The 92 requirements include the tenant-isolation-critical ones:
`FIL-06` (cross-tenant attachment probes), `QRY-04` (unauthorised entity types),
`SBX-05` (sandbox probe sentinel), `CAC-UI-01` (client cache leaks),
`DDL-05` (namespace reservation). Without a security gate those ship reviewed by
nobody.

**Do.** Write `docs/agents/instructions/security-invariants.md` as numbered
invariants, each with Rule / Reference / **How to verify** / Severity. Then add
a `security-reviewer` agent to the roster and insert it into WF-02 after
implementation and before TEST-DESIGNER, gating any change that touches a
tenant-data path.

Start from these, drawn from rules already stated across your own docs:

| | Invariant |
|---|---|
| INV-1 | Every query on a shared table carries a `tenant_id` predicate. No exception for internal or admin paths. BLOCKER. |
| INV-2 | Field visibility is not security. The server strips unauthorised fields before responding; the SPA never strips. BLOCKER. |
| INV-3 | Tenant scripts run in Lua or Wasm with the host allowlist. No network, no disk. BLOCKER. |
| INV-4 | Secrets by reference only — never in logs, traces, error messages or serialised payloads. BLOCKER. |
| INV-5 | A cross-tenant probe is indistinguishable from a not-found. One sentinel, one status code. BLOCKER. |
| INV-6 | Every new data-access path proves its tenant scoping to the security-reviewer. BLOCKER. |

**Done when:** the file exists with a verification step per invariant; the agent
is in `.claude/agents/` and in the WF-02 step list; one CI job runs the
cross-tenant isolation tests on any change under `src/`.

**Effort:** M. **Needs:** PI-01.

---

### PI-03 — A Zig build and lint gate

**Problem.** Your three custom linters police *process artefacts*
(`lint_design_artefact`, `lint_frontend_conventions`, `lint_test_isolation`),
not backend code. There is no `zig fmt --check` and no vet gate. The only
Zig-level check is `zig build 2>&1 | grep -i "error set"` — written in prose,
and your own docs call it "the #1 cause of TEST-RUNNER compile failures."

**Do.** Move that grep into a build step so it fails loudly and identically for
every agent. Add `zig fmt --check` alongside it.

```
zig build check   # zig fmt --check + build + the error-set assertion
```

**Done when:** `zig build check` exists, is referenced from BACKEND-DEV's
workflow instead of the prose grep, and a failing error set fails the command
with a non-zero exit rather than requiring an agent to read stderr.

**Effort:** S. **Value:** highest ratio of the nine — it fires on every one of
~30 WF-02 runs.

---

### PI-04 — One command surface

**Problem.** Commands are duplicated across `README.md`, `CLAUDE.md`,
`backend_developer_guide.md` and `test_developer_guide.md`, forked between bash
and PowerShell (`$env:BPM_DB_URL = …` vs `BPM_DB_URL=… zig build migrate`).
Every agent hand-assembles env plus command. TEST-RUNNER's service pre-check is
prose, which is where INFRA_BLOCK round-trips come from.

**Do.** One `make.ps1` (Windows is your primary environment) or a `Makefile`,
self-documenting, with a **service-readiness wait** rather than an instruction
to check manually:

```
./make.ps1 up          docker compose up -d, then poll pg_isready up to 10x
./make.ps1 migrate     with BPM_DB_URL already set
./make.ps1 test        unit
./make.ps1 test-live   waits for Postgres and Keycloak, then integration
./make.ps1 check       PI-03's gate
./make.ps1 e2e         Playwright against a running stack
```

**Done when:** every guide and agent instruction references the script instead
of a raw command; `test-live` blocks until the services answer, so "service not
up" stops being an agent-visible failure.

**Effort:** S.

---

## Then start the 92. Do the rest opportunistically.

Stop after PI-04. These five are real improvements, but none of them compounds
the way the first four do, and a pipeline that is always being sharpened never
ships. Pick one up when its pain actually bites.

### PI-05 — Scored test-tier rubric and the fail-first rule
Score a change across dimensions (DB schema 2, tenant isolation 2, Wasm 2,
cross-module 1, transactional boundary 1): 0 points = unit only, 1–2 = unit +
integration, 3+ = add sandbox. Today TEST-DESIGNER re-derives the tier every
run. Add the **fail-first rule** at the same time — *a test that passes both
before and after the change proves nothing; every test must fail on the
original code* — which is absent entirely and costs one line in
TEST-DESIGN-VALIDATOR's checklist. **Effort:** S. **Do it when** test scope
starts varying between runs for similar changes.

### PI-06 — Test helpers apply real migration files
Hand-rolled DDL in test helpers drifts silently from the production schema.
You are append-only-migration and event-sourced, so drift fails late and
confusingly. **Effort:** S–M. **Do it when** PW-04 or PW-06 lands, since both
touch migrations directly.

### PI-07 — Gate tiering, flakiness policy, CI path filters
PR gate (unit, fast integration, lint, build) / merge gate (slow integration,
sandbox, isolation) / nightly (perf, chaos). Tag `@flaky`, skip on PR,
fix within 48h or disable. And a path filter so coordination-only commits —
you commit `handoffs/**` and `registry.json` constantly — do not pay for a full
suite. **Effort:** M. **Do it when** full-suite time starts blocking runs.

### PI-08 — Bounded in-branch cascading fixes
WF-05 currently spawns WF-03 for every BLOCKER and MAJOR. ASCOA measured that
fan-out as prohibitively expensive and retired it: register the issue, fix it
on the parent branch, ship one MR, budget 5 per run, then terminate in
`needs-review`. Your `max_rework: 3` is the same intent already. **Effort:** M.
**Do it when** a UAT run first spawns more than two WF-03s.

### PI-09 — Operations runbook and a fail-fast startup assertion
No runbook, no startup assertions. Document the config the app assumes but does
not control, and assert it right after the DB connects with a deterministic
FATAL line whose text is pinned by a test so alerts can match it. **Effort:** S.
**Do it when** you first deploy somewhere you did not set up by hand.

---

## How to dispatch one

These are ADHOC handoffs, not WF-02. No requirement ID, no stage, no UAT.

```
ADHOC-pi03-zig-build-gate-20260730
  agent:     backend-dev
  scope:     tooling only -- no change under src/ except build.zig
  artifacts: build.zig, docs/agents/instructions/zig-conventions.md
  done when: `zig build check` exits non-zero on a formatting error and on an
             error-set regression; BACKEND-DEV's instructions call it instead of
             the prose grep
```

Two rules worth holding:

1. **One PI item per handoff.** They look small and tempt bundling; a bundled
   handoff that half-fails leaves the pipeline in a worse state than before.
2. **No PI item may change `src/` behaviour.** If one seems to need a product
   change, it is not a PI item — it is a requirement, and it goes through
   `reqctl` and a `PW-nn`.

---

## Order, including everything else outstanding

| # | What | Vehicle |
|---|---|---|
| 0 | `ISS-BRW-01` — `secrets/crypto.zig` stores plaintext | WF-03 |
| 1 | **PI-01** split `CLAUDE.md` | ADHOC |
| 2 | **PI-02** security invariants + security-reviewer | ADHOC |
| 3 | **PI-03** `zig build check` | ADHOC |
| 4 | **PI-04** one command surface | ADHOC |
| 5 | `ISS-BRW-02` — `.env.example` | WF-03, any time |
| 6 | The 92 requirements, in the RUNBOOK's order | WF-02 |
| — | **PI-05 … PI-09** | ADHOC, when the pain bites |
