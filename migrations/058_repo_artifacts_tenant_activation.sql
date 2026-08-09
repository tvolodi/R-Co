-- 058_repo_artifacts_tenant_activation.sql
--
-- ISS-0641 / GH-637: this file deliberately carries NO public-only scope
-- header (see migrations.zig migrationScope()/SCOPE_PUBLIC_HEADER) — the
-- two tables it creates have DIFFERENT correct classifications, so marking
-- the whole file public-only would be wrong for one of them.
--
-- `repository_artifacts` is HYBRID (confirmed by
-- tests/integration/iss0185_dual_schema_test.zig's
-- TC-ISS-0185-03, which asserts it exists in BOTH public and
-- tenant_default): migrations/045_repository_artifacts.sql's
-- artifact_versions.content_hash FK, and artifact_versions itself is
-- confirmed HYBRID with legitimate tenant-side rows, so tenant_default
-- needs its own repository_artifacts copy too. This file must keep
-- creating it unqualified (all-schemas default) — do not mark this file
-- public-only or public.-qualify this statement.
--
-- `tenant_artifact_activations` is GLOBAL_REGISTRY (canonical home =
-- public): src/config/loader.zig:204-213 queries
-- `FROM tenant_artifact_activations taa ... WHERE taa.tenant_id = $1` — a
-- single global table filtered by tenant_id (same shape as
-- service_catalog), not per-tenant-schema data. Row-count-verified on
-- live db_test: public.tenant_artifact_activations held 8 real rows
-- while tenant_default.tenant_artifact_activations held 0 rows — public
-- is canonical. migrations.zig's migrationScope() has no per-table
-- primitive (only a whole-file public-only-vs-all-schemas choice) and
-- this file cannot use the whole-file option (see above), so this
-- table's statement keeps creating an unwanted tenant-schema shadow; see
-- migrations/GBL-141_iss0641_drop_dual_schema_shadows.sql, which drops it
-- (idempotent, re-run after any cold-start replay). See also
-- docs/issues/ISS-0641.json and docs/issue-reports/ISS-0185-diagnosis.yaml.

CREATE TABLE IF NOT EXISTS repository_artifacts (
artifact_id UUID,
version_id UUID PRIMARY KEY,
artifact_kind VARCHAR(64),
artifact_name VARCHAR(255),
content_hash TEXT,
content_json JSONB,
parent_version_id UUID,
created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS tenant_artifact_activations (
tenant_id UUID NOT NULL,
artifact_kind VARCHAR(64) NOT NULL,
artifact_name VARCHAR(255) NOT NULL,
active_version_id UUID NOT NULL,
activated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
PRIMARY KEY (tenant_id, artifact_kind, artifact_name)
);
