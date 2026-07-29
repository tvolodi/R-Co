---
id: SVC-04
title: Admin UI and API for service catalog scope management
stage: 13
priority: MUST
status: RELEASED
---

# SVC-04 — Admin UI and API for service catalog scope management `[MUST]`

> The platform SHALL expose API endpoints and an admin UI view that allow a
> platform-admin to register, update scope, and deregister services in the
> catalog. Tenant admins SHALL be able to view the services available to their
> tenant (global + their own tenant-scoped services) but not register or modify
> entries.

**Acceptance Criteria:**
- `POST /api/v1/admin/services` (platform-admin only): registers a new service
  with fields `service_id`, `endpoint_url`, `scope` (`global` | `tenant`),
  `owner_tenant_id` (required if `scope = tenant`), `request_schema`,
  `response_schema`, `auth_method`, `timeout_ms`, `max_retries`. Returns HTTP
  201 with the created entry.
- `PATCH /api/v1/admin/services/:service_id` (platform-admin only): allows
  updating `scope` and `owner_tenant_id` on an existing entry. Returns HTTP 200.
  Changing scope from `global` to `tenant` on a service already referenced by
  multiple tenants' active definitions: returns HTTP 409 listing the conflicting
  tenants.
- `DELETE /api/v1/admin/services/:service_id` (platform-admin only): removes
  the service. Returns HTTP 409 if any `ACTIVE` definition references the
  service (lists the definition IDs).
- `GET /api/v1/services` (any authenticated role, tenant-scoped): returns all
  `scope = global` entries plus `scope = tenant` entries where
  `owner_tenant_id` matches the caller's tenant. Does not return other tenants'
  scoped services.
- `GET /api/v1/admin/services` (platform-admin only): returns all entries
  regardless of scope or tenant.
- The admin UI (`ADM-UI` section) includes a "Services" page showing the
  services available to the current tenant, with columns: service_id, scope,
  endpoint, timeout, retries. Platform-admins see an additional "Owner tenant"
  column and a "Register service" button.

**See:** SVC-01 (service catalog scope model), SVC-03 (activation validation
uses this catalog), ADP-08 (service task catalog reference at runtime),
ADM-UI-01 (admin section pattern)

**Edge cases:**
- `PATCH` changes `owner_tenant_id` from tenant A to tenant B: existing active
  definitions for tenant A that reference this service are not immediately
  invalidated, but a WARNING audit entry is written. Next activation attempt
  for those definitions will fail.
- Registering a service with a `service_id` that already exists: HTTP 409.
- Tenant admin attempts `POST /api/v1/admin/services`: HTTP 403.
