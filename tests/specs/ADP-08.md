# Test Spec: ADP-08 -- Service task catalog reference

**Requirement:** ADP-08 -- The SERVICE_TASK node configuration supports either `url` (legacy EXT-01 behavior) or `service_id` (catalog reference). When both are present, `service_id` takes precedence, `url` is ignored with a warning, and capability `service:call:<service_id>` is required for the `service_id` path.
**Priority:** MUST
**Test layer:** unit, integration

## Acceptance Criteria Coverage

- Legacy definitions using `url` execute unchanged.
- Definitions using `service_id` enforce capability and catalog lookup behavior.
- When both `service_id` and `url` are present, `service_id` wins and warning behavior is present.

## Test Cases

### TC-ADP-08-U01: service_id takes precedence over url with warning and catalog endpoint routing
**Given:** SERVICE_TASK attributes include both `service_id` and `url`, valid catalog entry, and required capability.
**When:** `parseConfigFromNodeAttributes` parses node attributes.
**Then:** Route is catalog-based, resolved endpoint equals catalog endpoint, and warning is present for ignored inline URL.
**Layer:** unit
**Acceptance criterion mapped:** Both-field precedence and warning behavior.
**Implemented by:** `tests/unit/service_task_test.zig` test `ADP-08: parse SERVICE_TASK config resolves service_id via catalog and enforces precedence`.

### TC-ADP-08-U02: service_id path rejects missing capability
**Given:** SERVICE_TASK attributes include `service_id` and catalog entry, but capability set does not include `service:call:<service_id>` or wildcard.
**When:** `parseConfigFromNodeAttributes` executes.
**Then:** Returns `error.MissingServiceCapability`.
**Layer:** unit
**Acceptance criterion mapped:** Capability enforcement for `service_id` route.
**Implemented by:** `tests/unit/service_task_test.zig` test `ADP-08: service_id path without required capability is rejected`.

### TC-ADP-08-U03: service_id path rejects missing catalog reference deterministically
**Given:** SERVICE_TASK attributes include `service_id`, but catalog object does not contain the referenced key.
**When:** `parseConfigFromNodeAttributes` executes.
**Then:** Returns `error.CatalogEntryNotFound`.
**Layer:** unit
**Acceptance criterion mapped:** Missing catalog behavior for `service_id` route.
**Implemented by:** `tests/unit/service_task_test.zig` test `ADP-08: service_id path with missing catalog entry is rejected deterministically`.

### TC-ADP-08-U04: service_id path accepts wildcard capability
**Given:** SERVICE_TASK attributes include `service_id`, valid catalog entry, and capability `service:call:*`.
**When:** `parseConfigFromNodeAttributes` executes.
**Then:** Configuration is accepted and catalog routing is selected.
**Layer:** unit
**Acceptance criterion mapped:** Capability model support for allowed wildcard grant.
**Implemented by:** `tests/unit/service_task_test.zig` test `ADP-08: service_id path accepts wildcard service capability` and `tests/unit/graph_node_attributes_test.zig` test `TC-ADP-08-01b: SERVICE_TASK with service_id and wildcard capability -> valid`.

### TC-ADP-08-U05: service_id path rejects inactive catalog entry
**Given:** SERVICE_TASK attributes include `service_id` and matching catalog entry with `is_active=false`.
**When:** `parseConfigFromNodeAttributes` executes.
**Then:** Returns `error.CatalogEntryInactive`.
**Layer:** unit
**Acceptance criterion mapped:** Invalid catalog reference behavior.
**Implemented by:** `tests/unit/service_task_test.zig` test `ADP-08: service_id path with inactive catalog entry is rejected`.

### TC-ADP-08-U06: service_id path rejects invalid catalog entry shape
**Given:** SERVICE_TASK attributes include `service_id`, but catalog entry has invalid `endpoint_url` type.
**When:** `parseConfigFromNodeAttributes` executes.
**Then:** Returns `error.InvalidConfig` from strict parser validation.
**Layer:** unit
**Acceptance criterion mapped:** Invalid catalog reference behavior.
**Implemented by:** `tests/unit/service_task_test.zig` test `ADP-08: service_id path with invalid catalog endpoint shape is rejected`.

### TC-ADP-08-I01: service_id route executes via catalog endpoint and ignores inline url
**Given:** Definition includes both `service_id` and `url`, valid catalog entry, and required capability.
**When:** Instance reaches SERVICE_TASK execution in integration flow.
**Then:** Instance completes and exactly one request is issued to catalog endpoint path (inline URL is not used).
**Layer:** integration
**Acceptance criterion mapped:** Dual-field precedence during real execution path.
**Implemented by:** `tests/integration/ext01_service_task_test.zig` test `TC-ADP-08-INT-01: service_id uses catalog endpoint and ignores inline url when both are present`.

### TC-ADP-08-I02: service_id without required capability is rejected at definition validation
**Given:** SERVICE_TASK uses `service_id` but capabilities omit required grant.
**When:** Definition creation runs graph validation.
**Then:** Definition creation fails with graph validation error.
**Layer:** integration
**Acceptance criterion mapped:** Capability enforcement.
**Implemented by:** `tests/integration/ext01_service_task_test.zig` test `TC-ADP-08-INT-02: service_id without service:call capability is rejected at definition validation`.

### TC-ADP-08-I03: missing catalog entry transitions instance to ERROR without outbound call
**Given:** SERVICE_TASK uses `service_id` not present in service catalog.
**When:** SERVICE_TASK executes after preceding human task completion.
**Then:** Instance transitions to `ERROR`; no HTTP request is emitted.
**Layer:** integration
**Acceptance criterion mapped:** Missing catalog behavior.
**Implemented by:** `tests/integration/ext01_service_task_test.zig` test `TC-ADP-08-INT-03: missing catalog entry transitions to ERROR before HTTP call`.

### TC-ADP-08-I04: inactive catalog entry transitions instance to ERROR without outbound call
**Given:** SERVICE_TASK uses `service_id` with catalog entry marked inactive.
**When:** SERVICE_TASK executes after preceding human task completion.
**Then:** Instance transitions to `ERROR`; no HTTP request is emitted.
**Layer:** integration
**Acceptance criterion mapped:** Invalid catalog reference behavior.
**Implemented by:** `tests/integration/ext01_service_task_test.zig` test `TC-ADP-08-INT-04: inactive catalog entry transitions to ERROR before HTTP call`.

### TC-ADP-08-C01: legacy url-only path remains compatible
**Given:** Definitions that provide only `url` for SERVICE_TASK.
**When:** Existing EXT-01 integration scenarios run.
**Then:** Legacy runtime semantics remain unchanged (success, retry, redirect, error/DLQ, and validation behavior).
**Layer:** integration
**Acceptance criterion mapped:** Legacy URL compatibility.
**Implemented by:** `tests/integration/ext01_service_task_test.zig` tests `TC-EXT-01-INT-01` through `TC-EXT-01-INT-07`.

## Traceability Matrix

| ADP-08 acceptance area | Deterministic evidence |
|---|---|
| Legacy `url` execution remains unchanged | `TC-ADP-08-C01` mapped to `TC-EXT-01-INT-01..07` |
| `service_id` uses catalog lookup and capability model | `TC-ADP-08-U02`, `TC-ADP-08-U03`, `TC-ADP-08-U04`, `TC-ADP-08-U05`, `TC-ADP-08-U06`, `TC-ADP-08-I02`, `TC-ADP-08-I03`, `TC-ADP-08-I04` |
| Dual-field precedence with warning and `service_id` winner | `TC-ADP-08-U01`, `TC-ADP-08-I01` |

## Required Additions For Release Confidence

- Added in this handoff and now covered by executable tests:
  - Wildcard capability acceptance (`service:call:*`) for `service_id` path.
  - Inactive catalog entry handling as deterministic failure before outbound call.
  - Invalid catalog endpoint shape handling (`InvalidConfig`).

## Execution Notes For TEST-RUNNER

- Unit target: `zig build test`.
- Integration target: `zig build test-integration` with `BPM_TEST_DB_URL` set.
- Primary executable files:
  - `tests/unit/service_task_test.zig`
  - `tests/unit/graph_node_attributes_test.zig`
  - `tests/integration/ext01_service_task_test.zig`
- Focus filters:
  - `TC-ADP-08-INT-*` for integration acceptance verification.
  - `ADP-08:` and `TC-ADP-08-*` tests for unit/validation coverage.
