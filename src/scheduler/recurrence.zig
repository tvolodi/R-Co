const std = @import("std");

pub const RepeatMode = enum {
    finite,
    infinite,
};

pub const RepeatSpec = struct {
    mode: RepeatMode,
    repeat_total: ?u32,
    interval_us: u64,
    normalized: []const u8,
};

pub const RepeatState = struct {
    repeat_total: ?u32,
    fired_count: u32,
    interval_us: u64,
    scheduled_fire_at_us: i64,
};

pub const ParseRepeatError = error{
    InvalidFormat,
    InvalidRepeatCount,
    InvalidDuration,
    ZeroInterval,
    Overflow,
    OutOfMemory,
};

pub const RearmDecision = union(enum) {
    complete,
    rearm: struct {
        next_fire_at_us: i64,
        next_fired_count: u32,
    },
};

pub const RearmError = error{
    CountOverflow,
    TimestampOverflow,
};

pub fn parseRepeatExpression(
    allocator: std.mem.Allocator,
    expr: []const u8,
) ParseRepeatError!RepeatSpec {
    if (expr.len < 4) return ParseRepeatError.InvalidFormat;

    const normalized = allocator.alloc(u8, expr.len) catch return ParseRepeatError.OutOfMemory;
    for (expr, 0..) |ch, i| {
        normalized[i] = std.ascii.toUpper(ch);
    }

    errdefer allocator.free(normalized);

    if (normalized[0] != 'R') return ParseRepeatError.InvalidFormat;

    const slash_idx = std.mem.indexOfScalar(u8, normalized, '/') orelse return ParseRepeatError.InvalidFormat;
    if (slash_idx < 1 or slash_idx + 1 >= normalized.len) return ParseRepeatError.InvalidFormat;

    const count_part = normalized[1..slash_idx];
    const duration_part = normalized[slash_idx + 1 ..];

    const interval_us = parseIsoDurationToMicros(duration_part) catch |err| switch (err) {
        error.InvalidDuration => return ParseRepeatError.InvalidDuration,
        error.Overflow => return ParseRepeatError.Overflow,
    };
    if (interval_us == 0) return ParseRepeatError.ZeroInterval;

    if (count_part.len == 0) {
        return RepeatSpec{
            .mode = .infinite,
            .repeat_total = null,
            .interval_us = interval_us,
            .normalized = normalized,
        };
    }

    const repeat_total = std.fmt.parseInt(u32, count_part, 10) catch return ParseRepeatError.InvalidRepeatCount;
    if (repeat_total == 0) return ParseRepeatError.InvalidRepeatCount;

    return RepeatSpec{
        .mode = .finite,
        .repeat_total = repeat_total,
        .interval_us = interval_us,
        .normalized = normalized,
    };
}

pub fn computeRearmDecision(state: RepeatState) RearmError!RearmDecision {
    if (state.interval_us == 0) return RearmDecision.complete;

    const next_fired_count = std.math.add(u32, state.fired_count, 1) catch return RearmError.CountOverflow;

    if (state.repeat_total) |limit| {
        if (next_fired_count >= limit) return RearmDecision.complete;
    }

    const interval_i64 = std.math.cast(i64, state.interval_us) orelse return RearmError.TimestampOverflow;
    const next_fire_at_us = std.math.add(i64, state.scheduled_fire_at_us, interval_i64) catch return RearmError.TimestampOverflow;

    return RearmDecision{ .rearm = .{
        .next_fire_at_us = next_fire_at_us,
        .next_fired_count = next_fired_count,
    } };
}

fn parseIsoDurationToMicros(duration: []const u8) error{ InvalidDuration, Overflow }!u64 {
    if (duration.len < 3 or duration[0] != 'P') return error.InvalidDuration;

    var idx: usize = 1;
    var in_time = false;
    var seen_any = false;

    var seen_d = false;
    var seen_h = false;
    var seen_m = false;
    var seen_s = false;

    var total_us: u64 = 0;

    while (idx < duration.len) {
        if (duration[idx] == 'T') {
            if (in_time) return error.InvalidDuration;
            in_time = true;
            idx += 1;
            continue;
        }

        const start = idx;
        while (idx < duration.len and std.ascii.isDigit(duration[idx])) : (idx += 1) {}
        if (start == idx or idx >= duration.len) return error.InvalidDuration;

        const value = std.fmt.parseInt(u64, duration[start..idx], 10) catch return error.InvalidDuration;
        const unit = duration[idx];
        idx += 1;

        switch (unit) {
            'D' => {
                if (in_time or seen_d) return error.InvalidDuration;
                seen_d = true;
                total_us = try addScaled(total_us, value, 86_400_000_000);
            },
            'H' => {
                if (!in_time or seen_h) return error.InvalidDuration;
                seen_h = true;
                total_us = try addScaled(total_us, value, 3_600_000_000);
            },
            'M' => {
                if (!in_time or seen_m) return error.InvalidDuration;
                seen_m = true;
                total_us = try addScaled(total_us, value, 60_000_000);
            },
            'S' => {
                if (!in_time or seen_s) return error.InvalidDuration;
                seen_s = true;
                total_us = try addScaled(total_us, value, 1_000_000);
            },
            else => return error.InvalidDuration,
        }
        seen_any = true;
    }

    if (!seen_any) return error.InvalidDuration;
    return total_us;
}

fn addScaled(base: u64, value: u64, scale: u64) error{Overflow}!u64 {
    const scaled = std.math.mul(u64, value, scale) catch return error.Overflow;
    return std.math.add(u64, base, scaled) catch return error.Overflow;
}

test "SCH-07 parseRepeatExpression parses infinite repeat" {
    const alloc = std.testing.allocator;
    const spec = try parseRepeatExpression(alloc, "R/PT1H");
    defer alloc.free(spec.normalized);

    try std.testing.expectEqual(RepeatMode.infinite, spec.mode);
    try std.testing.expect(spec.repeat_total == null);
    try std.testing.expectEqual(@as(u64, 3_600_000_000), spec.interval_us);
}

test "SCH-07 parseRepeatExpression parses finite repeat" {
    const alloc = std.testing.allocator;
    const spec = try parseRepeatExpression(alloc, "R3/PT1H30M");
    defer alloc.free(spec.normalized);

    try std.testing.expectEqual(RepeatMode.finite, spec.mode);
    try std.testing.expectEqual(@as(u32, 3), spec.repeat_total.?);
    try std.testing.expectEqual(@as(u64, 5_400_000_000), spec.interval_us);
}

test "SCH-07 parseRepeatExpression rejects invalid inputs" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(ParseRepeatError.InvalidRepeatCount, parseRepeatExpression(alloc, "R0/PT1H"));
    try std.testing.expectError(ParseRepeatError.InvalidDuration, parseRepeatExpression(alloc, "R3/P1D"));
    try std.testing.expectError(ParseRepeatError.InvalidFormat, parseRepeatExpression(alloc, "PT1H"));
}

test "SCH-07 computeRearmDecision completes finite series" {
    const decision = try computeRearmDecision(.{
        .repeat_total = 3,
        .fired_count = 2,
        .interval_us = 3_600_000_000,
        .scheduled_fire_at_us = 1_000,
    });
    try std.testing.expect(decision == .complete);
}

test "SCH-07 computeRearmDecision rearms infinite series" {
    const decision = try computeRearmDecision(.{
        .repeat_total = null,
        .fired_count = 7,
        .interval_us = 2_000_000,
        .scheduled_fire_at_us = 10_000,
    });
    try std.testing.expect(decision == .rearm);
    try std.testing.expectEqual(@as(u32, 8), decision.rearm.next_fired_count);
    try std.testing.expectEqual(@as(i64, 2_010_000), decision.rearm.next_fire_at_us);
}
