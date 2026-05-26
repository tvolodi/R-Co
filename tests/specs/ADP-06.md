# Test Spec: ADP-06 -- Pipeline run correlation on audit and events

**Requirement:** ADP-06 -- The audit table gains nullable `pipeline_run_id UUID`, event metadata carries `pipeline_run_id` for pipeline-driven actions, and records produced by pipeline runs are queryable by `pipeline_run_id` while preserving legacy null/absent compatibility.
**Priority:** SHOULD
**Test layer:** integration

## Test Cases

### TC-ADP-06-01: migration adds nullable audit pipeline_run_id and correlation indexes
**Given:** Migration `033_adp06_pipeline_run_correlation.sql` has been applied to the integration database.
**When:** Column metadata and expected index names are queried from `information_schema.columns` and `pg_indexes`.
**Then:** `audit_entries.pipeline_run_id` is nullable (`is_nullable = 'YES'`) and correlation indexes exist for audit/events/events_archive.
**Layer:** integration
**Acceptance criterion mapped:** Additive nullable schema support and queryability infrastructure for pipeline-run correlation.
**Implemented by:** `tests/integration/adp06_pipeline_run_correlation_test.zig` test `TC-ADP-06-01`.

### TC-ADP-06-02: pipeline-driven actions propagate identical run id to event metadata and audit
**Given:** A valid instance, registered event type, and trusted pipeline context with deterministic UUID `11111111-2222-3333-4444-555555555555`.
**When:** An event is appended through `Store.append` under pipeline context.
**Then:** `events.metadata->>'pipeline_run_id'` equals the trusted run id, latest `audit_entries.pipeline_run_id` for the resource equals the same run id, and global event reads filtered by that run id return at least one correlated event.
**Layer:** integration
**Acceptance criterion mapped:** Pipeline-produced audit/event records are queryable by `pipeline_run_id` with cross-surface correlation parity.
**Implemented by:** `tests/integration/adp06_pipeline_run_correlation_test.zig` test `TC-ADP-06-02`.

### TC-ADP-06-03: non-pipeline actions preserve null/absent compatibility and exclude unrelated filtered reads
**Given:** A valid instance and a non-pipeline action (pipeline context explicitly cleared).
**When:** An event is appended and both event-history and audit APIs are queried using an unrelated `pipeline_run_id` filter.
**Then:** Event metadata does not contain `pipeline_run_id`, latest audit row has `pipeline_run_id = NULL`, filtered event history returns zero rows, and filtered audit response excludes the unrelated run id.
**Layer:** integration
**Acceptance criterion mapped:** Backward-compatible null/absent behavior for non-pipeline actions while preserving run-id filter semantics.
**Implemented by:** `tests/integration/adp06_pipeline_run_correlation_test.zig` test `TC-ADP-06-03`.

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADP-06: nullable audit schema compatibility | `TC-ADP-06-01` in `tests/integration/adp06_pipeline_run_correlation_test.zig` and migration `migrations/033_adp06_pipeline_run_correlation.sql` |
| ADP-06 + OBS-03 + ES-08: correlated propagation into audit and event metadata | `TC-ADP-06-02` in `tests/integration/adp06_pipeline_run_correlation_test.zig` |
| ADP-06: cross-surface queryability by pipeline_run_id | `TC-ADP-06-02` (`store.readGlobal` filter) and `TC-ADP-06-03` (`audit_routes.handleList` filter) |
| ADP-06: backward-compatible non-pipeline behavior | `TC-ADP-06-03` in `tests/integration/adp06_pipeline_run_correlation_test.zig` |

## Coverage Gaps Identified

- None for the ADP-06 acceptance scope in this handoff. Existing integration tests cover nullable schema compatibility, correlated propagation, cross-surface filtering, and non-pipeline null/absent behavior with deterministic assertions.

## Execution Notes For TEST-RUNNER

- Required env: `BPM_TEST_DB_URL` pointing to PostgreSQL integration database.
- Execute integration suite entrypoint via `zig build test-integration` to run `TC-ADP-06-*`.
- Assertions are deterministic (fixed UUID fixtures, direct SQL row checks, and explicit route/store filter verification).
