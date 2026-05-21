# fn:update-changelog

**Category:** DOC  
**Used by:** `DOC-UPDATER`  
**Calls:** —

```
INPUT: stage, list of {requirement_id, summary}
1. Read docs/CHANGELOG.md (create if absent)
2. Prepend a new entry:
   ## Stage <N> — <date>
   ### Added
   - [REQ-ID] <summary>
3. Write docs/CHANGELOG.md
```
