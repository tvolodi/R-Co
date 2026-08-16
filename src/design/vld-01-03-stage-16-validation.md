# Module: vld-01-03 — Stage 16 Semantic Validation (typed environment, CEL compile, aggregated diagnostics)

**Requirement IDs:** VLD-01, VLD-02, VLD-03
**Run ID:** WF02-vld01-03-20260816 (Stage 16)
**Type:** Type E — novel cross-cutting design (typed environment builder + CEL semantic compiler + aggregated diagnostic formatters). Type A validation endpoint is reclassified away from the lego template because the handler needs multi-step orchestration (env build → per-site compile → finding collection) that does not fit a single `// CUSTOM:` block (see `templates/lego-catalog.md` "Tip into Type E" — "handler calls more than one store method in sequence, or coordinates with a second module"). Type C is not used: VLD-01/02/03 have **no new persistent table** — findings are returned in the HTTP 422 response body only; the optional `semantically_valid` verdict / compiler_version row is VLD-04's concern and not part of this handoff.
**Authoritative requirement source:** `docs/requirements.yaml` lines 13129–13194 (VLD-01, VLD-02, VLD-03 bodies and acceptance criteria).
**See:** PD-02 (PD-02 graph-structure check runs first), PD-06 (CEL *syntax* check — VLD-02 reads its outcome, runs only after it passes), EE-05 (CEL evaluation already uses the runtime variable map; VLD-02 compiles the same expressions against the *typed* declaration-time map), REPO-07 / SVC-01 (service catalog `response_schema` is the source of SERVICE_TASK output types), PLC-01 (process module `interface_schema` outputs feed the env), PD-05 (node-type attributes — `computed_from`, `visible_when`, `delay`, `assignee_ref`, etc. live here), VLD-04 (separate handoff — owns the gate at draft save / promotion submit, the `semantically_valid` verdict storage, the 5-second budget, and the compiler-version invalidation; VLD-01/02/03 must not depend on VLD-04's storage path).

---

## 1. Module purpose

Stage 16 turns the existing CEL surface — used today only for gateway edge conditions (PD-06) and edge transforms (EXT-04) and validated at definition time only for **syntax**, with semantic checks deferred to runtime (EE-05) — into a statically typed, declaration-grounded pipeline. Three requirements together:

1. **VLD-01**: build a typed environment from the *definition's own declarations* (variable_schema, service-catalog result schemas, module output schemas, human-task form fields). The environment is a static assignment of `TypeTag` to `name` — no instance values contribute.
2. **VLD-02**: compile every CEL expression carried by the definition against the environment visible at that site. Surface a precise `error_kind` taxonomy when the expression is empty, uses an unknown identifier, misuses a type, or produces the wrong result type.
3. **VLD-03**: aggregate every finding from a single validation pass into one HTTP 422 response with a deterministic ordering rule, and constrain `error_kind` to a closed enumeration.

The output of this module is a pure function `validateDefinition(env-input) -> findings` plus a thin HTTP wrapper that returns those findings as RFC 9457 Problem Details. VLD-04 (separate handoff) is the only consumer that calls this function as a **gate** and persists a verdict; VLD-01/02/03 themselves are storage-free.

---

## 2. Classification rationale (why Type E, not A or C)

Per `templates/lego-catalog.md` selection rules:

- **Type C** (migration) — no. VLD-01/02/03 require no new persistent table. The findings are response-only. The `definition_validation_results` / `semantic_verdicts` table VLD-04 introduces is out of scope for this handoff.
- **Type A** (CRUD endpoint) — no. The validation handler does not map 1-to-1 onto a single store method: it must (a) build the typed environment from four sources, (b) walk every expression site, (c) compile each against the per-site env slice, (d) collect all findings, (e) format the response. This is the lego-catalog "tip into Type E" rule ("handler calls more than one store method in sequence, or coordinates with a second module"). The endpoint is documented in §7 as a contract, but the handler logic is the Type E design below.
- **Type E** — yes. The env builder, the per-site compile loop, and the finding-formatter are all genuinely novel and have no template precedent.

So this batch produces **1 Type E design document** (this file) and **0 parameter files**. `artifacts_out` lists this file path only.

---

## 3. Existing pattern followed

Per the handoff's instruction to ground every design in a prior pattern:

- **PD-06 edge-condition syntax check** (`src/definition/graph.zig` lines 1074–1230, `validateEdgeConditions` + `isValidCelSyntax`) is the closest precedent. VLD-02 calls the same `isValidCelSyntax` to decide whether to proceed (VLD-02 AC4); if it returns false, VLD-02 returns the PD-06 diagnostics verbatim without invoking the semantic compiler. The violation shape (`Violation` struct, `ValidationResult { valid, violations }`) is the same shape VLD-03 reuses for `Finding` (the SEMANTIC validation outcome).
- **PLC-01 process module catalog** (`src/design/plc-01-process-module-catalog.md`) is the precedent for "read a typed schema from a sibling module and surface HTTP 422 on absence" — the `UndeclaredResultSchema` and `ConflictingFieldType` error kinds follow the same `ModuleCatalogError` shape: a closed enum, each variant carrying `(node_id, ...)` and implying HTTP 422.
- **SPC-01 sub-process interface contract** (`src/design/spc-01-sub-process-interface-contract.md`) is the precedent for "well-formed JSON Schema is a precondition for typed validation" — SPC-02 already guarantees that every `interface.inputs[].json_schema` and `interface.outputs[].json_schema` is a parsed JSON Schema with supported keywords. VLD-01 reads those already-validated schemas via PLC-01's `process_module_catalog.interface_schema` column.
- **SPD-02 / PD-02 collection-all-violations rule** (`src/definition/graph.zig` line 195: "ALL eight checks are executed and ALL violations are collected before returning") is the precedent for VLD-03 AC1: validation never stops at the first failure. The same `errdefer` + `try` pattern feeds `findings.items` until every site has been visited.
- **expr/ module** (`src/design/expr.md`, `src/design/expr-types.md`) owns the AST, types, and parser. VLD-02 **does not** reimplement type checking; it walks the AST that `expr.parse()` already produces and uses the same `TypeTag` from `expr.types`.

---

## 4. Data model

VLD-01/02/03 introduce **no new persistent tables**. All data below is in-memory for the duration of a single `validateDefinition` call.

### 4.1 `TypedEnv` — the typed environment (VLD-01 AC1–AC5)

A per-site, name → `TypeTag` map. Owned by the validation pass; not serialised.

| Field | Type | Description |
|---|---|---|
| `site_id` | `SiteId` (see §4.2) | The expression site this env slice belongs to. |
| `entries` | `[]Entry` | Ordered: name → mapped type. Key uniqueness is enforced by the builder (VLD-01 AC3). |
| `compiler_version` | `[]const u8` | The compile-time version of the env builder (used by VLD-04 to invalidate cached verdicts — read here, not produced). |
| `warnings` | `[]Warning` | Soft warnings (e.g. unused `variable_schema` entry). NOT findings; emitted as structured logs only. |

```zig
pub const TypeTag = enum {
    string,    // from "string", "text", "enum"
    number,    // from "integer", "decimal", "money"
    bool,      // from "boolean"
    timestamp, // from "date", "datetime"
    list,      // list<T> — element type carried in `element_tag`
    map,       // from "object"
    dyn,       // empty-schema service result; type-checked only at usage
};

pub const Entry = struct {
    name: []const u8,
    tag: TypeTag,
    element_tag: ?TypeTag = null, // populated when tag == .list
    provenance: Provenance,       // where the declaration came from (see §4.3)
    source_node_id: ?[]const u8 = null, // for node output visibility
};

pub const Provenance = enum {
    variable_schema,
    service_result,    // SERVICE_TASK → catalog.response_schema
    module_output,     // SUB_PROCESS → PLC-01 catalog.interface_schema.outputs
    form_field,        // HUMAN_TASK form field
};
```

`TypeTag` mirrors `expr.types.TypeTag` (the six DSL types plus `list`, `map`, `dyn`). The type-mapping table (VLD-01 body) is the single source of truth — see §8.

### 4.2 `SiteId` — expression site identification (VLD-03 AC2, AC4)

A structured identifier used to build `node_id` + `expression_path` on every finding. Two strings, in fixed order:

| Field | Value | Example |
|---|---|---|
| `node_id` | The definition-graph node id (`graph.nodes[i].id`). | `"gw_approve"` |
| `expression_path` | A JSON-Pointer-like path inside the node attribute where the expression lives. Stable, deterministic. | `"/edges/0/condition"`, `"/attributes/assignment"`, `"/attributes/delay"`, `"/attributes/input_mapping/customer_id"`, `"/forms/0/fields/2/visible_when"`, `"/forms/0/fields/2/computed_from"` |

`SiteId` is opaque to the caller and is constructed by the site walker (see §6). Ordering uses lex order on `(node_id, expression_path)` — VLD-03 AC4.

### 4.3 `Finding` — the diagnostic struct (VLD-03 AC2, AC3, AC5)

```zig
pub const ErrorKind = enum {
    UnknownVariable,        // VLD-02 AC2
    TypeMismatch,           // VLD-02 AC1 (result not bool / not the declared type)
    OperandTypeError,       // VLD-02 AC3 (operator mismatch)
    UnknownVariableType,    // VLD-01 AC1 (variable_schema declares an unmapped type)
    UndeclaredResultSchema, // VLD-01 AC2 (service catalog entry has no response_schema)
    ConflictingFieldType,   // VLD-01 AC3 (form-field name collision)
    EmptyExpression,        // VLD-02 AC5
};

pub const Finding = struct {
    node_id: []const u8,         // VLD-03 AC2
    expression_path: []const u8,  // VLD-03 AC2, AC4
    source: []const u8,           // VLD-03 AC2 — the literal CEL source slice
    error_kind: ErrorKind,        // VLD-03 AC2, AC5 — closed enum
    message: []const u8,          // VLD-03 AC2, AC3 (for UnknownVariable: includes identifier + nearest-by-edit-distance)
};
```

`ErrorKind` is a **closed enum** with exactly 7 variants — VLD-03 AC5 ("No `error_kind` value outside the enumerated set is emitted"). The compiler is a `switch` over the enum; adding a variant fails to compile against every existing `switch` (the type checker enforces the closed set). The `toWire()` mapping produces the canonical JSON strings shown in §5.

### 4.4 `ValidationFailure` — the wire aggregate (VLD-03 AC1)

```zig
pub const ValidationFailure = struct {
    findings: []Finding,         // immutable, ordered by (node_id, expression_path)
    pd06_diagnostics: ?[]Pd06Diagnostic, // populated when VLD-02 AC4 fires — verbatim from PD-06
    validated_at: []const u8,    // ISO-8601 UTC instant from `tools/utcnow.py`
    compiler_version: []const u8, // the VLD-04-relevant version
};
```

`findings` is the *aggregation* — VLD-03 AC1 ("one HTTP 422 response contains three findings"). The slice is **all** of them, never truncated.

### 4.5 Storage implication

**VLD-01/02/03 introduce no migration.** The findings live only in the HTTP 422 response of `POST /api/v1/definitions/{id}/validate` (VLD-04's domain) and in the equivalent gating response at draft save (also VLD-04). The optional verdict row that VLD-04 will store is a separate handoff's concern.

---

## 5. API contract

### 5.1 Wire enumerations

The 7 `error_kind` values are serialised as the canonical strings from the requirements:

| Zig enum | Wire string | Source requirement |
|---|---|---|
| `UnknownVariable` | `"UnknownVariable"` | VLD-02 AC2, VLD-03 AC3 |
| `TypeMismatch` | `"TypeMismatch"` | VLD-02 AC1 |
| `OperandTypeError` | `"OperandTypeError"` | VLD-02 AC3 |
| `UnknownVariableType` | `"UnknownVariableType"` | VLD-01 AC1 |
| `UndeclaredResultSchema` | `"UndeclaredResultSchema"` | VLD-01 AC2 |
| `ConflictingFieldType` | `"ConflictingFieldType"` | VLD-01 AC3 |
| `EmptyExpression` | `"EmptyExpression"` | VLD-02 AC5 |

The wire enum is **case-sensitive** and matches the YAML body verbatim. Any future variant requires a requirements change — VLD-03 AC5's "no error_kind value outside the enumerated set is emitted" is enforced *by* keeping the Zig enum closed, not by a runtime allow-list.

### 5.2 HTTP endpoint

`POST /api/v1/definitions/{id}/validate` (this is the VLD-04-named endpoint; VLD-01/02/03 define the *response body*). Request body is empty; the path id identifies the definition version. Auth: PROCESS_DESIGNER or PLATFORM_ADMIN (matches PD-01/PD-02 conventions).

Successful response — the definition is clean:

```json
HTTP/1.1 200 OK
Content-Type: application/problem+json

{
  "status": "semantically_valid",
  "findings": [],
  "validated_at": "2026-08-16T12:00:00Z",
  "compiler_version": "vld-01-03-WF02-vld01-03-20260816"
}
```

Failure response — VLD-01/02/03 produce this RFC 9457 body:

```json
HTTP/1.1 422 Unprocessable Entity
Content-Type: application/problem+json

{
  "type": "https://platform/validation/semantic",
  "title": "Definition failed semantic validation",
  "status": 422,
  "findings": [
    {
      "node_id": "gw_approve",
      "expression_path": "/edges/0/condition",
      "source": "amount >
      "error_kind": "UnknownVariable",
      "message": "UnknownVariable: identifier 'amont' is not declared; did you mean 'amount'?"
    },
    {
      "node_id": "task_collect",
      "expression_path": "/forms/0/fields/2/visible_when",
      "source": "",
      "error_kind": "EmptyExpression",
      "message": "EmptyExpression: expression site on node 'task_collect' at '/forms/0/fields/2/visible_when' is empty or whitespace-only"
    },
    {
      "node_id": "service_lookup",
      "expression_path": "/attributes/input_mapping/customer_id",
      "source": "amount + customer_id",
      "error_kind": "OperandTypeError",
      "message": "OperandTypeError: operator '+' cannot combine operand of type 'number' with operand of type 'string'"
    }
  ],
  "validated_at": "2026-08-16T12:00:00Z",
  "compiler_version": "vld-01-03-WF02-vld01-03-20260816"
}
```

When VLD-02 AC4 fires (PD-06 syntax check failed), `findings` is empty and `pd06_diagnostics` carries the verbatim PD-06 violations (code + message) — the client distinguishes the two cases by the `pd06_diagnostics` field's presence, not by inventing a synthetic `error_kind`. The 422 status code is the same.

### 5.3 Field contracts

- `node_id` — UTF-8 string, opaque identifier borrowed from the definition graph node id. Always non-empty.
- `expression_path` — JSON-Pointer (RFC 6901) string. Always non-empty; the walker never produces a root-only `/` path (every expression site has a parent node attribute).
- `source` — the literal CEL source slice (substring of the JSON definition body). For PD-06-only responses (VLD-02 AC4 carrying through), this carries the truncated syntax-error message string from PD-06 instead. UTF-8.
- `error_kind` — one of the 7 wire strings. Closed set.
- `message` — UTF-8, human-readable. Format rules per error_kind in §9.

### 5.4 Ordering guarantee (VLD-03 AC4)

`findings` is sorted by `(node_id, expression_path)` using byte-wise lex order on the two strings. The same definition produces the same ordering on every invocation. The TD-02-TEST-RUNNER integration tests will assert byte-identity of two consecutive runs.

---

## 6. Per-requirement design

### 6.1 VLD-01 — Typed environment from definition context

#### 6.1.1 Env-builder inputs

The builder consumes four sources, in this order:

1. **Definition's `variable_schema`** (sibling of the graph in the definition JSON): a list of `{name, type}` pairs, where `type` is one of the eight declared names.
2. **Service catalog `response_schema`** (REPO-07, SVC-01): for every SERVICE_TASK node carrying a `service_id` reference, the catalog entry's `response_schema` (a JSON Schema string, fetched via the existing `service_catalog.lookup`; if null → VLD-01 AC2). The names exported into the env are the top-level property names of that schema (recursive flattening is **out of scope** — VLD-01 uses the root keys only).
3. **Process module `interface_schema.outputs`** (PLC-01): for every SUB_PROCESS node carrying a `module_ref`, the resolved catalog entry's `interface_schema["outputs"]` names. Each entry carries its declared `json_schema`; the env uses the simple-type mapping (string/number/bool/timestamp) inferred from the schema's `"type"` keyword at the top level. Names with object/array schemas are emitted as `map`/ respective `list<...>` types.
4. **Human-task form fields** (PD-05 HUMAN_TASK `forms[].fields[]`): each field carries a declared type. Two fields with the same name and different types in the same form trigger VLD-01 AC3. Fields are scoped to their own `node_id` (VLD-01 AC5).

#### 6.1.2 VLD-01 AC1 — `UnknownVariableType`

```zig
for (variable_schema) |vs_entry| {
    const mapped = mapDeclaredTypeName(vs_entry.type) orelse {
        try findings.append(Finding{
            .node_id = "<definition>",       // root-level finding
            .expression_path = "/variable_schema/" ++ vs_entry.name,
            .source = vs_entry.type,
            .error_kind = .UnknownVariableType,
            .message = "UnknownVariableType: variable '" ++ vs_entry.name ++
                       "' declares type '" ++ vs_entry.type ++
                       "' which is outside the mapping table (string, text, enum, integer, decimal, money, boolean, date, datetime, list<T>, object)",
        });
        continue;
    };
    // ... append to env
}
```

The check fires on the **raw declared name string** — even if a synonym-like string such as `"String"` (capital S) is encountered, the mapping is case-sensitive and rejects it (the mapping table is fixed; see §8). The error message names both the variable and the offending type.

#### 6.1.3 VLD-01 AC2 — `UndeclaredResultSchema`

For each SERVICE_TASK node:

```zig
for (service_task_nodes) |node| {
    const ref = node.attributes.service_id orelse continue; // no ref → skipped
    const catalog = service_catalog.lookup(ref) orelse {
        // Missing catalog entry is VLD-01's "no schema" case — see step below
    };
    if (catalog.response_schema == null) {
        try findings.append(Finding{
            .node_id = node.id,
            .expression_path = "/attributes/input_mapping",
            .source = ref,
            .error_kind = .UndeclaredResultSchema,
            .message = "UndeclaredResultSchema: SERVICE_TASK node '" ++ node.id ++
                       "' references catalog entry '" ++ ref ++
                       "' which declares no response_schema",
        });
        continue;
    }
    // ... parse the schema and emit entries into env
}
```

The error names **both** the node id and the failed reference. Note: this fires even when the SERVICE_TASK has no expression sites (the env still won't have any output names exported for it, but the undeclared-schema condition is itself a flat 422).

#### 6.1.4 VLD-01 AC3 — `ConflictingFieldType`

For each HUMAN_TASK node's `forms[i].fields[]`:

```zig
var seen = std.StringHashMap(TypeTag).init(allocator);
defer seen.deinit();
for (form.fields) |field| {
    const mapped = mapDeclaredTypeName(field.type) orelse {
        // ... emit UnknownVariableType-style finding; continue
        continue;
    };
    if (seen.get(field.name)) |existing| {
        if (existing != mapped) {
            try findings.append(Finding{
                .node_id = task_node.id,
                .expression_path = "/forms/" ++ form_index_str ++ "/fields/" ++ field_index_str ++ "/type",
                .source = field.type,
                .error_kind = .ConflictingFieldType,
                .message = "ConflictingFieldType: form field '" ++ field.name ++
                           "' is declared as '" ++ existing_str ++
                           "' (first declaration) and '" ++ mapped_str ++
                           "' (this declaration) within human task scope '" ++ task_node.id ++ "'",
            });
            continue;
        }
    } else {
        try seen.put(field.name, mapped);
    }
    // ... emit env entry, scoped to task_node.id
}
```

The error names **both declarations** — the existing one (the first one seen) and the conflicting one. Within the **same human task scope** (= same `node_id`); fields across two different HUMAN_TASK nodes never conflict (each has its own scope — VLD-01 AC5).

#### 6.1.5 VLD-01 AC4 — declarations only, no instance values

The env builder reads **only** the definition JSON (and the catalog read-only entries), never the instance's variable map. The EE-05 runtime variable map is a separate concept that lives behind `expr.evaluate()`; VLD-02 formalises the AST only against the declaration-derived TypeTag. The `EnvBuilder` constructor takes `Definition + ServiceCatalog + ModuleCatalog` and **no** `Instance` type — the type signature is the static guarantee.

#### 6.1.6 VLD-01 AC5 — scope rules

- **Node output type scope.** A SERVICE_TASK's output entries are visible only to expression sites on **nodes reachable from the SERVICE_TASK** in the directed graph. "Reachable" includes the SERVICE_TASK itself (its own nodes — current behaviour) and any downstream node via the forward edge closure. A pre-computed `forward_reachable_from[node_id]` set (one computed per VLD-01 build, derived from the same graph DFS that PD-02 already computes for cycle detection) drives the visibility filter at site-walk time. SUB_PROCESS module outputs propagate one layer further: their nodes are visible to expression sites on nodes reachable in the parent graph *after* the SUB_PROCESS edge.
- **Form field scope.** A form field's TypeTag is visible only to expression sites that are themselves under the same HUMAN_TASK node's `forms[].fields[]` (`visible_when` and `computed_from`). The `site.walking_node_id == form.node_id` check is the rule. Form fields are **not** inherited by sibling nodes even though they share the same definition scope.

The implementation enforces scope by **filtering the env at compile time** for each site, not by attempting to encode scope into the global env. See §7.2 for the per-site slice.

### 6.2 VLD-02 — Expression compile and type check

#### 6.2.1 VLD-02 AC1 — `TypeMismatch` (result type)

```zig
fn checkResultType(expected: TypeTag, compiled: TypeTag, site: SiteId, source: []const u8) !void {
    if (expected != compiled) {
        try findings.append(Finding{
            .node_id = site.node_id,
            .expression_path = site.expression_path,
            .source = source,
            .error_kind = .TypeMismatch,
            .message = "TypeMismatch: expected '" ++ @tagName(expected) ++
                       "', got '" ++ @tagName(compiled) ++
                       "' at site '" ++ site.node_id ++ site.expression_path ++ "'",
        });
    }
}
```

The `expected` is per-site:

| Site | Expected type |
|---|---|
| EXCLUSIVE_GATEWAY edge condition (PD-06) | `bool` |
| EXCLUSIVE_GATEWAY edge default — no expression | n/a (no compile) |
| HUMAN_TASK assignment expression | `string` (a role name string) |
| HUMAN_TASK timer delay | `timestamp` (or `number` reinterpreted as ms-since-epoch; documented §8.4) |
| SERVICE_TASK input mapping value | the corresponding input schema type from the catalog entry's `request_schema` |
| Form `visible_when` | `bool` |
| Form `computed_from` | the declared field type of the field itself |

#### 6.2.2 VLD-02 AC2 — `UnknownVariable` + edit-distance suggestion (VLD-03 AC3)

The compiler emits `UnknownVariable` (VLD-02 AC2) when an identifier in the AST cannot be resolved in the site's env. The **message** follows the VLD-03 AC3 format:

```zig
fn unknownVariableMessage(missing: []const u8, env: *const TypedEnv, allocator: Allocator) ![]const u8 {
    var nearest: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (env.entries) |e| {
        const d = editDistance(missing, e.name);
        if (d < best_dist) {
            best_dist = d;
            nearest = e.name;
        }
    }
    if (nearest) |n| {
        return std.fmt.allocPrint(allocator,
            "UnknownVariable: identifier '{s}' is not declared; did you mean '{s}'?",
            .{missing, n});
    }
    return std.fmt.allocPrint(allocator,
        "UnknownVariable: identifier '{s}' is not declared in the visible environment",
        .{missing});
}
```

`editDistance` is Levenshtein over the byte slices. The suggestion is the *nearest declared identifier* by edit distance (VLD-03 AC3). When the nearest is the identifier itself (edit distance 0), the suggestion is omitted (the message becomes the no-match form). The wire `error_kind` is still `UnknownVariable` regardless of whether a suggestion is present.

#### 6.2.3 VLD-02 AC3 — `OperandTypeError`

For every operator node in the AST whose operand TypeTags are incompatible (`+`/`-`/`*`/`/`/`%` on `string` or `bool`; `==`/`!=` on `map` ↔ `list`; `and`/`or` on `number`):

```zig
try findings.append(Finding{
    .node_id = site.node_id,
    .expression_path = site.expression_path,
    .source = source,
    .error_kind = .OperandTypeError,
    .message = "OperandTypeError: operator '" ++ op_str ++
               "' cannot combine operand of type '" ++ @tagName(left_tag) ++
               "' with operand of type '" ++ @tagName(right_tag) ++
               "' at site '" ++ site.node_id ++ site.expression_path ++ "'",
});
```

The message names **both** operand types and the operator. The check is symmetric (the message identifies the operator regardless of which side is the "wrong" one).

#### 6.2.4 VLD-02 AC4 — PD-06 syntax check is a hard gate

The `validateDefinition` entry-point runs the existing `graph.zig` `validateEdgeConditions` (PD-06) **first**, on **every** expression site. If the syntactic check fails at any site, the *semantic* compile loop **does not** execute for that site. The overall response:

- `findings` is empty (semantic compilation didn't run).
- `pd06_diagnostics` is populated with the verbatim PD-06 violation list (each entry keeps its PD-06 code + message).
- HTTP status is 422.

Implementation:

```zig
const pd06 = graph.validateEdgeConditions(allocator, graph_obj);
const transforms = graph.validateEdgeTransforms(allocator, graph_obj);
// ... aggregate PD-06 violations for every expression site, including those
// in node attributes that validateEdgeConditions does not currently cover.

if (pd06.violations.len > 0 or transforms.violations.len > 0 or /* other PD-06 sites */) {
    return ValidationFailure{
        .findings = &[_]Finding{},
        .pd06_diagnostics = pd06.violations,
        .validated_at = now(),
        .compiler_version = env_version,
    };
}

// PD-06 clean → proceed to VLD-02 semantic compile loop
```

The "other PD-06 sites" includes the gap for VLD-02 to also surface as 422 (VLD-02 body: "Compilation runs only after the PD-02 structure check and the PD-06 syntax check pass"). The PD-06 surface is being widened in this handoff to cover timer delay, assignment, and form expressions as well — the precise list is owned by the existing PD-06 channel; VLD-02 just reads its verdict.

#### 6.2.5 VLD-02 AC5 — `EmptyExpression`

Each site is read as the raw source string. Before any other compile step, the walker checks:

```zig
fn isEmptyOrWhitespace(s: ?[]const u8) bool {
    const src = s orelse return true;
    for (src) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return false;
    }
    return true;
}
```

A `true` result fires `EmptyExpression` and short-circuits all other compile checks for that site (one finding per site, never two). The `source` field on the finding is the literal source slice (empty string `""` in the typical case), preserving the VLD-03 AC2 contract.

### 6.3 VLD-03 — Aggregated validation diagnostics

#### 6.3.1 VLD-03 AC1 — collect-all, never stop

The env builder and the site compile loop both collect into the same `findings: ArrayList(Finding)` until **every** site has been visited. No early-exit on the first error. The "stop at first PD-06 error" property of `isValidCelSyntax` is upstream — VLD-02 AC4 — and only blocks the *semantic* compile, not the syntax check's own multi-error recovery (which PD-06 already does).

#### 6.3.2 VLD-03 AC2 — field set on every finding

See §4.3. The struct is exhaustive; serialisation writes every field; the JSON wire shape is the same regardless of `error_kind`. Test-Designer will assert every field is non-empty (excluding `source` for `EmptyExpression`, where the source is `""`).

#### 6.3.3 VLD-03 AC3 — message format for `UnknownVariable`

See §6.2.2. The format is: `"UnknownVariable: identifier '<missing>' is not declared; did you mean '<nearest>'?"` (or the no-match form when no declared identifier is within edit-distance ≤ 4 — the threshold is a constant; subjects are the existing `expr.types` constants for environment builders).

#### 6.3.4 VLD-03 AC4 — deterministic ordering

```zig
std.sort.block(Finding, findings.items, {}, struct {
    fn lt(_: void, a: Finding, b: Finding) bool {
        if (!std.mem.eql(u8, a.node_id, b.node_id)) {
            return std.mem.lessThan(u8, a.node_id, b.node_id);
        }
        return std.mem.lessThan(u8, a.expression_path, b.expression_path);
    }
}.lt);
```

The sort is byte-wise lex, not locale-aware. Two runs of the same definition produce identical ordering; the test will assert byte-identity.

#### 6.3.5 VLD-03 AC5 — closed enumeration

Enforced by the Zig `enum` type (§4.3). The `switch` exhaustive-coverage warning at every `error_kind` dispatch site will catch any future addition at compile time. The wire serialiser (`toWire`) is a `switch` with a `comptime` guarantee that every variant has a wire string — adding a variant without a wire string is a Zig compile error.

---

## 7. CEL integration point

### 7.1 Where expression compilation lives today

| Source | Role |
|---|---|
| `src/expr/lexer.zig`, `src/expr/parser.zig` | Lex + parse CEL source into an AST. |
| `src/expr/ast.zig` | AST node tagged union, `TypeTag`, `Value` type. |
| `src/expr/mod.zig` | `parse()` public API; `evaluate()` stub. |
| `src/definition/graph.zig` `:1186` | `isValidCelSyntax` — pure syntax check used by PD-06. |
| `src/definition/graph.zig` `:1074` | `validateEdgeConditions` — runs the syntax check on every edge condition. |

The **type checker does not exist yet**. PD-06 only verifies syntax (`isValidCelSyntax`); EE-05 only evaluates against the runtime variable map. VLD-02 introduces the type-checker between the two.

### 7.2 The new module: `src/validation/`

```
src/validation/
├── mod.zig        — public API: validateDefinition(...), ValidationFailure, Finding
├── env.zig        — TypedEnv builder, Entry, Provenance, mapDeclaredTypeName
├── scope.zig      — forward_reachable_from[node_id] set
├── typecheck.zig  — type checker: TypedEnv + AST → () | findings
├── site.zig       — SiteId walker: Definition → enumerated (site, source-slice, expected-type)
├── pd06.zig       — PD-06 re-entry: aggregates validateEdgeConditions + validateEdgeTransforms + form/timer/assignment
├── finding.zig    — Finding struct, ErrorKind enum, toWire, sort, dedupe
└── wire.zig       — HTTP-layer: serialize ValidationFailure → RFC 9457 body
```

Strict layering: `mod.zig` orchestrates `env → pd06 → site → typecheck → finding`. `typecheck.zig` depends on `expr/ast.zig` and `expr/types.zig` only — **no engine, no DB, no allocations beyond a fixed-budget arena** (the 5-second budget is VLD-04's, but the type checker itself is allocation-bounded per site).

### 7.3 The per-site compile contract

For each `(SiteId, source-slice, expected-type)` triple:

1. **VLD-02 AC5 first** — check `isEmptyOrWhitespace(source)`. If true, emit `EmptyExpression` and return.
2. **PD-06 syntax check** — call `isValidCelSyntax(source)`. If false, the *PD-06-level* fail is the caller's problem (the v1 caller in `mod.zig` aggregates PD-06 once and short-circuits the whole validation; future VLD-04 gate integration will pass through the PD-06 fault per site). When per-site PD-06 fails, the response is 422 with `pd06_diagnostics` populated; semantic compile is skipped.
3. **VLD-02 type compile** — `parse(source)` → AST → `typecheck(env, ast, expected_type)`:
   - Walk the AST. For each `dot_path` node, resolve the first segment against the env. If absent → `UnknownVariable` (VLD-02 AC2).
   - For each binary operator, validate operand types. If incompatible → `OperandTypeError` (VLD-02 AC3).
   - For each unary/method call, type-check arguments.
   - At the root, compare the computed type to `expected_type`. If different → `TypeMismatch` (VLD-02 AC1).

Each finding is appended to the shared `findings` list. The compile loop **continues** to the next site regardless of findings collected so far.

### 7.4 Dependency diagram

```
[Definition JSON] ──► env.zig (read ServiceCatalog + ModuleCatalog) ──► TypedEnv
                                                                       │
                                                                       ▼
[Definition graph] ──► scope.zig (forward-reachable DFS) ──► per-site env slice
                                                                       │
                                                                       ▼
                   site.zig (enumerate every expression site) ──► []SiteSpec
                                                                       │
                                                                       ▼
                   pd06.zig (syntax check) ──► 422 with PD-06 if any fail
                                                                       │
                                              ▼ (PD-06 clean)
                   typecheck.zig (AST + TypedEnv + expected) ──► []Finding
                                                                       │
                                                                       ▼
                   finding.zig (sort, dedupe) ──► ValidationFailure
                                                                       │
                                                                       ▼
                   wire.zig (RFC 9457 body) ──► HTTP 422
```

---

## 8. Type mapping table (VLD-01 body)

The single source of truth for declared-type-name → `TypeTag`. Every other module that needs this mapping imports from `validation/env.zig`.

| Declared name (case-sensitive) | `TypeTag` | Notes |
|---|---|---|
| `string` | `string` | direct |
| `text` | `string` | synonym |
| `enum` | `string` | the value space is constrained by the JSON Schema's `enum` keyword; env records the *type*, not the constraint |
| `integer` | `number` | whole-number subtype; env does not distinguish int vs float |
| `decimal` | `number` | |
| `money` | `number` | currency metadata lives in the JSON Schema, not the env |
| `boolean` | `bool` | |
| `date` | `timestamp` | date-only is widened to timestamp for CEL comparison purposes |
| `datetime` | `timestamp` | |
| `list<T>` | `list<mapped_T>` | recursive mapping: `T` is mapped via the same table; an `list<unknown>` shape falls back to `list<dyn>` (env accepts but typechecks only at element-level usage) |
| `object` | `map` | properties are not flattened into the env (VLD-01 §6.1.1 source 2) — the env entry is `map` and the field access is recorded at the AST-walk site with a `dyn` resolution |
| anything else | n/a → `UnknownVariableType` | VLD-01 AC1 |

The mapping table is **case-sensitive on declared names**. Capitalisation variants (`"String"`, `"INTEGER"`) are rejected. This is deliberate: the platform's `variable_schema` convention is lowercase, and accepting synonyms here would itself be a typo magnet.

---

## 9. Error taxonomy

The 7 error kinds are emitted in exactly the situations listed below. **No other situations emit any of them**, and **no other error kind is emitted** (VLD-03 AC5).

### 9.1 `UnknownVariable` (VLD-02 AC2 / VLD-03 AC3)

**Emitted when:** an identifier in the AST cannot be resolved in the site's env (the env filter has been applied for scope — visibility is satisfied — but the name is missing).

**Message format:**
```
UnknownVariable: identifier '<missing>' is not declared; did you mean '<nearest>'?
```

When no declared identifier is within edit-distance ≤ 4 (or the env is empty):
```
UnknownVariable: identifier '<missing>' is not declared in the visible environment
```

`<missing>` is the literal bytes from the AST `.dot_path` first segment. `<nearest>` is the env entry with the lowest Levenshtein distance to `<missing>`; ties broken by byte-wise lex order on `entry.name`.

### 9.2 `TypeMismatch` (VLD-02 AC1)

**Emitted when:** the AST's root TypeTag does not match the per-site expected type.

**Message format:**
```
TypeMismatch: expected '<expected>', got '<actual>' at site '<node_id><expression_path>'
```

`expected` is per-site (see §6.2.1). `actual` is the computed TypeTag at the AST root.

### 9.3 `OperandTypeError` (VLD-02 AC3)

**Emitted when:** a binary operator is applied to incompatible operand types.

**Message format:**
```
OperandTypeError: operator '<op>' cannot combine operand of type '<left>' with operand of type '<right>' at site '<node_id><expression_path>'
```

`<op>` is one of `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `and`, `or`. `<left>` and `<right>` are the operand TypeTags.

### 9.4 `UnknownVariableType` (VLD-01 AC1)

**Emitted when:** `variable_schema` (or any other declaration source) has a type name outside the §8 mapping table.

**Message format:**
```
UnknownVariableType: variable '<name>' declares type '<raw>' which is outside the mapping table (string, text, enum, integer, decimal, money, boolean, date, datetime, list<T>, object)
```

`<raw>` is the literal declared type string. The mapping list in the message is the canonical `string, text, enum, integer, decimal, money, boolean, date, datetime, list<T>, object` — that order itself is the spec.

### 9.5 `UndeclaredResultSchema` (VLD-01 AC2)

**Emitted when:** a SERVICE_TASK references a catalog entry whose `response_schema` is null.

**Message format:**
```
UndeclaredResultSchema: SERVICE_TASK node '<node_id>' references catalog entry '<service_id>' which declares no response_schema
```

The catalog entry existing but having a null `response_schema` is distinct from the entry not existing at all (which is a different REPO-07 error class, not in VLD's scope).

### 9.6 `ConflictingFieldType` (VLD-01 AC3)

**Emitted when:** two fields in the same form (same HUMAN_TASK scope) declare the same name with different types.

**Message format:**
```
ConflictingFieldType: form field '<name>' is declared as '<first_type>' (first declaration) and '<second_type>' (this declaration) within human task scope '<node_id>'
```

`<first_type>` and `<second_type>` are the mapped `TypeTag` names. The first declaration is the one earlier in `forms[].fields[]` order.

### 9.7 `EmptyExpression` (VLD-02 AC5)

**Emitted when:** an expression site holds an empty or whitespace-only string. Detected before the AST parse, so the CEL compiler never sees a malformed input.

**Message format:**
```
EmptyExpression: expression site on node '<node_id>' at '<expression_path>' is empty or whitespace-only
```

The `source` field on the finding carries the empty / whitespace string exactly. The type checker does not run for that site.

### 9.8 What is NOT emitted

The following are outside VLD-01/02/03's scope and are **not** mapped onto `error_kind`:

| Situation | Owner | Why not a VLD error_kind |
|---|---|---|
| Service catalog entry does not exist | REPO-07 (`ModuleNotFound` 404) | pre-VLD surface; VLD env cannot be built at all |
| JSON Schema on `interface.*` is malformed | SPC-02 (already 422) | upstream gate; VLD reads only well-formed schemas |
| Module ref cannot be resolved | PLC-01 (`UnresolvedModuleRef` 422) | upstream gate; VLD env cannot be built |
| Expression site is missing entirely (key absent from JSON) | PD-05 (already 422) | pre-VLD surface; VLD-02 AC5 only fires when a site is *present* but empty |
| Definition has no `variable_schema` | VLD-01 assumes an empty schema (zero entries) | not an error — an empty schema is legitimate |

---

## 10. Scope rules — formal definitions

The two scope rules (VLD-01 AC5) are the only way the env's reach is constrained. The implementation is in `scope.zig` and `site.zig`.

### 10.1 Node output visibility

Let `R(n)` = forward-reachable set from node `n` in the directed graph (including `n` itself; computed once via DFS on the graph adjacency). The env entry for a SERVICE_TASK node `n`'s output is appended to the per-site env only when:

```
site.walking_node_id ∈ R(n)
```

For a SUB_PROCESS node `n` carrying a `module_ref` whose resolved catalog entry has `interface_schema.outputs` `O`:

```
site.walking_node_id ∈ R_parent(n)
```

where `R_parent` is the forward-reachable set in the *parent* graph (the one being validated). The module's outputs are visible to nodes that follow the SUB_PROCESS in the parent graph, exactly as if they were produced by the SUB_PROCESS node itself.

Cycle handling: the DFS that computes `R(n)` already handles the existing directed-graph cycle detection in PD-02; R(A) intersects R(B) is well-defined cyclic-visited-wise. No new cycle-handling logic is added.

### 10.2 Form field visibility

A form field's TypeTag is visible only to expression sites whose `parent_node_id` is the same `node_id` as the HUMAN_TASK node whose form carries the field. Less formally: a field's type is only visible to `visible_when` and `computed_from` expressions on the **same form, same field** (plus `visible_when` on other fields in the same form — see **10.3**).

### 10.3 Inter-field references within a form

`visible_when` on field `f_i` can reference any field `f_j` (`j ≤ i`) in the same form — `j > i` is reserved for forward references that VLD-02 is **not** in scope to evaluate (the runtime EE-05 evaluates them; the *type* is available in the env for `f_j` because `f_j` is declared in the same form). The env builder emits all fields of the form into the per-form env; the runtime is responsible for the ordering rule. VLD-02 only compiles the *type* of the reference — it does not enforce the `j ≤ i` rule (that's a separate PD-05 attribute check, not a VLD concern).

---

## 11. Migration sketch

**VLD-01/02/03 introduce no new persistent table.** There is no new migration file. The `/validation/` endpoint, the env builder, the type checker, and the finding formatter are all in-process Zig modules.

The following Type-E-only list is therefore **empty**:

```
migrations/
  (no new files for VLD-01/02/03)
```

If VLD-04 (separate handoff) chooses to store a `semantically_valid` verdict row, that table is VLD-04's responsibility and will be filed under a separate design + migration pair. VLD-01/02/03's `compiler_version` field on `ValidationFailure` is the data VLD-04 will read to implement its "re-verify when compiler version differs" rule.

---

## 12. Test plan pointers (for TEST-DESIGNER)

The test plan below names the *intent* of each test, not the assertions. TEST-DESIGNER authors the actual cases.

### 12.1 Unit tests (VLD-01 env builder)

- `env_test_unknown_variable_type` — `variable_schema` with `type: "strng"` (typo) → one `UnknownVariableType` finding naming the variable and the type.
- `env_test_undeclared_result_schema` — SERVICE_TASK referencing a catalog entry with `response_schema: null` → one `UndeclaredResultSchema` finding naming the node and the reference.
- `env_test_conflicting_field_type` — form with two fields of the same name, different types → one `ConflictingFieldType` finding naming both declarations.
- `env_test_declarations_only` — env builder produces the same `TypedEnv` for two instances with different variable values (the env takes no instance parameter).
- `env_test_node_output_scope` — an expression site upstream of a SERVICE_TASK cannot see that SERVICE_TASK's outputs; an expression site downstream can.
- `env_test_form_field_scope` — a form field's type is visible to `visible_when` on the same field and on other fields in the same form; not visible to a sibling HUMAN_TASK node's expressions.

### 12.2 Unit tests (VLD-02 type checker)

- `typecheck_test_guard_type_mismatch` — `condition: "42"` (literal int) on an EXCLUSIVE_GATEWAY edge → one `TypeMismatch` finding naming `bool` as expected and `number` as actual.
- `typecheck_test_unknown_variable` — `condition: "amount_gt_100"` (typo) → one `UnknownVariable` finding naming the identifier and the nearest (e.g. `amount`) by edit distance.
- `typecheck_test_operand_type_error` — `condition: "amount + customer_id"` where `customer_id` is `string` → one `OperandTypeError` naming `+` and both operand types.
- `typecheck_test_pd06_gate` — `condition: "amount >"` (syntax error) → 422 with `pd06_diagnostics` populated, `findings` empty.
- `typecheck_test_empty_expression` — `condition: "   "` (whitespace-only) → one `EmptyExpression` finding; the AST compiler is not invoked.

### 12.3 Unit tests (VLD-03 aggregator)

- `aggregate_test_three_findings_in_one_response` — a definition with three failing expression sites → HTTP 422 with one response carrying three entries in `findings`.
- `aggregate_test_finding_field_set` — every serialised finding carries `node_id`, `expression_path`, `source`, `error_kind`, `message` (assert each non-empty; `source` may be empty for `EmptyExpression`).
- `aggregate_test_unknown_variable_message` — every `UnknownVariable` finding carries the identifier and the nearest declared identifier by edit distance.
- `aggregate_test_ordered_by_node_id_then_expression_path` — run the validation twice on the same definition; compare the bytes of `findings` byte-for-byte.
- `aggregate_test_error_kind_is_closed` — every `error_kind` value in the response is one of the 7 wire strings; a synthetic value like `"UnknownMethod"` causes the test to fail.

### 12.4 Integration tests

- `int_test_validate_endpoint_clean` — `POST /api/v1/definitions/{id}/validate` on a clean definition → 200, `findings: []`.
- `int_test_validate_endpoint_dirty` — `POST /api/v1/definitions/{id}/validate` on a dirty definition → 422, body matches §5.2 shape.
- `int_test_validate_endpoint_role_check` — non-PROCESS_DESIGNER caller → 403.
- `int_test_validate_persistent` — the same definition under two different tenants with two different private variable schemas produces two different envs and two different findings (no cross-tenant leak).

### 12.5 Conformance / property tests

- `prop_test_finding_sort_is_idempotent` — sort the findings array twice; the two results are byte-identical.
- `prop_test_env_does_not_depend_on_instance` — for any definition, the env is the same regardless of the runtime instance's variable map.
- `prop_test_edit_distance_is_symmetric` — Levenshtein between missing and nearest is at most 4 (the suggestion threshold).

---

## 13. Migration / file changes summary

| Path | Change | Owner |
|---|---|---|
| `src/validation/mod.zig` (new) | Public API; orchestrates env → pd06 → site → typecheck → finding. |
| `src/validation/env.zig` (new) | `TypedEnv` builder, `TypeTag`, `mapDeclaredTypeName`. |
| `src/validation/scope.zig` (new) | `forward_reachable_from[node_id]` DFS. |
| `src/validation/typecheck.zig` (new) | AST + `TypedEnv` → `[]Finding`. |
| `src/validation/site.zig` (new) | Definition → enumerated `(SiteId, source, expected)`. |
| `src/validation/pd06.zig` (new) | Aggregates `validateEdgeConditions` + `validateEdgeTransforms` + form/timer/assignment sites. |
| `src/validation/finding.zig` (new) | `Finding`, `ErrorKind`, sort, dedupe, `toWire`. |
| `src/validation/wire.zig` (new) | HTTP-layer serialiser. |
| `src/definition/graph.zig` | **No change.** `isValidCelSyntax` and `validateEdgeConditions` are reused unchanged. |
| `src/expr/ast.zig`, `src/expr/types.zig` | **No change.** The type checker reads them but does not modify them. |
| `src/lua/service_catalog.zig` | **No change.** `response_schema` is read-read-only. |
| `migrations/` | **No new files.** VLD-01/02/03 are storage-free. |
| `docs/requirements.yaml` | VLD-01, VLD-02, VLD-03 `status` transition from `DRAFT` to `RELEASED` after the round of WF-02 testing. **NOT a CODE-DESIGNER change** — DOC-UPDATER owns this. |

---

## 14. Dependencies

| Dependency | Direction | What it provides |
|---|---|---|
| `src/expr/` | VLD-02 reads | AST, `TypeTag`, `parse()`. |
| `src/definition/graph.zig` | VLD-02 reads | `validateEdgeConditions`, `validateEdgeTransforms`, `isValidCelSyntax`. |
| `src/lua/service_catalog.zig` | VLD-01 reads | `response_schema` lookup. |
| `src/definition/sub_process_interface.zig` (SPC-01) | VLD-01 reads | `interface_schema` shape and JSON Schema validation. |
| `src/repository/process_module_catalog.zig` (PLC-01) | VLD-01 reads | Resolved module outputs. |
| `src/obs/audit_log.zig` (OBS-03) | VLD-02 calls (read-only) | `DEFINITION_VALIDATED` / `DEFINITION_VALIDATION_FAILED` events are VLD-04's, but the canonical append logic lives here. |
| `src/obs/structured_logging.zig` (OBS-01) | VLD-02 calls | Env-build warnings, "skipping site X (already failed PD-06)" notes. |

### What this module MUST NOT depend on

- `src/engine/` — type-check is a *static* analysis; runtime engine is irrelevant.
- `src/api/` — VLD-01/02/03 are below the HTTP layer (the wire module is the only HTTP touchpoint).
- `src/db/` — no DB; VLD-04 is the persistence boundary.
- `src/admin/`, `src/scheduler/`, `src/lua/`, `src/dlq/`, `src/event_store/` — orthogonal to semantic validation.

---

## 15. Open questions

1. **Edit-distance threshold.** The current design uses `≤ 4` as the suggestion threshold. Should this be a fixed constant exposed in the wire enum (so the field's value drives a configurable UX), or hard-coded? The threshold constant is a candidate for migration to a `validation/env.zig` configurable. **Flag:** REQ-ANALYST clarification recommended before VLD-04 ships VLD-01/02/03 to a customer-facing environment.
2. **List element type fallback.** When `list<T>` carries an unresolvable `T` (e.g. `list<foo>` where `foo` is not a declared name), the design currently falls back to `list<dyn>` and surfaces a `UnknownVariableType` finding when a dot-path is resolved against the element. Should the env builder hold the unresolvable `T` as the literal `dyn` and *not* emit, deferring all type-checking to the AST walker? **Flag:** SPEC ambiguity — recommend REQ-ANALYST clarify.
3. **Form `computed_from` inheritance of the field's type.** The expected type for `computed_from` is the field's own declared type. Should this be the *mapped* `TypeTag` (e.g. `string`) or the *raw* declared name (e.g. `enum`)? The current design uses the mapped type. **Flag:** SPEC ambiguity — recommend REQ-ANALYST clarify.
4. **Should `service_request_schema` (the input side of a SERVICE_TASK) also feed the env?** VLD-01 body mentions only result schemas (REPO-07 / SVC-01). The current design does not import the request schema into the env. If the request side is also needed to type-check `input_mapping` expressions, the env builder needs a second pass. **Flag:** SPEC ambiguity — recommend REQ-ANALYST clarify.
5. **Cross-batch visibility of SUB_PROCESS outputs.** When a SUB_PROCESS node's `module_ref` resolves to a module whose `interface_schema.outputs` references a type from the parent's `variable_schema` (e.g. parent has `order_id: string` and the module inherits it back), the env builder must emit the order_id along the *forward* reachability chain but not along the *backward* one. The current design only handles forward. **Flag:** REQ-ANALYST clarification needed if nested modules are in scope.
6. **Audit logging.** VLD-04's `DEFINITION_VALIDATED` / `DEFINITION_VALIDATION_FAILED` events are appended by VLD-04's gate, not by VLD-01/02/03. The current design treats VLD-01/02/03 as read-only of the audit log (it does not append). Confirm with VLD-04 that this is the intended split. **Flag:** cross-batch consistency check.

---

## 16. Acceptance criteria coverage

| Req | AC | Where covered | Notes |
|---|---|---|---|
| VLD-01 | AC1 — type name outside mapping → `UnknownVariableType` | §6.1.2, §9.4, §12.1 | Variable name + type in the message body. |
| VLD-01 | AC2 — SERVICE_TASK catalog entry with no `response_schema` → `UndeclaredResultSchema` | §6.1.3, §9.5, §12.1 | Node id + reference in the message. |
| VLD-01 | AC3 — two form fields, same name, different types → `ConflictingFieldType` | §6.1.4, §9.6, §12.1 | Both declarations named in the message. |
| VLD-01 | AC4 — env from declarations only | §4.1, §6.1.5, §12.1 dependency test | `EnvBuilder` constructor signature excludes `Instance`. |
| VLD-01 | AC5 — node output visibility + form-field scope | §6.1.5, §10, §12.1 | Forward-reachable DFS + per-form scoping. |
| VLD-02 | AC1 — guard not bool → `TypeMismatch` | §6.2.1, §9.2, §12.2 | Expected + actual named. |
| VLD-02 | AC2 — missing identifier → `UnknownVariable` | §6.2.2, §9.1, §12.2 | Identifier named. |
| VLD-02 | AC3 — string + number → `OperandTypeError` | §6.2.3, §9.3, §12.2 | Operator + both operand types. |
| VLD-02 | AC4 — PD-06 syntax fail → semantic compile skipped | §6.2.4, §7.3, §12.2 | `pd06_diagnostics` carries the PD-06 list verbatim. |
| VLD-02 | AC5 — empty/whitespace expression → `EmptyExpression` | §6.2.5, §9.7, §12.2 | Pre-parse check. |
| VLD-03 | AC1 — three failures → one 422 with three findings | §6.3.1, §12.3 | Collect-all, no early exit. |
| VLD-03 | AC2 — every finding has node_id, expression_path, source, error_kind, message | §4.3, §5.3, §12.3 | Exhaustive struct. |
| VLD-03 | AC3 — `UnknownVariable` message names identifier + nearest by edit distance | §6.2.2, §6.3.3, §9.1, §12.3 | Levenshtein. |
| VLD-03 | AC4 — ordered by node_id then expression_path, deterministic | §5.4, §6.3.4, §12.3 | Byte-wise lex sort. |
| VLD-03 | AC5 — `error_kind` outside the enumerated set is never emitted | §4.3, §5.1, §9, §12.3 | Closed Zig enum; wire serialiser is exhaustive. |

**All 15 ACs are covered.** A VLD-04 follow-on handoff will own the persistent verdict row, the draft-save gate, the promotion gate, the 5-second budget, and the compiler-version invalidation rule. VLD-01/02/03 are storage-free and the lego-catalog classification is Type E only (no parameter files, no new migrations).
