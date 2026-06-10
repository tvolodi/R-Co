---
id: TNT-04
title: Public schema contains only routing and registry tables
stage: 12
priority: MUST
status: DRAFT
---

# TNT-04 — Public schema contains only routing and registry tables `[MUST]`

> The `public` schema SHALL be the platform's routing and cluster management
> layer only. It SHALL contain the canonical list of tables below and nothing
> else. Any table not on this list that is found in `public` at startup or
> detected by the schema linter SHALL cause a startup warning logged at ERROR
> level.

**Permitted tables in `public`:**

| Table | Purpose |
|---|---|
| `tenant` | Master tenant registry (id, slug, display_name, status) |
| `tenant_schemas` | Maps tenant_id → schema_name; used by pool for search_path |
| `tenant_hostnames` | Maps hostnames → tenant_id for subdomain routing |
| `tenant_realm_binding` | Maps OIDC realm → tenant_id |
| `schema_migrations` | Tracks applied migrations per schema_name |
| `onboarding_registry` | Idempotency and state tracking for tenant onboarding sagas |
| `service_catalog` | Global and tenant-scoped service registrations (SVC-01) |
| `repository_artifacts` | Content-addressed artifact store (global) |
| `repository_activations` | Per-tenant artifact version activations |
| `alerting_state` | Platform-wide alerting configuration |

**Acceptance Criteria:**
- GIVEN the platform starts, THEN it runs a schema audit: it queries
  `information_schema.tables WHERE table_schema = 'public'` and compares the
  result against the permitted list above.
- GIVEN the audit finds a table not on the permitted list, THEN the platform
  logs an ERROR-level message naming the unexpected table and continues (no
  hard stop, to allow zero-downtime migration windows).
- GIVEN the audit finds all tables on the permitted list and nothing else, THEN
  the platform logs an INFO-level message `"public schema audit: CLEAN"`.
- GIVEN a migration is applied that would create a new table in `public`, THEN
  the CI migration linter (TNT-02) MUST require that the table name is added to
  the permitted list in this requirement's definition before the migration is
  merged.
- The `tenant_id UUID NOT NULL` column and all Row Level Security policies on
  business tables that were added by migrations 027 and 028 (ADP-01/ADP-02)
  are removed as part of the TNT-05 backfill migration once all tenants are
  confirmed migrated.

**See:** TNT-01 (business tables in tenant schemas), TNT-02 (migration linter),
TNT-05 (backfill removes business tables from public), SVC-01 (service_catalog
scope field added here)

**Edge cases:**
- During the migration window (TNT-05 in progress): business tables temporarily
  exist in both `public` (legacy rows) and `tenant_<uuid>` (migrated rows);
  the audit produces a WARNING rather than ERROR during this window, identified
  by a migration-window flag in `onboarding_registry`.
- Functions and sequences in `public`: not checked by the audit; only `BASE
  TABLE` and `VIEW` types are validated.
