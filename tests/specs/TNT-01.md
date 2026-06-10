# Test Spec: TNT-01 — Business tables must live in per-tenant schemas, not public

**Requirement:** TNT-01 — All business data tables SHALL reside exclusively in the
tenant's private PostgreSQL schema (`tenant_<uuid>`). The `public` schema SHALL contain
only platform-level routing and registry tables. No business data row belonging to a
tenant SHALL exist in the `public` schema.  
**Priority:** MUST  
**Test layer:** integration

## Test Cases

### TC-TNT-01-01: All 21 business tables exist in tenant schema after provisioning
**Given:** A fresh tenant UUID is generated (per-test random UUID)  
**When:** `provisionTenantSchema` is called for that tenant  
**Then:** All 21 business tables (`events`, `events_archive`, `process_definitions`,
`instance_projections`, `tasks`, `tokens`, `timers`, `audit_entries`, `audit_log`,
`users`, `groups`, `group_members`, `roles`, `user_roles`, `api_tokens`,
`webhook_subscriptions`, `dead_letter_items`, `event_type_registry`,
`event_retention_policies`, `repository_form_schemas`, `instance_sequence`)
exist in the tenant schema as reported by `pg_tables WHERE schemaname = <tenant_schema>`  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN a tenant is provisioned, WHEN the tenant schema
is inspected, THEN all of the following tables exist inside `tenant_<uuid>`"

### TC-TNT-01-02: None of the 21 business tables exist in public after provisioning
**Given:** A fresh tenant is provisioned via a per-test UUID  
**When:** `public` schema is inspected via `pg_tables WHERE schemaname = 'public'`  
**Then:** None of the 21 business tables (`events`, `events_archive`,
`process_definitions`, `instance_projections`, `tasks`, `tokens`, `timers`,
`audit_entries`, `audit_log`, `users`, `groups`, `group_members`, `roles`,
`user_roles`, `api_tokens`, `webhook_subscriptions`, `dead_letter_items`,
`event_type_registry`, `event_retention_policies`, `repository_form_schemas`,
`instance_sequence`) are found in the `public` schema  
**Layer:** integration  
**Acceptance criterion mapped:** "contain no rows in `public`" / public contains only
permitted tables

### TC-TNT-01-03: Cross-tenant isolation — tenant A events not visible from tenant B schema
**Given:** Two tenants A and B provisioned with fresh per-test UUIDs  
**When:** A connection with `search_path` set to tenant A's schema queries `SELECT * FROM events`  
**Then:** Zero rows from tenant B are returned (the query cannot see `tenant_B.events`);
the query resolves only to `tenant_A.events`  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN two tenants A and B are provisioned, WHEN a
query is issued against `tenant_<A>.events`, THEN no rows from tenant B are returned"

### TC-TNT-01-04: Public schema contains only permitted tables (no business tables)
**Given:** Migrations have been applied against the test database  
**When:** `information_schema.tables WHERE table_schema = 'public'` is queried  
**Then:** Every returned table name is one of the 10 permitted public tables;
none of the 21 business tables appear  
**Layer:** integration  
**Acceptance criterion mapped:** "GIVEN the `public` schema is inspected, THEN only
the following tables are present: `tenant`, `tenant_schemas`, `tenant_hostnames`,
`tenant_realm_binding`, `schema_migrations`, `onboarding_registry`, `service_catalog`,
`repository_artifacts`, `repository_activations`, `alerting_state`"
