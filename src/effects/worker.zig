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
const secrets = @import("../secrets/mod.zig");

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
    secret_wrapping_key_ref: []const u8 = "local:master",
    secret_wrapping_key_version: []const u8 = "v1",
    secret_master_key_hex: []const u8 = "0000000000000000000000000000000000000000000000000000000000000000",
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

    // ISS-0158 / GH #479: events.sequence_number is NOT NULL, and this INSERT
    // never supplied it — so EVERY effect re-entry (EFFECT_COMPLETED and
    // EFFECT_FAILED alike) failed with C23502 and rolled the transaction back.
    // Reserve the next per-instance sequence the same canonical way
    // src/event_store/store.zig does (INSERT … ON CONFLICT DO UPDATE on
    // instance_sequence), which is race-free under concurrent appends, rather
    // than SELECT MAX(sequence_number)+1.
    const seq_rows = conn.query(
        allocator,
        \\INSERT INTO instance_sequence (instance_id, next_seq)
        \\VALUES (NULLIF($1,'')::uuid, 2)
        \\ON CONFLICT (instance_id) DO UPDATE
        \\  SET next_seq = instance_sequence.next_seq + 1
        \\RETURNING next_seq - 1 AS assigned_seq
    ,
        &.{instance_id},
    ) catch return error.PersistenceFailed;
    const sequence_number: []const u8 = blk: {
        defer {
            var r = seq_rows;
            r.deinit();
        }
        if (seq_rows.rows.len == 0 or seq_rows.rows[0].len == 0) return error.PersistenceFailed;
        const v = seq_rows.rows[0][0] orelse return error.PersistenceFailed;
        // `seq_rows` owns `v`; dupe before its deinit above runs.
        break :blk allocator.dupe(u8, v) catch return error.PersistenceFailed;
    };
    defer allocator.free(sequence_number);

    conn.exec(
        \\INSERT INTO events
        \\  (instance_id, event_type, payload, actor_id, sequence_number, idempotency_key, metadata, created_at)
        \\VALUES
        \\  (NULLIF($1,'')::uuid, $2, $3::jsonb, gen_random_uuid(), $5::bigint, $4, '{}', NOW())
        \\ON CONFLICT (idempotency_key) DO NOTHING
    ,
        &.{ instance_id, event_type, payload_json, idempotency_key, sequence_number },
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
    // GH-654 / ISS-0649: the fetch connection is released BEFORE processing
    // rows, not held for the whole sweep. processRow() acquires its own
    // connection(s) per row (delivery result update, retry/DLQ marking,
    // re-entry) — nesting those inside this function's own held lease
    // silently starved the pool under a small pool_size (e.g. the
    // EffectsPoolFixture test harness's pool_size=2, where the caller
    // already holds one connection), causing every per-row pool.acquire()
    // to fail and get swallowed by `catch return`, leaving delivered rows
    // stuck at status='pending' forever with no error surfaced anywhere.
    // Same nested-acquire-under-held-lease class as GH-521/ISS-0130.
    const rows = blk: {
        const conn = pool.acquire() catch return;
        defer pool.release(conn);
        break :blk queue.fetchDueRows(allocator, conn, config.max_rows_per_cycle) catch |err| {
            logWorkerError(allocator, "effects_worker.sweep_fetch_failed", @errorName(err));
            return;
        };
    };
    defer {
        for (rows) |row| row.deinit(allocator);
        allocator.free(rows);
    }

    for (rows) |row| {
        processRow(allocator, pool, &row, executor_kind, config);
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
    config: WorkerConfig,
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
        .tenant_id = "default",
        .instance_id = row.instance_id,
        .node_id = row.node_id,
        .token_id = "",
        .correlation_key = row.correlation_key,
        .kind = kind,
        .spec_json = row.spec_json,
    };

    const result = deliverSpec(allocator, pool, spec, row.attempt_count, executor_kind, config) catch |err| {
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
    pool: *db.Pool,
    spec: EffectSpec,
    attempt: u8,
    executor_kind: ExecutorKind,
    config: WorkerConfig,
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
                    // ISS-0158 / GH #479: parseHttpEffectSpec dupes url,
                    // method, headers_json, body_json and secret_ref. Nothing
                    // freed them, so every http_call delivery leaked 2-5
                    // allocations. http_adapter.deliver only reads these
                    // fields (its result owns separately-allocated memory), so
                    // freeing after it returns is safe.
                    defer freeHttpEffectSpec(allocator, http_spec);
                    var resolved_secret: ?[]u8 = null;
                    defer if (resolved_secret) |secret| {
                        std.crypto.secureZero(u8, secret);
                        allocator.free(secret);
                    };
                    if (http_spec.secret_ref) |secret_ref| {
                        resolved_secret = resolveSecretValue(allocator, pool, config, spec.tenant_id, secret_ref, .effects_http) catch return error.SecretResolutionFailed;
                    }
                    return http_adapter.deliver(allocator, spec, http_spec, resolved_secret);
                },
                .email => {
                    const email_spec = parseEmailEffectSpec(allocator, spec.spec_json) catch {
                        return error.InvalidSpec;
                    };
                    // ISS-0158 / GH #479: same leak as the http_call arm above.
                    defer freeEmailEffectSpec(allocator, email_spec);
                    var resolved_secret: ?[]u8 = null;
                    defer if (resolved_secret) |secret| {
                        std.crypto.secureZero(u8, secret);
                        allocator.free(secret);
                    };
                    if (email_spec.secret_ref) |secret_ref| {
                        resolved_secret = resolveSecretValue(allocator, pool, config, spec.tenant_id, secret_ref, .effects_email) catch return error.SecretResolutionFailed;
                    }
                    return email_adapter.deliver(allocator, spec, email_spec, resolved_secret);
                },
            }
        },
    }
    _ = attempt;
}

/// ISS-0158 / GH #479: release everything parseHttpEffectSpec duped.
/// Every []const u8 field it returns is allocator-owned; timeout_ms and
/// retry_limit are scalars and need no teardown.
fn freeHttpEffectSpec(allocator: std.mem.Allocator, s: mod.HttpEffectSpec) void {
    allocator.free(s.url);
    allocator.free(s.method);
    if (s.headers_json) |h| allocator.free(h);
    if (s.body_json) |b| allocator.free(b);
    if (s.secret_ref) |r| allocator.free(r);
}

/// ISS-0158 / GH #479: release everything parseEmailEffectSpec duped.
fn freeEmailEffectSpec(allocator: std.mem.Allocator, s: mod.EmailEffectSpec) void {
    allocator.free(s.to);
    allocator.free(s.subject);
    allocator.free(s.body);
    if (s.secret_ref) |r| allocator.free(r);
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

    const headers_json = if (obj.get("headers_json")) |h| switch (h) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    const body_json = if (obj.get("body_json")) |b| switch (b) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;

    const secret_ref = if (obj.get("secret_ref")) |s| switch (s) {
        .string => |v| if (v.len == 0) null else try allocator.dupe(u8, v),
        .null => null,
        else => null,
    } else null;

    return mod.HttpEffectSpec{
        .url = url,
        .method = method,
        .headers_json = headers_json,
        .body_json = body_json,
        .timeout_ms = timeout_ms,
        .retry_limit = retry_limit,
        .secret_ref = secret_ref,
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

    const secret_ref = if (obj.get("secret_ref")) |s| switch (s) {
        .string => |v| if (v.len == 0) null else try allocator.dupe(u8, v),
        .null => null,
        else => null,
    } else null;

    return mod.EmailEffectSpec{
        .to = to,
        .subject = subject,
        .body = body,
        .secret_ref = secret_ref,
    };
}

fn resolveSecretValue(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    config: WorkerConfig,
    tenant_id: []const u8,
    secret_ref: []const u8,
    consumer: secrets.Consumer,
) ![]u8 {
    var store = try secrets.Store.init(allocator, pool, .{
        .wrapping_key_ref = config.secret_wrapping_key_ref,
        .wrapping_key_version = config.secret_wrapping_key_version,
        .master_key_hex = config.secret_master_key_hex,
    });
    const resolved = try store.resolveSecret(allocator, .{
        .tenant_id = tenant_id,
        .secret_ref = secret_ref,
        .consumer = consumer,
    });
    defer resolved.deinit(allocator);
    return allocator.dupe(u8, resolved.value);
}

fn logWorkerError(allocator: std.mem.Allocator, component: []const u8, message: []const u8) void {
    const fields = [_]logger.LogField{
        .{ .key = "error", .value = .{ .string = message } },
    };
    logger.log(allocator, .ERROR, component, message, &fields) catch {};
}
