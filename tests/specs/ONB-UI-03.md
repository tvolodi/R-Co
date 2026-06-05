---
requirement_id: ONB-UI-03
spec_version: "1.0"
test_file: web/tests/e2e/onboarding/onb-ui-03.e2e.spec.ts
stage: F7 — Tenant Onboarding GUI
---

# Spec: ONB-UI-03 — Onboarding Progress Display

## Requirement text

> After a successful form submission, the platform MUST display a progress indicator while the onboarding saga executes asynchronously. The platform MUST poll `GET /api/v1/onboarding/:onboardingId` at the configured interval. When the saga reaches a terminal state (`completed` or `failed`), polling MUST stop and the user MUST be advanced to the result screen.

## Polling lifecycle rules

| Event | Behaviour |
|---|---|
| Component mounts | Interval starts immediately at `VITE_POLL_INTERVAL_MS` (default 10 s) |
| Tab hidden | Tick skipped (Page Visibility API) |
| `state: "pending"` | Reset transient error counter; stay on screen; spinner visible |
| `state: "completed"` | Clear interval; navigate to result screen |
| `state: "failed"` | Clear interval; navigate to result screen |
| 1st or 2nd consecutive 5xx | No error shown; polling continues silently |
| 3rd consecutive 5xx | Clear interval; show error banner + "Retry" button |
| Component unmounts | `clearInterval` called unconditionally |

## Acceptance criteria

### AC-01: Progress screen shows spinner immediately after submit

**GIVEN** a PLATFORM_ADMIN has submitted a valid registration form  
**WHEN** the browser navigates to the progress screen  
**THEN** a spinner (or indeterminate progress indicator) with `role="status"` is visible on screen

### AC-02: Saga completion navigates to result screen

**GIVEN** a PLATFORM_ADMIN is on the progress screen and polling is active  
**WHEN** the backend saga completes (`state: "completed"`)  
**THEN** the browser navigates to `/admin/onboarding/<id>/result` and the result screen is visible (not the spinner)

## Test approach

- Use `loginWithToken` with a PLATFORM_ADMIN token.
- Submit a real registration form (same approach as ONB-UI-02 AC-06) using a per-test UUID slug.
- Assert the progress screen URL pattern (`/progress`) and that `role="status"` element is visible — this is the screen verdict.
- Wait up to 60 s for the URL to change to `/result` (saga completion).
- Take a screenshot on the progress screen and again after navigation to the result screen.
- If Keycloak is unavailable the `getKeycloakToken` call will throw; the test must fail with a descriptive error, not silently skip.

## Edge cases

- The test sets a 60 s timeout to accommodate the real onboarding saga (Keycloak realm creation is slow).
- If the saga fails instead of completing, the browser still navigates to `/result`; the test should pass on navigation regardless of the terminal state (AC-02 does not require success — only that navigation happens).
- The progress screen must not be shown to non-PLATFORM_ADMIN users; covered by the role-guard test in ONB-UI-01.

## Files

- **Implementation:** `web/src/pages/admin/onboarding/OnboardingProgressPage.tsx`
- **API module:** `web/src/api/onboarding.ts` (`getOnboardingStatus`)
- **Test file:** `web/tests/e2e/onboarding/onb-ui-03.e2e.spec.ts`
