# Test Spec: OBS-06 — Alerting hooks

**Requirement:** OBS-06 — The platform SHALL support configurable webhook calls on system events for ERROR-duration, DLQ threshold crossing, and scheduler lag threshold, with bounded retries and terminal failure logging.
**Priority:** SHOULD
**Test layer:** unit, integration

## Requirement Traceability

| Requirement clause / edge case | Test case IDs |
|---|---|
| ERROR-duration trigger: instance in ERROR for > N minutes emits webhook payload with instance, reason, duration | TC-OBS-06-INT-01 |
| Multiple instances simultaneously entering ERROR: one alert per instance | TC-OBS-06-INT-01 |
| ERROR-duration one-shot behavior while still above threshold | TC-OBS-06-INT-01 |
| Re-fire after recovery and re-cross (instance exits ERROR then enters ERROR again) | TC-OBS-06-INT-01 |
| DLQ threshold crossing one-shot while above threshold and re-arm after recovery | TC-OBS-06-INT-02 |
| Scheduler lag threshold crossing behavior and one-shot/re-arm semantics | TC-OBS-06-INT-02 |
| Deterministic payload envelope fields and correlation ID contract | TC-OBS-06-INT-01, TC-OBS-06-INT-04 |
| Delivery retry policy: max 3 attempts with bounded exponential semantics and terminal failure result | TC-OBS-06-INT-03 |
| Negative/regression: no duplicate firing while threshold remains above | TC-OBS-06-INT-01, TC-OBS-06-INT-02 |

## Test Cases

### TC-OBS-06-INT-01: ERROR-duration trigger emits per-instance alerts with one-shot and re-arm behavior
**Given:** an alerting state store, threshold `error_stuck_minutes = 10`, and two instances that have remained in `ERROR` for longer than the threshold
**When:** rules are evaluated repeatedly while instances remain in `ERROR`, then evaluated after recovery and a subsequent re-entry into `ERROR`
**Then:** one alert is emitted per qualifying instance; duplicate alerts are suppressed while still above threshold; after recovery and re-entry, alerting re-arms and emits again; payload includes deterministic required keys and correlation ID format
**Layer:** integration
**Acceptance criterion mapped:** ERROR-duration behavior, edge case for simultaneous instances, duplicate suppression, re-fire after recovery, deterministic payload/correlation fields

### TC-OBS-06-INT-02: DLQ and scheduler lag threshold triggers are crossing-based one-shot alerts with re-arm
**Given:** configured DLQ and scheduler lag thresholds with initial samples below threshold
**When:** values cross upward, remain above threshold, drop below threshold, and cross upward again
**Then:** each trigger emits exactly once per upward crossing; no re-fire while above threshold; after recovery below threshold, next upward crossing emits again
**Layer:** integration
**Acceptance criterion mapped:** DLQ crossing semantics and scheduler lag crossing semantics, including one-shot/re-arm behavior

### TC-OBS-06-INT-03: Dispatcher retries failed deliveries up to 3 attempts and returns terminal failure
**Given:** a hook with retry policy capped at 3 attempts and a delivery adapter that always returns non-2xx
**When:** alert dispatch executes
**Then:** delivery is attempted exactly 3 times and dispatch returns terminal failure without unbounded retries
**Layer:** integration
**Acceptance criterion mapped:** bounded retry policy and terminal-failure handling

### TC-OBS-06-INT-04: Correlation ID and payload envelope are deterministic for same input
**Given:** fixed alert type, trigger key, and occurred_at timestamp
**When:** correlation ID and payload are generated
**Then:** correlation ID matches `obs06:<alert_type>:<trigger_key>:<occurred_at_epoch_ms>` and payload includes stable required envelope keys
**Layer:** unit
**Acceptance criterion mapped:** deterministic payload and correlation ID contract

### TC-OBS-06-INT-05: DLQ depth source and trigger state persistence use observable DB semantics
**Given:** deterministic DLQ rows in `pending`, `retrying`, and non-counted statuses plus persisted trigger-state records
**When:** DLQ depth is read and trigger state is persisted twice for same key
**Then:** depth counts only `pending` and `retrying`; state row is upserted and latest values are visible
**Layer:** integration
**Acceptance criterion mapped:** integration with OBS-05 depth source and durable trigger-state behavior

## Execution Targets For TEST-RUNNER

- `zig build test` (covers OBS-06 deterministic payload/correlation and state-machine tests in `src/obs/alerts.zig`)
- `zig build test-integration` (covers OBS-06 integration tests in `tests/integration/obs06_alerts_test.zig` through `tests/integration/main_test.zig`)
