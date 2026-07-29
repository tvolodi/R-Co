> The platform SHALL upsert a tenant's `platform.platform_migrations` row to `done` inside the same transaction that applies that tenant's DDL steps, so a `done` row proves the DDL committed. A per-tenant failure is recorded as `status = 'failed'` with `error_msg` in a separate transaction opened after the tenant transaction has rolled back.

**Acceptance Criteria:**
- GIVEN a tenant's DDL commits, WHEN the transaction ends, THEN the `done` row committed in that same transaction.
- GIVEN a DDL statement raises, WHEN the transaction ends, THEN it rolls back and neither partial DDL nor a `done` row survives in that schema.
- GIVEN the tenant transaction rolled back, WHEN the failure is recorded, THEN `status = 'failed'` and `error_msg` are written in their own transaction.
- GIVEN the failure-recording transaction itself fails, WHEN the fanout continues, THEN the row remains `pending` and the MIG-04 resume query covers it.
- No code path writes a tenant's control row on a connection other than the one applying that tenant's DDL.

**See:** MIG-01, MIG-03, MIG-04, MIG-05, SPT-01
