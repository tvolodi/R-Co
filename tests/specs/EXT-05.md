# Test Spec: EXT-05 — Sub-process support

**Requirement:** EXT-05 — The platform SHALL support a SUB_PROCESS node type that starts a child process instance from a referenced definition. The parent waits for child completion, merges child output on success (per EE-09), propagates child ERROR/CANCELLED to parent ERROR with required IDs, and parent cancellation must not cascade to the child.
**Priority:** SHOULD
**Test layer:** unit, integration

---

## Requirement Traceability

| Acceptance criterion / edge case | Test case IDs | Layer | Runnable file mapping |
|---|---|---|---|
| AC1: SUB_PROCESS activation starts child and parks parent token in waiting state | TC-EXT-05-INT-01 | integration | tests/integration/ext05_sub_process_support_test.zig |
| AC2: child gets copy-on-start variables; child mutation does not change parent before child completion | TC-EXT-05-INT-02 | integration | tests/integration/ext05_sub_process_support_test.zig |
| AC3: child completion advances parent and merges child output via EE-09 semantics | TC-EXT-05-INT-03 | integration | tests/integration/ext05_sub_process_support_test.zig |
| AC4: child ERROR propagates parent ERROR and appends CHILD_PROCESS_ERROR payload containing parent/child instance IDs | TC-EXT-05-INT-04 | integration | tests/integration/ext05_sub_process_support_test.zig |
| AC5: external child cancellation propagates parent ERROR and appends CHILD_PROCESS_CANCELLED payload containing parent/child instance IDs | TC-EXT-05-INT-05 | integration | tests/integration/ext05_sub_process_support_test.zig |
| AC6: parent cancellation does not cascade to child | TC-EXT-05-INT-06 | integration | tests/integration/ext05_sub_process_support_test.zig |
| Edge: SUB_PROCESS node requires child_definition_id attribute | TC-EXT-05-UT-01 | unit | tests/unit/graph_node_attributes_test.zig |

---

## Unit Test Cases

Unit coverage currently verifies SUB_PROCESS node attribute contract and prevents malformed process definitions from entering runtime flow.

### TC-EXT-05-UT-01: SUB_PROCESS child_definition_id attribute validation
**Given:** SUB_PROCESS node definitions with and without child_definition_id
**When:** graph node-attribute validation runs
**Then:** valid attributes pass and missing child_definition_id fails with SUB_PROCESS_MISSING_CHILD_DEFINITION_ID
**Layer:** unit
**Runnable file mapping:** tests/unit/graph_node_attributes_test.zig
**Acceptance criterion mapped:** EXT-05 structural precondition for child start

---

## Integration Test Cases

Integration coverage runs against real PostgreSQL (DIRECTIVE T-1) and validates parent-child runtime behavior end-to-end.

### TC-EXT-05-INT-01: SUB_PROCESS activation starts child and parent enters waiting
**Given:** parent definition with HUMAN_TASK -> SUB_PROCESS -> END and child definition with a pending human task
**When:** parent task is completed so execution reaches SUB_PROCESS
**Then:** child instance is created and parent current_nodes encodes waiting_child_instance_id linkage
**Layer:** integration
**Runnable file mapping:** tests/integration/ext05_sub_process_support_test.zig
**Acceptance criterion mapped:** AC1

### TC-EXT-05-INT-02: copy-on-start isolates parent variables until child completes
**Given:** parent starts with variables and child is started from SUB_PROCESS
**When:** child mutates variables but has not completed
**Then:** parent variables remain unchanged until completion path runs
**Layer:** integration
**Runnable file mapping:** tests/integration/ext05_sub_process_support_test.zig
**Acceptance criterion mapped:** AC2

### TC-EXT-05-INT-03: child completion merges output to parent and completes parent
**Given:** parent is waiting on a child instance
**When:** child task completes with output variables
**Then:** parent completes and merged parent variables include child output and overwrite semantics per EE-09
**Layer:** integration
**Runnable file mapping:** tests/integration/ext05_sub_process_support_test.zig
**Acceptance criterion mapped:** AC3

### TC-EXT-05-INT-04: child ERROR propagates to parent ERROR with required IDs
**Given:** parent waiting on child instance
**When:** child transitions to ERROR via setInstanceError
**Then:** parent status becomes ERROR and latest CHILD_PROCESS_ERROR event payload includes parent_instance_id and child_instance_id
**Layer:** integration
**Runnable file mapping:** tests/integration/ext05_sub_process_support_test.zig
**Acceptance criterion mapped:** AC4

### TC-EXT-05-INT-05: external child cancellation propagates to parent ERROR with required IDs
**Given:** parent waiting on child instance
**When:** child is cancelled externally
**Then:** parent status becomes ERROR and latest CHILD_PROCESS_CANCELLED event payload includes parent_instance_id and child_instance_id
**Layer:** integration
**Runnable file mapping:** tests/integration/ext05_sub_process_support_test.zig
**Acceptance criterion mapped:** AC5

### TC-EXT-05-INT-06: cancelling parent does not cancel child
**Given:** parent waiting on child instance
**When:** parent is cancelled
**Then:** child remains ACTIVE and continues independently
**Layer:** integration
**Runnable file mapping:** tests/integration/ext05_sub_process_support_test.zig
**Acceptance criterion mapped:** AC6

---

## Coverage Notes

- Mapping is explicit for both unit and integration suites and points to runnable files already in the workspace.
- EXT-05 edge-case handling around parent-child runtime propagation is validated in integration where parent/child linkage, event payload fields, and status transitions are persisted and queryable.