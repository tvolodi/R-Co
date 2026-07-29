> The platform SHALL make a migration run idempotent through `ON CONFLICT (migration_id, tenant_id) DO UPDATE ... WHERE status != 'done'`. Re-running a completed migration is a no-op for tenants already `done`, and opens no transaction against their schemas. A migration file is frozen once any tenant holds a `done` row for its `migration_id`.

**Acceptance Criteria:**
- GIVEN a migration completed for a tenant, WHEN the migration is run again, THEN no DDL executes for that tenant and its `completed_at` is unchanged.
- GIVEN a tenant row in `failed`, WHEN the migration is run again, THEN the tenant is re-attempted and its row is updated.
- GIVEN a tenant row in `done`, WHEN the seeding step of a re-run executes, THEN the conflict clause leaves `status`, `completed_at` and `error_msg` untouched and does not move the row back to `pending`.
- GIVEN a tenant row in `done`, WHEN the fanout loop reaches that tenant, THEN it is skipped without opening a transaction against that tenant schema.
- GIVEN any tenant holds a `done` row for `migration_id`, WHEN the migration file content changes, THEN the change is rejected and a new `migration_id` is required.

**See:** MIG-01, MIG-02, MIG-03, MIG-04, MIG-06
