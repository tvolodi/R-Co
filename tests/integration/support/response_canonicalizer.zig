const std = @import("std");

pub const RegressionPhase = enum {
    pre_migration,
    post_migration,
};

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const InformationalAllowlist = struct {
    header_names: []const []const u8,
    json_pointer_paths: []const []const u8,
};

pub const ResponseSnapshot = struct {
    case_id: []const u8,
    phase: RegressionPhase,
    status_code: u16,
    headers_canonical_json: []const u8,
    body_canonical_bytes: []const u8,
    body_sha256_hex: [64]u8,
    content_type: []const u8,
};

const CanonicalHeader = struct {
    name: []u8,
    value: []u8,
};

pub fn deinitSnapshots(allocator: std.mem.Allocator, snapshots: []ResponseSnapshot) void {
    for (snapshots) |snapshot| {
        allocator.free(snapshot.case_id);
        allocator.free(snapshot.headers_canonical_json);
        allocator.free(snapshot.body_canonical_bytes);
        allocator.free(snapshot.content_type);
    }
    allocator.free(snapshots);
}

pub fn deinitSnapshot(allocator: std.mem.Allocator, snapshot: *ResponseSnapshot) void {
    allocator.free(snapshot.case_id);
    allocator.free(snapshot.headers_canonical_json);
    allocator.free(snapshot.body_canonical_bytes);
    allocator.free(snapshot.content_type);
}

pub fn canonicalizeResponse(
    allocator: std.mem.Allocator,
    case_id: []const u8,
    phase: RegressionPhase,
    raw_status_code: u16,
    raw_headers: []const HeaderPair,
    raw_body: []const u8,
    content_type: []const u8,
    allowlist: InformationalAllowlist,
) !ResponseSnapshot {
    const canonical_headers = try canonicalizeHeaders(allocator, raw_headers, allowlist.header_names);
    errdefer allocator.free(canonical_headers);

    const canonical_body = try canonicalizeBody(allocator, raw_body, content_type, allowlist.json_pointer_paths);
    errdefer allocator.free(canonical_body);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_body, &digest, .{});

    var digest_hex: [64]u8 = undefined;
    const rendered_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)});
    defer allocator.free(rendered_hex);
    @memcpy(digest_hex[0..], rendered_hex[0..64]);

    return .{
        .case_id = try allocator.dupe(u8, case_id),
        .phase = phase,
        .status_code = raw_status_code,
        .headers_canonical_json = canonical_headers,
        .body_canonical_bytes = canonical_body,
        .body_sha256_hex = digest_hex,
        .content_type = try allocator.dupe(u8, content_type),
    };
}

fn canonicalizeHeaders(
    allocator: std.mem.Allocator,
    headers: []const HeaderPair,
    excluded_names: []const []const u8,
) ![]u8 {
    var canonical: std.ArrayList(CanonicalHeader) = .empty;
    defer {
        for (canonical.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        canonical.deinit(allocator);
    }

    for (headers) |header| {
        if (isExcludedHeader(header.name, excluded_names)) continue;

        var lower_name = try allocator.alloc(u8, header.name.len);
        errdefer allocator.free(lower_name);
        for (header.name, 0..) |ch, idx| {
            lower_name[idx] = std.ascii.toLower(ch);
        }

        const trimmed_value = std.mem.trim(u8, header.value, " \t\r\n");
        const value_copy = try allocator.dupe(u8, trimmed_value);

        try canonical.append(allocator, .{
            .name = lower_name,
            .value = value_copy,
        });
    }

    std.sort.block(CanonicalHeader, canonical.items, {}, struct {
        fn lessThan(_: void, lhs: CanonicalHeader, rhs: CanonicalHeader) bool {
            const by_name = std.mem.order(u8, lhs.name, rhs.name);
            if (by_name != .eq) return by_name == .lt;
            return std.mem.lessThan(u8, lhs.value, rhs.value);
        }
    }.lessThan);

    return std.json.Stringify.valueAlloc(allocator, canonical.items, .{});
}

fn canonicalizeBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    content_type: []const u8,
    json_pointer_allowlist: []const []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, content_type, "application/json")) {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        removeAllowedJsonPointers(&parsed.value, json_pointer_allowlist);
        return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    }

    if (std.mem.startsWith(u8, content_type, "text/")) {
        return normalizeTextBody(allocator, body);
    }

    return allocator.dupe(u8, body);
}

fn normalizeTextBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var idx: usize = 0;
    while (idx < body.len) : (idx += 1) {
        if (body[idx] == '\r') {
            if (idx + 1 < body.len and body[idx + 1] == '\n') {
                try out.append(allocator, '\n');
                idx += 1;
                continue;
            }
            try out.append(allocator, '\n');
            continue;
        }
        try out.append(allocator, body[idx]);
    }

    return out.toOwnedSlice(allocator);
}

fn removeAllowedJsonPointers(value: *std.json.Value, pointers: []const []const u8) void {
    if (value.* != .object) return;

    for (pointers) |pointer| {
        if (pointer.len < 2) continue;
        if (pointer[0] != '/') continue;
        // ADP-12 allowlist pointers are top-level keys only.
        if (std.mem.indexOfScalar(u8, pointer[1..], '/')) |_| continue;
        _ = value.object.swapRemove(pointer[1..]);
    }
}

fn isExcludedHeader(name: []const u8, excluded_names: []const []const u8) bool {
    for (excluded_names) |excluded| {
        if (std.ascii.eqlIgnoreCase(name, excluded)) return true;
    }
    return false;
}
