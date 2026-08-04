# Module: api-health

## Module purpose
The api-health module provides two unauthenticated operational endpoints for infrastructure probes: GET /health/live for process liveness and GET /health/ready for readiness. Liveness is intentionally minimal and independent of database startup state. Readiness verifies that request-serving critical subsystems are operational, including mandatory DB-04 connectivity via Pool.healthCheck(), and returns a structured degraded payload with failing-subsystem detail when not ready. Both endpoints are designed for a strict sub-1-second budget while still participating in API-09 trace assignment and propagation.

## Zig source files
- src/api/routes/health.zig (new): HTTP handlers and response serialization for /health/live and /health/ready.
- src/api/health/readiness.zig (new): readiness orchestration, DB-04 call, subsystem aggregation, error mapping.
- src/api/health/subsystems.zig (new): subsystem checker contract and registry utilities for extensibility.
- src/api/api_mod.zig (change): export health route/readiness modules.
- src/main.zig (change): route registration for unauthenticated health endpoints and dependency wiring.
- src/api/openapi/builder.zig (change): add public health endpoint descriptors with auth_required = false.

## Public types
```zig
pub const HandlerResult = @import("../response.zig").HandlerResult;

pub const HealthStatus = enum {
    ok,
    degraded,
};

pub const LiveResponse = struct {
    status: []const u8, // always "ok"
};

pub const ReadyResponse = struct {
    status: []const u8, // "ok"
    db_latency_ms: u64,
};

pub const ReadyFailureResponse = struct {
    status: []const u8, // "degraded"
    failing_subsystems: []const FailingSubsystem,
};

pub const FailingSubsystem = struct {
    subsystem: []const u8, // e.g. "database"
    code: []const u8, // e.g. "POOL_EXHAUSTED", "QUERY_FAILED"
    detail: []const u8, // stable operator-facing detail
    retryable: bool,
};

pub const ReadyCheckResult = union(enum) {
    ready: struct {
        db_latency_ms: u64,
    },
    not_ready: struct {
        failing_subsystems: []FailingSubsystem,
    },
};

pub const SubsystemCheckResult = union(enum) {
    ok: void,
    failed: FailingSubsystem,
};

pub const SubsystemChecker = struct {
    name: []const u8,
    checkFn: *const fn (allocator: std.mem.Allocator) anyerror!SubsystemCheckResult,
};
```

## Public functions
```zig
// src/api/routes/health.zig
pub fn handleLive(allocator: std.mem.Allocator) HandlerResult;
pub fn handleReady(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    readiness: *readiness_mod.ReadinessService,
) HandlerResult;

// src/api/health/readiness.zig
pub const ReadinessError = error{
    OutOfMemory,
};

pub const ReadinessService = struct {
    pub fn init(
        allocator: std.mem.Allocator,
        pool: *db_pool.Pool,
        checkers: []const SubsystemChecker,
    ) ReadinessService;

    pub fn evaluate(
        self: *ReadinessService,
        allocator: std.mem.Allocator,
    ) ReadinessError!ReadyCheckResult;
};

pub fn mapPoolErrorToFailure(err: db_pool.PoolError) FailingSubsystem;

// src/api/health/subsystems.zig
pub fn defaultCriticalCheckers() []const SubsystemChecker;
pub fn runCheckers(
    allocator: std.mem.Allocator,
    checkers: []const SubsystemChecker,
) ![]FailingSubsystem;
```

## Error types
- db_pool.PoolError.ExhaustedPool -> readiness HTTP 503, failing_subsystems includes:
  - subsystem: "database"
  - code: "POOL_EXHAUSTED"
  - detail: "database pool exhausted"
  - retryable: true
- db_pool.PoolError.ConnectionFailed -> readiness HTTP 503, code "DB_CONNECTION_FAILED", retryable true.
- db_pool.PoolError.QueryFailed -> readiness HTTP 503, code "DB_QUERY_FAILED", retryable true.
- db_pool.PoolError.StaleConnection -> readiness HTTP 503, code "DB_STALE_CONNECTION", retryable true.
- Any readiness assembly/serialization allocation failure -> HTTP 500 with RFC 9457 via api/errors.zig.

## Data flow diagram
```mermaid
flowchart LR
    LB[Load Balancer / Orchestrator Probe] --> TRACE[Trace middleware API-09]
    TRACE --> ROUTER[Router]
    ROUTER -->|GET /health/live| LIVE[handleLive]
    ROUTER -->|GET /health/ready| READY[handleReady]

    LIVE --> LIVE200[200 {"status":"ok"}]

    READY --> RSVC[ReadinessService.evaluate]
    RSVC --> DB04[db_pool.Pool.healthCheck DB-04]
    RSVC --> CHECKS[runCheckers critical subsystems]
    DB04 --> AGG[aggregate result]
    CHECKS --> AGG

    AGG -->|all ok| READY200[200 {"status":"ok","db_latency_ms":N}]
    AGG -->|any failed| READY503[503 {"status":"degraded","failing_subsystems":[...]}]
```

## State transitions
```text
ReadinessState transitions per request:
UNKNOWN -> CHECKING -> READY      (HTTP 200)
UNKNOWN -> CHECKING -> NOT_READY  (HTTP 503)

Transition rule:
- READY only if DB-04 succeeds and every critical checker returns ok.
- NOT_READY if DB-04 fails or any critical checker fails.
```

## Integration notes
- Unauthenticated routing strategy:
  - Keep trace middleware first for all requests.
  - Route /health/live and /health/ready through an unauthenticated branch before auth middleware.
  - Keep existing authenticated routes unchanged.
  - This preserves API-09 behavior for health requests while avoiding API-08 auth enforcement.
- DB-04 call path:
  - handleReady -> ReadinessService.evaluate -> db_pool.Pool.healthCheck.
  - No direct SQL in route handler.
- Response-time strategy (< 1 second):
  - Target budget: 1000 ms hard cap at handler level.
  - DB health probe budget: <= 700 ms.
  - Subsystem checker aggregate budget: <= 200 ms.
  - Serialization/response budget: <= 100 ms.
  - Pool exhaustion remains immediate (DB-02), supporting deterministic fast failure.
- Structured degraded response shape (HTTP 503):
  - JSON body uses status plus failing_subsystems array for machine-readable probe diagnostics.
  - API-09 trace remains available in X-Trace-Id header and logs.
- OpenAPI registration:
  - Add GET /health/live and GET /health/ready with auth_required = false.
  - 200 and 503 responses documented explicitly, including failing_subsystems schema.

## Subsystem readiness contract and extensibility
- Critical-now checks (Stage 4):
  - database: mandatory DB-04 Pool.healthCheck.
  - api_router: static self-check that route table and readiness service are initialized.
- Extensibility:
  - New subsystems are added by appending SubsystemChecker entries (e.g., scheduler, webhook dispatcher, metrics sink) without changing route signatures.
  - Each checker must return stable subsystem and code values for alerting compatibility.

## Testability plan
- Unit tests (src/api/routes/health.zig):
  - handleLive returns 200 and body {"status":"ok"}.
  - handleReady success path with stub readiness service returns 200 and db_latency_ms.
  - handleReady degraded path returns 503 and failing_subsystems array.
- Unit tests (src/api/health/readiness.zig):
  - mapPoolErrorToFailure maps ExhaustedPool to POOL_EXHAUSTED detail.
  - evaluate returns READY when DB-04 and all checkers succeed.
  - evaluate returns NOT_READY with multiple failing subsystems aggregation.
- Integration tests:
  - /health/live remains 200 before DB connectivity is available.
  - /health/ready uses real DB pool and includes db_latency_ms when DB is reachable.
  - /health/ready returns 503 when pool is exhausted.
  - both endpoints return within 1 second under nominal test environment.
  - both endpoints include X-Trace-Id (API-09).

## Acceptance-criteria traceability
- AC: design artefact src/design/api-health.md exists.
  - Covered by this document.
- AC: explicit unauthenticated routing strategy for /health/live and /health/ready.
  - Covered in Integration notes (unauthenticated branch after trace, before auth).
- AC: DB-04 readiness probe integration and degraded 503 response shape.
  - Covered in Public functions, Error types, and Data flow.
- AC: module interfaces, public types, and error mapping.
  - Covered in Public types, Public functions, and Error types.
- AC: <1s response-time strategy and trace propagation expectations.
  - Covered in Integration notes response budget and API-09 trace requirements.
- AC: integration notes for existing API modules.
  - Covered in Integration notes and file-level integration list.

## Open questions
- OQ-API12-1: Should readiness 503 also include top-level message/detail fields compatible with RFC 9457, or is the dedicated degraded payload sufficient for Stage 4 probes?
- OQ-API12-2: Are scheduler/webhook components considered critical for readiness in Stage 4, or should they become critical only when their stages are enabled?
