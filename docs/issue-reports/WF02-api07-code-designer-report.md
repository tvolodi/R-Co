# Inner Report: CODE-DESIGNER — API-07 Input Validation Design

**Run ID:** WF02-api07-20260523
**Handoff ID:** a0700001-2605-4000-8007-202605230001
**Date:** 2026-05-23T03:57:49Z
**Status:** PASS

---

## Design Artefact

`src/design/api-validation.md` — Complete design for the API-07 input validation module.

## Acceptance Criteria Check

| AC | Status | Notes |
|---|---|---|
| Design artefact created | ✅ | `src/design/api-validation.md` |
| Covers all API-07 acceptance criteria | ✅ | Full mapping table in §Acceptance criteria mapping |
| References `src/api/errors.zig` | ✅ | `ProblemDetails` embedded in `ValidationProblemDetails`; existing constructors unchanged |
| References `src/api/response.zig` | ✅ | `HandlerResult` used in `validationErrorResponse()`; middleware returns `response.HandlerResult` |
| Defines module interface: types, functions, error handling | ✅ | `ValidationError`, `Schema(T)`, `ValidationResult(T)`, `FieldConstraint`, `JsonType`, all public functions |
| Addresses edge cases: malformed JSON, empty required fields, all errors listed | ✅ | Malformed JSON → HTTP 400 upstream; empty strings → `constraint: "required"`; collector pattern collects all errors |

## Design Decisions

1. **Non-breaking extension of errors.zig** — New `ValidationProblemDetails` wrapper struct instead of modifying `ProblemDetails` directly.
2. **Middleware pipeline placement** — Validation runs after `content_type.zig`, before route handlers.
3. **Pure validator** — Zero I/O; validates `std.json.Value` against compile-time schema definitions.
4. **Schema co-location** — Per-route `Schema(T)` constants defined in each route file (recommended).
5. **Nested validation deferred** — Top-level field validation only for Stage 4; nested object/array validation deferred to Stage 5.

## Open Questions for BACKEND-DEV

1. Schema registration location (per-route vs central registry)
2. Typed context propagation mechanism in http.zig
3. Nested field path format for Stage 5

## Next Action

Route to BACKEND-DEV (Step 2a) for implementation.
