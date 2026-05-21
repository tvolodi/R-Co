# fn:check-code-coverage

**Category:** CODE  
**Used by:** `TEST-RUNNER`, `RELEASE-VALIDATOR`  
**Calls:** —

```
1. Run: zig build test-coverage (backend) or cd web && npm run test:coverage (frontend)
2. Parse coverage report
3. Check thresholds (from docs/guides/test_developer_guide.md):
   - Backend unit tests: ≥ 90% line coverage on pure functions
   - Frontend: ≥ 80% line coverage on non-UI logic
4. Return PASS/FAIL with per-module coverage percentages
```
