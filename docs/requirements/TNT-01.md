---
id: TNT-01
title: Business tables must live in per-tenant schemas, not public
stage: 12
status: RELEASED
priority: MUST
status: RELEASED
---

# TNT-01 — Business tables must live in per-tenant schemas, not public `[MUST]`

> All business data tables — events, process definitions, instances, tasks,
> tokens, timers, audit entries, users, groups, and related tables — SHALL
> reside exclusively in the tenant's private PostgreSQL schema (`tenant_<uuid>`).
> The `public` schema SHALL contain only platform-level routing and registry
> tables. No business data row belonging to a tenant SHALL exist in the `public`
> schema.

**Acceptance Criteria:**
- GIVEN a tenant is provisioned, WHEN the tenant schema is inspected, THEN all
  of the following tables exist inside `tenant_<uuid>` and contain no rows in
  `public`: `events`, `events_archive`, `process_definitions`,
  `instance_projections`, `tasks`, `tokens`, `timers`, `audit_entries`,
  `audit_log`, `users`, `groups`, `group_members`, `roles`, `user_roles`,
  `api_tokens`, `webhook_subscriptions`, `dead_letter_items`,
  `event_type_registry`, `event_retention_policies`, `repository_form_schemas`.
- GIVEN the `public` schema is inspected, THEN only the following tables are
  present: `tenant`, `tenant_schemas`, `tenant_hostnames`,
  `tenant_realm_binding`, `schema_migrations`, `onboarding_registry`,
  `service_catalog`, `repository_artifacts`, `repository_activations`,
  `alerting_state`, and platform-level system functions.
- GIVEN two tenants A and B are provisioned, WHEN a query is issued against
  `tenant_<A>.events`, THEN no rows from tenant B are returned, and the query
  does not touch `tenant_<B>` at any level.
- GIVEN a new migration file is added, WHEN the migration runner executes it
  for a tenant schema, THEN the tables it creates land in the tenant schema
  (not `public`) without any code change to the migration SQL.
- All existing `tenant_id UUID NOT NULL` columns and Row Level Security policies
  on business tables in `public` are removed once all tenants are fully migrated
  to per-schema isolation.

**See:** TNT-02 (migration runner schema-path enforcement), TNT-03 (connection
pool search_path), TNT-04 (public schema registry tables definition), TNT-05
(backfill migration for existing tenants), DB-01 (PostgreSQL foundation),
DB-03 (transactional integrity)

**Edge cases:**
- Default tenant (`00000000-0000-0000-0000-000000000000`): uses schema
  `tenant_default`; same rules apply — no business data in `public`.
- A migration that explicitly qualifies a table with `public.` prefix: treated
  as a bug; the migration linter (TNT-02) MUST reject it at CI time.
- Cross-tenant admin queries (platform-admin only): performed by explicitly
  setting `search_path` to the target tenant schema for the duration of that
  connection; no permanent bypass exists.
