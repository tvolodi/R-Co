# Test Spec: ADP-11 -- Replay-safe retention policy

**Requirement:** ADP-11 -- Event types in protected replay-critical families `{INSTANCE_*, TASK_*, GATEWAY_*, EXECUTION_*}` must not allow hard-delete retention; they must use retain-forever or archive-and-queryable retention. Non-protected families keep ES-07 configurability.
**Priority:** MUST
**Test layer:** integration

## Acceptance Criteria Coverage

- Protected-family hard-delete configuration is rejected at policy upsert time.
- Explicit `INSTANCE_STARTED` hard-delete rejection returns deterministic structured error semantics.
- Non-protected families preserve ES-07 hard-delete configurability and hard-delete behavior.
- Replay-safe archive/queryability invariant holds for protected families configured with archive retention (`keep_days`/`keep_count`).

## Test Cases

### TC-ADP-11-01: protected family rejects hard-delete policy deterministically
**Given:** A retention policy upsert for protected event type `INSTANCE_STARTED` using `hard_delete_days`.
**When:** The policy is validated and upsert attempted.
**Then:** The operation fails with `ProtectedFamilyHardDeleteForbidden`; deterministic violation payload fields are stable (`code`, `reason`, `event_family`, `requested_mode`, ordered `allowed_modes`), and error-code mapping resolves to `RETENTION_POLICY_PROTECTED_FAMILY_HARD_DELETE_FORBIDDEN`.
**Layer:** integration
**Acceptance criterion mapped:** Protected-family hard-delete rejection + structured error semantics.
**Implemented by:** `tests/integration/event_store_integration_test.zig` test `TC-ADP-11-01: protected family rejects hard-delete policy deterministically`.

### TC-ADP-11-02: non-protected families retain hard-delete configurability
**Given:** A non-protected event type (`ADP11_AUDIT_EVENT`) with an applied `hard_delete_days` policy.
**When:** Retention archival job runs with zero-day threshold.
**Then:** The event is hard-deleted from live storage and not copied to archive (`events=0`, `events_archive=0`).
**Layer:** integration
**Acceptance criterion mapped:** ES-07 compatibility for non-protected families.
**Implemented by:** `tests/integration/event_store_integration_test.zig` test `TC-ADP-11-02: non-protected families retain hard-delete configurability`.

### TC-ADP-11-03: protected keep_days policy archives and preserves queryability
**Given:** Protected event type `INSTANCE_STARTED` with `keep_days=0` archive policy.
**When:** Retention archival job runs.
**Then:** Event is removed from live table and preserved in `events_archive` (`events=0`, `events_archive=1`), proving replay-safe archive retention and queryability invariant.
**Layer:** integration
**Acceptance criterion mapped:** Replay-safe archive/queryability invariant for protected families.
**Implemented by:** `tests/integration/event_store_integration_test.zig` test `TC-ADP-11-03: protected keep_days policy archives and preserves queryability`.

## Traceability Matrix

| ADP-11 acceptance area | Deterministic evidence |
|---|---|
| Protected-family hard-delete rejected | `TC-ADP-11-01` |
| Explicit `INSTANCE_STARTED` hard-delete structured error | `TC-ADP-11-01` |
| Non-protected ES-07 hard-delete configurability preserved | `TC-ADP-11-02` |
| Protected archive/queryability replay-safety invariant | `TC-ADP-11-03` |

## Execution Notes For TEST-RUNNER

- Primary target: `zig build test-integration` (with `BPM_TEST_DB_URL` set).
- Focus file: `tests/integration/event_store_integration_test.zig`.
- Focus filters: `TC-ADP-11-*`.
