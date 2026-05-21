# fn:run-unit-tests

**Category:** TEST  
**Used by:** `TEST-RUNNER`, `ISSUE-FIXER`, `BACKEND-DEV`  
**Calls:** —

```
INPUT: optional module name (e.g. ""engine"", ""event_store"")
1. If module specified: run zig build test-<module>
2. If no module: run zig build test
3. Capture test output
4. Parse results: list of {test_name, status: pass|fail|skip, error_message}
5. Return structured report
```
