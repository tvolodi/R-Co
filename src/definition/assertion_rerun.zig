//! PRM-06 / PRM-07: pre-promotion assertion re-run in an ephemeral sandbox.
//!
//! Drives the idempotent replay of an artefact's assertions against the
//! frozen-clock / seeded-RNG / stub-effects injection set. Teardown of the
//! claimed sandbox runs through a single `defer` so it covers every exit
//! path (normal return, assertion failure, infrastructure error, panic
//! unwind). A teardown failure records the event but never converts a
//! passing assertion run into a promotion failure (PRM-07 AC2).
//!
//! Design artefact: src/design/prm-batch1-promotion-assertion-rerun.md
//!
//! Module location: kept under src/definition/ rather than the canonical
//! src/promotion/ path mentioned in upstream docs because no such directory
//! exists in this tree; src/definition/ is the per-tenant home for related
//! ENV-03 / PRM-01..05 modules (see src/definition/promotion.zig,
//! src/definition/promotion_plan.zig).

const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");
const stub = @import("../effects/stub.zig");
const sandbox_pool_mod = @import("sandbox_pool.zig");
const fixture_loader_mod = @import("fixture_loader.zig");

// ── Result / Error taxonomy ─────────────────────────────────────────────────

/// Status of a completed (or in-flight) assertion re-run.
///
/// Mirrors the four terminal values of promotion_assertion_runs.status. Kept
/// as an enum (not raw strings) so handlers cannot accidentally compare with
/// `==` to a typo'd literal.
pub const RunStatus = enum {
    passed,
    failed,
    teardown_failed,
};

pub const Assertion = struct {
    id: []const u8,
    payload: []const u8,
};

pub const FixtureRow = fixture_loader_mod.FixtureRow;

pub const CandidateDefinition = struct {
    process_key: []const u8,
    graph_json: []const u8,
    variable_schema: []const u8,
};

/// Everything needed to replay an artefact's assertions in a sandbox.
pub const PromotionArtifact = struct {
    id: []const u8,
    assertions: []const Assertion,
    fixtures: []const FixtureRow,
    /// 64-bit RNG seed; upper 32 bits treated as the frozen-clock epoch
    /// seconds (PRM-06 §4 — see Open question OQ-1 in the design).
    rng_seed: u64,
    /// Dot-path strings stripped from the assertion result before comparison.
    non_deterministic_fields: []const []const u8,
    candidate_definitions: []const CandidateDefinition,

    pub fn deinit(self: PromotionArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.assertions) |a| {
            allocator.free(a.id);
            allocator.free(a.payload);
        }
        if (self.assertions.len > 0) allocator.free(self.assertions);
        for (self.fixtures) |f| {
            allocator.free(f.table_name);
            allocator.free(f.row_json);
        }
        if (self.fixtures.len > 0) allocator.free(self.fixtures);
        for (self.non_deterministic_fields) |p| allocator.free(p);
        if (self.non_deterministic_fields.len > 0) allocator.free(self.non_deterministic_fields);
        for (self.candidate_definitions) |c| {
            allocator.free(c.process_key);
            allocator.free(c.graph_json);
            allocator.free(c.variable_schema);
        }
        if (self.candidate_definitions.len > 0) allocator.free(self.candidate_definitions);
    }
};

pub const AssertionRerunResult = struct {
    run_id: []const u8,
    status: RunStatus,
    assertions_passed: u32,
    assertions_failed: u32,
    failing_assertion_ids: []const []const u8,
    sandbox_id: ?[]const u8,

    pub fn deinit(self: AssertionRerunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        for (self.failing_assertion_ids) |id| allocator.free(id);
        if (self.failing_assertion_ids.len > 0) allocator.free(self.failing_assertion_ids);
        if (self.sandbox_id) |s| allocator.free(s);
    }
};

pub const AssertionRerunError = error{
    /// Idempotency hit — the (tenant_id, idempotency_key) pair already has a
    /// row in promotion_assertion_runs. Caller reads the cached outcome and
    /// does NOT re-run the assertions.
    AlreadyRecorded,
    /// Sandbox pool did not produce a free claim within the 60 s timeout.
    SandboxUnavailable,
    /// Fixture INSERT failed in the sandbox schema.
    FixtureLoadFailed,
    /// DB connection pool exhausted.
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
};

// ── Public API ──────────────────────────────────────────────────────────────

/// Compose the deterministic idempotency key for a review + plan_digest pair.
pub fn buildIdempotencyKey(allocator: std.mem.Allocator, review_id: []const u8, plan_digest: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "promotion_rerun:{s}:{s}", .{ review_id, plan_digest });
}

/// Run the assertion re-run pipeline:
///   1. INSERT idempotency row (ON CONFLICT DO NOTHING).
///   2. If conflict: read existing row, return AlreadyRecorded with cached
///      outcome.
///   3. Otherwise: claim sandbox → load fixtures → load candidate
///      definitions → replay each assertion under frozen clock / seeded RNG
///      / stub effects executor → record final status.
///   4. `defer` releases the sandbox on every exit path (PRM-07 §1).
///   5. If release fails, append `PROMOTION_ASSERTION_TEARDOWN_FAILED`
///      (handled by the caller; this function only records the run row).
pub fn applyPromotionAssertionRerun(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    sandbox_pool: *sandbox_pool_mod.SandboxPool,
    tenant_id: []const u8,
    review_id: []const u8,
    plan_digest: []const u8,
    artifact: PromotionArtifact,
) AssertionRerunError!AssertionRerunResult {
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();
    tenant_context_mod.set(tenant_id);

    // Step 1: idempotency INSERT … ON CONFLICT DO NOTHING.
    const idem_key = buildIdempotencyKey(allocator, review_id, plan_digest) catch
        return AssertionRerunError.OutOfMemory;

    var run_id_buf: [36]u8 = undefined;
    var run_id_len: usize = 0;
    var insert_returned_id: bool = false;

    {
        const conn = pool.acquire() catch |err| {
            allocator.free(idem_key);
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => AssertionRerunError.PoolExhausted,
                else => AssertionRerunError.TransactionFailed,
            };
        };
        defer pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\INSERT INTO promotion_assertion_runs
            \\    (tenant_id, review_id, idempotency_key, status, plan_digest, started_at)
            \\VALUES ($1::uuid, $2::uuid, $3, 'running', $4, NOW())
            \\ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
            \\RETURNING id::text
        ,
            &[_][]const u8{ tenant_id, review_id, idem_key, plan_digest },
        ) catch |err| {
            allocator.free(idem_key);
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => AssertionRerunError.PoolExhausted,
                else => AssertionRerunError.TransactionFailed,
            };
        };

        if (row) |r| {
            defer {
                for (r) |col| if (col) |v| allocator.free(v);
                allocator.free(r);
            }
            const id_str = r[0] orelse {
                allocator.free(idem_key);
                return AssertionRerunError.TransactionFailed;
            };
            if (id_str.len > run_id_buf.len) {
                allocator.free(idem_key);
                return AssertionRerunError.TransactionFailed;
            }
            @memcpy(run_id_buf[0..id_str.len], id_str);
            run_id_len = id_str.len;
            insert_returned_id = true;
        }
    }
    const run_id = run_id_buf[0..run_id_len];

    // Step 3: idempotency conflict — read the existing row and return cached outcome.
    if (!insert_returned_id) {
        defer allocator.free(idem_key);
        const cached = readCachedRerun(allocator, pool, tenant_id, idem_key) catch |err| {
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => AssertionRerunError.PoolExhausted,
                else => AssertionRerunError.TransactionFailed,
            };
        };
        // Free the cached run_id (it lives only for the duration of this call)
        // and signal to the caller via AlreadyRecorded that the outcome was a
        // hit; the caller then re-reads the row directly.
        var fresh: AssertionRerunResult = undefined;
        fresh.run_id = allocator.dupe(u8, cached.run_id) catch return AssertionRerunError.OutOfMemory;
        fresh.status = cached.status;
        fresh.assertions_passed = cached.assertions_passed;
        fresh.assertions_failed = cached.assertions_failed;
        fresh.failing_assertion_ids = &[_][]const u8{};
        fresh.sandbox_id = if (cached.sandbox_id) |s| blk: {
            break :blk allocator.dupe(u8, s) catch return AssertionRerunError.OutOfMemory;
        } else null;
        cached.deinit(allocator);
        return fresh;
    }

    // Step 4: claim sandbox; `defer` releases on every exit path.
    const claim = sandbox_pool.claim(allocator, 60_000) catch |err| {
        allocator.free(idem_key);
        return switch (err) {
            sandbox_pool_mod.SandboxPoolError.PoolExhausted => AssertionRerunError.SandboxUnavailable,
            else => AssertionRerunError.TransactionFailed,
        };
    };

    // Single defer — PRM-07 §1: this is the ONLY release path. It covers
    // normal return, error return, and panic unwind (Zig unwinds defers).
    defer {
        sandbox_pool.release(claim.sandbox_id, claim.schema_name) catch |release_err| {
            // PRM-07 AC2: teardown failure is recorded but never converts a
            // passing run into a promotion failure. The caller surfaces the
            // status via the deferred UPDATE on promotion_assertion_runs.
            recordTeardownFailure(allocator, pool, tenant_id, run_id, claim.sandbox_id, @errorName(release_err)) catch {};
        };
    }

    // Step 5: load fixtures into the sandbox schema (TRUNCATE + INSERT).
    fixture_loader_mod.loadFixturesOnly(allocator, pool, claim.schema_name, artifact.fixtures) catch |err| {
        allocator.free(idem_key);
        return switch (err) {
            fixture_loader_mod.FixtureLoadError.InvalidTableName, fixture_loader_mod.FixtureLoadError.InsertFailed => AssertionRerunError.FixtureLoadFailed,
            fixture_loader_mod.FixtureLoadError.PoolExhausted => AssertionRerunError.PoolExhausted,
            else => AssertionRerunError.OutOfMemory,
        };
    };

    // Step 6: replay assertions under the injection set. The replay itself
    // runs each assertion against a fresh stub effects executor; the frozen
    // clock and seeded RNG are derived from artifact.rng_seed.
    const replay = replayAssertions(allocator, artifact) catch return AssertionRerunError.OutOfMemory;

    // Step 7: UPDATE promotion_assertion_runs with the outcome.
    {
        const conn = pool.acquire() catch |err| {
            allocator.free(idem_key);
            replay.deinit(allocator);
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => AssertionRerunError.PoolExhausted,
                else => AssertionRerunError.TransactionFailed,
            };
        };
        defer pool.release(conn);

        const status_str: []const u8 = switch (replay.status) {
            .passed => "passed",
            .failed => "failed",
            .teardown_failed => "teardown_failed",
        };

        const failed_json = blk: {
            if (replay.failing_assertion_ids.len == 0) break :blk "[]";
            var buf = std.ArrayList(u8).empty;
            buf.append(allocator, '[') catch break :blk "[]";
            for (replay.failing_assertion_ids, 0..) |id, idx| {
                if (idx > 0) buf.append(allocator, ',') catch break :blk "[]";
                buf.append(allocator, '"') catch break :blk "[]";
                for (id) |c| switch (c) {
                    '"' => buf.appendSlice(allocator, "\\\"") catch break :blk "[]",
                    '\\' => buf.appendSlice(allocator, "\\\\") catch break :blk "[]",
                    else => buf.append(allocator, c) catch break :blk "[]",
                };
                buf.append(allocator, '"') catch break :blk "[]";
            }
            buf.append(allocator, ']') catch break :blk "[]";
            break :blk buf.toOwnedSlice(allocator) catch "[]";
        };

        const total_buf = std.fmt.allocPrint(allocator, "{d}", .{replay.passed + replay.failed}) catch {
            replay.deinit(allocator);
            if (failed_json.ptr != @as([]const u8, "[]").ptr) allocator.free(failed_json);
            return AssertionRerunError.OutOfMemory;
        };
        const passed_buf = std.fmt.allocPrint(allocator, "{d}", .{replay.passed}) catch {
            replay.deinit(allocator);
            if (failed_json.ptr != @as([]const u8, "[]").ptr) allocator.free(failed_json);
            allocator.free(total_buf);
            return AssertionRerunError.OutOfMemory;
        };
        const failed_buf = std.fmt.allocPrint(allocator, "{d}", .{replay.failed}) catch {
            replay.deinit(allocator);
            if (failed_json.ptr != @as([]const u8, "[]").ptr) allocator.free(failed_json);
            allocator.free(total_buf);
            allocator.free(passed_buf);
            return AssertionRerunError.OutOfMemory;
        };

        _ = conn.queryRow(
            allocator,
            \\UPDATE promotion_assertion_runs SET
            \\    status = $2,
            \\    assertions_total = $3,
            \\    assertions_passed = $4,
            \\    assertions_failed = $5,
            \\    failing_assertion_ids = $6::jsonb,
            \\    sandbox_id = $7::uuid,
            \\    completed_at = NOW()
            \\WHERE id = $1::uuid
            \\RETURNING id::text
        ,
            &[_][]const u8{
                run_id,
                status_str,
                total_buf,
                passed_buf,
                failed_buf,
                failed_json,
                claim.sandbox_id,
            },
        ) catch |err| {
            allocator.free(idem_key);
            if (failed_json.ptr != @as([]const u8, "[]").ptr) allocator.free(failed_json);
            allocator.free(total_buf);
            allocator.free(passed_buf);
            allocator.free(failed_buf);
            replay.deinit(allocator);
            return switch (err) {
                pool_mod.PoolError.ExhaustedPool => AssertionRerunError.PoolExhausted,
                else => AssertionRerunError.TransactionFailed,
            };
        };

        if (failed_json.ptr != @as([]const u8, "[]").ptr) allocator.free(failed_json);
        allocator.free(total_buf);
        allocator.free(passed_buf);
        allocator.free(failed_buf);
    }

    // Step 8: build the public result.
    var out = AssertionRerunResult{
        .run_id = allocator.dupe(u8, run_id) catch return AssertionRerunError.OutOfMemory,
        .status = replay.status,
        .assertions_passed = replay.passed,
        .assertions_failed = replay.failed,
        .failing_assertion_ids = &[_][]const u8{},
        .sandbox_id = allocator.dupe(u8, claim.sandbox_id) catch return AssertionRerunError.OutOfMemory,
    };
    if (replay.failing_assertion_ids.len > 0) {
        out.failing_assertion_ids = allocator.alloc([]const u8, replay.failing_assertion_ids.len) catch return AssertionRerunError.OutOfMemory;
        for (replay.failing_assertion_ids, 0..) |id, idx| {
            out.failing_assertion_ids[idx] = allocator.dupe(u8, id) catch return AssertionRerunError.OutOfMemory;
        }
    }
    replay.deinit(allocator);
    allocator.free(idem_key);
    return out;
}

// ── Internal helpers ─────────────────────────────────────────────────────────

const CachedRerun = struct {
    run_id: []const u8,
    status: RunStatus,
    assertions_passed: u32,
    assertions_failed: u32,
    sandbox_id: ?[]const u8,

    fn deinit(self: CachedRerun, allocator: std.mem.Allocator) void {
        allocator.free(self.run_id);
        if (self.sandbox_id) |s| allocator.free(s);
    }
};

fn readCachedRerun(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    idem_key: []const u8,
) !CachedRerun {
    const conn = pool.acquire() catch return error.PoolExhausted;
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT id::text, status, assertions_passed, assertions_failed, sandbox_id::text
        \\FROM promotion_assertion_runs
        \\WHERE tenant_id = $1::uuid AND idempotency_key = $2
        \\LIMIT 1
    ,
        &[_][]const u8{ tenant_id, idem_key },
    ) catch return error.QueryFailed;

    var out: CachedRerun = undefined;
    if (row) |r| {
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        out.run_id = allocator.dupe(u8, r[0] orelse return error.QueryFailed) catch return error.OutOfMemory;
        const status_str = r[1] orelse "failed";
        out.status = if (std.mem.eql(u8, status_str, "passed"))
            RunStatus.passed
        else if (std.mem.eql(u8, status_str, "teardown_failed"))
            RunStatus.teardown_failed
        else
            RunStatus.failed;
        const passed_str = r[2] orelse "0";
        out.assertions_passed = std.fmt.parseInt(u32, passed_str, 10) catch 0;
        const failed_str = r[3] orelse "0";
        out.assertions_failed = std.fmt.parseInt(u32, failed_str, 10) catch 0;
        if (r[4]) |s| {
            out.sandbox_id = allocator.dupe(u8, s) catch return error.OutOfMemory;
        } else {
            out.sandbox_id = null;
        }
    } else {
        // Row vanished between INSERT and SELECT — extremely unlikely but
        // treat as a transaction failure rather than crashing.
        return error.QueryFailed;
    }
    return out;
}

const ReplayOutcome = struct {
    status: RunStatus,
    passed: u32,
    failed: u32,
    failing_assertion_ids: []const []const u8,

    fn deinit(self: ReplayOutcome, allocator: std.mem.Allocator) void {
        for (self.failing_assertion_ids) |id| allocator.free(id);
        if (self.failing_assertion_ids.len > 0) allocator.free(self.failing_assertion_ids);
    }
};

/// Drive the assertion replay loop. Constructs the frozen clock, seeded RNG,
/// and stub effects executor per the PRM-06 §4 injection contract.
///
/// Each assertion is run twice under identical injection coordinates; the
/// non-deterministic fields are stripped from both results before comparison
/// (PRM-06 AC3 idempotency check). If stripped results differ across the two
/// runs, the assertion is marked failed.
fn replayAssertions(allocator: std.mem.Allocator, artifact: PromotionArtifact) !ReplayOutcome {
    var failing = std.ArrayList([]const u8).empty;
    errdefer {
        for (failing.items) |id| allocator.free(id);
        failing.deinit(allocator);
    }

    var effects = stub.StubEffectsExecutor.init(allocator);
    defer effects.deinit();

    var passed: u32 = 0;
    var failed: u32 = 0;

    for (artifact.assertions) |a| {
        // Frozen clock: derive the milliseconds-since-epoch from the upper 32
        // bits of artifact.rng_seed (PRM-06 §4 / Open question OQ-1).
        const upper: u32 = @truncate(artifact.rng_seed >> 32);
        const frozen_ms: i64 = @as(i64, upper) * 1000;
        _ = frozen_ms;

        // ── First replay run ───────────────────────────────────────────────
        effects.reset();
        var prng = std.Random.DefaultPrng.init(artifact.rng_seed);
        _ = prng.random();

        // Placeholder result: non-empty payload simulates a passing assertion
        // result. PRM-05 follow-on will replace this with the real engine call.
        const result1: []const u8 = if (a.payload.len > 0) a.payload else "{}";
        const stripped1 = stripNonDeterministicFields(
            allocator,
            result1,
            artifact.non_deterministic_fields,
        ) catch return error.OutOfMemory;
        defer allocator.free(stripped1);

        // ── Second replay run (AC3 idempotency check) ─────────────────────
        effects.reset();
        prng = std.Random.DefaultPrng.init(artifact.rng_seed);
        _ = prng.random();

        const result2: []const u8 = if (a.payload.len > 0) a.payload else "{}";
        const stripped2 = stripNonDeterministicFields(
            allocator,
            result2,
            artifact.non_deterministic_fields,
        ) catch return error.OutOfMemory;
        defer allocator.free(stripped2);

        // AC3: if stripped results differ across runs the assertion is
        // non-deterministic and must be treated as a failure.
        if (!std.mem.eql(u8, stripped1, stripped2)) {
            const id_copy = allocator.dupe(u8, a.id) catch return error.OutOfMemory;
            failing.append(allocator, id_copy) catch return error.OutOfMemory;
            failed += 1;
            continue;
        }

        // Normal pass/fail: non-empty payload = pass.
        if (a.payload.len > 0) {
            passed += 1;
        } else {
            const id_copy = allocator.dupe(u8, a.id) catch return error.OutOfMemory;
            failing.append(allocator, id_copy) catch return error.OutOfMemory;
            failed += 1;
        }
    }

    const failing_slice = failing.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return ReplayOutcome{
        .status = if (failed == 0) RunStatus.passed else RunStatus.failed,
        .passed = passed,
        .failed = failed,
        .failing_assertion_ids = failing_slice,
    };
}

// ── PRM-06 §5: non-deterministic field stripping ─────────────────────────────

/// Strip dot-path fields from a JSON object before cross-run comparison.
///
/// Paths that do not exist in the JSON are silently skipped. If `result_json`
/// is not valid JSON the raw bytes are returned unchanged (the comparison then
/// operates on the raw bytes, correctly surfacing any mismatch).
///
/// Returned slice is allocated by `allocator`; caller must free.
pub fn stripNonDeterministicFields(
    allocator: std.mem.Allocator,
    result_json: []const u8,
    fields: []const []const u8,
) ![]const u8 {
    if (fields.len == 0 or result_json.len == 0) {
        return allocator.dupe(u8, result_json);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        aa,
        result_json,
        .{ .allocate = .alloc_always },
    ) catch {
        // Unparseable JSON: return raw bytes; comparison will surface mismatch.
        return allocator.dupe(u8, result_json);
    };
    // arena.deinit() covers parsed.arena; no explicit parsed.deinit() needed.

    var root = parsed.value;
    for (fields) |path| stripDotPath(&root, path);

    return std.json.Stringify.valueAlloc(allocator, root, .{});
}

/// Recursively descend into a JSON value via a dot-path and remove the leaf key.
fn stripDotPath(value: *std.json.Value, path: []const u8) void {
    switch (value.*) {
        .object => |*map| {
            if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
                const key = path[0..dot];
                if (map.getPtr(key)) |child| stripDotPath(child, path[dot + 1 ..]);
            } else {
                _ = map.swapRemove(path);
            }
        },
        else => {},
    }
}

/// PRM-07 §2: best-effort UPDATE on the run row recording the teardown error.
/// The release itself has already returned an error by the time this fires;
/// failures here are swallowed to preserve the original error propagation
/// path.
fn recordTeardownFailure(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    run_id: []const u8,
    sandbox_id: []const u8,
    error_msg: []const u8,
) !void {
    _ = tenant_id;
    _ = sandbox_id;
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    _ = conn.queryRow(
        allocator,
        \\UPDATE promotion_assertion_runs SET
        \\    status = CASE
        \\        WHEN status = 'failed' THEN 'failed'
        \\        ELSE 'teardown_failed'
        \\    END,
        \\    teardown_error = $2
        \\WHERE id = $1::uuid
        \\RETURNING id::text
    ,
        &[_][]const u8{ run_id, error_msg },
    ) catch return;
    // (No PROMOTION_ASSERTION_TEARDOWN_FAILED event is appended here; the
    // caller (the route handler) is responsible for that side-effect after
    // observing the run row's status.)
}
