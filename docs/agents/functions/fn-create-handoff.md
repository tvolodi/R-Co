# fn:create-handoff

**Category:** HO  
**Used by:** `ORCH`  
**Calls:** `fn:register-handoff`

```
INPUT: run_id, step, to_agent, context, task, priority
1. Generate UUID v4 for handoff_id
2. Build filename: handoffs/<run_id>/step-<step>-<agent-slug>.json
3. Create directory handoffs/<run_id>/ if it does not exist
4. Write handoff JSON to the file
5. → fn:register-handoff (handoff_id, filename, run_id, step, to_agent, stage)
6. Append to handoffs/orchestrator.log:
     <ISO8601> | ROUTE | <run_id> | <handoff_id[:8]> | ORCH → <to_agent> | PENDING
7. Return handoff_id and filename
```

`fn:create-handoff` only prepares the open handoff and registers it in the active registry. When the handoff reaches a terminal state, ORCH archives the final snapshot to `handoffs/<run_id>/registry.json` through the completion path.
