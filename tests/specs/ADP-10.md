# Test Spec: ADP-10 -- Agent I/O capture in audit

**Requirement:** ADP-10 -- The audit table gains nullable `payload_full JSONB`; agent invocations store full input/output/tool-call payload (and raw messages where policy permits), while non-agent actions keep `payload_full = NULL`.
**Priority:** MUST
**Test layer:** integration

## Acceptance Criteria Coverage

- Additive schema support exists: nullable `payload_full` plus payload index and object-shape guard.
- Agent actions persist non-null `payload_full` envelope with required ADP-10 keys.
- Non-agent actions preserve OBS-03 behavior and keep `payload_full = NULL`.
- ADP-10 rows remain compatible with ADP-09 deterministic chain semantics.

## Test Cases

### TC-ADP-10-01: migration adds nullable payload_full column and payload index
**Given:** A migrated test database.
**When:** Audit table column/index metadata is queried.
**Then:** `payload_full` exists as nullable JSONB and the partial GIN index for non-null payload rows exists.
**Layer:** integration
**Acceptance criterion mapped:** ADP-10 additive schema readiness.
**Implemented by:** `tests/integration/adp10_agent_io_capture_audit_test.zig` test `TC-ADP-10-01: migration adds nullable payload_full column and payload index`.

### TC-ADP-10-02: agent rows persist payload_full while non-agent rows stay NULL
**Given:** One agent-authored audit write and one non-agent audit write.
**When:** Both rows are read from `audit_entries`.
**Then:** Agent row contains non-null `payload_full` with `schema_version`, `capture_mode`, and `tool_calls`; non-agent row has `payload_full IS NULL`.
**Layer:** integration
**Acceptance criterion mapped:** Agent/non-agent capture semantics.
**Implemented by:** `tests/integration/adp10_agent_io_capture_audit_test.zig` test `TC-ADP-10-02: agent rows persist payload_full while non-agent rows stay NULL`.

### TC-ADP-10-03: ADP-10 payload capture is chain-compatible and OBS-03-compatible
**Given:** The same paired agent/non-agent rows.
**When:** Chain hash recomputation and core OBS-03 fields (`action`, `resource_type`, `before_state`, `after_state`) are validated.
**Then:** Recomputed chain hash matches stored `chain_hash` for both rows, and core OBS-03 fields remain unchanged for both payload states.
**Layer:** integration
**Acceptance criterion mapped:** Compatibility with ADP-09 chain semantics and existing OBS-03 behavior.
**Implemented by:** `tests/integration/adp10_agent_io_capture_audit_test.zig` test `TC-ADP-10-02: agent rows persist payload_full while non-agent rows stay NULL`.

## Traceability Matrix

| ADP-10 acceptance area | Deterministic evidence |
|---|---|
| Additive schema readiness | `TC-ADP-10-01` |
| Agent payload capture (`payload_full` populated) | `TC-ADP-10-02` |
| Non-agent null payload behavior | `TC-ADP-10-02` |
| ADP-09 chain compatibility + OBS-03 contract compatibility | `TC-ADP-10-03` |

## Execution Notes For TEST-RUNNER

- Primary target: `zig build test-integration` (with `BPM_TEST_DB_URL` set).
- Focus file: `tests/integration/adp10_agent_io_capture_audit_test.zig`.
- Focus filters: `TC-ADP-10-*`.
