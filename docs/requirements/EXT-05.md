---
id: EXT-05
title: Sub-process support
stage: 6
priority: SHOULD
status: VALIDATED
---

# EXT-05 — Sub-process support `[SHOULD]`

> The platform SHALL support a SUB_PROCESS node type that starts a child process instance from a referenced definition. The parent instance waits for the child to complete before continuing. **Child failure handling:** if the child instance transitions to ERROR status, the parent also transitions to ERROR status and appends a `CHILD_PROCESS_ERROR` event referencing the child instance ID. If the child is cancelled externally, the parent also transitions to ERROR status with a `CHILD_PROCESS_CANCELLED` event. Sub-processes do not support timeout at this stage; that is deferred to a future requirement.

**Acceptance Criteria:**
- GIVEN execution reaches a SUB_PROCESS node, WHEN activated, THEN a child instance is started from the referenced definition; the parent token enters a WAITING state.
- The child instance inherits a copy of the parent's variable map at the time of activation. Mutations in the child do NOT affect the parent.
- GIVEN the child instance reaches COMPLETED status, WHEN the completion event is detected, THEN the parent token advances past the SUB_PROCESS node and the child's output variables are merged into the parent per EE-09.
- GIVEN the child instance transitions to ERROR, THEN the parent also transitions to ERROR and a `CHILD_PROCESS_ERROR` event is appended containing the child's `instance_id`.
- GIVEN the child instance is cancelled externally (EE-08), THEN the parent also transitions to ERROR and a `CHILD_PROCESS_CANCELLED` event is appended.
- Cancelling the parent instance (EE-08) MUST NOT cascade to the child; the child continues independently.

**See:** EE-01 (child instance start reuses this logic), EE-08 (cancel parent does not cancel child), EE-09 (child output merged to parent on completion), EE-10 (ERROR state for parent on child failure)

**Edge cases:**
- Child definition is deprecated between parent activation and child completion: child instance uses the snapshot captured at start time (EE-01 snapshot rule).
- Parent cancelled while child is in WAITING for its own sub-process: parent cancels; child continues independently.
