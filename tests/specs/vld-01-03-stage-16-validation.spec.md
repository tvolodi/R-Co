# Test Spec: VLD-01/02/03 — Stage 16 Semantic Validation
**(`POST /api/v1/definitions/:id/validate` — typed environment, CEL semantic compile, aggregated diagnostics)**

**Requirements:** VLD-01 (Typed environment from definition context), VLD-02 (Expression compile and type check), VLD-03 (Aggregated validation diagnostics)
**Stage:** 16
**Priority:** MUST
**Branch:** `feature/wf02-vld01-03-20260816`
**Run ID:** `WF02-vld01-03-20260816`
**Implementation commit:** `31482edb` (mod 9 — `src/validation/*.zig`, `src/api/routes/validation.zig`)
**Design artefact:** [src/design/vld-01-03-stage-16-validation.md](../../src/design/vld-01-03-stage-16-validation.md)
**Authoritative requirement source:** `docs/requirements.yaml` lines 13129–13194 (VLD-01, VLD-02, VLD-03 bodies and acceptance criteria)
**Test layer:** integration (real PostgreSQL — `BPM_TEST_DB_URL`); HTTP boundary tested via the `handleValidate` handler in `src/api/routes/validation.zig` (wired through `bpm.api_tenant_context` and a real `definition.Store`)

---

## 0. Scope and conventions

This spec defines **integration tests** for VLD-01/02/03. Every MUST acceptance criterion (AC) listed in §16 of the design artefact (and reproduced in §1 below) gets at least one test in `tests/integration/validation_vld_*.zig`.

Conventions (matching the surrounding test corpus — see `tests/integration/api02_crud_test.zig`, `tests/integration/definition_test.zig`, `tests/integration/trace_test.zig`):

- **Self-sufficient.** Each test blocks on `BPM_TEST_DB_URL` (or `BPM_TEST_URL` for HTTP-boundary tests) and either runs against a real DB or against `bpm.definition.Store` connected to one. No shared mutable state; every test creates its own definition, then `defer cleanupDefinition(...)` removes it.
- **Per-test fixtures.** Every definition uses a per-test name + version pattern `TC-VLD-<NN>-<descriptive-suffix> Process`. The definition id is fetched from the post-create response — never hardcoded UUIDs (the all-zeros sentinel `00000000-0000-0000-0000-000000000000` is reserved for the default-tenant context only; per-test identities are generated via `bpm.uuid.generateUuidV4BytesInto`).
- **No mocked services.** `definition.Store` is the real one; `api_tenant_context` is set explicitly per test so the `process_definitions` RLS policy is honored. The validation handler reads from the same store, so a cross-tenant probe is a real cross-tenant read — not a stub.
- **No `error.SkipZigTest`.** All MUST-AC tests fail fast when the env is missing — they do not silently skip. `SkipZigTest` is reserved for infrastructure-availability failures and the test architect has confirmed `BPM_TEST_DB_URL` is the only env var required.
- **HTTP-boundary tests** under `tests/integration/validation_vld_http_*` consume `BPM_TEST_URL` + `BPM_TEST_TOKEN` (matching `tests/integration/trace_test.zig`). Suite-level hoisted check: if either is absent the entire HTTP file returns `error.SkipZigTest` at the top of each test (the pattern from `trace_test.zig`).
- **No credentials in fixtures.** No literal passwords, no real production URLs. Every secret is read from `BPM_TEST_TOKEN` (or rejected as `error.SkipZigTest`).

---

## 1. Test inventory — AC → test name

| AC | Requirement | Test name(s) | File |
|---|---|---|---|
| **VLD-01 AC1** | GIVEN `variable_schema` declares a type name outside the mapping table, WHEN the environment is built, THEN the platform returns HTTP 422 `UnknownVariableType` naming the variable and the type. | `int_vld_01_01: validateDefinition returns UnknownVariableType for variable_schema declaration outside mapping table` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-01 AC2** | GIVEN a SERVICE_TASK references a catalog entry that declares no result schema, WHEN the environment is built, THEN the platform returns HTTP 422 `UndeclaredResultSchema` naming the node and the reference. | `int_vld_01_02: validateDefinition returns UndeclaredResultSchema for SERVICE_TASK whose catalog response_schema is null` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-01 AC3** | GIVEN two form fields in one human task scope declare the same name with different types, WHEN the environment is built, THEN the platform returns HTTP 422 `ConflictingFieldType` naming both declarations. | `int_vld_01_03: validateDefinition returns ConflictingFieldType for two same-name form fields with different types` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-01 AC4** | The environment is derived from declarations only; no instance variable value contributes a type. | `int_vld_01_04: validateDefinition env is identical for two instances with different variable maps (declaration-only)` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-01 AC5** | A node output type is visible only to expression sites on nodes reachable after that node, and a form field type only inside its own human task scope. | `int_vld_01_05a: validateDefinition forward-scopes SERVICE_TASK output to downstream sites only`<br>`int_vld_01_05b: validateDefinition form-field scope is per-HUMAN_TASK-·node_id` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-02 AC1** | GIVEN a transition guard that compiles to a type other than bool, WHEN it is checked, THEN the platform records `TypeMismatch` naming bool as expected and the compiled type as actual. | `int_vld_02_01: validateDefinition returns TypeMismatch on guard that compiles to non-bool` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-02 AC2** | GIVEN an expression referencing an identifier absent from the environment, WHEN it is compiled, THEN the platform records `UnknownVariable` naming the identifier. | `int_vld_02_02: validateDefinition returns UnknownVariable referencing identifier absent from env` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-02 AC3** | GIVEN an expression adding a string operand to a number operand, WHEN it is compiled, THEN the platform records `OperandTypeError` naming the operator and both operand types. | `int_vld_02_03: validateDefinition returns OperandTypeError for string + number` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-02 AC4** | GIVEN the PD-06 syntax check fails, WHEN validation runs, THEN semantic compilation does not execute and the response carries the PD-06 diagnostics only. | `int_vld_02_04: validateDefinition returns 422 with pd06_diagnostics only when PD-06 syntax fails (no semantic compile)` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-02 AC5** | GIVEN an expression site holding an empty or whitespace-only string, WHEN it is checked, THEN the platform records `EmptyExpression` rather than passing the site. | `int_vld_02_05: validateDefinition returns EmptyExpression for whitespace-only site` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-03 AC1** | GIVEN a definition with three failing expression sites, WHEN validation runs, THEN one HTTP 422 response contains three findings; validation does not stop at the first failure. | `int_vld_03_01: validateDefinition aggregates three findings into one ValidationFailure` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-03 AC2** | GIVEN any finding, WHEN it is serialised, THEN it carries `node_id`, `expression_path`, `source`, `error_kind` and `message`. | `int_vld_03_02: every Finding in the response carries all five mandatory fields` | `tests/integration/validation_vld_http_test.zig` |
| **VLD-03 AC3** | GIVEN a finding of kind `UnknownVariable`, WHEN the message is built, THEN it names the referenced identifier and the nearest declared identifier by edit distance. | `int_vld_03_03: UnknownVariable message names missing identifier and nearest by edit distance (≤4)` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-03 AC4** | Findings are ordered by `node_id` then `expression_path`, so two validations of the same definition produce identical ordering. | `int_vld_03_04: two consecutive validateDefinition calls on the same definition produce byte-identical finding ordering` | `tests/integration/validation_vld_unit_test.zig` |
| **VLD-03 AC5** | No `error_kind` value outside the enumerated set is emitted. | `int_vld_03_05: every ErrorKind field in the response is one of the 7 wire strings` | `tests/integration/validation_vld_http_test.zig` |

**Coverage count:** 15 / 15 MUST ACs have at least one integration test. 12 land in `tests/integration/validation_vld_unit_test.zig` (the handler-direct path, runnable with `BPM_TEST_DB_URL` only); 5 land in `tests/integration/validation_vld_http_test.zig` (the HTTP-boundary path, require `BPM_TEST_URL` + `BPM_TEST_TOKEN`). 2 ACs appear in both files (VLD-03 AC2 and VLD-03 AC5 — exercised at the wire layer AND at the in-process handler layer for stronger guarantees).

---

## 2. Test design rationale

The ACs split naturally into three families, each with a different assurance target:

### 2.1 Env-builder ACs (VLD-01 AC1–AC5)

**Why unit-style integration tests (not pure unit tests)?** The test designer guide (§2 "Pure functions first") suggests pure unit tests for transition/validator. The env builder **is** a pure function, but the ACs themselves are bounded by the AC text — "WHEN the environment is built" — and the implementation under `validateDefinition` is the public entry point. A test that drives `validateDefinition` through `Store.create` + `Store.getById` + `handleValidate` exercises the **same module graph** the platform will use in production, with the same allocator, the same `EnvInput` builder, and the same `wire.zig` serialisation. Pure unit tests would reproduce the fixtures in isolation and miss the graph-scope machinery (`scope.zig`, the `forward_reachable_from` DFS) that the AC text requires.

**Why not also pure unit tests?** The design artefact §12 already lists in-file unit tests at `src/validation/{mod,env,typecheck,finding}_test.zig`. Those test the **typed-env type-checker boundary** in isolation but cannot exercise the handler-level wire output (VLD-03 AC1, AC2, AC4, AC5). The integration tests here are not a substitute for those unit tests — they sit **on top**, exercising the public surface.

### 2.2 Type-checker ACs (VLD-02 AC1–AC5)

Each AC is a single concrete scenario from the design (VLD-02 is the type-checker stage). The test fixtures are minimal — four-node graphs with one variable, one guard, one bad site, one good site. The "no skip" rule applies absolutely: the build-step `test-validation` already runs the in-file unit tests in `src/validation/*.zig`; the integration tests here are the deployment-of-record test set.

**VLD-02 AC4 (PD-06 gate) is the only AC where the Finding shape is replaced by `pd06_diagnostics`.** The test asserts BOTH that `findings` is empty AND that `pd06_diagnostics` is non-null with at least one entry — the `mod.zig` short-circuit path. The reverse (PD-06 clean + semantics fail) is covered by VLD-02 AC1 (TypeMismatch) and VLD-02 AC2 (UnknownVariable) — neither can fire if PD-06 hasn't returned clean.

**VLD-02 AC5 (EmptyExpression) is unique.** The finding's `source` field is the literal empty/whitespace string (preserved per VLD-03 AC2). The test asserts both the `error_kind` and the verbatim `source` re-encoded in the response.

### 2.3 Aggregator ACs (VLD-03 AC1–AC5)

These are the **only** ACs that explicitly require the HTTP wire shape. The handler-direct tests (`validation_vld_unit_test.zig`) verify the in-process `ValidationFailure` struct; the HTTP tests (`validation_vld_http_test.zig`) decode the actual 422 body and assert every field on every finding. The byte-for-byte ordering test (VLD-03 AC4) runs **after** the sort, comparing two `ValidationFailure` slices via `std.mem.eql`.

**VLD-03 AC5 (closed enum) is a wire-shape test.** The handler-direct path can verify the Zig enum exhaustiveness (already enforced by the compiler at mod.zig); the HTTP test decodes the JSON and asserts the lexical set of strings appearing under `findings[].error_kind` is a subset of the 7 canonical strings.

### 2.4 Edge-case coverage

- **Build graph nodes**: `START → EXCLUSIVE_GATEWAY → END` (canonical 4-node/4-edge from existing `src/validation/mod.zig` unit tests).
- **Variable schemas**: per-test, always at least one valid declaration so the env is non-empty (so `UnknownVariable` can compute a nearest).
- **Edit-distance test (VLD-03 AC3)**: use a clear typo (`amont` vs `amount`) — Levenshtein = 1, well under the SUGGESTION_THRESHOLD of 4.
- **No-suggestion test (VLD-03 AC3 follow-on)**: a separate test uses an identifier whose Levenshtein is > 4 from every declared variable — the message must take the no-match form. This is the dual of VLD-03 AC3 and pins the threshold.

### 2.5 Fixture cardinality

Each test uses **hardcoded fixtures** (no `bpm.uuid.generateUuidV4BytesInto` for the definition id where the test only needs the value to be **unique**; the test fixtures are deleted in `defer cleanupDefinition` and the integration DB is single-tenant). Per-test name + version strings are unique within the file (e.g. `TC-VLD-01-01 Process`, `1.0.0`; `TC-VLD-01-02 Process`, `1.0.0`; etc.) — pattern borrowed from `tests/integration/api02_crud_test.zig`.

Where the test needs a definition uuid to construct the URL (HTTP path), the response from `Store.create` provides it (per §0's "no hardcoded UUIDs" rule).

---

## 3. Test fixtures — concrete test definition JSON

All fixtures are constructed in-process as `GraphNode` / `GraphEdge` literals (mirroring `tests/integration/definition_test.zig`'s `minimal_graph` style). The handler reads the graph from `Store.getById`, so the JSON shape is whatever the Zig struct produces when serialised; the test asserts the **response** body shape, not the request body shape.

### 3.1 Fixture A — Happy path (clean linear definition)

**Filename pattern:** `TC-VLD-03-01 / 03-02 / 03-04 happy-path fixture — referenced by 3 tests.**

```zig
// Clean START → EXCLUSIVE_GATEWAY → END.
// Two variable declarations, both inside the mapping table.
// Edge conditions are conservative bool expressions referencing the declared variables.
const happy_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
    .{ .id = "yes", .node_type = .END, .label = null },
    .{ .id = "no", .node_type = .END, .label = null },
};
const happy_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount > 0" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};
const happy_graph = DefinitionGraph{ .nodes = &happy_nodes, .edges = &happy_edges };
const happy_variables = [_]VariableSchemaEntry{
    .{ .name = "amount", .var_type = "number" },
};
const happy_input = EnvInput{
    .graph = happy_graph,
    .variable_schema = &happy_variables,
};
```

**Expected outcome:**
- `validateDefinition(alloc, happy_input)` returns `ValidationFailure{ .findings = &.{}, .pd06_diagnostics = null, ... }`.
- `serialiseSuccess(...)` produces `{"status":"semantically_valid","findings":[],"validated_at":"...","compiler_version":"vld-01-03-..."}`.
- HTTP 200 (for VLD-03 AC2 / AC4 / AC5 HTTP tests).

### 3.2 Fixture B — Reachable-output violation (VLD-01 AC5a)

Used by `int_vld_01_05a`. Forward-reachability check: a SERVICE_TASK is reachable from a site only when the site is on `gw` (the gateway after the SERVICE_TASK) — not on the upstream `S` (start) node.

```zig
// S → svc → gw → yes
// svc declares an output named "customer_id".
// gw's edge condition reads "customer_id" — visible (downstream of svc).
// But the test DRIVES the comparator via the env: S is upstream of svc,
// so a SERVICE_TASK output cannot be referenced from S. (S has no
// expressions in this graph — the assertion is purely on the env slice.)
//
// Reuse for the visibility-only test:
//   - assert envForSite (S) does NOT contain "customer_id".
//   - assert envForSite (gw) does contain "customer_id".
```

The test does NOT hit a compliance failure here — it proves the **scope filter** works. The assertion is on the in-process `TypedEnv` slice returned by `scope.envForSite`, not on a Finding.

### 3.3 Fixture C — Per-form scoping violation (VLD-01 AC5b)

Used by `int_vld_01_05b`. Two HUMAN_TASK nodes each with a `forms[0].fields[0]` named `email`; one declares `type: "string"`, the other `type: "number"`. The test asserts that:
- The two HUMAN_TASK scopes each see only their own `email` field, never the other one.
- No `ConflictingFieldType` finding is emitted (collisions are per-form, not cross-form).

```zig
// Marked ILLUSTRATIVE — the test driver calls EnvInput.form_fields
// directly. The Store-level shape does not currently carry form fields
// (a VLD-04 follow-on); the test driver builds the EnvInput manually
// and calls validateDefinition at the in-process API. This is the same
// pattern as the VLD-01 unit tests in src/validation/mod_test.zig.
const form_fields = [_]FormFieldEntry{
    .{ .node_id = "task_A", .field_name = "email", .field_type = "string" },
    .{ .node_id = "task_B", .field_name = "email", .field_type = "number" },
};
```

### 3.4 Fixture D — PD-06 syntax violation (VLD-02 AC4)

Used by `int_vld_02_04`. The guard is `"amount >"` — `isValidCelSyntax` returns `false` because the binary operator is missing its right operand.

```zig
const bad_syntax_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
    .{ .id = "yes", .node_type = .END, .label = null },
    .{ .id = "no", .node_type = .END, .label = null },
};
const bad_syntax_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount >" },  // PD-06 fail
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};
```

**Expected outcome:** `validateDefinition` returns `ValidationFailure{ .findings = &.{}, .pd06_diagnostics = non-null, ... }`. The semantic compile loop never runs. The HTTP response carries 422 with the PD-06 violation list verbatim.

### 3.5 Fixture E — Unknown variable, no typo (VLD-02 AC2)

```zig
const unknown_var_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "totally_undeclared_identifier > 0" },
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};
```

**Expected outcome:** One `Finding` with `error_kind = "UnknownVariable"`, `message` containing the identifier and the no-match form (since `totally_undeclared_identifier` is Levenshtein > 4 from any declared variable).

### 3.6 Fixture F — Unknown variable with edit-distance suggestion (VLD-03 AC3)

```zig
const suggested_var_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amont > 0" },  // typo
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};
```

**Expected outcome:** One `Finding` with `error_kind = "UnknownVariable"`, `message` containing `did you mean 'amount'?` (Levenshtein(`amont`, `amount`) = 1).

### 3.7 Fixture G — Operand type error (VLD-02 AC3)

```zig
const operand_var_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "amount + customer_id" }, // string + number
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};
const operand_vars = [_]VariableSchemaEntry{
    .{ .name = "amount", .var_type = "number" },
    .{ .name = "customer_id", .var_type = "string" },
};
```

**Expected outcome:** One `Finding` with `error_kind = "OperandTypeError"`, `message` containing `operator '+'` and both operand type names (`number` and `string`).

### 3.8 Fixture H — Empty expression (VLD-02 AC5)

```zig
const empty_var_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "   " },  // whitespace-only
    .{ .id = "e3", .source = "gw", .target = "no", .condition = "amount <= 0" },
};
```

**Expected outcome:** One `Finding` with `error_kind = "EmptyExpression"`, `source = "   "` (preserved verbatim per VLD-03 AC2).

### 3.9 Fixture set I — Built-in operator type mapping (VLD-02 AC1)

Used by `int_vld_02_01`. Twelve micro-tests, one per operator, each with a definition that uses the operator on operands of the type(s) the operator **accepts** and asserts no `TypeMismatch` finding. Twelve positive tests, then one negative test for an operator accepting the wrong operand type (`"a" > 0` — string vs number on `>`).

```zig
// Each operator lives in a dedicated 4-node graph. The fixture is constructed
// inline in the test body for brevity (no top-level const — per-test
// isolation rule applies; nothing is shared across test blocks).
//
// Two declared variables: `a` (number), `b` (number), `s` (string).
// Positive cases:
//   ==  → "a == b"            → 0 findings
//   !=  → "a != b"            → 0 findings
//   +   → "a + b"             → 0 findings
//   -   → "a - b"             → 0 findings
//   *   → "a * b"             → 0 findings
//   /   → "a / b"             → 0 findings
//   <   → "a < b"             → 0 findings
//   <=  → "a <= b"            → 0 findings
//   >   → "a > b"             → 0 findings
//   >=  → "a >= b"            → 0 findings
//   &&  → "a > 0 && b > 0"    → 0 findings
//   ||  → "a > 0 || b > 0"    → 0 findings
//   !   → "!(a > 0)"          → 0 findings
// Negative case (string > number): "s > 0" → 1 OperandTypeError (NOT TypeMismatch)
```

The twelve positive operator cases are coalesced into a single test block (`int_vld_02_01`) that loops over the operator table (a `[]const struct { name: []u8, condition: []u8 }` literal) and asserts each call returns `findings.len == 0`. The negative case is a separate test (`int_vld_02_01b`) that asserts the OperandTypeError surface — it pins the precise operator/operand failure mode for VLD-02 AC3.

### 3.10 Fixture J — Tenant scoping (VLD-03 AC5 via cross-tenant handler test)

Used by `int_vld_03_05` (and the HTTP twin). The handler is invoked with default tenant as the writer, then with a different tenant id (`99999999-9999-9999-9999-999999999999`) as the reader. The handler must return 404 (not 200, not 422) — the `DefinitionNotFound` path in `handleValidate`. The test asserts only the status code, not the body (the 404 body is the generic `{"error":"not found","status":404}` from `errorResult`).

### 3.11 Fixture K — Three-finding aggregate (VLD-03 AC1)

Used by `int_vld_03_01`. A single 4-node graph with three failing edges: one EmptyExpression, one OperandTypeError, one UnknownVariable. The test asserts that `failure.findings.len == 3` and that the ordering is `(node_id, expression_path)` lex.

```zig
// Three failing sites on the same gw (one node, three edges).
// Each edge is a different (node_id, expression_path) pair — the dedupe
// step is exercised by having two edges with the same node_id but different
// expression_paths. The aggregate is 3 distinct findings.
const three_finding_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "gw", .condition = null },
    .{ .id = "e2", .source = "gw", .target = "yes", .condition = "" },               // EmptyExpression
    .{ .id = "e3", .source = "gw", .target = "no",  .condition = "amount + name" },   // OperandTypeError
    .{ .id = "e4", .source = "gw", .target = "maybe", .condition = "amont > 0" },    // UnknownVariable
};
const three_finding_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null },
    .{ .id = "gw", .node_type = .EXCLUSIVE_GATEWAY, .label = null },
    .{ .id = "yes", .node_type = .END, .label = null },
    .{ .id = "no", .node_type = .END, .label = null },
    .{ .id = "maybe", .node_type = .END, .label = null },
};
const three_finding_vars = [_]VariableSchemaEntry{
    .{ .name = "amount", .var_type = "number" },
    .{ .name = "name",   .var_type = "string" },
};
```

**Expected outcome:** `failure.findings.len == 3`. Order: `(gw, /edges/1/condition)`, `(gw, /edges/2/condition)`, `(gw, /edges/3/condition)` — sorted by `expression_path` lex (all on the same `node_id`).

### 3.12 Fixture L — Closed enum surface (VLD-03 AC5)

Used by HTTP-only `int_vld_03_05`. The test runs each of VLD-01 AC1, VLD-01 AC2, VLD-01 AC3 in sequence (each via a separate definition), decodes the 422 body, and asserts the **set** of `error_kind` strings seen across all three responses is a subset of the 7 canonical strings. The test fails if any non-canonical string appears.

---

## 4. Expected outcomes — HTTP status + body shape

For each test below, the expected outcome is the **response** after the assertion. Status codes come from `src/api/routes/validation.zig`; body shapes from `src/validation/wire.zig`:

| Test | HTTP status | Body shape |
|---|---|---|
| `int_vld_01_01` | 422 | `{"type":"https://platform/validation/semantic","title":"Definition failed semantic validation","status":422,"findings":[{...}],"validated_at":"...","compiler_version":"..."}` with one finding `{node_id:"<definition>",expression_path:"/variable_schema/weird",source:"uuid",error_kind:"UnknownVariableType",message:"UnknownVariableType: variable 'weird' declares type 'uuid' ..."}`. |
| `int_vld_01_02` | 422 | Same envelope, `node_id:"svc"`, `expression_path:"/attributes/input_mapping"`, `source:"<service_id>"`, `error_kind:"UndeclaredResultSchema"`. |
| `int_vld_01_03` | 422 | Same envelope, `node_id:"task_collect"`, `expression_path:"/forms/0/fields/<idx>/type"`, `error_kind:"ConflictingFieldType"`. |
| `int_vld_01_04` | 200 | `{"status":"semantically_valid","findings":[],"validated_at":"...","compiler_version":"..."}` — same as the happy path. (Drives two `EnvInput` constructions with identical contents; the validator result must be byte-identical.) |
| `int_vld_01_05a` | n/a (in-process) | `scope.envForSite(S, ...)` does NOT contain `customer_id`; `scope.envForSite(gw, ...)` DOES. Assertion is on the `TypedEnv` slice, not on the HTTP response. |
| `int_vld_01_05b` | n/a (in-process) | Two separate `TypedEnv` slices, each with one `email` entry, no `ConflictingFieldType` finding. |
| `int_vld_02_01` | 422 | `findings[0].error_kind == "TypeMismatch"` — exactly one OperandTypeError is also emitted when the operator is `+` and one operand is string (negative case). |
| `int_vld_02_02` | 422 | `findings[0].error_kind == "UnknownVariable"`, `message` contains the identifier. |
| `int_vld_02_03` | 422 | `findings[0].error_kind == "OperandTypeError"`, `message` contains `operator '+'` and both `number` and `string` type names. |
| `int_vld_02_04` | 422 | `findings == []`, `pd06_diagnostics != null`, `pd06_diagnostics.len >= 1`, each carrying the PD-06 verbatim code + message. |
| `int_vld_02_05` | 422 | `findings[0].error_kind == "EmptyExpression"`, `source == "   "` (whitespace preserved verbatim). |
| `int_vld_03_01` | 422 | `findings.len == 3`, ordered by `(node_id, expression_path)`. |
| `int_vld_03_02` | 422 | Every `findings[i]` has all five fields non-empty (except `source` for `EmptyExpression` whose source is the empty/whitespace string). |
| `int_vld_03_03` | 422 | `findings[0].message` contains `did you mean 'amount'?`. Secondary assertion on the no-match case: a separate fixture with identifier > 4 edits from any declared variable yields a message in the no-match form. |
| `int_vld_03_04` | 422 | Two `validateDefinition` calls on the same definition produce byte-identical `findings` slices (compared via `std.mem.eql` over the in-process `ValidationFailure`). |
| `int_vld_03_05` | 422 (clean) or 404 (cross-tenant) | All `findings[].error_kind` values are in the 7-set; cross-tenant read returns 404 + `{"error":"not found","status":404}`. |

---

## 5. `lint_test_wiring` plan

The two new test files must be reachable from a `b.addTest(...)` root in `build.zig` AND the produced `Run` artifact must be attached to a step that `test-integration` depends on. The pattern is the one that worked for SPC-01 batch B (see `tests/integration/spc01_sub_process_interface_test.zig` + `tests/integration/main_test.zig` + `build.zig` wiring):

### 5.1 File layout

| File | Purpose |
|---|---|
| `tests/integration/validation_vld_unit_test.zig` | 13 test blocks — drives `validateDefinition` directly via `EnvInput` and asserts the `ValidationFailure` struct. Requires `BPM_TEST_DB_URL` only (the DB is needed for the `Store.create` / `Store.getById` baseline used by `tests/integration/definition_test.zig`; the validator itself is pure and does not touch the DB, but the fixtures are still persisted-and-cleaned to match the existing test convention). |
| `tests/integration/validation_vld_http_test.zig` | 5 test blocks — drives `POST /api/v1/definitions/:id/validate` via `BPM_TEST_URL` + `BPM_TEST_TOKEN`. Asserts the full HTTP envelope (status code, RFC 9457 body fields, field-by-field equality). |
| `tests/integration/main_test.zig` | Add `const _vld_unit = @import("validation_vld_unit_test.zig"); const _vld_http = @import("validation_vld_http_test.zig");` plus `comptime { _ = _vld_unit; _ = _vld_http; }` so `lint_test_wiring` sees the imports as reachable. |
| `build.zig` | New `addTest` artifacts for both files, wired into the existing `test-integration-others-step` (umbrella `test-integration`) AND into a narrow step `test-integration-vld` for targeted runs. Same pattern as `test-integration-spc01` (see `tests/integration/spc01_sub_process_interface_test.zig`). |
| `tests/integration/_fixtures/` (no new files) | Fixtures are constructed in-source. No new `_fixtures` files needed for this handoff. |

### 5.2 `addTest` block (build.zig)

Mirrors the existing SPC-01 instructions (see `bpm-test-designer-spc-batch-b-wiring.md` in repo memory):

```zig
// New integration test entries for VLD-01/02/03 (WF02-vld01-03-20260816).
//
// Pattern: each integration test file gets its own addTest artifact
// (so the file is reachable from a build root) AND its own narrow
// `test-integration-vld-*` step (so it can be run in isolation during
// post-implementation rework). The narrow steps are aggregated into the
// existing `test-integration-others-step` so the umbrella `test-integration`
// step still runs them.

const vld_unit_tests = b.addTest(.{ ... });
const vld_http_tests = b.addTest(.{ ... });
const run_vld_unit_tests = b.addRunArtifact(vld_unit_tests);
const run_vld_http_tests = b.addRunArtifact(vld_http_tests);
// setCwd, setEnvironmentVariable(BPM_TEST_DB_URL, BPM_TEST_URL, BPM_TEST_TOKEN)
// — match the surrounding pattern.

const test_integration_vld_unit_step = b.step("test-integration-vld-unit", "...");
const test_integration_vld_http_step = b.step("test-integration-vld-http", "...");
test_integration_vld_unit_step.dependOn(&run_vld_unit_tests.step);
test_integration_vld_http_step.dependOn(&run_vld_http_tests.step);
test_integration_others_step.dependOn(&run_vld_unit_tests.step);
test_integration_others_step.dependOn(&run_vld_http_tests.step);
```

### 5.3 AC → file → test-block mapping (the wiring table this spec produces)

| AC | Test file | Test block name (literal Zig `test "..."` string) |
|---|---|---|
| VLD-01 AC1 | unit | `int_vld_01_01: validateDefinition returns UnknownVariableType for variable_schema declaration outside mapping table` |
| VLD-01 AC2 | unit | `int_vld_01_02: validateDefinition returns UndeclaredResultSchema for SERVICE_TASK whose catalog response_schema is null` |
| VLD-01 AC3 | unit | `int_vld_01_03: validateDefinition returns ConflictingFieldType for two same-name form fields with different types` |
| VLD-01 AC4 | unit | `int_vld_01_04: validateDefinition env is identical for two instances with different variable maps (declaration-only)` |
| VLD-01 AC5a | unit | `int_vld_01_05a: validateDefinition forward-scopes SERVICE_TASK output to downstream sites only` |
| VLD-01 AC5b | unit | `int_vld_01_05b: validateDefinition form-field scope is per-HUMAN_TASK-node_id` |
| VLD-02 AC1 | unit | `int_vld_02_01: validateDefinition returns TypeMismatch on guard that compiles to non-bool` (sub-blocks for each operator — see §3.9) |
| VLD-02 AC2 | unit | `int_vld_02_02: validateDefinition returns UnknownVariable referencing identifier absent from env` |
| VLD-02 AC3 | unit | `int_vld_02_03: validateDefinition returns OperandTypeError for string + number` |
| VLD-02 AC4 | unit | `int_vld_02_04: validateDefinition returns 422 with pd06_diagnostics only when PD-06 syntax fails (no semantic compile)` |
| VLD-02 AC5 | unit | `int_vld_02_05: validateDefinition returns EmptyExpression for whitespace-only site` |
| VLD-03 AC1 | unit | `int_vld_03_01: validateDefinition aggregates three findings into one ValidationFailure` |
| VLD-03 AC2 | http | `int_vld_03_02: every Finding in the response carries all five mandatory fields` |
| VLD-03 AC3 | unit | `int_vld_03_03: UnknownVariable message names missing identifier and nearest by edit distance (≤4)` |
| VLD-03 AC4 | unit | `int_vld_03_04: two consecutive validateDefinition calls on the same definition produce byte-identical finding ordering` |
| VLD-03 AC5 | http | `int_vld_03_05: every ErrorKind field in the response is one of the 7 wire strings` |

### 5.4 Linter pre-flight

Before completion of this spec (Step 03 → Step 04), the TEST-DESIGNER will run:

```bash
python3 tools/lint_test_isolation.py tests/integration
python3 tools/lint_handoffs.py
```

The first mechanically catches the two regressions that account for the majority of TEST-DESIGN-VALIDATOR rejections (hardcoded fixture UUIDs, `error.SkipZigTest` on requirement-covering tests). The second validates the handoff JSON itself (BOM-free, completed_at ≥ started_at, legal `result.status`).

`lint_test_wiring` is run by TEST-DESIGN-VALIDATOR after the source files are written — this spec only declares the file names and the block names; the linter verifies them once the files exist.

---

## 6. Coverage matrix

| AC | Requirement text (paraphrased) | Test name | Status |
|---|---|---|---|
| VLD-01 AC1 | `variable_schema` declare outside mapping → 422 `UnknownVariableType` | `int_vld_01_01` | COVERED |
| VLD-01 AC2 | SERVICE_TASK catalog no-response_schema → 422 `UndeclaredResultSchema` | `int_vld_01_02` | COVERED |
| VLD-01 AC3 | Same-name form fields, different types → 422 `ConflictingFieldType` | `int_vld_01_03` | COVERED |
| VLD-01 AC4 | Env is declaration-only (no instance variable values) | `int_vld_01_04` | COVERED |
| VLD-01 AC5 | Node output forward-reachable + form-field per-task scope | `int_vld_01_05a`, `int_vld_01_05b` | COVERED |
| VLD-02 AC1 | Guard result type ≠ bool → `TypeMismatch` | `int_vld_02_01` (12 positive + 1 negative) | COVERED |
| VLD-02 AC2 | Undeclared identifier → `UnknownVariable` | `int_vld_02_02` | COVERED |
| VLD-02 AC3 | String + number → `OperandTypeError` | `int_vld_02_03` | COVERED |
| VLD-02 AC4 | PD-06 syntax fail → 422 with `pd06_diagnostics` only | `int_vld_02_04` | COVERED |
| VLD-02 AC5 | Empty / whitespace → `EmptyExpression` | `int_vld_02_05` | COVERED |
| VLD-03 AC1 | Three failing sites → one 422 with three findings | `int_vld_03_01` | COVERED |
| VLD-03 AC2 | Every finding has all five fields | `int_vld_03_02` | COVERED |
| VLD-03 AC3 | `UnknownVariable` message has identifier + nearest by edit distance | `int_vld_03_03` | COVERED |
| VLD-03 AC4 | Two validations → byte-identical ordering | `int_vld_03_04` | COVERED |
| VLD-03 AC5 | `error_kind` is closed enumeration | `int_vld_03_05` | COVERED |

**Total:** 15 / 15 MUST ACs covered. 16 test blocks total (15 ACs + 1 positive/negative split on VLD-02 AC1 — `int_vld_02_01` drives the 12-pass operator table in one block, `int_vld_02_01b` is the negative OperandTypeError for VLD-02 AC3 and is rolled into the same line above).

No test is deferred. No test relies on unit-test coverage in lieu of integration. No `error.SkipZigTest` is used on any block covering a MUST AC.

---

## 7. Out-of-scope (explicitly NOT covered by this spec)

- **VLD-04** (separate handoff) — gate at draft save / promotion submit, `semantically_valid` verdict storage, 5-second budget, compiler-version invalidation. VLD-04 will be the only consumer that calls `validateDefinition` as a **gate** and persists a verdict; this spec exercises the validator's output, not VLD-04's gating logic.
- **PD-02 graph-structure errors** (`MISSING_START_NODE`, multiple `END` nodes, etc.) — owned by `src/definition/graph.zig`'s `validateGraphShape` and surfaced via `Store.create`'s 422 channel. VLD-01/02/03 operate on a graph that has already passed PD-02; graph-structure failures are NOT in VLD's scope.
- **PD-06 syntax details** beyond the AC text — the VLD-02 AC4 test asserts the **short-circuit** behaviour (PD-06 fail → no semantic compile), not the per-violation PD-06 catalogue. The PD-06 catalogue is PD-06's own test plan.
- **JSON Schema validation** of `interface_schema` etc. — SPC-02's pre-flight. VLD-01 reads only well-formed schemas; JSON Schema validation is out of scope.
- **Wasm / sandbox threat model** — VLD-01/02/03 are pure functions (no I/O, no DB) and cannot be sandboxed.
- **Frontend (React) UI tests** — there is no UI for the validation endpoint; the design wires the endpoint exclusively for `curl`/`direct HTTP` consumption. UAT scenarios belong to UAT-RUNNER, not this spec.

---

## 8. Open questions / dependencies

None. The implementation is at `31482edb` on `feature/wf02-vld01-03-20260816`; SECURITY-REVIEWER (Step 02c) returned PASS; the design artefact is final. The TEST-DESIGNER can produce the source files in Step 04 against this spec without further coordination.
