# Test Spec: DSL-02 — AST Stability

**Requirement:** DSL-02 — The parser MUST produce an AST whose shape is deterministic for a given input. Two parses of the same input MUST yield structurally identical ASTs.  
**Priority:** MUST  
**Test layer:** unit

---

## Overview

DSL-02 mandates that parsing the same source string twice always produces two structurally
identical ASTs. The verification mechanism is `ast.nodeEql(ast1.root, ast2.root)` — a pure
recursive equality function defined in `src/expr/ast.zig`.

This spec covers:

1. **Positive cases (TC-DSL02-0xx)** — 9 inputs covering every major Node variant; each must
   satisfy `nodeEql(parse(src).root, parse(src).root) == true`.
2. **Negative cases (TC-DSL02-1xx)** — 3 pairs of structurally distinct inputs; each must
   satisfy `nodeEql(parse(lhs).root, parse(rhs).root) == false`.

No mocks, stubs, or in-memory fakes are used. All tests invoke the real parser at
`src/expr/parser.zig` (via `src/expr/mod.zig`) against real allocator memory.

**Test file:** `tests/unit/expr_ast_stability_test.zig`  
**Build command:** `zig build test-expr` (or `zig build test`)  
**Entry point:** `src/expr/mod.zig::parse(allocator, source)` returning `ParseResult` (`.ok` / `.fail`)

---

## Test Case Boilerplate

All test cases follow the pattern below. TEST-RUNNER MUST import `nodeEql` from `ast.zig`
and `parse` from `mod.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const expr    = @import("../../src/expr/mod.zig");
const ast_mod = @import("../../src/expr/ast.zig");

// Helper: parse src, assert ok, return Ast.
// Caller must call .deinit() on the returned Ast.
fn mustParse(alloc: std.mem.Allocator, src: []const u8) !ast_mod.Ast {
    var result = try expr.parse(alloc, src);
    switch (result) {
        .fail => |errs| {
            alloc.free(errs);
            try testing.expect(false); // unexpected parse failure
            unreachable;
        },
        .ok => |a| return a,
    }
}
```

---

## Section 1: Positive Cases — Same Input → `nodeEql` Returns `true`

---

### TC-DSL02-001: integer literal — `"42"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "42")` is called → `ast1` (result is `.ok`)
2. `parse(alloc, "42")` is called again → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.int_literal` with value `42`
- `ast2.root.*` is `.int_literal` with value `42`
- `nodeEql(ast1.root, ast2.root) == true`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic integer literal node; `nodeEql` leaf comparison via `a.int_literal == b.int_literal`

---

### TC-DSL02-002: float literal — `"3.14"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "3.14")` → `ast1` (result is `.ok`)
2. `parse(alloc, "3.14")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.float_literal`
- `nodeEql(ast1.root, ast2.root) == true`

**Note:** Bitwise `f64` equality is used (not epsilon). Two parses of the same source string
go through the same `std.fmt.parseFloat` path and produce the same bit pattern.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic float literal node; `nodeEql` float comparison

---

### TC-DSL02-003: string literal — `"\"hello\""`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "\"hello\"")` → `ast1` (result is `.ok`)
2. `parse(alloc, "\"hello\"")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.string_literal` with inner bytes `hello` (quotes stripped)
- `nodeEql(ast1.root, ast2.root) == true`

**Note:** The two string slices may point to different memory addresses (separate parse arenas).
`nodeEql` MUST use `std.mem.eql(u8, ...)` — not pointer equality — for this case to pass.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic string literal node; `nodeEql` byte-wise string comparison

---

### TC-DSL02-004: boolean literal `true` — `"true"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "true")` → `ast1` (result is `.ok`)
2. `parse(alloc, "true")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.bool_literal` with value `true`
- `nodeEql(ast1.root, ast2.root) == true`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic bool literal node; `nodeEql` bool comparison

---

### TC-DSL02-005: null literal — `"null"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "null")` → `ast1` (result is `.ok`)
2. `parse(alloc, "null")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.null_literal`
- `nodeEql(ast1.root, ast2.root) == true`

**Note:** `null_literal` carries `void` payload; `nodeEql` returns `true` unconditionally for
this variant once the tag check passes.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic null literal node; `nodeEql` void-payload handling

---

### TC-DSL02-006: arithmetic expression — `"1 + 2 * 3"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "1 + 2 * 3")` → `ast1` (result is `.ok`)
2. `parse(alloc, "1 + 2 * 3")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.add_expr` with `op == .add`
  - left child is `.int_literal` 1
  - right child is `.mul_expr` with `op == .mul`; its left is `.int_literal` 2, right is `.int_literal` 3
- `ast2.root` has the identical shape
- `nodeEql(ast1.root, ast2.root) == true`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic compound arithmetic tree; exercises `add_expr` and `mul_expr` operator + children comparison

---

### TC-DSL02-007: boolean expression with comparison — `"x > 0 and y < 10"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "x > 0 and y < 10")` → `ast1` (result is `.ok`)
2. `parse(alloc, "x > 0 and y < 10")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.and_expr`
  - left child is `.cmp_expr` with `op == .gt`; left is `.dot_path` `["x"]`, right is `.int_literal` 0
  - right child is `.cmp_expr` with `op == .lt`; left is `.dot_path` `["y"]`, right is `.int_literal` 10
- `ast2.root` has the identical shape
- `nodeEql(ast1.root, ast2.root) == true`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic compound boolean/comparison tree; exercises `and_expr`, `cmp_expr`, `dot_path`, `int_literal` comparisons; `dot_path` segment-level equality used for `["x"]` and `["y"]`

---

### TC-DSL02-008: dot path — `"order.total"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "order.total")` → `ast1` (result is `.ok`)
2. `parse(alloc, "order.total")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.dot_path` with `len == 2`; segments are `["order", "total"]`
- `nodeEql(ast1.root, ast2.root) == true`

**Note:** Segment slices in each tree point into separate arena allocations. `nodeEql` MUST
compare each segment with `std.mem.eql(u8, ...)` for this case to pass.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic dot-path node; `nodeEql` segment-by-segment comparison

---

### TC-DSL02-009: function call — `"length(name)"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "length(name)")` → `ast1` (result is `.ok`)
2. `parse(alloc, "length(name)")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.func_call` with `name == "length"` and `args.len == 1`
  - `args[0]` is `.dot_path` with segments `["name"]`
- `ast2.root` has the identical shape
- `nodeEql(ast1.root, ast2.root) == true`

**Note:** Both function name and argument nodes are compared. The name slice comparison uses
`std.mem.eql(u8, ...)` because the two slices point into separate parse arenas.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — deterministic function-call node; exercises `func_call` name comparison + recursive argument comparison

---

## Section 2: Negative Cases — Different Inputs → `nodeEql` Returns `false`

---

### TC-DSL02-101: same operator, different operands — `"1 + 2"` vs `"1 + 3"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "1 + 2")` → `ast1` (result is `.ok`)
2. `parse(alloc, "1 + 3")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.add_expr`; right child is `.int_literal` 2
- `ast2.root.*` is `.add_expr`; right child is `.int_literal` 3
- `nodeEql(ast1.root, ast2.root) == false`

**Rationale:** The `add_expr` tags match, the `op` fields match (`.add` in both), but the
right-child `int_literal` payloads differ (2 ≠ 3). The recursive call on the right children
returns `false`, which propagates to the top.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — `nodeEql` correctly distinguishes trees with matching operator but differing operand values

---

### TC-DSL02-102: same literal type, different value — `"true"` vs `"false"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "true")` → `ast1` (result is `.ok`)
2. `parse(alloc, "false")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.bool_literal` with value `true`
- `ast2.root.*` is `.bool_literal` with value `false`
- `nodeEql(ast1.root, ast2.root) == false`

**Rationale:** Tags match (`.bool_literal`), but `true != false`.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — `nodeEql` correctly distinguishes bool literal trees with different values

---

### TC-DSL02-103: different node types — `"1"` (int) vs `"1.0"` (float)

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "1")` → `ast1` (result is `.ok`)
2. `parse(alloc, "1.0")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.int_literal` with value `1`
- `ast2.root.*` is `.float_literal` with value `1.0`
- `nodeEql(ast1.root, ast2.root) == false`

**Rationale:** Active tags differ (`.int_literal` vs `.float_literal`). The tag-inequality
fast-path in `nodeEql` returns `false` before any payload comparison is needed.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — `nodeEql` correctly distinguishes trees with different Node variant tags; validates the tag fast-path

---

## Section 3: Additional Stability Invariant Cases

The following cases verify that the determinism property holds for complex, deeply-nested
expressions — confirming that `nodeEql` operates correctly throughout the full recursive depth.

---

### TC-DSL02-201: negated complex condition — `"not (x > 0 and y < 100)"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "not (x > 0 and y < 100)")` → `ast1` (result is `.ok`)
2. `parse(alloc, "not (x > 0 and y < 100)")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.not_expr`; operand is `.and_expr`
- `nodeEql(ast1.root, ast2.root) == true`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — determinism for `not_expr` wrapping `and_expr`; exercises `not_expr` and `unary_neg` recursive comparison

---

### TC-DSL02-202: multi-argument function call — `"date_add(due_date, 7)"`

**Given:** a test allocator is initialised  
**When:**
1. `parse(alloc, "date_add(due_date, 7)")` → `ast1` (result is `.ok`)
2. `parse(alloc, "date_add(due_date, 7)")` → `ast2` (result is `.ok`)

**Then:**
- Both results are `.ok`
- `ast1.root.*` is `.func_call` with `name == "date_add"` and `args.len == 2`
  - `args[0]` is `.dot_path` `["due_date"]`
  - `args[1]` is `.int_literal` 7
- `nodeEql(ast1.root, ast2.root) == true`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-02 — determinism for `func_call` with multiple arguments; exercises argument-count check and per-argument recursive comparison

---

## Summary Table

| ID | Input(s) | Positive / Negative | Node variants exercised | AC |
|---|---|---|---|---|
| TC-DSL02-001 | `"42"` | Positive | `int_literal` | DSL-02 |
| TC-DSL02-002 | `"3.14"` | Positive | `float_literal` | DSL-02 |
| TC-DSL02-003 | `"\"hello\""` | Positive | `string_literal` | DSL-02 |
| TC-DSL02-004 | `"true"` | Positive | `bool_literal` | DSL-02 |
| TC-DSL02-005 | `"null"` | Positive | `null_literal` | DSL-02 |
| TC-DSL02-006 | `"1 + 2 * 3"` | Positive | `add_expr`, `mul_expr`, `int_literal` | DSL-02 |
| TC-DSL02-007 | `"x > 0 and y < 10"` | Positive | `and_expr`, `cmp_expr`, `dot_path`, `int_literal` | DSL-02 |
| TC-DSL02-008 | `"order.total"` | Positive | `dot_path` | DSL-02 |
| TC-DSL02-009 | `"length(name)"` | Positive | `func_call`, `dot_path` | DSL-02 |
| TC-DSL02-101 | `"1 + 2"` vs `"1 + 3"` | Negative | `add_expr`, `int_literal` | DSL-02 |
| TC-DSL02-102 | `"true"` vs `"false"` | Negative | `bool_literal` | DSL-02 |
| TC-DSL02-103 | `"1"` vs `"1.0"` | Negative | `int_literal` vs `float_literal` | DSL-02 |
| TC-DSL02-201 | `"not (x > 0 and y < 100)"` | Positive | `not_expr`, `and_expr`, `cmp_expr`, `dot_path` | DSL-02 |
| TC-DSL02-202 | `"date_add(due_date, 7)"` | Positive | `func_call` (2 args), `dot_path`, `int_literal` | DSL-02 |

**Total positive cases:** 11 (TC-DSL02-001 through TC-DSL02-009 plus TC-DSL02-201 and TC-DSL02-202)  
**Total negative cases:** 3 (TC-DSL02-101 through TC-DSL02-103)  
**Minimum acceptance criteria satisfied:** ≥ 9 positive, ≥ 3 negative — YES

---

## Implementation Notes for TEST-RUNNER

### Test file location

`tests/unit/expr_ast_stability_test.zig`

### Import pattern

```zig
const std    = @import("std");
const testing = std.testing;
const expr   = @import("../../src/expr/mod.zig");
const ast_mod = @import("../../src/expr/ast.zig");
```

### ParseResult handling

```zig
var result = try expr.parse(alloc, src);
switch (result) {
    .ok  => |*a| {
        defer a.deinit();
        // assertions here
    },
    .fail => |errs| {
        defer alloc.free(errs);
        try testing.expect(false); // unexpected failure
    },
}
```

### nodeEql invocation

```zig
try testing.expect(ast_mod.nodeEql(ast1.root, ast2.root));      // positive
try testing.expect(!ast_mod.nodeEql(ast1.root, ast2.root));     // negative
```

### No mocks or stubs

All tests call the real parser in `src/expr/parser.zig`. No mock parser, no hand-constructed
`Node` trees (those would bypass the parser determinism property under test). Each test case
parses its input string via `expr.parse` to obtain a genuine AST before comparing.

### Build command

```bash
zig build test-expr
```

(or `zig build test` to run the full suite including DSL-02 tests)
