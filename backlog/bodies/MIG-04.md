> The platform SHALL provide `POST /api/v1/admin/migrations/{migration_id}/resume`, which applies the migration only to tenants whose control row is `pending` or `failed`, reading that set through `platform_migrations_resume_idx`. Tenants whose row is `done` are never re-applied.

**Acceptance Criteria:**
- GIVEN rows in `done`, `pending` and `failed`, WHEN resume runs, THEN DDL is applied to the `pending` and `failed` tenants only.
- GIVEN every row for the migration is `done`, WHEN resume runs, THEN it executes no DDL and returns zero counts.
- GIVEN resume selects its tenant set, WHEN the query plan is inspected, THEN it reads through `platform_migrations_resume_idx`.
- GIVEN a resume run, WHEN tenants are processed, THEN they are processed in `tenant_id` order, so the failure list is reproducible between a run and its resume.
- Resume applies the MIG-02 rule: each tenant's control row is upserted in the same transaction as that tenant's DDL.

**See:** MIG-01, MIG-02, MIG-03, MIG-05, MIG-06
