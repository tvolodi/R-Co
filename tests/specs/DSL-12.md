# Test Spec: DSL-12 — Engine API (Parse & Evaluate)

**Requirement:** DSL-12 — Engine API  
**Purpose:** Public API for parsing and evaluating expressions with caching support. The API decouples expression parsing (one-time cost) from evaluation (per-evaluation cost), enabling reusability of parsed expressions across multiple contexts.

**Priority:** MUST  
**Test layer:** unit

---

## Test Strategy

All DSL-12 tests are executed at the unit layer (pure Zig tests, no database, no I/O). Parse and evaluate operations are pure functions: given an explicit source string and context, they always produce the same result deterministically. These tests verify:

1. **Parse function correctness** — valid expressions parse successfully into reusable `ParsedExpr` objects
2. **Parse determinism** — parsing the same source twice produces structurally identical ASTs
3. **Evaluate function correctness** — parsed expressions evaluate correctly against different contexts
4. **Caching & reusability** — same `ParsedExpr` can be evaluated multiple times yielding identical results
5. **Error handling** — parse errors and evaluation errors return detailed diagnostics (line, column, message)
6. **Memory management** — `ParsedExpr` owns allocations via arena; `deinit()` properly deallocates
7. **Whitespace normalization** — leading/trailing/internal whitespace is normalized for caching
8. **Null/empty handling** — null context and empty strings are handled gracefully
9. **Context independence** — same `ParsedExpr` evaluated against different contexts yields correct results for each context
10. **Metadata tracking** — `ParsedExpr` metadata correctly tracks node count and evaluation statistics

**Test environment:** Pure Zig unit tests, no database required, no I/O. Tests run via `zig build test`.

**Key design invariants verified:**
- Parsing is deterministic: `parse(alloc, src) == parse(alloc, src)` (structurally identical AST)
- `ParsedExpr` is immutable after construction
- Evaluation is deterministic: `evaluate(&expr, &ctx1) == evaluate(&expr, &ctx1)` (same inputs → same output)
- `ParsedExpr` can be safely shared across multiple concurrent read-only evaluations
- Parse errors include line/column info and offending token
- Evaluation errors include line/column info and type/operation details
- Memory allocated by `parse()` is owned by the returned `ParsedExpr` and freed on `deinit()`
- Memory allocated during `evaluate()` is temporary and freed before return
- Source string lifetime must be maintained while parse errors are in use (lexeme slices point into source)
- Whitespace normalization applies to cache keys but not to token sequences within literals

---

## Coverage Matrix

| Category | Test Cases | Layer |
|---|---|---|
| **Parse — Valid expressions** | | |
| Simple literal (integer) | TC-DSL-12-01 | unit |
| Simple literal (float) | TC-DSL-12-02 | unit |
| Simple literal (string) | TC-DSL-12-03 | unit |
| Simple literal (boolean) | TC-DSL-12-04 | unit |
| Simple identifier (single variable) | TC-DSL-12-05 | unit |
| Identifier with dot-path (two levels) | TC-DSL-12-06 | unit |
| Binary operator (comparison) | TC-DSL-12-07 | unit |
| Binary operator (arithmetic) | TC-DSL-12-08 | unit |
| Binary operator (logical) | TC-DSL-12-09 | unit |
| Complex expression (nested operators) | TC-DSL-12-10 | unit |
| **Parse — Determinism & Normalization** | | |
| Same source parsed twice yields identical AST | TC-DSL-12-11 | unit |
| Whitespace-trimmed expressions normalize to same cache key | TC-DSL-12-12 | unit |
| Internal whitespace collapsed (single space) normalizes correctly | TC-DSL-12-13 | unit |
| Empty string handling in parse | TC-DSL-12-14 | unit |
| Whitespace-only string handling | TC-DSL-12-15 | unit |
| **Parse — Error cases** | | |
| Invalid syntax (unexpected token) | TC-DSL-12-16 | unit |
| Invalid syntax (malformed operator) | TC-DSL-12-17 | unit |
| Invalid syntax (unmatched parenthesis) | TC-DSL-12-18 | unit |
| Parse error includes line/column info | TC-DSL-12-19 | unit |
| Parse error includes offending token | TC-DSL-12-20 | unit |
| Out of memory during parse | TC-DSL-12-21 | unit |
| **Evaluate — Basic evaluation** | | |
| Evaluate literal (no context required) | TC-DSL-12-22 | unit |
| Evaluate identifier against context | TC-DSL-12-23 | unit |
| Evaluate dot-path against context | TC-DSL-12-24 | unit |
| Evaluate comparison (true result) | TC-DSL-12-25 | unit |
| Evaluate comparison (false result) | TC-DSL-12-26 | unit |
| Evaluate arithmetic (addition) | TC-DSL-12-27 | unit |
| Evaluate arithmetic (subtraction) | TC-DSL-12-28 | unit |
| Evaluate logical AND (true && true = true) | TC-DSL-12-29 | unit |
| Evaluate logical AND (true && false = false) | TC-DSL-12-30 | unit |
| Evaluate logical OR (true \|\| false = true) | TC-DSL-12-31 | unit |
| Evaluate logical NOT (!true = false) | TC-DSL-12-32 | unit |
| **Evaluate — Multiple contexts** | | |
| Same ParsedExpr evaluated against context1 | TC-DSL-12-33 | unit |
| Same ParsedExpr evaluated against context2 (different values) | TC-DSL-12-34 | unit |
| Different contexts yield different results for same expression | TC-DSL-12-35 | unit |
| Same variable name, different values across contexts | TC-DSL-12-36 | unit |
| **Evaluate — Null context & missing vars** | | |
| Evaluate with empty (null) context | TC-DSL-12-37 | unit |
| Missing variable resolves to null (DSL-10 integration) | TC-DSL-12-38 | unit |
| Missing nested path returns null (DSL-11 integration) | TC-DSL-12-39 | unit |
| Null in context value propagates correctly (DSL-05 integration) | TC-DSL-12-40 | unit |
| **Evaluate — Error cases** | | |
| Evaluation error on type mismatch | TC-DSL-12-41 | unit |
| Evaluation error includes line/column info | TC-DSL-12-42 | unit |
| Evaluation error on division by zero | TC-DSL-12-43 | unit |
| Evaluation error on unsupported operation | TC-DSL-12-44 | unit |
| Out of memory during evaluation | TC-DSL-12-45 | unit |
| **Caching & Reusability** | | |
| Parse once, evaluate same ParsedExpr multiple times | TC-DSL-12-46 | unit |
| Multiple evaluations of same ParsedExpr yield identical results | TC-DSL-12-47 | unit |
| Evaluating cached expression produces same result as new parse+eval | TC-DSL-12-48 | unit |
| ParsedExpr is not modified by evaluate() calls | TC-DSL-12-49 | unit |
| Metadata (eval_count) increments on each evaluate | TC-DSL-12-50 | unit |
| Different source strings produce different ParsedExpr objects | TC-DSL-12-51 | unit |
| **Memory & Safety** | | |
| ParsedExpr.deinit() properly deallocates arena | TC-DSL-12-52 | unit |
| No memory leak after parse+deinit cycle | TC-DSL-12-53 | unit |
| Parse result lifetime independent of source lifetime | TC-DSL-12-54 | unit |
| Parse error lexeme slices point into original source | TC-DSL-12-55 | unit |
| Evaluate allocations are temporary and freed on return | TC-DSL-12-56 | unit |
| Multiple sequential parse+deinit cycles do not leak | TC-DSL-12-57 | unit |
| Context can be deallocated independently of ParsedExpr | TC-DSL-12-58 | unit |
| **Metadata & Node Count** | | |
| Metadata.ast_node_count > 0 for non-trivial expression | TC-DSL-12-59 | unit |
| Metadata.ast_node_count == 1 for simple literal | TC-DSL-12-60 | unit |
| Metadata.source_hash set for caching | TC-DSL-12-61 | unit |
| Metadata.eval_count starts at 0 | TC-DSL-12-62 | unit |
| **Integration: Parse → Evaluate → Re-evaluate** | | |
| End-to-end: parse → evaluate1 → evaluate2 → deinit | TC-DSL-12-63 | unit |
| End-to-end: complex expression (DSL-05 + DSL-10 + DSL-11) | TC-DSL-12-64 | unit |
| End-to-end: error handling in parse returns detailed diagnostic | TC-DSL-12-65 | unit |
| End-to-end: error handling in evaluate returns detailed diagnostic | TC-DSL-12-66 | unit |

**Total: 66 test cases covering all 14 categories**

---

## Test Cases

### Category 1: Parse — Valid Expressions

#### TC-DSL-12-01: Parse simple integer literal
**Given:** Source `"42"` and valid allocator  
**When:** `parse(allocator, "42")` is called  
**Then:** Returns `ParsedExpr` with root node of type `literal` containing `int_val == 42`  
**Layer:** unit  
**Rationale:** Verify that simple integer literals parse correctly.  
**Acceptance criterion mapped:** Valid expressions parse successfully into reusable ParsedExpr objects

#### TC-DSL-12-02: Parse simple float literal
**Given:** Source `"3.14"` and valid allocator  
**When:** `parse(allocator, "3.14")` is called  
**Then:** Returns `ParsedExpr` with root node of type `literal` containing `float_val == 3.14`  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-03: Parse simple string literal
**Given:** Source `"\"hello\""` and valid allocator  
**When:** `parse(allocator, "\"hello\"")` is called  
**Then:** Returns `ParsedExpr` with root node containing string value `"hello"`  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-04: Parse simple boolean literal
**Given:** Source `"true"` and valid allocator  
**When:** `parse(allocator, "true")` is called  
**Then:** Returns `ParsedExpr` with root node containing `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-05: Parse simple identifier (single variable)
**Given:** Source `"order"` and valid allocator  
**When:** `parse(allocator, "order")` is called  
**Then:** Returns `ParsedExpr` with root node of type `identifier` with name `"order"`  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-06: Parse identifier with dot-path (two levels)
**Given:** Source `"order.total"` and valid allocator  
**When:** `parse(allocator, "order.total")` is called  
**Then:** Returns `ParsedExpr` with root node of type `dot_path` with segments `["order", "total"]`  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-07: Parse comparison operator
**Given:** Source `"price > 100"` and valid allocator  
**When:** `parse(allocator, "price > 100")` is called  
**Then:** Returns `ParsedExpr` with root node of type `cmp_expr` (greater than), left operand `identifier("price")`, right operand `literal(100)`  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-08: Parse arithmetic operator
**Given:** Source `"a + b"` and valid allocator  
**When:** `parse(allocator, "a + b")` is called  
**Then:** Returns `ParsedExpr` with root node of type `add_expr`, left operand `identifier("a")`, right operand `identifier("b")`  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-09: Parse logical operator
**Given:** Source `"active and enabled"` and valid allocator  
**When:** `parse(allocator, "active and enabled")` is called  
**Then:** Returns `ParsedExpr` with root node of type `logical_and`, left and right operands as identifiers  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

#### TC-DSL-12-10: Parse complex nested expression
**Given:** Source `"(a + b) * (c - d) > 100 and status == \"ok\""` and valid allocator  
**When:** `parse()` is called  
**Then:** Returns `ParsedExpr` with multi-level AST structure correctly representing operator precedence and associativity  
**Layer:** unit  
**Acceptance criterion mapped:** Valid expressions parse successfully

---

### Category 2: Parse — Determinism & Normalization

#### TC-DSL-12-11: Same source parsed twice yields identical AST
**Given:** Source `"order.total > 100"` parsed twice with the same allocator  
**When:** `parse(alloc, src)` called twice  
**Then:** Both `ParsedExpr` instances have structurally identical root nodes (recursively equal AST)  
**Layer:** unit  
**Rationale:** Verify parsing determinism (DSL-02 invariant).  
**Acceptance criterion mapped:** Parsing is deterministic

#### TC-DSL-12-12: Whitespace-trimmed expressions normalize to same cache key
**Given:** Sources `"  order.total > 100  "` and `"order.total > 100"` and valid allocator  
**When:** Both are parsed and their normalized strings compared  
**Then:** Both should normalize to the same cache key (after trimming leading/trailing whitespace)  
**Layer:** unit  
**Rationale:** Cache normalization should collapse whitespace differences.  
**Acceptance criterion mapped:** Whitespace normalization applies to cache keys

#### TC-DSL-12-13: Internal whitespace collapsed to single space normalizes correctly
**Given:** Sources `"order  .  total"` (multiple spaces around dot) and `"order . total"` (single spaces)  
**When:** Both are parsed  
**Then:** Both should normalize to consistent cache key representation (internal spaces collapsed to single space)  
**Layer:** unit  
**Acceptance criterion mapped:** Whitespace normalization handles internal spaces

#### TC-DSL-12-14: Empty string handling in parse
**Given:** Source `""` (empty string) and valid allocator  
**When:** `parse(allocator, "")` is called  
**Then:** Returns error (parse error for empty input)  
**Layer:** unit  
**Rationale:** Empty expressions are invalid.  
**Acceptance criterion mapped:** Error handling for invalid input

#### TC-DSL-12-15: Whitespace-only string handling
**Given:** Source `"   "` (only spaces) and valid allocator  
**When:** `parse(allocator, "   ")` is called  
**Then:** Returns error (parse error for whitespace-only input)  
**Layer:** unit  
**Acceptance criterion mapped:** Error handling for invalid input

---

### Category 3: Parse — Error Cases

#### TC-DSL-12-16: Invalid syntax (unexpected token)
**Given:** Source `"order >> 100"` (invalid operator `>>`) and valid allocator  
**When:** `parse(allocator, "order >> 100")` is called  
**Then:** Returns error with `ParseError` containing message about unexpected token `>>`  
**Layer:** unit  
**Acceptance criterion mapped:** Parse errors include detailed diagnostics

#### TC-DSL-12-17: Invalid syntax (malformed operator)
**Given:** Source `"a +++ b"` and valid allocator  
**When:** `parse()` is called  
**Then:** Returns error (unexpected token sequence)  
**Layer:** unit  
**Acceptance criterion mapped:** Parse errors for malformed operators

#### TC-DSL-12-18: Invalid syntax (unmatched parenthesis)
**Given:** Source `"(a + b"` (missing closing paren) and valid allocator  
**When:** `parse()` is called  
**Then:** Returns error with message indicating unclosed parenthesis  
**Layer:** unit  
**Acceptance criterion mapped:** Parse errors for syntax errors

#### TC-DSL-12-19: Parse error includes line/column info
**Given:** Multi-line equivalent or single-line source with error at known position  
**When:** `parse()` returns error  
**Then:** Error includes `line: 1` and `column: <position of error>` (1-based)  
**Layer:** unit  
**Rationale:** Error diagnostics must be actionable.  
**Acceptance criterion mapped:** Parse errors include line/column information

#### TC-DSL-12-20: Parse error includes offending token
**Given:** Source `"order >> 100"` and valid allocator  
**When:** `parse()` returns error  
**Then:** Error message includes the offending token `">>"` or a slice pointing into the source  
**Layer:** unit  
**Acceptance criterion mapped:** Parse errors include offending token

#### TC-DSL-12-21: Out of memory during parse
**Given:** Valid source string and an allocator that fails on any allocation (simulated OOM)  
**When:** `parse(oom_allocator, source)` is called  
**Then:** Returns `OutOfMemory` error  
**Layer:** unit  
**Rationale:** Handle allocation failures gracefully.  
**Acceptance criterion mapped:** Error handling for memory errors

---

### Category 4: Evaluate — Basic Evaluation

#### TC-DSL-12-22: Evaluate literal (no context required)
**Given:** `ParsedExpr` for `"42"` and any context  
**When:** `evaluate(&parsed_expr, &context, allocator)` is called  
**Then:** Returns `Value.int_val == 42` (literals are context-independent)  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate function correctly evaluates expressions

#### TC-DSL-12-23: Evaluate identifier against context
**Given:** `ParsedExpr` for `"order"` and context `{ "order": 100 }`  
**When:** `evaluate()` is called  
**Then:** Returns `Value.int_val == 100`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate resolves identifiers from context

#### TC-DSL-12-24: Evaluate dot-path against context
**Given:** `ParsedExpr` for `"order.total"` and context `{ "order": "{\"total\": 500}" }`  
**When:** `evaluate()` is called  
**Then:** Returns `Value.int_val == 500` (DSL-11 integration)  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate integrates with DSL-11 dot-path

#### TC-DSL-12-25: Evaluate comparison (true result)
**Given:** `ParsedExpr` for `"100 > 50"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates comparisons

#### TC-DSL-12-26: Evaluate comparison (false result)
**Given:** `ParsedExpr` for `"50 > 100"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates comparisons

#### TC-DSL-12-27: Evaluate arithmetic (addition)
**Given:** `ParsedExpr` for `"30 + 12"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.int_val == 42`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates arithmetic

#### TC-DSL-12-28: Evaluate arithmetic (subtraction)
**Given:** `ParsedExpr` for `"100 - 42"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.int_val == 58`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates arithmetic

#### TC-DSL-12-29: Evaluate logical AND (true && true = true)
**Given:** `ParsedExpr` for `"true and true"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates logical operators

#### TC-DSL-12-30: Evaluate logical AND (true && false = false)
**Given:** `ParsedExpr` for `"true and false"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates logical operators

#### TC-DSL-12-31: Evaluate logical OR (true || false = true)
**Given:** `ParsedExpr` for `"true or false"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates logical operators

#### TC-DSL-12-32: Evaluate logical NOT (!true = false)
**Given:** `ParsedExpr` for `"not true"` and any valid context  
**When:** `evaluate()` is called  
**Then:** Returns `Value.bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluate correctly evaluates logical operators

---

### Category 5: Evaluate — Multiple Contexts

#### TC-DSL-12-33: Same ParsedExpr evaluated against context1
**Given:** `ParsedExpr` for `"price > 100"` and context1 `{ "price": 150 }`  
**When:** `evaluate(&parsed_expr, &context1, allocator)` is called  
**Then:** Returns `Value.bool_val == true`  
**Layer:** unit  
**Rationale:** Verify ParsedExpr can be evaluated against different contexts.  
**Acceptance criterion mapped:** Same ParsedExpr can be evaluated against different contexts

#### TC-DSL-12-34: Same ParsedExpr evaluated against context2 (different values)
**Given:** Same `ParsedExpr` for `"price > 100"` and context2 `{ "price": 50 }`  
**When:** `evaluate(&parsed_expr, &context2, allocator)` is called  
**Then:** Returns `Value.bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Same ParsedExpr yields correct results for different contexts

#### TC-DSL-12-35: Different contexts yield different results for same expression
**Given:** `ParsedExpr` for `"x + 10"` evaluated against context1 `{ "x": 5 }` and context2 `{ "x": 20 }`  
**When:** Both evaluations are performed  
**Then:** context1 yields `15`, context2 yields `30` (context-dependent evaluation)  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluation results depend on context values

#### TC-DSL-12-36: Same variable name, different values across contexts
**Given:** `ParsedExpr` for `"amount"` evaluated against multiple contexts with different `amount` values  
**When:** Each evaluation is performed  
**Then:** Each returns the value from its respective context  
**Layer:** unit  
**Acceptance criterion mapped:** Variable resolution is context-specific

---

### Category 6: Evaluate — Null Context & Missing Variables

#### TC-DSL-12-37: Evaluate with empty (null) context
**Given:** `ParsedExpr` for `"x"` and empty context `{}`  
**When:** `evaluate(&parsed_expr, &empty_context, allocator)` is called  
**Then:** Returns `Value.null_val` (DSL-10 missing variable behavior)  
**Layer:** unit  
**Rationale:** Unresolved identifiers return null, not error.  
**Acceptance criterion mapped:** Null context handling (DSL-10 integration)

#### TC-DSL-12-38: Missing variable resolves to null (DSL-10 integration)
**Given:** `ParsedExpr` for `"missing_var"` and context without that key  
**When:** `evaluate()` is called  
**Then:** Returns `Value.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Missing variables return null (DSL-10)

#### TC-DSL-12-39: Missing nested path returns null (DSL-11 integration)
**Given:** `ParsedExpr` for `"data.missing.field"` and context `{ "data": "{\"other\": 42}" }`  
**When:** `evaluate()` is called  
**Then:** Returns `Value.null_val` (missing field in nested structure)  
**Layer:** unit  
**Acceptance criterion mapped:** Missing nested paths return null (DSL-11)

#### TC-DSL-12-40: Null in context value propagates correctly (DSL-05 integration)
**Given:** `ParsedExpr` for `"x and true"` and context `{ "x": null }`  
**When:** `evaluate()` is called  
**Then:** Returns `Value.null_val` (three-valued logic from DSL-05)  
**Layer:** unit  
**Acceptance criterion mapped:** Null propagation in evaluation (DSL-05)

---

### Category 7: Evaluate — Error Cases

#### TC-DSL-12-41: Evaluation error on type mismatch
**Given:** `ParsedExpr` for `"\"string\" + 5"` (cannot add string and int) and valid context  
**When:** `evaluate()` is called  
**Then:** Returns `TypeError` error  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluation errors for type mismatches

#### TC-DSL-12-42: Evaluation error includes line/column info
**Given:** `ParsedExpr` for an expression with a type error at a known position  
**When:** `evaluate()` returns error  
**Then:** Error includes `line: 1` and `column: <position>` where the error occurred  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluation errors include line/column information

#### TC-DSL-12-43: Evaluation error on division by zero
**Given:** `ParsedExpr` for `"100 / 0"` and valid context  
**When:** `evaluate()` is called  
**Then:** Returns `DivideByZero` error or similar  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluation errors for arithmetic errors

#### TC-DSL-12-44: Evaluation error on unsupported operation
**Given:** `ParsedExpr` for an expression with an unsupported operation (e.g., modulo on non-integers)  
**When:** `evaluate()` is called  
**Then:** Returns `EvalError` or `TypeError`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluation errors for unsupported operations

#### TC-DSL-12-45: Out of memory during evaluation
**Given:** `ParsedExpr` for a complex expression and an allocator that fails (simulated OOM)  
**When:** `evaluate(&parsed_expr, &context, oom_allocator)` is called  
**Then:** Returns `OutOfMemory` error  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluation error handling for memory errors

---

### Category 8: Caching & Reusability

#### TC-DSL-12-46: Parse once, evaluate same ParsedExpr multiple times
**Given:** `ParsedExpr` for `"x > 10"` parsed once  
**When:** `evaluate()` is called 5 times with different contexts  
**Then:** All 5 evaluations complete successfully (parser cost amortized)  
**Layer:** unit  
**Rationale:** Verify that a single parsed expression can be reused.  
**Acceptance criterion mapped:** Caching: parse once, evaluate multiple times

#### TC-DSL-12-47: Multiple evaluations of same ParsedExpr yield identical results
**Given:** `ParsedExpr` for `"5 + 3"` and context that does not affect result (literal expression)  
**When:** `evaluate()` is called 3 times on the same `ParsedExpr`  
**Then:** All 3 calls return `Value.int_val == 8`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluation is deterministic

#### TC-DSL-12-48: Evaluating cached expression produces same result as new parse+eval
**Given:** Source `"a + b"` with context `{ "a": 10, "b": 20 }`  
**When:** Evaluated via cached `ParsedExpr` and via new `parse()` then `evaluate()`  
**Then:** Both produce identical result `Value.int_val == 30`  
**Layer:** unit  
**Acceptance criterion mapped:** Caching preserves evaluation semantics

#### TC-DSL-12-49: ParsedExpr is not modified by evaluate() calls
**Given:** `ParsedExpr` for `"x"` and metadata tracking eval_count initially at 0  
**When:** `evaluate()` is called (note: metadata updates use `@constCast` internally)  
**Then:** The returned `ParsedExpr` reference is still valid, and the AST structure is unchanged  
**Layer:** unit  
**Rationale:** Evaluate must not mutate the AST (immutability guarantee).  
**Acceptance criterion mapped:** ParsedExpr immutability after construction

#### TC-DSL-12-50: Metadata (eval_count) increments on each evaluate
**Given:** `ParsedExpr` with initial `metadata.eval_count == 0`  
**When:** `evaluate()` is called 3 times  
**Then:** `metadata.eval_count` increases by 1 after each call (final value 3)  
**Layer:** unit  
**Rationale:** Cache statistics track evaluation frequency.  
**Acceptance criterion mapped:** Metadata tracking of evaluation statistics

#### TC-DSL-12-51: Different source strings produce different ParsedExpr objects
**Given:** Sources `"a + b"` and `"a - b"` both parsed  
**When:** Both `ParsedExpr` instances are compared structurally  
**Then:** Their root nodes are not equal (different operators)  
**Layer:** unit  
**Acceptance criterion mapped:** Different expressions yield different ASTs

---

### Category 9: Memory & Safety

#### TC-DSL-12-52: ParsedExpr.deinit() properly deallocates arena
**Given:** `ParsedExpr` returned from `parse()`  
**When:** `deinit(allocator)` is called  
**Then:** The arena allocator is freed; no resources remain in use (verified via leak detection tools)  
**Layer:** unit  
**Rationale:** Proper resource cleanup.  
**Acceptance criterion mapped:** Memory management for ParsedExpr

#### TC-DSL-12-53: No memory leak after parse+deinit cycle
**Given:** Loop performing `parse()` then `deinit()` 100 times with the same allocator  
**When:** All cycles complete  
**Then:** Allocator reports no outstanding allocations (no leaks)  
**Layer:** unit  
**Acceptance criterion mapped:** Memory safety

#### TC-DSL-12-54: Parse result lifetime independent of source lifetime
**Given:** Source string allocated on stack, `parse()` called, source lifetime ends  
**When:** `ParsedExpr` is still in use (not yet deinit'd)  
**Then:** `ParsedExpr` remains valid (arena owns all AST data, not dependent on source)  
**Layer:** unit  
**Rationale:** AST nodes and slices are copied into arena; no references to source buffer remain.  
**Acceptance criterion mapped:** Memory independence of parse result

#### TC-DSL-12-55: Parse error lexeme slices point into original source
**Given:** Source `"order >> 100"` and parse error returned  
**When:** Error's token slice is accessed  
**Then:** Slice points into the original source buffer (lexeme offset is valid while source is alive)  
**Layer:** unit  
**Rationale:** Parse errors contain lexeme slices; source must remain valid while error is in use.  
**Acceptance criterion mapped:** Parse error lifetime requirements

#### TC-DSL-12-56: Evaluate allocations are temporary and freed on return
**Given:** `ParsedExpr` and a scratch allocator passed to `evaluate()`  
**When:** `evaluate()` returns  
**Then:** All allocations made to the scratch allocator are freed (or can be reset if arena-based); no leaks  
**Layer:** unit  
**Acceptance criterion mapped:** Memory management for evaluate temporary allocations

#### TC-DSL-12-57: Multiple sequential parse+deinit cycles do not leak
**Given:** Loop performing parse+deinit 50 times with same allocator  
**When:** All cycles complete  
**Then:** Allocator reports zero outstanding allocations  
**Layer:** unit  
**Acceptance criterion mapped:** Memory safety across multiple cycles

#### TC-DSL-12-58: Context can be deallocated independently of ParsedExpr
**Given:** `ParsedExpr` and `Context` created, evaluate() called, then context deinit() called  
**When:** `ParsedExpr` is used again in another evaluate() with a new context  
**Then:** `ParsedExpr` remains valid (contexts do not borrow from ParsedExpr)  
**Layer:** unit  
**Acceptance criterion mapped:** Context and ParsedExpr lifetime independence

---

### Category 10: Metadata & Node Count

#### TC-DSL-12-59: Metadata.ast_node_count > 0 for non-trivial expression
**Given:** `ParsedExpr` for `"a + b > c"` (multi-node AST)  
**When:** Parsed  
**Then:** `metadata.ast_node_count >= 3` (at least one node per operator/operand)  
**Layer:** unit  
**Acceptance criterion mapped:** Metadata tracking of AST complexity

#### TC-DSL-12-60: Metadata.ast_node_count == 1 for simple literal
**Given:** `ParsedExpr` for `"42"` (single literal node)  
**When:** Parsed  
**Then:** `metadata.ast_node_count == 1`  
**Layer:** unit  
**Acceptance criterion mapped:** Metadata accuracy for node count

#### TC-DSL-12-61: Metadata.source_hash set for caching
**Given:** `ParsedExpr` for any expression  
**When:** Parsed  
**Then:** `metadata.source_hash != 0` (hash is computed and stored)  
**Layer:** unit  
**Acceptance criterion mapped:** Metadata tracking of source hash

#### TC-DSL-12-62: Metadata.eval_count starts at 0
**Given:** `ParsedExpr` immediately after parse  
**When:** Metadata is checked  
**Then:** `metadata.eval_count == 0` (not yet evaluated)  
**Layer:** unit  
**Acceptance criterion mapped:** Metadata initialization

---

### Category 11: Integration: Parse → Evaluate → Re-evaluate

#### TC-DSL-12-63: End-to-end: parse → evaluate1 → evaluate2 → deinit
**Given:** Source `"x * 2 + y"`, context1 `{ "x": 5, "y": 3 }`, context2 `{ "x": 10, "y": 7 }`  
**When:** Full workflow executed: parse → eval1 (should be 13) → eval2 (should be 27) → deinit  
**Then:** Both evaluations succeed with correct results; no leaks on deinit  
**Layer:** unit  
**Rationale:** Comprehensive integration test.  
**Acceptance criterion mapped:** End-to-end parse-evaluate-deinit workflow

#### TC-DSL-12-64: End-to-end: complex expression (DSL-05 + DSL-10 + DSL-11)
**Given:** Source `"(customer.data.total > 100 and status == \"approved\") or override"` with nested context and multiple variables  
**When:** Parsed and evaluated  
**Then:** Returns correct boolean result integrating coercion (DSL-05), resolution (DSL-10), and dot-path (DSL-11)  
**Layer:** unit  
**Acceptance criterion mapped:** Integration with DSL-05, DSL-10, DSL-11

#### TC-DSL-12-65: End-to-end: error handling in parse returns detailed diagnostic
**Given:** Invalid source `"a >>"` that fails parsing  
**When:** `parse()` returns error  
**Then:** Error includes line, column, offending token, and human-readable message  
**Layer:** unit  
**Acceptance criterion mapped:** Error handling with detailed diagnostics

#### TC-DSL-12-66: End-to-end: error handling in evaluate returns detailed diagnostic
**Given:** Valid source `"\"text\" + 5"` (valid parse, runtime type error) and context  
**When:** `evaluate()` returns error  
**Then:** Error includes line, column, operation description, and types involved  
**Layer:** unit  
**Acceptance criterion mapped:** Error handling with detailed diagnostics

---

## Test Implementation Notes

### Memory Safety Testing

For TC-DSL-12-52, TC-DSL-12-53, TC-DSL-12-57:
- Use a test allocator that tracks allocations (e.g., `std.testing.allocator`)
- Verify `allocator.deinit()` or similar shows zero outstanding allocations
- Alternatively, use Valgrind or AddressSanitizer if running on suitable platform

### Parsing Determinism Test (TC-DSL-12-11)

```zig
// Pseudo-code for structural equality check
fn structurallyEqual(node1: *Node, node2: *Node) bool {
    if (node1.tag != node2.tag) return false;
    switch (node1.tag) {
        .literal => return valuesEqual(node1.value, node2.value),
        .identifier => return stringsEqual(node1.name, node2.name),
        .binary_op => return (node1.op == node2.op and
                              structurallyEqual(node1.left, node2.left) and
                              structurallyEqual(node1.right, node2.right)),
        // ... other cases ...
    }
}
```

### Whitespace Normalization (TC-DSL-12-12, TC-DSL-12-13)

Test normalization logic by:
1. Parsing two sources with different whitespace
2. Comparing their `metadata.source_hash` (should be equal if normalized correctly)
3. Or comparing their normalized source strings directly (if exposed)

### Context Preparation

For evaluate tests, set up contexts as:
```zig
var context = Context.init(allocator);
defer context.deinit();
try context.put("variable_name", Value.valueInt(42));
try context.put("price", Value.valueFloat(19.99));
try context.put("name", Value.valueStr("Alice"));
```

### Error Testing

For error cases (TC-DSL-12-16 through TC-DSL-12-21, TC-DSL-12-41 through TC-DSL-12-45):
- Expect specific error enum values (e.g., `ParseError`, `TypeError`, `DivideByZero`)
- Verify error details with `try testing.expectEqualStrings(error.message, expected_msg)`
- Check line/column fields of error struct

---

## Coverage Summary

| Category | Test Cases | Count |
|----------|-----------|-------|
| Parse — Valid expressions | TC-DSL-12-01 through TC-DSL-12-10 | 10 |
| Parse — Determinism & Normalization | TC-DSL-12-11 through TC-DSL-12-15 | 5 |
| Parse — Error cases | TC-DSL-12-16 through TC-DSL-12-21 | 6 |
| Evaluate — Basic evaluation | TC-DSL-12-22 through TC-DSL-12-32 | 11 |
| Evaluate — Multiple contexts | TC-DSL-12-33 through TC-DSL-12-36 | 4 |
| Evaluate — Null context & missing vars | TC-DSL-12-37 through TC-DSL-12-40 | 4 |
| Evaluate — Error cases | TC-DSL-12-41 through TC-DSL-12-45 | 5 |
| Caching & Reusability | TC-DSL-12-46 through TC-DSL-12-51 | 6 |
| Memory & Safety | TC-DSL-12-52 through TC-DSL-12-58 | 7 |
| Metadata & Node Count | TC-DSL-12-59 through TC-DSL-12-62 | 4 |
| Integration: Parse → Evaluate → Re-evaluate | TC-DSL-12-63 through TC-DSL-12-66 | 4 |
| **Total** | | **66** |

All test cases verify acceptance criteria from the DSL-12 requirement and ensure parse/evaluate correctness, caching behavior, memory safety, and integration with dependent DSL modules (DSL-05, DSL-10, DSL-11).
