# Unified command surface (GH-294 / ISS-0079 / PI-04)

Type E design note. MAJOR-severity issue, Effort: S per `docs/agents/PIPELINE_BACKLOG.md`
— the target is a straightforward script with a handful of named subcommands,
not a general-purpose task runner or framework.

## Problem

Commands to run and validate the BPM Platform stack were duplicated across
`README.md`, `CLAUDE.md`, `docs/guides/backend_developer_guide.md`,
`docs/guides/test_developer_guide.md`, and `docs/guides/test_infrastructure_guide.md`,
forked between bash and PowerShell forms
(`BPM_DB_URL=... zig build migrate` vs `$env:BPM_DB_URL = "..."; zig build migrate`),
and every agent hand-assembled env vars plus the raw command from prose. TEST-RUNNER's
service pre-check (`docker-compose ps`, `curl .../health/ready`, `psql -c "SELECT 1"`)
was itself prose describing a manual, non-blocking check rather than a wait — this is
where INFRA_BLOCK round-trips between ORCH and BACKEND-DEV came from (ORCH dispatches
BACKEND-DEV to start services, BACKEND-DEV starts them, but nothing in the pipeline
actually blocks until they are ready before TEST-RUNNER tries again).

## What was built

One script, `make.ps1`, at the repo root (PowerShell, since this repo's primary
environment is Windows per the design brief). It exposes exactly the subcommands the
issue specifies:

| Subcommand | What it does |
|---|---|
| `up` | `docker compose up -d`, then polls every service's Docker health status (reusing the healthchecks already defined in `docker-compose.yml` / `docker-compose.override.yml` — `db`, `db_test`, `keycloak`, `keycloak_gateway`) up to 10 times with a 3-second delay, failing clearly if any service is still unhealthy after that. |
| `migrate` | `zig build migrate`, with `BPM_DB_URL` sourced from `.env` by the script's own dotenv loader — the caller does not export it by hand. |
| `test` | `zig build test` (unit tests only, no services required). |
| `test-live` | Runs the same readiness wait as `up` for `db`, `db_test`, `keycloak`, `keycloak_gateway`, then `zig build test-integration` with `BPM_TEST_DB_URL` sourced from `.env`. This is the subcommand that makes "service not up" stop being an agent-visible failure — the command blocks until services answer instead of a TEST-RUNNER pre-check discovering they are still down. |
| `e2e` | `cd web && npm run test:e2e` (the existing Playwright script; `playwright.config.ts` already manages its own dev-server lifecycle via `webServer.reuseExistingServer`). |
| `check` | See "Scoping `check`" below — an explicitly-labelled interim stand-in, not PI-03's real gate. |
| `help` / no args | Prints the subcommand table above. |

### Why a `.env` loader instead of requiring the caller to `Set-Item Env:`

The issue's "done when" criterion is specifically that `test-live` blocks on real
readiness and that agents stop hand-assembling env + command. A script that still
required `$env:BPM_DB_URL = "..."` before invocation would not fix that — the exact
duplication (env assembly forked between the run and the docs describing the run)
would just move one layer down. `make.ps1` reads `.env` itself (skipping comments and
blank lines, stripping one layer of surrounding quotes) and populates the process
environment before invoking `zig build migrate` / `zig build test-integration`, so a
workspace's already-configured `.env` (this workspace: `BPM_DB_URL` on port 5452,
`BPM_TEST_DB_URL` on port 5453 — see `.env`'s parallel-workspace port-shift comment)
is picked up automatically. No workspace's ports are hardcoded in the script itself.

### Why readiness polling reuses Docker's own health status

`docker-compose.yml` already defines a `healthcheck:` block for all four services
(`pg_isready` for both Postgres containers, a `/health/ready` HTTP probe behind the
Keycloak gateway, a TCP probe for Keycloak itself). `Wait-ServicesHealthy` calls
`docker compose ps --format json` and reads each service's `.Health` field rather than
re-implementing a second, possibly-inconsistent probe (e.g. a bare TCP connect that
would report "up" before Postgres has finished recovery, or before Keycloak has
imported the realm). This is the same signal `docker compose ps` already surfaces to a
human running it by hand — the script does not invent a new readiness definition.

### PowerShell 5.1 compatibility note (found during validation)

An early version of the script set `$ErrorActionPreference = "Stop"` at the top,
matching a common PowerShell-script convention. This turned out to be actively wrong
here: `zig build test` (and other native tools invoked below) routinely write normal
progress/advisory text to stderr on a **successful** run, and PowerShell 5.1's
`NativeCommandError` wrapping — triggered by `"Stop"` — turns that stderr traffic into
a terminating error even though the process's own exit code is 0. The script now
relies on `$LASTEXITCODE` exclusively to judge success/failure of every native command
it invokes, and does not set a blanket `ErrorActionPreference`. (Separately, invoking
the script itself with an outer `2>&1`, e.g. `.\make.ps1 test 2>&1`, reproduces the
same wrapping one layer up, in the *caller's* shell — this is a documented PowerShell
5.1 quirk, not a defect in the script; it was confirmed during validation by running
`.\make.ps1 test` both with and without the outer redirection.)

## Scoping `check`

The issue's blueprint names `check` as "PI-03's gate" — but PI-03 (a real,
build-graph-integrated `zig build check` step combining `zig fmt --check`, the build,
and the error-set grep) is GH-293, a separate, still-open issue. This was verified
directly before starting, not assumed:

- `gh issue view 293 --json state` → still `OPEN`.
- `grep -n 'b.step("check"' build.zig` → no such step exists in `build.zig`.

Implementing GH-293's actual gate logic inside this run would be uncoordinated scope
creep on an already-substantial MAJOR issue, and would pre-empt whatever design
GH-293 eventually settles on for the real gate.

`make.ps1 check` is therefore built as an explicit, labelled **interim stand-in** —
option (a) from the issue brief, not option (b) (omit entirely). It runs exactly the
two commands CLAUDE.md's BACKEND-DEV section already mandates before self-review:
`zig build`, followed by a grep of that output for the literal text `"error set"`
(the existing `zig build 2>&1 | grep -i "error set"` pattern, already prose-documented
as mandatory). Every line of output is prefixed `PRE-PI-03 INTERIM STAND-IN` / labelled
`(interim stand-in — not the real PI-03 gate; see GH-293)` so nobody mistakes a PASS
here for PI-03's real gate passing.

`zig fmt --check src/` was tried during design and deliberately dropped from the
final version. Running it directly against the current `main` reports 225 files as
non-conforming, repo-wide, unrelated to this change:

```
zig fmt --check src/ | wc -l   # 225
zig fmt --check src/ ; echo $? # 1
```

`zig fmt` was never part of CLAUDE.md's mandated backend self-review checklist in the
first place (only `zig build`, `zig build test`, `zig build migrate`, the error-set
grep, and the SQL type-cast linter are listed there). Folding a pre-existing,
unrelated, 225-file formatting backlog into `check` would make the interim stand-in
fail for reasons that have nothing to do with whatever change is actually being
validated — exactly the kind of noise a real PI-03 gate needs to be designed around
deliberately (e.g. formatting only files touched by the current diff), not something
this stand-in should pre-empt by accident. `check`'s design note and this section
record that decision so it is not silently dropped when GH-293 is eventually picked
up — GH-293 should decide fmt scope on purpose, not inherit whatever `make.ps1` did by
default.

## Validation of `test-live` against the real aggregate suite

`./make.ps1 test-live` was run against this workspace's real, already-healthy
containers. The readiness wait reported all four services healthy on attempt 1/10 and
correctly proceeded straight to `zig build test-integration` with `BPM_TEST_DB_URL`
sourced from `.env` — confirming the logic this issue is actually about. The aggregate
suite itself then surfaced a large volume of `runMigrations`/`acquireIntegrationLock`
contention on the `bpm_test_migrations_public` advisory lock across many unrelated test
files. `git log` confirms this workspace has an extensive, active, ongoing history of
exactly this class of issue (ISS-0659/GH-681 "extend advisory lock to all 31
self-managed-pool binaries" and its lineage — ISS-0658, ISS-0655, ISS-0654, ISS-0652,
ISS-0651, ISS-0646 — among the last ~20 commits touching this exact area), unrelated to
and unmodified by this change. Per this issue's own guidance to trust
`zig build test-integration` itself rather than necessarily running the full aggregate
suite to completion (that suite is pre-existing and not what this change touches), the
run was stopped once the readiness-wait/dispatch behavior was confirmed correct.

## Docs updated

Per the issue's actual "done when" criterion — every guide references the script
instead of restating the raw command — the following were grepped for the specific
raw invocations (`zig build migrate`, `zig build test-integration`, `docker-compose up
-d`, `zig build test`, `npx playwright test`) and updated to point at `make.ps1`:

- `README.md` — Quick start steps 1–2 now show `./make.ps1 up` / `./make.ps1 migrate`
  as the primary path, with the raw bash/PowerShell forms kept directly underneath
  ("what the script expands to") rather than deleted, since the quick-start is a
  first-contact document for a reader who may not yet have Node/PowerShell execution
  policy set up. The command table's rows were updated to reference `make.ps1`.
- `CLAUDE.md` — BACKEND-DEV's "Validate" step, the error-set-grep step's surrounding
  text, TEST-RUNNER's service-check pre-check, and ORCH's INFRA_BLOCK ADHOC
  BACKEND-DEV task template were updated to show the `make.ps1` form as primary. The
  literal raw commands are kept alongside (not deleted) in the ADHOC task template and
  the BACKEND-DEV "Allowed commands" list, since those are hard-gate instructions
  agents currently rely on for literal command text — CLAUDE.md's own structure
  (section headers, hard-gate wording, "Allowed commands" fences) was left otherwise
  unchanged.
- `docs/guides/backend_developer_guide.md` — the development-commands table and the
  "Bootstrap test database" section now reference `make.ps1 migrate` / `make.ps1 test`
  alongside the underlying `zig build` commands (the table is also the authoritative
  list of individual `zig build test-<module>` targets, which `make.ps1` does not
  wrap individually — only the two blueprint-named aggregate subcommands, `test` and
  `test-live`, are in scope here).
- `docs/guides/test_developer_guide.md` — the manual verification checklist and the
  flaky-test-policy cross-reference to `zig build test-integration` now mention
  `make.ps1 test-live` as the wrapped form.
- `docs/guides/test_infrastructure_guide.md` — the Infrastructure Health Checklist's
  `zig build migrate` verification command and the manual-migration example now
  reference `make.ps1 migrate` / `make.ps1 up`.

## What was not changed

- `.github/agents/*.agent.md` and `.github/instructions/*.instructions.md` — these
  are a separate instruction layer (Copilot / per-agent Claude Code files) not named
  in the issue's affected-files list (`README.md`, `CLAUDE.md`, `docs/guides/`).
  `tools/lint_agent_docs.py` does not check `CLAUDE.md` itself (it checks the
  per-agent files against `docs/agents/shared/HANDOFF_PROTOCOL.md`), so updating
  `CLAUDE.md` alone does not trip that linter. Touching 8 additional per-agent files
  to also reference `make.ps1` would meaningfully exceed Effort: S for this issue;
  left as a natural follow-up if/when those files are next touched for another reason.
- `zig build test-env-verify` (`tools/verify_test_env.py`) itself — this is the
  Infrastructure Health Checklist's authoritative exit-code gate (§3 of
  `test_infrastructure_guide.md`) and is explicitly judged "by the exit code only,
  never by whether particular words appear in the output" per CLAUDE.md's own
  anti-pattern warning. `make.ps1` does not wrap or re-implement it; TEST-RUNNER
  continues to invoke `zig build test-env-verify` directly as its own pre-check.
