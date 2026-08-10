# `zig build check` — the PI-03 build and lint gate (GH-293 / ISS-0078)

Type E design note. MAJOR-severity issue, Effort: S — a build-graph step plus a doc
reference update, not a new subsystem.

## Problem

The only Zig-level check BACKEND-DEV's workflow named was prose an agent had to run and
read by hand:

```bash
zig build 2>&1 | grep -i "error set"
```

`CLAUDE.md` itself called this "the #1 cause of TEST-RUNNER compile failures and WF-03
dispatches" — yet nothing enforced it ran, and a passing exit code from `zig build`
carried no formatting guarantee at all (`zig fmt --check` did not exist anywhere in the
pipeline). The three existing custom linters (`lint_design_artefact`,
`lint_frontend_conventions`, `lint_test_isolation`) police process artefacts, not
backend Zig source.

## Investigation: does the grep do anything the exit code doesn't?

No. Verified directly: a minimal function declared to return `NarrowError!void` that
actually returns a `WideError!void` value (where `WideError` is a superset of
`NarrowError`) fails `zig build-exe` outright —

```
error: expected type 'error{Foo}!void', found 'error{Bar,Foo}!void'
note: 'error.Bar' not a member of destination error set
```

— with exit code 1 and no binary produced. This is a genuine compile error, not
advisory stderr text sitting alongside a 0 exit code. The grep therefore added no
coverage beyond what `zig build`'s own exit code already provided; it existed only
because agents were instructed to run the build manually and inspect stderr rather than
trust the process result. **Fix: trust the exit code. No new error-set detection logic
was written — `zig build check` depends on the normal build step and inherits its exit
code.**

## Investigation: whole-tree `zig fmt --check`

Re-verified independently (not just trusting the prior PI-04/ISS-0079 run's number):

```
zig fmt --check .          → 440 files
zig fmt --check src        → 225 files
zig fmt --check tests      → 200 files
zig fmt --check build.zig build.zig.zon  → both unformatted
```

The remaining ~13 files are under `vendor/` (third-party, must never be reformatted by
this repo) and `scratch/` (git-ignored, never part of a PR). Gating on the whole tree
would fail on 425+ files of debt unrelated to any given change — attributing pre-existing
formatting drift to whichever branch happens to run the gate, and making every future PR
red on day one regardless of what it touches.

### Decision: scope to the current branch's diff, not the whole tree

`tools/check_fmt_scope.py` computes the `.zig` files that differ between the current
worktree and `main` (committed diff via `git diff --name-only main...HEAD`, plus
uncommitted and untracked `.zig` files so nothing about to be pushed is missed), then
runs `zig fmt --check` against exactly that list. Empty list = pass trivially (nothing to
check). This is the standard pattern for introducing a formatting gate into a codebase
carrying pre-existing debt: fail loudly for *this* change, without punishing branches for
debt they didn't create.

This does not make the 425-file debt disappear — it is still there and still worth
cleaning up as its own, separately-reviewable, whole-tree `zig fmt` commit at some point
(a change large enough that it deserves its own PR and its own careful CI watch, not to
be folded into a MAJOR/Effort:S issue). That cleanup is intentionally **not** done here;
see `docs/issues/ISS-0078.json` for the follow-up note. Whole-tree gating can be turned on
once that debt is cleared, by pointing `check_fmt_scope.py` (or a successor) at `.` instead
of the diff.

### Why not `--exclude`?

`zig fmt --check --exclude vendor --exclude scratch .` was tried and confirmed to work
(drops the tree from 440 to 428), but 428 remaining pre-existing violations under `src/`
and `tests/` make whole-tree-minus-excludes just as unusable as whole-tree today. `--exclude`
is the right tool for permanently-excluded paths (vendored/generated code), not for
"everything we haven't gotten around to formatting yet." The scoped-diff approach in
`check_fmt_scope.py` is orthogonal and composable with `--exclude` if vendor/scratch ever
stop being excluded by other means.

## What was built

1. `tools/check_fmt_scope.py` — scoped `zig fmt --check`, described above. Exit 0 on an
   empty diff or an all-formatted diff; exit 1 with the offending file list otherwise.
2. `build.zig`: `zig build check` step. Depends on (a) the default install step (the
   build itself — this is the error-set assertion, no separate logic needed) and (b)
   `check_fmt_scope.py` via `b.addSystemCommand`. Follows the same
   `b.addSystemCommand` + `b.step(...)` pattern already used for
   `zig build test-env-verify` and `zig build test-wiring-check`.
3. `CLAUDE.md`: BACKEND-DEV's "Error-set validation" step replaced with "Build and
   formatting gate," now referencing `zig build check` directly; self-review checklist
   item updated to match; Allowed-commands list updated.
4. `docs/agents/workflows/WF-02_requirement_implementation.md`: Step 8 updated to match.
5. `README.md`: `make.ps1 check` row updated from "interim pre-PI-03 stand-in" to the real
   gate description.
6. `make.ps1`: `Invoke-Check` now calls `zig build check` directly instead of
   reimplementing the interim `zig build` + grep logic from GH-294/ISS-0079/PI-04. Help
   text and doc-comment header updated to match.

## Validation performed

- `zig build check` exits 0 on the clean tree (confirmed via raw `$LASTEXITCODE`, not
  piped through a text filter that can obscure PowerShell 5.1 native-command exit
  semantics).
- Deliberately broke formatting in `build.zig` (`const check_step   =    b.step(`) and
  confirmed `zig build check` fails with exit 1, correctly identifying `build.zig` as the
  offending file; reverted and reconfirmed pass.
- `zig build` (full) exits 0.
- `zig build test` exits 0 (raw exit code captured directly to a log file, not through a
  pipe — `--listen=-` protocol chatter from the test runner can otherwise look like
  "failed command" text in a terminal even on a genuine pass).
- `./make.ps1 check` and `./make.ps1 help` both run correctly against the updated
  `Invoke-Check`.

## Effort note

This came in as designed: a `build.zig` addition (~45 lines including comments), one new
~100-line Python helper following the existing `tools/verify_test_env.py` /
`tools/lint_test_wiring.py` house style, and doc reference updates. No new subsystem, no
whole-tree reformat.
