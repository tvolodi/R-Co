# PI-09: Operations Runbook + Fail-Fast Startup Assertion

**Issue:** ISS-0084 / GH-299  
**Classification:** Type E (novel documentation + assertion)  
**Severity:** MINOR (operations/runbook)  
**Design Date:** 2026-08-10

---

## 1. Module Purpose

Provide operators with a complete reference for the application's environmental assumptions, and add a fail-fast startup assertion that detects database misconfiguration immediately after connection initialization. The assertion emits a deterministic FATAL log line whose exact format is pinned by a test, enabling reliable alert routing.

**Scope:**
- Documentation: `docs/runbook/OPERATIONS.md` (new file, new directory)
- Code: `src/operations/startup_assertions.zig` (new module)
- Integration point: `src/main.zig` line ~156 (immediately after `provisionTenantSchema`, before store initialization)

---

## 2. Operations Runbook Structure

**Path:** `docs/runbook/OPERATIONS.md`

### 2.1 Required Sections

The runbook at `docs/runbook/OPERATIONS.md` will document:

**Section 1: Environment Variables** (grouped by category)
- Core Configuration: `BPM_DB_URL`, `BPM_DB_POOL_SIZE`, `BPM_ENV`, `BPM_LOG_LEVEL`
- Identity Provider: `BPM_IDP_BASE_URL`, `BPM_IDP_ADMIN_CREDENTIALS_REF`
- Bootstrap & Testing: `BPM_BOOTSTRAP_TOKEN`, `BPM_TEST_DB_URL`, `BPM_UAT_TOKEN`
- Each variable entry: format, default, source of truth, used by

**Section 2: Database Configuration Assumptions**
- PostgreSQL 14.0 or later (verified at startup)
- `pg_trgm` extension installed
- Standard `public` schema with no unexpected tables
- Connection user privileges: `CREATE SCHEMA`, `CREATE TABLE`, `CREATE EXTENSION`

**Section 3: Startup Sequence** (10 steps)
1. Environment variable parsing → 2. Logger init → 3. Identity provider bootstrap (non-fatal) → 4. Pool init → 5. **Database configuration assertions (FATAL GATE)** → 6. Tenant schema provisioning → 7. Public schema audit (non-fatal) → 8. Store init → 9. Scheduler spawn → 10. HTTP server listen

**Section 4: Alert Routing**
- FATAL line format: `FATAL startup.database <ERROR_CODE> <key>=<value> ...`
- Example: `FATAL startup.database PG_VERSION_MISMATCH current=13.8 required_min=14.0`
- Alerting systems match on prefix `FATAL startup.database`

**Section 5: Common Failure Modes** (table)

| Error Code | Meaning | Remedy |
|---|---|---|
| `PG_VERSION_MISMATCH` | PostgreSQL version < 14.0 | Upgrade PostgreSQL server |
| `PG_EXTENSION_MISSING` | `pg_trgm` not installed | Run `CREATE EXTENSION pg_trgm;` as superuser |
| `PUBLIC_SCHEMA_POLLUTION` | Unexpected tables in `public` schema | Review and drop stale tables |

---

## 3. Public Interface — `src/operations/startup_assertions.zig`

### 3.1 Function Signature

```zig
const std = @import("std");
const db_pool = @import("pool");
const obs_logger = @import("obs/logger.zig");

pub const StartupAssertionError = error{
    PgVersionMismatch,
    PgExtensionMissing,
    PublicSchemaPollution,
    QueryFailed,
};

/// Assert database configuration meets application requirements.
/// Emits a FATAL log line and returns error on any violation.
/// This function MUST be called immediately after Pool.init and before
/// any application logic that depends on database state.
pub fn assertDatabaseConfiguration(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
) StartupAssertionError!void;
```

### 3.2 Error Taxonomy

| Error Variant | Emitted When | FATAL Line Format |
|---|---|---|
| `PgVersionMismatch` | PostgreSQL version < 14.0 | `FATAL startup.database PG_VERSION_MISMATCH current=<ver> required_min=14.0` |
| `PgExtensionMissing` | `pg_trgm` extension not found | `FATAL startup.database PG_EXTENSION_MISSING extension=pg_trgm` |
| `PublicSchemaPollution` | Unexpected tables in `public` schema | `FATAL startup.database PUBLIC_SCHEMA_POLLUTION table_count=<N> expected=0` |
| `QueryFailed` | Introspection query failed (connection issue, permissions) | `FATAL startup.database QUERY_FAILED query=<name> error=<@errorName>` |

### 3.3 Behaviour

1. Acquire a connection from the pool
2. Execute three introspection queries:
   - `SELECT current_setting('server_version_num')::int` → version as integer (140000 = 14.0.0)
   - `SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm'` → 0 or 1 row
   - `SELECT count(*) FROM pg_tables WHERE schemaname = 'public'` → integer count
3. For each assertion:
   - If it fails: emit the FATAL log line (via `obs_logger.log(.FATAL, ...)`) and return the corresponding error variant
   - If it passes: continue
4. If all pass: return void (success)

**No fallback, no retry, no warning-and-continue.** Any failure is terminal.

### 3.4 Log Line Contract (pinned by test)

The exact log line format (for alert matching):

```
FATAL startup.database <ERROR_CODE> <context_key>=<context_value> ...
```

- `FATAL` — severity (uppercase)
- `startup.database` — component (lowercase, dot-separated)
- `<ERROR_CODE>` — one of: `PG_VERSION_MISMATCH`, `PG_EXTENSION_MISSING`, `PUBLIC_SCHEMA_POLLUTION`, `QUERY_FAILED`
- Context key-value pairs — space-separated, `key=value` format

This line is written to stderr by `obs_logger.log`. The test will capture stderr and assert exact string equality.

---

## 4. Data Flow

```
main()
  ↓
config.load()
  ↓
obs_logger.init()
  ↓
identity_provider.init() [non-fatal]
  ↓
db_pool.Pool.init()
  ↓
[NEW] startup_assertions.assertDatabaseConfiguration() ← FATAL GATE
  ↓ (on error)
  ├─→ obs_logger.log(.FATAL, "startup.database", ...)
  └─→ return error → main() catches → os.exit(1)
  ↓ (on success)
db_provisioning.provisionTenantSchema()
  ↓
bootstrap_audit.auditPublicSchema() [non-fatal]
  ↓
(store initialization)
  ↓
api/server.listen()
```

---

## 5. Dependencies

| Module | Purpose |
|---|---|
| `db_pool` (imported as `pool`) | Connection pool, `Pool.acquire()` / `Pool.release()` |
| `obs/logger.zig` | `obs_logger.log(.FATAL, ...)` for deterministic FATAL line |
| `std.mem.Allocator` | Query result allocation |
| No I/O modules | This is a synchronous, pure DB-query function |

**New dependency:** `src/operations/startup_assertions.zig` (new module; create alongside this design)

**Integration point:** `src/main.zig` line ~156, immediately after `provisionTenantSchema` returns.

```zig
// Existing:
db_provisioning.provisionTenantSchema(allocator, &pool, default_tenant_id, build_options.migrations_dir) catch |err| {
    // ... existing error handling ...
};

// NEW: Insert here (before bootstrap_audit)
startup_assertions.assertDatabaseConfiguration(allocator, &pool) catch |err| {
    // FATAL line already emitted by assertDatabaseConfiguration; just exit
    std.process.exit(1);
};

// Existing:
bootstrap_audit.auditPublicSchema(allocator, &pool) catch |audit_err| {
    // ... existing error handling ...
};
```

---

## 6. Test Specification — `tests/specs/ISS-0084.md`

See separate test spec file for full details. Summary:

### 6.1 Test Structure

- **Layer:** Integration test (requires real PostgreSQL)
- **File:** `tests/integration/startup_assertions_test.zig`
- **Test cases:**
  1. `assertDatabaseConfiguration_success` — all checks pass → returns void
  2. `assertDatabaseConfiguration_version_too_old` — mock PG 13.x → returns `PgVersionMismatch`, asserts FATAL line
  3. `assertDatabaseConfiguration_extension_missing` — `pg_trgm` not installed → returns `PgExtensionMissing`, asserts FATAL line
  4. `assertDatabaseConfiguration_public_schema_polluted` — extra table in `public` → returns `PublicSchemaPollution`, asserts FATAL line

### 6.2 FATAL Line Capture Mechanism

**Approach:** Redirect stderr to a buffer during test execution, then assert exact string match.

```zig
// Pseudo-code pattern (to be implemented by TEST-DESIGNER):
test "assertDatabaseConfiguration_version_too_old" {
    var stderr_buffer = std.ArrayList(u8).init(testing.allocator);
    defer stderr_buffer.deinit();
    
    // Redirect stderr to buffer (Zig stdlib provides std.io.getStdErr().writer())
    const old_stderr = std.io.getStdErr();
    defer std.io.getStdErr() = old_stderr;
    std.io.setStdErr(stderr_buffer.writer());
    
    // Arrange: connect to test DB, downgrade version via mock or separate old-version container
    const pool = try setupTestPoolWithOldPostgres();
    
    // Act
    const result = startup_assertions.assertDatabaseConfiguration(testing.allocator, &pool);
    
    // Assert
    try testing.expectError(error.PgVersionMismatch, result);
    const stderr_text = stderr_buffer.items;
    const expected_line = "FATAL startup.database PG_VERSION_MISMATCH current=130008 required_min=140000";
    try testing.expect(std.mem.indexOf(u8, stderr_text, expected_line) != null);
}
```

**Trade-off:** Redirecting stderr in tests is fragile across OS (Windows vs Linux handle semantics differ). Alternative: `obs_logger` could expose a test-only hook to capture log lines in-memory. Design defers this decision to TEST-DESIGNER; both approaches are viable.

---

## 7. State Transitions

None. This is a stateless assertion function called once at startup.

---

## 8. Open Questions

None. All requirements are specified:
- Runbook structure defined (section 2)
- Function signature defined (section 3.1)
- Error taxonomy defined (section 3.2)
- FATAL line format pinned (section 3.4)
- Test capture mechanism proposed (section 6.2)
- Integration point specified (section 5, code snippet)

---

## 9. Acceptance Criteria Mapping

| AC # | Handoff Requirement | Coverage |
|---|---|---|
| AC1 | `src/design/pi-09-operations-runbook.md` exists and covers all 6 AC | This file |
| AC2 | `tests/specs/ISS-0084.md` exists with FATAL-line capture test spec | Section 6 + separate file |
| AC3 | No implementation code bodies (signatures + error taxonomy only) | Sections 3.1, 3.2 — no function bodies provided |
| AC4 | Depends only on existing modules (db_pool, obs_logger) or clearly names new ones | Section 5 — `startup_assertions.zig` explicitly named as new |
| AC5 | Design flow: env-parse → IDP → Pool.init → assertDatabaseConfiguration → provisionTenantSchema → API server | Section 4 (data flow diagram), section 3 (startup sequence) |
| AC6 | `lint_design_artefact.py` exits 0 | To be verified in step 4 |

---

## 10. Security Notes

- `assertDatabaseConfiguration` queries `pg_tables`, `pg_extension`, and `current_setting` — all are standard introspection views with no mutation or privilege escalation risk.
- The FATAL log line does NOT emit connection credentials or sensitive data — only version numbers, extension names, and table counts.
- No secrets in this module.

---

## 11. Performance Notes

- `assertDatabaseConfiguration` runs ONCE at startup, before any concurrent request handling.
- Three simple introspection queries (sub-millisecond on healthy DBs).
- No retry loop, no timeout handling — fast-fail by design.
- Not performance-sensitive; no NFR benchmark attached.

---

**End of Design Artefact**
