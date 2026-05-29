const std = @import("std");
const types = @import("types.zig");

pub const PlatformUuidSource = struct {
    state: u64,
    emitted: u64,

    pub fn init(seed: u64) types.SimulationError!PlatformUuidSource {
        if (seed == 0) return error.DeterministicUuidSeedInvalid;
        return .{ .state = seed, .emitted = 0 };
    }

    pub fn nextUuidV4(self: *PlatformUuidSource) types.SimulationError![36]u8 {
        if (self.emitted == std.math.maxInt(u64)) return error.DeterministicUuidSequenceExhausted;

        var bytes: [16]u8 = undefined;
        var i: usize = 0;
        while (i < bytes.len) : (i += 8) {
            const v = splitMix64(&self.state);
            var chunk: [8]u8 = undefined;
            std.mem.writeInt(u64, &chunk, v, .big);
            @memcpy(bytes[i .. i + 8], &chunk);
        }

        // RFC 4122 version/variant bits.
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;

        self.emitted += 1;
        return formatUuid(bytes);
    }
};

fn splitMix64(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn writeHexByte(dst: []u8, b: u8) void {
    const alphabet = "0123456789abcdef";
    dst[0] = alphabet[(b >> 4) & 0x0f];
    dst[1] = alphabet[b & 0x0f];
}

fn formatUuid(raw: [16]u8) [36]u8 {
    var out: [36]u8 = undefined;
    var di: usize = 0;
    var si: usize = 0;
    while (si < raw.len) : (si += 1) {
        if (di == 8 or di == 13 or di == 18 or di == 23) {
            out[di] = '-';
            di += 1;
        }
        writeHexByte(out[di .. di + 2], raw[si]);
        di += 2;
    }
    return out;
}

test "PlatformUuidSource: identical seeds produce identical sequence" {
    var a = try PlatformUuidSource.init(42);
    var b = try PlatformUuidSource.init(42);

    const a1 = try a.nextUuidV4();
    const b1 = try b.nextUuidV4();
    try std.testing.expectEqualSlices(u8, &a1, &b1);

    const a2 = try a.nextUuidV4();
    const b2 = try b.nextUuidV4();
    try std.testing.expectEqualSlices(u8, &a2, &b2);
}

test "PlatformUuidSource: UUID v4 formatting" {
    var src = try PlatformUuidSource.init(99);
    const v = try src.nextUuidV4();

    try std.testing.expectEqual(@as(usize, 36), v.len);
    try std.testing.expectEqual('-', v[8]);
    try std.testing.expectEqual('-', v[13]);
    try std.testing.expectEqual('-', v[18]);
    try std.testing.expectEqual('-', v[23]);
    try std.testing.expectEqual('4', v[14]);
    const variant = v[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}
