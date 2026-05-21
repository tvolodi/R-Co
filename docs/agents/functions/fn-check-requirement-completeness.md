# fn:check-requirement-completeness

**Category:** REQ  
**Used by:** `REQ-VALIDATOR`  
**Calls:** —

```
For each requirement in working set:
  CHECK: Has a clear, verifiable acceptance criterion (not vague)
  CHECK: Does not contradict another requirement (cross-reference by ID)
  CHECK: Has a defined Priority (MUST/SHOULD/COULD)
  CHECK: References to other requirements use valid IDs
  CHECK: If MUST: can it be implemented within the stage boundary?
  CHECK: Is it testable (can a test be written that definitively passes or fails)?
Result: list of {requirement_id, passed: bool, issues: [string]}
```
