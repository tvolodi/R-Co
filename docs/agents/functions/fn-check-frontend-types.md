# fn:check-frontend-types

**Category:** CODE  
**Used by:** `FRONTEND-DEV`, `ISSUE-FIXER`  
**Calls:** —

```
1. Run: cd web && npx tsc --noEmit
2. Capture output
3. If exit code != 0: return FAIL with error list
4. If exit code == 0: return PASS
```
