# Test Spec: EXT-04 — Variable transformer

**Requirement:** EXT-04 — Process definitions SHALL support declaration of CEL variable transformation expressions on edges, allowing field mapping or computation between task output and next task input without a gateway node.
**Priority:** SHOULD
**Test layer:** unit, integration

---

## Requirement Traceability

| Acceptance criterion / edge case | Test case IDs | Layer | Module touchpoints |
|---|---|---|---|
| Edge transform executes on traversed edge and object result merges via EE-09 semantics | EXT-04-UT-03 | unit | src/engine/transition.zig, src/engine/instance.zig |
| Transform returning non-object is rejected and mapped to EE-10 | EXT-04-UT-05 | unit | src/engine/transition.zig, src/engine/instance.zig |
| Transform syntax validation enforced on activation-time revalidation path | EXT-04-UT-02, TC-EXT-04-INT-01 | unit, integration | src/definition/graph.zig, src/definition/store.zig |
| Ordering is after task output merge (EE-09) and before next-node activation | EXT-04-UT-03 | unit | src/engine/instance.zig, src/engine/transition.zig |
| Runtime CEL evaluation failure maps to EE-10 terminal error path | EXT-04-UT-04 | unit | src/engine/transition.zig, src/engine/instance.zig |
| Missing variable referenced in transform follows CEL runtime error path | EXT-04-UT-04 | unit | src/engine/transition.zig, src/engine/instance.zig |
| Empty/whitespace transform treated as no-op and edge still traverses | EXT-04-UT-01, EXT-04-UT-06 | unit | src/definition/graph.zig, src/engine/transition.zig |

---

## Unit Test Cases

Unit coverage is implemented in tests/unit/graph_edge_conditions_test.zig and tests/unit/test_engine_ee05.zig.

### EXT-04-UT-01: null and whitespace transform expressions validate as no-op
**Given:** Edges with transform values null or whitespace-only
**When:** validateEdgeTransforms is executed
**Then:** Validation succeeds with zero violations
**Layer:** unit
**Acceptance criterion mapped:** Empty transform no-op contract

### EXT-04-UT-02: malformed transform expression is rejected
**Given:** Edge transform with malformed CEL syntax
**When:** validateEdgeTransforms is executed
**Then:** EDGE_INVALID_TRANSFORM_CEL violation is returned
**Layer:** unit
**Acceptance criterion mapped:** Syntax validation contract

### EXT-04-UT-03: transform result object merges into variables
**Given:** Task-completion output containing an object referenced by the transform expression
**When:** transition processes task_completed on an edge with transform
**Then:** Transform object fields are merged and token advances to target node
**Layer:** unit
**Acceptance criterion mapped:** Transform execution and EE-09 merge ordering

### EXT-04-UT-04: missing transform variable returns runtime CEL evaluation error
**Given:** Transform references a variable key that does not exist
**When:** transition evaluates the transform
**Then:** TransitionError.CelEvaluationError is returned
**Layer:** unit
**Acceptance criterion mapped:** Missing-variable runtime error behavior

### EXT-04-UT-05: non-object transform result is rejected
**Given:** Transform expression resolves to a scalar value
**When:** transition evaluates transform output
**Then:** TransitionError.TransformResultNonObject is returned
**Layer:** unit
**Acceptance criterion mapped:** Object-only transform output contract

### EXT-04-UT-06: whitespace-only transform is runtime no-op
**Given:** Edge transform is whitespace-only and task output contains valid variables
**When:** transition processes task completion
**Then:** Token advances and only task output merge is applied
**Layer:** unit
**Acceptance criterion mapped:** Empty-transform no-op behavior

---

## Integration Test Cases

Integration coverage is implemented in tests/integration/ext04_variable_transformer_test.zig and runs against real PostgreSQL (DIRECTIVE T-1).

### TC-EXT-04-INT-01: activation revalidation rejects invalid transform syntax
**Given:** A draft definition row whose graph is mutated to contain malformed edge transform CEL
**When:** activate() is called
**Then:** activate() fails with GraphValidationFailed and violations include EDGE_INVALID_TRANSFORM_CEL
**Layer:** integration
**Acceptance criterion mapped:** Activation-time syntax validation

---

## Coverage Notes

- EXT-04 acceptance criteria and declared edge cases are explicitly mapped to executable test IDs.
- Runtime ordering, object-only output, missing-variable handling, and transform no-op behavior are covered in deterministic unit tests.
- Activation-time validation against malformed transform syntax is covered in real-DB integration on the definition activation path.