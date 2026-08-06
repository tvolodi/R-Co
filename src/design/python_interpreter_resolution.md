# Design — Deterministic Python interpreter resolution for test subprocesses

**Run:** `WF03-gh374-20260806`
**Issue:** GH [#374](https://github.com/tvolodi/R-Co/issues/374) · `ISS-0147`
**Type:** E (novel / cross-cutting — no lego-catalog template applies)
**Related:** `ISS-0138` (GH #440) fixed `python3` → `python` in `build.zig`; this design
addresses the residual case where bare `python` itself resolves to the Windows Store
App Execution Alias stub.

---

## 0. Module purpose

Provide a single, deterministic way for test subprocesses to obtain a **verified-executable
Python interpreter**, so that a test asserting on a Python tool's exit code observes that
tool's exit code and never a non-interpreter's. Interpreter selection today is by bare name
(`"python"`), which on Windows can resolve to the Microsoft Store App Execution Alias stub
and yield exit 49 in place of the linter's real result. This module replaces name-based
selection with an ordered candidate list where each candidate must pass an execution probe
before it is accepted.

---

## 1. Problem

`tests/integration/tnt_schema_isolation_test.zig` spawns the migration-schema linter as a
subprocess with `argv[0] == "python"` (lines 612 and 680). On Windows, `python` has three
resolutions on this machine's `PATH`:

```
C:\Users\tvolo\AppData\Local\Programs\Python\Python312\python.exe   (real)
C:\Users\tvolo\AppData\Local\Microsoft\WindowsApps\python.exe       (Store alias stub)
C:\Users\tvolo\AppData\Local\Python\bin\python.exe                  (launcher shim)
```

Whenever the WindowsApps stub is reached first — which depends on the `PATH` the spawning
process inherits, and therefore is **not** stable between an interactive shell and a
`zig build`-spawned test binary — the stub prints

```
Python was not found; run without arguments to install from the Microsoft Store, ...
```

and exits **49**. The tests compare against the linter's real exit codes (1 for
TC-TNT-02-03, 0 for TC-TNT-02-04), so both fail.

Verified reproduction (this machine, 2026-08-06):

```
$ C:/Users/tvolo/AppData/Local/Microsoft/WindowsApps/python.exe tools/lint_migration_schema.py <file>
Python was not found; run without arguments to install from the Microsoft Store, ...
exit 49
```

The defect is **interpreter selection**, not linter logic: the same linter run under a real
interpreter produces the expected codes.

### Why `ISS-0138`'s fix is not sufficient

`ISS-0138` established the convention "use `python`, not `python3`, in `build.zig`". That
removed the `python3` stub from the path of two build steps. It does not help here because:

- the failing call sites are inside a **test binary**, not `build.zig`, and
- `python` *itself* has a WindowsApps alias, so the same trap exists one name over.

Name-based selection cannot be made deterministic. Resolution must be **probed**.

---

## 2. Design goals

| Goal | Rationale |
|---|---|
| G1 | Deterministic on Windows **and** non-Windows hosts. |
| G2 | Prefer the repository-selected interpreter (`.venv`) when present — matches what the developer's VS Code session uses. |
| G3 | Never select an interpreter that cannot actually execute code. |
| G4 | Fail loudly and specifically when no interpreter exists — never silently degrade to a wrong exit code. |
| G5 | Single resolution point; call sites do not each re-implement the search. |

G3 and G4 together are the anti-pattern guard: the failure mode this issue describes is a
*non-interpreter* being selected and its exit code being mistaken for the linter's. A
design that merely reorders candidate names would still be vulnerable to that.

---

## 3. Resolution order

The resolver returns the first candidate that **passes the liveness probe** (§4):

| # | Candidate | Source | If it fails the probe |
|---|---|---|---|
| 1 | `$BPM_PYTHON` | explicit operator/CI override — always wins | **hard failure** (see below) |
| 2 | `.venv/Scripts/python.exe` (Windows) / `.venv/bin/python` (POSIX) | repository-selected interpreter, relative to repo root | fall through to 3 |
| 3 | `$VIRTUAL_ENV/Scripts/python.exe` / `$VIRTUAL_ENV/bin/python` | active virtualenv, if the test process inherited one | fall through to 4 |
| 4 | `python3` on `PATH` | POSIX-conventional name; probe rejects the Windows stub | fall through to 5 |
| 5 | `python` on `PATH` | fallback; probe rejects the Windows stub | `error.NoPythonInterpreter` |

Rationale for the order: an explicit override must be unconditional (G1, CI use); the repo
`.venv` is the interpreter the repository itself selects (G2) and is stable regardless of
`PATH`; `PATH` names come last precisely because they are the non-deterministic input this
issue is about.

Candidate 2 is resolved **relative to the repository root**, not the process CWD, so it
holds regardless of where the test binary is spawned from — on a developer machine, where
a `.venv` exists.

**On CI it generally will not.** `.venv/` is gitignored (`.gitignore:55`), so on a fresh
checkout candidates 2 and 3 are both absent and resolution falls through to `python3` /
`python` on `PATH`. That remains *correct* — the probe still rejects any non-interpreter —
but CI's determinism rests on `BPM_PYTHON` (§5.1), not on candidate 2. A CI job that wants a
guaranteed specific interpreter must set `BPM_PYTHON` explicitly.

### `$BPM_PYTHON` is authoritative, not advisory

If `BPM_PYTHON` is set and non-empty, it is the **only** candidate considered. If it fails
the probe, resolution returns `error.BpmPythonOverrideUnusable` — it does **not** fall
through to candidates 2–5.

This is the single most important determinism rule in this design, and it is what makes G1
true rather than merely intended. The alternative (soft override, silently falling back to
`PATH`) reintroduces the exact defect this issue exists to eliminate: an operator or CI job
that names an interpreter would, on a stale or broken path, silently get *a different
interpreter than the one they named* — and the one they'd get is bare `python` on `PATH`,
the non-deterministic input in question. A wrong override is an operator error and must be
loud (G4), not absorbed.

Consequently `build.zig`'s fast path (§5.1) must set `BPM_PYTHON` **only** to an
interpreter it has itself verified, or leave it unset. Setting it speculatively would
convert a recoverable autodetection into a hard failure.

---

## 4. Liveness probe (the core mechanism)

A candidate is accepted only if executing it with

```
<candidate> -c "import sys; sys.stdout.write('BPM_PY_OK')"
```

terminates normally **with exit code 0** *and* writes exactly `BPM_PY_OK` to stdout.

This is what distinguishes a real interpreter from the App Execution Alias stub. Measured
on this machine:

| Candidate | Probe stdout | Probe exit | Accepted |
|---|---|---|---|
| `...\WindowsApps\python.exe` | *(alias message on stdout)* | 49 | ✗ |
| `...\Python312\python.exe` | `BPM_PY_OK` | 0 | ✓ |
| `.venv\Scripts\python.exe` | `BPM_PY_OK` | 0 | ✓ |

Checking the **sentinel on stdout** rather than only the exit code is deliberate: it makes
the probe robust to any future stub that exits 0 while doing nothing useful.

Note this is a probe of the *interpreter*, not a gate on the code under test — it does not
fall under the "never satisfy a gate by editing what it measures" prohibition. It makes the
tests observe the linter's real exit code instead of a stub's, i.e. it restores the
measurement rather than suppressing it.

---

## 5. Public interface

New module: **`tests/integration/python_interp.zig`**

It is placed in `tests/integration/` — beside the existing `tests/integration/helpers.zig` —
specifically so that it needs **no `build.zig` module wiring**. `tnt_schema_isolation_test.zig`
already imports its neighbour by relative path (`const helpers = @import("helpers.zig");`,
line 21), and Zig resolves such an import relative to the importing file. A `tests/support/`
directory would have required either a new named entry in `integration_imports`
(`build.zig:624`) or a `..`-relative import; both are avoidable complexity for a two-call-site
helper. See §8.1 for the full build-wiring statement.

```zig
/// Error set for interpreter resolution.
pub const PythonInterpError = error{
    /// No candidate passed the liveness probe.
    NoPythonInterpreter,
    /// $BPM_PYTHON was set and non-empty but failed the liveness probe.
    /// Never falls through to autodetection — see §3.
    BpmPythonOverrideUnusable,
} || std.mem.Allocator.Error;

/// Resolve a Python interpreter that is verified executable.
///
/// Resolution order: $BPM_PYTHON (authoritative), repo .venv, $VIRTUAL_ENV,
/// python3, python. Each candidate is accepted only after passing the
/// liveness probe.
///
/// OWNERSHIP: caller owns the returned slice and must free it with `allocator`.
pub fn resolve(allocator: std.mem.Allocator, io: std.Io) PythonInterpError![]const u8;

/// resolve() with a process-lifetime cache, so repeated calls within one test
/// binary probe at most once.
///
/// OWNERSHIP: the returned slice is owned by this module, NOT by the caller.
/// Callers must NOT free it. It stays valid until `deinitCache` is called.
/// This contract differs from `resolve` deliberately — see below.
pub fn resolveCached(allocator: std.mem.Allocator, io: std.Io) PythonInterpError![]const u8;

/// Release the cached interpreter path. Call once per test binary, from the
/// last test that used `resolveCached`, so the testing allocator sees no leak.
pub fn deinitCache(allocator: std.mem.Allocator) void;
```

`resolveCached` exists because a test binary may spawn the linter several times (two call
sites today); probing once per process keeps the added cost to a single subprocess spawn.

### Caching semantics (explicit — the two functions differ)

| Aspect | `resolve` | `resolveCached` |
|---|---|---|
| Ownership of result | caller owns; caller frees | module owns; caller must **not** free |
| Repeat calls | probes every call | probes once, then returns the cached slice |
| Are failures cached? | n/a | **no** — only a successful resolution is cached; an error is returned without being memoised, so a transient probe failure does not poison the rest of the run |
| Cleanup | caller's `defer allocator.free(...)` | `deinitCache(allocator)` once per binary |

Getting this wrong is a real hazard under `std.testing.allocator`: if `resolveCached`
returned a caller-owned slice, the second call site would free an already-freed slice
(use-after-free / double-free); if nothing ever frees it, the testing allocator reports a
leak and fails the test. The table above is the contract BACKEND-DEV must implement.

### Fast path via build.zig

`build.zig` sets `BPM_PYTHON` on the integration-test run artifacts to the interpreter it
already uses for its own Python steps. When present, candidate 1 hits immediately and no
probing subprocess is spawned at all. The resolver remains correct without it — this is an
optimisation and a consistency measure (build steps and test subprocesses then provably use
the *same* interpreter), not a dependency.

---

## 6. Call-site changes

`tests/integration/tnt_schema_isolation_test.zig`, both TC-TNT-02-03 (line ~612) and
TC-TNT-02-04 (line ~680):

```
BEFORE:  .argv = &.{ "python", "tools/lint_migration_schema.py", scratch_path }
AFTER:   const py = try python_interp.resolveCached(alloc, std.testing.io);
         .argv = &.{ py, "tools/lint_migration_schema.py", scratch_path }
```

Per §5's ownership table, `py` is module-owned: neither call site frees it. The later of the
two tests calls `python_interp.deinitCache(alloc)` so the testing allocator sees no leak.

The test file gains one import line beside the existing `helpers.zig` import (line 21):

```
const python_interp = @import("python_interp.zig");
```

No change to either test's assertions — they continue to assert exit 1 and exit 0
respectively. The point of the fix is that those assertions now observe the linter.

---

## 7. Error taxonomy

| Condition | Behaviour |
|---|---|
| No candidate passes the probe | `error.NoPythonInterpreter`; the test prints the candidate list it tried and fails. **Never** silently skipped — a skipped test would hide the regression this issue is about (G4). |
| Candidate 2–5 exists but probe spawn fails (`FileNotFound`, `AccessDenied`) | Treated as "candidate rejected"; resolution continues to the next candidate. |
| `$BPM_PYTHON` set (non-empty) but fails the probe | `error.BpmPythonOverrideUnusable`. Resolution **stops** — it does not fall through to candidates 2–5. The message names the offending path so the operator can see which value was rejected. See §3. |
| `$BPM_PYTHON` set but empty / whitespace | Treated as unset; resolution proceeds at candidate 2. This keeps a blank CI variable from becoming a hard failure. |

---

## 8. Dependencies

- `std.process.run` (Zig 0.16), already used by both call sites.
- `std.process.getEnvVarOwned` for `BPM_PYTHON` / `VIRTUAL_ENV`.
- `builtin.os.tag` to select `Scripts/python.exe` vs `bin/python`.
- No new third-party dependency; no change to `tools/lint_migration_schema.py`.
- No dependency on `bpm`, `env`, `build_options`, or `helpers.zig` — the module is
  self-contained and depends only on `std`.

### 8.1 Build wiring (exhaustive)

This design's total footprint in `build.zig` is **one optional line**. Specifically:

| Change | Where | Required? |
|---|---|---|
| New module `tests/integration/python_interp.zig` becomes importable | *nothing* — resolved by relative `@import` from the test file, exactly as `helpers.zig` is today (`tnt_schema_isolation_test.zig:21`) | n/a |
| Add `python_interp.zig` to `integration_imports` (`build.zig:624`) | — | **No.** A relative import needs no named module entry. |
| `run_tnt_integration_tests.setEnvironmentVariable("BPM_PYTHON", <verified path>)` | `build.zig:794-796`, beside the existing `BPM_MIGRATIONS_DIR` line | **Optional** (fast path, §5.1) |

The `BPM_PYTHON` line is optional because the resolver is correct without it: with the
variable unset, resolution simply starts at candidate 2. It is worth adding only if
`build.zig` can supply a path it has verified — per §3, an unverified value would convert a
recoverable autodetection into `error.BpmPythonOverrideUnusable`. **BACKEND-DEV should
implement the resolver first, confirm the tests pass with `BPM_PYTHON` unset, and add the
fast-path line only if it can be set from a verified source.** No other `build.zig` edit is
in scope for this design (see §10).

---

## 9. Acceptance criteria mapping (GH #374)

| Issue criterion | Satisfied by |
|---|---|
| Integration tests resolve the repository-selected interpreter deterministically on Windows and non-Windows | §3 order + §4 probe; §5 `.venv` path is OS-branched |
| TC-TNT-02-03 observes expected linter rejection exit 1 | §6 — assertion unchanged, now reaching the real linter |
| TC-TNT-02-04 observes expected linter acceptance exit 0 | §6 — as above |
| Full `zig build test-integration` no longer contains `Python was not found` | §4 rejects the alias stub before it is ever used to run the linter |

---

## 10. Out of scope

The four `build.zig` bare-`python` call sites (lines 1143, 1149, 1520, 1546) are **not**
changed by this design beyond adding the `BPM_PYTHON` pass-through. They are covered by the
`ISS-0138` convention and are not implicated in this issue's reproduction. If they are found
to fail on a host where the `PATH` order differs, that is a separate finding to be filed and
enqueued per `docs/agents/protocols/ISSUE_QUEUE.md`.
