# Test Spec: DSL-11 — Dot-Path Traversal (Nested Object Traversal)

**Requirement:** DSL-11 — Dot-path traversal enables expressions to navigate nested JSON objects. Multi-segment paths like `a.b.c` MUST traverse through nested structures by parsing JSON at each level. Null-propagation MUST return `null` without error for missing fields, null intermediates, or type mismatches at any nesting level.

**Priority:** MUST  
**Test layer:** unit

---

## Test Strategy

All DSL-11 tests are executed at the unit layer (pure Zig tests, no database, no I/O). Dot-path traversal is a pure operation: given an explicit context map and a dot-path expression, evaluation always produces the same result. These tests verify:

1. **Simple and nested path resolution** — two-level paths (`a.b`) up to deeply nested paths (5+ levels)
2. **Null-propagation** — when any segment in the path is `null` or missing, the entire path returns `null` without error
3. **Mixed types** — extracting scalar values (int, float, bool, string) from JSON objects, and handling objects/arrays as JSON strings
4. **Error avoidance** — malformed JSON, missing fields, and scalar traversal attempts all return `null` gracefully
5. **Type coercion** — JSON values converted correctly to DSL Value types (integration with DSL-05)
6. **Integration with DSL-10** — dot-path builds on identifier resolution; single-segment paths continue to work as before

**Test environment:** Pure Zig unit tests, no database required, no I/O. Tests run via `zig build test`.

**Key design invariants verified:**
- Root identifier resolution follows DSL-10 rules (case-sensitive, unresolved → null)
- Single-segment paths (`x`) return the context value unchanged (backward compatible with DSL-10)
- Multi-segment paths require JSON parsing of intermediate values
- Null at any level (root, intermediate, or field) propagates to the final result without error
- Missing fields in JSON objects return `null`, not an error
- Non-object intermediate types (scalars) cannot be traversed further; return `null`
- Nested objects and arrays are re-serialized to JSON strings for further traversal
- Malformed JSON in intermediate values gracefully returns `null`
- JSON values extracted from objects are converted to appropriate DSL Value types

---

## Coverage Matrix

| Category | Test Cases | Layer |
|---|---|---|
| **Basic traversal** | | |
| Single-segment path (DSL-10 compat) | TC-DSL-11-01 | unit |
| Two-level path (simple nesting) | TC-DSL-11-02 | unit |
| Three-level path (intermediate JSON) | TC-DSL-11-03 | unit |
| Four-level path (deep nesting) | TC-DSL-11-04 | unit |
| Five-level path (very deep nesting) | TC-DSL-11-05 | unit |
| **Null propagation — root level** | | |
| Root identifier missing from context | TC-DSL-11-06 | unit |
| Root identifier is null in context | TC-DSL-11-07 | unit |
| Root identifier missing, multi-segment path | TC-DSL-11-08 | unit |
| **Null propagation — intermediate levels** | | |
| First intermediate field is null | TC-DSL-11-09 | unit |
| Second intermediate field is null | TC-DSL-11-10 | unit |
| Third intermediate field is null | TC-DSL-11-11 | unit |
| Null at each nesting level (exhaustive) | TC-DSL-11-12 | unit |
| **Null propagation — missing fields** | | |
| Missing field at first level | TC-DSL-11-13 | unit |
| Missing field at second level | TC-DSL-11-14 | unit |
| Missing field at third level | TC-DSL-11-15 | unit |
| **Type handling — scalars in path** | | |
| Root is int64, attempt multi-segment path | TC-DSL-11-16 | unit |
| Root is float64, attempt traversal | TC-DSL-11-17 | unit |
| Root is bool, attempt traversal | TC-DSL-11-18 | unit |
| Intermediate is scalar (non-JSON), further traversal | TC-DSL-11-19 | unit |
| **Mixed types in JSON — successful extraction** | | |
| Extract int64 from nested object | TC-DSL-11-20 | unit |
| Extract float64 from nested object | TC-DSL-11-21 | unit |
| Extract bool from nested object | TC-DSL-11-22 | unit |
| Extract string from nested object | TC-DSL-11-23 | unit |
| **Nested structures — objects and arrays** | | |
| Extract nested object (returned as JSON string) | TC-DSL-11-24 | unit |
| Extract array from object (returned as JSON string) | TC-DSL-11-25 | unit |
| Attempt to index array with field name (no numeric indexing) | TC-DSL-11-26 | unit |
| Nested object within array (cannot access via field name) | TC-DSL-11-27 | unit |
| **Error cases — graceful handling** | | |
| Malformed JSON in intermediate | TC-DSL-11-28 | unit |
| Invalid JSON string (missing quotes, braces) | TC-DSL-11-29 | unit |
| Attempt traversal on partially invalid JSON | TC-DSL-11-30 | unit |
| **Type coercion from JSON** | | |
| JSON int coerces to DSL int64 | TC-DSL-11-31 | unit |
| JSON float coerces to DSL float64 | TC-DSL-11-32 | unit |
| JSON bool coerces to DSL bool | TC-DSL-11-33 | unit |
| JSON string stays as DSL string | TC-DSL-11-34 | unit |
| JSON null becomes DSL null_val | TC-DSL-11-35 | unit |
| **Edge cases** | | |
| Empty path segments (defensive) | TC-DSL-11-36 | unit |
| Very deeply nested (6+ levels) | TC-DSL-11-37 | unit |
| Unicode field names and values | TC-DSL-11-38 | unit |
| Large JSON object traversal | TC-DSL-11-39 | unit |
| Special characters in field names | TC-DSL-11-40 | unit |
| **Integration with DSL-05 (coercion) and DSL-10 (resolution)** | | |
| Path result used in comparison (DSL-05 compat) | TC-DSL-11-41 | unit |
| Path result used in arithmetic (DSL-05 compat) | TC-DSL-11-42 | unit |
| Null from path used in boolean logic (DSL-05 null logic) | TC-DSL-11-43 | unit |
| Context variable name collision (same identifier in different scopes) | TC-DSL-11-44 | unit |

**Total: 44 test cases covering all 14 categories and 44 distinct scenarios**

---

## Test Cases

### Category 1: Basic Traversal

#### TC-DSL-11-01: Single-segment path (DSL-10 compatibility)
**Given:** Context `{ "order": 100 }` and expression `order`  
**When:** Evaluated  
**Then:** Returns `int_val == 100`  
**Layer:** unit  
**Rationale:** Single-segment paths are handled by DSL-10 context resolution. DSL-11 must be backward compatible.  
**Acceptance criterion mapped:** Single-segment paths resolve via DSL-10 rules unchanged

#### TC-DSL-11-02: Two-level path with scalar in nested object
**Given:** Context `{ "order": "{\"total\": 100}" }` (order is a JSON object string) and expression `order.total`  
**When:** Evaluated  
**Then:** Returns `int_val == 100`  
**Layer:** unit  
**Rationale:** Root lookup returns JSON string; parse it and extract field `total`.  
**Acceptance criterion mapped:** Two-level path traversal parses JSON and extracts field

#### TC-DSL-11-03: Three-level path with embedded JSON
**Given:** Context `{ "data": "{\"user\": \"{\\\"name\\\": \\\"Alice\\\"}\"}" }` (doubly nested JSON) and expression `data.user.name`  
**When:** Evaluated  
**Then:** Returns `str_val == "Alice"`  
**Layer:** unit  
**Rationale:** At level 2, `user` is itself a JSON string; must parse again to extract `name`.  
**Acceptance criterion mapped:** Three-level path requires iterative JSON parsing

#### TC-DSL-11-04: Four-level path
**Given:** Context with `level1 -> "{\"level2\": \"{\\\"level3\\\": \\\"{\\\\\\\"value\\\\\\\": 42}\\\"}" }"` and expression `level1.level2.level3.value`  
**When:** Evaluated  
**Then:** Returns `int_val == 42`  
**Layer:** unit  
**Rationale:** Each intermediate level requires JSON parsing; confirm 4-level traversal works.  
**Acceptance criterion mapped:** Four-level path traversal works correctly

#### TC-DSL-11-05: Five-level path (very deep nesting)
**Given:** Context with `a -> "{\"b\": \"{\\\"c\\\": \\\"{\\\\\\\"d\\\\\\\": \\\\\\\"{\\\\\\\\\\\\\\\"e\\\\\\\\\\\\\\\": 777}\\\\\\\"}\\\"}\"}" }` and expression `a.b.c.d.e`  
**When:** Evaluated  
**Then:** Returns `int_val == 777`  
**Layer:** unit  
**Rationale:** Verify DSL-11 handles paths up to 5+ levels as per design.  
**Acceptance criterion mapped:** Five-level path traversal works as specified

---

### Category 2: Null Propagation — Root Level

#### TC-DSL-11-06: Root identifier missing from context
**Given:** Context `{}` (empty) and expression `order.total`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Root identifier `order` is not in context; returns null (DSL-10 behavior).  
**Acceptance criterion mapped:** Missing root identifier returns null without error

#### TC-DSL-11-07: Root identifier is null in context
**Given:** Context `{ "order": null }` and expression `order.total`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Root value is null; null-propagation returns null immediately.  
**Acceptance criterion mapped:** Null root propagates to final result

#### TC-DSL-11-08: Root identifier missing from multi-segment path
**Given:** Context `{ "customer": 42 }` and expression `order.address.city`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Even with multi-segment path, missing root returns null.  
**Acceptance criterion mapped:** Missing root in multi-segment path returns null

---

### Category 3: Null Propagation — Intermediate Levels

#### TC-DSL-11-09: First intermediate field is null
**Given:** Context `{ "order": "{\"total\": null}" }` and expression `order.total.amount`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** `order.total` resolves to null; attempting to traverse null returns null.  
**Acceptance criterion mapped:** Null at first intermediate stops traversal, returns null

#### TC-DSL-11-10: Second intermediate field is null
**Given:** Context `{ "data": "{\"user\": \"{\\\"profile\\\": null}\"}" }` and expression `data.user.profile.age`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** `data.user.profile` resolves to null; further traversal returns null.  
**Acceptance criterion mapped:** Null at second intermediate stops traversal, returns null

#### TC-DSL-11-11: Third intermediate field is null
**Given:** Context with a 4-level path where the 3rd level is null and expression `a.b.c.d` with `c = null`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Confirms null-propagation at deeper intermediate levels.  
**Acceptance criterion mapped:** Null at third intermediate stops traversal, returns null

#### TC-DSL-11-12: Exhaustive null-propagation test for all nesting levels
**Given:** Context with paths of depth 1, 2, 3, 4, 5 and null injected at each position (root, 1st intermediate, 2nd, etc.)  
**When:** Each configuration is evaluated  
**Then:** All return `null_val` without raising `EvalError`  
**Layer:** unit  
**Rationale:** Comprehensive verification that null at any level propagates to the final result.  
**Acceptance criterion mapped:** Null propagates consistently at all nesting levels

---

### Category 4: Null Propagation — Missing Fields

#### TC-DSL-11-13: Missing field at first level
**Given:** Context `{ "order": "{\"total\": 100}" }` and expression `order.status` (status field does not exist)  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Field `status` is not in the parsed object; return null, not error.  
**Acceptance criterion mapped:** Missing field returns null without error

#### TC-DSL-11-14: Missing field at second level
**Given:** Context `{ "data": "{\"user\": \"{\\\"name\\\": \\\"Bob\\\"}\"}" }` and expression `data.user.email` (email field does not exist)  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** In parsed user object, email field is missing; return null.  
**Acceptance criterion mapped:** Missing intermediate field returns null without error

#### TC-DSL-11-15: Missing field at third level
**Given:** Context with a 4-level path where a field at the 3rd level is missing and expression `a.b.c.missing_field`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Confirms missing-field null returns at deeper levels.  
**Acceptance criterion mapped:** Missing field at deeper level returns null without error

---

### Category 5: Type Handling — Scalars in Path

#### TC-DSL-11-16: Root is int64, attempt multi-segment path
**Given:** Context `{ "count": 42 }` (int64, not JSON) and expression `count.value`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Root is a scalar int64; cannot parse JSON or traverse further.  
**Acceptance criterion mapped:** Scalar type at root prevents traversal, returns null

#### TC-DSL-11-17: Root is float64, attempt traversal
**Given:** Context `{ "rate": 3.14 }` (float64, not JSON) and expression `rate.percent`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Root is a scalar float64; traversal returns null.  
**Acceptance criterion mapped:** Scalar float at root prevents traversal, returns null

#### TC-DSL-11-18: Root is bool, attempt traversal
**Given:** Context `{ "enabled": true }` (bool, not JSON) and expression `enabled.status`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Root is a bool; cannot traverse into a scalar boolean.  
**Acceptance criterion mapped:** Scalar bool at root prevents traversal, returns null

#### TC-DSL-11-19: Intermediate is scalar (non-JSON), further traversal
**Given:** Context `{ "order": "{\"total\": 100}" }` and expression `order.total.decimal` where `total` resolves to the int64 100  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** After extracting `total` as int64, attempting to traverse into it returns null.  
**Acceptance criterion mapped:** Scalar intermediate prevents further traversal, returns null

---

### Category 6: Mixed Types in JSON — Successful Extraction

#### TC-DSL-11-20: Extract int64 from nested object
**Given:** Context `{ "order": "{\"quantity\": 5}" }` and expression `order.quantity`  
**When:** Evaluated  
**Then:** Returns `int_val == 5`  
**Layer:** unit  
**Rationale:** JSON integer is converted to DSL int64 type correctly.  
**Acceptance criterion mapped:** JSON int extracted and converted to DSL int64

#### TC-DSL-11-21: Extract float64 from nested object
**Given:** Context `{ "product": "{\"price\": 19.99}" }` and expression `product.price`  
**When:** Evaluated  
**Then:** Returns `float_val == 19.99`  
**Layer:** unit  
**Rationale:** JSON float is converted to DSL float64 type correctly.  
**Acceptance criterion mapped:** JSON float extracted and converted to DSL float64

#### TC-DSL-11-22: Extract bool from nested object
**Given:** Context `{ "config": "{\"enabled\": true}" }` and expression `config.enabled`  
**When:** Evaluated  
**Then:** Returns `bool_val == true`  
**Layer:** unit  
**Rationale:** JSON boolean is converted to DSL bool type correctly.  
**Acceptance criterion mapped:** JSON bool extracted and converted to DSL bool

#### TC-DSL-11-23: Extract string from nested object
**Given:** Context `{ "user": "{\"name\": \"Charlie\"}" }` and expression `user.name`  
**When:** Evaluated  
**Then:** Returns `str_val == "Charlie"`  
**Layer:** unit  
**Rationale:** JSON string is extracted and stored as DSL string type.  
**Acceptance criterion mapped:** JSON string extracted and preserved as DSL string

---

### Category 7: Nested Structures — Objects and Arrays

#### TC-DSL-11-24: Extract nested object (returned as JSON string)
**Given:** Context `{ "user": "{\"profile\": {\"bio\": \"Developer\"}}" }` and expression `user.profile`  
**When:** Evaluated  
**Then:** Returns `str_val == "{\"bio\": \"Developer\"}"` (re-serialized JSON)  
**Layer:** unit  
**Rationale:** Nested object is re-serialized to JSON string to enable further traversal.  
**Acceptance criterion mapped:** Nested object extracted as JSON string for further traversal

#### TC-DSL-11-25: Extract array from object (returned as JSON string)
**Given:** Context `{ "data": "{\"items\": [1, 2, 3]}" }` and expression `data.items`  
**When:** Evaluated  
**Then:** Returns `str_val == "[1, 2, 3]"` (re-serialized JSON)  
**Layer:** unit  
**Rationale:** Arrays are not a native DSL type; return as JSON string.  
**Acceptance criterion mapped:** Array extracted as JSON string

#### TC-DSL-11-26: Attempt to index array with field name (no numeric indexing)
**Given:** Context `{ "arr": "[1, 2, 3]" }` and expression `arr.0` (attempt to use numeric index as field name)  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Arrays are indexed with `[index]` in JSON, not field names. Field name "0" does not exist in array.  
**Acceptance criterion mapped:** Numeric indexing on arrays returns null (no bracket indexing in DSL-11)

#### TC-DSL-11-27: Nested object within array (cannot access via field name)
**Given:** Context `{ "data": "[{\"name\": \"Alice\"}, {\"name\": \"Bob\"}]" }` and expression `data.name` (attempt to access without array index)  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Cannot access fields in array elements without numeric indexing (not supported in DSL-11).  
**Acceptance criterion mapped:** Field access on arrays without indexing returns null

---

### Category 8: Error Cases — Graceful Handling

#### TC-DSL-11-28: Malformed JSON in intermediate
**Given:** Context `{ "data": "{bad json}" }` and expression `data.field`  
**When:** Evaluated  
**Then:** Returns `null_val` without raising `EvalError`  
**Layer:** unit  
**Rationale:** Invalid JSON parses gracefully to null, not an error.  
**Acceptance criterion mapped:** Malformed JSON returns null gracefully

#### TC-DSL-11-29: Invalid JSON string (missing quotes, braces)
**Given:** Context `{ "obj": "{incomplete" }` and expression `obj.field`  
**When:** Evaluated  
**Then:** Returns `null_val` without raising `EvalError`  
**Layer:** unit  
**Rationale:** Incomplete JSON is treated as malformed; returns null.  
**Acceptance criterion mapped:** Incomplete JSON returns null without error

#### TC-DSL-11-30: Attempt traversal on partially invalid JSON
**Given:** Context `{ "data": "{\"valid_field\": 42, invalid}" }` (invalid JSON syntax) and expression `data.valid_field`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Entire JSON is invalid; returns null instead of attempting partial parsing.  
**Acceptance criterion mapped:** Partial JSON validity returns null (all-or-nothing parsing)

---

### Category 9: Type Coercion from JSON

#### TC-DSL-11-31: JSON int coerces to DSL int64
**Given:** Context `{ "obj": "{\"count\": 999}" }` and expression `obj.count`  
**When:** Evaluated  
**Then:** Returns `int_val == 999` (not string, not float)  
**Layer:** unit  
**Acceptance criterion mapped:** JSON int correctly converted to DSL int64 via type coercion

#### TC-DSL-11-32: JSON float coerces to DSL float64
**Given:** Context `{ "obj": "{\"pi\": 3.14159}" }` and expression `obj.pi`  
**When:** Evaluated  
**Then:** Returns `float_val == 3.14159`  
**Layer:** unit  
**Acceptance criterion mapped:** JSON float correctly converted to DSL float64 via type coercion

#### TC-DSL-11-33: JSON bool coerces to DSL bool
**Given:** Context `{ "obj": "{\"success\": false}" }` and expression `obj.success`  
**When:** Evaluated  
**Then:** Returns `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** JSON bool correctly converted to DSL bool via type coercion

#### TC-DSL-11-34: JSON string stays as DSL string
**Given:** Context `{ "obj": "{\"msg\": \"hello world\"}" }` and expression `obj.msg`  
**When:** Evaluated  
**Then:** Returns `str_val == "hello world"`  
**Layer:** unit  
**Acceptance criterion mapped:** JSON string preserved as DSL string via type coercion

#### TC-DSL-11-35: JSON null becomes DSL null_val
**Given:** Context `{ "obj": "{\"optional\": null}" }` and expression `obj.optional`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** JSON null converted to DSL null_val via type coercion

---

### Category 10: Edge Cases

#### TC-DSL-11-36: Empty path segments (defensive)
**Given:** Expression with zero path segments (edge case; should not occur via parser but test defensively)  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Rationale:** Defensive check; empty path is treated as unresolvable.  
**Acceptance criterion mapped:** Empty path returns null

#### TC-DSL-11-37: Very deeply nested (6+ levels)
**Given:** Context with a JSON structure 6 levels deep and expression traversing all 6 levels  
**When:** Evaluated  
**Then:** Returns the correct value at the leaf level  
**Layer:** unit  
**Rationale:** Verify DSL-11 can handle paths beyond the typical 3-5 level design target.  
**Acceptance criterion mapped:** Very deep nesting (6+ levels) works correctly

#### TC-DSL-11-38: Unicode field names and values
**Given:** Context `{ "data": "{\"名前\": \"田中\"}" }` (Japanese field name and value) and expression `data.名前`  
**When:** Evaluated  
**Then:** Returns `str_val == "田中"`  
**Layer:** unit  
**Rationale:** JSON standard supports Unicode; verify DSL-11 handles it.  
**Acceptance criterion mapped:** Unicode in field names and values handled correctly

#### TC-DSL-11-39: Large JSON object traversal
**Given:** Context with a large JSON object (100+ fields) and expression accessing a deep field  
**When:** Evaluated  
**Then:** Returns the correct value efficiently  
**Layer:** unit  
**Rationale:** Performance check: large objects should still parse and traverse correctly.  
**Acceptance criterion mapped:** Large JSON objects traversed correctly

#### TC-DSL-11-40: Special characters in field names
**Given:** Context `{ "data": "{\"field-name\": 42, \"field.with.dots\": 99}" }` and expression `data."field-name"` and `data."field.with.dots"`  
**When:** Evaluated  
**Then:** Returns `int_val == 42` and `int_val == 99` respectively  
**Layer:** unit  
**Rationale:** JSON field names can contain hyphens, dots, and other special characters; verify parsing.  
**Acceptance criterion mapped:** Special characters in field names handled correctly

---

### Category 11: Integration with DSL-05 (Coercion) and DSL-10 (Resolution)

#### TC-DSL-11-41: Path result used in comparison (DSL-05 compat)
**Given:** Context `{ "order": "{\"total\": 100}" }` and expression `order.total == 100`  
**When:** Evaluated  
**Then:** Returns `bool_val == true`  
**Layer:** unit  
**Rationale:** Path result (int64) used in comparison; verifies DSL-05 integration.  
**Acceptance criterion mapped:** Path result integrates with DSL-05 comparison operators

#### TC-DSL-11-42: Path result used in arithmetic (DSL-05 compat)
**Given:** Context `{ "order": "{\"price\": 50}" }` and expression `order.price + 10`  
**When:** Evaluated  
**Then:** Returns `int_val == 60`  
**Layer:** unit  
**Rationale:** Path result used in arithmetic; verifies DSL-05 integration.  
**Acceptance criterion mapped:** Path result integrates with DSL-05 arithmetic operators

#### TC-DSL-11-43: Null from path used in boolean logic (DSL-05 null logic)
**Given:** Context `{ "data": "{}" }` and expression `(data.missing and true)` where `data.missing` returns null  
**When:** Evaluated  
**Then:** Returns `null_val` (three-valued logic from DSL-05)  
**Layer:** unit  
**Rationale:** Null from path follows DSL-05 three-valued boolean logic.  
**Acceptance criterion mapped:** Null from path integrates with DSL-05 three-valued logic

#### TC-DSL-11-44: Context variable name collision (same identifier in different scopes)
**Given:** Context `{ "x": 10, "obj": "{\"x\": 20}" }` and expression `obj.x` (inner `x` should take precedence in JSON scope)  
**When:** Evaluated  
**Then:** Returns `int_val == 20` (from JSON object, not context root)  
**Layer:** unit  
**Rationale:** Verify that path traversal uses field lookup within JSON, not context root.  
**Acceptance criterion mapped:** Field lookup in JSON object is independent of context scope

---

## Test Implementation Notes

### Null-Propagation Test Harness

For TC-DSL-11-12 (exhaustive null-propagation), construct a test matrix:

```
For path depths d = [1, 2, 3, 4, 5]:
  For each position p in the path [0, 1, ..., d-1]:
    Inject null at position p
    Evaluate expression
    Assert result is null_val
    Assert no EvalError raised
```

### JSON Test Data Construction

All JSON objects in context should be properly escaped strings. Example:

```zig
var context = StringHashMap(Value).init(allocator);
try context.put("user", valueStr("{\"name\": \"Alice\", \"age\": 30}"));
try context.put("nested", valueStr("{\"level2\": \"{\\\"level3\\\": \\\"value\\\"}\"}"));
```

### Type Preservation Verification

After extracting a value from JSON, verify the returned DSL Value has the correct tag:
- JSON `123` → `int_val`
- JSON `3.14` → `float_val`
- JSON `true/false` → `bool_val`
- JSON `"string"` → `str_val`
- JSON `null` → `null_val`
- JSON `{...}` or `[...]` → `str_val` (re-serialized)

---

## Coverage Summary

| Category | Test Cases | Count |
|----------|-----------|-------|
| Basic traversal | TC-DSL-11-01 through TC-DSL-11-05 | 5 |
| Null propagation — root | TC-DSL-11-06 through TC-DSL-11-08 | 3 |
| Null propagation — intermediate | TC-DSL-11-09 through TC-DSL-11-12 | 4 |
| Null propagation — missing fields | TC-DSL-11-13 through TC-DSL-11-15 | 3 |
| Type handling — scalars | TC-DSL-11-16 through TC-DSL-11-19 | 4 |
| Mixed types — extraction | TC-DSL-11-20 through TC-DSL-11-23 | 4 |
| Nested structures | TC-DSL-11-24 through TC-DSL-11-27 | 4 |
| Error cases — graceful handling | TC-DSL-11-28 through TC-DSL-11-30 | 3 |
| Type coercion from JSON | TC-DSL-11-31 through TC-DSL-11-35 | 5 |
| Edge cases | TC-DSL-11-36 through TC-DSL-11-40 | 5 |
| Integration (DSL-05, DSL-10) | TC-DSL-11-41 through TC-DSL-11-44 | 4 |
| **Total** | | **44** |

All test cases verify acceptance criteria from the DSL-11 requirement and ensure null-propagation semantics are correctly implemented at all nesting levels.
