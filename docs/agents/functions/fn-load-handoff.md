# fn:load-handoff

**Category:** HO  
**Used by:** All agents (at start of task)  
**Calls:** —

```
INPUT: handoff_id or (run_id + step)
1. Find filename in handoffs/registry.json by handoff_id (or by run_id + step)
2. Read and parse the handoff JSON file
3. Verify status == IN_PROGRESS (set it to IN_PROGRESS if PENDING)
4. Return handoff object
```
