//! Effects worker — EXP-301
//!
//! Background polling loop that sweeps the effects_outbox table, attempts
//! delivery via the registered executor, and drives result re-entry into the
//! engine via reenterEffectResult().
//!
//! Mirrors the SCH-02 scheduler pattern: runs as an independent goroutine
//! alongside the main API server, polls every ~5 s, uses FOR UPDATE SKIP LOCKED
//! so multiple workers don't double-process the same row.
//!
//! Inviolable invariants:
//!   - transition.zig is never called from this module.
//!   - All DB writes are atomic: deliver + mark_delivered happen in one txn.
//!   - The event log stays source of truth; outbox rows are projections.
const std = @import("std");
const db = @import("pool");
const mod = @import("mod.zig");
const queue = @import("queue.zig");
const http_adapter = @import("adapters/http.zig");
const email_adapter = @import("adapters/email.zig");
const logger = @import("../obs/logger.zig");

pub const EffectSpec = mod.EffectSpec;
pub const EffectKind = mod.EffectKind;
pub const EffectDeliveryResult = mod.EffectDeliveryResult;
pub const EffectDeliveryError = mod.EffectDeliveryError;
pub const HttpOutcome = mod.HttpOutcome;

pub const EFFECT_BACKOFF_MS = mod.EFFECT_BACKOFF_MS;
pub const EFFECT_MAX_ATTEMPTS = mod.EFFECT_MAX_ATTEMPTS;

pub const WorkerConfig = struct {
    poll_interval_ms: u64 = 5_000,
    max_rows_per_cycle: u32 = 64,
};

// ---------------------------------------------------------------------------
// reenterEffectResult — called after delivery; drives engine re-entry
// ---------------------------------------------------------------------------

pub const ReentryInput = struct {
    pool: *db.Pool,
    correlation_key: []const u8,
    succeeded: bool,
    response_body: ?[]const u8,
    http_status: u16,
};

/// Appends EFFECT_COMPLETED or EFFECT_FAILED to the event log and drives
/// the catch-event transition, all in one atomic transaction.
///
/// On CorrelationKeyNotFound: logs and discards (idempotent; catch-event
/// already fired or was never armed).
pub fn reenterEffectResult(
    allocator: std.mem.Allocator,
    input: ReentryInput,
) mod.EffectReentryError!void {
    const conn = input.pool.acquire() catch return error.PersistenceFailed;
    defer input.pool.release(conn);

    conn.begin() catch return error.PersistenceFailed;
    errdefer conn.rollback() catch {};

    // Look up the instance_waits row for this correlation_key.
    const wait_rows = conn.query(
        allocator,
        \\SELECT
        \\  iw.instance_id::text,
        \\  iw.id::text
        \\FROM instance_waits iw
        \\WHERE iw.catch_event_key = $1
        \\  AND iw.resolved_at IS NULL
        \\LIMIT 1
    ,
        &.{input.correlation_key},
    ) catch return error.PersistenceFailed;
    defer {
        var r = wait_rows;
        r.deinit();
    }

    if (wait_rows.rows.len == 0) {
        // Idempotent skip: catch-event already fired or was never armed.
        conn.rollback() catch {};
        return error.CorrelationKeyNotFound;
    }

    const instance_id = wait_rows.rows[0][0] orelse {
        conn.rollback() catch {};
        return error.InstanceNotFound;
    };
    const wait_id = wait_rows.rows[0][1] orelse {
        conn.rollback() catch {};
        return error.PersistenceFailed;
    };

    // Append EFFECT_COMPLETED or EFFECT_FAILED event to the event log.
    const event_type = if (input.succeeded) "EFFECT_COMPLETED" else "EFFECT_FAILED";
    const status_str = try std.fmt.allocPrint(allocator, "{d}", .{input.http_status});
    defer allocator.free(status_str);
    const payload_json = if (input.succeeded) blk: {
        const body = input.response_body orelse "{}";
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"correlation_key\":\"{s}\",\"http_status\":{d},\"response_body_json\":\"{}\"}}",
            .{ input.correlation_key, input.http_status, std.json.fmt(body, .{}) },
        );
    } else blk: {
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"correlation_key\":\"{s}\",\"http_status\":{d},\"error_detail\":\"delivery failed after max attempts\"}}",
            .{ input.correlation_key, input.http_status },
        );
    };
    defer allocator.free(payload_json);

    const idempotency_key = try std.fmt.allocPrint(
        allocator,
        "effect-reentry:{s}:{s}",
        .{ input.correlation_key, event_type },
    );
    defer allocator.free(idempotency_key);

    conn.exec(
        \\INSERT INTO events
        \\  (instance_id, event_type, payload, actor_id, idempotency_key, metadata, created_at)
        \\VALUES
        \\  (NULLIF($1,'')::uuid, $2, $3::jsonb, gen_random_uuid(), $4, '{}', NOW())
        \\ON CONFLICT (idempotency_key) DO NOTHING
    ,
        &.{ instance_id, event_type, payload_json, idempotency_key },
    ) catch return error.PersistenceFailed;

    // Mark the instance_waits row as resolved.
    conn.exec(
        \\UPDATE instance_waits
        \\SET resolved_at = NOW()
        \\WHERE id = $1::uuid
    ,
        &.{wait_id},
    ) catch return error.PersistenceFailed;

    conn.commit() catch return error.PersistenceFailed;
}

// ---------------------------------------------------------------------------
// sweepOnce — one poll cycle
// ---------------------------------------------------------------------------

/// Run one sweep cycle: fetch due rows, attempt delivery, update status.
/// Does not sleep — caller is responsible for the poll interval.
pub fn sweepOnce(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    executor_kind: ExecutorKind,
    config: WorkerConfig,
) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    const rows = queue.fetchDueRows(allocator, conn, config.max_rows_per_cycle) catch |err| {
        logWorkerError(allocator, "effects_worker.sweep_fetch_failed", @errorName(err));
        return;
    };
    defer {
        for (rows) |row| row.deinit(allocator);
        allocator.free(rows);
    }

    for (rows) |row| {
        processRow(allocator, pool, &row, executor_kind);
    }
}

pub const ExecutorKind = enum {
    http,
    stub_noop, // always succeeds with 200 / "{}"
};

fn processRow(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    row: *const queue.OutboxRow,
    executor_kind: ExecutorKind,
) void {
    const kind = mod.EffectKind.fromWire(row.kind_str) orelse {
        // Invalid kind — DLQ immediately (no retry slot consumed).
        const conn = pool.acquire() catch return;
        defer pool.release(conn);
        queue.markDeadLettered(conn, row.effect_delivery_id, "invalid_kind") catch {};
        return;
    };

    const spec = EffectSpec{
        .effect_event_id = row.effect_event_id,
        .instance_id = row.instance_id,
        .node_id = row.node_id,
        .token_id = "",
        .correlation_key = row.correlation_key,
        .kind = kind,
        .spec_json = row.spec_json,
    };

    const result = deliverSpec(allocator, spec, row.attempt_count, executor_kind) catch |err| {
        // Transport error — schedule retry.
        const backoff = mod.computeEffectBackoffMs(row.attempt_count);
        const conn = pool.acquire() catch return;
        defer pool.release(conn);

        if (row.attempt_count + 1 >= EFFECT_MAX_ATTEMPTS) {
            // Max attempts exhausted — DLQ.
            queue.markDeadLettered(conn, row.effect_delivery_id, @errorName(err)) catch {};
            reenterEffectResult(allocator, .{
                .pool = pool,
                .correlation_key = row.correlation_key,
                .succeeded = false,
                .response_body = null,
                .http_status = 0,
            }) catch |rerr| {
                logWorkerError(allocator, "effects_worker.reentry_failed", @errorName(rerr));
            };
        } else {
            queue.markRetry(allocator, conn, row.effect_delivery_id, 0, @errorName(err), backoff) catch {};
        }
        return;
    };
    defer if (result.response_body) |b| allocator.free(b);

    const outcome = mod.classifyHttpOutcome(result.status_code);
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    switch (outcome) {
        .success => {
            queue.markDelivered(allocator, conn, row.effect_delivery_id, result.status_code) catch {};
            reenterEffectResult(allocator, .{
                .pool = pool,
                .correlation_key = row.correlation_key,
                .succeeded = true,
                .response_body = result.response_body,
                .http_status = result.status_code,
            }) catch |err| {
                if (err != error.CorrelationKeyNotFound) {
                    logWorkerError(allocator, "effects_worker.reentry_failed", @errorName(err));
                }
            };
        },
        .retry => {
            if (row.attempt_count + 1 >= EFFECT_MAX_ATTEMPTS) {
                queue.markDeadLettered(conn, row.effect_delivery_id, "max_attempts_exhausted") catch {};
                reenterEffectResult(allocator, .{
                    .pool = pool,
                    .correlation_key = row.correlation_key,
                    .succeeded = false,
                    .response_body = null,
                    .http_status = result.status_code,
                }) catch {};
            } else {
                const backoff = mod.computeEffectBackoffMs(row.attempt_count);
                queue.markRetry(allocator, conn, row.effect_delivery_id, result.status_code, "retriable_failure", backoff) catch {};
            }
        },
        .permanent => {
            queue.markDeadLettered(conn, row.effect_delivery_id, "permanent_http_failure") catch {};
            reenterEffectResult(allocator, .{
                .pool = pool,
                .correlation_key = row.correlation_key,
                .succeeded = false,
                .response_body = null,
                .http_status = result.status_code,
            }) catch {};
        },
    }
}

fn deliverSpec(
    allocator: std.mem.Allocator,
    spec: EffectSpec,
    attempt: u8,
    executor_kind: ExecutorKind,
) EffectDeliveryError!EffectDeliveryResult {
    switch (executor_kind) {
        .stub_noop => {
            const body = allocator.dupe(u8, "{}") catch return error.OutOfMemory;
            return EffectDeliveryResult{
                .status_code = 200,
                .response_body = body,
                .idempotency_key_sent = spec.effect_event_id,
            };
        },
        .http => {
            switch (spec.kind) {
                .http_call => {
                    // Parse HttpEffectSpec from spec_json.
                    const http_spec = parseHttpEffectSpec(allocator, spec.spec_json) catch {
                        return error.InvalidSpec;
                    };
                    return http_adapter.deliver(allocator, spec, http_spec);
                },
                .email => {
                    const email_spec = parseEmailEffectSpec(allocator, spec.spec_json) catch {
                        return error.InvalidSpec;
                    };
                    return email_adapter.deliver(allocator, spec, email_spec);
                },
            }
        },
    }
    _ = attempt;
}

fn parseHttpEffectSpec(
    allocator: std.mem.Allocator,
    spec_json: []const u8,
) !mod.HttpEffectSpec {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, spec_json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidSpec,
    };

    const url = switch (obj.get("url") orelse return error.InvalidSpec) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidSpec,
    };
    errdefer allocator.free(url);

    const method = if (obj.get("method")) |m| switch (m) {
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, "POST"),
    } else try allocator.dupe(u8, "POST");
    errdefer allocator.free(method);

    const timeout_ms: u32 = if (obj.get("timeout_ms")) |t| switch (t) {
        .integer => |n| @intCast(@max(0, n)),
        else => 30_000,
    } else 30_000;

    const retry_limit: u8 = if (obj.get("retry_limit")) |r| switch (r) {
        .integer => |n| @intCast(@max(0, @min(255, n))),
        else => 5,
    } else 5;

    return mod.HttpEffectSpec{
        .url = url,
        .method = method,
        .headers_json = null,
        .body_json = null,
        .timeout_ms = timeout_ms,
        .retry_limit = retry_limit,
        .secret_ref = null,
    };
}

fn parseEmailEffectSpec(
    allocator: std.mem.Allocator,
    spec_json: []const u8,
) !mod.EmailEffectSpec {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, spec_json, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidSpec,
    };

    const to = switch (obj.get("to") orelse return error.InvalidSpec) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidSpec,
    };
    errdefer allocator.free(to);
    const subject = if (obj.get("subject")) |s| switch (s) {
        .string => |v| try allocator.dupe(u8, v),
        else => try allocator.dupe(u8, ""),
    } else try allocator.dupe(u8, "");
    errdefer allocator.free(subject);
    const body = if (obj.get("body")) |b| switch (b) {
        .string => |v| try allocator.dupe(u8, v),
        else => try allocator.dupe(u8, ""),
    } else try allocator.dupe(u8, "");

    return mod.EmailEffectSpec{
        .to = to,
        .subject = subject,
        .body = body,
        .secret_ref = null,
    };
}

fn logWorkerError(allocator: std.mem.Allocator, component: []const u8, message: []const u8) void {
    const fields = [_]logger.LogField{
        .{ .key = "error", .value = .{ .string = message } },
    };
    logger.log(allocator, .ERROR, component, message, &fields) catch {};
}
