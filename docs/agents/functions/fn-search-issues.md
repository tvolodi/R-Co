# fn:search-issues

**Category:** ISS  
**Used by:** `ISSUE-FIXER`, `BACKEND-DEV`, `FRONTEND-DEV`  
**Calls:** —

```
PURPOSE: Search the issue knowledge base before starting any fix. Reuse proven
         solutions instead of re-diagnosing from scratch.

INPUT: keywords[], affected_areas[] (optional), error_snippet (optional)

1. Read docs/issues/issue_index.json
2. If file does not exist: return [] (empty knowledge base — no prior issues)
3. Filter entries by:
   a. Any keyword appears in title or affected_areas (case-insensitive)
   b. If affected_areas provided: intersection with entry.affected_areas is non-empty
4. For each matching entry:
   - Read docs/issues/<issue_id>.json
   - If error_snippet provided: score by similarity to entry.error_detail
     (exact substring match = HIGH, overlapping tokens = MEDIUM, no overlap = SKIP)
5. Sort by: RESOLVED issues first, then by score descending
6. Return top 5 matches:
   [{
     "issue_id": "ISS-NNN",
     "title": "<title>",
     "root_cause": "<root cause>",
     "resolution": "<resolution or null>",
     "prevention": "<prevention or null>",
     "status": "OPEN | RESOLVED"
   }]

USAGE RULE: If any RESOLVED match has the same root cause as the current problem,
            apply that resolution strategy before attempting novel approaches.
```
