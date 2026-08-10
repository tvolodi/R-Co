# CI gate tiering (GH-297 / ISS-0082)

Type E design note. MINOR-severity process improvement — scope is deliberately
conservative: do the mechanical, low-risk part fully, and do not invent
machinery the repo doesn't yet have a use for.

## Module purpose

This design covers `.github/workflows/ci.yml`'s trigger configuration and
`docs/guides/test_developer_guide.md`'s CI-process documentation — not a Zig
module, so "module" here means the CI trigger surface plus the flaky-test
convention. The purpose is to reduce redundant full-suite CI runs on commits
that touch only cross-workspace coordination state, and to record a written
answer (not silence) on whether the issue's two other asks — gate tiering
and flaky-test tooling — are justified by the repo's current state.

## What the issue asks for

> Tier the gates: PR gate (unit, fast integration, lint, build) / merge gate
> (slow integration, sandbox, isolation) / nightly (perf, chaos). Tag @flaky,
> skip on PR, fix within 48h or disable. Add a path filter so
> coordination-only commits do not run the full suite.

Three sub-asks. Each is evaluated against the actual state of `.github/workflows/ci.yml`
and the test suite, not assumed.

## 1. Path filter — implemented

`ci.yml`'s `on:` block currently runs all 7 jobs unconditionally on every
`push`/`pull_request`. This workspace and its sibling (`r-co-2` and `r-co-1`)
are both running an autonomous issue-resolution loop right now, and every
loop iteration ends with a `queue_release.py` commit that touches only
`handoffs/global_queue.json` (and usually `handoffs/orchestrator.log`). Two
such commits landed on `main` in the minutes before this run started
(`bb42d71`, `39ae098`). Running the full 7-job, ~7-job-minutes-of-runner-time
suite for a JSON lock-file update is pure overhead — this is the concrete,
already-happening case the issue describes.

**Design decision:** add `paths-ignore` to both `push` and `pull_request`
triggers, scoped to paths that are *pure coordination bookkeeping with no
code, schema, or gate-relevant content*:

```yaml
paths-ignore:
  - 'handoffs/global_queue.json'
  - 'handoffs/orchestrator.log'
  - 'handoffs/registry.json'
  - 'docs/status/**'
```

**What is deliberately NOT excluded, and why:**

- `handoffs/**` generally (i.e. individual step handoff JSON files, and
  `handoffs/<run-id>/` directories) — the `bookkeeping` job's `Handoff
  schema, timestamps, encoding` step runs `python3 tools/lint_handoffs.py
  --changed`, which lints exactly the handoff files a branch touches (see
  `tools/lint_handoffs.py` module docstring: "`--changed` restricts findings
  to handoff files the branch actually touched"). Excluding `handoffs/**`
  wholesale would silently stop linting the one class of file that linter
  exists to check on every PR. Only the three specific files above are
  excluded, because they are pure state (a lock registry, an append-only
  log, a routing table) that `lint_handoffs.py --changed` does not itself
  validate as its primary target — the step still runs on any PR that also
  touches an actual `handoffs/<run-id>/step-*.json` file, which is the case
  the linter is for.
- `docs/issues/**` and `docs/issue-reports/**` — not excluded. These are
  content (root-cause diagnoses, resolution records) rather than pure
  coordination state, and nothing currently gates on them, but excluding
  them provides no measurable benefit (they change infrequently, only as a
  side effect of an actual fix landing alongside code) while adding a
  category human reviewers might expect CI to still touch. Left in scope.
- `.github/workflows/**` — never excluded, and cannot be, since this PR
  itself touches `.github/workflows/ci.yml`. A path filter that excluded the
  workflow directory would make it impossible to verify changes to the
  workflow via its own triggered run. This is checked directly on this PR
  (see verification below): the PR's changed files include
  `.github/workflows/ci.yml`, `docs/design/...`, and `docs/issues/...`, none
  of which match `paths-ignore`, so the full suite must still trigger.

`docs/status/**` is added because `reqctl.py render-status` output
(`docs/status/requirement_status.yaml`) and release decision files are
generated/recorded artifacts, not something any current CI job inspects.

## 2. Gate tiering (PR gate / merge gate / nightly split) — judged unnecessary at this time

Measured actual per-job duration from a representative recent green run
(`gh run view <id> --json jobs`, run `31426634920`, 2026-08-10):

| Job | Duration |
|---|---|
| Platform status | 9s |
| Pipeline bookkeeping | 11s |
| Source linters | 11s |
| Frontend checks | 38s |
| Fresh-database migration bootstrap | 49s |
| Build and unit tests | 87s |
| Clean-checkout LuaJIT build (test-lua) | 125s |

Total wall clock for the slowest job is ~2 minutes; the jobs run in
parallel, so a full CI run currently completes in 2–4 minutes end to end
(confirmed against `gh run list --limit 20`: recent successful runs show
`startedAt`→`updatedAt` deltas of 2–3 minutes). None of the 7 jobs in
`ci.yml` runs `zig build test-integration` (the aggregate suite ISS-0658/
ISS-0659 measured at ~12 minutes) or any Playwright E2E suite — the guide's
own §10 CI Integration Notes documents integration tests and E2E as later
pipeline stages, not part of this workflow file. `ci.yml`'s own `build` job
comment states this explicitly: "No database: integration tests need
PostgreSQL and Keycloak, which belong in a separate workflow rather than
gating every PR."

**Design decision: do not add a merge-gate/nightly split at this time.**
There is no slow job currently in `ci.yml` to move out of the PR path — the
one thing that actually is slow (`test-integration`, ~12 minutes) already
does not run here. Inventing a second workflow file to hold jobs that don't
yet exist (sandbox tests, isolation tests, perf tests, chaos tests) would
add maintenance surface with nothing concrete to put in it: `find tests/
-iname '*perf*' -o -iname '*chaos*'` returns no matches anywhere in the
repo. Per CLAUDE.md's Zero Manual Work directive read correctly — it binds
agent effort, not a mandate to over-build infrastructure a MINOR issue does
not need — the smallest correct action is to record this finding and leave
the door open rather than fabricate a nightly job with an empty job body.

If a genuinely slow gate is added later (e.g. `test-integration` wired into
CI, or a real perf/chaos suite under `tests/`), the split described in the
issue is the right shape and should be implemented then, against real
job(s) rather than placeholders. This design note is the record that the
question was asked and answered "not yet, and here is the evidence" rather
than silently skipped.

## 3. Flaky-test policy — documentation only

The issue's flaky-tagging ask ("tag @flaky, skip on PR, fix within 48h or
disable") is a **convention**, not infrastructure that needs new code. No
flaky-test marker or skip mechanism exists anywhere in the repo today
(`grep -rn "@flaky"` returns nothing), and there is currently no slow/CI-gated
test category to apply it to (per §2 above — CI's own tests all pass
reliably and quickly; the known-flaky surface is `zig build test-integration`,
which is not in `ci.yml` at all).

**Design decision:** add a written policy section to
`docs/guides/test_developer_guide.md` §10 (CI Integration Notes), stating:

- A test suspected flaky (fails intermittently, not on a genuine assertion
  a code change should have caught) gets a `// FLAKY(GH-<issue>):` comment
  directly above the failing `test` block, naming a tracking GitHub issue
  filed the same way any other discovered defect is filed (per CLAUDE.md's
  "No Issue Left Local-Only").
- The comment is a marker for humans/agents reading the file, not an
  enforcement mechanism — there is no skip macro to build until a real case
  exists, per the same reasoning as §2.
- The tracking issue must be resolved (test fixed or the test deliberately
  disabled with a change reviewed the same as any other) within 48 hours of
  being marked; ISSUE-FIXER treats a `FLAKY` marker older than 48h as a
  BLOCKER-worthy finding when encountered.
- This reuses the existing `ISS-0659`-style precedent already in this repo
  (a documented, evidenced root-cause + forwarded GitHub issue) rather than
  adding new tooling.

This keeps the policy real and enforceable-by-convention without building
unused machinery, consistent with the MINOR severity of this issue.

## Public interface

The surface this design changes is configuration and documentation, not a
Zig API, but it has an equally concrete external contract:

- **`.github/workflows/ci.yml` `on:` block** — the `paths-ignore` lists
  under `push` and `pull_request` are the interface other workspaces and
  future commits interact with implicitly, by which paths they touch. A
  commit touching only the four listed paths does not trigger the 7-job
  suite; a commit touching anything else (including any single file inside
  `handoffs/<run-id>/`) triggers it exactly as before. This is the only
  behavioural change introduced by this design.
- **`// FLAKY(GH-<issue-number>): <symptom>. Filed <date>.`** — the
  documented comment convention is the interface between a test author (or
  agent) marking a test and ISSUE-FIXER/TEST-RUNNER later reading it. No
  code parses this comment; it is read by humans and agents per the
  written policy in `test_developer_guide.md` §10.1.
- **`src/design/ci-gate-tiering.md`** itself — the interface between this
  decision and any future agent revisiting the gate-tiering question. It
  answers "was tiering considered and rejected, or never considered" so a
  future run does not have to re-derive the same job-duration evidence.

## Error taxonomy

Failure modes considered for this change, and how each is guarded:

- **A commit that should trigger CI is silently skipped.** Guarded by
  keeping `paths-ignore` narrow (four specific files/patterns, not a
  directory-wide `handoffs/**` or `docs/**`) and by verifying live on this
  design's own PR that a run touching `.github/workflows/ci.yml` plus
  `docs/` files outside `docs/status/` still triggers the full suite (see
  ISS-0082.json `verification`).
- **`bookkeeping` job's `lint_handoffs.py --changed` loses coverage.**
  Guarded by explicitly not excluding `handoffs/**` — only the three named
  files that `--changed` mode does not itself validate as its primary
  target (see §1 above for the full reasoning).
- **Malformed YAML breaks CI for every branch, including the sibling
  workspace's.** Guarded by validating with
  `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
  before pushing, and by watching the live PR run rather than assuming the
  trigger behaves as written.
- **A future reader assumes gate tiering was never considered and
  re-proposes it without evidence.** Guarded by recording the actual
  measured job durations and the "not yet, here is why" decision in this
  document rather than leaving the question unanswered.
- **A `FLAKY` marker is added and never followed up.** Guarded by the
  written 48-hour rule and by naming ISSUE-FIXER/TEST-RUNNER as the parties
  that treat a stale marker as a finding — the same enforcement-by-review
  pattern the rest of this repo's issue lifecycle already relies on.

## Files changed by this design

- `.github/workflows/ci.yml` — add `paths-ignore` to `push` and
  `pull_request` triggers.
- `docs/guides/test_developer_guide.md` — new flaky-test policy subsection
  under §10.
- `docs/issues/ISS-0082.json` — bookkeeping record for this issue.

No new workflow file, no new build steps, no new Zig code.
