# fn:load-test-specs

**Category:** TEST  
**Used by:** `TEST-DESIGNER`, `TEST-RUNNER`  
**Calls:** —

```
INPUT: requirement_ids (list)
1. Read all files under tests/specs/ matching the requirement IDs
2. Return list of test case specifications
3. If no spec file exists for a MUST requirement: flag as missing (BLOCKER)
```
