# Test Spec: SCH-03 - Timer cancellation

**Requirement:** SCH-03 - When an instance is cancelled or completes, all pending timers for that instance SHALL be cancelled atomically within the same transaction that records the cancellation/completion event. No pending timer for a CANCELLED or COMPLETED instance must be fired by SCH-02. If firing and cancellation race, first transaction commit wins; the other is rolled back.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SCH-03-01: Completion atomically cancels pending timers and scheduler does not fire them
**Given:** An ACTIVE instance with at least one PENDING timer and one PENDING human task that will complete the instance.
**When:** The task is completed and the instance transitions to COMPLETED.
**Then:** All PENDING timers for that instance are updated to CANCELLED in the same completion transaction.
**And:** A scheduler poll does not fire those CANCELLED timers and appends no TIMER_FIRED event.
**Layer:** integration
**Acceptance criterion mapped:** Atomic pending-timer cancellation on completion; non-fire guarantee for CANCELLED timers.

### TC-SCH-03-02: Cancellation atomically cancels all pending timers and does not affect already FIRED timers
**Given:** An ACTIVE instance with multiple PENDING timers and one already FIRED timer.
**When:** The instance is cancelled.
**Then:** All PENDING timers become CANCELLED atomically in the cancellation transaction.
**And:** Existing FIRED timers remain FIRED (no retroactive cancellation).
**And:** A scheduler poll does not fire any timer for that cancelled instance.
**Layer:** integration
**Acceptance criterion mapped:** Atomic pending-timer cancellation on cancellation; explicit non-impact on already FIRED timers; scheduler non-fire guarantee.

### TC-SCH-03-03: First-commit-wins ordering when fire commits before cancel
**Given:** A due PENDING timer and an ACTIVE instance.
**When:** SCH-02 firing commits first, and instance cancellation occurs after.
**Then:** The timer remains FIRED, and cancellation does not convert it to CANCELLED.
**Layer:** integration
**Acceptance criterion mapped:** Fire-vs-cancel first-commit-wins rule (fire-first outcome).

### TC-SCH-03-04: First-commit-wins ordering when cancel commits before fire attempt
**Given:** A due PENDING timer on an ACTIVE instance.
**When:** Instance cancellation commits before the scheduler fire attempt.
**Then:** Timer status is CANCELLED and SCH-02 does not append TIMER_FIRED.
**Layer:** integration
**Acceptance criterion mapped:** Fire-vs-cancel first-commit-wins rule (cancel-first outcome) and non-fire guarantee for CANCELLED timers.

## Traceability Matrix

| SCH-03 acceptance slice | Covered by test case(s) |
|---|---|
| Atomic cancellation of all PENDING timers on COMPLETED | TC-SCH-03-01 |
| Atomic cancellation of all PENDING timers on CANCELLED | TC-SCH-03-02 |
| CANCELLED timers are never fired by SCH-02 | TC-SCH-03-01, TC-SCH-03-02, TC-SCH-03-04 |
| Fire-vs-cancel first-commit-wins | TC-SCH-03-03, TC-SCH-03-04 |
| FIRED timers are not impacted by cancellation/completion | TC-SCH-03-02, TC-SCH-03-03 |
