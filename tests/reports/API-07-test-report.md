# Test Report: API-07 — Input Validation

**Run ID:** WF02-api07-20260523  
**Timestamp:** 2026-05-23T04:43:17Z  
**Agent:** TEST-RUNNER  
**Requirement:** API-07 — Input validation (MUST)  
**Test layer:** unit  

---

## Summary

| Metric | Count |
|---|---|
| **Total API-07 tests** | 36 |
| **Passed** | 36 |
| **Failed (assertion)** | 0 |
| **Skipped** | 0 |
| **Memory leaks** | 0 |
| **Overall exit code** | 0 (PASS) |

**Verdict: PASS** — All 36 API-07 tests pass with 0 memory leaks. `zig build test` exits 0.

## Build Summary

```
Build Summary: 49/49 steps succeeded; 246/348 tests passed (102 skipped)
test success
+- run test 36 pass (36 total)
```

## Previous Failures — Now Resolved

The prior run (2026-05-23T04:30:17Z) showed 8 memory leaks across 3 tests (TC-API-07-06, TC-API-07-07, TC-API-07-07b), all originating from `parseFromValue` with `.alloc_always` in `src/api/validation.zig:validate()`. After the BACKEND-DEV fix in step-02a, all leaks are resolved — the `validate()` function now properly frees its internal arena allocator before returning.

## Test Execution Details

### All 36 tests and their results:

| # | Test | Result |
|---|---|---|
| 1 | TC-API-07-01: validateField returns FieldError for missing required field | ✅ PASS |
| 2 | TC-API-07-02: validateField returns FieldError for wrong type (string expected, got integer) | ✅ PASS |
| 3 | TC-API-07-02b: validateField returns FieldError for wrong type (string expected, got boolean) | ✅ PASS |
| 4 | TC-API-07-02c: validateField returns FieldError for wrong type (boolean expected, got null) | ✅ PASS |
| 5 | TC-API-07-03: validate collects all errors, not just the first | ✅ PASS |
| 6 | TC-API-07-04: empty required string with reject_empty_string treated as missing | ✅ PASS |
| 7 | TC-API-07-04b: empty required string without reject_empty_string passes type check | ✅ PASS |
| 8 | TC-API-07-05: validate with non-object JSON returns type.object error | ✅ PASS |
| 9 | TC-API-07-06: valid payload returns .ok with parsed value | ✅ PASS |
| 10 | TC-API-07-07: enforceValidation returns .reject for invalid payload | ✅ PASS |
| 11 | TC-API-07-07b: enforceValidation returns .ok for valid payload | ✅ PASS |
| 12 | TC-API-07-08: optional field absent returns null (no error) | ✅ PASS |
| 13 | TC-API-07-09: optional field with correct type returns null (no error) | ✅ PASS |
| 14 | TC-API-07-10: string exceeding max_length returns FieldError | ✅ PASS |
| 15 | TC-API-07-11: string below min_length returns FieldError | ✅ PASS |
| 16 | TC-API-07-12: non-required empty string with reject_empty_string returns not_empty error | ✅ PASS |
| 17 | TC-API-07-13: null value with required=true returns FieldError | ✅ PASS |
| 18 | TC-API-07-14: null value with required=false returns null (no error) | ✅ PASS |
| 19 | TC-API-07-15: integer below min_value returns FieldError | ✅ PASS |
| 20 | TC-API-07-16: integer above max_value returns FieldError | ✅ PASS |
| 21 | TC-API-07-17: array below min_items returns FieldError | ✅ PASS |
| 22 | TC-API-07-18: array above max_items returns FieldError | ✅ PASS |
| 23 | TC-API-07-19: serialiseValidationErrors produces valid JSON with expected fields | ✅ PASS |
| 24 | TC-API-07-20: multiple FieldErrors serialised as comma-separated array | ✅ PASS |
| 25 | TC-API-07-21: FieldError with received value serialises the fragment | ✅ PASS |
| 26 | TC-API-07-22: field without expected_type accepts any JSON type | ✅ PASS |
| 27 | TC-API-07-23: integer field with correct integer type passes | ✅ PASS |
| 28 | TC-API-07-24: number type accepts both integer and float JSON values | ✅ PASS |
| 29 | TC-API-07-25: type check runs before string length constraints | ✅ PASS |
| 30 | TC-API-07-26: string at exactly max_length boundary passes | ✅ PASS |
| 31 | TC-API-07-27: string at exactly min_length boundary passes | ✅ PASS |
| 32 | TC-API-07-28: integer at exactly min_value boundary passes | ✅ PASS |
| 33 | TC-API-07-29: integer at exactly max_value boundary passes | ✅ PASS |
| 34 | TC-API-07-30: array at exactly min_items boundary passes | ✅ PASS |
| 35 | TC-API-07-31: array at exactly max_items boundary passes | ✅ PASS |
| 36 | TC-API-07-32: validateField respects reject_empty_string before type check | ✅ PASS |

---

## Coverage

Not measured (coverage instrumentation not requested for this run).

## Next Action

Route to **RELEASE-VALIDATOR** (WF-02 Step 5) — all acceptance criteria met.
