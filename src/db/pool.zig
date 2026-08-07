//! Database connection pool — DB-01, DB-02, DB-03, DB-04
//!
//! Wraps the pg vendor module (vendor/pg/pg.zig).  Provides acquire/release
//! semantics over a fixed-size connection pool.  All SQL execution goes through
//! pg.zig which delivers real query results against a live PostgreSQL database.
//!
//! Design artefact: src/design/db.md
const std = @import("std");

const pg = @import("pg");
const tenant_context_mod = @import("tenant_context");
const pipeline_context_mod = @import("pipeline_context");

fn currentRequestTenantId() []const u8 {
    return tenant_context_mod.get();
}

fn currentRequestPipelineRunId() []const u8 {
    return pipeline_context_mod.get();
}

// ---------------------------------------------------------------------------
// TNT-06: db_host routing helpers
// ---------------------------------------------------------------------------

/// TNT-06: Build a new DSN by replacing the host component of base_url with
/// new_host.  Port, user, password, and database name are preserved unchanged.
///
/// Accepts DSNs of the form postgres://user:pass@host:port/dbname or
/// postgresql://user:pass@host:port/dbname.  Returns PoolError.ConnectionFailed
/// if the DSN cannot be parsed or new_host contains characters outside
/// [a-zA-Z0-9._-].
///
/// allocator — caller must free the returned string.
pub fn buildTenantDsn(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    new_host: []const u8,
) PoolError![]const u8 {
    // Validate new_host: only alphanumeric, dot, hyphen allowed.
    for (new_host) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == '_';
        if (!ok) return PoolError.ConnectionFailed;
    }
    if (new_host.len == 0) return PoolError.ConnectionFailed;

    // Find the scheme prefix (postgres:// or postgresql://)
    const at_pos = std.mem.indexOf(u8, base_url, "@") orelse
        return PoolError.ConnectionFailed;

    // The host (and optional port) starts just after '@'.
    // Find the end of host: either '/' (path), ':' (port), or end of string.
    const after_at = base_url[at_pos + 1 ..];
    const slash_pos_rel = std.mem.indexOf(u8, after_at, "/");
    const colon_pos_rel = std.mem.indexOf(u8, after_at, ":");

    // Determine where the host ends in after_at.
    const host_end_rel: usize = blk: {
        if (slash_pos_rel != null and colon_pos_rel != null) {
            break :blk @min(slash_pos_rel.?, colon_pos_rel.?);
        } else if (slash_pos_rel != null) {
            break :blk slash_pos_rel.?;
        } else if (colon_pos_rel != null) {
            break :blk colon_pos_rel.?;
        } else {
            break :blk after_at.len;
        }
    };

    // Build: prefix_up_to_@  + new_host + suffix_from_host_end
    const prefix = base_url[0 .. at_pos + 1]; // includes '@'
    const suffix = after_at[host_end_rel..]; // ":port/dbname" or "/dbname" or ""

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, new_host, suffix }) catch
        return PoolError.ConnectionFailed;
}

/// TNT-06: Look up db_host for the given tenant from public.tenant_schemas.
/// Returns null when db_host IS NULL or no tenant_schemas row exists for
/// this tenant (falls back to single-server behaviour).
///
/// conn   — a connection already checked out from the pool (caller owns it).
/// allocator — for the returned host string (caller must free).
/// tenant_id — the resolved tenant UUID string.
///
/// Returns PoolError.QueryFailed on DB error.
pub fn resolveDbHostForTenant(
    conn: *Conn,
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
) PoolError!?[]const u8 {
    // Use parameterised query — no string interpolation of tenant_id.
    const row = conn.queryRow(
        allocator,
        "SELECT db_host FROM public.tenant_schemas WHERE tenant_id = $1 LIMIT 1",
        &.{tenant_id},
    ) catch return PoolError.QueryFailed;

    if (row) |r| {
        defer {
            // Free the column slices other than [0] which we may return.
            for (r[1..]) |col| {
                if (col) |c| allocator.free(c);
            }
            allocator.free(r);
        }
        if (r.len > 0) {
            if (r[0]) |host_val| {
                // Caller takes ownership of this slice.
                return host_val;
            }
        }
    }
    return null;
}

/// Derive the PostgreSQL schema name for a given tenant ID string.
///
/// - Empty string  → "tenant_default"
/// - All-zeros UUID → "tenant_default"
/// - Any other UUID → "tenant_" + UUID with hyphens stripped
///
/// NOTE (ISS-501 / ISS-0098): the empty-string branch above is unreachable
/// from applyRequestStorageRouting()'s no-tenant path — that function
/// short-circuits an empty tenant_id to `SET search_path TO public` and
/// returns before ever calling this helper (see the no-tenant branch below).
/// This function's empty-string case only matters if some other caller
/// invokes it directly with an empty tenant_id; the SCHEMA-routing branch
/// (non-empty resolved tenant IDs) is the only production caller today.
///
/// The result is written into buf (must be at least 40 bytes; 7 + 32 = 39 max).
/// Returns a slice into buf.  The caller must consume it before the frame returns.
/// This function is allocation-free and safe to call on the hot path.
pub fn schemaNameForTenant(tenant_id: []const u8, buf: *[80]u8) []const u8 {
    const default_uuid = "00000000-0000-0000-0000-000000000000";
    if (tenant_id.len == 0 or std.mem.eql(u8, tenant_id, default_uuid)) {
        const result = "tenant_default";
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }
    // Write "tenant_" prefix then UUID with hyphens stripped.
    const prefix = "tenant_";
    @memcpy(buf[0..prefix.len], prefix);
    var out: usize = prefix.len;
    for (tenant_id) |c| {
        if (c != '-') {
            buf[out] = c;
            out += 1;
        }
    }
    return buf[0..out];
}

/// Parse a storage_mode string returned from public.tenant.storage_mode.
/// Returns null when the string is unrecognised (caller falls back to
/// the tenant_schemas heuristic, then to .LEGACY_RLS).
///
/// Recognised values: "LEGACY_RLS", "SCHEMA".
pub fn parseStorageMode(raw: []const u8) ?tenant_context_mod.StorageMode {
    if (std.mem.eql(u8, raw, "LEGACY_RLS")) return .LEGACY_RLS;
    if (std.mem.eql(u8, raw, "SCHEMA")) return .SCHEMA;
    return null;
}

/// ISS-0114 / GH-377: resolve the storage_mode for `tenant_id` and cache it
/// in tenant_context. Algorithm:
///   1. SELECT storage_mode FROM public.tenant WHERE id = $1::uuid LIMIT 1.
///   2. If exactly 1 row returned, parse storage_mode and cache it.
///   3. If 0 rows OR the mode is unrecognised, SELECT 1 FROM
///      public.tenant_schemas WHERE tenant_id = $1::uuid LIMIT 1.
///      A row means the schema is provisioned — trust .SCHEMA.
///   4. Otherwise (both queries 0 rows) — fall through to .LEGACY_RLS.
///
/// `tenant_id` must be the canonical 36-char UUID string.
/// `conn` must be a checked-out pool connection.
///
/// Returns PoolError.QueryFailed on any underlying query failure; on
/// query failure the resolver falls back to .LEGACY_RLS so callers do
/// not block subsequent acquire() attempts.
pub fn resolveAndCacheStorageMode(
    conn: *Conn,
    tenant_id: []const u8,
) PoolError!void {
    // Step 1: query public.tenant.storage_mode.
    const row = conn.queryRow(
        std.heap.page_allocator,
        "SELECT storage_mode FROM public.tenant WHERE id = $1::uuid LIMIT 1",
        &.{tenant_id},
    ) catch {
        // Query failure: degrade to LEGACY_RLS (defensive; matches prior
        // behaviour so a transient DB blip does not block the request).
        tenant_context_mod.setStorageMode(.LEGACY_RLS);
        return;
    };

    if (row) |r| {
        defer {
            if (r[0]) |v| std.heap.page_allocator.free(v);
            std.heap.page_allocator.free(r);
        }
        if (r[0]) |mode_str| {
            if (parseStorageMode(mode_str)) |mode| {
                tenant_context_mod.setStorageMode(mode);
                return;
            }
        }
    }

    // Step 2: fallback to public.tenant_schemas (ISS-0114 / GH-377).
    // When the tenant was provisioned but no public.tenant row exists, the
    // schema-per-tenant path is the correct routing — trust it.
    const schema_row = conn.queryRow(
        std.heap.page_allocator,
        "SELECT 1 FROM public.tenant_schemas WHERE tenant_id = $1::uuid LIMIT 1",
        &.{tenant_id},
    ) catch {
        // Fallback query failure: stay on LEGACY_RLS.
        tenant_context_mod.setStorageMode(.LEGACY_RLS);
        return;
    };

    if (schema_row) |sr| {
        defer std.heap.page_allocator.free(sr);
        // tenant_schemas row present → SCHEMA mode is authoritative.
        tenant_context_mod.setStorageMode(.SCHEMA);
        return;
    }

    // Step 3: both queries returned 0 rows — fall back to LEGACY_RLS.
    tenant_context_mod.setStorageMode(.LEGACY_RLS);
}

/// ISS-501: Storage-mode-aware connection routing.
/// Replaces TNT-03's applyRequestTenantContext().
/// Called unconditionally by Pool.acquire() after selecting the connection.
///
/// Branches on the resolved tenant's storage_mode:
///
///   tenant_id empty/absent (no resolved tenant):
///     SET search_path TO public
///     (no set_config calls)
///
///   storage_mode = LEGACY_RLS:
///     SET search_path TO public
///     SELECT set_config('bpm.tenant_id', $1, false)     ← RLS active
///     SELECT set_config('bpm.pipeline_run_id', $1, false)
///
///   storage_mode = SCHEMA:
///     SET search_path TO tenant_{slug},public
///     SELECT set_config('bpm.pipeline_run_id', $1, false)  ← no tenant_id for RLS
///
/// The search_path SET is issued FIRST so any subsequent unqualified query
/// immediately resolves to the correct schema.
/// Returns PoolError.QueryFailed if any SET fails.
fn applyRequestStorageRouting(conn: *Conn) PoolError!void {
    const tenant_id = currentRequestTenantId();

    if (tenant_id.len == 0) {
        // No-tenant branch (bootstrap token / platform-admin / no resolved tenant).
        try conn.exec("SET search_path TO public", &.{});
        return;
    }

    // ISS-501: Resolve storage_mode once per request.
    // On first connection acquisition: query tenant for storage_mode,
    // cache it in tenant_context.  On subsequent acquisitions: use cached value.
    if (!tenant_context_mod.hasStorageMode()) {
        try resolveAndCacheStorageMode(conn, tenant_id);
    }

    const mode = tenant_context_mod.getStorageMode();

    switch (mode) {
        .LEGACY_RLS => {
            // Legacy path: public schema + RLS predicate via set_config.
            try conn.exec("SET search_path TO public", &.{});
            const pipeline_run_id = currentRequestPipelineRunId();
            try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_id});
            try conn.exec("SELECT set_config('bpm.pipeline_run_id', $1, false)", &.{pipeline_run_id});
        },
        .SCHEMA => {
            // Schema-per-tenant path: tenant schema first, no RLS.
            var schema_buf: [80]u8 = undefined;
            const schema_name = schemaNameForTenant(tenant_id, &schema_buf);
            var path_buf: [128]u8 = undefined;
            const search_path = std.fmt.bufPrint(
                &path_buf,
                "SET search_path TO {s},public",
                .{schema_name},
            ) catch return PoolError.QueryFailed;
            try conn.exec(search_path, &.{});

            const pipeline_run_id = currentRequestPipelineRunId();
            try conn.exec("SELECT set_config('bpm.pipeline_run_id', $1, false)", &.{pipeline_run_id});
            // No set_config('bpm.tenant_id', ...) — RLS is inactive in tenant schemas.
        },
    }
}

/// TNT-06: Redirect a connection to a tenant-specific remote host if
/// tenant_schemas.db_host IS NOT NULL and differs from the current connection's
/// host.  Called by Pool.acquire() after the stale-connection check.
///
/// pool_allocator is used to allocate the db_host string stored on the conn.
/// On failure: returns PoolError.ConnectionFailed (callers discard the connection).
fn maybeRedirectToTenantHost(
    conn: *Conn,
    pool_allocator: std.mem.Allocator,
    io: std.Io,
) PoolError!void {
    const tenant_id = currentRequestTenantId();
    if (tenant_id.len == 0) {
        // No tenant context — single-server path; nothing to redirect.
        return;
    }

    // We need a temporary allocator for the queryRow result.
    // Use the pool allocator (short-lived; freed within this function).
    const db_host_opt = resolveDbHostForTenant(conn, pool_allocator, tenant_id) catch {
        // Query failure: fall back to default host (non-fatal for routing).
        return;
    };

    if (db_host_opt) |new_host| {
        // Check if we are already on this host.
        const already_on_host = blk: {
            if (conn._remote_host) |current| {
                break :blk std.mem.eql(u8, current, new_host);
            }
            break :blk false;
        };

        if (!already_on_host) {
            // Build a new DSN with the remote host substituted.
            const new_dsn = buildTenantDsn(pool_allocator, conn._url, new_host) catch {
                pool_allocator.free(new_host);
                return PoolError.ConnectionFailed;
            };
            defer pool_allocator.free(new_dsn);

            // Close current connection and open a new one to the remote host.
            conn._pg.close();
            const remote_pg = pg.Conn.connectUrl(io, pool_allocator, new_dsn) catch {
                conn._is_valid = false;
                pool_allocator.free(new_host);
                return PoolError.ConnectionFailed;
            };
            conn._pg = remote_pg;

            // Free previous remote_host if any, then store new one.
            if (conn._remote_host) |old| pool_allocator.free(old);
            conn._remote_host = new_host;
        } else {
            // Already on the correct host; free the duplicate.
            pool_allocator.free(new_host);
        }
    } else {
        // db_host IS NULL → single-server path.
        // If we were previously redirected to a remote host, close that
        // connection and reconnect to the default URL.
        if (conn._remote_host != null) {
            conn._pg.close();
            const default_pg = pg.Conn.connectUrl(io, pool_allocator, conn._url) catch {
                conn._is_valid = false;
                return PoolError.ConnectionFailed;
            };
            conn._pg = default_pg;
            if (conn._remote_host) |old| pool_allocator.free(old);
            conn._remote_host = null;
        }
    }
}

/// TNT-03: Reset search_path to public on a connection being returned to the idle pool.
/// Called by Pool.release() before marking the connection idle.
/// On failure: marks connection invalid so it will be reconnected on next acquire.
/// Cross-tenant contamination guard — a connection that cannot be reset is discarded.
fn resetConnectionSearchPath(conn: *Conn) void {
    if (!conn._is_valid) return; // already invalid; will be replaced on next acquire
    conn.exec("SET search_path TO public", &.{}) catch {
        // Reset failed — mark connection invalid so Pool.release discards it.
        conn._is_valid = false;
    };
}

/// ISS-0612 / GH #556: defense-in-depth safety net called from Pool.release().
///
/// Unconditionally releases every session-scoped advisory lock held by this
/// connection's underlying Postgres session before the connection re-enters
/// the idle set. pg_advisory_unlock_all() is defined to succeed trivially
/// when no advisory locks are held, so calling it on every release (not just
/// ones suspected of holding a lock) is always safe and cheap. This bounds
/// the blast radius of any future bug where a code path acquires a
/// session-scoped advisory lock (e.g. via provisioning.zig's
/// acquireAdvisoryLock) and, through an error path or a missed defer, fails
/// to release it before returning the connection to the pool — instead of
/// silently hanging every future caller that acquires this exact connection
/// and contends on this exact key, the stale lock is cleared here.
fn clearConnectionAdvisoryLocks(conn: *Conn) void {
    if (!conn._is_valid) return; // already invalid; will be replaced on next acquire
    conn.exec("SELECT pg_advisory_unlock_all()", &.{}) catch {
        // Clear failed — mark connection invalid so Pool.release discards it,
        // rather than silently returning a connection that may still hold a
        // stale lock back to the idle set.
        conn._is_valid = false;
    };
}

const obs_metrics_mod = @import("obs_metrics");

fn recordDbQueryDurationFromSql(sql: []const u8, elapsed_s: f64) void {
    obs_metrics_mod.recordDbQueryDurationSeconds(
        obs_metrics_mod.classifyQueryType(sql),
        elapsed_s,
    );
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
    /// TNT-06: non-null when this connection is routed to a remote host instead
    /// of the default BPM_DB_URL host.  Slice is allocator-owned (pool allocator).
    _remote_host: ?[]const u8,
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
        defer result.deinit();
        if (result.rows.len == 0) {
            return null;
        }

        const source_row = result.rows[0];
        const owned_row = allocator.alloc(?[]u8, source_row.len) catch {
            return PoolError.QueryFailed;
        };

        var copied: usize = 0;
        errdefer {
            for (owned_row[0..copied]) |col| {
                if (col) |c| allocator.free(c);
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

    /// Execute a multi-statement SQL string using the simple query protocol.
    ///
    /// Unlike exec(), this method uses PostgreSQL's Simple Query Protocol, which
    /// accepts semicolon-separated multi-statement SQL.  No parameter binding is
    /// supported.  Use for migration SQL files which contain multiple DDL statements.
    pub fn simpleQuery(self: *Conn, sql: []const u8) PoolError!void {
        const started_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds();
        defer {
            const elapsed_ms: i64 = std.Io.Clock.real.now(self._io).toMilliseconds() - started_ms;
            const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            recordDbQueryDurationFromSql(sql, elapsed_s);
        }

        if (!self._is_valid) return PoolError.StaleConnection;
        self._pg.simpleQuery(sql) catch |err| {
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
                ._remote_host = null, // TNT-06: no remote host override initially
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
            // TNT-06: reset remote_host tracking on reconnect (new connection is
            // to the default URL; db_host routing will be re-evaluated below).
            if (conn._remote_host) |old| {
                self.allocator.free(old);
                conn._remote_host = null;
            }
        }

        // TNT-06: Redirect to tenant-specific host if db_host IS NOT NULL.
        maybeRedirectToTenantHost(conn, self.allocator, self.io) catch |err| {
            self.idle_indices[self.idle_count] = idx;
            self.idle_count += 1;
            return err;
        };

        applyRequestStorageRouting(conn) catch |err| {
            self.idle_indices[self.idle_count] = idx;
            self.idle_count += 1;
            return err;
        };

        return conn;
    }

    /// Return a connection to the idle pool.
    /// conn must have been obtained from this Pool.
    ///
    /// TNT-03: Calls resetConnectionSearchPath before returning conn to idle.
    /// If the reset fails the connection is marked invalid (not returned to pool),
    /// preventing cross-tenant search_path contamination on the next acquire.
    ///
    /// TNT-06: If the connection was redirected to a remote host, close it and
    /// reconnect to the default URL before returning to the idle pool.  Remote
    /// connections are not kept open between requests — the pool reconnects on
    /// the next acquire when db_host IS NOT NULL.
    pub fn release(self: *Pool, conn: *Conn) void {
        // TNT-06: If this connection was redirected to a remote host, close it
        // and reconnect to the default URL so the slot is clean for the next user.
        if (conn._remote_host != null and conn._is_valid) {
            conn._pg.close();
            if (conn._remote_host) |old| {
                self.allocator.free(old);
                conn._remote_host = null;
            }
            // Reconnect to default URL; on failure mark invalid for reconnect on next acquire.
            const default_pg = pg.Conn.connectUrl(self.io, self.allocator, conn._url) catch {
                conn._is_valid = false;
                self.mutex.lockUncancelable(self.io);
                self.idle_indices[self.idle_count] = conn._pool_idx;
                self.idle_count += 1;
                self.mutex.unlock(self.io);
                return;
            };
            conn._pg = default_pg;
        }

        // TNT-03: Reset search_path to public before returning to idle pool.
        // resetConnectionSearchPath marks conn._is_valid = false on failure.
        resetConnectionSearchPath(conn);

        // ISS-0612 / GH #556: defense-in-depth. Unconditionally release any
        // session-scoped advisory locks still held by this connection before
        // it re-enters the idle set. pg_advisory_unlock_all() is a no-op
        // when no locks are held, so this is always safe to call. This
        // converts any future bug of this class (a code path that acquires
        // a session-scoped advisory lock and, through a missed defer or a
        // new call site that forgets the release-before-pool-release
        // discipline, fails to release it) from "silently hangs every
        // future caller that acquires this exact connection and contends on
        // this exact key" into a harmless no-op — the pool itself now
        // guarantees no connection re-enters idle carrying a stale lock.
        // Mirrors resetConnectionSearchPath's own pattern immediately above:
        // on failure, mark the connection invalid rather than silently
        // returning it to idle.
        clearConnectionAdvisoryLocks(conn);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (!conn._is_valid) {
            // Reset failed — discard this connection slot. On next acquire it will
            // be reconnected via the stale-connection path in Pool.acquire().
            // Push the index back so the slot can be reused after reconnect.
            self.idle_indices[self.idle_count] = conn._pool_idx;
            self.idle_count += 1;
            return;
        }

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
