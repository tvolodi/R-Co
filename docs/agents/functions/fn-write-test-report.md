# fn:write-test-report

**Category:** TEST  
**Used by:** `TEST-RUNNER`  
**Calls:** —

```
INPUT: test results (from fn:run-* functions)
1. Aggregate all results into a unified report structure
2. Compute summary: total, passed, failed, skipped
3. Classify failures: BLOCKER (failing MUST req), MAJOR (failing SHOULD req), MINOR (other)
4. Write to tests/reports/report-<ISO8601-date>-<run_id>.json
5. Return report file path and summary
```
