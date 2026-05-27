# Inner Report: DSL-05 Coercion Design

**Agent:** CODE-DESIGNER  
**Run ID:** WF02-dsl05-20260527  
**Date:** 2026-05-27T07:45:50Z  
**Status:** COMPLETED

## Summary

Designed the complete type coercion rules for the Expression DSL evaluator per DSL-05.

## Artefacts produced

- `src/design/dsl-05-coercion.md` — full coercion design covering:
  - 6×6 × 4 operator category coercion matrix
  - Three-valued null propagation logic
  - Evaluation strategy per Node variant
  - Updated `evaluateNode()` dispatch table
  - Complete test matrix (90+ test cases)
  - Error taxonomy with message constants
  - Data flow diagram (coercion layer)

## Acceptance criteria met

- [x] Coercion table covers all 6 types × all operator categories
- [x] No silent coercion in comparisons documented and enforced
- [x] Three-valued null logic fully specified
- [x] Test matrix covering every type pair and operator is specified
- [x] Design maps directly to implementable evaluateNode() changes

## Next action

Route to BACKEND-DEV (Step 2a) for implementation.
