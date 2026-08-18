//! QRY-03 — Keyset cursor encoding and decoding.
//!
//! Wire format (before base64url): QE:<issued_at_us>:<fingerprint>:<val1>|<val2>|…
//! `QE:` prefix rejects cursors from other endpoints.

const std = @import("std");
const builtin = @import("builtin");

pub const SortFingerprint = struct {
    value: []const u8,
};

pub const QueryCursor = struct {
    fingerprint: SortFingerprint,
    tuple: [][]const u8,
    issued_at_us: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const QueryCursor) void {
        self.allocator.free(self.fingerprint.value);
        for (self.tuple) |v| self.allocator.free(v);
        self.allocator.free(self.tuple);
    }
};

pub const CursorDecodeError = error{ CursorMalformed, CursorSortMismatch, OutOfMemory };

const CURSOR_EXPIRY_US: i64 = 86_400_000_000;
const CURSOR_PREFIX = "QE:";

pub fn encodeCursor(
    allocator: std.mem.Allocator,
    fingerprint: SortFingerprint,
    tuple: []const []const u8,
    issued_at_us: i64,
) error{OutOfMemory}![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);

    const ts_str = std.fmt.allocPrint(allocator, "{d}", .{issued_at_us}) catch return error.OutOfMemory;
    defer allocator.free(ts_str);

    raw.appendSlice(allocator, CURSOR_PREFIX) catch return error.OutOfMemory;
    raw.appendSlice(allocator, ts_str) catch return error.OutOfMemory;
    raw.append(allocator, ':') catch return error.OutOfMemory;
    raw.appendSlice(allocator, fingerprint.value) catch return error.OutOfMemory;
    raw.append(allocator, ':') catch return error.OutOfMemory;

    for (tuple, 0..) |val, i| {
        if (i > 0) raw.append(allocator, '|') catch return error.OutOfMemory;
        for (val) |c| {
            if (c == '|') {
                raw.appendSlice(allocator, "%7C") catch return error.OutOfMemory;
            } else {
                raw.append(allocator, c) catch return error.OutOfMemory;
            }
        }
    }

    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(raw.items.len);
    const out = allocator.alloc(u8, encoded_len) catch return error.OutOfMemory;
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, raw.items);
    return out;
}

pub fn decodeCursor(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    fingerprint: SortFingerprint,
    order_by_count: usize,
) CursorDecodeError!QueryCursor {
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch
        return CursorDecodeError.CursorMalformed;
    const raw = allocator.alloc(u8, decoded_len) catch return CursorDecodeError.OutOfMemory;
    defer allocator.free(raw);
    std.base64.url_safe_no_pad.Decoder.decode(raw, encoded) catch
        return CursorDecodeError.CursorMalformed;

    if (!std.mem.startsWith(u8, raw, CURSOR_PREFIX)) return CursorDecodeError.CursorMalformed;
    const after_prefix = raw[CURSOR_PREFIX.len..];

    const colon1 = std.mem.indexOf(u8, after_prefix, ":") orelse return CursorDecodeError.CursorMalformed;
    const issued_at_us = std.fmt.parseInt(i64, after_prefix[0..colon1], 10) catch
        return CursorDecodeError.CursorMalformed;

    const now_us = currentMicrosecondTimestamp();
    if (now_us - issued_at_us > CURSOR_EXPIRY_US) return CursorDecodeError.CursorMalformed;

    const rest_after_ts = after_prefix[colon1 + 1 ..];
    const colon2 = std.mem.indexOf(u8, rest_after_ts, ":") orelse return CursorDecodeError.CursorMalformed;
    const fp_raw = rest_after_ts[0..colon2];

    if (!std.mem.eql(u8, fp_raw, fingerprint.value)) return CursorDecodeError.CursorSortMismatch;

    const values_raw = rest_after_ts[colon2 + 1 ..];
    var tuple: std.ArrayList([]u8) = .empty;
    errdefer {
        for (tuple.items) |v| allocator.free(v);
        tuple.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, values_raw, '|');
    while (it.next()) |segment| {
        const decoded_val = decodePercentPipe(allocator, segment) catch
            return CursorDecodeError.OutOfMemory;
        tuple.append(allocator, decoded_val) catch {
            allocator.free(decoded_val);
            return CursorDecodeError.OutOfMemory;
        };
    }

    if (tuple.items.len != order_by_count) return CursorDecodeError.CursorMalformed;

    const fp_copy = allocator.dupe(u8, fp_raw) catch return CursorDecodeError.OutOfMemory;
    errdefer allocator.free(fp_copy);

    const tuple_slice = tuple.toOwnedSlice(allocator) catch return CursorDecodeError.OutOfMemory;

    return QueryCursor{
        .fingerprint = .{ .value = fp_copy },
        .tuple = @ptrCast(tuple_slice),
        .issued_at_us = issued_at_us,
        .allocator = allocator,
    };
}

pub const SortTerm = struct { name: []const u8, dir: []const u8 };

pub fn buildFingerprint(
    allocator: std.mem.Allocator,
    sort_fields: []const SortTerm,
) error{OutOfMemory}!SortFingerprint {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    for (sort_fields, 0..) |sf, i| {
        if (i > 0) buf.append(allocator, ',') catch return error.OutOfMemory;
        buf.appendSlice(allocator, sf.name) catch return error.OutOfMemory;
        buf.append(allocator, ':') catch return error.OutOfMemory;
        buf.appendSlice(allocator, sf.dir) catch return error.OutOfMemory;
    }

    return SortFingerprint{ .value = try buf.toOwnedSlice(allocator) };
}

fn decodePercentPipe(allocator: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (i + 2 < s.len and s[i] == '%' and s[i + 1] == '7' and (s[i + 2] == 'C' or s[i + 2] == 'c')) {
            out.append(allocator, '|') catch return error.OutOfMemory;
            i += 3;
        } else {
            out.append(allocator, s[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn currentMicrosecondTimestamp() i64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10);
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        return ts.sec * 1_000_000 + @divTrunc(ts.nsec, 1000);
    }
}
