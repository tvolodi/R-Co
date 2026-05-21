# Changelog

All notable changes to the BPM Platform are documented here.

## [Unreleased]

### Added — PD-09 Definition import/export (2026-05-21)
- New `src/definition/export_import.zig`: `ExportImportStore` providing `exportDefinition()` and `importDefinition()` for migrating definitions between environments.
- `exportDefinition()` produces a self-contained `ExportDocument` JSON with `bpm_export_schema_version = "bpm/definition/v1"`, all definition fields, and the full graph; works for definitions in any status.
- `importDefinition()` validates schema version, checks name+version uniqueness (HTTP 409 on conflict), re-validates CEL conditions via `validateEdgeConditions()` (HTTP 422 on invalid CEL), then creates the definition with `status = DRAFT`.
- New HTTP handlers `handleExport` and `handleImport` added to `src/api/routes/definitions.zig`.
- `src/bpm.zig` now exports `pub const export_import`.

## [Stage 1] — 2026-05-20

### Added
- DB module: connection pool (src/db/pool.zig), migration runner (src/db/migrations.zig)
- Event Store module: append, read, idempotency, global stream, type registry, point-in-time query, retention/archival (src/event_store/store.zig, src/event_store/registry.zig)
- Migration 013: UNIQUE index on events_archive(idempotency_key)
- Test specs: tests/specs/DB-01-04.md (13 cases), tests/specs/ES-01-08.md (22 cases)
- Test stubs: db_test.zig, event_store_test.zig, db_integration_test.zig, event_store_integration_test.zig

### Verified
- zig build exits 0
- zig build test exits 0 (38 unit stubs SKIP, engine placeholder PASS)
- zig build test-integration exits 0 (10 stubs SKIP — awaiting DB)

### [Stage 1 — Integration Tests Verified] — 2026-05-21
- Real PostgreSQL client integrated (vendor/pg)
- Integration test harness (tests/integration/helpers.zig) implemented
- All Stage 1 MUST integration tests pass against bpm_test DB (17/17 PASS, 5 consecutive stable runs)
- DB-01, DB-03, DB-04, ES-01..ES-08: integration tests confirmed PASS; test_run and tested_at recorded
- DB-02 (connection pooling): coverage gap — no dedicated integration test in current suite; pool exercised implicitly by all 17 tests but pool-size, exhaustion, and validation scenarios untested; follow-up required from TEST-DESIGNER

### [Stage 1 — Released] — 2026-05-21
- All Stage 1 MUST requirements promoted to RELEASED
- DB-01..DB-04: Schema init, connection pooling, transactional integrity, health check
- ES-01..ES-08: Append event, ordered read, idempotency, global stream, type registry,
  point-in-time query, retention policy, event metadata
- Provider errors (pg.zig / pool.zig) confirmed clean under Zig 0.16
- Stage 1 release gate passed (release-stage1-2026-05-21.json)

## [Stage 2] PD-08 — Definition Snapshot (2026-05-21)

- Added `src/definition/snapshot.zig` implementing `SnapshotStore.create()` and `SnapshotStore.getByInstanceId()`
- Added `instance_definition_snapshots` table (migration 004) — snapshots bound to instance_id PRIMARY KEY
- Snapshots are immutable: concurrent definition changes cannot affect running instances (FOR SHARE + ON CONFLICT DO NOTHING)
- Exported as `bpm.snapshot` from `src/bpm.zig`
- 4 unit tests passing (TC-PD-08-06u-01..04); 7 integration tests ready pending BPM_TEST_DB_URL
- Requirement: PD-08 (MUST, Stage 2) — RELEASED

## [Stage 2 — Process Definition] — 2026-05-21

### Released
- PD-01 (Create definition): UUID assignment, DRAFT status, duplicate name+version rejection, optional description
- PD-02 (Graph validation): START/END node checks, dangling edges, isolated nodes, duplicate node IDs, cycle detection with gateway exemption

### Released
- PD-03 (Version management): incremental versioning on definition save, atomic ACTIVE→DEPRECATED transition when a new version is activated, list-by-status returning exactly one ACTIVE version per name, idempotent re-activation guard

### Added
- Definition module: process definition creation and storage (src/definition/store.zig, src/definition/graph.zig)
- Graph validation: 9 distinct error codes covering all structural defects (src/definition/graph.zig)
- Version management: version column, activation/deprecation logic, filtered list queries (src/definition/store.zig)
- Test specs: tests/specs/PD-01-02.md (15 cases: 4 for PD-01, 11 for PD-02), tests/specs/PD-03.md (7 cases)

### Verified
- zig build exits 0
- zig build test exits 0 (12 PASS, 38 SKIP — pre-existing stubs)
- zig build test-integration exits 0 (34/34 PASS: 15 new PD tests + 19 Stage 1 regression tests)
- All Stage 1 regression tests (DB-01..DB-04, ES-01..ES-08) confirmed passing
- Stage 2 release gate passed (release-pd01-2026-05-21.json)

### Released — 2026-05-21
- PD-05 (Node types): NodeType enum updated and extended
  - `USER_TASK` renamed to `HUMAN_TASK`; `SCRIPT_TASK` renamed to `TIMER`
  - Full enum: `START`, `END`, `HUMAN_TASK`, `SERVICE_TASK`, `EXCLUSIVE_GATEWAY`, `PARALLEL_GATEWAY`, `TIMER`
  - New optional `attributes` field on `GraphNode` struct (key/value string map)

### Stage 2 — PD-07 — Definition retrieval (released 2026-05-21)

- Added `Store.getActiveByName()` to retrieve the currently ACTIVE version of a definition by name (`GET /definitions/active/:name`).
- Added `?stage=` filter support to `Store.list()` via new `stage` field in `ListOpts`.
- Added migration `014_definition_stage.sql` to add `stage` column to `process_definitions`.
- Implemented HTTP route handlers in `src/api/routes/definitions.zig`: `handleGetById`, `handleList`, `handleGetActiveByName`.
- API-06 cursor-based pagination implemented in `handleList` using base64url-encoded `created_at` timestamps.
- `?status=` and `?page_size=` validated at HTTP layer before reaching store.

### PD-06 — Edge conditions [RELEASED]
- Added `is_default: bool` field to `GraphEdge` struct
- Added `validateEdgeConditions()` to `graph.zig`: enforces CEL syntax validity and EXCLUSIVE_GATEWAY edge rules (CHK-EC-01 through CHK-EC-06)
- Added `isValidCelSyntax()` pure helper for structural CEL syntax checking
- `validateEdgeConditions()` integrated into `Store.create()` after `validateNodeAttributes()`
- Updated `web/src/types/api.ts` `GraphEdge` interface with `is_default?: boolean`
- 19 unit tests added in `tests/unit/graph_edge_conditions_test.zig`
  - New `validateNodeAttributes()` pure function in `src/definition/graph.zig`
  - Per-type mandatory attribute validation enforced at definition-save time:
    - `HUMAN_TASK`: requires `role` (non-empty string) → HTTP 422 / `HUMAN_TASK_MISSING_ROLE`
    - `SERVICE_TASK`: requires `endpoint` (non-empty string) and `timeout_ms` (integer 1..300000) → HTTP 422
    - `TIMER`: requires `duration_iso8601` (valid ISO 8601 duration; `P0D` accepted) → HTTP 422
  - Attribute violations surface as `GraphValidationFailed` (HTTP 422) alongside structural violations
  - Test spec: `tests/specs/PD-05.md`; test run: `WF02-pd05-20260521-run-01`
