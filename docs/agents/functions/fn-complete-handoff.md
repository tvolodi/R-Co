# fn:complete-handoff

**Category:** HO  
**Used by:** All agents (when finishing their task)  
**Calls:** — (must be preceded by `fn:register-inner-report`)

```
PRE-CONDITION: fn:validate-completeness AND fn:register-inner-report MUST have been called before this function.

INPUT: handoff_id, result (status, summary, artifacts_out, issues, next_action)
1. Read the handoff file
2. Set result field
3. Set status = COMPLETED (or FAILED if result.status == FAIL)
4. Set completed_at = now()
5. Write the updated handoff file
6. Update status in handoffs/registry.json for this handoff_id
```
