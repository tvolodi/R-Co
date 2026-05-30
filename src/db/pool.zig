//! Database connection pool — DB-01, DB-02, DB-03, DB-04
//!
//! Wraps the pg vendor module (vendor/pg/pg.zig).  Provides acquire/release
//! semantics over a fixed-size connection pool.  All SQL execution goes through
//! pg.zig which delivers real query results against a live PostgreSQL database.
//!
//! Design artefact: src/design/db.md
const std = @import("std");

const pg = @import("pg");
const root = @import("root");

fn currentRequestTenantId() []const u8 {
    if (@hasDecl(root, "api_tenant_context")) {
        return root.api_tenant_context.get();
    }
    return "";
}

fn currentRequestPipelineRunId() []const u8 {
    if (@hasDecl(root, "api_pipeline_context")) {
        return root.api_pipeline_context.get();
    }
    return "";
}

fn applyRequestTenantContext(conn: *Conn) PoolError!void {
    const tenant_id = currentRequestTenantId();
    const effective_tenant = if (tenant_id.len == 0) "" else tenant_id;
    const pipeline_run_id = currentRequestPipelineRunId();
    const effective_pipeline_run = if (pipeline_run_id.len == 0) "" else pipeline_run_id;
    try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{effective_tenant});
    try conn.exec("SELECT set_config('bpm.pipeline_run_id', $1, false)", &.{effective_pipeline_run});
}

fn recordDbQueryDurationFromSql(sql: []const u8, elapsed_s: f64) void {
    if (@hasDecl(root, "obs_metrics")) {
        const m = root.obs_metrics;
        m.recordDbQueryDurationSeconds(m.classifyQueryType(sql), elapsed_s);
    }
}

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const PoolError = error{
    /// DB-02: all connections are in use — return immediately, no blocking.
    ExhaustedPool,
    /// Cannot open a new connection to PostgreSQL (network, auth failure).
    ConnectionFailed,
    /// Connection validation failed on acquire; discarded, replacement attempted.
    StaleConnection,
    /// pool_size < 2 or > 200 (NFR-06, DB-02) — fatal at startup.
    InvalidPoolSize,
    /// PostgreSQL server version < 15 (DB-01) — fatal at startup.
    UnsupportedPgVersion,
    /// Health check SELECT 1 returned a database error (DB-04).
    QueryFailed,
};

// ---------------------------------------------------------------------------
// Public config / result types
// ---------------------------------------------------------------------------

pub const PoolConfig = struct {
    /// PostgreSQL DSN from BPM_DB_URL.  Must be non-empty.
    url: []const u8,
    /// From BPM_DB_POOL_SIZE.  Valid range: 2..200.  Default: 10. (DB-02, NFR-06)
    pool_size: u8,
};

pub const HealthResult = struct {
    /// Wall-clock round-trip time from acquire() to SELECT 1 result, in ms. (DB-04)
    latency_ms: u64,
};

// ---------------------------------------------------------------------------
// Conn
//
// NOTE: The design artefact specifies `pub const Conn = opaque {};`.  A fully
// opaque type has no callable methods, which prevents store.zig and
// migrations.zig from executing SQL through the handle.  This implementation
// uses a concrete struct that is intentionally un-constructible by callers
// (no public constructor; all fields are private by convention).  External
// modules must only obtain Conn handles via Pool.acquire().
// ---------------------------------------------------------------------------

pub const Conn = struct {
    _pool_idx: usize, // index into Pool.conns; used by release()
    _is_valid: bool,
    _url: []const u8,
    _io: std.Io,
    /// Real PostgreSQL connection.  Always valid when _is_valid is true.
    _pg: pg.Conn,

    // -----------------------------------------------------------------------
    // SQL execution helpers
    //
    // All use $1, $2, ... placeholders — no string interpolation of user data.
    // The `params` slice contains the serialised parameter values to bind.
    //
    // NOTE: Real pg delegation is deferred until pg.zig is implemented.
    // All methods currently return QueryFailed (no real connection).
    // -----------------------------------------------------------------------

    /// Execute a parameterised DML/DDL statement (no result rows expected).
    /// sql must use $1, $2, ... placeholders corresponding to params entries.
    pub fn exec(
        self: *Conn,
        sql: []const u8,
        params: []const []const u8,
    ) PoolError!void {
        const started_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds() - started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            recordDbQueryDurationFromSql(sql, elapsed_s);
        }

        if (!self._is_valid) return PoolError.StaleConnection;
        self._pg.exec(sql, params) catch |err| {
            // Mark connection invalid on protocol/connection errors.
            if (err == pg.PgError.ConnectionFailed or err == pg.PgError.ProtocolError) {
                self._is_valid = false;
                return PoolError.StaleConnection;
            }
            return PoolError.QueryFailed;
        };
    }

    /// Execute a parameterised query and return all result rows.
    ///
    /// Returns a QueryResult whose memory is owned by the caller; call
    /// QueryResult.deinit() to free.  Returns an empty result when the query
    /// produces no rows (NOT an error).
    pub fn query(
        self: *Conn,
        allocator: std.mem.Allocator,
        sql: []const u8,
        params: []const []const u8,
    ) PoolError!QueryResult {
        const started_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds() - started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            recordDbQueryDurationFromSql(sql, elapsed_s);
        }

        if (!self._is_valid) return PoolError.StaleConnection;
        const result = self._pg.query(allocator, sql, params) catch |err| {
            if (err == pg.PgError.ConnectionFailed or err == pg.PgError.ProtocolError) {
                self._is_valid = false;
                return PoolError.StaleConnection;
            }
            return PoolError.QueryFailed;
        };
        return QueryResult{ .rows = result.rows, .result = result };
    }

    /// Execute a parameterised query and return the first row, or null if no
    /// rows match.  Caller owns the row slice; free each non-null column and
    /// then the slice itself.
    pub fn queryRow(
        self: *Conn,
        allocator: std.mem.Allocator,
        sql: []const u8,
        params: []const []const u8,
    ) PoolError!?[]?[]u8 {
        const started_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds() - started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            recordDbQueryDurationFromSql(sql, elapsed_s);
        }

        if (!self._is_valid) return PoolError.StaleConnection;
        var result = self._pg.query(allocator, sql, params) catch |err| {
            if (err == pg.PgError.ConnectionFailed or err == pg.PgError.ProtocolError) {
                self._is_valid = false;
                return PoolError.StaleConnection;
            }
            return PoolError.QueryFailed;
        };
        if (result.rows.len == 0) {
            result.deinit();
            return null;
        }

        const source_row = result.rows[0];
        const owned_row = allocator.alloc(?[]u8, source_row.len) catch {
            result.deinit();
            return PoolError.QueryFailed;
        };

        var copied: usize = 0;
        errdefer {
            for (owned_row[0..copied]) |col| {
                if (col) |c| if (c.len > 0) allocator.free(c);
            }
            allocator.free(owned_row);
        }

        for (source_row, 0..) |col, idx| {
            if (col) |value| {
                owned_row[idx] = allocator.dupe(u8, value) catch return PoolError.QueryFailed;
            } else {
                owned_row[idx] = null;
            }
            copied += 1;
        }

        result.deinit();
        return owned_row;
    }

    // -----------------------------------------------------------------------
    // Transaction helpers
    // -----------------------------------------------------------------------

    /// Begin a database transaction.
    pub fn begin(self: *Conn) PoolError!void {
        const started_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds() - started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            recordDbQueryDurationFromSql("BEGIN", elapsed_s);
        }

        if (!self._is_valid) return PoolError.StaleConnection;
        self._pg.begin() catch |err| {
            if (err == pg.PgError.ConnectionFailed or err == pg.PgError.ProtocolError) {
                self._is_valid = false;
                return PoolError.StaleConnection;
            }
            return PoolError.QueryFailed;
        };
    }

    /// Commit the current transaction.
    pub fn commit(self: *Conn) PoolError!void {
        const started_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds() - started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            recordDbQueryDurationFromSql("COMMIT", elapsed_s);
        }

        if (!self._is_valid) return PoolError.StaleConnection;
        self._pg.commit() catch |err| {
            if (err == pg.PgError.ConnectionFailed or err == pg.PgError.ProtocolError) {
                self._is_valid = false;
                return PoolError.StaleConnection;
            }
            return PoolError.QueryFailed;
        };
    }

    /// Roll back the current transaction.  Best-effort: errors are non-fatal
    /// because rollback is often called in error-cleanup paths.
    pub fn rollback(self: *Conn) PoolError!void {
        const started_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds() - started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            recordDbQueryDurationFromSql("ROLLBACK", elapsed_s);
        }

        if (!self._is_valid) return PoolError.StaleConnection;
        self._pg.rollback() catch |err| {
            if (err == pg.PgError.ConnectionFailed or err == pg.PgError.ProtocolError) {
                self._is_valid = false;
                return PoolError.StaleConnection;
            }
            return PoolError.QueryFailed;
        };
    }
};

// ---------------------------------------------------------------------------
// QueryResult
// ---------------------------------------------------------------------------

/// Result of a SQL query: a slice of rows, each row a slice of nullable column
/// values (all byte strings).  All memory is owned by the caller.
pub const QueryResult = struct {
    /// rows[i][j] = column j of row i, or null for SQL NULL.
    rows: [][]?[]u8,
    result: pg.Result,

    pub fn deinit(self: *QueryResult) void {
        self.result.deinit();
        self.rows = &.{};
    }
};

// ---------------------------------------------------------------------------
// Pool
// ---------------------------------------------------------------------------

pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PoolConfig,
    /// All connections; owned by the pool.
    conns: []Conn,
    /// Stack of idle connection indices into conns[].
    idle_indices: []usize,
    /// Number of currently idle connections (valid range: 0..conns.len).
    idle_count: usize,
    mutex: std.Io.Mutex,
    /// Cached PostgreSQL server_version_num; verified >= 150000 in init().
    pg_version: u32,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// Validate config, open pool_size connections, verify PostgreSQL >= 15.
    ///
    /// Returns InvalidPoolSize if pool_size < 2 or > 200.
    /// Returns ConnectionFailed if any initial connection cannot be established.
    /// Returns UnsupportedPgVersion if server_version_num < 150000.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: PoolConfig) PoolError!Pool {
        if (config.pool_size < 2 or config.pool_size > 200) {
            return PoolError.InvalidPoolSize;
        }
        if (config.url.len == 0) {
            return PoolError.ConnectionFailed;
        }

        const pool_size: usize = @intCast(config.pool_size);

        const conns = allocator.alloc(Conn, pool_size) catch return PoolError.ConnectionFailed;
        errdefer allocator.free(conns);

        const idle_indices = allocator.alloc(usize, pool_size) catch return PoolError.ConnectionFailed;
        errdefer allocator.free(idle_indices);

        // Open real PostgreSQL connections.
        var opened: usize = 0;
        errdefer {
            for (conns[0..opened]) |*c| c._pg.close();
        }

        var pg_version: u32 = 0;
        for (conns, 0..) |*c, i| {
            const pg_conn = pg.Conn.connectUrl(io, allocator, config.url) catch
                return PoolError.ConnectionFailed;
            c.* = Conn{
                ._pool_idx = i,
                ._is_valid = true,
                ._url = config.url,
                ._io = io,
                ._pg = pg_conn,
            };
            opened += 1;
            idle_indices[i] = i;
            if (i == 0) pg_version = pg_conn.serverVersion();
        }

        // DB-01: require PostgreSQL >= 15.
        if (pg_version != 0 and pg_version < 150000) {
            return PoolError.UnsupportedPgVersion;
        }

        return Pool{
            .allocator = allocator,
            .io = io,
            .config = config,
            .conns = conns,
            .idle_indices = idle_indices,
            .idle_count = pool_size,
            .mutex = .init,
            .pg_version = if (pg_version == 0) 150000 else pg_version,
        };
    }

    /// Close all connections and free pool memory.
    /// Must not be called while any connection is acquired.
    pub fn deinit(self: *Pool) void {
        for (self.conns) |*c| {
            if (c._is_valid) c._pg.close();
        }
        self.allocator.free(self.idle_indices);
        self.allocator.free(self.conns);
    }

    // -----------------------------------------------------------------------
    // Acquire / release
    // -----------------------------------------------------------------------

    /// Acquire a validated idle connection.
    ///
    /// Returns ExhaustedPool immediately if none are available.
    /// Validates the connection before returning; replaces stale connections
    /// with a single retry.  Returns ConnectionFailed if both validation and
    /// replacement fail.
    pub fn acquire(self: *Pool) PoolError!*Conn {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.idle_count == 0) return PoolError.ExhaustedPool;

        self.idle_count -= 1;
        const idx = self.idle_indices[self.idle_count];
        const conn = &self.conns[idx];

        if (!conn._is_valid) {
            // Attempt to reconnect before failing.
            conn._pg.close();
            conn._pg = pg.Conn.connectUrl(self.io, self.allocator, conn._url) catch {
                self.idle_indices[self.idle_count] = idx;
                self.idle_count += 1;
                return PoolError.ConnectionFailed;
            };
            conn._is_valid = true;
            conn._io = self.io;
        }

        applyRequestTenantContext(conn) catch |err| {
            self.idle_indices[self.idle_count] = idx;
            self.idle_count += 1;
            return err;
        };

        return conn;
    }

    /// Return a connection to the idle pool.
    /// conn must have been obtained from this Pool.
    pub fn release(self: *Pool, conn: *Conn) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.idle_indices[self.idle_count] = conn._pool_idx;
        self.idle_count += 1;
    }

    // -----------------------------------------------------------------------
    // Health check (DB-04)
    // -----------------------------------------------------------------------

    /// Run SELECT 1 using a pool connection and return wall-clock latency.
    ///
    /// Returns ExhaustedPool if no connection is available.
    /// Returns QueryFailed if the query fails (DB unreachable, timeout, etc.).
    pub fn healthCheck(self: *Pool) PoolError!HealthResult {
        const start: i64 = std.Io.Clock.real.now(self.io).toMilliseconds();
        const conn = try self.acquire();
        defer self.release(conn);
        // DB-04: issue a real SELECT 1 to verify the connection is live.
        conn.exec("SELECT 1", &.{}) catch return PoolError.QueryFailed;
        const end: i64 = std.Io.Clock.real.now(self.io).toMilliseconds();
        return HealthResult{ .latency_ms = @intCast(end - start) };
    }
};
