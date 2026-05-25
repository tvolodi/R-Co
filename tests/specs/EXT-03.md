# Test Spec: EXT-03 — Plugin interface

**Requirement:** EXT-03 — The platform SHALL define a stable internal interface for registering custom node type handlers. A handler receives the current instance context and returns an outcome. Handlers are registered at startup.
**Priority:** SHOULD
**Test layer:** unit, integration

---

## Requirement Traceability

| Acceptance criterion / edge case | Test case IDs | Layer | Module touchpoints |
|---|---|---|---|
| Startup-registered plugin handler receives current instance context and is invoked for matching node type | TC-EXT-03-U01, TC-EXT-03-U02, TC-EXT-03-INT-01 | unit, integration | src/engine/plugin_interface.zig, src/engine/plugin_registry.zig, src/engine/instance.zig |
| Handler outcome contract is restricted to COMPLETE (optional output variables) and ERROR (reason string) | TC-EXT-03-U03, TC-EXT-03-U04, TC-EXT-03-U05, TC-EXT-03-INT-02 | unit, integration | src/engine/plugin_interface.zig, src/engine/instance.zig |
| Plugin panic is mapped to deterministic ERROR path and EE-10 handling | TC-EXT-03-U06, TC-EXT-03-INT-03 | unit, integration | src/engine/plugin_interface.zig, src/engine/instance.zig |
| Plugins are startup-only (registry frozen after bootstrap) and runtime registration is rejected | TC-EXT-03-U07, TC-EXT-03-U08, TC-EXT-03-INT-04 | unit, integration | src/engine/plugin_registry.zig, src/main.zig |
| Stable Zig API compatibility boundaries are enforced at registration | TC-EXT-03-U09, TC-EXT-03-U10, TC-EXT-03-INT-05 | unit, integration | src/engine/plugin_registry.zig |
| Edge case: plugin shadows built-in handler for same node type | TC-EXT-03-U11, TC-EXT-03-INT-06 | unit, integration | src/engine/plugin_registry.zig, src/engine/instance.zig |
| COMPLETE output variables follow EE-09 merge behavior (success and invalid output error path) | TC-EXT-03-U12, TC-EXT-03-INT-07, TC-EXT-03-INT-08 | unit, integration | src/engine/plugin_interface.zig, src/engine/instance.zig |
| ERROR outcome follows EE-10 and blocks further progression | TC-EXT-03-U13, TC-EXT-03-INT-09 | unit, integration | src/engine/instance.zig |
| Edge case: no plugin and no built-in handler resolves to missing handler error path | TC-EXT-03-U14, TC-EXT-03-INT-10 | unit, integration | src/engine/plugin_registry.zig, src/engine/instance.zig |

---

## Unit Test Cases

Unit coverage is implemented in tests/unit/ext03_plugin_test.zig and focuses on deterministic plugin registry/interface behavior.

### TC-EXT-03-U01: Safe invocation forwards COMPLETE outcome
**Given:** A registered plugin handler that returns COMPLETE with optional output variables
**When:** invokePluginHandlerSafely is called with deterministic context
**Then:** COMPLETE is returned and output payload contract is preserved
**Layer:** unit
**Acceptance criterion mapped:** Handler outcome contract and invocation behavior

### TC-EXT-03-U02: Safe invocation forwards ERROR outcome
**Given:** A registered plugin handler that returns ERROR with reason
**When:** invokePluginHandlerSafely is called
**Then:** ERROR is returned with the original reason
**Layer:** unit
**Acceptance criterion mapped:** Handler outcome contract and invocation behavior

### TC-EXT-03-U03: COMPLETE outcome with output payload validates
**Given:** A COMPLETE outcome with output_variables_json set to a JSON object string
**When:** validateOutcome is executed
**Then:** Validation succeeds
**Layer:** unit
**Acceptance criterion mapped:** COMPLETE outcome with optional output variables

### TC-EXT-03-U04: ERROR outcome with non-empty reason validates
**Given:** An ERROR outcome with non-empty reason
**When:** validateOutcome is executed
**Then:** Validation succeeds
**Layer:** unit
**Acceptance criterion mapped:** ERROR outcome with reason contract

### TC-EXT-03-U05: ERROR outcome with empty reason is rejected
**Given:** An ERROR outcome with empty reason
**When:** validateOutcome is executed
**Then:** InvalidErrorReason is returned
**Layer:** unit
**Acceptance criterion mapped:** ERROR outcome reason must be non-empty

### TC-EXT-03-U06: Invocation error maps panic to deterministic reason code
**Given:** Invocation error PanicCaught
**When:** invocationErrorReason is called
**Then:** PLUGIN_PANIC_CAUGHT reason code is produced
**Layer:** unit
**Acceptance criterion mapped:** Panic-to-error deterministic mapping

### TC-EXT-03-U07: Registration lifecycle enforces startup freeze
**Given:** Plugin registry after at least one successful registration
**When:** freezePluginRegistry is called and another registration is attempted
**Then:** RegistryLocked is returned
**Layer:** unit
**Acceptance criterion mapped:** Startup-only registration

### TC-EXT-03-U08: Registration rejects invalid inputs
**Given:** Registration input with empty node_type or null handler
**When:** registerPluginHandler is called
**Then:** InvalidNodeType or InvalidHandler is returned
**Layer:** unit
**Acceptance criterion mapped:** Stable interface contract and startup validation

### TC-EXT-03-U09: Duplicate registration for same node type is rejected
**Given:** Existing registration for node type SERVICE_TASK
**When:** A second registration for SERVICE_TASK is attempted
**Then:** DuplicateNodeType is returned
**Layer:** unit
**Acceptance criterion mapped:** Registration contract uniqueness

### TC-EXT-03-U10: API compatibility enforces major version boundary
**Given:** Runtime API major version 1
**When:** Registration targets major version 2
**Then:** IncompatibleApiVersion is returned
**Layer:** unit
**Acceptance criterion mapped:** Breaking-change compatibility boundary

### TC-EXT-03-U11: Plugin precedence shadows built-in handler
**Given:** Plugin registered for node type that also has built-in handler
**When:** resolveNodeHandlerKind is called with has_builtin_handler=true
**Then:** plugin is selected
**Layer:** unit
**Acceptance criterion mapped:** Edge case plugin precedence

### TC-EXT-03-U12: Compatible API version registers and resolves
**Given:** Target API major matches runtime and minor is compatible
**When:** Registration succeeds and resolvePluginHandler is queried
**Then:** Plugin registration exists and is resolvable
**Layer:** unit
**Acceptance criterion mapped:** Stable API compatibility and startup registration success

### TC-EXT-03-U13: Built-in fallback is selected when plugin is absent
**Given:** No plugin registration for node type and built-in exists
**When:** resolveNodeHandlerKind is called with has_builtin_handler=true
**Then:** builtin is selected
**Layer:** unit
**Acceptance criterion mapped:** Runtime resolution behavior

### TC-EXT-03-U14: Missing plugin and missing built-in returns no handler
**Given:** No plugin registration and no built-in handler for node type
**When:** resolveNodeHandlerKind is called with has_builtin_handler=false
**Then:** null is returned
**Layer:** unit
**Acceptance criterion mapped:** Edge case no handler found

---

## Integration Test Cases

Integration coverage validates EXT-03 behavior through real runtime execution paths with PostgreSQL-backed instance state.

### TC-EXT-03-INT-01: Startup-registered plugin receives instance context at execution
**Given:** Startup bootstrapped plugin registration for a custom node type and an ACTIVE instance reaching that node
**When:** Node execution dispatch runs
**Then:** Plugin receives context fields for instance variables and node config and handler is invoked
**Layer:** integration
**Acceptance criterion mapped:** Startup invocation with current context

### TC-EXT-03-INT-02: COMPLETE outcome advances execution and keeps instance non-error
**Given:** Plugin returns COMPLETE with optional output variables
**When:** Node execution runs
**Then:** Engine continues normal progression and instance does not transition to ERROR
**Layer:** integration
**Acceptance criterion mapped:** COMPLETE outcome handling

### TC-EXT-03-INT-03: Panic-mapped plugin failure transitions instance via EE-10
**Given:** Plugin invocation fails with panic-mapped path
**When:** Node execution handles invocation failure
**Then:** EXECUTION_ERROR is appended and instance status becomes ERROR with deterministic reason code
**Layer:** integration
**Acceptance criterion mapped:** Panic mapped to EE-10

### TC-EXT-03-INT-04: Registration attempts after startup freeze are rejected
**Given:** Registry frozen after bootstrap
**When:** Runtime registration is attempted
**Then:** Registration fails with RegistryLocked and runtime registry remains unchanged
**Layer:** integration
**Acceptance criterion mapped:** Startup-only registration

### TC-EXT-03-INT-05: Incompatible API major version fails startup registration
**Given:** Plugin registration targeting incompatible API major
**When:** Startup registration list is processed
**Then:** Registration fails deterministically and plugin is not available for resolution
**Layer:** integration
**Acceptance criterion mapped:** API compatibility boundary

### TC-EXT-03-INT-06: Plugin shadows built-in service task handler at runtime
**Given:** Built-in SERVICE_TASK handler exists and plugin registered for SERVICE_TASK
**When:** Execution reaches SERVICE_TASK node
**Then:** Plugin handler path is executed instead of built-in path
**Layer:** integration
**Acceptance criterion mapped:** Edge case plugin precedence

### TC-EXT-03-INT-07: COMPLETE output variables merge through EE-09 success path
**Given:** Plugin returns COMPLETE with valid JSON object output variables
**When:** Instance execution applies plugin output
**Then:** Variables are merged using EE-09 semantics and execution continues
**Layer:** integration
**Acceptance criterion mapped:** EE-09 integration success path

### TC-EXT-03-INT-08: COMPLETE with invalid/non-object output transitions to EE-10
**Given:** Plugin returns COMPLETE with invalid or non-object output payload
**When:** Output validation/merge is attempted
**Then:** Merge is rejected, EXECUTION_ERROR is appended, and instance transitions to ERROR
**Layer:** integration
**Acceptance criterion mapped:** EE-09 validation failure routed to EE-10

### TC-EXT-03-INT-09: Explicit ERROR outcome transitions to EE-10 terminal state
**Given:** Plugin returns ERROR with reason
**When:** Node execution handles plugin result
**Then:** Instance transitions to ERROR, EXECUTION_ERROR records reason, and follow-up completion actions are rejected
**Layer:** integration
**Acceptance criterion mapped:** EE-10 integration behavior

### TC-EXT-03-INT-10: Missing plugin and built-in handler routes to execution error
**Given:** Plugin registry has no handler for a custom node type and built-in handler flag is false
**When:** Runtime handler resolution is evaluated via registry API
**Then:** Resolution returns null (no handler), which is the deterministic missing-handler signal used by runtime dispatch
**Layer:** integration
**Acceptance criterion mapped:** Missing-handler edge case

---

## Fixture Plan

| Fixture | Purpose | Used by |
|---|---|---|
| ext03_registry_open | Startup registration window before freeze | TC-EXT-03-INT-01, TC-EXT-03-INT-05 |
| ext03_registry_frozen | Runtime state after freeze | TC-EXT-03-INT-04 |
| ext03_plugin_complete | Deterministic plugin returning COMPLETE | TC-EXT-03-INT-02, TC-EXT-03-INT-07 |
| ext03_plugin_error | Deterministic plugin returning ERROR reason | TC-EXT-03-INT-09 |
| ext03_plugin_invalid_output | Plugin returning COMPLETE with invalid output payload | TC-EXT-03-INT-08 |
| ext03_plugin_shadow_service_task | Plugin registered for SERVICE_TASK to shadow built-in | TC-EXT-03-INT-06 |
| ext03_instance_seed | ACTIVE instance positioned at plugin-dispatched node | TC-EXT-03-INT-01, TC-EXT-03-INT-02, TC-EXT-03-INT-06, TC-EXT-03-INT-07, TC-EXT-03-INT-08, TC-EXT-03-INT-09, TC-EXT-03-INT-10 |
| ext03_error_event_probe | Query helper for EXECUTION_ERROR and terminal status assertions | TC-EXT-03-INT-03, TC-EXT-03-INT-08, TC-EXT-03-INT-09, TC-EXT-03-INT-10 |
| ext03_db_tx_rollback | Per-test DB transaction rollback wrapper | All integration cases |

---

## Coverage Notes

- Every EXT-03 acceptance criterion and edge case is mapped to explicit test IDs.
- Startup-only registration, plugin precedence shadowing, panic reason mapping, COMPLETE/ERROR contract handling, and EE-09/EE-10 integration behavior are all explicitly covered.
- Unit tests are deterministic and have no wall-clock or network dependence.
- Integration cases are executable in `tests/integration/ext03_plugin_integration_test.zig` and imported by the integration entrypoint.
- Coverage expectation handling: when `zig build test-coverage` is unavailable in `build.zig`, WF-02 verification for EXT-03 uses executable test-ID traceability (TC-EXT-03-INT-01..10 and TC-EXT-03-U01..14) plus `zig build test` and `zig build test-integration` command outcomes.
