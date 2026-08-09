# Fix design: ISS-0117 / GH-380 — EXP-401 definition creation accepts invalid process graphs

## Problem

`src/definition/graph.zig` defines two graph-validation functions:

- `validateCompensationHandlers(allocator, graph) GraphError!ValidationResult`
- `validateReversibility(allocator, graph) GraphError!ValidationResult`

Both detect real structural defects in compensation/error-boundary metadata
(`COMPENSATION_HANDLER_SCOPE_UNKNOWN`, `COMPENSATION_HANDLER_NOT_REVERSED`,
`COMPENSATION_HANDLER_TARGET_UNKNOWN`, `COMPENSATION_HANDLER_NOT_REACHABLE`,
`ERROR_BOUNDARY_EVENTS_MISSING`, `ERROR_BOUNDARY_UNKNOWN_ATTACHMENT`,
`ERROR_BOUNDARY_NOT_REACHABLE`, `NON_REVERSIBLE_ACTIVITY`), but neither
function is invoked anywhere. `src/definition/store.zig` (`Store.create`,
`Store.promote`, `Store.update`) only calls:

1. `graph_mod.validateGraph`
2. `graph_mod.validateNodeAttributes`
3. `graph_mod.validateEdgeConditions`
4. `graph_mod.validateEdgeTransforms`

before persisting. Because `validateCompensationHandlers` and
`validateReversibility` are never called, graphs with unknown compensation
scopes, non-reversed compensation handlers, or compensation/error-boundary
metadata on non-reversible node types are persisted successfully instead of
being rejected with `DefinitionError.GraphValidationFailed`.

This is a "validator exists but is not wired up" defect, not a validator
logic defect — `validateCompensationHandlers` and `validateReversibility`
already return the exact violation codes the tests assert
(`TC-EXP-401-02` → `COMPENSATION_HANDLER_SCOPE_UNKNOWN`, `TC-EXP-401-03` →
`COMPENSATION_HANDLER_NOT_REVERSED`, `TC-EXP-401-04` →
`NON_REVERSIBLE_ACTIVITY`, `TC-EXP-401-05` → `ERROR_BOUNDARY_EVENTS_MISSING`).

`tests/integration/exp401_exp402_comp_restore_test.zig` is not referenced
directly in `build.zig`, but it IS reached indirectly: `tests/integration/
main_test.zig` (`build.zig`'s `integration_tests` root, run via
`run_integration_tests`, which is the first dependency of
`test_integration_others_step`) does
`@import("exp401_exp402_comp_restore_test.zig")` and pins it with
`_ = exp401_exp402_comp_restore_integration;`, per the established
ISS-0137/GH-439 pattern used for ~30 other integration test files in that
file. So this file's tests already run under `zig build test-integration`
today — no wiring gap here. (Initial investigation mistakenly concluded
otherwise by grepping `build.zig` alone without checking `main_test.zig`'s
own `@import` list; corrected before this fix landed.)

For fast, targeted iteration while fixing this specific issue, a new narrow
step `test-integration-exp401-exp402` is still added (mirroring the
`ext02_integration_tests` / `adp02_integration_tests` precedent), but this is
a convenience addition, not a defect fix — the file was already exercised by
the full `test-integration` umbrella beforehand.

## Fix

### 1. `src/definition/store.zig` — wire the two missing validators into all three graph-mutating paths

In each of the three call sites that already run the four-stage validation
pipeline (`validateGraph` → `validateNodeAttributes` → `validateEdgeConditions`
→ `validateEdgeTransforms`), insert two additional stages **before** the `[C]`
"acquire pool connection" step (i.e. still entirely pre-persistence, matching
the existing fail-fast pattern) and **after** `validateEdgeTransforms`:

- `Store.create` — after the existing `transform_result` block (currently
  ends at the line `allocator.free(transform_result.violations);` just above
  `// [C] Acquire pool connection.`).
- `Store.promote` — same relative position, inside the `if (current_status == .DRAFT)` block,
  after its `transform_result` block and before the `[SVC-03]` service-scope
  validation block.
- `Store.update` — same relative position, inside the `if (params.graph) |g|`
  block, after its `transform_result` block and before `// [B] Acquire pool connection.`.

Each new stage follows the exact same shape as the existing four (same error
mapping, same `self.last_violations` assignment, same
`allocator.free(<result>.violations)` on the empty-success path):

```zig
const comp_result = graph_mod.validateCompensationHandlers(self.allocator, <graph-expr>) catch
    return DefinitionError.TransactionFailed;
if (!comp_result.valid) {
    self.last_violations = comp_result.violations;
    return DefinitionError.GraphValidationFailed;
}
allocator.free(comp_result.violations);

const reversibility_result = graph_mod.validateReversibility(self.allocator, <graph-expr>) catch
    return DefinitionError.TransactionFailed;
if (!reversibility_result.valid) {
    self.last_violations = reversibility_result.violations;
    return DefinitionError.GraphValidationFailed;
}
allocator.free(reversibility_result.violations);
```

Where `<graph-expr>` is `params.graph` in `create`, `graph_to_validate` in
`promote`, and `g` in `update` — i.e. whichever local binding the existing
four calls in that function already use.

No other code changes. No SQL changes. No new error variants needed —
`DefinitionError.GraphValidationFailed` and `DefinitionError.TransactionFailed`
already exist and are already the return type of the enclosing functions.

### 2. `build.zig` — add a narrow integration-test step for this file (convenience, not a fix)

Add a `b.addTest` entry for
`tests/integration/exp401_exp402_comp_restore_test.zig` using the shared
`integration_imports` (it uses `bpm`, `env`, `pool`, `tenant_context` — the
same shape as the other `integration_imports`-based narrow steps such as
`ext02_integration_tests` / `adp02_integration_tests`), wrapped with
`addIntegrationRun(b, ..., migrations_dir, clean_test_db)`, exposed as a new
step `test-integration-exp401-exp402`. This file's tests already run under
the full `test-integration` umbrella via `main_test.zig`'s `@import`
(see Problem section above) — the new narrow step exists only so this one
file's 7 tests can be iterated on without paying for the ~40-binary
umbrella, following the `ext02_integration_tests` / `adp02_integration_tests`
precedent (ISS-0637/0638).

## Acceptance criteria mapping

| Acceptance criterion | How this fix satisfies it |
|---|---|
| Definition creation validates every graph before persistence | The two new validation stages run before `[C] Acquire pool connection` in `create` (and the equivalent pre-DB-write point in `promote`/`update`) — strictly before any INSERT/UPDATE. |
| Each invalid graph class returns `error.GraphValidationFailed` | Both new stages return `DefinitionError.GraphValidationFailed` on `!result.valid`, matching the existing four stages exactly. |
| Rejected definitions leave no persisted definition or related side effects | Validation happens before pool acquisition / SQL execution — same as the other four stages, which already satisfy this property. No transaction is opened for a graph that fails these checks. |
| Valid graph creation continues to pass | `validateCompensationHandlers`/`validateReversibility` only add violations for nodes carrying `compensation_handler`/`error_boundary` attributes with actual defects (unknown scope, unreached target, `reverse_order: false`, non-reversible node type). `TC-EXP-401-01`'s valid graph has none of these defects, so both new stages return `valid = true`, `violations.len == 0`, unchanged behavior. |

## Test impact

No test source changes are required. `TC-EXP-401-02` through `TC-EXP-401-05`
in `tests/integration/exp401_exp402_comp_restore_test.zig` already assert the
exact violation codes these two validators produce — once the store wires
them in, those four tests are expected to pass unmodified. `TC-EXP-401-01`
(valid graph) and the `TC-EXP-402-*` tests in the same file must continue to
pass, confirming no regression.

The missing `build.zig` step (see above) must be added so these tests are
actually exercised by the build.
