---
pipeline_id: onboarding-wizard
spec_version: "1.0"
test_file: web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts
---

# Pipeline Spec: Tenant Onboarding Wizard

## Purpose

Verifies the end-to-end tenant registration wizard as experienced by a PLATFORM_ADMIN:
navigating to the entry point, filling and submitting the registration form, observing
the async saga progress screen, and confirming the final result screen shows the correct
tenant details. Exercises the full ONB-UI-01..04 requirement chain in a single
uninterrupted flow.

## Requirements covered

| Step | Screen shows | Requirement |
|---|---|---|
| 01 | "Register Tenant" nav entry visible in sidebar | ONB-UI-01 |
| 02 | Registration form filled; progress screen heading visible after submit | ONB-UI-02 |
| gate | onboarding_id captured from progress URL | ONB-UI-02 |
| 03 | Spinner with `role="status"` visible on progress screen | ONB-UI-03 |
| 04 | Result screen shows slug (and oidc_authority on success) | ONB-UI-04 |

## Chain topology

```
pre-check-services
→ login-as-platform-admin
→ 01: verify-register-tenant-nav-entry    [gate: entry present in DOM]
→ 02: fill-and-submit-form                [produces: onboardingId, slug, hostname]
→ gate: onboarding-id-captured
→ 03: progress-screen-shows-spinner       [asserts: role="status" visible]
→ 04: result-screen-shows-slug            [waits ≤90s for saga completion]
→ cleanup: log tenant reference (no DELETE endpoint in this version)
```

## State flow

| Step | Writes to state | Reads from state |
|---|---|---|
| 02 | `onboardingId` | `slug`, `hostname` |
| 04 | — | `slug`, `onboardingId` |
| cleanup | — | `slug`, `hostname` |

## Fixture data

A unique tenant is created per test run using a `randomUUID().slice(0,8)` suffix:
- Slug: `pl-<uid>`
- Hostname: `pl-tenant-<uid>.example.com`
- Admin email: `admin@pl-<uid>.example.com`
- Admin username: `pl-admin-<uid>`
- Redirect URI: `https://app.example.com/cb`

No pre-seeded data required. The test is self-contained.

## Verdict criteria

| Step | Criterion |
|---|---|
| 01 | `page.getByRole('link', { name: /register tenant/i })` count > 0 |
| 02 | URL matches `/admin/onboarding/<id>/progress`; heading "Onboarding in Progress" visible |
| 03 | `[role="status"]` element is visible on screen |
| 04 | URL matches `/admin/onboarding/<id>/result`; success banner OR failure banner visible |

All verdicts are visual observations, not absence-of-error assertions.

## Cleanup

`pl.onCleanup` is registered unconditionally at pipeline start. The created tenant
lives in the Keycloak test realm. When a `DELETE /api/v1/admin/tenants/:slug` endpoint
is added, the cleanup function must be updated to call it.

## Known gaps

- No DELETE endpoint for tenants in this version. Cleanup logs the slug but cannot
  remove the Keycloak realm. Accumulated test tenants should be periodically purged
  from the test Keycloak instance.
- Step 04 treats saga failure as a warning rather than a hard test failure, because
  provisioning success depends on Keycloak connectivity at test runtime. If the saga
  consistently fails, investigate Keycloak health rather than the UI.
