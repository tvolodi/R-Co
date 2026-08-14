# CODE-DESIGN-VALIDATOR: E010 lint rule requires explicit "Error taxonomy" / "Errors" / "Error cases" section

## Rule
`tools/lint_design_artefact.py` rule E010 is a MAJOR-level check that every Type E
prose design artefact (`src/design/*.md`) MUST contain a top-level section heading
matching one of: `error taxonomy`, `errors`, or `error cases`. A single MAJOR
terminates validation with FAIL — even when the rest of the design is content-complete.

## How to satisfy (verified WF02-pw13-pw16-batch19-20260813, 2026-08-13)
Add a substantive section (e.g. `## 12. Error taxonomy`) that enumerates runtime
failure modes per requirement covered. Don't just add a stub heading — E010 (or
adjacent rules like E020) will flag empty sections.

Recommended subsection structure:
- `### 12.<n> <REQUIREMENT-ID> error modes`
- Numbered list, each entry with: trigger condition, observable surface behaviour,
  test assertion.

Minimum error-mode checklist (CODE-DESIGN-VALIDATOR commonly asks for these):
- Rate-limit classification failures (429 without Retry-After, non-integer Retry-After)
- Conflict-resolver 409-without-XRV edge cases
- axe scan timeout vs violation distinction
- BLOCKER-unreachable path (Keycloak + BPM API + PostgreSQL for E2E gate)
- Dangling aria-errormessage detection
- fieldRegistry lookup miss → fall-through to defaultBuiltinRenderer
- 409 on non-definition endpoint fallbacks
- Refetch-during-network-failure
- color-contrast E_CONFIG trip-wire
- report-write failure (atomic fsync)
- aria-busy cleared in `finally`
- Missing required schema → attribute omission
- Multi-hint space-separated aria-describedby ordering

## Verification command
```
python tools/lint_design_artefact.py src/design/<artefact>.md
# Expected: "OK — 1 file(s) checked, no issues." (exit 0)
```

## Related lint rules
- E010: missing required section heading → MAJOR
- E020 / E030: prose-vs-DDL check for Type E artefacts (no SQL DDL in prose)
- E050: 40-line fenced block limit (no full bodies)

## Related memory files
- bpm-design-validator-e030-prose-vs-ddl.md — the SQL-DDL companion check
- bpm-design-validator-grep-scope.md — grep scope when validating coverage
