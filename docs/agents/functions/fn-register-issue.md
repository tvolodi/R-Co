# fn:register-issue

**Category:** ISS  
**Used by:** `ISSUE-FIXER`, `TEST-RUNNER`, `BACKEND-DEV`, `FRONTEND-DEV`  
**Calls:** —

```
PURPOSE: Persist a new issue entry in the knowledge base so future agents
         can search for it and reuse the solution.

INPUT: title, description, root_cause, affected_areas[], error_detail, run_id, handoff_id

1. Read docs/issues/issue_index.json (create if absent: {"next_id": 1, "issues": []})
2. Assign ISS-ID: "ISS-" + zero-padded next_id (e.g. ISS-001)
3. Increment next_id and write back to issue_index.json
4. Build issue entry:
   {
     "issue_id": "ISS-NNN",
     "title": "<short title>",
     "description": "<full description>",
     "root_cause": "<root cause analysis>",
     "affected_areas": ["<module>", ...],
     "error_detail": "<exact error message or stack trace>",
     "status": "OPEN",
     "created_at": "<ISO8601 UTC>",
     "run_id": "<run_id>",
     "handoff_id": "<handoff_id>",
     "resolution": null,
     "prevention": null
   }
5. Write to docs/issues/ISS-NNN.json
6. Append {issue_id, title, affected_areas, status} to issue_index.json entries
7. Return issue_id
```
