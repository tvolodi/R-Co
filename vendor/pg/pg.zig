//! Minimal PostgreSQL wire protocol v3 client.
//!
//! Implements just enough of the PostgreSQL frontend/backend protocol to
//! support the connection pool in src/db/pool.zig:
//!   - URL parsing  (postgres://user:pass@host:port/database)
//!   - TCP connection + Startup handshake
//!   - Authentication: Trust, Cleartext, MD5, SCRAM-SHA-256
//!   - Extended Query Protocol for parameterised exec/query
//!   - Simple Query Protocol for begin/commit/rollback
//!   - server_version_num detection
//!
//! Security: all user-supplied parameter values are sent via the Extended
//! Query Protocol Bind message, never string-interpolated into SQL.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const mem = std.mem;
const crypto = std.crypto;
const base64 = std.base64;
// ISS-0607 / GH-542: compile-time gate for the stderr print on PostgreSQL
// ErrorResponse messages. Default off (silent) so that `zig test` does not
// treat every negative-path integration test as a binary-level stderr
// failure. Opt back in via `-Dlog-pg-errors=true` for post-mortem debugging.
const build_options = @import("build_options");
const log_pg_errors = build_options.log_pg_errors;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const PgError = error{
    ConnectionFailed,
    AuthenticationFailed,
    ProtocolError,
    ServerError,
    InvalidUrl,
    OutOfMemory,
    Timeout,
    UnexpectedEof,
    UnsupportedAuthMethod,
};

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

/// Rows returned by a SELECT query.  Each row is a slice of nullable column
/// values (all represented as UTF-8 byte strings).  Memory is owned by the
/// caller; call deinit() to release.
pub const Result = struct {
    rows: [][]?[]u8,
    allocator: mem.Allocator,

    pub fn deinit(self: *Result) void {
        for (self.rows) |row| {
            for (row) |col| {
                if (col) |value| self.allocator.free(value);
            }
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
        self.rows = &.{};
    }
};

// ---------------------------------------------------------------------------
// ConnectOptions
// ---------------------------------------------------------------------------

pub const ConnectOptions = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    user: []const u8,
    password: []const u8,
};

// ---------------------------------------------------------------------------
// Conn
// ---------------------------------------------------------------------------

pub const Conn = struct {
    /// Buffered reader owns the stream, io, and read buffer.
    reader: net.Stream.Reader,
    allocator: mem.Allocator,
    pid: i32 = 0,
    secret: i32 = 0,
    server_version: u32 = 0,
    /// SQLSTATE (5-char code, e.g. "23514") from the most recent ErrorResponse
    /// ('E' field code 'C'), captured so callers can distinguish specific
    /// server-side error conditions (e.g. PAR-01 AC4's "no partition of
    /// relation" check violation) from the generic PgError.ServerError the
    /// wire-protocol layer otherwise collapses everything to. Reset to all
    /// zero bytes at the start of every exec()/query() call so a stale
    /// SQLSTATE from a prior statement can never leak into the next one's
    /// result. Zero bytes ("\x00" * 5) means "no error on the last call".
    last_sqlstate: [5]u8 = std.mem.zeroes([5]u8),

    // -----------------------------------------------------------------------
    // Connect
    // -----------------------------------------------------------------------

    /// Open a connection using a postgres:// URL.
    pub fn connectUrl(io: Io, allocator: mem.Allocator, url: []const u8) PgError!Conn {
        const opts = parseUrl(url) catch return PgError.InvalidUrl;
        return Conn.connect(io, allocator, opts);
    }

    /// Open a connection with explicit options.
    pub fn connect(io: Io, allocator: mem.Allocator, opts: ConnectOptions) PgError!Conn {
        // Try to parse as IP literal first; fall back to hostname-based DNS lookup.
        const stream = blk: {
            if (net.IpAddress.parse(opts.host, opts.port)) |addr| {
                break :blk addr.connect(io, .{ .mode = .stream }) catch
                    return PgError.ConnectionFailed;
            } else |_| {}
            // Hostname (e.g. "localhost") — use HostName.connect which does DNS lookup.
            const host_name = net.HostName.init(opts.host) catch return PgError.InvalidUrl;
            break :blk host_name.connect(io, opts.port, .{ .mode = .stream }) catch
                return PgError.ConnectionFailed;
        };
        errdefer stream.close(io);

        // Heap-allocate the read buffer so it survives struct moves.
        const rbuf = allocator.alloc(u8, 65536) catch return PgError.OutOfMemory;
        errdefer allocator.free(rbuf);

        var conn = Conn{
            .reader = net.Stream.Reader.init(stream, io, rbuf),
            .allocator = allocator,
        };

        try conn.startup(opts);
        return conn;
    }

    /// Close the connection.
    pub fn close(self: *Conn) void {
        // Send Terminate message (type 'X').
        var msg: [5]u8 = undefined;
        msg[0] = 'X';
        std.mem.writeInt(i32, msg[1..5], 4, .big);
        var wbuf: [16]u8 = undefined;
        var w = self.reader.stream.writer(self.reader.io, &wbuf);
        w.interface.writeAll(&msg) catch {};
        w.interface.flush() catch {};
        self.reader.stream.close(self.reader.io);
        self.allocator.free(self.reader.interface.buffer);
    }

    // -----------------------------------------------------------------------
    // High-level SQL helpers
    // -----------------------------------------------------------------------

    /// Execute a parameterised statement with no result rows (INSERT, UPDATE,
    /// DELETE, DDL, etc.).  Parameters are sent as text-format bind values.
    pub fn exec(self: *Conn, sql: []const u8, params: []const []const u8) PgError!void {
        self.last_sqlstate = std.mem.zeroes([5]u8);
        try self.extendedQuery(sql, params);
        try self.readUntilReady(null, null);
    }

    /// Execute a parameterised query and collect all result rows.
    pub fn query(
        self: *Conn,
        allocator: mem.Allocator,
        sql: []const u8,
        params: []const []const u8,
    ) PgError!Result {
        self.last_sqlstate = std.mem.zeroes([5]u8);
        try self.extendedQuery(sql, params);
        var rows: std.ArrayList([]?[]u8) = .empty;
        errdefer {
            for (rows.items) |row| {
                allocator.free(row);
            }
            rows.deinit(allocator);
        }
        try self.readUntilReady(allocator, &rows);
        return Result{
            .rows = try rows.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    /// SQLSTATE of the most recent ErrorResponse from the server (e.g.
    /// "23514" for check_violation), or null if the last exec()/query() did
    /// not error or the server omitted the field (protocol violation; never
    /// observed against real PostgreSQL, which always sends 'C').
    pub fn lastSqlState(self: *const Conn) ?[]const u8 {
        if (std.mem.allEqual(u8, &self.last_sqlstate, 0)) return null;
        return &self.last_sqlstate;
    }

    // -----------------------------------------------------------------------
    // Transaction helpers
    // -----------------------------------------------------------------------

    pub fn begin(self: *Conn) PgError!void {
        try self.simpleQuery("BEGIN");
    }

    pub fn commit(self: *Conn) PgError!void {
        try self.simpleQuery("COMMIT");
    }

    pub fn rollback(self: *Conn) PgError!void {
        try self.simpleQuery("ROLLBACK");
    }

    pub fn serverVersion(self: *const Conn) u32 {
        return self.server_version;
    }

    // -----------------------------------------------------------------------
    // Simple Query Protocol  (no params; for BEGIN/COMMIT/ROLLBACK)
    // -----------------------------------------------------------------------

    pub fn simpleQuery(self: *Conn, sql: []const u8) PgError!void {
        // Message: 'Q' | int32(len+4) | sql | '\0'
        const msg_len: i32 = @intCast(4 + sql.len + 1);
        var header: [5]u8 = undefined;
        header[0] = 'Q';
        std.mem.writeInt(i32, header[1..5], msg_len, .big);
        var wbuf: [4096]u8 = undefined;
        var w = self.reader.stream.writer(self.reader.io, &wbuf);
        w.interface.writeAll(&header) catch return PgError.ConnectionFailed;
        w.interface.writeAll(sql) catch return PgError.ConnectionFailed;
        w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
        w.interface.flush() catch return PgError.ConnectionFailed;
        try self.readUntilReady(null, null);
    }

    // -----------------------------------------------------------------------
    // Extended Query Protocol  (parameterised)
    // -----------------------------------------------------------------------

    fn extendedQuery(self: *Conn, sql: []const u8, params: []const []const u8) PgError!void {
        // Unnamed prepared statement and unnamed portal.
        // All four messages (Parse, Bind, Execute, Sync) are sent in one flush.
        var wbuf: [65536]u8 = undefined;
        var w = self.reader.stream.writer(self.reader.io, &wbuf);

        // --- Parse ---
        // 'P' | int32(len) | stmt_name'\0' | query'\0' | int16(0)
        {
            const body_len: i32 = @intCast(1 + sql.len + 1 + 2);
            var hdr: [5]u8 = undefined;
            hdr[0] = 'P';
            std.mem.writeInt(i32, hdr[1..5], 4 + body_len, .big);
            w.interface.writeAll(&hdr) catch return PgError.ConnectionFailed;
            w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
            w.interface.writeAll(sql) catch return PgError.ConnectionFailed;
            w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
            var zero16: [2]u8 = std.mem.zeroes([2]u8);
            w.interface.writeAll(&zero16) catch return PgError.ConnectionFailed;
        }

        // --- Bind ---
        // 'B' | int32(len) | portal'\0' | stmt'\0' |
        //   int16(0)=nformats | int16(nparams) |
        //   for each param: int32(col_len) | bytes
        //   int16(0)=nresult_formats
        {
            var body_len: i32 = 1 + 1 + 2 + 2 + 2; // two nulls + nformats + nparams + nresults
            for (params) |p| body_len += 4 + @as(i32, @intCast(p.len));
            var hdr: [5]u8 = undefined;
            hdr[0] = 'B';
            std.mem.writeInt(i32, hdr[1..5], 4 + body_len, .big);
            w.interface.writeAll(&hdr) catch return PgError.ConnectionFailed;
            w.interface.writeAll("\x00") catch return PgError.ConnectionFailed; // portal
            w.interface.writeAll("\x00") catch return PgError.ConnectionFailed; // stmt
            var i16buf: [2]u8 = undefined;
            var i32buf: [4]u8 = undefined;
            std.mem.writeInt(i16, &i16buf, 0, .big); // 0 format codes = all text
            w.interface.writeAll(&i16buf) catch return PgError.ConnectionFailed;
            std.mem.writeInt(i16, &i16buf, @intCast(params.len), .big);
            w.interface.writeAll(&i16buf) catch return PgError.ConnectionFailed;
            for (params) |p| {
                std.mem.writeInt(i32, &i32buf, @intCast(p.len), .big);
                w.interface.writeAll(&i32buf) catch return PgError.ConnectionFailed;
                w.interface.writeAll(p) catch return PgError.ConnectionFailed;
            }
            std.mem.writeInt(i16, &i16buf, 0, .big); // 0 result format codes = all text
            w.interface.writeAll(&i16buf) catch return PgError.ConnectionFailed;
        }

        // --- Execute ---
        // 'E' | int32(9) | portal'\0' | int32(0)=max_rows
        {
            var msg: [10]u8 = undefined;
            msg[0] = 'E';
            std.mem.writeInt(i32, msg[1..5], 9, .big);
            msg[5] = 0;
            std.mem.writeInt(i32, msg[6..10], 0, .big);
            w.interface.writeAll(&msg) catch return PgError.ConnectionFailed;
        }

        // --- Sync ---
        {
            var msg: [5]u8 = undefined;
            msg[0] = 'S';
            std.mem.writeInt(i32, msg[1..5], 4, .big);
            w.interface.writeAll(&msg) catch return PgError.ConnectionFailed;
        }

        w.interface.flush() catch return PgError.ConnectionFailed;
    }

    // -----------------------------------------------------------------------
    // Response reading
    // -----------------------------------------------------------------------

    fn readUntilReady(
        self: *Conn,
        allocator: ?mem.Allocator,
        rows: ?*std.ArrayList([]?[]u8),
    ) PgError!void {
        var got_error = false;
        while (true) {
            const msg_type = self.readByte() catch return PgError.ConnectionFailed;
            const msg_len = self.readInt32() catch return PgError.ConnectionFailed;
            const payload_len: usize = @intCast(msg_len - 4);

            switch (msg_type) {
                'Z' => { // ReadyForQuery
                    _ = self.readByte() catch return PgError.ConnectionFailed;
                    if (got_error) return PgError.ServerError;
                    return;
                },
                'D' => { // DataRow
                    if (allocator != null and rows != null) {
                        const row = try self.parseDataRow(allocator.?, payload_len);
                        rows.?.append(allocator.?, row) catch return PgError.OutOfMemory;
                    } else {
                        try self.skipBytes(payload_len);
                    }
                },
                'E' => { // ErrorResponse
                    const err_raw = self.reader.interface.take(payload_len) catch return PgError.ConnectionFailed;
                    // ISS-0607 / GH-542: only print the server-side error
                    // payload to stderr when explicitly opted in via
                    // `-Dlog-pg-errors=true`. The typed
                    // PgError.ServerError return value is preserved
                    // unchanged — only this side effect is gated.
                    if (log_pg_errors) std.debug.print("\nPOSTGRES ERROR: {s}\n", .{err_raw});
                    self.captureSqlState(err_raw);
                    got_error = true;
                },
                // All other messages are safely skipped.
                else => {
                    try self.skipBytes(payload_len);
                },
            }
        }
    }

    /// Parse the SQLSTATE ('C') field out of a raw ErrorResponse body and
    /// store it on the connection. ErrorResponse fields are
    /// `byte1(field_code) ++ c_string ++ ...`, terminated by a single zero
    /// byte. SQLSTATE is always exactly 5 ASCII bytes per the PostgreSQL
    /// protocol spec; a malformed/short field is ignored (last_sqlstate
    /// stays zeroed, i.e. lastSqlState() returns null) rather than read out
    /// of bounds.
    fn captureSqlState(self: *Conn, err_raw: []const u8) void {
        var i: usize = 0;
        while (i < err_raw.len and err_raw[i] != 0) {
            const field_code = err_raw[i];
            i += 1;
            const start = i;
            while (i < err_raw.len and err_raw[i] != 0) : (i += 1) {}
            const field_value = err_raw[start..i];
            if (i < err_raw.len) i += 1; // skip the field's terminating NUL
            if (field_code == 'C' and field_value.len == 5) {
                @memcpy(&self.last_sqlstate, field_value[0..5]);
                return;
            }
        }
    }

    fn parseDataRow(self: *Conn, allocator: mem.Allocator, _payload_len: usize) PgError![]?[]u8 {
        _ = _payload_len;
        const ncols = self.readInt16() catch return PgError.ConnectionFailed;
        const row = allocator.alloc(?[]u8, @intCast(ncols)) catch return PgError.OutOfMemory;
        errdefer {
            allocator.free(row);
        }

        for (row) |*col| {
            const col_len = self.readInt32() catch return PgError.ConnectionFailed;
            if (col_len == -1) {
                col.* = null;
            } else {
                const col_len_u: usize = @intCast(col_len);
                const col_data = self.reader.interface.take(col_len_u) catch
                    return PgError.ConnectionFailed;
                const bytes = allocator.dupe(u8, col_data) catch return PgError.OutOfMemory;
                col.* = bytes;
            }
        }
        return row;
    }

    // -----------------------------------------------------------------------
    // Startup and authentication
    // -----------------------------------------------------------------------

    fn startup(self: *Conn, opts: ConnectOptions) PgError!void {
        // StartupMessage (no message-type byte):
        // int32(total_len) | int32(196608) | "user\0<user>\0" | "database\0<db>\0" | "\0"
        const proto: i32 = 196608; // 3.0
        const user_key = "user\x00";
        const db_key = "database\x00";

        const total_len: i32 = @intCast(
            4 + 4 + // len + proto
                user_key.len + opts.user.len + 1 +
                db_key.len + opts.database.len + 1 +
                1,
        );

        var len_buf: [4]u8 = undefined;
        var proto_buf: [4]u8 = undefined;
        std.mem.writeInt(i32, &len_buf, total_len, .big);
        std.mem.writeInt(i32, &proto_buf, proto, .big);

        var wbuf: [4096]u8 = undefined;
        var w = self.reader.stream.writer(self.reader.io, &wbuf);
        w.interface.writeAll(&len_buf) catch return PgError.ConnectionFailed;
        w.interface.writeAll(&proto_buf) catch return PgError.ConnectionFailed;
        w.interface.writeAll(user_key) catch return PgError.ConnectionFailed;
        w.interface.writeAll(opts.user) catch return PgError.ConnectionFailed;
        w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
        w.interface.writeAll(db_key) catch return PgError.ConnectionFailed;
        w.interface.writeAll(opts.database) catch return PgError.ConnectionFailed;
        w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
        w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
        w.interface.flush() catch return PgError.ConnectionFailed;

        try self.handleAuth(opts);
    }

    fn handleAuth(self: *Conn, opts: ConnectOptions) PgError!void {
        while (true) {
            const msg_type = self.readByte() catch return PgError.ConnectionFailed;
            const msg_len = self.readInt32() catch return PgError.ConnectionFailed;
            const payload_len: usize = @intCast(msg_len - 4);

            switch (msg_type) {
                'R' => {
                    const auth_type = self.readInt32() catch return PgError.ConnectionFailed;
                    switch (auth_type) {
                        0 => {}, // AuthenticationOk — trust auth
                        3 => { // CleartextPassword
                            try self.sendCleartextPassword(opts.password);
                        },
                        5 => { // MD5Password
                            const salt_raw = self.reader.interface.take(4) catch
                                return PgError.ConnectionFailed;
                            const salt: [4]u8 = salt_raw[0..4].*;
                            try self.sendMd5Password(opts.user, opts.password, salt);
                        },
                        10 => { // SASL — SCRAM-SHA-256
                            const sasl_payload = payload_len - 4;
                            // Read mechanism list; look for SCRAM-SHA-256.
                            if (sasl_payload > 65536) return PgError.ProtocolError;
                            const sasl_data = self.reader.interface.take(sasl_payload) catch
                                return PgError.ConnectionFailed;
                            if (mem.indexOf(u8, sasl_data, "SCRAM-SHA-256") == null)
                                return PgError.UnsupportedAuthMethod;
                            try self.handleScram(opts.password);
                        },
                        else => {
                            try self.skipBytes(payload_len - 4);
                            return PgError.UnsupportedAuthMethod;
                        },
                    }
                },
                'S' => { // ParameterStatus — key\0value\0
                    if (payload_len > 65536) {
                        try self.skipBytes(payload_len);
                    } else {
                        const ps_data = self.reader.interface.take(payload_len) catch
                            return PgError.ConnectionFailed;
                        const key = mem.sliceTo(ps_data, 0);
                        if (mem.eql(u8, key, "server_version_num")) {
                            const val_start = key.len + 1;
                            if (val_start < payload_len) {
                                const val = mem.sliceTo(ps_data[val_start..], 0);
                                self.server_version = std.fmt.parseInt(u32, val, 10) catch 0;
                            }
                        }
                    }
                },
                'K' => { // BackendKeyData
                    self.pid = self.readInt32() catch return PgError.ConnectionFailed;
                    self.secret = self.readInt32() catch return PgError.ConnectionFailed;
                },
                'Z' => { // ReadyForQuery
                    _ = self.readByte() catch return PgError.ConnectionFailed;
                    return;
                },
                'E' => {
                    try self.skipBytes(payload_len);
                    return PgError.AuthenticationFailed;
                },
                else => {
                    try self.skipBytes(payload_len);
                },
            }
        }
    }

    fn sendCleartextPassword(self: *Conn, password: []const u8) PgError!void {
        const msg_len: i32 = @intCast(4 + password.len + 1);
        var hdr: [5]u8 = undefined;
        hdr[0] = 'p';
        std.mem.writeInt(i32, hdr[1..5], msg_len, .big);
        var wbuf: [4096]u8 = undefined;
        var w = self.reader.stream.writer(self.reader.io, &wbuf);
        w.interface.writeAll(&hdr) catch return PgError.ConnectionFailed;
        w.interface.writeAll(password) catch return PgError.ConnectionFailed;
        w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
        w.interface.flush() catch return PgError.ConnectionFailed;
    }

    fn sendMd5Password(self: *Conn, user: []const u8, password: []const u8, salt: [4]u8) PgError!void {
        // inner = md5(password || user)
        var inner_input_buf: [512]u8 = undefined;
        const inner_input = std.fmt.bufPrint(&inner_input_buf, "{s}{s}", .{ password, user }) catch
            return PgError.AuthenticationFailed;
        var inner_hash: [16]u8 = undefined;
        crypto.hash.Md5.hash(inner_input, &inner_hash, .{});
        // inner_hex = hex(inner)
        const inner_hex = std.fmt.bytesToHex(&inner_hash, .lower);

        // outer = md5(inner_hex || salt)
        var outer_input_buf: [64]u8 = undefined;
        const outer_input = std.fmt.bufPrint(&outer_input_buf, "{s}{s}", .{ inner_hex, salt }) catch
            return PgError.AuthenticationFailed;
        var outer_hash: [16]u8 = undefined;
        crypto.hash.Md5.hash(outer_input, &outer_hash, .{});
        const outer_hex = std.fmt.bytesToHex(&outer_hash, .lower);

        // Password string: "md5" + hex (35 bytes total)
        var full_pw: [35]u8 = undefined;
        @memcpy(full_pw[0..3], "md5");
        @memcpy(full_pw[3..35], &outer_hex);

        const msg_len: i32 = 4 + 35 + 1;
        var hdr: [5]u8 = undefined;
        hdr[0] = 'p';
        std.mem.writeInt(i32, hdr[1..5], msg_len, .big);
        var wbuf: [64]u8 = undefined;
        var w = self.reader.stream.writer(self.reader.io, &wbuf);
        w.interface.writeAll(&hdr) catch return PgError.ConnectionFailed;
        w.interface.writeAll(&full_pw) catch return PgError.ConnectionFailed;
        w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
        w.interface.flush() catch return PgError.ConnectionFailed;
    }

    /// SCRAM-SHA-256 authentication per RFC 5802 / PostgreSQL protocol.
    fn handleScram(self: *Conn, password: []const u8) PgError!void {
        const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;

        // 1. Generate client nonce.
        var nonce_raw: [18]u8 = undefined;
        self.reader.io.random(&nonce_raw);
        var nonce_b64: [24]u8 = undefined;
        _ = base64.standard.Encoder.encode(&nonce_b64, &nonce_raw);

        // client-first-message-bare: "n=,r=<nonce>"
        const gs2_header = "n,,";
        var cfm_bare_buf: [128]u8 = undefined;
        const cfm_bare = std.fmt.bufPrint(&cfm_bare_buf, "n=,r={s}", .{nonce_b64}) catch
            return PgError.AuthenticationFailed;
        var cfm_buf: [132]u8 = undefined;
        const cfm = std.fmt.bufPrint(&cfm_buf, "{s}{s}", .{ gs2_header, cfm_bare }) catch
            return PgError.AuthenticationFailed;

        // 2. Send SASLInitialResponse.
        // 'p' | int32(len) | "SCRAM-SHA-256\0" | int32(cfm_len) | cfm
        {
            const mech = "SCRAM-SHA-256";
            const msg_len: i32 = @intCast(4 + mech.len + 1 + 4 + cfm.len);
            var hdr: [5]u8 = undefined;
            hdr[0] = 'p';
            std.mem.writeInt(i32, hdr[1..5], msg_len, .big);
            var wbuf: [256]u8 = undefined;
            var w = self.reader.stream.writer(self.reader.io, &wbuf);
            w.interface.writeAll(&hdr) catch return PgError.ConnectionFailed;
            w.interface.writeAll(mech) catch return PgError.ConnectionFailed;
            w.interface.writeAll("\x00") catch return PgError.ConnectionFailed;
            var cfm_len_buf: [4]u8 = undefined;
            std.mem.writeInt(i32, &cfm_len_buf, @intCast(cfm.len), .big);
            w.interface.writeAll(&cfm_len_buf) catch return PgError.ConnectionFailed;
            w.interface.writeAll(cfm) catch return PgError.ConnectionFailed;
            w.interface.flush() catch return PgError.ConnectionFailed;
        }

        // 3. Read AuthenticationSASLContinue (type 'R', auth_type=11).
        const r_type = self.readByte() catch return PgError.ConnectionFailed;
        if (r_type != 'R') return PgError.AuthenticationFailed;
        const r_len = self.readInt32() catch return PgError.ConnectionFailed;
        const r_auth = self.readInt32() catch return PgError.ConnectionFailed;
        if (r_auth != 11) return PgError.AuthenticationFailed;

        const sfm_payload_len: usize = @intCast(r_len - 8);
        // Copy sfm to a stack buffer — the take() result will be invalidated by the next read.
        var sfm_buf: [1024]u8 = undefined;
        if (sfm_payload_len > sfm_buf.len) return PgError.AuthenticationFailed;
        const sfm_raw = self.reader.interface.take(sfm_payload_len) catch
            return PgError.ConnectionFailed;
        @memcpy(sfm_buf[0..sfm_payload_len], sfm_raw);
        const sfm = sfm_buf[0..sfm_payload_len];

        // 4. Parse server-first-message: r=<combined_nonce>,s=<salt_b64>,i=<iterations>
        var combined_nonce: []const u8 = &.{};
        var salt_b64: []const u8 = &.{};
        var iterations: u32 = 0;
        var sfm_it = mem.splitScalar(u8, sfm, ',');
        while (sfm_it.next()) |part| {
            if (mem.startsWith(u8, part, "r=")) combined_nonce = part[2..] else if (mem.startsWith(u8, part, "s=")) salt_b64 = part[2..] else if (mem.startsWith(u8, part, "i="))
                iterations = std.fmt.parseInt(u32, part[2..], 10) catch return PgError.AuthenticationFailed;
        }
        if (combined_nonce.len == 0 or salt_b64.len == 0 or iterations == 0)
            return PgError.AuthenticationFailed;
        if (!mem.startsWith(u8, combined_nonce, &nonce_b64))
            return PgError.AuthenticationFailed;

        // 5. Decode salt and compute SaltedPassword via PBKDF2-HMAC-SHA-256.
        var salt: [64]u8 = undefined;
        const salt_len = base64.standard.Decoder.calcSizeForSlice(salt_b64) catch
            return PgError.AuthenticationFailed;
        if (salt_len > salt.len) return PgError.AuthenticationFailed;
        base64.standard.Decoder.decode(salt[0..salt_len], salt_b64) catch
            return PgError.AuthenticationFailed;

        var salted_password: [32]u8 = undefined;
        pbkdf2HmacSha256(&salted_password, password, salt[0..salt_len], iterations);

        // ClientKey = HMAC(SaltedPassword, "Client Key")
        var client_key: [32]u8 = undefined;
        HmacSha256.create(&client_key, "Client Key", &salted_password);

        // StoredKey = SHA256(ClientKey)
        var stored_key: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&client_key, &stored_key, .{});

        // client-final-message-without-proof: "c=biws,r=<combined_nonce>"
        var cfmwp_buf: [256]u8 = undefined;
        const cfmwp = std.fmt.bufPrint(&cfmwp_buf, "c=biws,r={s}", .{combined_nonce}) catch
            return PgError.AuthenticationFailed;

        // AuthMessage = cfm_bare + "," + sfm + "," + cfmwp
        var auth_msg_buf: [4096]u8 = undefined;
        const auth_msg = std.fmt.bufPrint(&auth_msg_buf, "{s},{s},{s}", .{ cfm_bare, sfm, cfmwp }) catch
            return PgError.AuthenticationFailed;

        // ClientSignature = HMAC(StoredKey, AuthMessage)
        var client_sig: [32]u8 = undefined;
        HmacSha256.create(&client_sig, auth_msg, &stored_key);

        // ClientProof = ClientKey XOR ClientSignature
        var client_proof: [32]u8 = undefined;
        for (&client_proof, client_key, client_sig) |*p, k, s| p.* = k ^ s;

        // 6. Send SASLResponse.
        var proof_b64: [44]u8 = undefined;
        _ = base64.standard.Encoder.encode(&proof_b64, &client_proof);

        var cf_buf: [512]u8 = undefined;
        const cf = std.fmt.bufPrint(&cf_buf, "{s},p={s}", .{ cfmwp, proof_b64 }) catch
            return PgError.AuthenticationFailed;

        {
            const msg_len: i32 = @intCast(4 + cf.len);
            var hdr: [5]u8 = undefined;
            hdr[0] = 'p';
            std.mem.writeInt(i32, hdr[1..5], msg_len, .big);
            var wbuf: [640]u8 = undefined;
            var w = self.reader.stream.writer(self.reader.io, &wbuf);
            w.interface.writeAll(&hdr) catch return PgError.ConnectionFailed;
            w.interface.writeAll(cf) catch return PgError.ConnectionFailed;
            w.interface.flush() catch return PgError.ConnectionFailed;
        }

        // 7. Read AuthenticationSASLFinal (type 'R', auth_type=12).
        const f_type = self.readByte() catch return PgError.ConnectionFailed;
        if (f_type != 'R') return PgError.AuthenticationFailed;
        const f_len = self.readInt32() catch return PgError.ConnectionFailed;
        const f_auth = self.readInt32() catch return PgError.ConnectionFailed;
        if (f_auth != 12) return PgError.AuthenticationFailed;

        const sfinal_payload_len: usize = @intCast(f_len - 8);
        var sfinal_buf: [256]u8 = undefined;
        if (sfinal_payload_len > sfinal_buf.len) return PgError.AuthenticationFailed;
        const sfinal_raw = self.reader.interface.take(sfinal_payload_len) catch
            return PgError.ConnectionFailed;
        @memcpy(sfinal_buf[0..sfinal_payload_len], sfinal_raw);
        const sfinal = sfinal_buf[0..sfinal_payload_len];

        // Verify server signature.
        if (!mem.startsWith(u8, sfinal, "v=")) return PgError.AuthenticationFailed;
        const server_sig_b64 = sfinal[2..];

        var server_key: [32]u8 = undefined;
        HmacSha256.create(&server_key, "Server Key", &salted_password);
        var expected_server_sig: [32]u8 = undefined;
        HmacSha256.create(&expected_server_sig, auth_msg, &server_key);

        var server_sig_decoded: [32]u8 = undefined;
        const sig_len = base64.standard.Decoder.calcSizeForSlice(server_sig_b64) catch
            return PgError.AuthenticationFailed;
        if (sig_len != 32) return PgError.AuthenticationFailed;
        base64.standard.Decoder.decode(&server_sig_decoded, server_sig_b64) catch
            return PgError.AuthenticationFailed;
        if (!mem.eql(u8, &server_sig_decoded, &expected_server_sig))
            return PgError.AuthenticationFailed;

        // 8. Read AuthenticationOk.
        const ok_type = self.readByte() catch return PgError.ConnectionFailed;
        if (ok_type != 'R') return PgError.AuthenticationFailed;
        const ok_len = self.readInt32() catch return PgError.ConnectionFailed;
        _ = ok_len;
        const ok_auth = self.readInt32() catch return PgError.ConnectionFailed;
        if (ok_auth != 0) return PgError.AuthenticationFailed;
    }

    // -----------------------------------------------------------------------
    // Low-level read helpers
    // -----------------------------------------------------------------------

    fn readByte(self: *Conn) !u8 {
        const b = try self.reader.interface.take(1);
        return b[0];
    }

    fn readInt32(self: *Conn) !i32 {
        const b = try self.reader.interface.take(4);
        return std.mem.readInt(i32, b[0..4], .big);
    }

    fn readInt16(self: *Conn) !i16 {
        const b = try self.reader.interface.take(2);
        return std.mem.readInt(i16, b[0..2], .big);
    }

    fn skipBytes(self: *Conn, n: usize) PgError!void {
        if (n == 0) return;
        self.reader.interface.discardAll(n) catch return PgError.ConnectionFailed;
    }
};

// ---------------------------------------------------------------------------
// PBKDF2-HMAC-SHA-256  (single-block, dkLen=32)
// ---------------------------------------------------------------------------

fn pbkdf2HmacSha256(out: *[32]u8, password: []const u8, salt: []const u8, iterations: u32) void {
    const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;

    // U1 = HMAC(Password, Salt || 0x00000001)
    var salt_block: [256]u8 = undefined;
    const block_len = @min(salt.len, salt_block.len - 4);
    @memcpy(salt_block[0..block_len], salt[0..block_len]);
    salt_block[block_len + 0] = 0;
    salt_block[block_len + 1] = 0;
    salt_block[block_len + 2] = 0;
    salt_block[block_len + 3] = 1;

    var u_prev: [32]u8 = undefined;
    HmacSha256.create(&u_prev, salt_block[0 .. block_len + 4], password);
    @memcpy(out, &u_prev);

    var i: u32 = 1;
    while (i < iterations) : (i += 1) {
        var u_curr: [32]u8 = undefined;
        HmacSha256.create(&u_curr, &u_prev, password);
        for (out, u_curr) |*o, u| o.* ^= u;
        u_prev = u_curr;
    }
}

// ---------------------------------------------------------------------------
// URL parser  (postgres://user:pass@host:port/database)
// ---------------------------------------------------------------------------

fn parseUrl(url: []const u8) !ConnectOptions {
    const scheme = "postgres://";
    if (!mem.startsWith(u8, url, scheme)) return error.InvalidUrl;

    var rest = url[scheme.len..];

    // Split on last '@' to get user:pass and host:port/db.
    const at_idx = mem.lastIndexOf(u8, rest, "@") orelse return error.InvalidUrl;
    const user_pass = rest[0..at_idx];
    rest = rest[at_idx + 1 ..];

    var user: []const u8 = user_pass;
    var password: []const u8 = "";
    if (mem.indexOf(u8, user_pass, ":")) |colon| {
        user = user_pass[0..colon];
        password = user_pass[colon + 1 ..];
    }

    var host: []const u8 = rest;
    var port: u16 = 5432;
    var database: []const u8 = "";

    if (mem.indexOf(u8, rest, "/")) |slash| {
        host = rest[0..slash];
        database = rest[slash + 1 ..];
        // Strip query parameters.
        if (mem.indexOf(u8, database, "?")) |q| database = database[0..q];
    }

    // host:port
    if (mem.lastIndexOf(u8, host, ":")) |colon| {
        port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch return error.InvalidUrl;
        host = host[0..colon];
    }

    if (user.len == 0 or host.len == 0 or database.len == 0)
        return error.InvalidUrl;

    return ConnectOptions{
        .host = host,
        .port = port,
        .database = database,
        .user = user,
        .password = password,
    };
}
