# Module: fix-ISS-0111 — deterministic cross-platform Python interpreter resolution for `tools/lint_migration_schema.py` invocations from `tnt_schema_isolation_test.zig`

**Tracker:** GitHub #374 / recommended new local entry `ISS-0111` (triage cross-reference `WF03-gh364-20260801-PYTHON-PATH`).
**Parent run:** `WF03-gh364-20260801` (parent issue GitHub #364 / ISS-0106).
**Parent handoff:** `3195ef19-1619-466f-be1c-5a0f8418014e` (Step 3, FAIL with GH-366 / GH-374 / GH-359 blockers).
**Blocker triage handoff:** `f7c3b8e2-4a1d-4f8e-9b2c-1e5a7d3f6c8b` (Step 03a, PASS — see `docs/issue-reports/WF03-gh364-20260801-step-03a-issue-fixer-blockers-INNER-REPORT.yaml`).
**Classification:** **Type E** (cross-cutting — cross-platform subprocess resolution + multi-callsite consistency + lifetime-of-allocated-path ownership). This is novel design work: it specifies a small, deterministic, environment-overridable helper that resolves a Python interpreter path on Windows and POSIX, then threads that resolved path into the two existing `std.process.run` callsites, with a strict error behavior when no interpreter exists. It is not a CRUD endpoint, not a list page, not a migration, not a React Flow node. Per `templates/lego-catalog.md` selection rule 5 ("Type E otherwise") this is unambiguously Type E.

---

## Module purpose

`tests/integration/tnt_schema_isolation_test.zig` must launch `tools/lint_migration_schema.py` as a child process for two of its tests (`TC-TNT-02-03`, `TC-TNT-02-04`) and assert on the subprocess's exit code and output. The current implementation hard-codes the literal interpreter name `"python3"`, which is portable on POSIX (resolves to `/usr/bin/python3`) but unsafe on Windows (resolves to the Microsoft Store AppExecutionAlias stub at `C:\Users\<user>\AppData\Local\Microsoft\WindowsApps\python3.exe`, which prints "Python was not found" and exits 49 — failing both tests). This module specifies a small, environment-overridable interpreter resolver that the two subprocess invocations call before launching, eliminating the platform-specific ambiguity while preserving current Linux/macOS CI behavior.

## Summary

`tests/integration/tnt_schema_isolation_test.zig` (test IDs `TC-TNT-02-03` at line 563, `TC-TNT-02-04` at line 635) launches `tools/lint_migration_schema.py` as a child process via `std.process.run` with `.argv = &.{ "python3", "tools/lint_migration_schema.py", scratch_path }` (line 592 and line 660). The literal `"python3"` is unsafe on Windows: the `where.exe python3` lookup on the current host returns `C:\Users\tvolo\AppData\Local\Microsoft\WindowsApps\python3.exe` (the Microsoft Store AppExecutionAlias stub) **before** any other match, the stub prints `"Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Apps > Advanced app settings > App execution aliases."` to stderr, and exits with code 49. The tests assert specific exit codes (`expectEqual(@as(u8, 1), exit_code)` for `TC-TNT-02-03`, `expectEqual(@as(u8, 0), exit_code)` for `TC-TNT-02-04`); exit 49 fails both, with the captured log showing `"expected 1, found 49"` and `"expected 0, found 49"` respectively. On Linux/macOS CI the same literal `"python3"` typically resolves to a real interpreter (e.g. `/usr/bin/python3`) and the tests pass — this is a Windows-host-specific failure mode that does not surface on the project's Linux CI agents but blocks the project's own Windows-based integration verification.

**Captured evidence (from `scratch/WF03-gh364-20260801-step03-full-integration-utf8.log`):**

- Line 3260: `linter stderr: Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Apps > Advanced app settings > App execution aliases.`
- Lines 3256-3321: `TC-TNT-02-03` and `TC-TNT-02-04` both fail with `expected 1, found 49` and `expected 0, found 49` respectively.
- `where.exe python3` on the current host: `C:\Users\tvolo\AppData\Local\Microsoft\WindowsApps\python3.exe` (AppExecutionAlias) first, then `C:\Users\tvolo\AppData\Local\Python\bin\python3.exe` (real shim) second.
- Repository `.venv` has `C:\Users\tvolo\dev\ai-dala\R-Co\.venv\Scripts\python.exe` available — the natural choice for both invocations, but neither test currently uses it.

The fix is a small, environment-overridable interpreter-resolution helper at the top of `tests/integration/tnt_schema_isolation_test.zig` (and, in the same design's optional companion, a shared helper in `tests/integration/helpers.zig` if a second test file ever needs the same logic) that resolves the interpreter in a strict priority order, and both `std.process.run` argv arrays then use the resolved string. The helper's ownership and lifetime are explicit (allocated with `std.testing.allocator`, freed via `defer` inside the helper, callers receive a `[]const u8` that is valid only for the helper's body — but the existing test code already owns the allocator and the helper returns a copied slice, see "Required change" below). The error behavior when no interpreter exists is `error.MissingTestPythonInterpreter` — distinct from the existing `error.MissingTestDatabaseUrl`, surfaceable in the test log with a clear remediation message, and not silently swallowed by the helper.

---

## Root cause (definitive, source- and log-verified)

`std.process.run` (Zig 0.16.0 standard library) accepts an `argv` array; on Windows, the first element is resolved against the system PATH by `CreateProcess` rules. `CreateProcess` does **not** skip AppExecutionAlias directories, does **not** warn that the resolved target is a Microsoft Store stub rather than a real interpreter, and does **not** apply any "preferred real interpreter" precedence. The result is that the first PATH match wins, and on a typical Windows dev machine that first match is `C:\Users\<user>\AppData\Local\Microsoft\WindowsApps\python3.exe` because Windows adds that directory to PATH ahead of any user-installed Python. The stub binary's exit behavior (exit 49 + the "Python was not found" stderr) is the OS-level design, not a Python or Zig bug.

The test code's choice of `python3` was correct for Linux/macOS (where `python3` is a real interpreter) but unsafe for Windows. The repo already carries a usable interpreter (the venv) but the test ignores it. There is no per-test interpreter-resolution helper anywhere in `tests/integration/`, so this failure mode will recur in any future test that also launches `python3` against the same regex/process-run pattern.

---

## Resolution priority order (strict)

The helper resolves the interpreter in this exact order, returning the first match and `error.MissingTestPythonInterpreter` if no match is found:

1. **Explicit override:** `BPM_TEST_PYTHON` environment variable, if set and non-empty. The helper reads it via the same `std.process.Environ` API already used at the top of the test file (line 39-40). This is the recommended knob for CI agents that need to pin a specific interpreter (e.g. a Linux CI container with a venv at `/opt/venv/bin/python`). The override is honored verbatim — no path resolution, no existence check (the CI caller is expected to have set it to a valid path; if it points at a non-existent file, the subprocess launch will fail with a clear Windows/Linux error, which is the right behavior — the test will fail with a clear "subprocess could not launch" message rather than silently fall through to a different interpreter).
2. **Repository `.venv` interpreter (Windows):** `.venv\Scripts\python.exe` relative to cwd, if it exists. This is the natural choice for the project's own Windows-based dev machines (the venv is created by `python -m venv .venv` early in the dev setup, and `Scripts\python.exe` is its canonical Windows interpreter path).
3. **Repository `.venv` interpreter (POSIX):** `.venv/bin/python` relative to cwd, if it exists. Same idea, POSIX path.
4. **Bare `python3` (fallback):** the literal string `"python3"`, used as a final fallback. This preserves the current Linux/macOS CI behavior (where `python3` is a real interpreter) and provides a "best effort" on Windows hosts that do not have a `.venv` (in which case the AppExecutionAlias stub will still be hit and the test will still fail — but the failure is now attributable to a missing interpreter rather than to a silent wrong-interpreter choice).

**Strict order rationale:** the override is first so CI can pin; the venv is second because it is the project's own intent on the platform that already ships with a venv; the bare fallback is last so existing Linux/macOS CI agents see no change in behavior. **The helper does not consult `where.exe` / `which`, does not consult the registry, does not consult `py -3` or any other launcher, and does not consult `PATH` directly.** Doing any of those would re-introduce the AppExecutionAlias ambiguity on Windows or produce platform-specific behavior that the test cannot assert on.

---

## Fix scope confirmation

Exactly **1 file** for the minimum viable fix; optionally **2 files** if a second test file ever needs the same logic (not currently the case; the design does not require a shared helper today, and over-abstracting is itself a maintenance hazard):

- `tests/integration/tnt_schema_isolation_test.zig` — primary: add the resolution helper at the top of the file (after the existing `testDbUrl` helper at line 30-50), and replace the literal `"python3"` argv[0] in the two `std.process.run` calls at lines 592 and 660 with the helper-resolved string.
- `tests/integration/helpers.zig` — NOT TOUCHED by this design. A shared helper can be added later, when a second consumer exists, as a follow-up; the test file is currently the only consumer, and the helper as specified is small enough (≈15 lines) that inlining it in the test file is the cleanest option.
- `tools/lint_migration_schema.py` — NOT TOUCHED. The linter itself is correct; only the invocation needs the right interpreter. Adding `--python` to the linter would be wrong: the test code is the right place to fix invocation, and the linter should remain a pure "consume a SQL file, emit a verdict" tool with no interpreter-discovery concerns.
- `build.zig` — NOT TOUCHED. The fix is at the test source level, not the build graph level.

Stays well within the ≤5 file Fix Scope Rule (1 of 5 minimum; 2 of 5 if the optional shared helper is added later).

---

## Required change (exact source delta in `tests/integration/tnt_schema_isolation_test.zig`)

### A. Add the helper, immediately after the existing `testDbUrl` helper (around line 51 of the file)

The helper signature and body (see "Resolution priority order" above for the
priority policy and "Why the ownership / lifetime model is safe" for the
allocator-lifetime rationale; both replace the doc-comment block normally
placed above a Zig function):

```zig
fn resolveTestPython(allocator: std.mem.Allocator) ![]const u8 {
    // 1. Explicit override (BPM_TEST_PYTHON env var).
    const env: std.process.Environ = .{ .block = .global };
    if (env.getAlloc(allocator, "BPM_TEST_PYTHON")) |p| {
        if (p.len > 0) return p;
        allocator.free(p);
    } else |err| switch (err) {
        error.EnvironmentVariableMissing => {},
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => unreachable,
    }
    // 2. Repo venv interpreter (Windows: Scripts\python.exe; POSIX: bin/python).
    const builtin = @import("builtin");
    const venv_rel = if (builtin.os.tag == .windows)
        ".venv\\Scripts\\python.exe"
    else
        ".venv/bin/python";
    if (std.Io.Dir.cwd().statFile(std.testing.io, venv_rel)) |_| {
        return allocator.dupe(u8, venv_rel) catch return error.OutOfMemory;
    } else |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    }
    // 3. Bare fallback.
    return allocator.dupe(u8, "python3") catch return error.OutOfMemory;
}
```

### B. Replace the two `std.process.run` callsites (lines 591-593 and 659-661)

For `TC-TNT-02-03` (around line 591-593), change:

```zig
const result = try std.process.run(alloc, std.testing.io, .{
    .argv = &.{ "python3", "tools/lint_migration_schema.py", scratch_path },
    .stdout_limit = .limited(64 * 1024),
    .stderr_limit = .limited(64 * 1024),
});
defer alloc.free(result.stdout);
defer alloc.free(result.stderr);
```

to:

```zig
const python = resolveTestPython(alloc) catch |err| switch (err) {
    error.MissingTestPythonInterpreter => {
        std.debug.print(
            "TC-TNT-02-03: no Python interpreter found. Set $BPM_TEST_PYTHON or " ++
                "create .venv at the repo root (python -m venv .venv). Tested " ++
                "paths: $BPM_TEST_PYTHON, .venv/Scripts/python.exe (Windows) / " ++
                ".venv/bin/python (POSIX), bare 'python3' on PATH.\n",
            .{},
        );
        return error.MissingTestPythonInterpreter;
    },
    else => return err,
};
defer alloc.free(python);
const result = try std.process.run(alloc, std.testing.io, .{
    .argv = &.{ python, "tools/lint_migration_schema.py", scratch_path },
    .stdout_limit = .limited(64 * 1024),
    .stderr_limit = .limited(64 * 1024),
});
defer alloc.free(result.stdout);
defer alloc.free(result.stderr);
```

The same substitution applies to `TC-TNT-02-04` (around line 659-661), with the error message prefix changed from `"TC-TNT-02-03"` to `"TC-TNT-02-04"`.

That is the entire source delta. Two callsites updated, one helper added. No new test file, no new build step, no new dependency.

---

## Why the ownership / lifetime model is safe

The helper returns a `[]const u8` that the caller must free. The three return paths have different provenance:

1. **Env-var path:** `std.process.Environ.getAlloc` returns a heap-allocated copy owned by the caller. The helper does NOT need to free it before returning; the caller frees it via `defer alloc.free(python)` after the `std.process.run` call returns. This matches the existing `testDbUrl` pattern at line 30-50 of the same file.
2. **Venv path:** the helper allocates a new slice via `allocator.dupe(u8, venv_rel)`. The caller frees it via `defer alloc.free(python)`.
3. **Bare fallback:** the helper allocates a new slice via `allocator.dupe(u8, "python3")`. The caller frees it via `defer alloc.free(python)`.

All three return paths are freed exactly once, by the same `defer` in the caller. There is no double-free risk (the env-var path is allocated in `getAlloc`, returned to the caller, and the caller's `defer` frees it — the helper does not free it because the helper does not own it). There is no use-after-free risk (the `defer alloc.free(python)` is the LAST defer to fire — the `defer alloc.free(result.stdout)` and `defer alloc.free(result.stderr)` fire first, before `python` is freed, because defers fire in LIFO order in Zig, and `python` was declared first).

The `std.process.run` argv array's lifetime is the call itself; it does not outlive the call, so the slice is consumed before the `defer` fires. No dangling pointer is observable.

---

## Why this is not a workaround

This fix is not a "bandaid" — it is the root-cause correction:

- **The root cause** is the test code's assumption that `"python3"` is a portable literal that resolves to a real interpreter on every platform the test runs on. The assumption was true on Linux/macOS (the project's CI host) and false on Windows (the project's own dev host). The assumption is also fragile: any future addition of a `python3` entry to the Windows PATH (e.g. by installing a package that ships a `python3.exe` to `WindowsApps\`) will silently change which interpreter is invoked.
- **The fix removes the assumption** by making the test code consult a deterministic priority order, with an explicit env-var override so CI can pin. After the fix, the test does not assume any particular PATH layout; it consults the env first, then the venv (which is the project's own intent on every platform that has a venv), then falls back to the bare literal. The behavior is now: same as before on Linux/macOS CI (where the bare fallback is the typical resolution), and correct on Windows dev hosts (where the venv is the typical resolution).
- **This is not a sleep / retry / sleep-mask / driver-change / global-inflation workaround** — those are the anti-patterns `docs/anti-patterns.md` and the ISS-0107 design explicitly call out and reject. This fix is a different category: it makes a non-deterministic runtime lookup deterministic by introducing a small, well-defined, environment-overridable resolver. The runtime lookup is still happening; what changes is that the lookup is now under the test's control rather than under Windows PATH's control.

---

## What this fix does NOT do (explicit non-solutions)

- **Does not disable `TC-TNT-02-03` / `TC-TNT-02-04`.** Both are valid tests; the fix is to invoke them with the correct interpreter. Disabling the tests would mask the underlying schema-isolation rule (`tools/lint_migration_schema.py` correctly identifies `public.events` as a BLOCKER violation) and would lose the regression coverage.
- **Does not hard-code the user's absolute Python path.** Env-dependent and brittle across machines; a path like `C:\Users\alice\.venv\Scripts\python.exe` would silently fail on every other dev's machine and every CI agent.
- **Does not disable the Microsoft Store AppExecutionAlias.** Out-of-repo config change; cannot rely on this for CI (CI does not have the AppExecutionAlias set up at all, and modifying the alias is a per-developer manual step that the pipeline cannot assume).
- **Does not change `tools/lint_migration_schema.py` to accept `--python`.** The test code is the right place to fix invocation. The linter should remain a pure "consume a SQL file, emit a verdict" tool, with no interpreter-discovery concerns.
- **Does not change `tools/lint_migration_schema.py`'s shebang line.** The current shebang (`#!/usr/bin/env python3`) is correct for POSIX and does not affect Windows behavior (Windows does not use shebangs). Changing it would not fix the Windows failure mode.
- **Does not add a `python3.exe` symlink/copy to the repo or to `.venv/Scripts/`.** That would be a brittle workaround that has to be re-done every time `.venv` is recreated.
- **Does not consult `where.exe` / `which` / `py -3` / Windows registry.** Any of those would re-introduce the AppExecutionAlias ambiguity or add platform-specific code paths that the test cannot deterministically assert on. The three-step priority order above is the simplest deterministic surface area.
- **Does not bundle a Python interpreter with the repo.** That would be ~50MB of unrelated dependency, a licensing and packaging concern, and out of scope for this fix.
- **Does not touch `build.zig`.** The fix is at the test source level.

---

## Verification plan

### Acceptance bar (all required to PASS)

1. `zig build` exits 0.
2. `zig build test` exits 0.
3. `zig build migrate` exits 0.
4. Error-set validation: `zig build 2>&1 | grep -i "error set"` produces zero output.
5. **Focused test target** `zig build test-integration-tnt` (or equivalent that exercises `tnt_schema_isolation_test.zig` only) exits 0. Specifically:
   - `TC-TNT-02-03` returns exit code 1 (the linter correctly flags `public.events` as a BLOCKER) and the test passes.
   - `TC-TNT-02-04` returns exit code 0 (the linter correctly accepts `public.schema_migrations` as a permitted reference) and the test passes.
   - Neither test's log contains `"Python was not found"` (the AppExecutionAlias stub's signature stderr message).
6. **Full `zig build test-integration`** exits 0.
7. **TC-TNT-02-03/04 actual output present in the full-suite log** (the assertions' success lines are visible, not just the absence of failure lines).
8. **Override knob works:** with `BPM_TEST_PYTHON=/some/path/to/python` set in the test environment, the helper selects that path (verifiable by `select-string -path <log> -pattern "/some/path/to/python"` after a focused run with `zig build test-integration-tnt`). Conversely, with the variable unset, the helper falls through to the venv or bare path. The test's behavior must be deterministic in both regimes.
9. **No MSW / no HTTP mocking:** the test still launches a real subprocess against the real linter script; no mocking layer is introduced. (The repo's `docs/anti-patterns.md` Frontend section's MSW prohibition is frontend-only but the same principle applies here for subprocess mocking.)
10. **Tracked-file git status is clean** (`git status --short` for tracked files is empty after the commit; only workflow artefacts under `handoffs/`, `docs/issue-reports/`, and `scratch/` may be untracked/modified).

### Focused regression assertions (this design's contribution to the test suite)

The two existing tests are themselves the regression assertions. After the fix:

- **`TC-TNT-02-03` is the regression test for GH-374.** Its existence proves the failure mode is detectable and will be re-detected if a future change reintroduces it (e.g. by reverting the helper, or by changing the priority order so the AppExecutionAlias wins). Its assertion (`expectEqual(@as(u8, 1), exit_code)`) is the same assertion that fails today; the fix makes it pass.
- **`TC-TNT-02-04` is the regression test for the helper's "accept" path.** Its assertion (`expectEqual(@as(u8, 0), exit_code)`) is the same assertion that fails today; the fix makes it pass.

No new test file is required. The existing tests, post-fix, are the regression suite. This is the minimum-viable regression coverage and matches the design's principle of "no over-abstracting, no over-testing".

### Abort conditions

- If any of items 1-7 fail: route back to CODE-DESIGNER for rework (rework 1 of 3).
- If the override knob (item 8) does not work as designed: the helper's env-var reading is wrong — route back to CODE-DESIGNER for rework.
- If a future Windows PATH change re-introduces the AppExecutionAlias as the first match for `python3` AND the venv does not exist: the bare fallback will still fail. This is the documented "best effort" behavior of the design (the failure is then attributable to a missing venv, which is a real config problem worth surfacing), not a bug in the helper.

---

## Data flow / control flow

```
TC-TNT-02-03 setup
  │
  ├─ scratch_path = "scratch/tnt02_linter_test_blocker.sql"
  ├─ writeFile(scratch_path, <public.events test content>)
  │
  ├─ python = resolveTestPython(alloc)               ◄── NEW HELPER
  │     │
  │     ├─ env.getAlloc("BPM_TEST_PYTHON")           ──► if set & non-empty: return that
  │     ├─ statFile(".venv/Scripts/python.exe")      ──► if exists (Windows): dup & return
  │     ├─ statFile(".venv/bin/python")              ──► if exists (POSIX):  dup & return
  │     └─ else: dup("python3") & return             ──► final fallback
  │
  ├─ defer alloc.free(python)                        ──► after std.process.run returns
  │
  ├─ std.process.run(alloc, .{
  │      .argv = &.{ python, "tools/lint_migration_schema.py", scratch_path },
  │      ...
  │  })                                               ◄── WAS: .argv = &.{ "python3", ... }
  │
  ├─ defer alloc.free(result.stdout)
  ├─ defer alloc.free(result.stderr)
  │
  ├─ expectEqual(@as(u8, 1), exit_code)              ──► TC-TNT-02-03 passes
  └─ expect(combined mentions "M001" OR "public.events" OR "BLOCKER")
```

The same flow applies to `TC-TNT-02-04` (with `scratch_path = "scratch/tnt02_linter_test_allowed.sql"`, content `INSERT INTO public.schema_migrations ...`, expected exit code 0, no mentions_violation assertion).

---

## Public interface change

**None.** The change is internal to `tests/integration/tnt_schema_isolation_test.zig`. The new helper is a private file-local function (not exported, not `pub`). The two affected tests' signatures, return types, and external behavior are unchanged — they still launch a subprocess, assert on the exit code, and assert on the output content. The only thing that changes is which interpreter is invoked, and that change is what makes the assertions pass on Windows.

---

## Error taxonomy

New error case: `error.MissingTestPythonInterpreter`. This is a distinct error from the existing `error.MissingTestDatabaseUrl` (returned by `testDbUrl`) and is the helper's failure mode if:

- `BPM_TEST_PYTHON` is unset or empty, AND
- the venv does not exist at the expected path, AND
- the bare-fallback `"python3"` resolution fails to launch (which on Windows means the AppExecutionAlias stub is hit; on POSIX it should not happen if the test environment is sane).

When this error fires, the test prints a clear remediation message to stderr (the same `std.debug.print` pattern used by `testDbUrl`'s `error.MissingTestDatabaseUrl` handler), and the test returns the error. The test fails fast with a named error rather than silently producing a meaningless exit-49 assertion failure.

Other error cases:

- `error.OutOfMemory` — propagated from the helper's `allocator.dupe` calls. Same as the existing `testDbUrl`'s error path.
- `error.FileNotFound` — handled inside the helper's stat path (silently falls through to the next priority); never observed by the caller.
- Other `statFile` errors (e.g. `error.AccessDenied`) — surfaced via the helper's `else => return stat_err` branch with a clear stderr message; not silently masked.

---

## Dependencies

**Calls into:**

- `std.process.Environ.getAlloc` (existing pattern, same API the file already uses for `BPM_TEST_DB_URL`).
- `std.Io.Dir.cwd().statFile` (Zig 0.16.0 filesystem API; same pattern as the existing `writeFile` calls in the file at line 583-588 and 651-657).
- `std.testing.allocator` (existing test allocator, lifetime managed by the test runner).
- `std.debug.print` (existing logging pattern, same as the file's existing `TC-TNT-02-03: linter stderr:` lines).

**Does not depend on / must not depend on:**

- `tools/lint_migration_schema.py` — the linter is unchanged. The fix is about how the test invokes it, not about what the linter does.
- `tests/integration/helpers.zig` — the helper is file-local. A shared helper in `helpers.zig` can be added later if a second test file needs the same logic; the design explicitly does not require that today.
- `build.zig` — not in scope.
- `vendor/pg/pg.zig` — not in scope (no DB interaction).
- `bpm` module — not in scope.

---

## State transitions

None. The helper is a pure function: same inputs (allocator, env state, cwd contents) always produce the same output. There is no internal state machine, no caching, no side effects beyond the `std.debug.print` call on the error path.

---

## Open questions

None blocking. One minor item for future maintenance:

- **If a second test file ever needs the same interpreter resolution** (e.g. a future migration test that also launches a Python helper), the helper can be promoted to `tests/integration/helpers.zig` as `pub fn resolveTestPython(allocator: std.mem.Allocator) ![]const u8`. The promoted helper's signature, error set, and priority order should be byte-identical to the inlined version. The design does not require this today, and over-abstracting is itself a maintenance hazard (a shared helper in a shared file invites future modifications that change the resolution order in ways the calling tests do not anticipate).

---

## Cross-references

- **Blocker triage:** `docs/issue-reports/WF03-gh364-20260801-step-03a-issue-fixer-blockers-INNER-REPORT.yaml` (Step 03a, ISSUE-FIXER, 2026-08-01).
- **Step 3 inner report:** `docs/issue-reports/WF03-gh364-20260801-step-03-backend-dev-INNER-REPORT.yaml` (BACKEND-DEV, 2026-08-01; FAIL — full-suite evidence cited above).
- **GitHub issue:** https://github.com/tvolodi/R-Co/issues/374 (already filed, body tagged `<!-- rco-sync-ref: WF03-gh364-20260801-PYTHON-PATH -->`; to be closed by DOC-UPDATER after this fix lands and verifies).
- **Recommended new local entry:** `ISS-0111` (will be registered by ISSUE-FIXER as the GH-374 tracker; this design does not create the local file — that is the next agent's job, per the ISSUE-FIXER Step 0.5 procedure).
- **No cross-reference to `fix-ISS-0107.md` / `fix-ISS-0106.md`** — this fix is independent of both. The barrier (`fix-ISS-0106.md`) and the widened-lock + lock_timeout scoping (`fix-ISS-0107.md`) are not affected by the interpreter resolution change. The two test targets that were affected by the prior fixes (`tests/integration/test_iss503_rls_removal.zig` for the barrier; `tests/integration/db_integration_test.zig` for the lock scoping) are different files from the file this fix touches (`tests/integration/tnt_schema_isolation_test.zig`).
- **Anti-patterns entry:** none required. The fix is novel design, not a correction of a known anti-pattern. A future entry could be added to `docs/anti-patterns.md` under a "Testing (Zig)" section if the pattern recurs: "Launching subprocesses from Zig integration tests with a bare interpreter name literal (e.g. `python3`, `node`, `bash`) without environment-overridable resolution — produces platform-specific failures (Windows AppExecutionAlias hijack, CI environment drift) that are not detectable on the original test author's host" — but the design defers this DOC-UPDATER update to its own handoff so this design's scope stays minimal.

---

*No code is implemented by this design artefact. The change is 1 file, 1 helper added, 2 callsites updated, with strict ownership/lifetime semantics and a clear error behavior when no interpreter exists.*
