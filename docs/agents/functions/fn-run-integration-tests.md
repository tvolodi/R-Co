# fn:run-integration-tests

**Category:** TEST  
**Used by:** `TEST-RUNNER`, `RELEASE-VALIDATOR`  
**Calls:** —

```
PRE-CONDITION: PostgreSQL test instance running; BPM_TEST_DB_URL set
1. Run: zig build test-integration
2. Capture output
3. Parse pass/fail per test case
4. Return structured report with timing info
```
