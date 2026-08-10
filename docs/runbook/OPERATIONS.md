# BPM Platform — Operations Runbook

**Version:** 1.0  
**Last Updated:** 2026-08-10  
**Maintainer:** BPM Platform Operations Team

This document provides operators with a complete reference for the application's environmental assumptions, startup sequence, failure modes, and recovery procedures.

---

## 1. Environment Variables

### 1.1 Core Configuration

| Variable | Format | Default | Source of Truth | Used By |
|---|---|---|---|---|
| `BPM_DB_URL` | PostgreSQL connection string | `postgres://bpm:bpm@localhost:5432/bpm` | `.env`, Kubernetes Secret | Database pool initialization |
| `BPM_DB_POOL_SIZE` | Integer (1-100) | `10` | `.env`, runtime config | Connection pool sizing |
| `BPM_ENV` | Enum: `development`, `staging`, `production` | `development` | `.env`, deployment manifest | Environment-specific behaviour |
| `BPM_LOG_LEVEL` | Enum: `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL` | `INFO` | `.env`, runtime config | Logger verbosity |

### 1.2 Identity Provider

| Variable | Format | Default | Source of Truth | Used By |
|---|---|---|---|---|
| `BPM_IDP_BASE_URL` | HTTP(S) URL | `http://localhost:8081` | `.env`, Kubernetes ConfigMap | Keycloak API client |
| `BPM_IDP_ADMIN_CREDENTIALS_REF` | `user:pass` or `$VAR` | `admin:admin` | `.env`, Kubernetes Secret | Keycloak admin client authentication |

### 1.3 Bootstrap & Testing

| Variable | Format | Default | Source of Truth | Used By |
|---|---|---|---|---|
| `BPM_BOOTSTRAP_TOKEN` | UUID v4 | (none — must be set) | `.env`, Secret Manager | First-run system user authentication |
| `BPM_TEST_DB_URL` | PostgreSQL connection string | `postgres://bpm:bpm@localhost:5433/bpm_test` | `.env.test` | Integration test database |
| `BPM_UAT_TOKEN` | JWT bearer token | (none — generated on-demand) | `.env.uat`, test harness | UAT scenario authentication |
| `BPM_TEST_URL` | HTTP URL | `http://127.0.0.1:8080` | `.env.test` | Integration test target |

---

## 2. Database Configuration Assumptions

The application makes the following **hard assumptions** about the PostgreSQL database. Violations are detected at startup via fail-fast assertions (see Section 3.5).

| Assumption | Verification Method | Failure Mode |
|---|---|---|
| PostgreSQL version ≥ 14.0 | Query `current_setting('server_version_num')` | `PG_VERSION_MISMATCH` (FATAL) |
| `pg_trgm` extension installed | Query `pg_extension WHERE extname='pg_trgm'` | `PG_EXTENSION_MISSING` (FATAL) |
| Public schema has no application tables | Query `pg_tables WHERE schemaname='public'` | `PUBLIC_SCHEMA_POLLUTION` (FATAL) |
| Connection user has privileges | `CREATE SCHEMA`, `CREATE TABLE`, `CREATE EXTENSION` | Migration failure (non-fatal) |

**Rationale:**
- Full-text search requires `pg_trgm` (trigram indexing).
- Schema-per-tenant architecture requires a clean `public` schema (only system tables allowed).
- Version 14.0+ is required for stored procedure enhancements used in the scheduler.

---

## 3. Startup Sequence

The application initializes in **10 sequential steps**. Steps marked **(FATAL GATE)** will terminate the process on failure.

| Step | Module | Fatal? | Purpose |
|---|---|---|---|
| 1 | `config.load()` | No | Parse environment variables |
| 2 | `obs_logger.init()` | No | Initialize structured logger |
| 3 | `identity_provider.bootstrap()` | No | Bootstrap Keycloak/IDP client |
| 4 | `db_pool.Pool.init()` | No | Connect to PostgreSQL |
| 5 | **`startup_assertions.assertDatabaseConfiguration()`** | **Yes (FATAL)** | **Verify database assumptions** |
| 6 | `db_provisioning.provisionTenantSchema()` | No | Apply migrations to default tenant |
| 7 | `bootstrap_audit.auditPublicSchema()` | No | Log unexpected public schema state |
| 8 | Store initialization (event, definition, task stores) | No | Initialize in-memory state |
| 9 | `scheduler_poller.spawn()` | No | Start background scheduler |
| 10 | `server.listen()` | No | Begin accepting HTTP requests |

### 3.1 Step 5: Database Configuration Assertion (FATAL GATE)

This step runs **immediately after Pool.init** and **before any schema provisioning**. It verifies the three database assumptions listed in Section 2.

**On Success:**
- No output
- Process continues to Step 6

**On Failure:**
- Emits a `FATAL` log line to stderr (see Section 4)
- Returns error to `main()`
- Process exits with code `78` (EX_CONFIG)

**Integration Point in Source:**
```zig
// src/main.zig, line ~154 (after Pool.init, before provisionTenantSchema)
var pool = try db_pool.Pool.init(io, allocator, .{ .url = config.db_url, .pool_size = 10 });
defer pool.deinit();

// PI-09: Fail-fast database configuration assertion
startup_assertions.assertDatabaseConfiguration(allocator, &pool) catch |err| {
    const EX_CONFIG = 78;
    std.process.exit(EX_CONFIG);
};

// Continue with tenant provisioning...
db_provisioning.provisionTenantSchema(allocator, &pool, default_tenant_id, ...) catch |err| { ... };
```

---

## 4. Alert Routing: FATAL Log Line Format

When a startup assertion fails, the application emits a **deterministic FATAL log line** to stderr. This line is designed for machine parsing by alerting systems (e.g., Prometheus Alertmanager, PagerDuty).

### 4.1 Format Specification

```
FATAL startup.database <ERROR_CODE> <key>=<value> ...
```

**Components:**
- `FATAL` — Log severity (uppercase)
- `startup.database` — Component identifier (lowercase, dot-separated)
- `<ERROR_CODE>` — One of: `PG_VERSION_MISMATCH`, `PG_EXTENSION_MISSING`, `PUBLIC_SCHEMA_POLLUTION`, `QUERY_FAILED`
- Context pairs — Space-separated `key=value` pairs (no quotes)

### 4.2 Examples

```
FATAL startup.database PG_VERSION_MISMATCH current=130008 required_min=140000
FATAL startup.database PG_EXTENSION_MISSING extension=pg_trgm
FATAL startup.database PUBLIC_SCHEMA_POLLUTION table_count=3 expected=0
FATAL startup.database QUERY_FAILED query=server_version_num error=ConnectionRefused
```

### 4.3 Alert Rule Example (Prometheus)

```yaml
- alert: BPMStartupDatabaseConfigFailure
  expr: |
    increase(log_lines_total{severity="FATAL", component="startup.database"}[5m]) > 0
  labels:
    severity: critical
    team: platform
  annotations:
    summary: "BPM Platform failed database configuration check"
    description: "Pod {{ $labels.pod }} emitted FATAL startup.database line. Check logs for ERROR_CODE."
```

---

## 5. Common Failure Modes

| Error Code | Meaning | Probable Cause | Remedy |
|---|---|---|---|
| `PG_VERSION_MISMATCH` | PostgreSQL version < 14.0 | Old PostgreSQL server or wrong connection URL | Upgrade PostgreSQL to 14.x or later. Verify `BPM_DB_URL` points to correct instance. |
| `PG_EXTENSION_MISSING` | `pg_trgm` extension not installed | Extension not created in database | Connect as superuser: `CREATE EXTENSION pg_trgm;` |
| `PUBLIC_SCHEMA_POLLUTION` | Unexpected tables in `public` schema | Prior application state, manual DDL, or migration rollback artifact | Review table list: `SELECT tablename FROM pg_tables WHERE schemaname='public';`. Drop stale tables if safe. |
| `QUERY_FAILED` | Introspection query execution failed | Connection lost, insufficient permissions, or PostgreSQL unavailable | Check database connectivity. Verify user has `CONNECT` and `SELECT` privileges on system catalogs. |

### 5.1 Recovery Checklist: `PG_VERSION_MISMATCH`

1. Confirm PostgreSQL version: `psql -c "SHOW server_version;"`
2. If version < 14.0:
   - Schedule upgrade to PostgreSQL 14.x or 15.x
   - Test upgrade in staging first
   - Update deployment manifest to use new base image
3. If version ≥ 14.0:
   - Verify `BPM_DB_URL` environment variable points to correct host/port
   - Check for connection URL typo (wrong database, wrong host)

### 5.2 Recovery Checklist: `PG_EXTENSION_MISSING`

1. Connect to database as superuser:
   ```bash
   psql "$BPM_DB_URL" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
   ```
2. Verify installation:
   ```bash
   psql "$BPM_DB_URL" -c "SELECT * FROM pg_extension WHERE extname='pg_trgm';"
   ```
3. Restart application

### 5.3 Recovery Checklist: `PUBLIC_SCHEMA_POLLUTION`

1. Inspect public schema:
   ```bash
   psql "$BPM_DB_URL" -c "SELECT tablename FROM pg_tables WHERE schemaname='public';"
   ```
2. Identify stale tables (not system tables like `spatial_ref_sys`)
3. Drop if safe:
   ```bash
   psql "$BPM_DB_URL" -c "DROP TABLE IF EXISTS <table_name>;"
   ```
4. Restart application

**Warning:** Do NOT drop tables without verifying their origin. System tables (PostGIS, extensions) are expected and should be exempted from this check in future versions.

---

## 6. Process Management

### 6.1 Signal Handling

The application responds to the following signals:

| Signal | Behaviour | Use Case |
|---|---|---|
| `SIGTERM` | Graceful shutdown: stop accepting new connections, drain in-flight requests (30s timeout), then exit | Kubernetes pod termination, Docker stop |
| `SIGINT` | Same as `SIGTERM` (Ctrl+C in terminal) | Manual stop during development |
| `SIGKILL` | Immediate termination (cannot be caught) | Last resort when graceful shutdown hangs |

### 6.2 Graceful Shutdown Sequence

1. Receive `SIGTERM` / `SIGINT`
2. Stop accepting new HTTP connections
3. Wait for in-flight requests to complete (max 30 seconds)
4. Close database pool connections
5. Flush logs
6. Exit with code `0`

---

## 7. Health Check Endpoints

### 7.1 Liveness Probe: `/health/live`

**Purpose:** Kubernetes liveness probe — "Is the process running?"

**Response:**
```json
{"status": "live"}
```

**Status Code:** Always `200 OK` if process is alive

### 7.2 Readiness Probe: `/health/ready`

**Purpose:** Kubernetes readiness probe — "Can the service handle traffic?"

**Response:**
```json
{
  "status": "ready",
  "subsystems": {
    "database": "healthy",
    "identity_provider": "healthy",
    "scheduler": "healthy"
  }
}
```

**Status Codes:**
- `200 OK` — All critical subsystems healthy
- `503 Service Unavailable` — One or more critical subsystems unhealthy

**Subsystem Checks:**
- `database` — Connection pool can acquire and release a connection
- `identity_provider` — IDP client can reach Keycloak `/health/ready` endpoint
- `scheduler` — Background scheduler thread is alive

---

## 8. Cross-References

- **Backend Architecture:** `docs/BPM_Platform_Backend_Architecture.md`
- **Sandbox Threat Model:** `docs/sandbox_threat_model.md`
- **Agent System:** `docs/agents/AGENT_SYSTEM.md`
- **Test Infrastructure Guide:** `docs/guides/test_infrastructure_guide.md`
- **Migration Guide:** `migrations/README.md`

---

## 9. Operational Contacts

| Role | Team | Contact Method |
|---|---|---|
| On-Call Engineer | Platform Team | PagerDuty escalation policy |
| Database Administrator | Infrastructure Team | Slack `#infra-database` |
| Security Incident Response | Security Team | `security@bpm.local` |

---

**End of Operations Runbook**
