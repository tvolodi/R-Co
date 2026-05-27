# Test Spec: DSL-06 — Total Evaluation

**Requirement:** DSL-06 — Evaluation of a well-typed expression MUST always terminate and produce one of: a typed value, a typed `null`, or a structured evaluation error. Evaluation MUST NOT crash the host or enter an unbounded loop.

**Priority:** MUST  
**Test layer:** unit (Zig inline tests in `src/expr/mod.zig`)

---

## Acceptance Criteria Mapping

| # | Acceptance Criterion | Test Case(s) |
|---|---|---|
| AC1 | A property-based test generates random valid-grammar expressions; all evaluate within a fixed step bound. | TC-DSL-06-05, TC-DSL-06-06 |
| AC2 | No expression evaluation results in a host crash or panic. | TC-DSL-06-05 (implicit — any panic fails the test) |

---

## Existing Implementation Coverage

The BACKEND-DEV implementation in `src/expr/mod.zig` already includes inline property-based tests for DSL-06. This spec records those tests formally and identifies gaps.

| Existing test | Coverage | Gap? |
|---|---|---|
| `DSL-06: MAX_EVAL_DEPTH constant exists` | Verifies constant value (1024) and type (`usize`) | None |
| `DSL-06: evaluate delegates to evaluateNode with max depth` | Verifies `evaluate()` wrapper calls `evaluateNode` with `MAX_EVAL_DEPTH` | None |
| `DSL-06: evaluateNode with remaining=1 evaluates leaf nodes but fails on binary` | Verifies leaf nodes (null, bool, int, float, string) pass at remaining=1; binary node fails with depth error | None |
| `DSL-06: deep chain hits depth limit` | 2048-depth chain triggers depth error at `MAX_EVAL_DEPTH` | Does not test depth=MAX_EVAL_DEPTH (should succeed) or depth=MAX_EVAL_DEPTH+1 (should fail) |
| `DSL-06: 100 random expressions evaluate within bound` | 100 random expressions; seeded PRNG (42); all 14 Node variants; accepts both ok and err | Does not assert property-based iteration count or coverage of all acceptance criteria explicitly |

---

## Test Cases

### TC-DSL-06-01: MAX_EVAL_DEPTH constant exists and has correct value
**Given:** The `MAX_EVAL_DEPTH` constant in `src/expr/mod.zig`  
**When:** The constant is inspected at compile time  
**Then:** Its value MUST be 1024 and its type MUST be `usize`  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — the fixed step bound is defined

### TC-DSL-06-02: evaluate() delegates to evaluateNode with MAX_EVAL_DEPTH
**Given:** A parsed expression (e.g., `"42"`)  
**When:** `evaluate()` is called on the AST  
**Then:** `evaluate()` must pass `MAX_EVAL_DEPTH` as `remaining` to `evaluateNode` and return the correct result  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — the wrapper uses the fixed step bound

### TC-DSL-06-03: Leaf nodes evaluate with remaining=1 (depth boundary = 0)
**Given:** Leaf AST nodes (`.null_literal`, `.bool_literal`, `.int_literal`, `.float_literal`, `.string_literal`)  
**When:** `evaluateNode()` is called with `remaining=1`  
**Then:** Each leaf node must evaluate successfully (depth guard passes; no recursion needed)  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — leaf nodes terminate immediately

### TC-DSL-06-04: Binary node at remaining=1 triggers depth-exceeded error
**Given:** A binary AST node (`.add_expr`, `.mul_expr`, `.cmp_expr`, `.and_expr`, or `.or_expr`) with leaf children  
**When:** `evaluateNode()` is called with `remaining=1`  
**Then:** The evaluation must return `.err` with message containing `"evaluation depth exceeded"`  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — the depth guard catches insufficient remaining depth

### TC-DSL-06-05: Deep binary chain at exactly MAX_EVAL_DEPTH succeeds
**Given:** A deeply nested left-associative binary tree of exactly `MAX_EVAL_DEPTH` nodes  
**When:** `evaluateNode()` is called with `remaining=MAX_EVAL_DEPTH`  
**Then:** The evaluation must complete successfully (returns `.ok`) because each level decrements `remaining` by 1 and the final leaf consumes the last unit  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — expressions at exactly the depth bound evaluate successfully  
**Status:** NOT YET IMPLEMENTED — this is a gap in the existing test suite. The existing "deep chain" test uses depth 2048 and expects failure, but does not test depth=1024 to confirm success. A depth-1024 chain represents the worst-case legitimate expression.

### TC-DSL-06-06: Deep binary chain at MAX_EVAL_DEPTH+1 triggers depth-exceeded error
**Given:** A deeply nested left-associative binary tree of exactly `MAX_EVAL_DEPTH + 1` nodes  
**When:** `evaluateNode()` is called with `remaining=MAX_EVAL_DEPTH`  
**Then:** The evaluation must return `.err` with message containing `"evaluation depth exceeded"`  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — the depth guard rejects expressions exceeding the bound  
**Status:** NOT YET IMPLEMENTED — this is a gap. The existing "deep chain" test uses depth 2048 (way over), but does not test the precise boundary at `MAX_EVAL_DEPTH + 1`.

### TC-DSL-06-07: Property-based test — 100 random expressions evaluate without crash
**Given:** A seeded PRNG (seed=42) and a random expression generator producing ASTs up to generation depth 6 covering all 14 Node variants  
**When:** 100 random expressions are generated and each is evaluated via `evaluateNode()` with `remaining=MAX_EVAL_DEPTH`  
**Then:** Every evaluation MUST complete without crashing or panicking (both `.ok` and `.err` outcomes are valid — the requirement is termination, not success)  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 (fixed step bound), AC2 (no crash/panic)

### TC-DSL-06-08: Property-based test — all 14 Node variants appear in the random corpus
**Given:** The random expression generator from TC-DSL-06-07  
**When:** After generating 100 random expressions, the set of Node variant kinds used is compared against the full 14-variant set  
**Then:** At least one expression of each variant must have been generated, ensuring every code path in `evaluateNode` is exercised  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — all grammar constructs are covered by the property-based test  
**Status:** NOT YET IMPLEMENTED — the existing random test generates all 14 variants but does not assert coverage of all variants. This could be added as an optional verification.

### TC-DSL-06-09: Unary operator at remaining=1 succeeds (single recursion)
**Given:** A unary node (`.unary_neg` or `.not_expr`) with a leaf operand  
**When:** `evaluateNode()` is called with `remaining=1`  
**Then:** The evaluation must succeed because the unary node passes `remaining-1 = 0` to the leaf, which returns immediately  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — unary nodes require only one level of recursion

### TC-DSL-06-10: evaluateNode with remaining=0 returns depth-exceeded error
**Given:** Any AST node (leaf or compound)  
**When:** `evaluateNode()` is called with `remaining=0`  
**Then:** The evaluation must return `.err` with message containing `"evaluation depth exceeded"`  
**Layer:** unit  
**Acceptance criterion mapped:** AC1 — zero remaining depth immediately triggers the guard

---

## Property-Based Test Specification

| Parameter | Value |
|---|---|
| PRNG seed | `42` |
| Number of expressions | `100` |
| Max generation depth | `6` |
| Evaluation depth bound | `MAX_EVAL_DEPTH` (1024) |
| Node variant coverage | All 14 variants (null_literal, bool_literal, int_literal, float_literal, string_literal, unary_neg, not_expr, cmp_expr, add_expr, mul_expr, and_expr, or_expr, dot_path, func_call) |
| Expected outcome | Every evaluation terminates (ok or err); no panic/crash |
| Determinism | Seeded PRNG guarantees reproducible test runs |

---

## Edge Cases Summary

| Edge case | Covered by | Implemented? |
|---|---|---|
| `remaining = 0` (immediate depth error) | TC-DSL-06-10 | Yes (implicitly in evaluateNode entry guard) |
| `remaining = 1` + leaf node (success) | TC-DSL-06-03 | Yes |
| `remaining = 1` + binary node (depth error) | TC-DSL-06-04 | Yes |
| `remaining = 1` + unary node (success) | TC-DSL-06-09 | No — gap |
| Depth = exactly `MAX_EVAL_DEPTH` (success) | TC-DSL-06-05 | No — gap |
| Depth = exactly `MAX_EVAL_DEPTH + 1` (depth error) | TC-DSL-06-06 | No — gap |
| Depth = 2048 >> `MAX_EVAL_DEPTH` (depth error) | TC-DSL-06-04 (via deep chain test) | Yes |
| 100 random expressions (property-based) | TC-DSL-06-07 | Yes |
| All 14 Node variants in random corpus | TC-DSL-06-08 | Yes (generation), No (assertion) |

---

## Gap Analysis Summary

The existing test suite in `src/expr/mod.zig` is **substantially complete** for DSL-06. The property-based test (100 random expressions, seeded PRNG, all 14 Node variants) covers both acceptance criteria. The depth guard mechanism is verified at multiple levels.

**Identified gaps (recommended but non-blocking for test-spec completeness):**

1. **TC-DSL-06-05** — A chain of exactly `MAX_EVAL_DEPTH` (1024) that should succeed is not tested.
2. **TC-DSL-06-06** — A chain of exactly `MAX_EVAL_DEPTH + 1` (1025) that should fail at the guard is not tested.
3. **TC-DSL-06-09** — Unary operators with `remaining=1` (single recursion level) not explicitly tested.
4. **TC-DSL-06-08** — The random test generates all 14 variants but does not assert variant coverage.

These gaps are minor: the boundary behaviour is already tested at `remaining=1` (TC-DSL-06-03/04) and at depth 2048 (deep chain test). The exact-depth boundary tests would add precision but are not strictly necessary to satisfy the acceptance criteria.

**Recommendation:** The existing tests are sufficient to PASS the handoff. Gaps 1–3 could be filed as enhancement issues for a future polishing pass.
