# fn:update-requirement-status

**Category:** REQ  
**Used by:** `DOC-UPDATER`, `RELEASE-VALIDATOR`  
**Calls:** —

```
INPUT: requirement_id, new_status, optional metadata (implemented_in, test_ids, released_in)
1. Read docs/status/requirement_status.json
2. Find entry for requirement_id (create if absent with status = DRAFT)
3. Validate transition is legal:
   DRAFT → VALIDATED → DESIGNED → IMPLEMENTED → TESTED → RELEASED
   (Only forward transitions allowed; backward only via explicit ORCH escalation)
4. Update the entry fields
5. Set last_updated = now (ISO8601 UTC)
6. Write docs/status/requirement_status.json
7. Return updated entry
```
