# Test Spec: DSL-01 — Grammar Conformance

**Requirement:** DSL-01 — The DSL parser MUST accept all expressions conforming to the grammar defined in Architecture §5.1 and MUST reject all others with structured error messages including line and column number.  
**Priority:** MUST  
**Test layer:** unit

---

## Overview

This spec covers two acceptance criteria from DSL-01:

1. **AC-1** — For each grammar production, at least one positive test and one negative test exists.
2. **AC-2** — Rejection messages include the line number, column number, and the offending token (`ParseError.line`, `ParseError.column`, `ParseError.token`).

Grammar productions covered (nine in total):

| # | Production |
|---|---|
| 1 | `or_expr` |
| 2 | `and_expr` |
| 3 | `not_expr` |
| 4 | `cmp_expr` |
| 5 | `add_expr` |
| 6 | `mul_expr` |
| 7 | `unary` |
| 8 | `primary` (number, string, bool, null, identifier/dot-path, grouped) |
| 9 | `func_call` |

Integration-level cases appended in §3.

All tests are backend unit tests executed via `zig build test-expr` (or `zig build test`).  
No database, no I/O. Test file: `tests/unit/expr_parser_test.zig`.  
Entry point: `src/expr/mod.zig::parse(allocator, source)` returning `ParseResult` (`.ok` / `.fail`).

---

## Test Cases

### Section 1: Grammar Productions — Positive Cases

---

#### TC-DSL01-001: or_expr — binary `or`

**Given:** allocator is initialised  
**When:** `parse(alloc, "true or false")` is called  
**Then:**
- result is `.ok`
- `result.ok.root.*` is `.or_expr`
- left child is `.bool_literal` `true`, right child is `.bool_literal` `false`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (or_expr positive)

---

#### TC-DSL01-002: or_expr — chained `or` (left-associative)

**Given:** allocator is initialised  
**When:** `parse(alloc, "a or b or c")` is called  
**Then:**
- result is `.ok`
- root is `.or_expr`; its left child is also `.or_expr` (left-associativity)

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (or_expr positive, multi-operand)

---

#### TC-DSL01-003: and_expr — binary `and`

**Given:** allocator is initialised  
**When:** `parse(alloc, "true and false")` is called  
**Then:**
- result is `.ok`
- `result.ok.root.*` is `.and_expr`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (and_expr positive)

---

#### TC-DSL01-004: and_expr — chained `and`

**Given:** allocator is initialised  
**When:** `parse(alloc, "a and b and c")` is called  
**Then:**
- result is `.ok`
- root is `.and_expr`; left child is `.and_expr` (left-associativity)

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (and_expr positive, multi-operand)

---

#### TC-DSL01-005: not_expr — prefix `not`

**Given:** allocator is initialised  
**When:** `parse(alloc, "not true")` is called  
**Then:**
- result is `.ok`
- `result.ok.root.*` is `.not_expr`
- operand is `.bool_literal` `true`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (not_expr positive)

---

#### TC-DSL01-006: not_expr — `not` applied to comparison

**Given:** allocator is initialised  
**When:** `parse(alloc, "not x == 0")` is called  
**Then:**
- result is `.ok`
- root is `.not_expr`; operand is `.cmp_expr` with op `.eq`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (not_expr wraps cmp_expr)

---

#### TC-DSL01-007: cmp_expr — equality `==`

**Given:** allocator is initialised  
**When:** `parse(alloc, "42 == 42")` is called  
**Then:**
- result is `.ok`
- root is `.cmp_expr` with `op == .eq`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (cmp_expr positive, `==`)

---

#### TC-DSL01-008: cmp_expr — all six operators

**Given:** allocator is initialised  
**When:** each of the following is parsed individually:
- `"1 != 2"` → op `.neq`
- `"1 < 2"` → op `.lt`
- `"1 <= 2"` → op `.lte`
- `"1 > 2"` → op `.gt`
- `"1 >= 2"` → op `.gte`

**Then:** each result is `.ok` with `.cmp_expr` carrying the matching `CmpOp` variant

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (cmp_expr positive, all operators)

---

#### TC-DSL01-009: add_expr — addition `+`

**Given:** allocator is initialised  
**When:** `parse(alloc, "1 + 2")` is called  
**Then:**
- result is `.ok`
- root is `.add_expr` with `op == .add`
- left child `.int_literal` 1, right child `.int_literal` 2

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (add_expr positive, `+`)

---

#### TC-DSL01-010: add_expr — subtraction `-`

**Given:** allocator is initialised  
**When:** `parse(alloc, "10 - 3")` is called  
**Then:**
- result is `.ok`
- root is `.add_expr` with `op == .sub`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (add_expr positive, `-`)

---

#### TC-DSL01-011: add_expr — chained additions (left-associativity)

**Given:** allocator is initialised  
**When:** `parse(alloc, "1 + 2 + 3")` is called  
**Then:**
- result is `.ok`
- root is `.add_expr`; left child is `.add_expr` (left-associativity)

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (add_expr left-associative)

---

#### TC-DSL01-012: mul_expr — multiplication `*`

**Given:** allocator is initialised  
**When:** `parse(alloc, "2 * 3")` is called  
**Then:**
- result is `.ok`
- root is `.mul_expr` with `op == .mul`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (mul_expr positive, `*`)

---

#### TC-DSL01-013: mul_expr — division `/`

**Given:** allocator is initialised  
**When:** `parse(alloc, "10 / 2")` is called  
**Then:**
- result is `.ok`
- root is `.mul_expr` with `op == .div`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (mul_expr positive, `/`)

---

#### TC-DSL01-014: mul_expr — modulo `%`

**Given:** allocator is initialised  
**When:** `parse(alloc, "7 % 3")` is called  
**Then:**
- result is `.ok`
- root is `.mul_expr` with `op == .mod`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (mul_expr positive, `%`)

---

#### TC-DSL01-015: unary — numeric negation `-`

**Given:** allocator is initialised  
**When:** `parse(alloc, "-5")` is called  
**Then:**
- result is `.ok`
- root is `.unary_neg`
- operand is `.int_literal` 5

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (unary positive)

---

#### TC-DSL01-016: unary — negation applied to float

**Given:** allocator is initialised  
**When:** `parse(alloc, "-3.14")` is called  
**Then:**
- result is `.ok`
- root is `.unary_neg`; operand is `.float_literal`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (unary positive, float operand)

---

#### TC-DSL01-017: primary — integer literal

**Given:** allocator is initialised  
**When:** `parse(alloc, "42")` is called  
**Then:**
- result is `.ok`
- root is `.int_literal` with value 42

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, integer)

---

#### TC-DSL01-018: primary — float literal

**Given:** allocator is initialised  
**When:** `parse(alloc, "3.14")` is called  
**Then:**
- result is `.ok`
- root is `.float_literal`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, float)

---

#### TC-DSL01-019: primary — string literal

**Given:** allocator is initialised  
**When:** `parse(alloc, "\"hello\"")` is called  
**Then:**
- result is `.ok`
- root is `.string_literal` with inner value `hello` (quotes stripped)

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, string)

---

#### TC-DSL01-020: primary — boolean `true`

**Given:** allocator is initialised  
**When:** `parse(alloc, "true")` is called  
**Then:**
- result is `.ok`
- root is `.bool_literal` `true`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, bool true)

---

#### TC-DSL01-021: primary — boolean `false`

**Given:** allocator is initialised  
**When:** `parse(alloc, "false")` is called  
**Then:**
- result is `.ok`
- root is `.bool_literal` `false`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, bool false)

---

#### TC-DSL01-022: primary — null literal

**Given:** allocator is initialised  
**When:** `parse(alloc, "null")` is called  
**Then:**
- result is `.ok`
- root is `.null_literal`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, null)

---

#### TC-DSL01-023: primary — single identifier as dot-path

**Given:** allocator is initialised  
**When:** `parse(alloc, "amount")` is called  
**Then:**
- result is `.ok`
- root is `.dot_path` with `len == 1`, segments[0] == `"amount"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, single-segment identifier)

---

#### TC-DSL01-024: primary — two-segment dot-path

**Given:** allocator is initialised  
**When:** `parse(alloc, "order.total")` is called  
**Then:**
- result is `.ok`
- root is `.dot_path` with `len == 2`
- segments[0] == `"order"`, segments[1] == `"total"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, dot-path)

---

#### TC-DSL01-025: primary — grouped expression `(expr)`

**Given:** allocator is initialised  
**When:** `parse(alloc, "(1 + 2) * 3")` is called  
**Then:**
- result is `.ok`
- root is `.mul_expr`
- left child of mul_expr is `.add_expr` (grouping forced precedence)

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary positive, grouped)

---

#### TC-DSL01-026: func_call — zero-argument call

**Given:** allocator is initialised  
**When:** `parse(alloc, "now()")` is called  
**Then:**
- result is `.ok`
- root is `.func_call` with `name == "now"` and `args.len == 0`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (func_call positive, zero args)

---

#### TC-DSL01-027: func_call — single-argument call

**Given:** allocator is initialised  
**When:** `parse(alloc, "length(name)")` is called  
**Then:**
- result is `.ok`
- root is `.func_call` with `name == "length"` and `args.len == 1`
- first arg is `.dot_path` with segments `["name"]`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (func_call positive, one arg)

---

#### TC-DSL01-028: func_call — two-argument call

**Given:** allocator is initialised  
**When:** `parse(alloc, "date_add(ts, 7)")` is called  
**Then:**
- result is `.ok`
- root is `.func_call` with `name == "date_add"` and `args.len == 2`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (func_call positive, two args)

---

### Section 2: Grammar Productions — Negative Cases

Each negative case must verify `ParseError.line`, `ParseError.column`, and `ParseError.token` are populated.

---

#### TC-DSL01-101: or_expr — trailing `or` with no right operand

**Given:** allocator is initialised  
**When:** `parse(alloc, "true or")` is called  
**Then:**
- result is `.fail`
- `errors.len >= 1`
- `errors[0].line == 1`
- `errors[0].column == 8` (column of the EOF token that follows `or`)
- `errors[0].token` is `""` (the EOF lexeme)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (or_expr negative), AC-2 (line, column, token present)

---

#### TC-DSL01-102: and_expr — trailing `and` with no right operand

**Given:** allocator is initialised  
**When:** `parse(alloc, "true and")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 9`
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (and_expr negative), AC-2

---

#### TC-DSL01-103: not_expr — bare `not` with no operand

**Given:** allocator is initialised  
**When:** `parse(alloc, "not")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 4` (EOF follows immediately after `not`)
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (not_expr negative), AC-2

---

#### TC-DSL01-104: cmp_expr — comparison operator with no right-hand side

**Given:** allocator is initialised  
**When:** `parse(alloc, "42 ==")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 6` (EOF after `==`)
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (cmp_expr negative), AC-2

---

#### TC-DSL01-105: add_expr — trailing `+` with no right operand

**Given:** allocator is initialised  
**When:** `parse(alloc, "1 +")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 4`
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (add_expr negative), AC-2

---

#### TC-DSL01-106: mul_expr — trailing `*` with no right operand

**Given:** allocator is initialised  
**When:** `parse(alloc, "2 *")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 4`
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (mul_expr negative), AC-2

---

#### TC-DSL01-107: unary — lone minus with no operand

**Given:** allocator is initialised  
**When:** `parse(alloc, "-")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 2` (EOF after `-`)
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (unary negative), AC-2

---

#### TC-DSL01-108: primary — empty source (no tokens)

**Given:** allocator is initialised  
**When:** `parse(alloc, "")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 1`
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected expression"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary negative, empty input), AC-2

---

#### TC-DSL01-109: primary — unclosed parenthesis

**Given:** allocator is initialised  
**When:** `parse(alloc, "(1 + 2")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 7` (EOF where `)` was expected)
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected ')'"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary grouped negative), AC-2

---

#### TC-DSL01-110: primary — unterminated string literal

**Given:** allocator is initialised  
**When:** `parse(alloc, "\"hello")` is called (no closing quote)  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 1` (opening quote position)
- `errors[0].token` starts with `"` (the partial string lexeme)
- `errors[0].message` contains `"unterminated string literal"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary string negative), AC-2

---

#### TC-DSL01-111: primary — unknown character

**Given:** allocator is initialised  
**When:** `parse(alloc, "@x")` is called (`@` is not a valid DSL character)  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 1`
- `errors[0].token == "@"`
- `errors[0].message` contains `"unexpected character"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary negative, illegal char), AC-2

---

#### TC-DSL01-112: primary — dot-path trailing dot

**Given:** allocator is initialised  
**When:** `parse(alloc, "order.")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 7` (EOF after the dot)
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected identifier after '.'"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (dot-path negative), AC-2

---

#### TC-DSL01-113: func_call — unknown function name rejected

**Given:** allocator is initialised  
**When:** `parse(alloc, "bogus(42)")` is called (`bogus` is not in the whitelist)  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 1` (start of `bogus`)
- `errors[0].token == "bogus"`
- `errors[0].message` contains `"unknown function"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (func_call negative, unlisted name), AC-2

---

#### TC-DSL01-114: func_call — missing closing parenthesis

**Given:** allocator is initialised  
**When:** `parse(alloc, "length(name")` is called (no closing `)`)  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 12` (EOF position)
- `errors[0].token` is `""` (EOF)
- `errors[0].message` contains `"expected ')'"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (func_call negative, unclosed call), AC-2

---

### Section 3: Built-in Function Coverage

All 11 whitelisted built-ins must parse successfully. Each is lexed as `TokenKind.builtin_func` and produces a `.func_call` node.

---

#### TC-DSL01-201: built-in `length`

**Given:** allocator is initialised  
**When:** `parse(alloc, "length(name)")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "length"`; `args.len == 1`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (func_call positive), built-in whitelist coverage

---

#### TC-DSL01-202: built-in `lower`

**Given:** allocator is initialised  
**When:** `parse(alloc, "lower(name)")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "lower"`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-203: built-in `upper`

**Given:** allocator is initialised  
**When:** `parse(alloc, "upper(name)")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "upper"`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-204: built-in `trim`

**Given:** allocator is initialised  
**When:** `parse(alloc, "trim(field)")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "trim"`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-205: built-in `contains`

**Given:** allocator is initialised  
**When:** `parse(alloc, "contains(tags, \"admin\")")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "contains"` and `args.len == 2`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-206: built-in `startsWith`

**Given:** allocator is initialised  
**When:** `parse(alloc, "startsWith(code, \"ERR\")")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "startsWith"` and `args.len == 2`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-207: built-in `endsWith`

**Given:** allocator is initialised  
**When:** `parse(alloc, "endsWith(filename, \".pdf\")")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "endsWith"` and `args.len == 2`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-208: built-in `coalesce`

**Given:** allocator is initialised  
**When:** `parse(alloc, "coalesce(value, 0)")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "coalesce"` and `args.len == 2`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-209: built-in `now`

**Given:** allocator is initialised  
**When:** `parse(alloc, "now()")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "now"` and `args.len == 0`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-210: built-in `date_add`

**Given:** allocator is initialised  
**When:** `parse(alloc, "date_add(due_date, 7)")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "date_add"` and `args.len == 2`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

#### TC-DSL01-211: built-in `date_diff`

**Given:** allocator is initialised  
**When:** `parse(alloc, "date_diff(end_date, start_date)")` is called  
**Then:** result is `.ok`; root is `.func_call` with `name == "date_diff"` and `args.len == 2`

**Layer:** unit  
**Acceptance criterion mapped:** built-in whitelist coverage

---

### Section 4: Non-Whitelisted Function Name Rejection

---

#### TC-DSL01-301: non-whitelisted function `exec` is rejected

**Given:** allocator is initialised  
**When:** `parse(alloc, "exec(cmd)")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 1`
- `errors[0].token == "exec"`
- `errors[0].message` contains `"unknown function"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (func_call negative, non-whitelisted), AC-2

---

#### TC-DSL01-302: non-whitelisted function `printf` is rejected

**Given:** allocator is initialised  
**When:** `parse(alloc, "printf(\"hello\")")` is called  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 1`
- `errors[0].token == "printf"`
- `errors[0].message` contains `"unknown function"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-2 (non-whitelisted negative, second example)

---

#### TC-DSL01-303: function name that is a prefix of a valid built-in (`len`) is rejected

**Given:** allocator is initialised  
**When:** `parse(alloc, "len(x)")` is called  
**Then:**
- result is `.fail`
- `errors[0].token == "len"`
- `errors[0].message` contains `"unknown function"`

**Layer:** unit  
**Acceptance criterion mapped:** exact-match whitelist check (no prefix matching)

---

### Section 5: Integration-Level Cases

---

#### TC-DSL01-401: compound gateway condition expression

**Given:** allocator is initialised  
**When:** `parse(alloc, "order.total > 10000 and customer.tier == \"VIP\"")` is called  
**Then:**
- result is `.ok`
- root is `.and_expr`
- left child is `.cmp_expr` with `op == .gt`; its left is `.dot_path` `["order", "total"]` and right is `.int_literal` 10000
- right child is `.cmp_expr` with `op == .eq`; its left is `.dot_path` `["customer", "tier"]` and right is `.string_literal` `"VIP"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (compound expression; covers or_expr, and_expr, cmp_expr, add_expr, primary dot-path, primary string)

---

#### TC-DSL01-402: compound gateway condition with `or` at top level

**Given:** allocator is initialised  
**When:** `parse(alloc, "status == \"APPROVED\" or (amount < 100 and auto_approve == true)")` is called  
**Then:**
- result is `.ok`
- root is `.or_expr`
- right child has root `.and_expr` (parentheses forced grouping)

**Layer:** unit  
**Acceptance criterion mapped:** or_expr, and_expr, cmp_expr, grouped, string/bool literals

---

#### TC-DSL01-403: deeply nested dot-path `a.b.c.d`

**Given:** allocator is initialised  
**When:** `parse(alloc, "a.b.c.d")` is called  
**Then:**
- result is `.ok`
- root is `.dot_path` with `len == 4`
- segments are `["a", "b", "c", "d"]` in order

**Layer:** unit  
**Acceptance criterion mapped:** AC-1 (primary dot-path, deep nesting)

---

#### TC-DSL01-404: deeply nested dot-path used in comparison

**Given:** allocator is initialised  
**When:** `parse(alloc, "order.customer.address.country == \"DE\"")` is called  
**Then:**
- result is `.ok`
- root is `.cmp_expr` with `op == .eq`
- left is `.dot_path` with `len == 4`
- right is `.string_literal` `"DE"`

**Layer:** unit  
**Acceptance criterion mapped:** deep dot-path in real-world expression

---

#### TC-DSL01-405: arithmetic precedence — `*` binds tighter than `+`

**Given:** allocator is initialised  
**When:** `parse(alloc, "2 + 3 * 4")` is called  
**Then:**
- result is `.ok`
- root is `.add_expr`
- right child is `.mul_expr` (not `add_expr`), confirming correct precedence

**Layer:** unit  
**Acceptance criterion mapped:** mul_expr precedence over add_expr

---

#### TC-DSL01-406: `and` binds tighter than `or`

**Given:** allocator is initialised  
**When:** `parse(alloc, "a or b and c")` is called  
**Then:**
- result is `.ok`
- root is `.or_expr`
- right child is `.and_expr` (confirming `and` has higher precedence than `or`)

**Layer:** unit  
**Acceptance criterion mapped:** or_expr / and_expr precedence

---

#### TC-DSL01-407: `not` binds tighter than `and`

**Given:** allocator is initialised  
**When:** `parse(alloc, "not a and b")` is called  
**Then:**
- result is `.ok`
- root is `.and_expr`
- left child is `.not_expr` (confirming `not` binds to just `a`, not the whole `and`)

**Layer:** unit  
**Acceptance criterion mapped:** not_expr / and_expr precedence

---

#### TC-DSL01-408: error recovery — two unknown functions in one expression

**Given:** allocator is initialised  
**When:** `parse(alloc, "bogus(1) and unknown(2)")` is called  
**Then:**
- result is `.fail`
- `errors.len >= 2` (parser recovered after first error and found the second)
- `errors[0].token == "bogus"`, `errors[0].line == 1`, `errors[0].column == 1`
- `errors[1].token == "unknown"`, `errors[1].line == 1`, `errors[1].column > 1`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 multi-error recovery; AC-2 for both errors

---

### Section 6: Additional Error-Format Verification

These cases explicitly confirm all three required fields (`line`, `column`, `token`) in ParseError are non-default for non-EOF errors.

---

#### TC-DSL01-501: multi-line expression — error on line 2

**Given:** allocator is initialised  
**When:** `parse(alloc, "true and\nnot")` is called (valid `and` on line 1, then `not` with no operand on line 2)  
**Then:**
- result is `.fail`
- `errors[0].line == 2` (error occurs on the second line)
- `errors[0].column == 4` (EOF at column 4 of line 2)
- `errors[0].token` is `""` (EOF)

**Layer:** unit  
**Acceptance criterion mapped:** AC-2 (line tracking across newlines)

---

#### TC-DSL01-502: error column accurately tracks whitespace offset

**Given:** allocator is initialised  
**When:** `parse(alloc, "   @x")` is called (three leading spaces before `@`)  
**Then:**
- result is `.fail`
- `errors[0].line == 1`
- `errors[0].column == 4` (the `@` is at column 4, after three spaces)
- `errors[0].token == "@"`

**Layer:** unit  
**Acceptance criterion mapped:** AC-2 (column accuracy with leading whitespace)

---

## Summary Table

| ID | Description | Positive / Negative | Production covered | AC |
|---|---|---|---|---|
| TC-DSL01-001 | `true or false` | Positive | or_expr | AC-1 |
| TC-DSL01-002 | `a or b or c` | Positive | or_expr (chained) | AC-1 |
| TC-DSL01-003 | `true and false` | Positive | and_expr | AC-1 |
| TC-DSL01-004 | `a and b and c` | Positive | and_expr (chained) | AC-1 |
| TC-DSL01-005 | `not true` | Positive | not_expr | AC-1 |
| TC-DSL01-006 | `not x == 0` | Positive | not_expr wraps cmp | AC-1 |
| TC-DSL01-007 | `42 == 42` | Positive | cmp_expr (==) | AC-1 |
| TC-DSL01-008 | all six cmp operators | Positive | cmp_expr (all ops) | AC-1 |
| TC-DSL01-009 | `1 + 2` | Positive | add_expr (+) | AC-1 |
| TC-DSL01-010 | `10 - 3` | Positive | add_expr (-) | AC-1 |
| TC-DSL01-011 | `1 + 2 + 3` | Positive | add_expr (chained) | AC-1 |
| TC-DSL01-012 | `2 * 3` | Positive | mul_expr (*) | AC-1 |
| TC-DSL01-013 | `10 / 2` | Positive | mul_expr (/) | AC-1 |
| TC-DSL01-014 | `7 % 3` | Positive | mul_expr (%) | AC-1 |
| TC-DSL01-015 | `-5` | Positive | unary (int) | AC-1 |
| TC-DSL01-016 | `-3.14` | Positive | unary (float) | AC-1 |
| TC-DSL01-017 | `42` | Positive | primary int | AC-1 |
| TC-DSL01-018 | `3.14` | Positive | primary float | AC-1 |
| TC-DSL01-019 | `"hello"` | Positive | primary string | AC-1 |
| TC-DSL01-020 | `true` | Positive | primary bool true | AC-1 |
| TC-DSL01-021 | `false` | Positive | primary bool false | AC-1 |
| TC-DSL01-022 | `null` | Positive | primary null | AC-1 |
| TC-DSL01-023 | `amount` | Positive | primary identifier | AC-1 |
| TC-DSL01-024 | `order.total` | Positive | primary dot-path | AC-1 |
| TC-DSL01-025 | `(1 + 2) * 3` | Positive | primary grouped | AC-1 |
| TC-DSL01-026 | `now()` | Positive | func_call (0 args) | AC-1 |
| TC-DSL01-027 | `length(name)` | Positive | func_call (1 arg) | AC-1 |
| TC-DSL01-028 | `date_add(ts, 7)` | Positive | func_call (2 args) | AC-1 |
| TC-DSL01-101 | `true or` | Negative | or_expr | AC-1, AC-2 |
| TC-DSL01-102 | `true and` | Negative | and_expr | AC-1, AC-2 |
| TC-DSL01-103 | `not` | Negative | not_expr | AC-1, AC-2 |
| TC-DSL01-104 | `42 ==` | Negative | cmp_expr | AC-1, AC-2 |
| TC-DSL01-105 | `1 +` | Negative | add_expr | AC-1, AC-2 |
| TC-DSL01-106 | `2 *` | Negative | mul_expr | AC-1, AC-2 |
| TC-DSL01-107 | `-` | Negative | unary | AC-1, AC-2 |
| TC-DSL01-108 | empty string | Negative | primary (empty) | AC-1, AC-2 |
| TC-DSL01-109 | `(1 + 2` | Negative | primary grouped | AC-1, AC-2 |
| TC-DSL01-110 | `"hello` (unterminated) | Negative | primary string | AC-1, AC-2 |
| TC-DSL01-111 | `@x` | Negative | primary (illegal char) | AC-1, AC-2 |
| TC-DSL01-112 | `order.` | Negative | primary dot-path | AC-1, AC-2 |
| TC-DSL01-113 | `bogus(42)` | Negative | func_call (unknown) | AC-1, AC-2 |
| TC-DSL01-114 | `length(name` | Negative | func_call (unclosed) | AC-1, AC-2 |
| TC-DSL01-201 | `length(name)` | Positive | built-in: length | built-in coverage |
| TC-DSL01-202 | `lower(name)` | Positive | built-in: lower | built-in coverage |
| TC-DSL01-203 | `upper(name)` | Positive | built-in: upper | built-in coverage |
| TC-DSL01-204 | `trim(field)` | Positive | built-in: trim | built-in coverage |
| TC-DSL01-205 | `contains(tags, "admin")` | Positive | built-in: contains | built-in coverage |
| TC-DSL01-206 | `startsWith(code, "ERR")` | Positive | built-in: startsWith | built-in coverage |
| TC-DSL01-207 | `endsWith(filename, ".pdf")` | Positive | built-in: endsWith | built-in coverage |
| TC-DSL01-208 | `coalesce(value, 0)` | Positive | built-in: coalesce | built-in coverage |
| TC-DSL01-209 | `now()` | Positive | built-in: now | built-in coverage |
| TC-DSL01-210 | `date_add(due_date, 7)` | Positive | built-in: date_add | built-in coverage |
| TC-DSL01-211 | `date_diff(end_date, start_date)` | Positive | built-in: date_diff | built-in coverage |
| TC-DSL01-301 | `exec(cmd)` | Negative | non-whitelisted func | AC-1, AC-2 |
| TC-DSL01-302 | `printf("hello")` | Negative | non-whitelisted func | AC-2 |
| TC-DSL01-303 | `len(x)` | Negative | whitelist exact-match | built-in coverage |
| TC-DSL01-401 | compound gateway condition | Positive | integration (and, cmp, dot-path) | AC-1 |
| TC-DSL01-402 | compound with `or` at top | Positive | integration (or, and, grouped) | AC-1 |
| TC-DSL01-403 | `a.b.c.d` | Positive | deep dot-path | AC-1 |
| TC-DSL01-404 | deep dot-path in cmp | Positive | deep dot-path in context | AC-1 |
| TC-DSL01-405 | `2 + 3 * 4` precedence | Positive | mul > add precedence | AC-1 |
| TC-DSL01-406 | `a or b and c` precedence | Positive | and > or precedence | AC-1 |
| TC-DSL01-407 | `not a and b` precedence | Positive | not > and precedence | AC-1 |
| TC-DSL01-408 | two unknown funcs (recovery) | Negative | multi-error recovery | AC-2 |
| TC-DSL01-501 | error on line 2 | Negative | multi-line line tracking | AC-2 |
| TC-DSL01-502 | whitespace offset column | Negative | column accuracy | AC-2 |

**Total positive cases:** 38 (including 11 built-in coverage cases)  
**Total negative cases:** 18  
**Productions covered with ≥1 positive + ≥1 negative:** 9/9

---

## Implementation Notes for TEST-RUNNER

### Test file

Create `tests/unit/expr_parser_test.zig`. Import via:

```zig
const std = @import("std");
const testing = std.testing;
const expr = @import("../../src/expr/mod.zig");
```

### ParseResult handling pattern

```zig
var result = try expr.parse(alloc, "<source>");
defer switch (result) {
    .ok  => |*a| a.deinit(),
    .fail => |e| alloc.free(e),
};
try testing.expect(result == .ok); // or .fail
```

### Failure field assertions

```zig
const errs = result.fail;
try testing.expect(errs.len >= 1);
try testing.expectEqual(@as(u32, 1), errs[0].line);
try testing.expectEqual(@as(u32, 4), errs[0].column);
try testing.expectEqualStrings("", errs[0].token);
```

### Column calculation reference

The lexer sets `column` to `pos - line_start + 1` (1-based). EOF token column is one past the last character. Whitespace is skipped before `col` is calculated, so tabs count as single characters.

### Registration command

```bash
zig build test-expr
```

(or add `expr_parser_test.zig` to the build step for the `expr` module under `zig build test`)
