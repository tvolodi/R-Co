# Test Spec: SIM-04 - Deterministic UUIDs

**Requirement:** SIM-04 - In simulation mode, platform.uuid() MUST return deterministic UUIDs from a seeded sequence, not random values.
**Priority:** MUST
**Test layer:** unit

## Test Cases

### TC-SIM-04-01: Same seed yields identical UUID sequence
**Given:** Two simulation UUID sources initialized with the same seed
**When:** UUID values are generated in identical call order
**Then:** Each generated UUID at each index is identical between sources
**Layer:** unit
**Acceptance criterion mapped:** The same scenario produces the same UUID sequence across runs

### TC-SIM-04-02: Different seed yields different UUID sequence
**Given:** Two simulation UUID sources initialized with different seeds
**When:** The first UUID is generated from each source
**Then:** The UUID values differ
**Layer:** unit
**Acceptance criterion mapped:** UUID output is seed-driven and deterministic
