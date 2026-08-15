# Test Spec: SPC-01 — Declared input/output contract for SUB_PROCESS nodes

**Requirement:** SPC-01 — verbatim requirement text (docs/requirements.yaml):
> A SUB_PROCESS node MAY declare an `interface` object with `inputs` (array of `{name, json_schema, required}`) and `outputs` (array of `{name, json_schema, required}`). When declared, only the input variables named in `inputs` are copied into the child instance's initial variable map (instead of the full parent map), each validated against its `json_schema` before the child is created. On child completion, only the variables named in `outputs` are merged into the parent's variable map per EE-09; any other variable the child produced is discarded. If `interface` is omitted, EXT-05 behaviour applies unchanged.

**Priority:** SHOULD
**Test layer:** unit, integration
**Scored test-tier (test_developer_guide.md §2.1):** cross-module (1, `src/engine/instance.zig` calls into `src/definition/sub_process_interface.zig`) + transactional boundary (1, ERROR transition + event append are one transaction; child creation is excluded) = 2 points → unit + integration.

---

## Requirement Traceability

| Acceptance criterion / edge case | Test case IDs | Layer | Runnable file mapping |
|---|---|---|---|
| AC1: only named inputs copied to child initial map; other parent vars not visible | TC-SPC-01-UT-02, TC-SPC-01-INT-01 | unit, integration | src/definition/sub_process_interface.zig, tests/integration/spc01_sub_process_interface_test.zig |
| AC2: required input absent → parent ERROR (EE-10), no child created | TC-SPC-01-UT-03, TC-SPC-01-INT-02 | unit, integration | src/definition/sub_process_interface.zig, tests/integration/spc01_sub_process_interface_test.zig |
| AC3: input present but failing json_schema → parent ERROR before child (no orphan) | TC-SPC-01-UT-05, TC-SPC-01-INT-03 | unit, integration | src/definition/sub_process_interface.zig, tests/integration/spc01_sub_process_interface_test.zig |
| AC4: only named outputs merged back; unlisted child vars discarded | TC-SPC-01-UT-08, TC-SPC-01-INT-04 | unit, integration | src/definition/sub_process_interface.zig, tests/integration/spc01_sub_process_interface_test.zig |
| AC5: required output absent → parent ERROR (EE-10), merge not applied | TC-SPC-01-UT-09, TC-SPC-01-INT-05 | unit, integration | src/definition/sub_process_interface.zig, tests/integration/spc01_sub_process_interface_test.zig |
| AC6: no interface → EXT-05 unchanged (full copy / full merge) | TC-SPC-01-INT-07 | integration | tests/integration/spc01_sub_process_interface_test.zig |
| Edge: `interface.inputs == []` → child starts with empty map | TC-SPC-01-UT-06, TC-SPC-01-INT-06 | unit, integration | src/definition/sub_process_interface.zig, tests/integration/spc01_sub_process_interface_test.zig |
| Edge: present output failing json_schema → parent ERROR, no partial merge | TC-SPC-01-UT-10, TC-SPC-01-INT-08 | unit, integration | src/definition/sub_process_interface.zig, tests/integration/spc01_sub_process_interface_test.zig |

---

## Unit Test Cases

Unit coverage verifies the pure runtime helpers (`buildChildInitialMap`, `selectAndValidateOutputs`, `validateInputValue`, `validateOutputValue`) in `src/definition/sub_process_interface.zig` with `std.testing.allocator` — deterministic, no I/O, no DB.

### TC-SPC-01-UT-01: buildChildInitialMap copies ONLY named+present+valid inputs (AC1)
**Given:** a parent variable map with `customer_id`, `amount`, and `secret`; an interface declaring `customer_id` (required) and `amount` (optional)
**When:** `buildChildInitialMap` runs
**Then:** the child map contains only `customer_id` and `amount`; `secret` is absent; no violation is recorded
**Layer:** unit
**Acceptance criterion mapped:** AC1

### TC-SPC-01-UT-02: missing required input → `SubProcessMissingRequiredInput`
**Given:** a parent map without the required key
**When:** `buildChildInitialMap` runs
**Then:** `error.SubProcessMissingRequiredInput` is returned and the violation records `SUB_PROCESS_MISSING_REQUIRED_INPUT` with the key
**Layer:** unit
**Acceptance criterion mapped:** AC2

### TC-SPC-01-UT-03: absent optional input is skipped
**Given:** a parent map without an optional declared input
**When:** `buildChildInitialMap` runs
**Then:** the key is skipped; the child map is empty; no violation
**Layer:** unit
**Acceptance criterion mapped:** AC1 (optional input handling)

### TC-SPC-01-UT-04: input schema violation → `SubProcessInputSchemaViolation` (required AND optional alike)
**Given:** a present input whose value fails its declared `json_schema`
**When:** `buildChildInitialMap` runs
**Then:** `error.SubProcessInputSchemaViolation` is returned; the violation carries `SUB_PROCESS_INPUT_SCHEMA_VIOLATION`, the key, and the failing constraint; the child map is not produced
**Layer:** unit
**Acceptance criterion mapped:** AC3

### TC-SPC-01-UT-05: empty inputs list yields an empty child map (edge case)
**Given:** `interface.inputs == []` and a non-empty parent map
**When:** `buildChildInitialMap` runs
**Then:** the child map is empty regardless of parent state
**Layer:** unit
**Acceptance criterion mapped:** Edge — empty inputs

### TC-SPC-01-UT-06: selectAndValidateOutputs merges ONLY named+present+valid outputs (AC4)
**Given:** a child final map with `order_id` and `internal`; an interface declaring only `order_id`
**When:** `selectAndValidateOutputs` runs
**Then:** the output map contains only `order_id`; `internal` is discarded
**Layer:** unit
**Acceptance criterion mapped:** AC4

### TC-SPC-01-UT-07: missing required output → `SubProcessMissingRequiredOutput`, no merge
**Given:** a child final map without the required output key
**When:** `selectAndValidateOutputs` runs
**Then:** `error.SubProcessMissingRequiredOutput` is returned; the violation records `SUB_PROCESS_MISSING_REQUIRED_OUTPUT`
**Layer:** unit
**Acceptance criterion mapped:** AC5

### TC-SPC-01-UT-08: output schema violation → `SubProcessOutputSchemaViolation`, no partial merge
**Given:** a present output whose value fails its declared `json_schema`
**When:** `selectAndValidateOutputs` runs
**Then:** `error.SubProcessOutputSchemaViolation` is returned with the key and constraint; no partial output map is produced
**Layer:** unit
**Acceptance criterion mapped:** Edge — present-but-invalid output (design OQ-4 decision)

### TC-SPC-01-UT-09: absent optional output is skipped; empty outputs list is a no-op
**Given:** a child final map missing an optional output; and separately `interface.outputs == []`
**When:** `selectAndValidateOutputs` runs
**Then:** the output map is empty; the parent still advances (no-op merge)
**Layer:** unit
**Acceptance criterion mapped:** AC4 / Edge

### TC-SPC-01-UT-10: validateInputValue / validateOutputValue enforce the declared schema
**Given:** a `{type: "number"}` schema and values of each JSON kind
**When:** `validateInputValue` / `validateOutputValue` run
**Then:** conforming values pass; non-conforming values return the corresponding schema-violation error
**Layer:** unit
**Acceptance criterion mapped:** AC3 / Edge (runtime schema enforcement)

---

## Integration Test Cases

Integration coverage runs against real PostgreSQL (DIRECTIVE T-1) and validates the parent-child runtime contract end-to-end through the engine (`InstanceStore.completeTask` → SUB_PROCESS activation/completion gates). Every test creates its own parent/child definitions and instances with per-test UUID-derived names and cleans up unconditionally (`defer`), satisfying INV-TI-2.

### TC-SPC-01-INT-01: declared inputs are filtered into the child initial map (AC1)
**Given:** a SUB_PROCESS node declaring `inputs = [{customer_id, required}, {amount, optional}]`; parent starts with `{customer_id, amount, secret}`
**When:** the parent task is completed so the SUB_PROCESS activates
**Then:** a child instance is created whose initial variable map contains `customer_id` and `amount` but NOT `secret`
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_declared_inputs_are_filtered_test`
**Acceptance criterion mapped:** AC1

### TC-SPC-01-INT-02: missing required input → parent ERROR, no child created (AC2)
**Given:** a SUB_PROCESS node declaring a required input `customer_id`; parent starts without it
**When:** the parent task is completed
**Then:** `completeTask` returns `InstanceInError`, the parent instance status is ERROR, no `subprocess_links` row exists for the parent, and the `EXECUTION_ERROR` event reason names `SUB_PROCESS_MISSING_REQUIRED_INPUT`
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_missing_required_input_errors_parent_no_child_test`
**Acceptance criterion mapped:** AC2

### TC-SPC-01-INT-03: input schema violation → parent ERROR, no orphaned child (AC3)
**Given:** a SUB_PROCESS node declaring input `amount` with `{type: "number"}`; parent has `amount = "not-a-number"`
**When:** the parent task is completed
**Then:** `completeTask` returns `InstanceInError`, the parent instance status is ERROR, no child is created, and the `EXECUTION_ERROR` event reason names `SUB_PROCESS_INPUT_SCHEMA_VIOLATION`
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_input_schema_violation_no_orphan_child_test`
**Acceptance criterion mapped:** AC3

### TC-SPC-01-INT-04: only declared outputs merged back; unlisted child vars discarded (AC4)
**Given:** a SUB_PROCESS node declaring `outputs = [{order_id, required}]`; parent starts with `{x: 1}`
**When:** the parent task is completed (child starts) and the child task completes with `{order_id, internal}`
**Then:** the parent completes and its variables contain `order_id` but NOT `internal`; `x` is unchanged
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_declared_outputs_filter_merge_test`
**Acceptance criterion mapped:** AC4

### TC-SPC-01-INT-05: missing required output → parent ERROR, merge not applied (AC5)
**Given:** a SUB_PROCESS node declaring a required output `order_id`; parent starts with `{x: 1}`
**When:** the parent task completes (child starts) and the child task completes without `order_id`
**Then:** the parent instance status is ERROR, the merge is NOT applied (parent variables do not gain `something_else`), and the `EXECUTION_ERROR` event reason names `SUB_PROCESS_MISSING_REQUIRED_OUTPUT`
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_missing_required_output_errors_parent_test`
**Acceptance criterion mapped:** AC5

### TC-SPC-01-INT-06: empty inputs → child starts with empty map (edge)
**Given:** a SUB_PROCESS node declaring `inputs = []`; parent starts with `{a: 1, b: 2}`
**When:** the parent task is completed
**Then:** a child instance is created whose initial variable map is empty
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_empty_inputs_yields_empty_child_map_test`
**Acceptance criterion mapped:** Edge — empty inputs

### TC-SPC-01-INT-07: no interface → EXT-05 unchanged, full copy and full merge (AC6)
**Given:** a SUB_PROCESS node with no `interface` attribute; parent starts with `{x: 1, parent_only: true}`
**When:** the parent task completes (child starts) and the child task completes with `{x: 2, child_only: true}`
**Then:** the child initial map is the FULL parent map (`x` and `parent_only` visible), the parent completes, and the parent's merged variables include `x: 2` and `child_only` (full merge, EXT-05 behaviour)
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_no_interface_ext05_unchanged_test`
**Acceptance criterion mapped:** AC6

### TC-SPC-01-INT-08: output schema violation → parent ERROR, no partial merge (edge)
**Given:** a SUB_PROCESS node declaring output `order_id` with `{type: "string"}`; parent starts with `{x: 1}`
**When:** the child task completes with `order_id = 12345` (fails the string schema)
**Then:** the parent instance status is ERROR, `order_id` is NOT merged into the parent (no partial merge), and the `EXECUTION_ERROR` event reason names `SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION`
**Layer:** integration
**Runnable file mapping:** tests/integration/spc01_sub_process_interface_test.zig — `sub_process_output_schema_violation_no_partial_merge_test`
**Acceptance criterion mapped:** Edge — present-but-invalid output (design OQ-4 decision)

---

## Coverage Notes

- **Fail-first:** every integration case asserts a state change that is impossible under the pre-change code — the filtered child initial map (TC-SPC-01-INT-01/06/07), the parent ERROR + missing child (TC-SPC-01-INT-02/03), and the filtered merge + discarded unlisted vars (TC-SPC-01-INT-04/05/08). Under the pre-change EXT-05 path, the child would receive the full parent map and the parent would merge all child variables.
- **Isolation:** per-test UUID-derived definition names; each test cleans up definitions and instances via `defer cleanupByName` / `defer cleanupInstance`; no shared fixture state across test blocks (INV-TI-2).
- **No skip on MUST/SHOULD:** every case is a runnable, non-skipped test against real PostgreSQL via `BPM_TEST_DB_URL`.
- The EXT-05 regression path (AC6) is additionally covered by the pre-existing `tests/integration/ext05_sub_process_support_test.zig` suite, which must continue to pass untouched (SPC-01 must not alter the no-interface path).
