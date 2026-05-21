# fn:check-zig-build

**Category:** CODE  
**Used by:** `BACKEND-DEV`, `ISSUE-FIXER`, `TEST-RUNNER`  
**Calls:** —

```
1. Run: zig build
2. Capture stdout and stderr
3. If exit code != 0:
   - Parse error lines (format: file:line:col: error: message)
   - Return FAIL with list of {file, line, col, message}
4. If exit code == 0: return PASS
```
