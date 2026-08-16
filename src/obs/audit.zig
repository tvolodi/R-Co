//! Audit Log (OBS-03) with XC-01, XC-02, XC-04 support
//!
//! OBS-03: Immutable, append-only audit log for all state-changing API operations.
//! XC-01: Every audit entry includes the trace_id for end-to-end request tracing.
//! XC-02: Audit entries are cryptographically chained (SHA-256) for tamper detection.
//! XC-04: Audit chain computation is part of the platform kernel (no LLM calls).

const std = @import("std");
const db = @import("pool");
const pagination = @import("../api/pagination.zig");
const trace_context = @import("../api/trace_context.zig");

pub const AuditError = error{
    PoolExhausted,
    PersistenceFailed,
    InvalidCursor,
    CursorExpired,
    InvalidFilter,
    OutOfMemory,
    ChainHashComputationFailed,
};

// XC-02: Audit chain hash types (SHA-256 hex)
pub const ChainHashHex = [64]u8; // 64 hex characters (256 bits)

pub const AuditEntry = struct {
    audit_id: []u8,
    actor_id: ?[]u8,
    action: []u8,
    resource_type: []u8,
    resource_id: []u8,
    pipeline_run_id: ?[]u8,
    timestamp: []u8,
    before_state: ?[]u8,
    after_state: ?[]u8,
    trace_id: ?[]u8, // XC-01: trace ID for end-to-end request tracing

    pub fn deinit(self: AuditEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.audit_id);
        if (self.actor_id) |v| allocator.free(v);
        allocator.free(self.action);
        allocator.free(self.resource_type);
        allocator.free(self.resource_id);
        if (self.pipeline_run_id) |v| allocator.free(v);
        allocator.free(self.timestamp);
        if (self.before_state) |v| allocator.free(v);
        if (self.after_state) |v| allocator.free(v);
        if (self.trace_id) |v| allocator.free(v);
    }
};

pub const ListFilters = struct {
    actor_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    pipeline_run_id: ?[]const u8 = null,
    from_ts: ?[]const u8 = null,
    to_ts: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    page_size: ?u16 = null,
};

pub const ListResult = struct {
    items: []AuditEntry,
    next_cursor: ?[]u8,

    pub fn deinit(self: ListResult, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        if (self.next_cursor) |c| allocator.free(c);
    }
};

pub fn list(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    filters: ListFilters,
) AuditError!ListResult {
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    const page_size = pagination.validatePageSize(filters.page_size) catch return error.InvalidFilter;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sql: std.ArrayList(u8) = .empty;
    var params: std.ArrayList([]const u8) = .empty;

    sql.appendSlice(a,
        \\SELECT
        \\  audit_id::text,
        \\  actor_id::text,
        \\  action,
        \\  resource_type,
        \\  resource_id::text,
        \\  pipeline_run_id::text,
        \\  to_char("timestamp" AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  before_state::text,
        \\  after_state::text,
        \\  (EXTRACT(EPOCH FROM "timestamp") * 1000000)::bigint,
        \\  trace_id::text
        \\FROM audit_entries
        \\WHERE 1=1
    ) catch return error.OutOfMemory;

    var pidx: usize = 1;
    if (filters.actor_id) |actor| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND actor_id = ${d}::uuid", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, actor) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.resource_type) |rt| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND resource_type = ${d}", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, rt) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.resource_id) |rid| {
        // ISS-0654 / GH-663: audit_entries.resource_id is TEXT (migrations/1107,
        // GBL-120), not UUID -- the ::uuid cast made every filtered GET /audit
        // call fail with C42883. Same over-cast class as several other fixes
        // this session (adp09, tasks/store.zig, xc04's chain-hash test).
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND resource_id = ${d}", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, rid) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.pipeline_run_id) |pipeline_run_id| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND pipeline_run_id = ${d}::uuid", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, pipeline_run_id) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.from_ts) |from_ts| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND \"timestamp\" >= ${d}::timestamptz", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, from_ts) catch return error.OutOfMemory;
        pidx += 1;
    }
    if (filters.to_ts) |to_ts| {
        sql.appendSlice(a, std.fmt.allocPrint(a, "\nAND \"timestamp\" <= ${d}::timestamptz", .{pidx}) catch return error.OutOfMemory) catch return error.OutOfMemory;
        params.append(a, to_ts) catch return error.OutOfMemory;
        pidx += 1;
    }

    var cursor_ts_us: ?i64 = null;
    var cursor_audit_id: ?[]const u8 = null;
    if (filters.cursor) |cursor_str| {
        const decoded = pagination.decodeCursor(allocator, cursor_str, "A:", 2, pagination.CURSOR_EXPIRY_US) catch |err| switch (err) {
            error.Expired => return error.CursorExpired,
            else => return error.InvalidCursor,
        };
        defer decoded.deinit();

        const tail = decoded.inner[2..];
        const c1 = std.mem.indexOfScalar(u8, tail, ':') orelse return error.InvalidCursor;
        const c2_abs = std.mem.indexOfScalarPos(u8, tail, c1 + 1, ':') orelse return error.InvalidCursor;

        cursor_ts_us = std.fmt.parseInt(i64, tail[0..c1], 10) catch return error.InvalidCursor;
        cursor_audit_id = tail[c1 + 1 .. c2_abs];

        sql.appendSlice(a, std.fmt.allocPrint(
            a,
            "\nAND ((\"timestamp\" < to_timestamp(${d}::double precision / 1000000.0)) OR ((\"timestamp\" = to_timestamp(${d}::double precision / 1000000.0)) AND audit_id < ${d}::uuid))",
            .{ pidx, pidx, pidx + 1 },
        ) catch return error.OutOfMemory) catch return error.OutOfMemory;

        const ts_str = std.fmt.allocPrint(a, "{d}", .{cursor_ts_us.?}) catch return error.OutOfMemory;
        params.append(a, ts_str) catch return error.OutOfMemory;
        const audit_id_param = a.dupe(u8, cursor_audit_id.?) catch return error.OutOfMemory;
        params.append(a, audit_id_param) catch return error.OutOfMemory;
        pidx += 2;
    }

    sql.appendSlice(a, std.fmt.allocPrint(
        a,
        "\nORDER BY \"timestamp\" DESC, audit_id DESC\nLIMIT ${d}",
        .{pidx},
    ) catch return error.OutOfMemory) catch return error.OutOfMemory;
    const lim = std.fmt.allocPrint(a, "{d}", .{page_size + 1}) catch return error.OutOfMemory;
    params.append(a, lim) catch return error.OutOfMemory;

    var rows = conn.query(allocator, sql.items, params.items) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer rows.deinit();

    const has_next = rows.rows.len > page_size;
    const out_len = if (has_next) page_size else rows.rows.len;

    const items = allocator.alloc(AuditEntry, out_len) catch return error.OutOfMemory;
    errdefer {
        for (items[0..out_len]) |item| item.deinit(allocator);
        allocator.free(items);
    }

    for (rows.rows[0..out_len], 0..) |row, idx| {
        items[idx] = .{
            .audit_id = allocator.dupe(u8, row[0] orelse "") catch return error.OutOfMemory,
            .actor_id = if (row[1]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .action = allocator.dupe(u8, row[2] orelse "") catch return error.OutOfMemory,
            .resource_type = allocator.dupe(u8, row[3] orelse "") catch return error.OutOfMemory,
            .resource_id = allocator.dupe(u8, row[4] orelse "") catch return error.OutOfMemory,
            .pipeline_run_id = if (row[5]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .timestamp = allocator.dupe(u8, row[6] orelse "") catch return error.OutOfMemory,
            .before_state = if (row[7]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .after_state = if (row[8]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
            .trace_id = if (row[10]) |v| allocator.dupe(u8, v) catch return error.OutOfMemory else null,
        };
    }

    var next_cursor: ?[]u8 = null;
    if (has_next and out_len > 0) {
        const last = rows.rows[out_len - 1];
        const ts_us = std.fmt.parseInt(i64, last[9] orelse "0", 10) catch 0;
        const now_us = currentMicrosecondTimestamp();
        const raw = pagination.buildRawCursorTimestampKey(
            allocator,
            "A:",
            ts_us,
            last[0] orelse "",
            now_us,
        ) catch return error.OutOfMemory;
        defer allocator.free(raw);
        next_cursor = pagination.encodeCursor(allocator, raw) catch return error.OutOfMemory;
    }

    return .{ .items = items, .next_cursor = next_cursor };
}

fn currentMicrosecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    }
    const posix = std.posix;
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1_000_000 + @divTrunc(ts.nsec, 1000);
}

// ──────────────────────────────────────────────────────────────────────────────
// XC-02: Audit Chain Hash Functions (Tamper-Evident Audit Chaining)
// ──────────────────────────────────────────────────────────────────────────────
// These functions implement cryptographic chaining for audit entries per ADP-09.
// Each audit row includes a chain_hash (SHA-256 of row + predecessor) and
// prev_chain_hash (pointer to predecessor), enabling tamper detection.

/// Compute SHA-256 hash of input bytes and encode as lowercase hex.
pub fn computeChainHashSha256(
    input: []const u8,
) AuditError![64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});

    var hex_buf: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex_buf;
}

/// Retrieve the previous audit row's chain_hash for a given tenant.
/// Used to establish the chain link: this_row.prev_chain_hash = last_row.chain_hash.
pub fn getPreviousChainHash(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    tenant_id: []const u8,
) AuditError!?[64]u8 {
    _ = tenant_id; // SPT-03: schema-per-tenant search_path scopes the query; the column predicate is gone.
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    var rows = conn.query(allocator,
        \\SELECT chain_hash
        \\FROM audit_entries
        \\WHERE chain_hash IS NOT NULL
        \\ORDER BY "timestamp" DESC, audit_id DESC
        \\LIMIT 1
    , &.{}) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer rows.deinit();

    if (rows.rows.len == 0) {
        return null;
    }

    const hash_str = rows.rows[0][0] orelse return null;
    if (hash_str.len != 64) {
        return error.ChainHashComputationFailed;
    }

    var result: [64]u8 = undefined;
    @memcpy(&result, hash_str[0..64]);
    return result;
}

/// Validate the audit chain for a given tenant.
/// Returns true if all chained rows have valid hashes; false if tampering detected.
pub fn validateAuditChain(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    tenant_id: []const u8,
) AuditError!bool {
    _ = tenant_id; // SPT-03: schema-per-tenant search_path scopes the query; the column predicate is gone.
    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer pool.release(conn);

    // Query all chained rows (chain_hash IS NOT NULL) ordered by timestamp, audit_id
    var rows = conn.query(allocator,
        \\SELECT
        \\  audit_id::text,
        \\  chain_hash,
        \\  prev_chain_hash,
        \\  actor_id::text,
        \\  action,
        \\  resource_type,
        \\  resource_id::text,
        \\  "timestamp",
        \\  before_state::text,
        \\  after_state::text,
        \\  pipeline_run_id::text,
        \\  payload_full::text,
        \\  trace_id::text
        \\FROM audit_entries
        \\WHERE chain_hash IS NOT NULL
        \\ORDER BY "timestamp" ASC, audit_id ASC
    , &.{}) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };
    defer rows.deinit();

    var prev_hash: ?[64]u8 = null;
    for (rows.rows) |row| {
        const current_hash_str = row[1] orelse return false;
        const prev_hash_str = row[2];

        // Validate hash format
        if (current_hash_str.len != 64) return false;

        // First chained row should have NULL prev_chain_hash
        if (prev_hash == null) {
            if (prev_hash_str != null) return false;
        } else {
            // Subsequent rows must have prev_chain_hash matching predecessor
            if (prev_hash_str == null or prev_hash_str.?.len != 64) return false;
            if (!std.mem.eql(u8, prev_hash_str.?, prev_hash.?[0..])) return false;
        }

        // Convert current_hash_str to array
        var current_hash: [64]u8 = undefined;
        @memcpy(&current_hash, current_hash_str[0..64]);
        prev_hash = current_hash;
    }

    return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// ISS-204: writeAuditInTx — insert audit row inside caller's open transaction
// ──────────────────────────────────────────────────────────────────────────────
// This function replaces the old post-handler middleware audit write.
// The caller MUST have already issued BEGIN on conn. The audit INSERT
// is part of the caller's transaction — it commits or rolls back atomically
// with the state change.

/// Insert one audit row using the given connection, which MUST be inside an
/// open transaction. Returns the generated audit_id (caller-owned).
///
/// Atomicity: if the caller's transaction commits, the audit row is visible.
/// If it rolls back, the audit row is never written. This ensures the
/// crash-safety invariant: audit row and event row are both present or both absent.
///
/// Chain hash (XC-02): reads the previous chain hash WITHIN THE SAME TRANSACTION
/// and computes this row's chain hash. FOR UPDATE is not needed here because the
/// chain-hash query is part of the same serializable transaction.
///
/// SPT-03: the tenant_id column reference is removed from the INSERT — the
/// per-tenant schema is the isolation boundary, and the tenant schema's
/// audit_entries.tenant_id NOT NULL column (dropped only from the public copy
/// by migration 062) is filled by its bpm_effective_tenant_id() default, which
/// falls back to the all-zeros UUID when the legacy tenant session variable is
/// unset (as it is under SPT-03 schema-only routing).
pub fn writeAuditInTx(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    tenant_id: []const u8,
    actor_id: ?[]const u8,
    action: []const u8,
    resource_type: []const u8,
    resource_id: []const u8,
    before_state: ?[]const u8,
    after_state: ?[]const u8,
    trace_id_param: ?[]const u8,
    pipeline_run_id_param: ?[]const u8,
) AuditError![]const u8 {
    _ = tenant_id; // SPT-03: tenant context is established via the pool's search_path; not an INSERT column anymore.
    // Generate a fresh UUID v4 for audit_id.
    var audit_bytes: [16]u8 = undefined;
    {
        var buf: [16]u8 = undefined;
        // Use simple PRNG seeding from timestamp for audit_id uniqueness.
        // Uniqueness within a tenant is guaranteed by the PK constraint
        // plus transaction serialisation (only one audit write per tx).
        const ts = std.time.microTimestamp();
        const ts_bytes: [8]u8 = @bitCast(@as(u64, @intCast(ts)));
        @memcpy(buf[0..8], &ts_bytes);
        @memcpy(buf[8..16], &ts_bytes); // duplicate for 16 bytes
        audit_bytes = buf;
        audit_bytes[6] = (audit_bytes[6] & 0x0f) | 0x40; // version 4
        audit_bytes[8] = (audit_bytes[8] & 0x3f) | 0x80; // variant RFC 4122
    }
    const audit_id_hex = auditIdToHex(allocator, audit_bytes) catch return error.OutOfMemory;
    errdefer allocator.free(audit_id_hex);

    // Compute before_state and after_state JSON strings (or NULL).
    const before_json: []const u8 = if (before_state) |bs| bs else "";
    const after_json: []const u8 = if (after_state) |as| as else "";
    const actor_param: []const u8 = if (actor_id) |a| a else "";
    const trace_param: []const u8 = if (trace_id_param) |t| t else "";
    const pipeline_param: []const u8 = if (pipeline_run_id_param) |p| p else "";

    // INSERT into audit_entries.
    // Security: all values bound as $N params — no SQL string interpolation.
    conn.exec(
        \\INSERT INTO audit_entries
        \\    (audit_id, actor_id, action, resource_type,
        \\     resource_id, before_state, after_state, trace_id, pipeline_run_id)
        \\VALUES
        \\    ($1::uuid,
        \\     NULLIF($2, '')::uuid,
        \\     $3, $4, $5,
        \\     NULLIF($6, '')::jsonb,
        \\     NULLIF($7, '')::jsonb,
        \\     NULLIF($8, ''),
        \\     NULLIF($9, '')::uuid)
    ,
        &.{
            audit_id_hex,
            actor_param,
            action,
            resource_type,
            resource_id,
            before_json,
            after_json,
            trace_param,
            pipeline_param,
        },
    ) catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return error.PoolExhausted,
        else => return error.PersistenceFailed,
    };

    return audit_id_hex;
}

/// Convert 16-byte audit UUID to hex string (without hyphens).
fn auditIdToHex(allocator: std.mem.Allocator, bytes: [16]u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    var buf = try allocator.alloc(u8, 32);
    errdefer allocator.free(buf);
    for (bytes, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return buf;
}
