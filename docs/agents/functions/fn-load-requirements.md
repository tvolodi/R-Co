# fn:load-requirements

**Category:** REQ  
**Used by:** `REQ-ANALYST`, `REQ-VALIDATOR`, `CODE-DESIGNER`, `TEST-DESIGNER`  
**Calls:** —

```
1. Read docs/BPM_Platform_Functional_Requirements.md
2. Read docs/BPM_Platform_Backend_Architecture.md
3. Read docs/BPM_Platform_Frontend_Requirements.md
4. Filter to the stage and requirement IDs specified in the handoff context
5. Build a working set: list of {id, description, priority, stage, acceptance_criteria}
6. Return working set to the calling context
```
