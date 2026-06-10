---
id: TNT-06
title: Tenant schema export and import for server migration
stage: 12
status: RELEASED
priority: MUST
status: DRAFT
---

# TNT-06 — Tenant schema export and import for server migration `[MUST]`

> The platform SHALL provide a procedure (CLI command or admin API endpoint)
> that exports a single tenant's complete schema and data as a PostgreSQL dump,
> imports it into a target PostgreSQL server, updates the routing registry, and
> verifies the tenant is operational on the new server — all within a
> maintenance window of under 10 minutes for tenants up to 10 GB of data.

**Acceptance Criteria:**
- GIVEN a tenant T is on server S1, WHEN the export procedure runs, THEN it
  produces a self-contained dump of `tenant_<T_uuid>` schema (DDL + data) that
  can be restored on any PostgreSQL 15+ server without modification.
- GIVEN the dump is restored on server S2, WHEN the import procedure updates
  `public.tenant_schemas` on S1 to record `db_host = S2`, THEN all subsequent
  requests for tenant T are routed to S2.
- GIVEN the migration completes, WHEN a process instance is started for tenant
  T, THEN it uses S2 and the event is written to `tenant_<T_uuid>.events` on S2.
- GIVEN the migration completes, WHEN the old schema on S1 is dropped (operator
  action, separate step), THEN no data loss occurs because S2 is the authoritative
  source.
- The export procedure MUST pause new writes to the tenant (put the tenant in
  read-only mode via a `tenant.status = 'MIGRATING'` flag) for the final
  sync phase only; reads continue throughout.
- `public.tenant_schemas` MUST gain a `db_host TEXT` column (defaulting to the
  current server's `BPM_DB_URL` host) so the connection pool can route per-tenant
  to different PostgreSQL servers.
- The connection pool (TNT-03) MUST use `db_host` from `tenant_schemas` to
  select which server connection to use for a given tenant.
- The entire procedure (export → restore → routing update → verify) MUST complete
  in under 10 minutes for a tenant schema up to 10 GB.

**See:** TNT-01 (schema-per-tenant foundation), TNT-03 (connection pool
routing), TNT-04 (public schema registry), DB-01 (PostgreSQL foundation),
NFR-03 (availability — migration window minimised)

**Edge cases:**
- Tenant has active in-flight process instances during migration: they complete
  on S1 until read-only mode is engaged; the dump captures final state.
- S2 restore fails mid-way: routing is not updated; tenant remains on S1;
  partial dump on S2 is cleaned up by the procedure.
- `tenant_schemas.db_host` not set (single-server deployment): pool falls back
  to `BPM_DB_URL`; behaviour is identical to current single-server operation.
- Tenant schema size exceeds 10 GB: procedure emits a warning; migration is
  still attempted but the 10-minute SLA no longer applies.
