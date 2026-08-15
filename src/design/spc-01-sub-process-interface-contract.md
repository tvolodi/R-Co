# Module: spc-01-sub-process-interface-contract

**Requirement IDs:** SPC-01, SPC-02
**Run ID:** WF02-plc-batch-b-20260815 (Stage 15)
**Type:** Type E — novel cross-cutting design (runtime contract + definition-time validation)
**Covers:** SPC-01, SPC-02, EXT-05, EE-09, EE-10, PD-02, PD-05, PLC-01

---

## Module purpose

Defines the declared input/output contract (`interface`) for `SUB_PROCESS` nodes. When a
`SUB_PROCESS` node declares an `interface`, activation copies a **filtered** subset of the
parent's variable map into the child instance (validated against per-entry JSON Schemas), and
child completion merges a **filtered** subset of the child's final variable state back into
the parent per EE-09. Missing required inputs, input schema violations, missing required
outputs, and output schema violations transition the parent to ERROR per EE-10 with a
structured reason. A node that omits `interface` behaves exactly as EXT-05 (full map copy
out / full map merge back), so the contract is fully backward compatible. SPC-02 guarantees
at definition-creation/update time that every `json_schema` under `inputs`/`outputs` is a
well-formed JSON Schema, rejecting the definition with HTTP 422 otherwise — the interface is
then persisted as part of the node's attributes. This module provides the contract layer that
PLC-01's `interface_schema` catalog column consumes.

---

## Scope and relationship to prior releases

- **EXT-05** (RELEASED) established the unfiltered SUB_PROCESS variable handoff. SPC-01
  narrows that handoff when an `interface` is declared; SPC-01/02 must not alter the
  no-interface path.
- **PLC-01..04** (RELEASED, Batch A) added the process module catalog. The catalog's
  `interface_schema` column stores the same structure as a SUB_PROCESS node `interface`.
  SPC-02 is the validation that makes PLC-01/PLC-02's "declared interface" meaningful at the
  definition layer; PLC-01's `registerModule` copies the already-validated entry-point node
  interface into `interface_schema`.
- **This module introduces no schema migration.** The `interface` object is a node attribute
  inside the definition graph JSONB (`definitions.graph`), exactly like the existing
  `child_definition_id` attribute. Runtime reads it from the parent definition snapshot
  (EE-01 snapshot rule).

---

## The `interface` object (data model)

A `SUB_PROCESS` node MAY carry an optional `interface` attribute. Shape:

```json
{
  "interface": {
    "inputs": [
      { "name": "customer_id", "json_schema": { "type": "string" }, "required": true },
      { "name": "amount",     "json_schema": { "type": "number" }, "required": false }
    ],
    "outputs": [
      { "name": "order_id", "json_schema": { "type": "string" }, "required": true }
    ]
  }
}
```

Field semantics:

| Field | Type | Semantics |
|---|---|---|
| `name` | non-empty string | Variable key. MUST be unique within `inputs` and within `outputs`. |
| `json_schema` | JSON object | Well-formed JSON Schema (SPC-02). Constraints applied at runtime (SPC-01). |
| `required` | boolean, default `false` | Absent `required` is treated as `false` (matches PLC-03 OQ-3). |

Directional rules:

- `inputs` — the subset of parent variables copied into the child's **initial** variable map.
- `outputs` — the subset of child final variables merged into the parent on child COMPLETED.

**Effective interface source:**

1. A node using tenant-local `child_definition_id` — the node's own `interface` attribute is
   the effective interface.
2. A node using `module_ref` (PLC-01) — the effective interface is the resolved catalog
   entry's `interface_schema` (the module's published contract). The referencing node does not
   need to redeclare it; if it does declare one, the declared interface is used as the
   effective interface for the parent-side contract (the child resolves via PLC-01). Any
   conflict between the two is an authoring-time concern, not a runtime one (see Open
   questions OQ-3).
3. No `interface` and no catalog contract — EXT-05 legacy semantics.

---

## Public interface

### Zig types (`src/definition/sub_process_interface.zig`)

```zig
pub const InterfaceEntry = struct {
    name: []const u8,
    json_schema: std.json.Value,   // well-formed JSON Schema object (SPC-02)
    required: bool,                // defaults to false when absent
};

pub const SubProcessInterface = struct {
    inputs: []InterfaceEntry,
    outputs: []InterfaceEntry,
};
```

### Zig functions

```zig
// SPC-02 — definition-time structural validation (invoked from graph.zig checkSubProcess).
pub fn parseInterface(allocator, raw: std.json.Value) SubProcessInterfaceError!SubProcessInterface;
// SPC-02 — schema-of-schemas well-formedness check (homes in src/tools/json_schema.zig).
pub fn validateSchemaShape(allocator, schema: std.json.Value, depth: usize) SubProcessInterfaceError!void;

// SPC-01 — runtime helpers (invoked from the engine SUB_PROCESS activation/completion path).
pub fn buildChildInitialMap(allocator, parent_vars: std.json.ObjectMap, iface: SubProcessInterface) SubProcessInterfaceError!std.json.ObjectMap;
pub fn validateInputValue(allocator, value: std.json.Value, schema: std.json.Value) SubProcessInterfaceError!void;
pub fn selectAndValidateOutputs(allocator, child_vars: std.json.ObjectMap, iface: SubProcessInterface) SubProcessInterfaceError!std.json.ObjectMap;
pub fn validateOutputValue(allocator, value: std.json.Value, schema: std.json.Value) SubProcessInterfaceError!void;
```

`validateInputValue` / `validateOutputValue` reuse the collecting validator
(`src/tools/json_schema.zig validateCollect`) so the structured reason can name the failing
constraint and JSON pointer.

### TypeScript types (`web/src/types/api.ts`)

```ts
export interface SubProcessInterfaceEntry {
  name: string
  json_schema: Record<string, unknown>
  required?: boolean           // default false
}
export interface SubProcessInterface {
  inputs: SubProcessInterfaceEntry[]
  outputs: SubProcessInterfaceEntry[]
}
```

---

## Data flow diagram (ASCII)

```
Parent token at SUB_PROCESS node
   ▼
Resolve child (child_definition_id | PLC-01 module_ref → interface_schema)
   ▼
effective interface? ── No ──▶ EXT-05 legacy: full parent var map → child
   │ Yes
   ▼
[ACTIVATION GATE — buildChildInitialMap]
  each input:
    in parent vars? ─ No ─ required? ─ Yes ─▶ EE-10 parent ERROR (no child)
    │ Yes                └ No ─▶ skip
    value ok? ─ No ─▶ EE-10 parent ERROR (no orphan child)
    ▼ ok
  filtered map = named+present+valid inputs (empty list → empty map)
   ▼
Start child (EE-01) with filtered map; token → WAITING
   ▼ ... child executes ...
Child terminal ─ ERROR/CANCELLED ─▶ parent ERROR (EXT-05)
   ▼
Child COMPLETED → child final variable map
   ▼
effective interface? ── No ──▶ EXT-05 legacy: full child map via EE-09
   │ Yes
   ▼
[COMPLETION GATE — selectAndValidateOutputs]
  each output:
    in child vars? ─ No ─ required? ─ Yes ─▶ EE-10 parent ERROR (no merge)
    │ Yes                └ No ─▶ discard
    value ok? ─ No ─▶ EE-10 parent ERROR (no partial merge)
    ▼ ok
  merge named outputs via EE-09; unlisted child vars discarded
   ▼
Unpark token; advance past SUB_PROCESS
```

---

## Runtime semantics — SPC-01

### Activation: filtered copy-in (SPC-01 AC1..AC3)

Normative order when the effective interface is declared:

1. Resolve the child definition (tenant-local `child_definition_id`, or PLC-01
   `resolveModuleRef` for `module_ref`). The child must be ACTIVE at activation (EE-01 rule).
2. Build the child initial variable map from `interface.inputs`:
   - For each input key **present** in the parent variable map: validate the value against its
     `json_schema`. If it fails, the parent transitions to ERROR (EE-10,
     `SUB_PROCESS_INPUT_SCHEMA_VIOLATION`) **before any child instance is created** — no
     orphaned child. This applies to required AND optional inputs alike (an optional input the
     caller supplied must still honour its declared schema).
   - For each input key **absent** from the parent variable map:
     - `required == true` → parent transitions to ERROR (EE-10,
       `SUB_PROCESS_MISSING_REQUIRED_INPUT`) identifying the missing input; no child created.
     - `required == false` → the key is skipped; it is not passed to the child.
   - `interface.inputs == []` → the child starts with an **empty** initial variable map,
     regardless of parent state (SPC-01 edge case).
3. Start the child instance via the EE-01 path with the filtered initial map. Parent variables
   NOT named in `inputs` are **not visible to the child** (SPC-01 AC1).
4. Persist the parent-child linkage and park the parent token in WAITING on the child instance
   (existing EXT-05 mechanics; unchanged).

### Completion: filtered merge-back (SPC-01 AC4..AC5)

Normative order when the effective interface is declared:

1. On child COMPLETED, load the child's **final variable map** (the child's full variable state
   at COMPLETED — resolves EXT-05 design Open Question 1: the source of child "output
   variables" is the full final map, filtered here by the interface).
2. For each declared output key **present** in the child final map: validate the value against
   its `json_schema` **before** merging. If it fails, the parent transitions to ERROR (EE-10,
   `SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION`); the merge is NOT applied (no partial merge).
3. For each declared output key **absent** from the child final map:
   - `required == true` → parent transitions to ERROR (EE-10,
     `SUB_PROCESS_MISSING_REQUIRED_OUTPUT`) identifying the missing output; the merge is NOT
     applied.
   - `required == false` → skipped.
4. Merge the present-and-valid named outputs into the parent per EE-09 (existing collision
   policy: overwrite + `VARIABLE_OVERWRITTEN` event; the definition-registered variable schema
   check from EE-09 is applied during the merge after the interface schema check).
5. Any child variable NOT named in `outputs` is discarded — never merged (SPC-01 AC4).
6. `interface.outputs == []` → no-op merge; the parent still advances (consistent with EXT-05's
   "empty child output object is a no-op merge and parent still advances").
7. Unpark the parent token and advance past the SUB_PROCESS node.

### EE-10 error transitions

All four new trigger conditions produce the existing EE-10 behaviour on the **parent**
instance: `status = ERROR`, an `EXECUTION_ERROR` event appended with a structured reason,
and halt until operator retry/discard via OBS-05. The structured reason MUST carry:

- error type code (one of the four `SUB_PROCESS_*` runtime codes),
- the SUB_PROCESS `node_id`,
- the offending variable key (`input`/`output` name),
- the failing JSON Schema constraint + JSON pointer (schema-violation cases),
- a human-readable reason, and the parent variable state at the time of error (EE-10 AC1/AC5).

Atomicity (EE-10 AC4): the ERROR transition + `EXECUTION_ERROR` append are one transaction.
On the activation side, "no child instance is created" means the child creation is not part of
that transaction at all — the error fires before child instantiation. On the completion side,
the ERROR transition is atomic and no partial merge is committed.

### Ordering note (EE-09 interplay)

When a parent output key also has a registered variable schema on the parent definition
(EE-09), the interface output schema check runs first; the EE-09 registered-schema check runs
during the merge. Either failure → EE-10. The interface check is SPC-01's responsibility; the
registered-schema check is pre-existing EE-09 behaviour.

---

## Definition-time validation — SPC-02

### Hook point

SPC-02 validation runs inside `src/definition/graph.zig` `checkSubProcess`, which executes as
part of the PD-05 node-type attribute validation, itself invoked after the PD-02
graph-structure validation. Every create/update of a definition therefore applies SPC-02
without a separate pipeline stage. `checkSubProcess` gains an `interface` branch: parse the
`interface` attribute with `parseInterface`, which calls `validateSchemaShape` on every entry's
`json_schema`. The interface is persisted unchanged as part of the node's attributes once
validation passes (SPC-02 AC2).

### JSON Schema well-formedness rule

A `json_schema` is **well-formed** (SPC-02) iff it is a JSON object whose recognized keywords
carry the correct value type, per the platform's supported keyword set (aligned with
`src/tools/json_schema.zig`):

| Keyword | Valid value type |
|---|---|
| `type` | string in `string,number,integer,boolean,object,array,null`, or non-empty array of such strings |
| `minimum` / `maximum` | JSON number |
| `minLength` / `maxLength` | non-negative JSON integer |
| `enum` | JSON array |
| `required` | array of non-empty strings |
| `properties` | object whose values are themselves well-formed schemas (recursive) |
| `items` | well-formed schema (object) |
| `additionalProperties` | JSON boolean (only `false` is enforced at runtime) |

Additional rules:

- An **empty object** `{}` is a well-formed (fully permissive) schema.
- **Unknown keywords** — including `$ref`, `allOf`/`anyOf`/`oneOf`/`not`, `patternProperties`,
  `pattern`, `format`, `dependencies`, `title`, `description` — are **permitted and inert**.
  This matches the runtime validator's documented behaviour (unknown keywords are silently
  ignored), so SPC-02 never rejects a schema the runtime could not fully honour. Only the
  supported keyword set is enforced at runtime; unsupported keywords are carried but inactive.
- **Recursion guard:** nesting depth of `properties`/`items` is capped at 32; deeper nesting is
  rejected as malformed (prevents stack exhaustion on adversarial input).
- A value that is **not** a JSON object (e.g. a bare `true`/`false` or a string) is malformed —
  the platform contract requires an object schema (matches PLC-02's "a valid JSON Schema
  object" wording).

### HTTP 422 response

Any violation rejects the definition create/update with HTTP 422 (RFC 9457 Problem Details),
listing **all** offending entries and identifying the offending schema and its node. Error
codes (definition-time):

| Code | When |
|---|---|
| `SUB_PROCESS_INTERFACE_NOT_OBJECT` | `interface` present but not a JSON object |
| `SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY` | `interface.inputs` present but not an array |
| `SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY` | `interface.outputs` present but not an array |
| `SUB_PROCESS_INTERFACE_ENTRY_INVALID` | an entry is not an object, or `name` is empty/missing, or `required` is not a boolean, or `json_schema` is missing |
| `SUB_PROCESS_INTERFACE_SCHEMA_INVALID` | `json_schema` is not well-formed (SPC-02) |
| `SUB_PROCESS_INTERFACE_DUPLICATE_NAME` | duplicate `name` within `inputs` or within `outputs` |

Each violation detail carries `node_id`, direction (`inputs`/`outputs`), entry `name`, and a
JSON pointer to the offending field, so an operator can locate the defect without parsing the
whole definition.

### Client-side mirror

The process designer canvas runs client-side validation mirroring PD-02/PD-05 rules
(`web/src/pages/definitions/DefinitionEditorPage.tsx`). A SUB_PROCESS branch is added that
calls a `validateSubProcessInterface` util (same structural rules as above) so malformed
interfaces surface inline on the node (`validationError`) and in the validation summary bar
before save is allowed (PD-UI-13 / PD-UI-14).

---

## Frontend surface (SPC-01/02)

- **Property editor:** `web/src/components/canvas/PropertyPanel.tsx` currently returns no
  type-specific fields for `SUB_PROCESS`. A new "Interface" section is added for the
  SUB_PROCESS case: a JSON editor (textarea-based, since no reusable JSON editor component
  exists in `web/src/components/ui/`) bound to `data.attributes.interface`, with a
  well-formed/parse indicator. Edits are stored into the node attributes exactly like other
  attributes and round-trip through the existing `graphToFlow`/persistence path unchanged.
- **Validation util:** new `web/src/utils/canvas/interfaceValidation.ts` exporting
  `validateSubProcessInterface(value: unknown): InterfaceValidationIssue[]`, mirroring the
  SPC-02 structural rules (shape, entry shape, schema well-formedness, duplicate names).
- **Editor page wiring:** the validation effect in `DefinitionEditorPage.tsx` gains a
  SUB_PROCESS branch that surfaces issues on the node and blocks save until clean.
- The interface is optional; nodes without one render and save exactly as today (no regression
  to the EXT-05 authoring flow).

---

## Relationship to PLC-01 `interface_schema`

- PLC-01's `process_module_catalog.interface_schema` stores **the same structure** as a
  SUB_PROCESS node `interface`. SPC-02 is the definition-time guarantee that any interface
  reaching the catalog is already well-formed.
- PLC-01 `registerModule` copies the module entry-point node's interface into
  `interface_schema`; PLC-02's publication gate treats an empty `{}` as "no declared
  interface". Both rely on SPC-02 having validated the interface at the definition layer.
- PLC-03's cross-version compatibility analysis operates on the same `inputs`/`outputs`
  arrays (`name`, `json_schema`, `required`) that SPC-01/02 define, so the `required`
  default (`false`) is shared across both (PLC-03 OQ-3).
- Runtime: a `module_ref` SUB_PROCESS activation uses the resolved entry's `interface_schema`
  as the effective interface for the SPC-01 copy/merge gates.

---

## Error taxonomy

### Definition-time (SPC-02) → HTTP 422 on create/update

| Error | HTTP | When |
|---|---|---|
| `SUB_PROCESS_INTERFACE_NOT_OBJECT` | 422 | `interface` is not a JSON object |
| `SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY` | 422 | `inputs` not an array |
| `SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY` | 422 | `outputs` not an array |
| `SUB_PROCESS_INTERFACE_ENTRY_INVALID` | 422 | entry shape/type violation |
| `SUB_PROCESS_INTERFACE_SCHEMA_INVALID` | 422 | `json_schema` not well-formed |
| `SUB_PROCESS_INTERFACE_DUPLICATE_NAME` | 422 | duplicate key within `inputs` or `outputs` |

### Runtime (SPC-01) → parent instance ERROR (EE-10)

| Error | Trigger | Required behaviour |
|---|---|---|
| `SUB_PROCESS_MISSING_REQUIRED_INPUT` | required input absent from parent map at activation | Parent ERROR; no child created |
| `SUB_PROCESS_INPUT_SCHEMA_VIOLATION` | input present but fails its `json_schema` at activation | Parent ERROR; no child created (no orphan) |
| `SUB_PROCESS_MISSING_REQUIRED_OUTPUT` | required output absent from child final map at completion | Parent ERROR; merge not applied |
| `SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION` | output present but fails its `json_schema` at completion | Parent ERROR; no partial merge |

No new variants are added to the EXT-05 child-failure path (`CHILD_PROCESS_ERROR`,
`CHILD_PROCESS_CANCELLED`) — those remain unchanged; the four new codes are
`EXECUTION_ERROR` reason types on the same EE-10 mechanism.

---

## State transitions

No new instance states are introduced. SPC-01 adds four **trigger conditions** on the existing
EE-10 ERROR transition:

```
ParentActive ── SUB_PROCESS activation contract failure ──▶ ParentError   (no child created)
ParentWaitingOnChild ── child COMPLETED contract failure ──▶ ParentError  (no merge)
ParentWaitingOnChild ── child COMPLETED + merge OK ─────────▶ ParentActive (advance past node)
ParentWaitingOnChild ── child ERROR / CANCELLED ─────────────▶ ParentError (EXT-05, unchanged)
```

---

## Dependencies and module boundaries

### Depends on

1. `src/definition/graph.zig` — SPC-02 hook inside `checkSubProcess` (PD-05 attribute
   validation, after PD-02 structure validation).
2. `src/engine/instance.zig` / `src/engine/transition.zig` — SUB_PROCESS activation,
   WAITING linkage, and child-completion propagation; SPC-01 gates slot into the existing
   EXT-05 ordering.
3. `src/tools/json_schema.zig` — value validation (`validate`/`validateCollect`) at runtime;
   hosts the new `validateSchemaShape` (SPC-02).
4. `src/definition/sub_process_interface.zig` (new) — `parseInterface`,
   `buildChildInitialMap`, `selectAndValidateOutputs`; orchestration of SPC-01/02.
5. PLC-01 `resolveModuleRef` — effective-interface source for `module_ref` nodes.
6. EE-09 merge (collision policy + registered-schema check) and EE-10 (ERROR + event).

### Must not depend on

1. Any child-definition knowledge at the parent authoring/runtime layer — parent and child are
   authored and versioned independently (SPC-02 statement; PLC-03 owns cross-definition
   compatibility).
2. Runtime mutation of the child definition snapshot after child start (EE-01 rule).
3. Any change to the EXT-05 no-interface path (must remain byte-for-byte legacy behaviour).
4. A schema migration — the interface lives in the existing definition graph JSONB.

---

## Requirement traceability matrix

| Requirement / AC | Design section | Module touchpoints | Required tests |
|---|---|---|---|
| SPC-01 AC1: only named inputs copied to child | Runtime semantics — activation | `sub_process_interface.zig`, engine activation | Unit: `child_initial_map_contains_only_declared_inputs_test`; Integration: `sub_process_declared_inputs_are_filtered_test` |
| SPC-01 AC2: required input absent → parent ERROR, no child | Runtime semantics — activation, EE-10 | engine activation | Unit: `missing_required_input_maps_to_ee10_test`; Integration: `sub_process_missing_required_input_errors_parent_no_child_test` |
| SPC-01 AC3: input present but schema fail → parent ERROR before child | Runtime semantics — activation, EE-10 | engine activation, `json_schema.zig` | Unit: `input_schema_violation_maps_to_ee10_test`; Integration: `sub_process_input_schema_violation_no_orphan_child_test` |
| SPC-01 AC4: only named outputs merged; others discarded | Runtime semantics — completion | engine completion, `sub_process_interface.zig` | Unit: `completion_merges_only_declared_outputs_test`; Integration: `sub_process_declared_outputs_filter_merge_test` |
| SPC-01 AC5: required output absent → parent ERROR | Runtime semantics — completion, EE-10 | engine completion | Unit: `missing_required_output_maps_to_ee10_test`; Integration: `sub_process_missing_required_output_errors_parent_test` |
| SPC-01 AC6: no interface → EXT-05 unchanged | Runtime semantics — fallback | engine (no change) | Regression: existing EXT-05 integration tests still pass untouched |
| SPC-01 edge: empty inputs → empty child map | Runtime semantics — activation | engine activation | Unit: `empty_inputs_list_yields_empty_child_map_test` |
| SPC-02 AC1: malformed json_schema → HTTP 422 identifying node+schema | Definition-time validation | `graph.zig checkSubProcess`, `sub_process_interface.zig` | Unit: `check_sub_process_rejects_malformed_schema_test`; Integration: `definition_create_with_bad_interface_returns_422_test` |
| SPC-02 AC2: well-formed interface passes PD-02/PD-05, persisted | Definition-time validation | `graph.zig` | Unit: `check_sub_process_accepts_wellformed_interface_test`; Integration: `definition_interface_persisted_in_node_attributes_test` |
| SPC-02 edge: unknown keywords permitted | Definition-time validation — well-formedness | `validateSchemaShape` | Unit: `unknown_schema_keywords_are_accepted_test` |
| SPC-02 edge: duplicate names rejected | Definition-time validation | `parseInterface` | Unit: `duplicate_interface_names_rejected_test` |

---

## Open questions

1. **Unsupported-keyword policy (SPC-02):** the design permits-and-ignores unsupported JSON
   Schema keywords (e.g. `$ref`, `pattern`, `format`) so SPC-02 never rejects a schema the
   runtime cannot honour. Confirm whether a later requirement should either (a) enforce the
   unsupported keywords at runtime, or (b) reject them at definition-time to avoid a silent
   contract gap. Flagged for REQ-ANALYST.
2. **Child output source (EXT-05 OQ-1, resolved here for SPC-01):** this design treats the
   child's full final variable map at COMPLETED as the output source, filtered by `outputs`.
   Confirm this resolves the open question consistently for the no-interface path as well.
3. **`module_ref` + node-level interface conflict:** when a SUB_PROCESS node declares both a
   `module_ref` (whose catalog entry carries `interface_schema`) and its own `interface`, the
   design uses the node-declared interface as the effective contract. Confirm the intended
   precedence (node-declared vs catalog contract) or whether this should be a definition-time
   rejection.
4. **Runtime enforcement of output `json_schema`:** the design validates present outputs
   against their declared schema before merge (consistent with EE-09's schema-violation error
   path). The SPC-01 AC text names only the missing-required-output case; confirm validating
   present output values is the intended reading of "contract".
