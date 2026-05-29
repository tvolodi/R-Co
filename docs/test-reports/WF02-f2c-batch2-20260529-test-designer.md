# Test Designer Report — WF02-f2c-batch2-20260529

**Run ID:** WF02-f2c-batch2-20260529
**Agent:** TEST-DESIGNER
**Date:** 2026-05-29
**Requirements:** PD-09, PD-10, PD-UI-07, PD-UI-08

---

## Summary

All four requirements have test specs and test code. Backend integration tests (PD-09, PD-10) were already implemented in a prior run and verified to compile and pass. Frontend E2E tests (PD-UI-07, PD-UI-08) have been newly created.

| Requirement | Priority | Layer | Spec | Test Code | Status |
|-------------|----------|-------|------|-----------|--------|
| PD-09 (export/import) | SHOULD | integration | `tests/specs/PD-09.md` (7 TCs) | `tests/integration/test_export_import_integration.zig` (7 TCs) | EXISTING |
| PD-10 (search) | COULD | integration | `tests/specs/PD-10.md` (12 TCs) | `tests/integration/pd10_search_test.zig` (12 TCs) | EXISTING |
| PD-UI-07 (export/import buttons) | MUST | e2e | `tests/specs/PD-UI-07.md` (7 TCs) | `web/tests/e2e/pdui07-export-import.e2e.spec.ts` (7 TCs) | NEW |
| PD-UI-08 (debounced search) | MUST | e2e | `tests/specs/PD-UI-08.md` (6 TCs) | `web/tests/e2e/pdui08-debounced-search.e2e.spec.ts` (6 TCs) | NEW |

## Test Case Detail

### PD-09 — Definition import/export (SHOULD)

| TC ID | Description | Layer | Status |
|-------|-------------|-------|--------|
| TC-PD-09-const | EXPORT_SCHEMA_VERSION equals "bpm/definition/v1" | unit | EXISTING |
| TC-PD-09-01 | Export happy path returns ExportDocument with matching fields | integration | EXISTING |
| TC-PD-09-02 | Export unknown id returns DefinitionNotFound | integration | EXISTING |
| TC-PD-09-03 | Import happy path creates definition with DRAFT status | integration | EXISTING |
| TC-PD-09-04 | Import with name+version conflict returns NameVersionConflict | integration | EXISTING |
| TC-PD-09-05 | Import with invalid CEL condition returns InvalidGraph | integration | EXISTING |
| TC-PD-09-06 | Import with unknown schema version returns UnknownSchemaVersion | integration | EXISTING |
| TC-PD-09-07 | Export-import round-trip preserves full graph | integration | EXISTING |

### PD-10 — Definition search (COULD)

| TC ID | Description | Layer | Status |
|-------|-------------|-------|--------|
| TC-PD-10-01 | Exact name match returns result with rank 3.0 | integration | EXISTING |
| TC-PD-10-02 | Partial name match returns result with rank 2.0 | integration | EXISTING |
| TC-PD-10-03 | Description-only match returns result with rank 1.0 | integration | EXISTING |
| TC-PD-10-04 | No matching definitions returns empty slice | integration | EXISTING |
| TC-PD-10-05 | Empty query returns QueryEmpty without DB access | unit | EXISTING |
| TC-PD-10-06 | Query longer than 512 chars returns QueryTooLong | unit | EXISTING |
| TC-PD-10-07 | Uppercase query matches lowercase definition name | integration | EXISTING |
| TC-PD-10-08 | Name match ordered before description-only match | integration | EXISTING |
| TC-PD-10-09 | Limit and offset control the result window | integration | EXISTING |
| TC-PD-10-10 | SQL-special chars handled safely; no injection | integration | EXISTING |
| TC-PD-10-11 | Empty query (absent-param equivalent) returns QueryEmpty | unit | EXISTING |
| TC-PD-10-12 | DRAFT, ACTIVE, DEPRECATED, ARCHIVED all returned | integration | EXISTING |

### PD-UI-07 — Export/Import buttons (MUST)

| TC ID | Description | Layer | Status |
|-------|-------------|-------|--------|
| TC-PDUI07-01 | Export button is visible on definition editor page | e2e | NEW |
| TC-PDUI07-02 | Export button downloads a JSON file with definition data | e2e | NEW |
| TC-PDUI07-03 | Import button is visible on definition list page | e2e | NEW |
| TC-PDUI07-04 | Import button opens file picker dialog | e2e | NEW |
| TC-PDUI07-05 | Import with valid JSON file creates new definition | e2e | NEW |
| TC-PDUI07-06 | Import with invalid JSON shows error dialog | e2e | NEW |
| TC-PDUI07-07 | Import with name+version conflict shows error dialog | e2e | NEW |

### PD-UI-08 — Debounced full-text search (MUST)

| TC ID | Description | Layer | Status |
|-------|-------------|-------|--------|
| TC-PDUI08-01 | Search bar is visible on definition list page | e2e | NEW |
| TC-PDUI08-02 | Typing in search bar shows results after debounce | e2e | NEW |
| TC-PDUI08-03 | Empty search bar shows regular definition list | e2e | NEW |
| TC-PDUI08-04 | No results shows empty state message | e2e | NEW |
| TC-PDUI08-05 | Search results show highlighted matching text | e2e | NEW |
| TC-PDUI08-06 | Search bar does not fire request on every keystroke | e2e | NEW |

## Validation Results

- `zig build` → PASS (exit 0)
- `zig build test` → PASS (exit 0)
- All 7 PD-09 test cases: existing, verified compiling
- All 12 PD-10 test cases: existing, verified compiling
- All 7 PD-UI-07 test cases: newly created E2E spec + code
- All 6 PD-UI-08 test cases: newly created E2E spec + code
- No `error.SkipZigTest` on MUST test blocks
- All integration tests connect to real PostgreSQL via `BPM_TEST_DB_URL`
- All E2E tests connect to real backend (no MSW, no mocks)
- Fixtures use per-test UUIDs with cleanup

## Artefacts Produced

- `tests/specs/PD-UI-07.md`
- `tests/specs/PD-UI-08.md`
- `web/tests/e2e/pdui07-export-import.e2e.spec.ts`
- `web/tests/e2e/pdui08-debounced-search.e2e.spec.ts`

## Issues

None. All pre-existing backend tests compile and pass. Frontend E2E tests are syntactically valid Playwright using the established patterns from the existing `f2-definition-list.e2e.spec.ts`.
