---
id: ENV-04
title: UI clearly labels test tenants and blocks accidental production actions
stage: 14
priority: MUST
status: DRAFT
type: frontend
---

# ENV-04 — UI clearly labels test tenants and blocks accidental production actions `[MUST]`

> The platform UI SHALL display a persistent, visually distinct indicator on
> every page when the user is operating within a test tenant. Actions that
> would affect the paired production tenant SHALL require an explicit
> confirmation step. Test-tenant pages SHALL NOT render any production data.

**Acceptance Criteria:**
- GIVEN the authenticated user's tenant has `tenant_type = 'test'`, THEN every
  page in the UI renders a persistent banner or badge (e.g. yellow bar at the
  top of the screen) containing the text `"TEST ENVIRONMENT"` and the name of
  the paired production tenant.
- GIVEN the user is on a test tenant and clicks "Promote to Production" (ENV-03
  trigger), THEN a confirmation modal is shown: `"You are about to promote
  '<definition_name>' to production tenant '<production_display_name>'. This
  will create a DRAFT version that requires separate activation. Confirm?"`.
  The action proceeds only after explicit confirmation.
- GIVEN the user is on a production tenant (`tenant_type = 'production'`), THEN
  no test-environment banner is shown and no `TEST ENVIRONMENT` text appears
  anywhere on the page.
- GIVEN the admin tenant switcher (if present), THEN test tenants are shown
  with a `[TEST]` suffix in the tenant name and are visually distinguished from
  production tenants (e.g. different icon or colour).
- GIVEN the user is on a test tenant and navigates to the Instance list, THEN
  only instances belonging to the test tenant are shown; no production instances
  are visible.
- The "Promote to Production" button is only shown on the Process Definition
  detail page when the current tenant is a test tenant and the definition status
  is `ACTIVE`.

**See:** ENV-01 (tenant_type field), ENV-03 (promotion API called by this UI),
SH-01 (shell navigation), SH-03 (role-aware navigation)

**Edge cases:**
- User has access to both the test tenant and the production tenant (separate
  user accounts, separate logins): the banner reflects the current session's
  tenant only.
- Test tenant display name does not contain "test" or "staging": the banner
  still appears because it is driven by `tenant_type`, not the name string.
- Mobile or narrow viewport: the `TEST ENVIRONMENT` banner remains visible
  (fixed position); it is not collapsible.
