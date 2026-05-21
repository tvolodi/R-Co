# BPM Platform — Backend Developer Guide

**Version:** 0.1 · 2026-05-20  
**Agent ID:** `BACKEND-DEV`  
**Audience:** Backend Developer agent, Code Designer agent

---

## 1. Environment Setup

### Required tools
- Zig (latest stable — verify with `zig version`)
- PostgreSQL 15+ client tools (`psql`, `pg_isready`)
- Docker (for test database)

### Environment variables

| Variable | Required | Example |
|---|---|---|
| `BPM_DB_URL` | Yes (integration tests) | `postgres://bpm:bpm@localhost:5432/bpm_dev` |
| `BPM_TEST_DB_URL` | Yes (test runs) | `postgres://bpm:bpm@localhost:5432/bpm_test` |
| `BPM_PORT` | No (default 8080) | `8080` |
| `BPM_LOG_LEVEL` | No (default INFO) | `DEBUG` |
| `BPM_ENV` | No (default development) | `development` |
| `BPM_BOOTSTRAP_TOKEN` | Dev only | any string |

### Bootstrap test database
```bash
docker run -d --name bpm-test-db \
  -e POSTGRES_USER=bpm -e POSTGRES_PASSWORD=bpm -e POSTGRES_DB=bpm_test \
  -p 5433:5432 postgres:15-alpine
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test zig build migrate
```

---

## 2. Project Structure

```
src/
├── main.zig                    # Entrypoint: validate config, init pool, start server + scheduler
├── config.zig                  # Read + validate all env vars at startup
├── db/
│   ├── pool.zig                # Connection pool (wraps pg.zig)
│   └── migrations.zig          # Migration runner (reads migrations/ directory)
├── event_store/
│   ├── store.zig               # append, read, read_global, archive
│   └── registry.zig            # event type CRUD + JSON Schema validation
├── definition/
│   ├── registry.zig            # definition CRUD + lifecycle transitions
│   └── validator.zig           # graph validation pipeline (PD-02)
├── engine/
│   ├── transition.zig          # PURE transition function — no I/O allowed
│   ├── state.zig               # InstanceState, DefinitionSnapshot types
│   ├── cel.zig                 # CEL interpreter wrapper
│   └── service_task.zig        # SERVICE_TASK HTTP invocation (Stage 6)
├── tasks/
│   └── manager.zig             # task lifecycle: activate, complete, assign, reassign
├── scheduler/
│   └── scheduler.zig           # background timer polling thread
├── identity/
│   ├── registry.zig            # user/group/role CRUD
│   └── tokens.zig              # token issuance, hashing, validation, cache
├── api/
│   ├── server.zig              # http.zig server init; middleware chain assembly
│   ├── middleware/
│   │   ├── trace.zig           # trace_id injection
│   │   ├── auth.zig            # Bearer token validation
│   │   ├── rbac.zig            # RBAC permission check
│   │   ├── ratelimit.zig       # per-token sliding window
│   │   └── audit.zig           # audit log writer
│   ├── routes/
│   │   ├── definitions.zig
│   │   ├── instances.zig
│   │   ├── tasks.zig
│   │   ├── events.zig
│   │   ├── identity.zig
│   │   ├── dlq.zig
│   │   ├── webhooks.zig
│   │   ├── metrics.zig
│   │   └── health.zig
│   ├── pagination.zig          # cursor encoding/decoding
│   └── errors.zig              # RFC 9457 Problem Details builder
├── obs/
│   ├── logger.zig              # structured JSON logger
│   ├── metrics.zig             # in-process Prometheus counters/histograms
│   └── audit.zig               # audit log DB writer
├── webhook/
│   └── dispatcher.zig          # outbound webhook delivery worker
├── dlq/
│   └── store.zig               # dead letter queue operations
└── design/                     # CODE-DESIGNER artefacts (interfaces before implementation)
    └── *.md                    # One design file per module

migrations/
├── 001_event_store.sql
├── 002_event_type_registry.sql
├── 003_event_archive.sql
├── 004_definitions.sql
├── 005_instances.sql
├── 006_tasks.sql
├── 007_timers.sql
├── 008_identity.sql
├── 009_audit_log.sql
├── 010_dlq.sql
├── 011_webhook_subscriptions.sql
└── 012_event_retention.sql

tests/
├── unit/                       # Pure function tests (no DB)
│   ├── engine_test.zig
│   ├── validator_test.zig
│   └── cel_test.zig
└── integration/                # Tests against real PostgreSQL
    ├── event_store_test.zig
    ├── definition_test.zig
    ├── instance_lifecycle_test.zig
    └── scheduler_test.zig
```

---

## 3. Coding Conventions

### 3.1 Naming

| Element | Convention | Example |
|---|---|---|
| Types / structs | `PascalCase` | `InstanceState`, `EventRecord` |
| Functions | `camelCase` | `appendEvent`, `validateGraph` |
| Constants | `SCREAMING_SNAKE_CASE` | `MAX_POOL_SIZE` |
| Files | `snake_case.zig` | `event_store.zig` |
| DB tables | `snake_case` | `event_type_registry` |
| SQL column names | `snake_case` | `created_at`, `instance_id` |

### 3.2 Error handling

All functions that can fail return `Error!ReturnType`. Never use `catch unreachable` on paths that can realistically fail.

```zig
// CORRECT — propagate errors with context
pub fn appendEvent(pool: *Pool, args: AppendArgs) !EventRecord {
    const conn = pool.acquire() catch |err| return error.PoolExhausted;
    defer pool.release(conn);
    // ...
}

// WRONG — swallowing errors
pub fn appendEvent(pool: *Pool, args: AppendArgs) EventRecord {
    const conn = pool.acquire() catch return default; // never do this
}
```

Define domain-specific error sets per module:

```zig
pub const EventStoreError = error{
    PoolExhausted,
    DuplicateIdempotencyKey,
    UnknownEventType,
    PayloadSchemaInvalid,
    InstanceNotFound,
};
```

### 3.3 Memory management

- Every function that allocates must accept an `std.mem.Allocator` parameter. Never use a global allocator.
- Use `defer allocator.free(...)` or arena allocators for request-scoped memory.
- The transition function (engine/transition.zig) must not perform heap allocations in the critical path — use caller-provided arenas.

### 3.4 The pure transition function rule

`src/engine/transition.zig` is the **only** file where the following rule is absolute:

> **Zero I/O.** No database calls. No logging calls. No HTTP calls. No `std.time` calls. No randomness. Only pure computation on the inputs provided.

Any I/O need in the transition function is a design error. Restructure the caller instead.

---

## 4. Database Patterns

### 4.1 Atomic write pattern

Every write that spans multiple tables MUST use a single transaction:

```zig
const tx = try pool.beginTransaction(conn);
errdefer tx.rollback() catch {};

try event_store.appendInTx(tx, event_args);
try instance_projection.updateInTx(tx, state);

try tx.commit();
```

### 4.2 Idempotency key pattern

Use PostgreSQL `ON CONFLICT DO NOTHING RETURNING *`. If `RETURNING` yields no rows, fetch the existing record:

```zig
const result = try conn.queryRow(
    "INSERT INTO events (...) VALUES (...) ON CONFLICT (idempotency_key) DO NOTHING RETURNING *",
    args,
);
if (result == null) {
    // Duplicate: fetch the original
    return try conn.queryRow("SELECT * FROM events WHERE idempotency_key = $1", .{args.idempotency_key});
}
return result;
```

### 4.3 Prepared statements

All queries MUST use prepared statements (parameterised via `pg.zig`). No string interpolation of user-supplied values into SQL. This is a hard security requirement.

### 4.4 Migration conventions

- Filename: `NNN_<descriptive_name>.sql` where NNN is zero-padded to 3 digits
- Every migration MUST be idempotent (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`)
- No `DROP` statements in migrations (use a new migration to rename/replace)
- Migrations run in filename order; never rename an existing migration file

---

## 5. HTTP Handler Pattern

```zig
pub fn handleCompleteTask(ctx: *RequestContext) !void {
    // 1. Parse path params
    const task_id = try ctx.pathParam("id");

    // 2. Parse and validate body (validation already done by middleware)
    const body = try ctx.jsonBody(CompleteTaskRequest);

    // 3. Call domain logic (which does its own DB work)
    const result = try task_manager.completeTask(.{
        .task_id = task_id,
        .output_vars = body.output_variables,
        .actor_id = ctx.actor.user_id,
    });

    // 4. Return response
    try ctx.respondJson(200, result);
}
```

Route handler functions must NOT contain:
- Direct SQL queries (delegate to domain modules)
- Business logic (gateway evaluation, variable merging)
- Error type checks — use typed errors and let middleware map them to HTTP status codes

### 5.1 Error → HTTP mapping (in errors.zig)

| Error type | HTTP status |
|---|---|
| `PoolExhausted` | 503 |
| `Unauthorized` | 401 |
| `Forbidden` | 403 |
| `NotFound` | 404 |
| `ValidationFailed` | 422 |
| `DuplicateIdempotencyKey` | 200 (return original) |
| `RateLimitExceeded` | 429 |
| Any other | 500 |

---

## 6. Build Commands Reference

| Command | Purpose |
|---|---|
| `zig build` | Compile all source |
| `zig build test` | Run all unit tests |
| `zig build test-<module>` | Run tests for one module (e.g. `test-engine`) |
| `zig build test-integration` | Run integration tests (requires `BPM_TEST_DB_URL`) |
| `zig build test-coverage` | Run tests with coverage report |
| `zig build migrate` | Apply all pending migrations |
| `zig build bench` | Run NFR benchmark suite |
| `zig build openapi` | Generate `docs/openapi.json` |
| `zig build run` | Start the server |

---

## 7. Code Design Artefact Format

Before implementing a new module, `CODE-DESIGNER` writes a design file to `src/design/<module>.md` with:

```markdown
# Module: <name>

## Public interface
(list of function signatures with types)

## Data types
(key struct/union definitions)

## Key invariants
(properties that MUST always hold)

## External dependencies
(other modules, DB tables, env vars)

## Open questions
(unresolved design decisions for ORCH/human)
```

`BACKEND-DEV` MUST read the design file before writing any code for that module.
