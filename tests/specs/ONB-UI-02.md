---
requirement_id: ONB-UI-02
spec_version: "1.0"
test_file: web/tests/e2e/onboarding/onb-ui-02.e2e.spec.ts
stage: F7 — Tenant Onboarding GUI
---

# Spec: ONB-UI-02 — Tenant Registration Form

## Requirement text

> A PLATFORM_ADMIN MUST be able to submit a tenant registration form that collects: `slug`, `display_name`, `admin_email`, `admin_username`, `admin_display_name`, `hostname`, `redirect_uris` (at least one), and optional `realm_config` / `client_config` fields. The form MUST validate inputs client-side before issuing any network call. On successful submission the user is advanced to the progress screen.

## Validation rules (client-side, no network call made)

| Field | Rule | Error message |
|---|---|---|
| `slug` | Required | "Slug is required" |
| `slug` | 3–63 characters | "Slug must be 3–63 characters" |
| `slug` | Lowercase alphanumeric + hyphens only | "Slug may only contain lowercase letters, digits, and hyphens" |
| `display_name` | Required | "Display name is required" |
| `admin_email` | Required | "Admin email is required" |
| `admin_email` | Contains `@` and domain part | "Enter a valid email address" |
| `admin_username` | Required | "Admin username is required" |
| `admin_display_name` | Required | "Admin display name is required" |
| `hostname` | Required | "Hostname is required" |
| `hostname` | No `http://` / `https://` prefix, no `/` | "Enter a hostname only (no protocol or path)" |
| `redirect_uris` | At least one non-empty entry | "At least one redirect URI is required" |

## Acceptance criteria

### AC-01: Empty form shows all required-field errors

**GIVEN** a PLATFORM_ADMIN on the registration form with all fields empty  
**WHEN** they click "Register Tenant"  
**THEN** the form is not submitted (no network call made) and inline error messages appear beneath every required field

### AC-02: Invalid slug format shows slug validation error

**GIVEN** a form with `slug` set to a value containing uppercase letters or special characters (e.g. `"My Slug!"`)  
**WHEN** the user attempts to submit  
**THEN** the submission is blocked and the message "Slug may only contain lowercase letters, digits, and hyphens" appears under the slug field

### AC-03: Invalid email shows email validation error

**GIVEN** a form with `admin_email` set to `"notanemail"` (no `@`)  
**WHEN** the user attempts to submit  
**THEN** the submission is blocked and "Enter a valid email address" appears under the admin_email field

### AC-04: Hostname with protocol shows hostname validation error

**GIVEN** a form with `hostname` set to `"https://tenant.example.com"`  
**WHEN** the user attempts to submit  
**THEN** the submission is blocked and "Enter a hostname only (no protocol or path)" appears under the hostname field

### AC-05: Empty redirect_uris shows URI validation error

**GIVEN** a form where all redirect URI entries are blank  
**WHEN** the user attempts to submit  
**THEN** the submission is blocked and "At least one redirect URI is required" appears under the redirect_uris field

### AC-06: Valid form submission navigates to progress screen

**GIVEN** a PLATFORM_ADMIN with all fields valid (using a per-test UUID slug to avoid collisions)  
**WHEN** they click "Register Tenant"  
**THEN** the browser navigates to `/admin/onboarding/<onboarding_id>/progress` and the progress screen heading or spinner is visible on screen

## Test approach

- Use `loginWithToken` with a PLATFORM_ADMIN token.
- Navigate to `/admin/onboarding/new` via `navigateSpa`.
- For validation tests: fill only the triggering field, leave others blank or fill with invalid data, click submit, assert error message text is visible.
- For the success test: fill all fields with valid data; use `test-${crypto.randomUUID().slice(0,8)}` as the slug; verify navigation to `/admin/onboarding/<id>/progress` by asserting URL pattern match.
- Take a screenshot after each submit attempt.

## Edge cases

- Submitting twice in succession without page reload must use a distinct `Idempotency-Key` each time. This is verified at the network layer in the implementation; the E2E test verifies the behaviour (both submits reach the progress screen with different IDs).
- The "Register Tenant" button must be disabled during submission (not just once — while the POST is in flight).

## Files

- **Implementation:** `web/src/pages/admin/onboarding/RegisterTenantPage.tsx`
- **API module:** `web/src/api/onboarding.ts` (`submitOnboarding`)
- **Test file:** `web/tests/e2e/onboarding/onb-ui-02.e2e.spec.ts`
