# fn:load-handoff

**Category:** HO  
**Used by:** All agents (at start of task)  
**Calls:** —

```
INPUT: handoff_id or (run_id + step)
1. Resolve the handoff filename from `handoffs/registry.json` first, then fall back to `handoffs/<run_id>/registry.json` if the active registry does not contain the open handoff or the active registry is missing/stale
2. Read and parse the run-local handoff JSON file
3. Verify status == IN_PROGRESS (set it to IN_PROGRESS if PENDING)
4. If the active registry and handoff file disagree, prefer the handoff file and flag the mismatch for ORCH recovery
5. Return handoff object
```

Agents should always treat the run-local handoff file as the task-level source of truth. The registries are lookup and recovery aids, not the authoritative task record.
