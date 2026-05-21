# fn:update-issue

**Category:** ISS  
**Used by:** `ISSUE-FIXER`, `DOC-UPDATER`  
**Calls:** —

```
PURPOSE: Record the resolution and prevention measure for a known issue,
         closing the knowledge loop for future agents.

INPUT: issue_id, resolution, prevention, status ("RESOLVED" | "WONT-FIX")

1. Read docs/issues/<issue_id>.json (error if not found)
2. Update fields:
   - resolution: "<what was done to fix it, including file paths changed>"
   - prevention: "<rule or pattern that prevents recurrence>"
   - status: "RESOLVED" | "WONT-FIX"
   - resolved_at: now()
3. Write updated file
4. Update the matching entry in docs/issues/issue_index.json (status field)
5. Return updated issue entry
```
