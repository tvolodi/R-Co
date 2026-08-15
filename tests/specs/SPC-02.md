# Test Spec: SPC-02 — Contract validated at definition-time

**Requirement:** SPC-02 — verbatim requirement text (docs/requirements.yaml):
> On creation or update of a definition containing a SUB_PROCESS node with a declared `interface`, the platform SHALL validate that every `json_schema` under `inputs`/`outputs` is itself a well-formed JSON Schema, rejecting the definition with HTTP 422 otherwise. The platform does not validate at this point that the referenced child definition actually produces the declared outputs — parent and child may be authored and versioned independently; that cross-definition check is addressed by PLC-03.

**Priority:** SHOULD
**Test layer:** unit, integration
**Scored test-tier (test_developer_guide.md §2.1):** cross-module (1, `src/definition/graph.zig` calls into `src/definition/sub_process_interface.zig` and `src/tools/json_schema.zig`) + transactional boundary (1, create/update validates before persisting) = 2 points → unit + integration.

---

## Requirement Traceability

| Acceptance criterion / edge case | Test case IDs | Layer | Runnable file mapping |
|---|---|---|---|
| AC1: malformed `json_schema` under inputs/outputs → rejected (HTTP 422 via `GraphValidationFailed` + violations), identifying schema + node | TC-SPC-02-UT-04, TC-SPC-02-UT-06, TC-SPC-02-UT-08, TC-SPC-02-INT-01 | unit, integration | src/definition/sub_process_interface.zig, src/tools/json_schema.zig, tests/unit/graph_node_attributes_test.zig, tests/integration/spc01_sub_process_interface_test.zig |
| AC2: well-formed interface → validation passes, interface persisted in node attributes | TC-SPC-02-UT-01, TC-SPC-02-UT-05, TC-SPC-02-INT-02 | unit, integration | src/definition/sub_process_interface.zig, tests/unit/graph_node_attributes_test.zig, tests/integration/spc01_sub_process_interface_test.zig |
| Edge: unknown JSON Schema keywords permitted and inert | TC-SPC-02-UT-07 | unit | src/tools/json_schema.zig |
| Edge: duplicate names within a direction rejected | TC-SPC-02-UT-05 | unit | src/definition/sub_process_interface.zig |
| Edge: `interface` not an object / `inputs`/`outputs` not arrays rejected | TC-SPC-02-UT-02, TC-SPC-02-UT-03 | unit | src/definition/sub_process_interface.zig |

---

## Unit Test Cases

Unit coverage verifies `parseInterface` / `collectInterfaceViolations` in `src/definition/sub_process_interface.zig`, `validateSchemaShape` in `src/tools/json_schema.zig`, and the PD-05 `checkSubProcess` SPC-02 hook in `tests/unit/graph_node_attributes_test.zig` — deterministic, no I/O, no DB.

### TC-SPC-02-UT-01: well-formed interface parses (AC2)
**Given:** `{"inputs":[{"name":"customer_id","json_schema":{"type":"string"},"required":true}],"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}`
**When:** `parseInterface` runs
**Then:** the interface parses with one input and one output carrying their names, schemas, and required flags
**Layer:** unit
**Acceptance criterion mapped:** AC2

### TC-SPC-02-UT-02: interface not an object → `SubProcessInterfaceNotObject`
**Given:** an `interface` attribute that is not a JSON object (e.g. a bare string)
**When:** `parseInterface` runs
**Then:** `error.SubProcessInterfaceNotObject` is returned (HTTP 422 `SUB_PROCESS_INTERFACE_NOT_OBJECT`)
**Layer:** unit
**Acceptance criterion mapped:** Edge — shape

### TC-SPC-02-UT-03: inputs/outputs not arrays → NOT_ARRAY codes
**Given:** `interface.inputs` present but not an array, and `interface.outputs` present but not an array
**When:** `parseInterface` runs
**Then:** `error.SubProcessInterfaceInputsNotArray` / `error.SubProcessInterfaceOutputsNotArray` is returned (HTTP 422 codes)
**Layer:** unit
**Acceptance criterion mapped:** Edge — shape

### TC-SPC-02-UT-04: entry shape violations → `SubProcessInterfaceEntryInvalid`
**Given:** an entry that is not an object, an empty/missing `name`, a non-boolean `required`, or a missing `json_schema`
**When:** `parseInterface` runs
**Then:** `error.SubProcessInterfaceEntryInvalid` is returned (HTTP 422 code)
**Layer:** unit
**Acceptance criterion mapped:** AC1 (shape precondition)

### TC-SPC-02-UT-05: duplicate names within a direction → `SubProcessInterfaceDuplicateName`
**Given:** two entries with the same `name` in `inputs`
**When:** `parseInterface` runs
**Then:** `error.SubProcessInterfaceDuplicateName` is returned (HTTP 422 code)
**Layer:** unit
**Acceptance criterion mapped:** Edge — duplicate names

### TC-SPC-02-UT-06: malformed json_schema → `SubProcessInterfaceSchemaInvalid`
**Given:** an entry whose `json_schema` carries a recognised keyword with the wrong value type (e.g. `{"type": 42}`)
**When:** `parseInterface` runs
**Then:** `error.SubProcessInterfaceSchemaInvalid` is returned (HTTP 422 code)
**Layer:** unit
**Acceptance criterion mapped:** AC1

### TC-SPC-02-UT-07: unknown JSON Schema keywords are accepted (permitted and inert)
**Given:** a `json_schema` containing `$ref`, `pattern`, `format` (unsupported keywords)
**When:** `parseInterface` runs
**Then:** the interface parses successfully — unsupported keywords are carried but not rejected
**Layer:** unit
**Acceptance criterion mapped:** Edge — well-formedness rule

### TC-SPC-02-UT-08: collectInterfaceViolations lists EVERY offending entry
**Given:** an interface with a schema violation, a duplicate name, and a non-array `outputs`
**When:** `collectInterfaceViolations` runs
**Then:** all three violations are reported in order (`SUB_PROCESS_INTERFACE_SCHEMA_INVALID`, `SUB_PROCESS_INTERFACE_DUPLICATE_NAME`, `SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY`)
**Layer:** unit
**Acceptance criterion mapped:** AC1 (HTTP 422 lists all offending entries)

### TC-SPC-02-UT-09: validateSchemaShape keyword well-formedness (via src/tools/json_schema.zig)
**Given:** schemas covering the supported keyword set, wrong-value-type keywords, non-object schemas, unknown keywords, recursion, and the 32-level depth cap
**When:** `validateSchemaShape` runs
**Then:** well-formed schemas pass; malformed schemas and >32-deep nesting are rejected
**Layer:** unit
**Acceptance criterion mapped:** AC1 / well-formedness rule

### TC-SPC-02-UT-10: checkSubProcess validates the interface on SUB_PROCESS nodes (PD-05)
**Given:** SUB_PROCESS nodes with a well-formed interface, a malformed schema, a non-object interface, duplicate names, and `interface: null`
**When:** `validateNodeAttributes` runs
**Then:** well-formed and `null` interfaces pass; malformed interfaces produce the SPC-02 violation codes naming the offending node
**Layer:** unit
**Runnable file mapping:** tests/unit/graph_node_attributes_test.zig (TC-PD-05-22..TC-PD-05-27)
**Acceptance criterion mapped:** AC1, AC2

---

## Integration Test Cases

Integration coverage runs against real PostgreSQL (DIRECTIVE T-1) through `DefinitionStore.create()` — the exact store path the API handlers delegate to (the HTTP layer maps `GraphValidationFailed` to HTTP 422 with a serialized violations body; see `src/api/routes/definitions.zig` `handleCreate`/`handlePut`).

### TC-SPC-02-INT-01: definition create with malformed json_schema → rejected with SPC-02 violation naming node (AC1)
**Given:** a definition graph whose SUB_PROCESS node declares an interface with a malformed `json_schema` (e.g. `{"type": 42}`) under `inputs`
**When:** `DefinitionStore.create` runs
**Then:** create returns `GraphValidationFailed` (the API's HTTP 422 precondition), `lastViolations()` contains `SUB_PROCESS_INTERFACE_SCHEMA_INVALID`, and the violation message names the SUB_PROCESS node id
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `definition_create_with_bad_interface_returns_422_test`
**Acceptance criterion mapped:** AC1

### TC-SPC-02-INT-02: definition create with well-formed interface succeeds and interface persisted (AC2)
**Given:** a definition graph whose SUB_PROCESS node declares a well-formed interface under `inputs` and `outputs`
**When:** `DefinitionStore.create` runs, then the definition is re-fetched via `getById`
**Then:** create succeeds under the existing PD-02/PD-05 validation, and the persisted node attributes contain the `interface` object with its declared `inputs`/`outputs`
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `definition_interface_persisted_in_node_attributes_test`
**Acceptance criterion mapped:** AC2

---

## Coverage Notes

- **Fail-first:** TC-SPC-02-INT-01 asserts a rejection that is impossible before the SPC-02 branch existed in `checkSubProcess` (the malformed interface would previously be silently accepted). TC-SPC-02-INT-02 asserts the interface is persisted — under pre-change code the attribute would not be structurally validated or guaranteed persisted.
- **HTTP 422 mapping:** the integration tests assert the store-level `GraphValidationFailed` + violation codes because that is the delegated path the API handlers use to produce HTTP 422 (verified in `src/api/routes/definitions.zig` — `GraphStructureInvalid`/`GraphValidationFailed` → `serializeViolations(..., 422)`).
- **Isolation:** per-test UUID-derived definition names; each test cleans up definitions via `defer cleanupByName`; no shared fixture state (INV-TI-2).
- **No skip on MUST/SHOULD:** every case is a runnable, non-skipped test against real PostgreSQL via `BPM_TEST_DB_URL`.
