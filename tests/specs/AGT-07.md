# Test Specification: AGT-07 — Deprecated Envelope Field Names Rejected

**Requirement:** AGT-07  
**Run ID:** WF02-agt05-07-20260819  
**Test file:** tests/integration/test_agt05_07.zig  

---

## Summary

AGT-07 requires that the envelope field `ignore_fields` is rejected before schema or kind
validation. Any envelope containing `ignore_fields` (regardless of its value, including empty
array) returns HTTP 400 `deprecated_field:ignore_fields`. The check runs after body parse but
before kind validation, so an otherwise-invalid envelope still gets the deprecated-field error.
No `agent_artifacts` row is written.

---

## Test Cases

| ID | Title | Inputs | Expected |
|---|---|---|---|
| TC-AGT07-01 | `ignore_fields` with value rejected | Valid envelope + `"ignore_fields": ["x"]` | HTTP 400; body contains `deprecated_field:ignore_fields`; no artifact row |
| TC-AGT07-02 | Both `ignore_fields` and `non_deterministic_fields` present → same 400 | Valid envelope + both fields | HTTP 400 `deprecated_field:ignore_fields` (ignore_fields check wins) |
| TC-AGT07-03 | `ignore_fields` empty array rejected | Valid envelope + `"ignore_fields": []` | HTTP 400 `deprecated_field:ignore_fields` |
| TC-AGT07-04 | Deprecated check fires before schema validation | Invalid envelope (missing `kind`) + `"ignore_fields": ["x"]` | HTTP 400 `deprecated_field:ignore_fields` (not `missing_field_kind` or 422) |
| TC-AGT07-05 | No artifact row after deprecated field rejection | Any of TC-AGT07-01..04 scenario | DB query confirms no `agent_artifacts` row was written |

---

## Notes

- All tests call `handleArtifactSubmit` directly with `production_mode = false`.
- TC-AGT07-05 is verified as part of TC-AGT07-01..04 by querying `staging.agent_artifacts`
  after each call — the spec case count matches the test count (5 test blocks total).
- No `error.SkipZigTest` on any test block.
