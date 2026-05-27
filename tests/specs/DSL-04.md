# Test Spec: DSL-04 — Supported types

**Requirement:** DSL-04 — The DSL MUST support exactly these value types: `null`, `bool`, `int64`, `float64`, `string`, `timestamp`. No other types are valid.  
**Priority:** MUST  
**Test layer:** unit

---

## Test Cases

### TC-DSL-04-01: Value tagged union has exactly 6 variants
**Given:** The `Value` type defined in `ast.zig`  
**When:** The union fields are counted at compile time  
**Then:** There must be exactly 6 fields: `null_val`, `bool_val`, `int_val`, `float_val`, `str_val`, `ts_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Each type has a correct Zig representation

### TC-DSL-04-02: TypeTag enum mirrors the 6 types
**Given:** The `TypeTag` enum defined in `ast.zig`  
**When:** The enum fields are counted at compile time  
**Then:** There must be exactly 6 fields: `null`, `bool`, `int64`, `float64`, `string`, `timestamp`  
**Layer:** unit  
**Acceptance criterion mapped:** TypeTag correctly identifies all 6 types

### TC-DSL-04-03: typeOf returns correct tag for each variant
**Given:** A `Value` of each variant produced by the construction helpers  
**When:** `typeOf()` is called on each value  
**Then:** The returned `TypeTag` must match the expected tag  
**Layer:** unit  
**Acceptance criterion mapped:** Each type has a correct Zig representation

### TC-DSL-04-04: Value construction helpers produce correct payloads
**Given:** The six value construction helpers (`valueNull`, `valueBool`, `valueInt`, `valueFloat`, `valueStr`, `valueTs`)  
**When:** Each helper is called with a known input  
**Then:** The payload in the returned `Value` must match the input  
**Layer:** unit  
**Acceptance criterion mapped:** Each type has a correct Zig representation

### TC-DSL-04-05: Evaluate null literal
**Given:** Source expression `null`  
**When:** Parsed and evaluated  
**Then:** The result is `.ok` with a `null_val` variant  
**Layer:** unit  
**Acceptance criterion mapped:** Literal form round-trips through parse then evaluate

### TC-DSL-04-06: Evaluate bool literal true
**Given:** Source expression `true`  
**When:** Parsed and evaluated  
**Then:** The result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Literal form round-trips through parse then evaluate

### TC-DSL-04-07: Evaluate bool literal false
**Given:** Source expression `false`  
**When:** Parsed and evaluated  
**Then:** The result is `.ok` with `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Literal form round-trips through parse then evaluate

### TC-DSL-04-08: Evaluate int literal 42
**Given:** Source expression `42`  
**When:** Parsed and evaluated  
**Then:** The result is `.ok` with `int_val == 42`  
**Layer:** unit  
**Acceptance criterion mapped:** Literal form round-trips through parse then evaluate

### TC-DSL-04-09: Evaluate float literal 3.14
**Given:** Source expression `3.14`  
**When:** Parsed and evaluated  
**Then:** The result is `.ok` with `float_val == 3.14`  
**Layer:** unit  
**Acceptance criterion mapped:** Literal form round-trips through parse then evaluate

### TC-DSL-04-10: Evaluate string literal "hello"
**Given:** Source expression `"hello"`  
**When:** Parsed and evaluated  
**Then:** The result is `.ok` with `str_val == "hello"`  
**Layer:** unit  
**Acceptance criterion mapped:** Literal form round-trips through parse then evaluate

### TC-DSL-04-11: Evaluate empty string literal
**Given:** Source expression `""`  
**When:** Parsed and evaluated  
**Then:** The result is `.ok` with `str_val == ""` (empty string)  
**Layer:** unit  
**Acceptance criterion mapped:** Literal form round-trips through parse then evaluate

### TC-DSL-04-12: Round-trip payload verification for all literal types
**Given:** Source expressions for each literal type (null, true, false, 42, 3.14, "hello", "")  
**When:** Each is parsed and evaluated  
**Then:** The result value's type tag AND payload must match the original literal value  
**Layer:** unit  
**Acceptance criterion mapped:** Each type has a literal form (where applicable) and round-trips through parse then evaluate

### TC-DSL-04-13: Timestamp type verified via construction and typeOf
**Given:** The `valueTs()` construction helper and `typeOf()` helper  
**When:** A timestamp value is constructed with a known millisecond payload  
**Then:** The value has variant `.ts_val`, payload matches the input, and `typeOf()` returns `.timestamp`  
**Layer:** unit  
**Acceptance criterion mapped:** Timestamp type has a correct Zig representation (no literal form — timestamp is produced through context or built-ins per DSL-04 §3.3; full round-trip through evaluate() requires DSL-06 dot_path resolution)

### TC-DSL-04-14: Unsupported function call produces parse error
**Given:** Source expression `decimal(42)` where `decimal` is not a whitelisted built-in  
**When:** Parsed  
**Then:** The result is `.fail` with at least one `ParseError`  
**Layer:** unit  
**Acceptance criterion mapped:** Attempting to use an unsupported type produces a structured parse error

### TC-DSL-04-15: Hex literal produces parse error
**Given:** Source expression `0xFF` which is not a valid integer literal  
**When:** Parsed  
**Then:** The result is `.fail` with at least one `ParseError`  
**Layer:** unit  
**Acceptance criterion mapped:** Attempting to use an unsupported type produces a structured parse error

### TC-DSL-04-16: Integer literal out of i64 range produces structured parse error
**Given:** Source expression with an integer value exceeding `i64` max range (e.g., `99999999999999999999`)  
**When:** Parsed  
**Then:** The result is `.fail` with a `ParseError` whose `message` contains `"integer literal out of i64 range"`  
**Layer:** unit  
**Acceptance criterion mapped:** Attempting to use an unsupported type (overflow) produces a structured parse error
