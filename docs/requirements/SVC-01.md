---
id: SVC-01
title: Service catalog entries carry a scope and owner tenant
stage: 13
priority: MUST
status: DRAFT
---

# SVC-01 — Service catalog entries carry a scope and owner tenant `[MUST]`

> Every entry in the service catalog SHALL carry a `scope` field (`global` or
> `tenant`) and, when `scope = tenant`, an `owner_tenant_id` that identifies
> the single tenant that may reference this service in a process definition.
> A global service may be referenced by any tenant. A tenant-scoped service
> may only be referenced by its owning tenant.

**Acceptance Criteria:**
- GIVEN the `service_catalog` table, THEN it has columns:
  - `scope TEXT NOT NULL DEFAULT 'global' CHECK (scope IN (''global'', ''tenant''))`
  - `owner_tenant_id UUID NULL REFERENCES public.tenant(id) ON DELETE CASCADE`
  - Constraint: `CHECK ((scope = 'global' AND owner_tenant_id IS NULL) OR (scope = 'tenant' AND owner_tenant_id IS NOT NULL))`
- GIVEN a service with `scope = 'global'`, WHEN any tenant's process definition
  references it, THEN the definition activation succeeds.
- GIVEN a service with `scope = 'tenant'` and `owner_tenant_id = T`, WHEN
  tenant T's process definition references it, THEN activation succeeds.
- GIVEN a service with `scope = 'tenant'` and `owner_tenant_id = T`, WHEN a
  different tenant U's process definition references it, THEN definition
  activation is rejected with HTTP 422 and error
  `"service <service_id> is not available to this tenant"`.
- GIVEN a platform-admin registers a new service via
  `POST /api/v1/services` with `scope = 'tenant'` and `owner_tenant_id = T`,
  THEN the service is visible only in tenant T's service listing.
- GIVEN `GET /api/v1/services` is called by tenant T's admin, THEN the response
  includes all `scope = 'global'` entries plus all `scope = 'tenant'` entries
  where `owner_tenant_id = T`; no other tenant's scoped services are returned.
- All existing entries in `service_catalog` at the time of this migration are
  set to `scope = 'global'`, `owner_tenant_id = NULL`.

**See:** SVC-02 (plugin handler tenant scoping), SVC-03 (definition activation
validation updated), ADP-08 (service task catalog reference), TNT-01 (service
catalog stays in public schema as a routing/registry table)

**Edge cases:**
- Service with `scope = 'tenant'` whose `owner_tenant_id` tenant is deleted:
  `ON DELETE CASCADE` removes the service entry automatically.
- Platform-admin calls `GET /api/v1/services` without a tenant context: returns
  all entries (global + all tenant-scoped) for administrative purposes.
- Service `service_id` uniqueness: remains globally unique regardless of scope;
  two tenants cannot register the same `service_id`.
