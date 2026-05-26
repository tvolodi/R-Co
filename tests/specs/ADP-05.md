# Test Spec: ADP-05 -- Artifact hash reference on instance

**Requirement:** ADP-05 -- Add nullable `definition_artifact_hash` on instance metadata, persist hash for repository-backed starts, preserve `NULL` compatibility for legacy/pre-repository starts, and use artifact-hash-first reconstruction with PD-08 snapshot fallback.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-ADP-05-01: migration adds nullable definition_artifact_hash on instance row
**Given:** Migration `032_adp05_instance_artifact_hash.sql` has been applied to the integration database.
**When:** Column metadata for `instance_projections.definition_artifact_hash` is queried from `information_schema.columns`.
**Then:** `is_nullable = 'YES'` deterministically for schema compatibility.
**Layer:** integration
**Acceptance criterion mapped:** Nullable additive schema support with backward compatibility.
**Implemented by:** `tests/integration/adp05_instance_artifact_hash_test.zig` test `TC-ADP-05-01`.

### TC-ADP-05-02: repository-unaware compatibility start persists NULL artifact hash
**Given:** An ACTIVE definition without a repository artifact hash descriptor.
**When:** An instance is created through `InstanceStore.create`.
**Then:** `instance_projections.definition_artifact_hash` is persisted as `NULL`.
**Layer:** integration
**Acceptance criterion mapped:** Legacy/pre-repository compatibility with valid `NULL` semantics.
**Implemented by:** `tests/integration/adp05_instance_artifact_hash_test.zig` test `TC-ADP-05-02`.

### TC-ADP-05-03: repository-backed start persists non-null artifact hash
**Given:** An ACTIVE definition with a deterministic SHA-256 artifact hash persisted on `process_definitions.definition_artifact_hash`.
**When:** An instance is created through `InstanceStore.create`.
**Then:** The same hash value is persisted to `instance_projections.definition_artifact_hash`.
**Layer:** integration
**Acceptance criterion mapped:** Repository-backed instance creation writes artifact hash on instance row.
**Implemented by:** `tests/integration/adp05_instance_artifact_hash_test.zig` test `TC-ADP-05-03`.

### TC-ADP-05-04: malformed artifact hash is rejected on create
**Given:** An ACTIVE definition with malformed artifact hash text.
**When:** An instance is created through `InstanceStore.create`.
**Then:** Create fails deterministically with `InstanceError.InvalidInput`.
**Layer:** integration
**Acceptance criterion mapped:** Non-null hash input must satisfy repository hash shape constraints.
**Implemented by:** `tests/integration/adp05_instance_artifact_hash_test.zig` test `TC-ADP-05-04`.

### TC-ADP-05-05: reconstruction falls back to snapshot when hash is absent or mismatched
**Given:** A persisted instance snapshot and either `definition_artifact_hash = NULL` or a mismatched hash.
**When:** Replay source is resolved for reconstruction.
**Then:** Replay source is `snapshot_fallback` in both cases.
**Layer:** integration
**Acceptance criterion mapped:** Safe PD-08 fallback for compatibility and integrity-mismatch paths.
**Implemented by:** `tests/integration/adp05_instance_artifact_hash_test.zig` test `TC-ADP-05-05`.

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADP-05: nullable schema compatibility | `TC-ADP-05-01` in `tests/integration/adp05_instance_artifact_hash_test.zig` and migration `migrations/032_adp05_instance_artifact_hash.sql` |
| ADP-05 + EE-01: write-path `NULL` compatibility for legacy/pre-repository starts | `TC-ADP-05-02` in `tests/integration/adp05_instance_artifact_hash_test.zig` |
| ADP-05 + REPO-01 + EE-01: repository-backed hash persistence on start | `TC-ADP-05-03` and malformed-hash guard `TC-ADP-05-04` in `tests/integration/adp05_instance_artifact_hash_test.zig` |
| ADP-05 + PD-08 + IR-02: reconstruction fallback compatibility | `TC-ADP-05-05` in `tests/integration/adp05_instance_artifact_hash_test.zig` and replay-source logic in `src/engine/reconstruction.zig` |

## Coverage Gaps Identified

- **MAJOR**: Missing explicit deterministic test asserting positive artifact-hash-first selection (`ReplayDefinitionSource.artifact_repository`) for canonical hash/snapshot equivalence. Current coverage verifies fallback behavior but does not lock the preferred path required by ADP-05.

## Execution Notes For TEST-RUNNER

- Required env: `BPM_TEST_DB_URL` pointing to PostgreSQL integration database.
- Execute integration suite entrypoint via `zig build test-integration` to run `TC-ADP-05-*`.
- Assertions are deterministic (fixed literal hashes, fixed minimal graph fixtures, and direct row checks by concrete UUIDs).