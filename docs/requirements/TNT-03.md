---
id: TNT-03
title: Connection pool sets search_path per tenant on checkout
stage: 12
status: RELEASED
priority: MUST
status: DRAFT
---

# TNT-03 — Connection pool sets search_path per tenant on checkout `[MUST]`

> The connection pool SHALL set `search_path = <tenant_schema>, public` on
> every connection immediately after resolving the tenant context for a request.
> No query issued within that request SHALL access a different tenant's schema.
> The `search_path` MUST be reset to a safe default when the connection is
> returned to the pool.

**Acceptance Criteria:**
- GIVEN a request is resolved to tenant `swiftroute` (schema
  `tenant_abc123def456...`), WHEN a connection is acquired from the pool, THEN
  the pool issues `SET search_path = tenant_abc123def456, public` before
  returning the connection to the caller.
- GIVEN any SQL query issued on that connection that references an unqualified
  table name (e.g. `SELECT * FROM events`), THEN PostgreSQL resolves it to
  `tenant_abc123def456.events`, not `public.events`.
- GIVEN a connection is returned to the pool after a request completes, THEN
  the pool resets `search_path = public` on that connection before it can be
  reused for another request.
- GIVEN a request with no resolved tenant (bootstrap token, platform-admin
  system call), WHEN a connection is acquired, THEN `search_path = public` is
  set and no tenant schema is prepended.
- GIVEN two concurrent requests for different tenants A and B, WHEN both
  acquire connections from the pool simultaneously, THEN each connection has
  its own `search_path` set independently; no connection serves rows from the
  wrong tenant schema.
- The `search_path` setting MUST NOT be set via a session-level `SET` that
  persists across connection reuse; it MUST be re-applied on every checkout.
- Pool connection validation (DB-02 stale connection check) MUST re-apply the
  correct `search_path` after a reconnect.

**See:** TNT-01 (business tables in tenant schemas), TNT-02 (migration runner
uses same search_path pattern), ADP-03 (tenant context resolution from bearer
token), DB-02 (connection pool and stale connection handling)

**Edge cases:**
- Connection checkout within a database transaction: `search_path` is set
  before the transaction begins; it MUST NOT be reset mid-transaction.
- Nested pool acquisitions (e.g. a service that acquires a second connection
  for a sub-query): each acquisition independently sets `search_path` to the
  same tenant schema for the same request context.
- `search_path` reset on return fails (DB error): connection is discarded from
  the pool, not returned, to avoid cross-tenant contamination.
