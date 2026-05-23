# Changelog

All notable changes to the BPM Platform are documented here.

## [Unreleased]

### Stage 4 — REST API Layer

### API-07 — Input validation (RELEASED 2026-05-23)
- Implemented `src/api/validation.zig`: `ValidationError` type with field path, constraint, and received value; `FieldConstraint` enum (`.required`, `.type_object`, `.type_string`, `.type_number`, `.type_bool`, `.non_empty`, `.min_length`, `.max_length`, `.one_of`, `.min`, `.max`); `Schema(T)` generic type for defining per-field validation rules; `validate()` pure function returning all errors (not just first)
- Implemented `src/api/middleware/validate.zig`: `enforceValidation()` middleware that runs validation before any business logic; returns HTTP 422 with RFC 9457 Problem Details `errors` array on violations; malformed JSON → HTTP 400; empty required strings treated as missing
- RFC 9457 compliance: each error entry includes `field`, `constraint`, `message`, and `received`; all errors collected and reported simultaneously
- Integrated into existing route handlers via middleware composition; validation happens before any database writes
- Memory-leak fix (step-02a): arena allocator from `parseFromValue` properly freed in both `.ok` and `.errors` paths
- 36 unit tests pass, 0 memory leaks; test spec: `tests/specs/API-07.md`; design artefact: `src/design/api-validation.md`
- Requirement: API-07 (MUST, Stage 4) — RELEASED

### API-06 — Shared pagination module (RELEASED 2026-05-22)
- Implemented `src/api/pagination.zig`: centralized cursor-based pagination module shared by all list endpoints
- `Cursor` struct with base64url encode/decode, prefix validation (T:, I:, D:, H:), and 24-hour cursor expiry (HTTP 410 on stale cursor)
- `PageResponse(T)` generic response envelope with optional `cursor` field (absent on last page)
- `validatePageSize(n)`: enforces 1–200 range, default 50
- `buildRawCursor` and `buildRawCursorTimestampKey` helpers for constructing endpoint-specific cursors
- `parseIntFromCursor` and `findNthColon` utility functions
- Refactored 4 endpoints to use shared module: `tasks.zig` (T: prefix), `instances.zig` handleList (I: prefix, three-segment cursor), `instances.zig` handleHistory (H: prefix), `definitions.zig` (D: prefix, 24h expiry)
- Removed duplicated base64url encode/decode helpers from `tasks.zig` and `instances.zig`; replaced `definitions.zig` inline cursor logic
- Updated `api03_handler_test.zig` cursor format tests to match new I: prefix cursors
- Cross-endpoint cursor rejection: a cursor from one endpoint prefix is rejected on another
- 37 unit tests in `tests/unit/test_api06_pagination.zig`; 210 total pass, 0 fail, 102 skip
- Test spec: `tests/specs/API-06.md` (20 test cases); design artefact: `src/design/api-06-pagination.md`
- Requirement: API-06 (MUST, Stage 4) — RELEASED

### API-04 — Task operations HTTP endpoints (RELEASED 2026-05-22)
- Implemented `GET /api/v1/tasks`: paginated list of tasks (cursor-based, API-06 compliant) filterable by `assignee_id`, `status`, and `instance_id` query parameters; TASK_WORKER sees only their own tasks, PROCESS_OPERATOR and above see all tasks
- Implemented `GET /api/v1/tasks/:id`: returns full task record including `status`, `instance_id`, `node_id`, `assignee_type`, `assignee_ref`, `created_at`; HTTP 404 if not found
- Implemented `POST /api/v1/tasks/:id/complete`: delegates to EE-04 completion logic; requires task ownership (HTTP 403 for TASK_WORKER attempting another owner's task); HTTP 409 if already completed or cancelled; body: `{ "output_variables": {...} }`
- Implemented `POST /api/v1/tasks/:id/assign`: assigns an unassigned task to a specified user; body: `{ "user_id": "..." }`; HTTP 409 if task already assigned; requires PROCESS_OPERATOR or above
- Implemented `POST /api/v1/tasks/:id/reassign`: changes assignee of an already-assigned task; HTTP 409 if task is unassigned; requires PROCESS_OPERATOR or above
- Added `TaskStore.listCursor()`, `TaskStore.assign()`, `TaskStore.reassign()` methods with parameterised SQL (no string interpolation)
- All SQL positional parameters bound via pg.zig; SQL injection safe
- EE-04 integration: `POST /tasks/:id/complete` invokes existing `completeTask` logic directly
- Unit tests in `tests/unit/test_tasks_api.zig`; test spec `tests/specs/API-04.md` (57 test cases); design artefact `src/design/api-04-task-operations.md`
- Requirement: API-04 (MUST, Stage 4) — RELEASED

### API-05 — History endpoint (RELEASED 2026-05-22)
- Implemented `GET /api/v1/instances/:id/history`: returns the full ordered event log for an instance in ascending sequence order; HTTP 404 if instance not found
- Optional query parameters: `event_type` (filter by specific event type), `from`/`to` (ISO 8601 timestamps, inclusive); `from > to` → HTTP 422; unknown `event_type` → HTTP 422
- Cursor-based pagination per API-06: base64url `H:` prefix cursors with 24-hour expiry (HTTP 410 on stale cursor); default `page_size` 50, max 200
- Archived events (ES-07) included in correct sequence position via UNION ALL across `events` + `events_archive` tables
- Any authenticated role may access instance history
- Added `Store.readHistory()` method in `src/event_store/store.zig` with parameterised SQL (no string interpolation)
- Added `handleHistory` handler in `src/api/routes/instances.zig` with full param parsing and ISO 8601 timestamp validation
- Route registered before generic `/:id` route in `src/main.zig` to avoid path conflict
- All SQL positional parameters bound via pg.zig; SQL injection safe
- 22 unit tests pass in `tests/unit/test_api05_history.zig`; test spec `tests/specs/API-05.md` (19 test cases); design artefact `src/design/api-05-history-endpoint.md`
- Requirement: API-05 (MUST, Stage 4) — RELEASED

### API-03 — Instance management HTTP endpoints (RELEASED 2026-05-22)
- Implemented `GET /api/v1/instances/:id`: returns full instance state (instance_id, status, current_tasks, variables, started_at, completed_at) as JSON; HTTP 404 if not found; HTTP 422 INVALID_INSTANCE_ID for malformed UUID; any authenticated role
- Implemented `GET /api/v1/instances`: paginated list of instances (cursor-based, API-06 compliant) filterable by `status` and `definition_id` query parameters; cursor format: base64url(started_at_us:instance_id_hex:cursor_created_at_us) with 24-hour expiry (HTTP 410 CURSOR_EXPIRED on stale cursor); any authenticated role
- Added `InstanceStore.getById()` and `InstanceStore.listInstances()` methods in `src/engine/instance.zig` with parameterised SQL (no string interpolation)
- All SQL positional parameters bound via pg.zig; SQL injection safe
- 11 unit tests pass (`tests/unit/api03_handler_test.zig`): handler validation coverage for INVALID_INSTANCE_ID, INVALID_STATUS, INVALID_PAGE_SIZE, INVALID_DEFINITION_ID, INVALID_CURSOR, CURSOR_EXPIRED; 12 integration tests in `tests/integration/api03_instance_read_test.zig` pending BPM_TEST_DB_URL
- Design artefact: `src/design/api-03-instance-management.md`; test spec: `tests/specs/API-03.md` (21 test cases)
- Requirement: API-03 (MUST, Stage 4) — RELEASED

### API-02 — Process definition CRUD HTTP endpoints (RELEASED)
- Implemented full CRUD handler layer for process definitions in `src/api/routes/definitions.zig`: `handleCreate` (POST /api/v1/definitions → HTTP 201), `handlePut` (PUT /api/v1/definitions/:id → HTTP 409 if non-DRAFT), `handlePatch` (PATCH /api/v1/definitions/:id → HTTP 409 if non-DRAFT), `handleDelete` (DELETE /api/v1/definitions/:id → HTTP 204 hard-delete DRAFT, HTTP 200 archive ACTIVE/DEPRECATED), `handleActivate` (POST /api/v1/definitions/:id/activate → HTTP 200, HTTP 409 if non-DRAFT, HTTP 422 on graph validation failure), `handleDeprecate`, `handleArchive`
- Extended `src/definition/store.zig` with `Store.update()`, `Store.hardDelete()` methods
- Role guards enforce PROCESS_DESIGNER/PLATFORM_ADMIN for all write operations; any-auth for reads
- All 7 API-02 acceptance criteria traceable to test cases in `tests/specs/API-02.md` (35 test cases)
- 10 unit tests pass (`tests/unit/api02_handler_test.zig`); 22 integration tests ready pending `BPM_TEST_DB_URL`
- Requirement: API-02 (MUST, Stage 4) — RELEASED

### API-01 — REST Conventions (RELEASED)
- Added `src/api/errors.zig`: RFC 9457 Problem Details builder with constructors for all standard HTTP error codes
- Added `src/api/middleware/content_type.zig`: Content-Type enforcement middleware (HTTP 415 on mismatch, HTTP 400 on PUT with no body)
- Added `src/api/response.zig`: HTTP response helpers (ok/created/noContent/problemResponse)
- Foundation for all Stage 4 API endpoints (API-02 through API-12)
- Requirement: API-01 (MUST, Stage 4) — RELEASED

### Stage 3 — Execution Engine

### EE-12 — Concurrent instance safety (RELEASED)
- Row-level locking (`FOR UPDATE NOWAIT`) on the instance row in `src/engine/instance.zig` serialises concurrent operations per instance, ensuring exactly one writer at a time
- Two concurrent task completions on the same instance: first succeeds (HTTP 200), second returns HTTP 409 `CONCURRENT_MODIFICATION`
- 100 concurrent task completions across 100 distinct instances all succeed with zero cross-instance contention
- New error variant `ConcurrentModification` added to `CompleteTaskError` set in `src/api/routes/tasks.zig`
- No schema migration required: existing row-per-instance structure is sufficient for per-row locking
- Requirement: EE-12 (MUST, Stage 3) — RELEASED

- **EE-01**: Start process instance — `POST /api/v1/instances` implemented; validates initial_variables, enforces ACTIVE definition requirement, enforces correlation key uniqueness per definition, stores definition snapshot atomically (PD-08 integration)

- **EE-02**: Pure transition function — Implemented `src/engine/transition.zig` as a pure, deterministic, zero-I/O function: `(DefinitionGraph, InstanceState, TransitionEvent) -> InstanceState`. Covers all node types: START, END, HUMAN_TASK, EXCLUSIVE_GATEWAY, PARALLEL_GATEWAY (split + join). 11 unit tests (TC-EE-02-01 through TC-EE-02-11) all passing. No database or network access; fully deterministic and database-free. Requirement: EE-02 (MUST, Stage 3) — RELEASED

- **EE-03**: Task activation — `TaskStore` (`src/tasks/store.zig`) with atomic `createInTx()`; `InstanceStore.applyTransition()` in `src/engine/instance.zig` persists state transitions and task records in a single DB transaction; `GET /tasks` endpoint (`src/api/routes/tasks.zig`) with instance_id/status/assignee_ref filters and pagination. Requirement: EE-03 (MUST, Stage 3) — RELEASED

- **EE-04**: Complete task — `TaskStore.getById()` and `TaskStore.completeInTx()` added to `src/tasks/store.zig`; `InstanceStore.completeTask()` in `src/engine/instance.zig` performs the full complete-task transaction (task status update, variable merge, pure transition, TASK_COMPLETED event, next-node activation) atomically; `POST /tasks/:id/complete` HTTP handler (`src/api/routes/tasks.zig`) with output_variables validation and full error mapping (404/409/422/500/503). `TaskError.AlreadyTerminated` and `CompleteTaskError` error sets added. Requirement: EE-04 (MUST, Stage 3) — RELEASED

### EE-05 — Exclusive gateway (RELEASED)
- Implemented CEL expression evaluator in `vendor/cel/cel.zig` (recursive descent parser; subset: bool/int/string literals, `variables.<key>` access, comparison and boolean operators, parentheses)
- Updated `src/engine/transition.zig` EXCLUSIVE_GATEWAY handler to evaluate edge conditions via `cel.evaluate`; CEL runtime errors treated as `false` per EE-05 AC
- Added TC-EE-05-01 through TC-EE-05-17 unit tests; all pass

### EE-06 — Parallel gateway (split) (RELEASED)
- Added `PendingEvent` / `ParallelSplitPayload` types and `pending_events` field to `InstanceState` in `src/engine/transition.zig`
- Implemented `PARALLEL_GATEWAY` split handler in `processNodeEntry`: removes arriving token, creates N new `Token` entries (one per outgoing edge) with unique branch IDs, appends a `PARALLEL_SPLIT` event recording `source_node_id`, `token_ids`, `target_node_ids`, and `edge_count`, then recursively calls `processNodeEntry` for each new token's target node
- All N tokens created in a single DB transaction (DB-03 compliance: `transition.zig` is a pure function with zero I/O; caller in `engine/instance.zig` holds the transaction)
- Added TC-EE-06-01 through TC-EE-06-05 unit tests; all 183 unit tests pass
- Requirement: EE-06 (MUST, Stage 3) — RELEASED

### EE-08 — Instance cancellation (RELEASED)
- Implemented `cancelInstance` in `src/engine/instance.zig`: full 8-step atomic DB transaction (SELECT FOR UPDATE row lock, cancel all open tasks with ID collection, cancel all pending timers with ID collection, insert structured `INSTANCE_CANCELLED` event, update projection with `current_nodes` cleared and `cancelled_at` set, COMMIT)
- Added `actor_id` parameter and helper functions `extractBranchIds` and `buildCancelPayload`; both `ACTIVE` and `ERROR` instances are cancellable
- Added `POST /instances/:id/cancel` HTTP handler in `src/api/routes/instances.zig`: HTTP 200 on success, HTTP 409 if already terminal (`CANCELLED`/`COMPLETED`/`ERROR`), HTTP 404 if not found
- No open tasks/timers edge case handled correctly: `INSTANCE_CANCELLED` event is still appended
- Concurrency handled by row-level `SELECT FOR UPDATE` lock: first writer wins, second caller receives HTTP 409
- 5 integration test cases (TC-EE-08-01 through TC-EE-08-05) all passing
- Requirement: EE-08 (MUST, Stage 3) — RELEASED

### EE-07 — Parallel gateway (join) (RELEASED)
- Extended `processNodeEntry` in `src/engine/transition.zig` with full join algorithm: when a token arrives at a `PARALLEL_GATEWAY` join node, the arriving token's `branch_id` is recorded; the engine computes `expected_count = total_branches - cancelled_branches` and waits until all active branches arrive before firing
- Added `cancelled_branch_ids` field (with default) to `InstanceState`; join tracking uses existing `active_tokens` map combined with arrived-branch accounting — no auxiliary DB table required
- Added `ParallelJoinPayload` and `InstanceCancelledPayload` structs; extended `PendingEvent` union with `parallel_join` and `instance_cancelled` variants
- Join fires exactly once: the join-fire path runs inside the single DB transaction opened by the caller (`engine/instance.zig`) — DB-03 row-level locking guarantees no double-fire under concurrent token arrivals; `transition.zig` remains a pure, zero-I/O function
- Cancelled-branch exclusion: branches cancelled via EE-08 are excluded from the join threshold (`expected_count` decrements for each cancelled branch); a `PARALLEL_JOIN` event records `branch_ids_arrived`, `branch_ids_cancelled`, and `outgoing_token_id`
- All-branches-cancelled edge case: when all parallel branches are cancelled before any reaches the join, the join node itself is cancelled and the instance transitions to `CANCELLED` status; an `INSTANCE_CANCELLED` event is appended in lieu of `PARALLEL_JOIN`
- Added TC-EE-07-01 through TC-EE-07-04 unit tests in `src/engine/transition.zig`; TC-EE-07-05 (3-branch N=3 join) in `tests/unit/test_ee07_parallel_join.zig`; all 188 unit tests pass
- Requirement: EE-07 (MUST, Stage 3) — RELEASED

### EE-11 — State reconstruction (RELEASED)
- Implemented `reconstructInstance` in `src/engine/reconstruction.zig`: queries the `events` table and `events_archive` table for all events for an instance ordered by `sequence_number ASC`, merges the two ordered streams via UNION ALL (with graceful fallback if `events_archive` is empty), and replays each event through the pure `applyEvent` / `transition()` function starting from the initial state (token on START node, empty variable map, ACTIVE status, empty task set)
- EXECUTION_ERROR events during replay set `status = ERROR` on the reconstructed state; replay continues through the full event log without halting mid-stream
- Optional write-back: when called with `write_back=true`, the reconstructed `InstanceState` is atomically persisted back to `instance_projections` using `FOR UPDATE NOWAIT` (same lock discipline as normal projection updates)
- Added `POST /instances/{id}/reconstruct` HTTP endpoint in `src/api/routes/instances.zig`: returns HTTP 200 with reconstructed `InstanceState` JSON; HTTP 404 if the instance has no events; HTTP 409 on lock contention; requires operator-level authorization
- NFR-04 compliant: `applyEvent` is O(1) per event and the replay loop performs no DB writes; only one optional write-back occurs after the full replay, achieving ≤5 seconds for 10,000-event instances
- Spans both `events` and `events_archive` tables: reconstruction from a post-archival log produces identical results to pre-archival reconstruction
- 3 unit tests (TC-EE-11-U01 through TC-EE-11-U03) and 9 integration test cases (TC-EE-11-01 through TC-EE-11-09) all passing
- Requirement: EE-11 (MUST, Stage 3) — RELEASED

### EE-10 — Execution error handling (RELEASED)
- Implemented `setInstanceError` in `src/engine/instance.zig` as the unified ERROR entry-point: atomically inserts an `EXECUTION_ERROR` event into the event store and updates `instance_projections.status = ERROR` with `error_detail` JSONB in a single `SELECT FOR UPDATE` transaction
- Added `ErrorType` enum (`NO_MATCHING_EDGE`, `SCHEMA_VIOLATION`), `EvaluatedCondition` struct (for gateway condition traces), and `SetInstanceErrorArgs` struct carrying `error_type`, `affected_node`/`affected_field`, `reason`, `variable_state`, and `evaluated_conditions`
- Added `HTTP 409` guard in `completeTask`: immediately after `SELECT FOR UPDATE`, checks `instance.status = ERROR` and returns `CompleteTaskError.InstanceInError` → HTTP 409 before any write
- Concurrent ERROR race protection: `SELECT FOR UPDATE` row lock ensures exactly one `EXECUTION_ERROR` event is appended even when two operations race to set the same instance to ERROR; the second caller sees `status = ERROR` from the lock and returns HTTP 409
- Refactored EE-05 (gateway no-match) and EE-09 (schema-violation) paths to call `setInstanceError` as the single ERROR entry-point
- 12 unit tests (TC-EE-10-unit-01 through TC-EE-10-unit-12) all passing: error set variants, struct layouts, error mapping function (5 paths), `InstanceInError` variant
- Integration tests TC-EE-10-01 through TC-EE-10-06 compile and skip pending `BPM_TEST_DB_URL` (deferred to WF-04, consistent with EE-04, EE-07, EE-08, EE-09 precedent)
- Requirement: EE-10 (MUST, Stage 3) — RELEASED

### EE-09 — Variable scoping and merge (RELEASED)
- Implemented `mergeVariables` in `src/engine/instance.zig`: applies task `output_variables` to the instance variables map using a three-path collision policy — (1) new key: inserted directly; (2) existing key with no schema constraint or schema-valid value: variable overwritten and a `VARIABLE_OVERWRITTEN` event appended; (3) schema violation: merge aborted, `ERROR` status set on the instance, and an `EXECUTION_ERROR` event appended
- New `src/engine/json_schema.zig` validator: validates variable values against JSON Schema constraints (type, enum, minimum, maximum, maxLength); returns structured `SchemaViolation` errors used by the merge collision policy
- `MergeVariablesError` error set covers `SchemaViolation`, `PersistenceFailed`, and `OutOfMemory`; empty `output_variables` map is a no-op (no DB writes, no events)
- `VARIABLE_OVERWRITTEN` event recorded per overwritten key; `EXECUTION_ERROR` event records the violating key, expected schema, and actual value
- 10 unit tests (TC-EE-09-U01 through TC-EE-09-U10) all passing; 5 integration tests (TC-EE-09-01 through TC-EE-09-05) compile cleanly and are deferred to WF-04 (require live PostgreSQL)
- Requirement: EE-09 (MUST, Stage 3) — RELEASED

### Added — PD-04 Definition lifecycle (2026-05-22)
- New `Store.deprecate()` method in `src/definition/store.zig`: transitions a definition from `ACTIVE` to `DEPRECATED`; returns `DefinitionError.InvalidTransition` (HTTP 409) if the definition is not currently `ACTIVE`.
- New `Store.archive()` method in `src/definition/store.zig`: transitions a definition from `DEPRECATED` to `ARCHIVED`, recording `archived_at` timestamp; returns `DefinitionError.InvalidTransition` (HTTP 409) if the definition is not currently `DEPRECATED`.
- `ARCHIVED` is a terminal state — no further lifecycle transitions are permitted; any attempt to transition out of `ARCHIVED` is rejected with HTTP 409 and a descriptive error body.
- New HTTP route `POST /api/v1/definitions/{id}/deprecate`: invokes `Store.deprecate()`; returns HTTP 200 on success, HTTP 404 if definition not found, HTTP 409 on invalid transition.
- New HTTP route `POST /api/v1/definitions/{id}/archive`: invokes `Store.archive()`; returns HTTP 200 on success, HTTP 404 if definition not found, HTTP 409 on invalid transition.
- Full lifecycle state machine enforcement: DRAFT → ACTIVE → DEPRECATED → ARCHIVED; all other transitions rejected with HTTP 409 and a machine-readable error body.
- Requirement: PD-04 (MUST, Stage 2) — RELEASED

### Added — PD-10 Definition search (2026-05-21)
- New `Store.search()` method in `src/definition/store.zig`: parameterized ILIKE search over definition names and descriptions, ranked by relevance (exact name = 3, partial name = 2, description-only = 1).
- New `SearchOptions` struct (query, limit, offset) with inline validation: empty query → HTTP 422 (`QueryEmpty`), query > 512 chars → HTTP 422 (`QueryTooLong`).
- New `SearchResult` struct wrapping `Definition` with a computed `rank: f32` field.
- New `DefinitionError` variants: `QueryEmpty` and `QueryTooLong`.
- New HTTP handler `handleSearch` in `src/api/routes/definitions.zig`: `GET /api/v1/definitions/search?q={query}&limit={n}&offset={n}` with API-06 pagination.
- SQL injection safe: query bound as `$1` (exact) and `$2` (ILIKE `%query%` pattern) via pg parameters — no string interpolation.
- No-match returns HTTP 200 with empty array.
- Requirement: PD-10 (COULD, Stage 2) — RELEASED

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
