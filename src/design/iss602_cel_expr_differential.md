# Module: ISS-602 — CEL-to-expr Differential Test Corpus (Cutover Gate)

**Stage:** Epic 6 — Performance and cutover quality
**Requirement:** ISS-602
**Priority:** P1 · **Estimate:** L
**Labels:** engine, expr, risk
**Depends on:** ISS-201 (TransitionResult with emitted_events)
**Files to produce:** `src/engine/differential_harness.zig`, `tests/differential/corpus/` (JSON fixtures), `tests/differential/differential_test.zig`

---

## 1. Purpose

Stored process definitions contain gateway conditions written in CEL (Common Expression Language). These conditions are currently evaluated by `vendor/cel/cel.zig`. The platform has a nascent expression DSL in `src/expr/` (`lexer.zig`, `parser.zig`, `evaluator.zig`) intended to replace the vendor CEL interpreter. Before any production cutover, every real gateway condition must be proven to evaluate identically on both evaluators.

This module provides:
- A **differential test harness** that loads gateway conditions from real stored process definitions.
- Runs each condition through **both** `vendor/cel/cel.evaluate()` and `src/expr/evaluator.evaluate()`.
- Asserts **identical boolean results**.
- **Catalogues every divergence** with full context: condition text, CEL result, expr result, and the semantic difference.
- Acts as a **hard cutover gate**: no production code imports `src/expr/` on the engine transition path until the differential corpus is 100% green.

ISS-201 is the prerequisite: `transition()` returns `TransitionResult` with `emitted_events`, providing the event-driven architecture that the differential harness uses to verify end-to-end condition evaluation correctness.

---

## 2. Module Layout

```
src/engine/
└── differential_harness.zig         — NEW: harness runner, corpus loader, result cataloguer

tests/differential/
├── corpus/                          — NEW: checked-in JSON fixtures of real gateway conditions
│   └── conditions_v1.json           — initial corpus extracted from stored definitions
└── differential_test.zig            — NEW: integration test that runs the harness

vendor/cel/
└── cel.zig                          — EXISTING: CEL evaluator (public API: cel.evaluate)

src/expr/
├── mod.zig                          — EXISTING: expr.parse(), expr.evaluate()
├── lexer.zig                        — EXISTING
├── parser.zig                       — EXISTING
├── ast.zig                          — EXISTING
└── evaluator.zig                    — EXISTING: evaluate(parsed_expr, ctx, allocator)
```

No production code is modified. `src/engine/differential_harness.zig` is a test-time-only module (compiled only for `zig build test` and `zig build test-differential`, never linked into the server binary).

---

## 3. Data Model

### 3.1 Corpus Entry

Each condition in the corpus is a JSON object:

```json
{
  "condition_id": "gw-001",
  "source_definition_id": "a1b2c3d4-...",
  "source_definition_version": 1,
  "source_gateway_node_id": "gateway_approval_check",
  "condition_text": "variables.order_total > 1000",
  "context": {
    "order_total": 1500,
    "customer_status": "VIP",
    "amount": 250
  },
  "expected_result": true
}
```

| Field | Type | Purpose |
|---|---|---|
| `condition_id` | string | Unique identifier within the corpus. Stable across corpus versions. |
| `source_definition_id` | UUID string | The process definition this condition was extracted from. |
| `source_definition_version` | integer | Definition version at extraction time. |
| `source_gateway_node_id` | string | The gateway node in the definition graph this condition belongs to. |
| `condition_text` | string | The raw CEL expression text as stored in the definition. |
| `context` | object | A representative variable map for evaluation. Must contain all variables referenced by the condition. |
| `expected_result` | boolean | The expected boolean outcome. Initially derived from the CEL evaluator (baseline). When both evaluators agree, this field equals both results. |

### 3.2 Differential Result

The harness produces a structured result per condition:

```json
{
  "condition_id": "gw-001",
  "condition_text": "variables.order_total > 1000",
  "cel_result": true,
  "expr_result": true,
  "match": true,
  "cel_error": null,
  "expr_error": null,
  "diff_detail": null
}
```

| Field | Type | Purpose |
|---|---|---|
| `condition_id` | string | Matches the corpus entry. |
| `condition_text` | string | The evaluated expression (from the corpus entry). |
| `cel_result` | boolean or null | CEL evaluator result. Null if CEL errored. |
| `expr_result` | boolean or null | expr evaluator result. Null if expr errored. |
| `match` | boolean | True if both returned the same boolean value with no errors. |
| `cel_error` | string or null | CEL error message if evaluation failed (ParseError or EvalError). |
| `expr_error` | string or null | expr error message if evaluation failed (ParseFailed or EvalFailed). |
| `diff_detail` | string or null | Human-readable description of the divergence when `match` is false. |

### 3.3 Corpus Report

The harness produces an aggregate report:

```json
{
  "corpus_version": "v1",
  "timestamp": "2026-06-12T14:00:00Z",
  "total_conditions": 45,
  "matched": 43,
  "diverged": 2,
  "cel_only_errors": 0,
  "expr_only_errors": 1,
  "both_errors": 0,
  "overall_pass": false,
  "divergences": [
    {
      "condition_id": "gw-017",
      "condition_text": "variables.amount >= 0 and variables.status == 'active'",
      "cel_result": true,
      "expr_result": false,
      "diff_detail": "expr returns false: '>= 0' comparison on string-typed variable 'amount' evaluates to null; CEL coerces string to numeric. Semantics: type coercion difference — CEL is lenient, expr is strict."
    }
  ]
}
```

---

## 4. Public Interface

### 4.1 differential_harness.zig

```zig
pub const HarnessError = error{
    /// Failed to read or parse the corpus JSON file.
    CorpusLoadFailed,
    /// One or more differential test cases returned divergent results.
    DivergenceDetected,
    /// Allocator exhausted.
    OutOfMemory,
};

pub const CorpusEntry = struct {
    condition_id: []const u8,
    source_definition_id: []const u8,
    source_definition_version: u32,
    source_gateway_node_id: []const u8,
    condition_text: []const u8,
    context: std.json.ObjectMap,
    expected_result: bool,
};

pub const DiffResult = struct {
    condition_id: []const u8,
    condition_text: []const u8,
    cel_result: ?bool,
    expr_result: ?bool,
    match: bool,
    cel_error: ?[]const u8,
    expr_error: ?[]const u8,
    diff_detail: ?[]const u8,
};

pub const CorpusReport = struct {
    corpus_version: []const u8,
    timestamp: []const u8,
    total_conditions: u32,
    matched: u32,
    diverged: u32,
    cel_only_errors: u32,
    expr_only_errors: u32,
    both_errors: u32,
    overall_pass: bool,
    divergences: []DiffResult,
};

/// Load a corpus from a JSON file path.
///
/// The JSON file must be an array of CorpusEntry objects.
/// Returns a caller-owned slice of entries allocated with `allocator`.
pub fn loadCorpus(
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
) HarnessError![]CorpusEntry;

/// Evaluate a single condition against both CEL and expr evaluators.
///
/// Steps:
///   1. Parse condition_text with both CEL (vendor/cel) and expr (src/expr/).
///   2. Evaluate with the provided context.
///   3. Compare boolean results.
///   4. Return DiffResult with match/diff_detail populated.
///
/// allocator is used for temporary allocations; all result strings are
/// allocated with allocator and must be freed by the caller.
pub fn evaluateDifferential(
    allocator: std.mem.Allocator,
    entry: *const CorpusEntry,
) HarnessError!DiffResult;

/// Run the full differential corpus.
///
/// Steps:
///   1. Load corpus JSON file.
///   2. For each entry, call evaluateDifferential.
///   3. Aggregate results into CorpusReport.
///   4. Write report JSON to report_path.
///
/// Returns HarnessError.DivergenceDetected if any condition diverges.
/// The report is still written on divergence — callers can inspect it.
pub fn runCorpus(
    allocator: std.mem.Allocator,
    corpus_path: []const u8,
    report_path: []const u8,
) HarnessError!CorpusReport;
```

### 4.2 Translation layer (private to differential_harness.zig)

CEL uses `variables.field_name` syntax to reference the variable map, while `src/expr/` uses bare identifiers resolved against a `Context`. The harness must bridge these two syntaxes:

```zig
/// Translate a CEL condition text to expr-compatible syntax.
///
/// CEL syntax:  variables.order_total > 1000
/// expr syntax: order_total > 1000
///
/// Translation rules:
///   - Strip "variables." prefix from identifiers.
///   - `true` / `false` → literal keywords (identical in both).
///   - `&&` / `||` / `!` → `and` / `or` / `not` (CEL uses C-style, expr uses word operators).
///   - Numeric literals, string literals → pass through unchanged.
///   - Comparison operators `==`, `!=`, `<`, `>`, `<=`, `>=` → identical in both.
///
/// Returns the translated expression text allocated with `allocator`.
/// Returns null if the expression cannot be mechanically translated
/// (e.g. uses CEL-specific features like macros, comprehensions, or
///  functions not in the expr builtin whitelist). A non-translatable
/// expression is recorded as a divergence with diff_detail explaining
/// the unsupported feature.
fn translateCelToExpr(
    allocator: std.mem.Allocator,
    cel_expression: []const u8,
) ?[]const u8;
```

**Translation scope and limitations:**

The mechanical translator handles the intersection of CEL and expr grammars. Both share:
- Boolean literals (`true`, `false`)
- Numeric literals (integers, floats)
- String literals (`"..."`)
- Comparison operators (`==`, `!=`, `<`, `>`, `<=`, `>=`)
- Parenthesised expressions
- Logical operators (CEL: `&&`/`||`/`!`, expr: `and`/`or`/`not`)
- Variable references (CEL: `variables.ident`, expr: bare `ident`)

CEL features **not** supported by the translator (record as divergence with explanation):
- CEL macros (`has()`, `all()`, `exists()`, etc.)
- List/array literals or comprehensions
- Map literals
- CEL standard functions not in the expr whitelist (e.g. `size()`, `matches()`, `int()`, `string()`)
- Conditional (ternary) expressions

The translator produces a `diff_detail` like `"CEL feature not in expr: function 'matches' is not in the whitelist"` for unsupported constructs. These are legitimate divergences that must be resolved by either extending expr or defining a translation policy.

---

## 5. Algorithm: Differential Evaluation

### 5.1 Per-Condition Flow

```
evaluateDifferential(entry):
  # Step 1: Evaluate with CEL
  cel_ctx = convertContextToCelFormat(entry.context)
  cel_bool, cel_err = cel.evaluate(allocator, entry.condition_text, cel_ctx)

  # Step 2: Translate CEL → expr syntax
  expr_text = translateCelToExpr(allocator, entry.condition_text)
  if expr_text == null:
    return DiffResult{
      match = false,
      cel_result = cel_bool,
      expr_result = null,
      diff_detail = "CEL expression uses unsupported feature outside expr grammar intersection"
    }

  # Step 3: Parse with expr
  parse_result = expr.parse(allocator, expr_text)
  if parse_result is fail:
    return DiffResult{
      match = false,
      cel_result = cel_bool,
      expr_result = null,
      expr_error = "Parse failed: ...",
      diff_detail = "expr parser rejected translated expression"
    }

  # Step 4: Evaluate with expr
  expr_ctx = convertContextToExprFormat(entry.context)
  eval_result = expr.evaluate(ast, expr_ctx, allocator)
  if eval_result is err:
    return DiffResult{
      match = false,
      cel_result = cel_bool,
      expr_result = null,
      expr_error = "Evaluation failed: ...",
      diff_detail = "expr evaluator returned error"
    }

  # Step 5: Compare boolean results
  expr_bool = (eval_result.ok == .bool_val and eval_result.ok.bool_val == true)
  match = (cel_bool == expr_bool)

  if !match:
    return DiffResult{
      match = false,
      cel_result = cel_bool,
      expr_result = expr_bool,
      diff_detail = describeDivergence(cel_bool, expr_bool, entry.condition_text)
    }

  return DiffResult{ match = true, cel_result = cel_bool, expr_result = expr_bool }
```

### 5.2 Context Conversion

CEL expects `std.json.ObjectMap` where values are `std.json.Value`.

expr expects `Context` (from `src/expr/ast.zig`) where values are the `Value` tagged union:

```
expr Context → std.StringHashMap(expr Value)
expr Value   → union { null_val, bool_val, int_val, float_val, str_val, ts_val }
```

The harness converts `std.json.Value` entries to `expr.Value`:
- `json.Integer` → `expr.Value.int_val`
- `json.Float` → `expr.Value.float_val`
- `json.String` → `expr.Value.str_val`
- `json.Bool` → `expr.Value.bool_val`
- `json.Null` → `expr.Value.null_val`
- Objects and arrays → serialise to JSON string, store as `expr.Value.str_val` (for nested dot-path traversal in DSL-11).

### 5.3 Divergence Cataloguing

When results diverge, `describeDivergence` produces a human-readable explanation:

```
Pattern: "CEL returns <X>, expr returns <Y>. Difference: <reason>."

Example reasons:
- "Type coercion: CEL coerces string '100' to numeric for comparison; expr requires explicit types."
- "Null handling: CEL treats null as false in boolean context; expr uses three-valued logic with null propagation."
- "Operator semantics: CEL '||' short-circuits returning first truthy value, expr returns canonical boolean."
- "Variable resolution: condition references 'variables.x.y' (nested); expr flat-context lookup requires dot-path."
```

### 5.4 Report Generation

`runCorpus` produces a JSON report at `tests/differential/report-<timestamp>.json` with the schema defined in Section 3.2. The report is committed alongside the corpus for audit trail.

---

## 6. Error Taxonomy

### HarnessError

| Error | Condition | Meaning |
|---|---|---|
| `CorpusLoadFailed` | JSON file not found, malformed, or empty. | Fix the corpus file path or contents. |
| `DivergenceDetected` | One or more conditions produced different CEL vs expr results. | Cutover gate is blocked. Review divergences in the report. |
| `OutOfMemory` | Allocator exhausted. | Increase available memory or split corpus. |

The harness treats individual evaluation errors (CEL parse error, expr parse error, expr eval error) as divergence cases, not as harness failures. Each such case is recorded in the report with `match = false` and the appropriate error field populated.

---

## 7. Cutover Gate

The hard gate rule:

> **No production module shall import `src/expr/` on the engine transition path until the differential corpus is 100% green (all conditions match).**

Enforcement:
- `src/engine/transition.zig` currently imports `vendor/cel/cel.zig` for gateway condition evaluation via `cel.evaluate()`.
- `src/engine/transition.zig` must **not** import `src/expr/mod.zig` or any `src/expr/` submodule.
- The cutover PR that adds `const expr = @import("../expr/mod.zig")` to `transition.zig` must reference the passing corpus report (all conditions match, `overall_pass = true`).
- The cutover PR must also reference the version of the corpus used to validate the cutover (corpus version and timestamp).
- CODE-DESIGN-VALIDATOR checks this during the cutover PR review — if `overall_pass = false` in the latest report, the PR is blocked.

**What "engine path" means:**
- `src/engine/transition.zig` — must not import expr.
- `src/engine/instance.zig` — may import expr for non-transition purposes (e.g. variable transformer expressions in EXT-04) only if the corpus is green for those expression types.
- `src/engine/cel.zig` — the CEL wrapper module; must not import expr.
- Test files, benchmark files, and the differential harness itself are exempt — they are not "production code."

---

## 8. Corpus Management

### 8.1 Initial Corpus Extraction

The initial corpus is extracted from stored process definitions by querying the database:

```sql
SELECT
    pd.id AS source_definition_id,
    pd.version AS source_definition_version,
    -- Parse the definition graph JSON to extract gateway conditions
    -- Each EXCLUSIVE_GATEWAY node has outgoing edges with condition fields
    pd.definition_graph
FROM process_definitions pd
WHERE pd.status = 'ACTIVE'
  AND pd.definition_graph IS NOT NULL;
```

Each EXCLUSIVE_GATEWAY node in the definition graph has outgoing edges. Each edge with a non-null, non-empty `condition` field becomes a corpus entry. The context for each condition is extracted from the definition's node attributes (form schemas, default variable values) or from representative test data.

The extraction is a one-time manual/scripted process. The resulting `conditions_v1.json` is checked into `tests/differential/corpus/` and version-controlled.

### 8.2 Corpus Versioning

- `conditions_v1.json` — initial extraction from existing definitions.
- New versions (`conditions_v2.json`, etc.) are added when:
  - New gateway conditions are introduced by new definitions.
  - A divergence is resolved and the corpus is re-baselined.
  - A condition is found to have been incorrect in the original extraction (data error).
- Old versions are retained for historical comparison.

### 8.3 Corpus Maintenance

The corpus is a living artefact:
- When a new process definition is created or updated by BACKEND-DEV, relevant gateway conditions should be added to the corpus.
- DOC-UPDATER adds corpus update to the release checklist.
- TEST-DESIGNER includes corpus update verification in test design.

---

## 9. Dependencies

| Dependency | Direction | Why |
|---|---|---|
| `vendor/cel/cel.zig` | harness → vendor | `cel.evaluate()` — the current production evaluator. |
| `src/expr/mod.zig` | harness → expr | `expr.parse()` and `expr.evaluate()` — the candidate replacement. |
| `src/expr/evaluator.zig` | harness → expr | `ParsedExpr`, `Context`, `Value` types; `evaluate()` function. |
| `src/db/pool.zig` | harness → pool | Optional: for live corpus extraction from stored definitions (separate script). |
| `std.json` | harness → stdlib | JSON parsing for corpus files and report generation. |

**Must NOT depend on:**
- `src/engine/transition.zig` — the harness tests expression evaluation, not state transitions.
- `src/api/` — no HTTP handlers involved.
- `src/tasks/` — no task logic involved.

---

## 10. Integration Points

### 10.1 Build System

```bash
zig build test-differential   # NEW: compile and run the differential harness
```

The `test-differential` step:
1. Compiles `tests/differential/differential_test.zig` which imports `src/engine/differential_harness.zig`.
2. Runs the harness against `tests/differential/corpus/conditions_v1.json`.
3. Writes report to `tests/differential/report-<timestamp>.json`.
4. Exits 0 if all conditions match; exits 1 if any divergence detected.

### 10.2 CI/CD Integration

- `zig build test-differential` runs in CI on every PR.
- A divergence failure blocks the PR (exit code 1).
- The CI step uploads the report JSON as an artefact for inspection.

### 10.3 Pre-Cutover Checklist

Before any PR that adds `const expr = @import("../expr/mod.zig")` to `transition.zig`:
1. Run `zig build test-differential` — must exit 0.
2. Verify report JSON shows `overall_pass: true`.
3. Verify all divergence entries are empty.
4. Record corpus version and report timestamp in the PR description.
5. CODE-DESIGN-VALIDATOR verifies the report and signs off.

---

## 11. Example Walkthrough

### Condition from a stored definition

Gateway node `approval_check` in definition `shipment-process` has two outgoing edges:

- Edge 1: `condition = "variables.order_total > 1000"` (goes to "manager_approval")
- Edge 2: default (no condition, goes to "auto_approved")

**Corpus entry:**

```json
{
  "condition_id": "shipment-approval-check-edge1",
  "source_definition_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "source_definition_version": 1,
  "source_gateway_node_id": "approval_check",
  "condition_text": "variables.order_total > 1000",
  "context": {
    "order_total": 1500
  },
  "expected_result": true
}
```

**Harness execution:**

1. CEL: `cel.evaluate(allocator, "variables.order_total > 1000", {"order_total": 1500})` → `true`.
2. Translate: `translateCelToExpr` converts `"variables.order_total > 1000"` → `"order_total > 1000"`.
3. expr parse: `expr.parse(allocator, "order_total > 1000")` → AST (cmp_expr with dot_path ["order_total"] and int_literal 1000).
4. expr evaluate: `evaluate(ast, {"order_total": 1500})` → `Value.bool_val(true)`.
5. Compare: both `true` → `match = true`.

### Divergence example

Condition: `"variables.amount >= 0"` where `amount` is `"100"` (string).

1. CEL: coerces `"100"` to numeric → `100 >= 0` → `true`.
2. expr: `typeOf("100")` is `string`, `typeOf(0)` is `int64` → type mismatch → `null`.
3. Boolean coercion of `null` (three-valued logic) → `null` is not `true` → `false` in condition context.
4. Result: CEL `true`, expr `false` → **DIVERGENCE**.

**diff_detail:** `"Type coercion: CEL coerces string '100' to numeric for >= comparison; expr requires same-type operands and returns null on type mismatch, which evaluates to false in gateway context."`

This is a real divergence that must be resolved before cutover — either by:
- Making variable schemas enforce numeric types (so `amount` is always stored as a number).
- Extending expr to support numeric string coercion (policy decision).

---

## 12. Key Invariants

1. **The harness is read-only.** It evaluates expressions, compares results, and writes reports. It never modifies definitions, events, or instance state.

2. **The harness is deterministic.** Running the same corpus version with the same evaluator code always produces the same report.

3. **Every divergence is catalogued.** There is no silent mismatch — any difference in CEL vs expr result produces a `DiffResult` with `match = false` and `diff_detail` populated.

4. **Corpus is version-controlled.** All corpus JSON files are checked into `tests/differential/corpus/` and tracked in git alongside the code they validate.

5. **The cutover gate is enforced by process, not by code.** There is no runtime check that blocks expr import on the engine path — the gate is enforced by pull request review policy and CI checks.

6. **CEL remains the production evaluator until cutover.** No code path in `src/engine/transition.zig` evaluates expr during production request handling.

7. **The mechanical translator handles the intersection of the two grammars.** CEL expressions using features outside the intersection are recorded as divergences, not as harness failures.

---

## 13. Test Strategy

### Unit tests (no DB, no definitions)

- `translateCelToExpr` with valid CEL expressions — assert correct expr output.
- `translateCelToExpr` with CEL expressions using unsupported features — assert null return.
- `evaluateDifferential` with mock context and known-matching condition — assert match.
- `evaluateDifferential` with intentionally divergent condition — assert divergence recorded.
- Context conversion: `std.json.Value` → `expr.Value` for all six expr types.
- Report serialisation round-trip: create `CorpusReport`, serialise to JSON, parse back, assert equality.

### Integration tests (real definitions)

- Extract conditions from actual stored definitions in the test database.
- Run full differential corpus against the current test database.
- Assert no unexpected errors (CEL errors or expr parse errors suggest corrupt conditions).
- Verify report JSON is written and well-formed.

### Load test

- Run corpus with 100 conditions — measure total harness time.
- Ensure harness completes in < 5s (all conditions evaluated twice).
- Publish as part of the benchmark suite.

### CI test

- `zig build test-differential` must pass (all conditions match) on `main` and all PRs.
- A new PR that introduces a divergence must either:
  - Resolve the divergence (fix the evaluator or update the condition), or
  - Update the corpus to document the known divergence (with an associated issue for resolution).

---

## 14. Open Questions

1. **Corpus initial size.** How many distinct gateway conditions exist in current stored definitions? The initial corpus size determines whether the harness is a quick CI check or a longer-running test. A corpus with dozens of conditions is fast; hundreds may need batching.

2. **Variable type fidelity.** The CEL evaluator receives `std.json.Value` which does not distinguish `integer` (42) from `float` (42.0) — both are `json.Integer` vs `json.Float`. The expr evaluator distinguishes `int_val` (i64) from `float_val` (f64). The context conversion must decide: should `json.Integer` map to `int_val` or `float_val`? Recommendation: map `json.Integer` to `int_val` (CEL stores all numbers as `f64` internally, so comparison precision may still differ for very large integers).

3. **Translation of null coalescence.** CEL supports `variables.x || variables.y` as a null-coalescing pattern (returns the first truthy value). expr uses `coalesce(x, y)` built-in function. The mechanical translator must detect this pattern and produce the correct expr equivalent. This is a complex translation and may need manual annotation in the corpus for edge cases.

4. **Corpus extraction automation.** Should the corpus be automatically extracted from stored definitions at CI time, or manually curated? Recommendation: initial extraction is manual (curated for correctness), with automated extraction as a secondary validation step (to catch definitions not yet represented in the corpus).

5. **Green corpus for expr functions.** The expr evaluator supports 11 built-in functions (`length`, `lower`, `upper`, `trim`, `contains`, `startsWith`, `endsWith`, `coalesce`, `now`, `date_add`, `date_diff`). CEL has no direct equivalents for most of these. Conditions using these functions can only be in the corpus after the cutover (when switching from CEL to expr). The initial corpus is limited to the grammar intersection (boolean logic, comparisons, variable references).

---

## 15. Acceptance Criteria Checklist

- [ ] Differential harness loads a corpus of real/stored gateway conditions from JSON fixtures.
- [ ] Each condition is evaluated on both `vendor/cel` and `src/expr/` and boolean results are asserted identical.
- [ ] Divergences catalogued with condition text, CEL result, expr result, and diff detail.
- [ ] Harness produces a structured JSON report: total, matched, diverged counts, and per-divergence details.
- [ ] Cutover gate enforced: no production module imports `src/expr/` on the engine path until corpus is 100% green.
- [ ] `zig build test-differential` CI target exits 0 when all conditions match, 1 on divergence.
- [ ] ISS-201 `TransitionResult` with `emitted_events` is the prerequisite (already implemented).
- [ ] Corpus version-controlled at `tests/differential/corpus/conditions_v1.json`.
- [ ] Mechanical translator handles the CEL/expr grammar intersection; unsupported features recorded as divergences.
