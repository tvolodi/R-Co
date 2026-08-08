# Test Spec: ISS-0173 / GH-501 — `src/oidc/jwks.zig` orphan re-export removal

**Status:** IMPLEMENTED
**Run ID:** WF03-GH501-20260808
**Author:** TEST-DESIGNER
**Date:** 2026-08-08

## 1. Background

`src/oidc/jwks.zig` was orphaned on three independent axes:

1. No `addTest` root reached it, so `zig build test` never compiled it.
2. It was not registered as a named module in `build.zig`, so the linter
   did not flag it.
3. Its sole re-export — `pub const oidc_jwks = @import("oidc/jwks.zig");` at
   `src/main.zig:78` — was a dead re-export with zero external callers.

`zig build` is therefore green while the file contains at least 5 hard
compile errors against Zig 0.16 (the `std.ArrayList(T).init`/`deinit`/`append`
managed API and `std.Thread.Mutex` no longer exist).

The validated design (State A — DELETE) removes both the file and the
re-export, then adds regression tests that fail the build if either returns.

## 2. Acceptance criteria

| ID | Description |
|---|---|
| AC-01 | The literal `pub const oidc_jwks = @import` MUST NOT appear in `src/main.zig` |
| AC-02 | `src/oidc/jwks.zig` MUST NOT exist on the filesystem |
| AC-03 | `src/oidc/jwks.zig` MUST NOT be tracked by `git ls-files` |
| AC-04 | The identifier `oidc_jwks` MUST NOT appear anywhere in `src/main.zig` |
| AC-05 | `zig build` exits 0 with no reference to `oidc/jwks` |
| AC-06 | Deliberate-mutation probe: re-adding the re-export line MUST cause a clear compile error (RED), reverting MUST restore GREEN |

## 3. Test cases

### TC-ISS-0173-01: re-export declaration remains removed
**Given:** `src/main.zig` after the State A deletion fix  
**When:** the file is scanned for the declaration prefix `pub const oidc_jwks = @import`  
**Then:** the declaration is absent  
**Layer:** unit  
**Acceptance criterion mapped:** AC-01

### TC-ISS-0173-02: orphan source remains deleted
**Given:** the repository working tree after the State A deletion fix  
**When:** `src/oidc/jwks.zig` is queried through the filesystem  
**Then:** the query returns `FileNotFound`  
**Layer:** unit  
**Acceptance criterion mapped:** AC-02

### TC-ISS-0173-03: orphan source remains untracked
**Given:** the repository index after the State A deletion fix  
**When:** `git ls-files -- src/oidc/jwks.zig` is executed  
**Then:** it exits successfully with empty output  
**Layer:** unit  
**Acceptance criterion mapped:** AC-03

### TC-ISS-0173-04: orphan identifier remains absent
**Given:** `src/main.zig` after the State A deletion fix  
**When:** every line is scanned for the literal identifier `oidc_jwks`  
**Then:** no line contains that identifier  
**Layer:** unit  
**Acceptance criterion mapped:** AC-04

The four specification cases map one-to-one to the four `test "TC-ISS-0173-*"`
blocks in `tests/unit/iss0173_oidc_jwks_orphan_test.zig`. AC-05 is the suite-level
build gate and AC-06 is the deliberate-mutation gate; neither adds a fifth unit-test
block.

## 4. Per-test UUID isolation

Each test constructs its own UUID via `newTestUuid()` from the source
location (`@src()`). The UUID is printed at test start for traceability
and verified by `tools/lint_test_isolation.py` (no shared state across
tests, no leaked allocations, no skipped MUST tests).

## 5. Deliberate-mutation regression

The design document (src/design/iss0173-gh501-jwks-zig016-fix.md §3)
specifies a 3-phase mutation sequence:

| Phase | Action | Expected |
|---|---|---|
| Phase 1 | (pre-fix RED proof) | All 4 unit tests fail with clear messages identifying the orphan |
| Phase 2 | (post-fix GREEN) | All 4 unit tests pass; `zig build` exits 0 |
| Phase 3 | (re-add mutation) | `zig build` exits non-zero with `unable to load 'jwks.zig': FileNotFound`; revert returns to GREEN |

Evidence captured at:
- `scratch/_iss0173_wired_red.log` (Phase 1)
- `scratch/_iss0173_postdel_oidcsrc.log` (Phase 2)
- `scratch/_iss0173_readd_red.log` (Phase 3)

## 6. Build wiring

Added a new build step in `build.zig`:

```zig
test_step: {
    .name = "test-iss0173-orphan",
    .test_target = b.addTest(...),
}
```

Reachable from `zig build test-iss0173-orphan` directly and included in the
broader `zig build test` aggregate. Confirmed by `lint_test_wiring` (267
test-bearing files, 84 addTest roots, 368 reachable).

## 7. Out of scope (filed, not fixed)

- **FOLLOWUP-ISS-0174**: linter for dead `pub const X = @import(...)` re-exports
  in `src/main.zig` — out of scope for this WF-03 run, recommended as a
  separate ISS for a follow-up workflow that adds `tools/lint_dead_reexports.py`.
