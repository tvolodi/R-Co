---
requirement_id: ONB-UI-01
spec_version: "1.0"
test_file: web/tests/e2e/onboarding/onb-ui-01.e2e.spec.ts
stage: F7 — Tenant Onboarding GUI
---

# Spec: ONB-UI-01 — Register Tenant Entry Point

## Requirement text

> A "Register Tenant" navigation item (or button) MUST be visible in the admin section exclusively to authenticated users holding the `PLATFORM_ADMIN` role. Users who do not hold `PLATFORM_ADMIN` MUST NOT see the entry point — it MUST be hidden from the DOM, not merely disabled.

## Acceptance criteria

### AC-01: PLATFORM_ADMIN sees the nav entry

**GIVEN** a user authenticated with the `PLATFORM_ADMIN` role  
**WHEN** they view the admin navigation sidebar  
**THEN** a "Register Tenant" navigation entry is present in the DOM and is navigable to `/admin/onboarding/new`

### AC-02: Non-PLATFORM_ADMIN user does not see the nav entry

**GIVEN** a user authenticated with the `TASK_WORKER` role (or any role other than `PLATFORM_ADMIN`)  
**WHEN** they view the admin navigation sidebar  
**THEN** no "Register Tenant" entry point is present anywhere in the rendered page DOM (not disabled, not hidden via CSS — absent entirely)

### AC-03: Unauthenticated user cannot reach onboarding

**GIVEN** an unauthenticated user  
**WHEN** they navigate to `/admin/onboarding/new`  
**THEN** they are redirected to the login / Keycloak signin screen before any onboarding content is rendered  
*(Enforced upstream by `ProtectedRoute` which calls `signinRedirect()` for any protected route. Covered by `web/tests/e2e/oidcf-login.e2e.spec.ts` TC-OIDCF-01, which verifies the same code path for all protected routes including `/admin/*`. Adding a duplicate test for this specific URL would be redundant — the mechanism is generic and not path-specific.)*

### AC-04: Non-PLATFORM_ADMIN navigating directly to onboarding URLs is redirected

**GIVEN** a user authenticated with `TASK_WORKER` role  
**WHEN** they navigate directly to `/admin/onboarding/new`, `/admin/onboarding/:id/progress`, or `/admin/onboarding/:id/result`  
**THEN** they are redirected to `/instances` (the per-page role guard fires) and the onboarding content is never rendered

## Test approach

- Use `loginWithToken` to inject a real Keycloak token for each role into sessionStorage before page load.
- Navigate to a page that renders `AppShell` (e.g. `/admin/users`) and inspect the sidebar for "Register Tenant".
- Use `page.locator` / `getByText` with `not.toBeAttached()` assertion for the negative case.
- Take a screenshot after each navigation to record what was visible on screen.

## Edge cases

- The nav entry must be **absent from the DOM**, not merely set to `display: none` or `visibility: hidden`. Use `.count()` or `.isAttached()` to verify DOM presence, not CSS visibility.
- A user who holds both `TASK_WORKER` and `PLATFORM_ADMIN` must see the entry (this test does not cover multi-role tokens but notes the invariant).
- The test must fail clearly if Keycloak is unavailable — do not silently skip.

## Files

- **Implementation:** `web/src/components/layout/AppShell.tsx` (NAV_ITEMS filter)
- **Test file:** `web/tests/e2e/onboarding/onb-ui-01.e2e.spec.ts`
