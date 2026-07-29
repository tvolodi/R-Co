# Process: Definition Semantic Validation

| Field | Value |
|-------|-------|
| Process ID | `sys-definition-semantic-validation` |
| Owner | Tenant Admin / Authoring Agent |
| Scope | System-wide (per-tenant namespace) |
| Platform Workflow | PW-02 |
| Requirements | VLD-01, VLD-02, VLD-03, VLD-04 |
| Source | `docs/workflows.yaml` (PW-02) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.10 (FR-VAL-4) |

## Summary

Compiles every CEL expression carried by a definition against a typed
environment built from that definition's own variable context, so a type error
or a reference to an undeclared variable fails at authoring time and again at
promotion time instead of surfacing as a runtime evaluation error. This closes
the gap left by PD-06, which validates CEL syntax only and defers semantics to
EE-05 at execution time.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Tenant Admin | Human author | Saves and validates definition drafts through the authoring UI |
| Authoring Agent | Agent identity | Submits generated definitions; receives the diagnostic report as structured JSON |
| BPM Platform | System | Builds the typed environment, compiles every expression, aggregates diagnostics |
| Promotion Pipeline | System | Calls validation as a hard gate before the promotion plan is computed (PW-01) |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `definition_id` | UUID | The draft or candidate version under validation |
| `graph` | JSON | Nodes, transitions, start event; carries the expression sites |
| `variable_schema` | JSON | Declared process variables with names and types; the root of the typed environment |
| `service_catalog_refs` | string[] | Service catalog entries whose declared result types enter the environment |
| `form_schemas` | JSON[] | Human-task forms whose field types enter the environment for that task's scope |
| `module_refs` | string[] | Stage 15 sub-process modules whose declared output types enter the environment |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Tenant Admin / Authoring Agent | `PUT /api/v1/definitions/{id}` (save draft) or `POST /api/v1/definitions/{id}/validate` | Caller holds `definition.write` for this tenant? | -> 403 Forbidden if not | VLD-04 |
| 2 | Platform | Run the PD-02 graph structure check and the PD-06 CEL syntax check | Structure or syntax invalid? | -> 422 with the existing PD-02 / PD-06 diagnostics; semantic validation does not run | VLD-02 |
| 3 | Platform | Build the root typed environment from `variable_schema`: `string`/`text`/`enum` -> string, `integer`/`decimal`/`money` -> number, `boolean` -> bool, `date`/`datetime` -> timestamp, `list<T>` -> list of the mapped element type, `object` -> map | A declared variable has an unmapped type name? | -> 422 `UnknownVariableType` naming the variable and the type | VLD-01 |
| 4 | Platform | Extend the environment with node output types: service-task results from the referenced service catalog entry's declared result schema, sub-process outputs from the `module_ref` declared output schema | A referenced catalog entry or module has no declared result schema? | -> 422 `UndeclaredResultSchema` naming the node and the reference | VLD-01 |
| 5 | Platform | Extend the environment per human-task scope with that task's form field types | Two form fields in one scope declare the same name with different types? | -> 422 `ConflictingFieldType` naming both declarations | VLD-01 |
| 6 | Platform | Enumerate every expression site: transition guards, human-task assignment expressions, timer delay expressions, service-task input mappings, form `visible_when`, form `computed_from` | Site list is empty? | Validation passes with an empty diagnostic list | VLD-02 |
| 7 | Platform | Compile each expression against the environment visible at that site | Expression references a name absent from the environment? | Record `UnknownVariable` with the name and the closest declared name | VLD-02, VLD-03 |
| 8 | Platform | Check the compiled result type against the site's required type: guards require bool, timer delays require duration or timestamp, `computed_from` requires the declared field type | Result type does not match? | Record `TypeMismatch` with expected and actual type | VLD-02, VLD-03 |
| 9 | Platform | Check operand types inside each expression | Operator applied to incompatible operands, for example string added to number? | Record `OperandTypeError` with the operator and both operand types | VLD-02, VLD-03 |
| 10 | Platform | Continue to the next site after each finding; do not stop at the first error | -- | The report lists every failing site in one response | VLD-03 |
| 11 | Platform | Assemble the diagnostic report: one entry per finding with `node_id`, `expression_path`, `source`, `error_kind`, `message` | Any finding present? | -> 422 with the full report; the draft is not persisted as valid | VLD-03 |
| 12 | Platform | Record the validation verdict on the definition version | No findings? | Version marked `semantically_valid`; the verdict is stored with the compiler version used | VLD-04 |
| 13 | Promotion Pipeline | Re-run steps 3 to 11 against the promotion candidate at submit time (PW-01 step 2) | Any finding, or the stored verdict was produced by an older compiler version? | -> 422; no promotion plan is computed and no review row is created | VLD-04 |
| 14 | Authoring UI | Render each finding against its node in the canvas and against its field in the form editor | -- | The author sees the failing expression source inline, with the error kind | VLD-03 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Syntax before semantics | The PD-06 syntax check runs first. Semantic compilation runs only on a syntactically valid expression set |
| Environment is definition-local | The typed environment is built from this definition's own variable schema, catalog refs, module refs and form schemas. Runtime instance data never contributes types |
| Scoped visibility | A form field type is visible only to expressions inside that human task's scope. A node output type is visible only to nodes reachable after that node |
| No implicit coercion | String to number, number to bool and timestamp to string conversions are type errors. Conversion must be explicit in the expression |
| Guard result type | A transition guard that does not compile to bool is a `TypeMismatch`, including a guard that compiles to a truthy non-bool |
| Full aggregation | Validation reports every finding in one pass. Returning only the first failure is a defect |
| Both gates are hard | Authoring save and promotion submit each reject on any finding. There is no override parameter |
| Verdict is compiler-bound | The stored `semantically_valid` verdict names the compiler version. A verdict from an older version is re-verified rather than trusted |
| Unknown variable naming | An `UnknownVariable` finding names the referenced identifier and the nearest declared identifier by edit distance |
| Empty expression | An expression site holding an empty or whitespace-only string is an `EmptyExpression` finding, not a passing site |

---

## Outputs

| Output | Description |
|--------|-------------|
| `validation_report` | JSON array of findings, each with `node_id`, `expression_path`, `source`, `error_kind`, `message` |
| `error_kind` values | `UnknownVariable`, `TypeMismatch`, `OperandTypeError`, `UnknownVariableType`, `UndeclaredResultSchema`, `ConflictingFieldType`, `EmptyExpression` |
| Verdict | `semantically_valid` recorded on the definition version with the compiler version |
| Event log entry | `DEFINITION_VALIDATED` on a clean pass, `DEFINITION_VALIDATION_FAILED` with the finding count otherwise |
| Promotion gate signal | PW-01 receives pass or fail before it computes the promotion plan |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| No operational SLA | Validation is author-driven and synchronous; no timers are involved |
| Compilation budget | 5 s per definition across all expression sites; on expiry the call returns 422 `ValidationTimeout` with the sites compiled so far |
| API response | Platform NFR: <= 500 ms write. A definition of 200 expression sites stays inside that budget |
| Compiler version change | A platform release that changes the CEL compiler version invalidates stored verdicts; the next promotion submit re-validates |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 403 Forbidden | Caller lacks `definition.write` on this tenant | Authenticate with a tenant-admin or authoring-agent principal |
| 422 `UnknownVariable` | Expression references an identifier absent from the typed environment | Declare the variable in `variable_schema` or correct the reference |
| 422 `TypeMismatch` | Compiled result type does not match the site's required type | Change the expression so it yields the required type |
| 422 `OperandTypeError` | Operator applied to incompatible operand types | Add an explicit conversion or correct the operand |
| 422 `UnknownVariableType` | `variable_schema` declares a type name the environment builder does not map | Use a supported type name |
| 422 `UndeclaredResultSchema` | A service catalog entry or module reference carries no declared result schema | Declare the result schema on the catalog entry or module before referencing it |
| 422 `ConflictingFieldType` | Two form fields in one scope share a name with different types | Rename one field or align the types |
| 422 `EmptyExpression` | An expression site holds an empty string | Supply an expression or remove the site |
| 422 `ValidationTimeout` | Compilation exceeded the 5 s budget | Split the definition into sub-process modules and revalidate |
| 422 at promotion submit | The candidate fails validation during PW-01 step 2 | Fix the definition in the test tenant; no review row was created, so no approval is invalidated |
