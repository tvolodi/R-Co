---
id: ENV-01
title: Tenant carries a type field distinguishing production from test
stage: 14
priority: MUST
status: RELEASED
---

# ENV-01 — Tenant carries a type field distinguishing production from test `[MUST]`

> The `tenant` table SHALL gain a `tenant_type` column (`production` or `test`)
> and a `production_tenant_id` foreign key that links a test tenant to its
> paired production tenant. A production tenant has no parent reference. A test
> tenant always references exactly one production tenant. This relationship is
> enforced by a database constraint and by the onboarding API.

**Acceptance Criteria:**
- GIVEN the migration is applied, THEN `public.tenant` has:
  - `tenant_type TEXT NOT NULL DEFAULT 'production' CHECK (tenant_type IN ('production', 'test'))`
  - `production_tenant_id UUID NULL REFERENCES public.tenant(id) ON DELETE RESTRICT`
  - Constraint: `CHECK ((tenant_type = 'production' AND production_tenant_id IS NULL) OR (tenant_type = 'test' AND production_tenant_id IS NOT NULL))`
- GIVEN all existing tenant rows at migration time, THEN they are set to
  `tenant_type = 'production'`, `production_tenant_id = NULL`.
- GIVEN `POST /api/v1/tenants/onboard` is called with `tenant_type = 'test'`
  and a valid `production_tenant_id`, THEN a test tenant is provisioned with
  its own schema, Keycloak realm, admin user, and hostname — identical to a
  production tenant onboarding, with the link recorded.
- GIVEN `POST /api/v1/tenants/onboard` is called with `tenant_type = 'test'`
  and no `production_tenant_id` (or an invalid one), THEN HTTP 422 is returned:
  `"test tenant requires a valid production_tenant_id"`.
- GIVEN `POST /api/v1/tenants/onboard` is called with `tenant_type = 'production'`
  and a non-null `production_tenant_id`, THEN HTTP 422 is returned:
  `"production tenant must not have a production_tenant_id"`.
- GIVEN `GET /api/v1/admin/tenants`, THEN the response includes `tenant_type`
  and `production_tenant_id` for every entry.
- A production tenant with one or more test tenants linked to it MUST NOT be
  deleted while those links exist (`ON DELETE RESTRICT`).

**See:** ENV-02 (isolation level of test tenant), ENV-03 (definition promotion
from test to production), ENV-04 (UI labelling), ENV-05 (test tenant
lifecycle), TNT-01 (test tenant gets its own schema, same as production)

**Edge cases:**
- A test tenant can be linked to only one production tenant; a production tenant
  may have multiple test tenants linked to it (one-to-many).
- `tenant_type` and `production_tenant_id` are immutable after creation:
  `PATCH /api/v1/tenants/:id` MUST NOT allow changing these fields; HTTP 422
  if attempted.
- Slug convention for test tenants: recommended but not enforced by the platform
  (e.g. `swiftroute-test`); operators choose the slug freely.
