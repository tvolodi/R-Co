# fn:register-handoff

**Category:** HO  
**Used by:** `ORCH` (via `fn:create-handoff`)  
**Calls:** —

```
INPUT: handoff_id, filename, run_id, step, to_agent, stage
1. Read `handoffs/registry.json` (create file with an empty active-index structure if absent)
2. Upsert the open handoff entry by `handoff_id` with status = PENDING
3. Write `handoffs/registry.json`
```

This function manages the active registry only. Terminal handoffs are archived separately in `handoffs/<run_id>/registry.json` when ORCH closes the handoff.
