# Test Spec: SIM-06 - Assertion vocabulary

**Requirement:** SIM-06 - Scenarios MUST support assertions on: event sequence (with wildcards), final variable values, final instance status, task assignments, no-occurrence of forbidden events.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-SIM-06-01: event_sequence assertion passes with wildcard match
**Given:** A scenario event trace and an event_sequence assertion including a wildcard
**When:** The scenario is executed
**Then:** The event_sequence assertion passes
**Layer:** integration
**Acceptance criterion mapped:** event sequence assertions support wildcard matching

### TC-SIM-06-02: event_sequence assertion fails on mismatch
**Given:** A scenario event trace and an event_sequence assertion with a mismatching order
**When:** The scenario is executed
**Then:** The event_sequence assertion fails
**Layer:** integration
**Acceptance criterion mapped:** event sequence assertions detect mismatches

### TC-SIM-06-03: final_variables assertion passes on exact match
**Given:** A scenario with expected and actual final variables that are equal
**When:** The scenario is executed
**Then:** The final_variables assertion passes
**Layer:** integration
**Acceptance criterion mapped:** final variable assertions are supported

### TC-SIM-06-04: final_variables assertion fails on mismatch
**Given:** A scenario with expected and actual final variables that differ
**When:** The scenario is executed
**Then:** The final_variables assertion fails
**Layer:** integration
**Acceptance criterion mapped:** final variable assertions detect mismatches

### TC-SIM-06-05: final_status assertion passes on exact status
**Given:** A scenario with matching expected and actual final status
**When:** The scenario is executed
**Then:** The final_status assertion passes
**Layer:** integration
**Acceptance criterion mapped:** final status assertions are supported

### TC-SIM-06-06: final_status assertion fails on status mismatch
**Given:** A scenario with non-matching expected and actual final status
**When:** The scenario is executed
**Then:** The final_status assertion fails
**Layer:** integration
**Acceptance criterion mapped:** final status assertions detect mismatches

### TC-SIM-06-07: task_assignments assertion passes on exact assignment set
**Given:** A scenario with matching expected and actual task assignment arrays
**When:** The scenario is executed
**Then:** The task_assignments assertion passes
**Layer:** integration
**Acceptance criterion mapped:** task assignment assertions are supported

### TC-SIM-06-08: task_assignments assertion fails on assignment mismatch
**Given:** A scenario with differing expected and actual task assignment arrays
**When:** The scenario is executed
**Then:** The task_assignments assertion fails
**Layer:** integration
**Acceptance criterion mapped:** task assignment assertions detect mismatches

### TC-SIM-06-09: forbidden_events assertion passes when forbidden events are absent
**Given:** A scenario trace that contains no forbidden event types
**When:** The scenario is executed
**Then:** The forbidden_events assertion passes
**Layer:** integration
**Acceptance criterion mapped:** forbidden event assertions are supported

### TC-SIM-06-10: forbidden_events assertion fails when forbidden event is present
**Given:** A scenario trace that contains a forbidden event type
**When:** The scenario is executed
**Then:** The forbidden_events assertion fails
**Layer:** integration
**Acceptance criterion mapped:** forbidden event assertions detect violations
