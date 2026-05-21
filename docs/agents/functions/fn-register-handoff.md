# fn:register-handoff

**Category:** HO  
**Used by:** `ORCH` (via `fn:create-handoff`)  
**Calls:** —

```
INPUT: handoff_id, filename, run_id, step, to_agent, stage
1. Read handoffs/registry.json (create file with empty entries array if absent)
2. Append new entry with status = PENDING
3. Write registry.json
```
