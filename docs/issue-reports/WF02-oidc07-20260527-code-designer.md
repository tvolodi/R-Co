# Inner Report: WF02-oidc07-20260527 CODE-DESIGNER

## Scope

Produced Step 01 design artifact for requirement OIDC-07 claim validation.

## Inputs reviewed

- docs/BPM_Platform_Functional_Requirements.md (OIDC-07 section)
- handoffs/WF02-oidc07-20260527/step-01-code-designer.json
- handoffs/WF02-oidc07-20260527/step-00-backend-dev.json
- handoffs/WF02-oidc07-20260527/estimation.json
- src/design/oidc-06-jwks-caching.md

## Output

- src/design/oidc-07-claim-validation.md

## Design decisions

- Signature verification remains upstream in OIDC-06; OIDC-07 starts after signature success.
- Issuer and audience are validated against tenant-scoped realm config.
- Temporal validation uses symmetric skew with default 30 seconds and non-negative constraint.
- All invalid cases map to structured HTTP 401 with stable machine codes.
- Explicit unit and integration test plans cover each required invalid-case criterion.

## Issues

None.
