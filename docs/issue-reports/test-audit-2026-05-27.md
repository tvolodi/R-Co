# Test Audit Report — 2026-05-27

**Scope:** All implemented and RELEASED requirements across every stage.  
**Standard:** Every requirement test case must be *actually executed* by `zig build test` (unit) or `zig build test-integration` (integration). `return error.SkipZigTest` without a DB-environment guard and without a future-requirement deferral note is a violation. Stubs for OIDC operations deferred to OIDC-20 through OIDC-29 and the ScriptTransport keycloak adapter pattern are explicitly **correct** and excluded from this report.

---

## Legend

| Severity | Meaning |
|---|---|
| CRITICAL | Test case has zero execution coverage — it neither runs in unit nor integration build |
| MAJOR | Test case could run (logic is pure / no DB needed) but is permanently stubbed to skip |
| INFO | Duplicate or architectural concern; does not block coverage |

---

## CRITICAL Defects

### CRIT-01 — `tests/integration/adp02_tenant_scope_test.zig` is never executed

**Requirement:** ADP-02 — Tenant Column on Definition, Instance, and Audit Tables  
**Affected TCs:** TC-ADP-02-01, TC-ADP-02-02, TC-ADP-02-03, TC-ADP-02-04, TC-ADP-02-05  
**File:** `tests/integration/adp02_tenant_scope_test.zig`  
**Evidence:** `tests/integration/main_test.zig` has imports for adp03 through adp12 but **no import for `adp02_tenant_scope_test.zig`**. Confirmed by searching main_test.zig for `adp02` — zero matches. The file is real and fully implemented with proper DB-guard skip pattern.  
**Impact:** ADP-02 (MUST, RELEASED) has no integration test coverage at all despite the test file existing.  
**Required action:** Add `const adp02_tenant_scope_integration = @import("adp02_tenant_scope_test.zig");` to `tests/integration/main_test.zig` imports and `_ = adp02_tenant_scope_integration;` to the comptime block.

---

### CRIT-02 — TaskStore direct DB tests have no integration counterpart

**Requirement:** EE-03 — Task activation  
**Affected TCs:** TC-EE-03-07, TC-EE-03-08, TC-EE-03-STC-01, TC-EE-03-STC-02, TC-EE-03-STC-03, TC-EE-03-STC-04 (and adjacent list tests in the same file)  
**File:** `tests/unit/test_tasks_store.zig`  
**Evidence:** All 10 tests in this file unconditionally `return error.SkipZigTest` with no DB-guard. Searching `tests/integration/` for `TC-EE-03-07`, `TC-EE-03-STC-01` etc. returns zero matches. No file named `*task*store*test*` or `*tasks*integration*` exists in `tests/integration/`.  
**Impact:** `TaskStore.createInTx` and `TaskStore.list` DB logic is completely untested. These are the direct data-access paths for EE-03 and EE-04 task operations.  
**Required action:** Create `tests/integration/tasks_store_test.zig` implementing TC-EE-03-07, TC-EE-03-08, and TC-EE-03-STC-01 through STC-04 against a real PostgreSQL database (DB-guard skip pattern). Wire the file into `tests/integration/main_test.zig`.

---

### CRIT-03 — Tasks API DB-path tests have no integration counterpart

**Requirement:** EE-03 (GET /tasks), EE-04 (POST /tasks/:id/complete)  
**Affected TCs:**  
- TC-EE-03-API-05 (PENDING status accepted)  
- TC-EE-03-API-06 (COMPLETED status accepted)  
- TC-EE-03-API-07 (CANCELLED status accepted)  
- TC-EE-03-API-08 (empty query returns no parameter errors)  
- TC-EE-03-06 (GET /tasks empty list when no tasks exist)  
- TC-EE-03-API-09 (filters by instance_id)  
- TC-EE-03-API-10 (filters by status)  
- TC-EE-03-API-11 (pagination via limit and offset)  
- TC-EE-04-07 (complete task: DB-path, task not found → 404)  
- TC-EE-04-08 (complete task: DB-path, already completed → 409)  
- Several additional skipped DB paths in `test_tasks_api.zig` lines 122, 133, 139, 145, 151, 360, 369, 378  

**File:** `tests/unit/test_tasks_api.zig` — all DB-touching test bodies are `return error.SkipZigTest` unconditionally  
**Evidence:** No integration test file for Tasks API endpoint exists in `tests/integration/`. `main_test.zig` has no import for a tasks API integration test. The comment "Implemented in the integration test suite" in `test_tasks_api.zig` is incorrect — no such suite was created.  
**Impact:** The actual DB round-trip paths for `handleList` and `handleComplete` are completely untested. Status filtering, pagination, 404/409 completion errors are untested.  
**Required action:** Create `tests/integration/tasks_api_integration_test.zig` implementing the DB-touching test cases listed above. Wire the file into `tests/integration/main_test.zig`.

---

## MAJOR Defects

### MAJOR-01 — Pure config-validation tests permanently stubbed in `tests/unit/db_test.zig`

**Requirement:** DB-02 — Connection pooling  
**Affected TCs:** TC-DB-02-01 (pool_size below lower bound returns error), TC-DB-02-02 (pool_size above upper bound returns error)  
**File:** `tests/unit/db_test.zig`  
**Evidence:** Both tests unconditionally `return error.SkipZigTest`. These tests validate that `PoolConfig{ .pool_size = 0 }` and `PoolConfig{ .pool_size = 1025 }` return `error.InvalidPoolSize` from `Pool.init`. This logic lives in `src/db/pool.zig` and is a pure config check — no database connection is attempted before the guard fires.  
**Impact:** The error-path guards for invalid pool configuration have never been verified to actually reject bad config. If the guard were accidentally removed, no test would catch it.  
**Note:** `tests/integration/db_integration_test.zig` TC-DB-02-04 tests *boundary* values but not these specific invalid-range cases.  
**Required action:** Implement TC-DB-02-01 and TC-DB-02-02 directly in `tests/unit/db_test.zig` (or a dedicated unit file) without `SkipZigTest`. Use `std.testing.allocator`, construct an invalid `PoolConfig`, call `Pool.init`, and `try std.testing.expectError(error.InvalidPoolSize, ...)`.

---

### MAJOR-02 — Pure input-validation event-store tests permanently stubbed

**Requirement:** ES-01, ES-03  
**Affected TCs:**  
- TC-ES-01-05 (nil actor_id is rejected before DB touch)  
- TC-ES-01-06 (JSON array payload is rejected before DB touch)  
- TC-ES-03-02 (empty idempotency_key is rejected before DB touch)  
- TC-ES-03-03 (idempotency_key > 255 bytes is rejected before DB touch)  

**File:** `tests/unit/event_store_test.zig`  
**Evidence:** All tests in this file unconditionally `return error.SkipZigTest`. The four cases listed above are input-validation guards in the `EventStore.append` function (or its parameter structs) that fire before any SQL is executed.  
**Impact:** Input-boundary enforcement for the event store has never been verified by any test. These cases are also absent from `tests/integration/event_store_integration_test.zig` (integration tests pass valid inputs only).  
**Required action:** Implement these four test cases in `tests/unit/event_store_test.zig` without any `SkipZigTest`. They require only `std.testing.allocator` and a valid `EventStore` constructed with a dummy/no-op pool or via the same pattern as other unit tests in the codebase.

---

### MAJOR-03 — History endpoint valid-boundary tests permanently stubbed without integration counterpart

**Requirement:** API-05 — History endpoint  
**Affected TCs:**  
- TC-API-05-12c (page_size at lower bound 1 is accepted)  
- TC-API-05-12d (page_size at upper bound 200 is accepted)  
- TC-API-05-14a through TC-API-05-14e (valid ISO 8601 timestamp parsing accepted)  

**File:** `tests/unit/test_api05_history.zig` — skipped at lines ~267, 271, 275, 279, 283 and ~507, 637  
**Evidence:** These tests skip because they need a real store to return a successful page (no "invalid input" rejection means the handler proceeds to the store). There is no integration test file for API-05 history endpoint in `tests/integration/main_test.zig`.  
**Impact:** Valid-input boundary testing of the history endpoint is completely absent. The unit tests correctly cover all invalid-input paths, but the valid-path confirmation is missing.  
**Required action:** Create `tests/integration/api05_history_integration_test.zig` implementing TC-API-05-12c, TC-API-05-12d, and TC-API-05-14a through 14e. These tests need a real store, insert a definition and instance, and call the history handler with valid boundary parameters. Wire into `tests/integration/main_test.zig`.

---

---

## Production Code Stubs (runtime behaviour is wrong regardless of test coverage)

These are not test-layer issues — they are stubs in **production source code** whose behaviour is incorrect now that `pg.zig` is a working library. All three affect behaviour that is observable at runtime.

---

### PROD-01 — `src/main.zig` — Placeholder HTTP server: every API route returns HTTP 501

**Affected requirements:** API-01 through API-12 (all routes), OBS-01..06, ADP-01..12, EXT-01..05, IDN-01..04, SCH-01..07  
**File:** `src/main.zig` — `runPlaceholderApiServer()` / `servePlaceholderRequest()`  

**Evidence:**

```
const placeholder_not_implemented =
    "{\"type\":\"...\",\"title\":\"Not Implemented\",\"status\":501,\
     \"detail\":\"Runtime placeholder server is active; API routes are not wired yet.\"}";
```

`pub fn main()` calls only `runPlaceholderApiServer()`. All real route handlers are imported at the top of the file but never registered with a router or called from main:

```zig
pub const definition_routes = @import("api/routes/definitions.zig");   // imported, never called
pub const instance_routes   = @import("api/routes/instances.zig");     // imported, never called
pub const task_routes       = @import("api/routes/tasks.zig");         // imported, never called
// ... 20+ more
```

The placeholder handles `/health/live` and `/health/ready` with **hardcoded JSON strings**, bypassing the real `health_routes.handleLive` and `health_routes.handleReady` (which emit metrics, evaluate DB readiness, check subsystems).

**Impact:** A deployed binary serves HTTP 501 for every business request. The handler functions themselves are correct and tested; the routing dispatch layer was never built.

**Required action:** Implement a real HTTP router in `src/main.zig` (or a new `src/router.zig`) that dispatches incoming requests to the correct handler function based on method + URL pattern. Wire all routes. Replace the hardcoded health strings with calls to `health_routes.handleLive` and `health_routes.handleReady`.

---

### PROD-02 — `src/definition/store.zig` — `rowToDefinition()` never deserializes the `graph` JSONB column

**Affected requirements:** PD-07 (retrieve definition), API-02 (definition CRUD), PD-04 (activate definition)  
**File:** `src/definition/store.zig` line 1381–1383  

**Evidence:**

```zig
// Stub: graph column not parsed until pg.zig delivers real rows.
// TODO: parse JSONB text into DefinitionGraph when pg.zig is complete.
const graph = fallback.graph;   // ← col.get(row, 5) is IGNORED
```

Column index 5 in every SELECT/RETURNING query is the `graph` JSONB column. Its raw text is available in `row[5]` but is silently discarded and replaced with the caller-supplied `fallback.graph`, which is always `DefinitionGraph{.nodes=&.{}, .edges=&.{}}` for all callers that read from the database (`getById`, `list`, `update`, `activate`, `deprecate`, `archive`, `patch`, `getByNameVersion`, `search`).

**Cascading defect in `handleActivate`:** `src/api/routes/definitions.zig` `handleActivate` calls `getById` to re-validate the stored graph before activating. It receives an empty graph, runs `validateGraph({0 nodes, 0 edges})`, which returns `valid = false` (violations: `MISSING_START_NODE`, `MISSING_END_NODE`), and returns HTTP 422. The comment in the handler explicitly acknowledges this:

```zig
// The graph stored in the Definition struct is the in-memory stub (empty
// nodes/edges) because pg.zig does not yet parse JSONB rows.  When real DB
// rows are delivered, this will validate the actual stored graph.
```

This means `handleActivate` is functionally broken — it ALWAYS rejects definition activation with HTTP 422, regardless of how valid the stored graph is. (The integration tests call `def_store.activate(id)` directly, bypassing the HTTP handler and this validation, which is why they pass.)

**Additional impact:** `GET /definitions/:id` and `GET /definitions` serialize `Definition.graph` as empty `nodes`/`edges` arrays in the JSON response, discarding the actual graph data that was stored.

**Required action:**
1. Implement graph deserialization in `rowToDefinition` — parse `col.get(row, 5)` as a JSON object with `nodes` and `edges` arrays into a heap-allocated `DefinitionGraph`. Use `src/definition/snapshot.zig`'s `rowToSnapshot` / `parseGraphJson` as the reference implementation (it already does this correctly for the snapshot table).
2. Remove the `fallback.graph` path in `rowToDefinition` (or keep it only for the `create()` caller that passes params as fallback — but for DB-read callers pass a nil/error sentinel instead).
3. Update the comment in `handleActivate` to remove the pg.zig-stub disclaimer once the deserialization is in place.

---

### PROD-03 — `src/definition/export_import.zig` — `exported_at` is a hardcoded constant string

**Affected requirement:** PD-09 — definition export/import  
**File:** `src/definition/export_import.zig` line 138–139  

**Evidence:**

```zig
// TODO: real timestamp — generate from std.time.timestamp() as ISO8601
const exported_at = allocator.dupe(u8, "2026-05-21T00:00:00Z") catch ...
```

Every export document produced by `ExportDocument` will claim `exported_at = "2026-05-21T00:00:00Z"` regardless of when the export actually runs.

**Impact:** Export documents have an incorrect, static timestamp. Any client that uses `exported_at` for ordering, caching, or audit purposes receives false data.

**Required action:** Replace the hardcoded string with `std.time.timestamp()` rendered as an ISO 8601 UTC string. A correct implementation:

```zig
const ts_secs = std.time.timestamp();
const exported_at = try std.fmt.allocPrint(
    allocator,
    "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
    ... // derive year/month/day/hour/min/sec from ts_secs
);
```

Alternatively use `std.time.epoch.EpochSeconds` to break down the timestamp components.

---

### PROD-04 — `src/db/pool.zig` — module-level comment is a false outdated stub declaration (informational)

**File:** `src/db/pool.zig` lines 3–5  

The module doc-comment reads:

```
//! Wraps the pg vendor module (vendor/pg/pg.zig).  The pg module is currently a
//! stub; all connections are held as placeholder state and actual SQL execution
//! returns QueryFailed until pg.zig is fully implemented.
```

This is **factually incorrect** — the implementation uses real `pg.Conn` objects and delegates to `self._pg.exec()` / `self._pg.query()`. The integration test suite runs all SQL against a live PostgreSQL database and passes. The comment was written before `pg.zig` was completed and was never updated.

**Required action:** Remove the false stub declaration from the module doc-comment. No logic change required.

---

## INFO Items (no corrective action required)

### INFO-01 — Unit stub files whose integration coverage is complete

The following unit test files contain only `return error.SkipZigTest` stubs for DB-touching test cases. Each has a fully implemented integration test file in `tests/integration/` that covers all named TCs with real PostgreSQL. These stubs serve as traceability placeholders only and do not represent missing coverage.

| Unit stub file | Integration coverage file | TCs covered |
|---|---|---|
| `tests/unit/test_snapshot.zig` | `tests/integration/test_snapshot_integration.zig` | TC-PD-08-01 through TC-PD-08-07 (all 7) |
| `tests/unit/test_export_import.zig` | `tests/integration/test_export_import_integration.zig` | TC-PD-09-01 through TC-PD-09-07 |
| `tests/unit/definition_retrieval_test.zig` | `tests/integration/definition_test.zig` | PD-07 retrieval TCs |

**No action required.**

---

### INFO-02 — OIDC stub adapter (`adapters.stub`) — correct by design

`tests/unit/test_oidc01_provider_stub.zig` and `test_oidc01_provider_boundary.zig` call methods that return `error.NotImplemented` (lookupUser, provisionRealm, provisionUser, grantRoles, provisionClient, upsertFederation, deleteFederation, listAuditEvents). These test that the stub correctly satisfies the OIDC-01 interface contract. The real implementations are explicitly deferred to OIDC-20 through OIDC-29. This pattern is correct and intentional.

**No action required.**

---

### INFO-03 — Keycloak adapter uses ScriptTransport — correct by design

`src/identity/provider/test_oidc02_keycloak_adapter.zig` uses a `ScriptTransport` (scripted request/response pairs injected at init). This replaces real HTTP to Keycloak. No Keycloak container is needed because the adapter logic is tested at the HTTP-serialization boundary. This is a correct test-architecture decision.

**No action required.**

---

### INFO-04 — Identity route tests embedded in `src/api/routes/identity.zig`

TC-IDN-01-01 through TC-IDN-02-05 are implemented as in-source tests in `src/api/routes/identity.zig` with proper `testDbUrl()` guards (skip when `BPM_TEST_DB_URL` absent, run fully when present). These are correct. The IDN-01 through IDN-02 integration test files (`idn01_user_registry_test.zig`, `idn02_group_management_test.zig`) in `main_test.zig` provide additional dedicated coverage.

**No action required.**

---

## Remediation Summary

### Production code stubs (runtime correctness — must be fixed before any deployment)

| ID | Priority | Required action | File(s) to change |
|---|---|---|---|
| PROD-01 | P0 | Implement HTTP router in `main.zig`; dispatch all routes to real handler functions; replace hardcoded health strings with real handler calls | `src/main.zig` (new router, all routes) |
| PROD-02 | P0 | Implement graph JSON deserialization in `rowToDefinition`; fix cascading `handleActivate` HTTP 422 bug | `src/definition/store.zig` (`rowToDefinition`), `src/api/routes/definitions.zig` (comment cleanup) |
| PROD-03 | P1 | Replace hardcoded `"2026-05-21T00:00:00Z"` with real `std.time.timestamp()` ISO 8601 rendering | `src/definition/export_import.zig` line 138-139 |
| PROD-04 | P2 | Remove false stub declaration from `pool.zig` module doc-comment (no logic change) | `src/db/pool.zig` lines 3-5 |

### Test coverage gaps

| ID | Priority | Required action | File(s) to change |
|---|---|---|---|
| CRIT-01 | P0 | Wire `adp02_tenant_scope_test.zig` into `main_test.zig` | `tests/integration/main_test.zig` |
| CRIT-02 | P0 | Create `tasks_store_test.zig` integration tests for TC-EE-03-07, -08, STC-01..STC-04; wire into `main_test.zig` | NEW `tests/integration/tasks_store_test.zig`, `main_test.zig` |
| CRIT-03 | P0 | Create `tasks_api_integration_test.zig` for DB-path tasks API TCs; wire into `main_test.zig` | NEW `tests/integration/tasks_api_integration_test.zig`, `main_test.zig` |
| MAJOR-01 | P1 | Implement TC-DB-02-01 and TC-DB-02-02 as real unit tests (no DB required) | `tests/unit/db_test.zig` |
| MAJOR-02 | P1 | Implement TC-ES-01-05, TC-ES-01-06, TC-ES-03-02, TC-ES-03-03 as real unit tests (no DB required) | `tests/unit/event_store_test.zig` |
| MAJOR-03 | P2 | Create `api05_history_integration_test.zig` for valid-boundary history TCs; wire into `main_test.zig` | NEW `tests/integration/api05_history_integration_test.zig`, `main_test.zig` |
