---
id: ENV-02
title: Test tenant is fully isolated from its paired production tenant
stage: 14
priority: MUST
status: RELEASED
---

# ENV-02 — Test tenant is fully isolated from its paired production tenant `[MUST]`

> A test tenant SHALL have exactly the same isolation level from its paired
> production tenant as from any other unrelated tenant. The `production_tenant_id`
> link is a metadata relationship only; it confers no shared data access, no
> shared schema, no shared Keycloak realm, and no shared service credentials.
> A process running in the test tenant CANNOT read or write data in the
> production tenant by any platform mechanism.

**Acceptance Criteria:**
- GIVEN tenant T (production) and tenant T-test (test, linked to T), WHEN a
  process instance runs in T-test and issues any platform API call, THEN the
  call is scoped to T-test's schema and Keycloak realm; no call can resolve
  resources in T's schema.
- GIVEN T-test's connection pool connection, THEN `search_path` is set to
  `tenant_<T-test-uuid>, public` (TNT-03); `tenant_<T-uuid>` is not in the
  path and cannot be accessed by unqualified table references.
- GIVEN T-test's Keycloak realm, THEN it is a separate realm from T's realm;
  tokens issued by T-test's realm are rejected by T's API endpoints and vice
  versa.
- GIVEN a service with `scope = 'tenant'` and `owner_tenant_id = T` (the
  production tenant), WHEN T-test attempts to activate a definition referencing
  that service, THEN activation is rejected (SVC-03); the test tenant does NOT
  automatically inherit production tenant's scoped services.
- GIVEN T-test's schema is on the same PostgreSQL server as T, WHEN a query
  runs in T-test's connection, THEN it cannot access `tenant_<T-uuid>.*` via
  an unqualified name (different search_path) and cannot access it via a
  qualified name unless the DB user has been explicitly granted cross-schema
  access (which MUST NOT be done by the platform).
- The `production_tenant_id` column is used only by ENV-03 (promotion) and
  ENV-04 (UI labelling); no other platform subsystem grants special access
  based on this relationship.

**See:** ENV-01 (tenant_type and link model), ENV-03 (controlled promotion
path), TNT-01 (schema isolation), TNT-03 (search_path per tenant), SVC-03
(service availability check applies equally to test tenants)

**Edge cases:**
- Operator manually grants PostgreSQL cross-schema privileges: this is outside
  the platform's control; the platform provides no mechanism for it and does
  not test for it. Documentation MUST warn against this.
- Test tenant's service_catalog entries: a test tenant may register its own
  tenant-scoped services (e.g. pointing to a mock or staging endpoint) without
  affecting the production tenant's catalog.
