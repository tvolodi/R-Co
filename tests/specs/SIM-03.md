# Test Spec: SIM-03 - Time control

**Requirement:** SIM-03 - In simulation mode, platform.now() MUST return the scenario-controlled time, not wall clock time. Scenarios MAY advance time programmatically.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-SIM-03-01: Clock reads configured start time and advances deterministically
**Given:** A simulation platform clock initialized with a fixed start time
**When:** Time is advanced by a fixed delta
**Then:** nowMs returns the deterministic expected value
**Layer:** unit
**Acceptance criterion mapped:** A scenario asserting time-dependent behaviour passes deterministically

### TC-SIM-03-02: Programmatic time set and advance control scheduler-visible time
**Given:** A simulation platform clock
**When:** setMs and advanceMs are invoked in sequence
**Then:** nowMs reflects the exact requested simulation time transitions
**Layer:** unit
**Acceptance criterion mapped:** Programmatic time advancement triggers timer-dependent logic correctly
