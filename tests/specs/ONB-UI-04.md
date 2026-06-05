---
requirement_id: ONB-UI-04
spec_version: "1.0"
test_file: web/tests/e2e/onboarding/onb-ui-04.e2e.spec.ts
stage: F7 — Tenant Onboarding GUI
---

# Spec: ONB-UI-04 — Onboarding Result Screen

## Requirement text

> On `completed`: the platform MUST show the new tenant's `slug` and the Keycloak realm URL (`oidc_authority`) to the PLATFORM_ADMIN. On `failed`: the platform MUST show the failure reason from the saga response and offer a "Try Again" action that returns the user to the pre-filled registration form. The result screen MUST be reachable via `GET /api/v1/onboarding?hostname=<h>` so that a page reload does not lose state.

## State restore priority

1. `location.state.sagaResult` (forward navigation from progress screen) — no API call
2. `GET /api/v1/onboarding?hostname=<h>` (page-reload restore via URL `?hostname=` param)
3. "Could not restore onboarding state" fallback + "Start over" link

## Acceptance criteria

### AC-01: Completed result screen shows slug and oidc_authority

**GIVEN** a PLATFORM_ADMIN has completed the full onboarding wizard (form → progress → result)  
**WHEN** the result screen is shown with `state: "completed"`  
**THEN** the screen displays:
- The tenant `slug` (the value submitted in the form)
- The `oidc_authority` URL from the saga response
- A "Back to Admin" button

### AC-02: Try Again navigates back to form with prefilled values

**GIVEN** the result screen is shown with `state: "failed"` and the failure reason is visible  
**WHEN** the user clicks "Try Again"  
**THEN** the browser navigates to `/admin/onboarding/new` and the form is pre-filled with the values from the previous submission attempt (slug field contains the previously entered slug)

### AC-03: Page-reload restore via ?hostname= query param

**GIVEN** the result screen URL is `/admin/onboarding/<id>/result?hostname=<h>` and the page is reloaded (no router state)  
**WHEN** the page mounts  
**THEN** the platform calls `GET /api/v1/onboarding?hostname=<h>` to restore state, and the completed result (slug + oidc_authority) is shown on screen without requiring the user to resubmit

## Test approach

### For AC-01 and AC-02

- AC-01 requires a real completed saga. Submit a valid form, wait for navigation to `/result`, assert slug and oidc_authority are visible.
- AC-02 requires a failed-state result. If a natural failure is impractical, navigate directly to the result screen by injecting router state via `page.evaluate` to set `window.history.state` with a fake `sagaResult` of `state: "failed"` and valid `formValues`. Then click "Try Again" and verify the form is pre-filled.

### For AC-03 (page-reload restore)

- After a successful saga (or via API lookup if available), navigate the browser to the full result URL including `?hostname=<h>`.
- Reload the page with `page.reload()`.
- Assert that the loading indicator appears briefly and then the completed result (slug + oidc_authority) is shown.

## Edge cases

- If the `hostname` param is absent from the URL on reload, the "Could not restore" fallback must be shown with a "Start over" link.
- "Try Again" from a reloaded result screen (where `formValues` are not in router state) must navigate to a blank form — pre-fill is not available after reload.
- The non-PLATFORM_ADMIN role guard redirects immediately to `/instances` without showing any result data.

## Files

- **Implementation:** `web/src/pages/admin/onboarding/OnboardingResultPage.tsx`
- **API module:** `web/src/api/onboarding.ts` (`getOnboardingByHostname`)
- **Test file:** `web/tests/e2e/onboarding/onb-ui-04.e2e.spec.ts`
