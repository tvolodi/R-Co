# fn:run-e2e-tests

**Category:** TEST  
**Used by:** `TEST-RUNNER`, `RELEASE-VALIDATOR`  
**Calls:** —

```
PRE-CONDITION: Full stack running (backend + frontend + test DB)
1. Run: cd web && npx playwright test --reporter=json
2. Parse Playwright JSON output
3. Return list of {test_name, file, status, screenshot_path_on_fail}
```
