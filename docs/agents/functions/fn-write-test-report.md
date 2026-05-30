# fn:write-test-report

**Category:** TEST  
**Used by:** `TEST-RUNNER`  
**Calls:** —

```
INPUT: test results (from fn:run-* functions)
1. Aggregate all results into a unified report structure
2. Compute summary: total, passed, failed, skipped
3. Classify failures: BLOCKER (failing MUST req), MAJOR (failing SHOULD req), MINOR (other)
4. Write to tests/reports/report-<ISO8601-date>-<run_id>.yaml  ← YAML format required
5. Return report file path and summary
```

Output format (YAML):
```yaml
run_id: <uuid>
workflow_id: <WF-04 or WF-02>
timestamp: <ISO8601>
summary:
  total: 142
  passed: 138
  failed: 3
  skipped: 1
failures:
  - test_id: TC-EE-05-03
    layer: unit
    file: tests/unit/engine_test.zig
    error_message: "..."
    severity: BLOCKER
    requirement_id: EE-05
coverage:
  backend_unit_line: 92.4
  frontend_unit_line: 83.1
nfr_results:
  - nfr_id: NFR-01
    target: "p99 ≤ 200ms reads"
    actual: "p99 = 143ms"
    passed: true
```

**⛔ Do NOT write `.json` reports.** If prior reports used `.json`, the new report still uses `.yaml`.
