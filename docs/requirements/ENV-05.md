---
id: ENV-05
title: Test tenant lifecycle management
stage: 14
priority: SHOULD
status: RELEASED
---

# ENV-05 — Test tenant lifecycle management `[SHOULD]`

> A platform-admin SHALL be able to reset a test tenant (wipe all process
> instances, definitions, and user data while preserving the tenant record,
> schema, and Keycloak realm) and to decommission a test tenant (full deletion
> including schema and realm). Neither action SHALL affect the paired production
> tenant.

**Acceptance Criteria:**
- `POST /api/v1/admin/tenants/:test_tenant_id/reset` (platform-admin only):
  - Verifies the tenant has `tenant_type = 'test'`.
  - Truncates all business data tables in `tenant_<uuid>` schema:
    `events`, `events_archive`, `instance_projections`, `tasks`, `tokens`,
    `timers`, `audit_entries`, `audit_log`, `dead_letter_items`,
    `webhook_subscriptions` (subscriptions recreated from scratch),
    `process_definitions`.
  - Does NOT truncate: `users`, `groups`, `roles`, `api_tokens`,
    `event_type_registry`, `repository_form_schemas` (identity and schema
    definitions are preserved).
  - Returns HTTP 200: `{ "reset_at": "<timestamp>", "tables_truncated": [...] }`.
  - The paired production tenant is not touched.
- `DELETE /api/v1/admin/tenants/:test_tenant_id` (platform-admin only):
  - Verifies the tenant has `tenant_type = 'test'`.
  - Drops the `tenant_<uuid>` schema (CASCADE).
  - Deletes the Keycloak realm for the test tenant.
  - Removes rows from `public.tenant`, `public.tenant_schemas`,
    `public.tenant_hostnames`, `public.tenant_realm_binding`.
  - Returns HTTP 204.
  - The paired production tenant is not touched; `ON DELETE RESTRICT` on
    `production_tenant_id` means this DELETE on a test tenant succeeds because
    the test tenant is the child, not the parent.
- GIVEN `POST /api/v1/admin/tenants/:id/reset` is called on a tenant with
  `tenant_type = 'production'`, THEN HTTP 422:
  `"reset is only allowed for test tenants"`.
- GIVEN `DELETE /api/v1/admin/tenants/:id` is called on a tenant with
  `tenant_type = 'production'`, THEN HTTP 422:
  `"production tenants cannot be deleted via this endpoint; use decommission
  procedure"`.
- Reset is atomic: if any truncation fails, the transaction is rolled back and
  the tenant is left in a consistent (though unmodified) state.

**See:** ENV-01 (tenant_type enforcement), ENV-02 (production tenant not
affected), TNT-01 (schema isolation makes reset safe — only target schema is
touched), TNT-06 (full server migration, a distinct operation)

**Edge cases:**
- Reset while process instances are actively running (in-flight tasks): reset
  returns HTTP 409: `"tenant has active instances; stop or cancel them before
  resetting"`.
- Test tenant schema partially corrupted (migration failure): DELETE still
  attempts `DROP SCHEMA CASCADE`; if it fails, error is returned with details
  and the `public.tenant` row is NOT removed.
- Multiple test tenants linked to the same production tenant: each can be reset
  or deleted independently; deleting one does not affect the others.
