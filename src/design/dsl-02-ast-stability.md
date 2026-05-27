# Design Artefact — DSL-02: AST Stability (`nodeEql`)

**Requirement:** DSL-02  
**Stage:** Stage 7 — Expression DSL  
**Author:** CODE-DESIGNER  
**Run ID:** WF02-dsl02-20260527  
**Status:** DESIGN

---

## 1. Requirement Summary

DSL-02 states: the parser MUST produce an AST whose shape is deterministic for a given input.
Two parses of the same input MUST yield structurally identical ASTs.

The verification mechanism is a deep structural equality function over the AST. Parsing the same
source string twice and comparing the two resulting roots with this function MUST return `true`.

---

## 2. Design Decision: Location

The function is placed in `src/expr/ast.zig`, below the `Ast` struct definition.

**Rationale:**
- `ast.zig` already owns all Node type definitions. Placing `nodeEql` here avoids a circular
  import and keeps tree-shape logic co-located with tree-shape types.
- No new file is needed. No import from parser or evaluator modules is required.

---

## 3. Function Signature

```zig
pub fn nodeEql(a: *const Node, b: *const Node) bool
```

| Element | Detail |
|---|---|
| Visibility | `pub` — callable from tests and the parser module |
| Parameters | Two non-null read-only pointers to `Node` values |
| Return type | `bool` — `true` if the trees rooted at `a` and `b` are structurally identical |
| Recursion | Direct recursion on child pointers; the grammar is acyclic so no cycle guard is needed |
| Allocation | None — reads existing tree, no heap allocation |
| I/O | None — pure function |
| Errors | None — cannot fail; always returns a definite boolean |

The function MUST NOT be a method on `Node` (i.e., not `fn eql(self: *const Node, other: *const Node) bool`).
A free function is preferred to avoid polluting the union namespace and to remain callable from
contexts where `Node` is addressed only through a pointer.

---

## 4. Algorithm

The function is a tagged-union switch on the active variant of `a`. If the active tag of `a`
differs from the active tag of `b`, return `false` immediately (the two trees differ in shape).
Otherwise, compare the payload of each variant as described in Section 5.

```
nodeEql(a, b):
  if tag(a) != tag(b) → return false
  switch tag(a):
    each variant → compare payload (see §5) → return result
```

No iterative stack is needed. The grammar depth is bounded by the recursive descent of the parser
(which mirrors the grammar productions), so stack depth is proportional to expression nesting
depth. Practical DSL expressions do not exceed a few dozen levels of nesting.

---

## 5. Per-Variant Handling

The following table covers all 14 `Node` variants defined in `src/expr/ast.zig`.

### 5.1 Binary nodes (left + right child pointers)

| Variant | Payload fields | Comparison rule |
|---|---|---|
| `or_expr` | `left: *Node`, `right: *Node` | `nodeEql(a.or_expr.left, b.or_expr.left) and nodeEql(a.or_expr.right, b.or_expr.right)` |
| `and_expr` | `left: *Node`, `right: *Node` | `nodeEql(a.and_expr.left, b.and_expr.left) and nodeEql(a.and_expr.right, b.and_expr.right)` |

### 5.2 Comparison node (operator + two children)

| Variant | Payload fields | Comparison rule |
|---|---|---|
| `cmp_expr` | `op: CmpOp`, `left: *Node`, `right: *Node` | `a.cmp_expr.op == b.cmp_expr.op and nodeEql(a.cmp_expr.left, b.cmp_expr.left) and nodeEql(a.cmp_expr.right, b.cmp_expr.right)` |

### 5.3 Arithmetic binary nodes (operator + two children)

| Variant | Payload fields | Comparison rule |
|---|---|---|
| `add_expr` | `op: AddOp`, `left: *Node`, `right: *Node` | `a.add_expr.op == b.add_expr.op and nodeEql(a.add_expr.left, b.add_expr.left) and nodeEql(a.add_expr.right, b.add_expr.right)` |
| `mul_expr` | `op: MulOp`, `left: *Node`, `right: *Node` | `a.mul_expr.op == b.mul_expr.op and nodeEql(a.mul_expr.left, b.mul_expr.left) and nodeEql(a.mul_expr.right, b.mul_expr.right)` |

**Operator comparison:** `CmpOp`, `AddOp`, and `MulOp` are plain Zig enums. Enum equality uses
the built-in `==` operator; no helper is needed.

### 5.4 Unary nodes (single child pointer)

| Variant | Payload fields | Comparison rule |
|---|---|---|
| `not_expr` | `operand: *Node` | `nodeEql(a.not_expr.operand, b.not_expr.operand)` |
| `unary_neg` | `operand: *Node` | `nodeEql(a.unary_neg.operand, b.unary_neg.operand)` |

### 5.5 Scalar literals (leaf nodes — no children)

| Variant | Payload type | Comparison rule |
|---|---|---|
| `int_literal` | `i64` | `a.int_literal == b.int_literal` |
| `float_literal` | `f64` | `a.float_literal == b.float_literal` |
| `bool_literal` | `bool` | `a.bool_literal == b.bool_literal` |
| `null_literal` | `void` | `true` (both are null; no payload to compare) |

**Note on `float_literal`:** Bitwise equality (`==`) is used, not an epsilon comparison.
The goal is structural identity — two parses of the same source string produce the same
`f64` bit pattern because they go through the same `std.fmt.parseFloat` call path.
An epsilon tolerance would incorrectly treat structurally different trees as equal if
two distinct float literals happened to be close in value.

### 5.6 `string_literal` — slice comparison

```
Variant:  string_literal: []const u8
```

String slices are views into the source buffer (zero-copy). Two independent parse runs
may produce slices that point to different memory addresses but contain the same bytes.
Pointer equality (`a.string_literal.ptr == b.string_literal.ptr`) is therefore insufficient.

**Rule:** Use `std.mem.eql(u8, a.string_literal, b.string_literal)`.

This compares length first (O(1) fast-path) and then byte-by-byte content. It is correct for
all UTF-8 source strings and does not require the slices to be null-terminated.

### 5.7 `dot_path` — segment-by-segment comparison

```
Variant:  dot_path: [][]const u8
```

Each element of the outer slice is an identifier segment (e.g., `["order", "total"]` for
`order.total`). Slices are owned by the arena and may reside at different addresses across
two parse runs.

**Rule:**

1. If `a.dot_path.len != b.dot_path.len` → return `false`.
2. For each index `i` in `0..a.dot_path.len`: if `!std.mem.eql(u8, a.dot_path[i], b.dot_path[i])` → return `false`.
3. Return `true`.

Each segment is compared with `std.mem.eql(u8, ...)` for the same reason as `string_literal`.

### 5.8 `func_call` — name + recursive argument comparison

```
Variant:  func_call: struct { name: []const u8, args: []*Node }
```

**Rule:**

1. Compare function name: `std.mem.eql(u8, a.func_call.name, b.func_call.name)`.
   Names are slices into source; the same reasoning as `string_literal` applies.
2. If `a.func_call.args.len != b.func_call.args.len` → return `false`.
3. For each index `i` in `0..a.func_call.args.len`: if `!nodeEql(a.func_call.args[i], b.func_call.args[i])` → return `false`.
4. Return `true`.

Arguments are compared in order. Argument order is fixed by the grammar (left-to-right),
so the same source always produces arguments in the same order.

---

## 6. Complete Variant Coverage Checklist

| # | Variant | Handling section | Leaf? |
|---|---|---|---|
| 1 | `or_expr` | §5.1 | No |
| 2 | `and_expr` | §5.1 | No |
| 3 | `not_expr` | §5.4 | No |
| 4 | `cmp_expr` | §5.2 | No |
| 5 | `add_expr` | §5.3 | No |
| 6 | `mul_expr` | §5.3 | No |
| 7 | `unary_neg` | §5.4 | No |
| 8 | `int_literal` | §5.5 | Yes |
| 9 | `float_literal` | §5.5 | Yes |
| 10 | `string_literal` | §5.6 | Yes |
| 11 | `bool_literal` | §5.5 | Yes |
| 12 | `null_literal` | §5.5 | Yes |
| 13 | `dot_path` | §5.7 | Yes |
| 14 | `func_call` | §5.8 | No |

All 14 variants are covered. The `switch` in the implementation MUST be exhaustive (no `else`
branch). If a new variant is added to `Node` in the future, the Zig compiler will emit a
compile error at the `switch` statement, forcing the implementor to add a case.

---

## 7. Helper Function

No separate helper function is required. All logic fits directly inside the `switch` arms of
`nodeEql`. Inlining keeps the implementation compact and avoids the overhead of additional
stack frames for the simple scalar cases.

---

## 8. Test Strategy (for BACKEND-DEV / TEST-DESIGNER reference)

The acceptance criterion for DSL-02 is:

> Parsing the same input string twice and calling `nodeEql(ast1.root, ast2.root)` returns `true`.

The recommended test pattern:

```
test "DSL-02: double-parse AST stability" {
    const inputs = [_][]const u8{
        "1 + 2",
        "a.b.c == null",
        "not (x > 0 and y < 100)",
        "round(order.total * 1.1, 2)",
        "true or false",
    };
    for (inputs) |src| {
        var ast1 = try parse(src);
        defer ast1.deinit();
        var ast2 = try parse(src);
        defer ast2.deinit();
        try std.testing.expect(ast.nodeEql(ast1.root, ast2.root));
    }
}
```

Each input exercises a distinct set of Node variants, ensuring full coverage.

---

## 9. Constraints and Non-Goals

- `nodeEql` does NOT compare source positions (`line`, `column` from `Token`). Those fields are
  not stored in `Node` — the AST is already position-free, which simplifies the equality check.
- `nodeEql` does NOT check allocator identity or pointer identity.
- `nodeEql` is NOT an evaluation equivalence check. Two trees are equal if and only if they
  have the same shape and the same literal values, regardless of mathematical equivalence
  (e.g., `1 + 2` and `3` are NOT equal under `nodeEql`).
- `nodeEql` is NOT threadsafe (it reads shared tree nodes). Callers that share trees across
  threads must provide their own synchronisation. This is not a practical concern for tests.

---

## 10. File Placement Summary

| Artefact | Path |
|---|---|
| Design document (this file) | `src/design/dsl-02-ast-stability.md` |
| Implementation target | `src/expr/ast.zig` (append `nodeEql` below the `Ast` struct) |
| Test file (BACKEND-DEV to create or extend) | `src/expr/ast_test.zig` or inline `test` block in `ast.zig` |
