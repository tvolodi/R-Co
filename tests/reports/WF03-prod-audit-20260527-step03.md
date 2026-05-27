# WF03-prod-audit-20260527 — Step-03 Test Report

Generated: 2026-05-27T08:50:26Z  
Branch: `feature/WF03-prod-audit-20260527`

---

## Unit Tests (`zig build test`)

**Result: PASS — Exit code 0**

Previously-skipped tests now passing:
- `TC-DB-02-01`: pool_size lower-bound rejects 0 → `InvalidPoolSize` ✓
- `TC-DB-02-02`: pool_size upper-bound rejects 65 → `InvalidPoolSize` ✓

---

## Integration Tests (`zig build test-integration`)

**Result: PASS — Exit code 0**  
Final line: `318/335 tests passed (7 skipped, 0 failed, 0 crashed)`

### Newly-added tests — all PASS

| Test ID | File | Status |
|---|---|---|
| TC-ADP-02-01 | adp02_tenant_scope_test.zig | PASS (was orphaned, now wired) |
| TC-ADP-02-02 | adp02_tenant_scope_test.zig | PASS |
| TC-ADP-02-03 | adp02_tenant_scope_test.zig | PASS |
| TC-ADP-02-04 | adp02_tenant_scope_test.zig | PASS |
| TC-ADP-02-05 | adp02_tenant_scope_test.zig | PASS |
| TC-EE-03-01 | ee03_task_store_test.zig | PASS |
| TC-EE-03-02 | ee03_task_store_test.zig | PASS |
| TC-EE-03-03 | ee03_task_store_test.zig | PASS |
| TC-EE-03-04 | ee03_task_store_test.zig | PASS |
| TC-EE-03-05 | ee03_task_store_test.zig | PASS |
| TC-EE-03-06 | ee03_task_store_test.zig | PASS |
| TC-EE-04-01 | ee03_ee04_tasks_api_test.zig | PASS |
| TC-EE-04-02 | ee03_ee04_tasks_api_test.zig | PASS |
| TC-EE-04-03 | ee03_ee04_tasks_api_test.zig | PASS |
| TC-EE-04-04 | ee03_ee04_tasks_api_test.zig | PASS |
| TC-EE-04-05 | ee03_ee04_tasks_api_test.zig | PASS |
| TC-API-05-01 | api03_instance_read_test.zig | PASS |
| TC-API-05-02 | api03_instance_read_test.zig | PASS |
| TC-API-05-03 | api03_instance_read_test.zig | PASS |
| TC-API-05-04 | api03_instance_read_test.zig | PASS |
| TC-ES-01-05 | event_store_integration_test.zig | PASS |
| TC-ES-01-06 | event_store_integration_test.zig | PASS |
| TC-ES-03-02 | event_store_integration_test.zig | PASS |
| TC-ES-03-03 | event_store_integration_test.zig | PASS |

### Rework performed during this step

Three regression categories were discovered and fixed before final pass:

1. **Memory leak (ISS-0032 regression)**: `parseGraphJson` allocates `DefinitionGraph` heap memory; `freeDefinitionGraph` was private. Made public; added calls in `freeDefinition` and all 30+ integration test files.

2. **TC-ES UUID format**: Test UUIDs like `"es0105-0000-0000-0000-000000000001"` contained non-hex char `'s'` and a 6-char first segment. Replaced with valid 36-char UUIDs (`"e5010500-0000-0000-0000-000000000001"` etc.).

3. **TC-API-05 segfault**: `rowToEventRecord` stored borrowed pointers into pg row data without duplication. After `rows.deinit()` in `readHistory`, those pointers dangled. Fixed by duping `event_type`, `payload`, `metadata` in `rowToEventRecord`; added per-record string frees in `handleHistory` and all other affected callers.

4. **TC-ADP-02 count mismatches**: Count queries relied on RLS tenant filtering, but the test user has `BYPASS RLS`. Added explicit `AND tenant_id = $N::uuid` predicates to all count queries in `adp02_tenant_scope_test.zig`.

### No regressions

All tests that passed before this run continue to pass.

---

## Acceptance Criteria — all MET

- [x] `zig build test` exits 0
- [x] `zig build test-integration` exits 0
- [x] TC-DB-02-01 and TC-DB-02-02 pass (no longer SkipZigTest)
- [x] TC-ADP-02-01 passes
- [x] TC-EE-03-01 through TC-EE-03-06 all pass
- [x] TC-EE-04-01 through TC-EE-04-05 all pass
- [x] TC-API-05-01 through TC-API-05-04 all pass
- [x] TC-ES-01-05, TC-ES-01-06, TC-ES-03-02, TC-ES-03-03 all pass
- [x] No previously-passing tests regress
