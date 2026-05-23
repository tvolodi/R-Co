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
4. Get the actual current UTC timestamp by running a shell command — do NOT invent or guess the time:
   PowerShell: (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
   Bash/Python: python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))"
   Use the exact string printed by the command as completed_at.
5. Set completed_at to that value
6. Write the updated handoff file
7. Update status in handoffs/registry.json for this handoff_id
```

> ⛔ **NEVER write a timestamp from memory or by guessing.** LLM agents cannot access a clock. Any invented timestamp will be wrong and breaks the retrospective metrics. Step 4 is mandatory — run the command, read the output, use that string.
