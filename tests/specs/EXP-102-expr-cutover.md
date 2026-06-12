# Test Spec: EXP-102 — CEL → src/expr Cutover (Gateway Condition Evaluator)

**Requirement:** EXP-102 — Replace `vendor/cel` with `src/expr` as the gateway condition evaluator in `src/engine/transition.zig`. The differential corpus (15/15 match, 0 diverged) confirms semantic equivalence and clears the cutover gate established by ISS-602.  
**Priority:** MUST  
**Test layer:** unit (inline in transition.zig), static analysis (differential_test.zig), differential harness cross-reference  
**Design artefact:** `src/design/expr-cutover-exp102.md`  
**Run command:** `zig build test` (covers TC-EXP-102-01/02/03/04); `zig build test-differential` (covers TC-EXP-102-04/05)

---

## Test Cases

### TC-EXP-102-01: evaluateGatewayCondition returns true for a true condition
**Given:** A `std.json.ObjectMap` with `{"order_total": 1500}` and a CEL expression `"variables.order_total > 1000"`.  
**When:** `evaluateGatewayCondition(alloc, "variables.order_total > 1000", vars)` is called.  
**Then:** Returns `true`.  
**Layer:** unit (inline in `src/engine/transition.zig`)  
**Status:** Implemented — test block `"TC-EXP-102-01: evaluateGatewayCondition returns true for matching condition"` at bottom of transition.zig.  
**Acceptance criterion mapped:** Adapter translates CEL syntax to expr syntax and correctly evaluates a matching condition.

---

### TC-EXP-102-02: evaluateGatewayCondition returns false for a false condition
**Given:** A `std.json.ObjectMap` with `{"order_total": 500}` and a CEL expression `"variables.order_total > 1000"`.  
**When:** `evaluateGatewayCondition(alloc, "variables.order_total > 1000", vars)` is called.  
**Then:** Returns `false`.  
**Layer:** unit (inline in `src/engine/transition.zig`)  
**Status:** Implemented — test block `"TC-EXP-102-02: evaluateGatewayCondition returns false for non-matching condition"` at bottom of transition.zig.  
**Acceptance criterion mapped:** Adapter correctly evaluates a non-matching condition and returns false.

---

### TC-EXP-102-03: evaluateGatewayCondition returns false on parse error (no panic)
**Given:** An empty variable map and a syntactically invalid CEL expression `"variables.INVALID !!! syntax"`.  
**When:** `evaluateGatewayCondition(alloc, "variables.INVALID !!! syntax", vars)` is called.  
**Then:** Returns `false`. No panic. Preserves the `catch false` graceful-degradation semantics of the original `cel.evaluate(...) catch false` call.  
**Layer:** unit (inline in `src/engine/transition.zig`)  
**Status:** Implemented — test block `"TC-EXP-102-03: evaluateGatewayCondition returns false on syntax error (no panic)"` at bottom of transition.zig.  
**Acceptance criterion mapped:** Parse/eval errors in the adapter return false, not a Zig error or panic.

---

### TC-EXP-102-04: No `@import("cel")` on production engine path (static assertion)
**Given:** The source text of `src/engine/transition.zig` embedded at compile time via `@embedFile`.  
**When:** A compile-time substring search for `@import("cel")` is performed against the embedded source.  
**Then:** The substring is NOT found — confirming cel is retired from the production engine path.  
**Additionally:** A substring search for `@import("expr")` returns a match — confirming the cutover is complete.  
**Layer:** static analysis (no DB, no runtime)  
**Status:** Implemented — `tests/differential/differential_test.zig` test block `"TC-ISS-602-03: transition.zig imports expr post-cutover, cel is retired from engine path"` (updated from pre-cutover assertion).  
**Cross-reference:** TC-ISS-602-03 updated from "no expr import" (pre-cutover gate) to "expr present, cel absent" (post-cutover state).  
**Acceptance criterion mapped:** cel is retired from all production paths; `@import("expr")` is the only evaluator on the engine path.

---

### TC-EXP-102-05: Differential corpus still passes after wiring (cross-reference)
**Given:** The differential corpus at `tests/differential/corpus/conditions_v1.json` (15 conditions) and both `vendor/cel` and `src/expr` evaluators.  
**When:** `zig build test-differential` is run post-cutover.  
**Then:** All 15 conditions match (0 diverged). The test `"ISS-602: differential corpus — all conditions match"` passes.  
**Layer:** differential harness (corpus corpus fixture)  
**Status:** Cross-reference to TC-ISS-602-01 (pre-existing passing test). No new test file required. The differential harness serves as a permanent regression guard — it continues comparing cel vs expr on the corpus even after the production path has switched.  
**Acceptance criterion mapped:** Semantic equivalence between cel and expr confirmed for all stored gateway conditions; no regression introduced by the cutover wiring.

---

## Implementation Summary

| Test Case | File | Test Name |
|---|---|---|
| TC-EXP-102-01 | `src/engine/transition.zig` | `TC-EXP-102-01: evaluateGatewayCondition returns true for matching condition` |
| TC-EXP-102-02 | `src/engine/transition.zig` | `TC-EXP-102-02: evaluateGatewayCondition returns false for non-matching condition` |
| TC-EXP-102-03 | `src/engine/transition.zig` | `TC-EXP-102-03: evaluateGatewayCondition returns false on syntax error (no panic)` |
| TC-EXP-102-04 | `tests/differential/differential_test.zig` | `TC-ISS-602-03: transition.zig imports expr post-cutover, cel is retired from engine path` |
| TC-EXP-102-05 | `tests/differential/differential_test.zig` | `ISS-602: differential corpus — all conditions match` (cross-reference) |

## Notes on Integration Coverage

Per `src/design/expr-cutover-exp102.md §6.3`: an existing integration test in `tests/integration/` already covers `EXCLUSIVE_GATEWAY` branching via the full HTTP stack (`zig build test-integration`). No new DB-connected integration test is required for EXP-102 — the cutover is exercised through the existing gateway branching path. The differential corpus test (TC-EXP-102-05) provides the corpus-level correctness guarantee.
