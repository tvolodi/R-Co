# fn:check-doc-freshness

**Category:** DOC  
**Used by:** `RELEASE-VALIDATOR`, `DOC-UPDATER`  
**Calls:** —

```
1. For each RELEASED requirement, verify:
   - A matching entry exists in CHANGELOG.md
   - docs/status/requirement_status.json shows status = RELEASED
   - If the requirement introduced an API endpoint: it appears in docs/openapi.json
2. Return list of stale or missing items
```
