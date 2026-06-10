---
id: ENV-03
title: Process definition promotion from test tenant to production tenant
stage: 14
priority: MUST
status: DRAFT
---

# ENV-03 — Process definition promotion from test tenant to production tenant `[MUST]`

> The platform SHALL provide an API endpoint that promotes an `ACTIVE` process
> definition from a test tenant to its paired production tenant. The promoted
> definition is created as a new `DRAFT` version on the production tenant.
> Publishing it to `ACTIVE` on production is a separate, explicit admin action.
> Promotion is append-only: it never overwrites or deletes existing production
> definitions.

**Acceptance Criteria:**
- `POST /api/v1/tenants/:test_tenant_id/promote/:definition_name` (platform-admin
  or tenant-admin with PROCESS_DESIGNER role on both tenants):
  - Verifies `:test_tenant_id` has `tenant_type = 'test'`.
  - Verifies the caller has PROCESS_DESIGNER role on the test tenant AND on
    the linked production tenant.
  - Finds the `ACTIVE` definition with the given `definition_name` in the test
    tenant's schema.
  - Exports the definition graph (reuses `PD-09` export logic).
  - Imports it as a new `DRAFT` version on the production tenant (`PD-09`
    import logic), incrementing the version number if the name already exists.
  - Returns HTTP 201 with the new definition record on the production tenant
    (`definition_id`, `version`, `status = DRAFT`).
- GIVEN the test tenant has no `ACTIVE` definition with the given name, THEN
  HTTP 404: `"no active definition named '<name>' in test tenant"`.
- GIVEN the caller has PROCESS_DESIGNER on the test tenant but not on the
  production tenant, THEN HTTP 403.
- The promoted definition on production is `DRAFT`; it is NOT automatically
  activated. A separate `POST /definitions/:id/publish` call by an authorised
  user is required.
- Promotion is recorded as an audit entry on both the test tenant and the
  production tenant with `action = 'DEFINITION_PROMOTED'`, cross-referencing
  the source `definition_id` and the target `definition_id`.
- Promotion does not transfer service catalog entries, form schemas, or event
  type registrations; those must be independently registered on the production
  tenant before the promoted definition can be activated.

**See:** ENV-01 (test/production link), ENV-02 (isolation — promotion is the
only controlled bridge), PD-09 (export/import mechanism reused), PD-08
(definition activation remains a separate step), SVC-03 (activation on
production validates service availability independently)

**Edge cases:**
- Definition references a service with `scope = 'tenant'` belonging to the
  test tenant: the import succeeds (definition is `DRAFT`); activation on
  production will fail (SVC-03) until a matching service is registered for the
  production tenant. The promotion response includes a WARNING listing
  unresolved service references.
- Production tenant already has an `ACTIVE` definition with the same name:
  promotion imports a new `DRAFT` version with version = current_max + 1; the
  existing `ACTIVE` is not touched.
- Promoting to a production tenant that is in `status = 'INACTIVE'`: HTTP 409,
  `"production tenant is not active"`.
