# fn:run-frontend-unit-tests

**Category:** TEST  
**Used by:** `TEST-RUNNER`, `ISSUE-FIXER`, `FRONTEND-DEV`  
**Calls:** —

```
INPUT: optional component/module path
1. Run: cd web && npm run test -- [--path <path>] --reporter=json
2. Parse Vitest JSON output
3. Return list of {test_name, file, status, error_message}
```
