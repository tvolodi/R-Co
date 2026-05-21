# fn:check-frontend-build

**Category:** CODE  
**Used by:** `FRONTEND-DEV`, `ISSUE-FIXER`, `TEST-RUNNER`  
**Calls:** —

```
1. Run: cd web && npm run build
2. Capture stdout and stderr
3. If exit code != 0:
   - Parse TypeScript/ESBuild errors
   - Return FAIL with list of {file, line, message}
4. If exit code == 0: return PASS
```
