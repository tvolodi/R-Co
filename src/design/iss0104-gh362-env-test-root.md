# Design: ISS-0104 / GH-362 — `env_test_root.zig` scoped test root for `test-integration-env`

**Module:** `tests/integration/env_test_root.zig` (new file) + `build.zig` change  
**Type:** E (novel build-tooling change — no existing lego template covers multi-file aggregator shims)  
**Run:** WF03-GH362-20260809 / Step 2  
**Requirement IDs:** ISS-0104

---

## Module purpose

`test-integration-env` currently compiles `tests/integration/main_test.zig` as its root,
which imports all 130+ integration test files and runs the full ~700-test suite.  The step
description says "Run Stage 14 ENV-01..ENV-05 integration tests only" — a deliberate lie.

The fix is a thin aggregator shim `tests/integration/env_test_root.zig` that imports only
the five ENV test files and re-exports the `api_tenant_context` symbol required by the
pool layer.  `build.zig` is updated to point `env_integration_tests.root_source_file` at
the new shim, and `test_integration_others_step.dependOn` is added so the env artifacts
are guaranteed to execute under the umbrella (ISS-0150 / GH-466 policy).

---

## Public interface

This module has no callable API. It is a Zig test aggregator — all surface area is test
blocks declared inside the five imported files.

Re-exported symbol (required so pool connections set `tenant_id` search-path correctly;
same pattern as `ext02_webhook_dispatch_test.zig` line 11):

```zig
pub const api_tenant_context = bpm.api_tenant_context;
```

---

## Contents of `tests/integration/env_test_root.zig`

```zig
//! ENV test root — aggregates ENV-01..ENV-05 integration test files.
//!
//! Used as root_source_file for the `test-integration-env` build step so that
//! step runs only Stage 14 ENV tests rather than the full main_test.zig suite.
//!
//! ISS-0104 / GH-362
const std = @import("std");
const bpm = @import("bpm");

// Required: pool connections apply tenant-schema search_path
// (same pattern as ext02_webhook_dispatch_test.zig)
pub const api_tenant_context = bpm.api_tenant_context;

// Stage 14 — ENV-01: tenant type field (production vs test)
const env01 = @import("env01_test.zig");
// Stage 14 — ENV-01 variant: tenant type field (dedicated narrow step)
const env01_tt = @import("env01_tenant_type_field_test.zig");
// Stage 14 — ENV-02: tenant isolation
const env02 = @import("env02_test.zig");
// Stage 14 — ENV-03: definition promotion
const env03 = @import("env03_test.zig");
// Stage 14 — ENV-05: tenant lifecycle
const env05 = @import("env05_test.zig");

comptime {
    _ = std;
    _ = env01;
    _ = env01_tt;
    _ = env02;
    _ = env03;
    _ = env05;
}
```

**Notes:**
- `env04_test.zig` does not exist in `tests/integration/` — ENV-04 has no integration
  test file.  Do not create a placeholder.
- The `comptime { _ = X; }` idiom forces Zig to include each file's test blocks even
  when the file declares no `pub` symbols itself.  This is identical to how `main_test.zig`
  aggregates its imports (lines 271–305 of main_test.zig).
- `std` is referenced in `comptime` to silence any unused-import warnings.
- `bpm` is imported at the top and used only for `api_tenant_context`.  It is NOT added
  to `comptime` because it IS referenced by the `pub const` declaration above.

---

## `build.zig` change 1 — point `env_integration_tests` at the new root

**Location:** ~line 2494 (inside the `env_integration_tests` `b.addTest` block).

**Before:**
```zig
    const env_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
```

**After:**
```zig
    const env_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            // ISS-0104 / GH-362: was main_test.zig (ran full suite); now scoped shim
            .root_source_file = b.path("tests/integration/env_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = integration_imports,
        }),
    });
```

No other changes to the `addTest` block or its `addIntegrationRun` call.

---

## `build.zig` change 2 — attach `run_env_integration_tests` to the umbrella barrier

**Location:** immediately after the last existing `test_integration_others_step.dependOn`
line (currently ~line 2520, the `run_iss0072_integration_tests` line) and before the
`zig build migrate` comment block.

**Add:**
```zig
    test_integration_others_step.dependOn(&run_env_integration_tests.step); // ISS-0104 / GH-362: ENV-01..05 scoped step must also run under umbrella
```

**Rationale:** ISS-0150 / GH-466 policy — any narrow `addTest` artifact that is scoped
away from `main_test.zig` must also be attached to `test_integration_others_step` so
`zig build test-integration` still exercises those test blocks.  The ENV files are already
imported by `main_test.zig` (via `run_integration_tests`), so this causes a second compile
run of the five ENV files under the umbrella — identical to how `run_env01_tt_integration_tests`
is handled at line 2170.

---

## Data flow diagram

```
zig build test-integration-env
  └─ clean_test_db
  └─ run_env_integration_tests
       └─ env_integration_tests (addTest)
            └─ root: tests/integration/env_test_root.zig
                 ├─ env01_test.zig         (TC-ENV-01-*)
                 ├─ env01_tenant_type_field_test.zig  (TC-ENV-01-TT-*)
                 ├─ env02_test.zig         (TC-ENV-02-*)
                 ├─ env03_test.zig         (TC-ENV-03-*)
                 └─ env05_test.zig         (TC-ENV-05-*)

zig build test-integration  (umbrella — coverage unchanged)
  └─ test_integration_others_step barrier
       ├─ run_integration_tests → main_test.zig (imports all ENV files too)
       └─ run_env_integration_tests → env_test_root.zig  ← NEW attachment
```

---

## Error taxonomy

This module introduces no runtime errors.  Possible build-time failures:

| Failure | Cause | Resolution |
|---|---|---|
| `error: file not found: env_test_root.zig` | Shim file not created before `zig build` | Ensure BACKEND-DEV creates the file |
| `error: unused variable 'std'` | Zig emits unused-import warning | `comptime { _ = std; }` handles it |
| `error: no field or member called 'api_tenant_context' in module 'bpm'` | bpm module does not export it | Check `bpm` import alias in integration_imports — this symbol exists in main_test.zig line 4 |
| `test-integration-env` still runs all 700 tests | build.zig change 1 not applied | Verify root_source_file was changed |

---

## State transitions

Not applicable — this module contains no state machine.

---

## Dependencies

| Dependency | Direction | Notes |
|---|---|---|
| `bpm` (integration_imports) | in | provides `api_tenant_context` |
| `build_options` (integration_imports) | in | used by env test files |
| `env` (integration_imports) | in | used by env test files (`portable_env`) |
| `pg` (integration_imports) | in | used by env test files |
| `env01_test.zig` | in | Stage 14 ENV-01 |
| `env01_tenant_type_field_test.zig` | in | Stage 14 ENV-01 narrow |
| `env02_test.zig` | in | Stage 14 ENV-02 |
| `env03_test.zig` | in | Stage 14 ENV-03 |
| `env05_test.zig` | in | Stage 14 ENV-05 |

Must NOT import: any non-ENV test file.  The shim exists precisely to exclude them.

---

## Open questions

None.  The fix scope is unambiguous:
- Five ENV files confirmed to exist in `tests/integration/`.
- `env04_test.zig` confirmed absent (no ENV-04 integration test).
- `integration_imports` already contains all named modules the env files need.
- No new named module imports are required in `build.zig`.

---

## Test plan

```bash
# Verify scoped step runs only ENV tests (expect ~20–40 s, not 10–15 min)
zig build test-integration-env
# Expected: Build Summary shows only ENV-01..ENV-05 test blocks; exit 0

# Verify umbrella still covers all ENV tests
zig build test-integration
# Expected: all tests pass including ENV files; exit 0

# Verify build compiles without error
zig build
# Expected: exit 0, zero "error set" lines in stderr
```

Acceptance criterion: `zig build test-integration-env` exits 0 and does NOT invoke
any test binary that covers non-ENV test cases (i.e., build time is dramatically shorter
than the full `test-integration` umbrella run).
