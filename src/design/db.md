# Module: db

**Covers:** DB-01, DB-02, DB-03, DB-04  
**Files:** `src/db/pool.zig`, `src/db/migrations.zig`

---

## Public interface

### pool.zig

```zig
pub const PoolError = error{
    /// DB-02: all connections are in use — return immediately, no blocking
    ExhaustedPool,
    /// Cannot open a new connection to PostgreSQL (network, auth failure)
    ConnectionFailed,
    /// Connection validation failed on acquire; discarded, replacement attempted
    StaleConnection,
    /// pool_size < 2 or > 200 (NFR-06, DB-02) — fatal at startup
    InvalidPoolSize,
    /// PostgreSQL server version < 15 (DB-01) — fatal at startup
    UnsupportedPgVersion,
    /// Health check SELECT 1 returned a database error (DB-04)
    QueryFailed,
};

pub const PoolConfig = struct {
    /// PostgreSQL DSN from BPM_DB_URL. Must be non-empty.
    url: []const u8,
    /// From BPM_DB_POOL_SIZE. Valid range: 2..200. Default: 10. (DB-02, NFR-06)
    pool_size: u8,
};

pub const HealthResult = struct {
    /// Wall-clock round-trip time from acquire() to SELECT 1 result, in milliseconds. (DB-04)
    latency_ms: u64,
};

/// Opaque connection handle. Never construct directly; use Pool.acquire().
pub const Conn = opaque {};

pub const Pool = struct {
    /// Validate config, open pool_size connections, verify PostgreSQL >= 15.
    /// Returns InvalidPoolSize if pool_size < 2 or > 200.
    /// Returns UnsupportedPgVersion if server_version_num < 150000.
    /// Returns ConnectionFailed if any initial connection cannot be established.
    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) PoolError!Pool;

    /// Close all connections and free pool memory. Must not be called while connections are
    /// acquired. Caller ensures all outstanding Conn handles are released first.
    pub fn deinit(self: *Pool) void;

    /// Acquire a validated idle connection. Returns ExhaustedPool immediately if none available.
    /// Validates the connection before returning; replaces stale connections.
    pub fn acquire(self: *Pool) PoolError!*Conn;

    /// Return a connection to the idle pool. conn must have been obtained from this Pool.
    pub fn release(self: *Pool, conn: *Conn) void;

    /// DB-04: run SELECT 1 using a pool connection. Returns latency on success.
    /// Returns ExhaustedPool if no connection is available.
    /// Returns QueryFailed if the query fails (DB unreachable, timeout, etc.).
    pub fn healthCheck(self: *Pool) PoolError!HealthResult;
};
```

### migrations.zig

```zig
pub const MigrationError = error{
    /// migrations_dir path does not exist or is not readable
    MigrationsDirectoryNotFound,
    /// DB-01: a migration M > current N is already applied — applying N+1 before N
    OutOfOrderMigration,
    /// DB-01: SQL execution failed; the migration transaction was rolled back
    MigrationFailed,
    /// DB-01: PostgreSQL major version < 15; fatal
    UnsupportedPgVersion,
    /// Cannot acquire pool connection to run migrations
    PoolExhausted,
};

pub const Migrations = struct {
    /// Discover, order, and apply pending migrations from migrations_dir.
    /// Each pending migration runs inside a single transaction (BEGIN … COMMIT / ROLLBACK).
    /// Records successful application in schema_migrations.
    pub fn run(
        allocator:      std.mem.Allocator,
        pool:           *Pool,
        migrations_dir: []const u8,
    ) MigrationError!void;
};
```

---

## Data types

### PoolConfig
| Field | Type | Notes |
|---|---|---|
| `url` | `[]const u8` | PostgreSQL DSN; e.g. `postgres://user:pass@host:5432/db` |
| `pool_size` | `u8` | Valid range 2..200; default 10 from `BPM_DB_POOL_SIZE` |

### HealthResult
| Field | Type | Notes |
|---|---|---|
| `latency_ms` | `u64` | Wall-clock ms from `acquire()` call to `SELECT 1` result (DB-04) |

### Pool — internal fields (not part of public API)
| Field | Type | Notes |
|---|---|---|
| `allocator` | `std.mem.Allocator` | For connection slice and FIFO |
| `config` | `PoolConfig` | Stored copy |
| `conns` | `[]*InnerConn` | All connections, owned by pool |
| `idle` | `std.fifo.LinearFifo(*InnerConn, .Dynamic)` | Available connections |
| `mutex` | `std.Thread.Mutex` | Guards idle FIFO and in-use bookkeeping |
| `pg_version` | `u32` | Cached PostgreSQL server_version_num; verified ≥ 150000 in init() |

---

## Key invariants

1. **Pool size bounds** — `pool_size` must be in the range 2..200 inclusive. `Pool.init()` returns `InvalidPoolSize` if violated. `main.zig` treats this as a fatal startup error.

2. **No blocking on exhaustion** — `Pool.acquire()` returns `ExhaustedPool` immediately when no idle connection exists. Callers must not spin-retry. The HTTP error layer maps `ExhaustedPool` → HTTP 503.

3. **Stale connection replacement** — Before returning a connection, `acquire()` validates it with a lightweight ping. A failing validation discards that connection and opens a replacement. If the replacement also fails, `ConnectionFailed` is returned (the caller's acquire() fails; not a silent retry loop).

4. **All DB access via pool** — `pool.zig` is the sole file that constructs `pg.zig` connection objects. Every other module receives a `*Pool` and calls `acquire()`. Direct construction of `pg.zig` connections elsewhere is forbidden.

5. **Health check is read-only** — `healthCheck()` issues `SELECT 1`. No data modifications. Uses an existing pool connection; does NOT open a separate connection (DB-04).

6. **PostgreSQL 15+ enforcement** — `Pool.init()` issues `SHOW server_version_num` immediately after the first connection opens. A value < 150000 returns `UnsupportedPgVersion` and `init()` fails entirely.

7. **Migrations run in transactions** — Each `.sql` file in `Migrations.run()` is wrapped in `BEGIN` / `COMMIT`. On any SQL error the transaction is rolled back; `MigrationFailed` is returned and no further migrations are applied. The database is left in the pre-migration state for that file (DB-01, DB-03).

8. **Additive-only migrations** — Migration SQL files must not contain `DROP TABLE`, `DROP COLUMN`, `TRUNCATE`, or any destructive statement. This is enforced by code review / linting convention, not by the migration runner itself at this stage.

---

## External dependencies

| Dependency | Direction | Why |
|---|---|---|
| `vendor/pg/` | pool.zig → pg | Underlying connection library; Pool wraps pg connection objects |
| `src/config.zig` | main.zig → config | Provides `Config.db_url` and reads `BPM_DB_POOL_SIZE` for `PoolConfig` |
| `src/main.zig` | main.zig → Pool | Calls `Pool.init()`, then `Migrations.run()`, then starts HTTP server |
| All domain modules | domain → Pool | Receive `*Pool` at their own `init()` and call `acquire()` / `release()` |
| DB: `schema_migrations` | Migrations.run() → DB | Reads and writes this table to track applied migration versions |

---

## Migration discovery and ordering (Migrations.run)

1. List all `*.sql` files in `migrations_dir`; sort lexicographically (zero-padded `NNN_` prefix ensures numeric order).
2. Query `schema_migrations` for already-applied versions.
3. For each file in sorted order:
   - If its version is in `schema_migrations` → skip (idempotent).
   - If any version M > this file's N is already in `schema_migrations` → return `OutOfOrderMigration`.
   - Otherwise: `BEGIN`; execute file contents; `INSERT INTO schema_migrations (version) VALUES ($1)`; `COMMIT`. On any error: `ROLLBACK`; return `MigrationFailed`.
4. After all files processed: return normally.

### schema_migrations table (created by `001_event_store.sql`, not by migrations.zig itself)
| Column | Type | Notes |
|---|---|---|
| `version` | `TEXT PRIMARY KEY` | Migration filename, e.g. `"001_event_store.sql"` |
| `applied_at` | `TIMESTAMPTZ NOT NULL DEFAULT NOW()` | Timestamp of successful application |

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Pool exhaustion under sustained load | Requests return HTTP 503 | Operators increase `BPM_DB_POOL_SIZE` (up to 200); monitor pool exhaustion metric |
| Migration re-run on already-migrated DB | Potential schema errors | `schema_migrations` tracker prevents re-execution; SQL files use `IF NOT EXISTS` as a second safety net |
| Stale connection after DB restart | First request on stale connection fails | `acquire()` validates each connection; replaces before returning to caller |
| Migration partial failure | DB left in mid-migration state | Each migration runs in its own transaction; failure rolls back cleanly |

---

## Open questions

None. All ambiguities resolved from requirement files and migration SQL.

---

*Traceability:*  
- DB-01 → `Migrations.run()`, `MigrationError`, migration ordering / transaction rules  
- DB-02 → `PoolConfig.pool_size`, `Pool.acquire()`, `ExhaustedPool`, bounds 2..200  
- DB-03 → documented in invariants §7; transaction pattern used by all domain modules  
- DB-04 → `Pool.healthCheck()`, `HealthResult.latency_ms`
