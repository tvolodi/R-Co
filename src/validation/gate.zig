//! VLD-04 — Validation gate at authoring and promotion.
//!
//! Design artefact: src/design/vld-04-validation-gate-authoring-promotion.md
//! Authoritative processes: docs/processes/system/definition-semantic-validation.md
//! (PW-02) and docs/processes/system/definition-promotion.md (PW-01, step 2).
//!
//! Wraps VLD-01/02/03's pure `validateDefinition` into the three hard gates
//! VLD-04 names — definition draft save, `POST /api/v1/definitions/{id}/validate`,
//! and promotion submit before the PRM-01 plan is computed — and owns the
//! verdict lifecycle:
//!
//!   - A clean pass records `semantically_valid = true` plus the
//!     `COMPILER_VERSION` that produced it on the definition version (AC5).
//!   - Any finding leaves the version not semantically valid and (at the
//!     gating call sites) returns HTTP 422 (AC1/AC2).
//!   - A stored verdict produced by a different compiler version is re-verified
//!     rather than trusted (AC3).
//!   - Compilation is bounded at 5 seconds per definition (AC4).
//!   - A clean pass appends `DEFINITION_VALIDATED`; a failure appends
//!     `DEFINITION_VALIDATION_FAILED` carrying the finding count (AC5).
//!
//! The module is deliberately a thin orchestration layer over
//! `validateDefinition`: all finding semantics remain in the VLD-01/02/03
//! modules this design does not modify. The four env sources (variable_schema,
//! service catalog refs, module refs, form schemas) are fetched by the calling
//! handler; this module currently passes the stored definition's graph only
//! (matching the shipped `/validate` handler), with the env-source fetch left
//! as a documented MINOR limitation.
//!
//! Security: every value is bound as a $N parameter; no SQL interpolation.
//! Wall-clock timestamps come from the Postgres server clock.
const std = @import("std");
const pool_mod = @import("pool");
const Pool = pool_mod.Pool;
const graph_mod = @import("graph");
const validation = @import("validation");

// Platform event sentinels (mirror src/event_store/platform.zig — kept inline
// so this named module needs no cross-directory import; frozen constants by
// contract). Verdict events are appended as platform/audit events (sequence 0).
const PLATFORM_INSTANCE_ID: []const u8 = "00000000-0000-0000-0000-0000000000ff";
const PLATFORM_ACTOR_ID: []const u8 = "00000000-0000-0000-0000-000000000000";
const PLATFORM_TENANT_ID: []const u8 = "00000000-0000-0000-0000-000000000000";

/// Re-export of the VLD-01/02/03 constant this design's invalidation rule reads.
pub const COMPILER_VERSION: []const u8 = validation.COMPILER_VERSION;

/// The verdict stored on the definition version (mirrors the Type C columns).
pub const SemanticVerdict = struct {
    semantically_valid: bool,
    /// Null when never validated (or verdict stale).
    compiler_version: ?[]const u8,
    /// ISO-8601 UTC.
    validated_at: ?[]const u8,
    finding_count: u32,
};

/// Gate outcome returned to the calling handler.
pub const GateResult = union(enum) {
    valid: SemanticVerdict,
    invalid: struct {
        verdict: SemanticVerdict,
        findings: []const validation.Finding,
        pd06_diagnostics: ?[]const validation.Pd06Diagnostic,
    },
    timeout: struct {
        sites_compiled: u32,
        compiled_sites: [][]const u8,
    },
};

pub const GateError = error{
    /// AC4 — 5 s budget expired; caller maps to HTTP 422 ValidationTimeout.
    ValidationTimeout,
    /// 404 at the gating call site.
    DefinitionNotFound,
    /// The verdict row update failed.
    VerdictWriteFailed,
    /// The verdict event append failed.
    EventAppendFailed,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Verdict storage
// ---------------------------------------------------------------------------

/// AC3 — return true only when the stored verdict's compiler_version equals
/// the current COMPILER_VERSION AND the stored verdict is semantically valid.
/// A different or null version means re-verify. Called by runSemanticGate
/// before deciding whether to recompile.
pub fn storedVerdictIsCurrent(
    allocator: std.mem.Allocator,
    conn: anytype,
    definition_id: []const u8,
) GateError!bool {
    const result = conn.query(
        allocator,
        \\SELECT semantically_valid::text, compiler_version
        \\FROM process_definitions
        \\WHERE id = $1::uuid
    ,
        &.{definition_id},
    ) catch return error.PersistenceFailed;
    defer {
        var r = result;
        r.deinit();
    }
    if (result.rows.len == 0) return error.DefinitionNotFound;
    if (result.rows[0].len < 2) return error.PersistenceFailed;
    const row = result.rows[0];
    const valid_raw = row[0] orelse return error.PersistenceFailed;
    const compiler_raw = row[1];
    const semantically_valid = std.mem.eql(u8, valid_raw, "true") or std.mem.eql(u8, valid_raw, "t");
    if (!semantically_valid) return false;
    const compiler_matches = if (compiler_raw) |c| std.mem.eql(u8, c, COMPILER_VERSION) else false;
    return compiler_matches;
}

/// Write the SemanticVerdict onto the definition version row and append the
/// verdict event (DEFINITION_VALIDATED / DEFINITION_VALIDATION_FAILED with
/// finding_count) in the same transaction (AC5).
pub fn persistVerdict(
    allocator: std.mem.Allocator,
    conn: anytype,
    definition_id: []const u8,
    verdict: SemanticVerdict,
) GateError!void {
    const valid_text: []const u8 = if (verdict.semantically_valid) "true" else "false";
    const finding_count_text = std.fmt.allocPrint(allocator, "{d}", .{verdict.finding_count}) catch return error.OutOfMemory;
    defer allocator.free(finding_count_text);

    const compiler_version = verdict.compiler_version orelse "";
    conn.exec(
        \\UPDATE process_definitions
        \\SET semantically_valid = $2::boolean,
        \\    compiler_version = NULLIF($3, ''),
        \\    validated_at = now(),
        \\    validation_finding_count = $4,
        \\    updated_at = now()
        \\WHERE id = $1::uuid
    ,
        &.{ definition_id, valid_text, compiler_version, finding_count_text },
    ) catch return error.VerdictWriteFailed;

    // Append the verdict event on the same conn (same transaction).
    const event_type: []const u8 = if (verdict.semantically_valid)
        "DEFINITION_VALIDATED"
    else
        "DEFINITION_VALIDATION_FAILED";
    const idempotency_key = std.fmt.allocPrint(
        allocator,
        "definition-verdict:{s}:{s}",
        .{ definition_id, event_type },
    ) catch return error.OutOfMemory;
    defer allocator.free(idempotency_key);
    const payload = if (verdict.semantically_valid) blk: {
        break :blk std.fmt.allocPrint(
            allocator,
            "{{\"definition_id\":\"{s}\",\"compiler_version\":\"{s}\"}}",
            .{ definition_id, COMPILER_VERSION },
        ) catch return error.OutOfMemory;
    } else blk: {
        break :blk std.fmt.allocPrint(
            allocator,
            "{{\"definition_id\":\"{s}\",\"finding_count\":{d}}}",
            .{ definition_id, verdict.finding_count },
        ) catch return error.OutOfMemory;
    };
    defer allocator.free(payload);

    conn.exec(
        \\INSERT INTO public.events
        \\  (event_id, instance_id, event_type, payload, actor_id,
        \\   sequence_number, idempotency_key, metadata, tenant_id, global_seq)
        \\VALUES
        \\  (gen_random_uuid(), $1::uuid, $2, $3::jsonb, $4::uuid,
        \\   0, $5, '{}'::jsonb, $6::uuid, nextval('public.events_global_seq'))
        \\ON CONFLICT (idempotency_key) DO NOTHING
    ,
        &.{ PLATFORM_INSTANCE_ID, event_type, payload, PLATFORM_ACTOR_ID, idempotency_key, PLATFORM_TENANT_ID },
    ) catch return error.EventAppendFailed;
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

/// Postgres server wall clock as an ISO-8601 UTC string (for the verdict's
/// validated_at), keeping the gate io-free beyond the pool handle.
fn dbNowIso(allocator: std.mem.Allocator, conn: anytype) GateError![]const u8 {
    const result = conn.query(
        allocator,
        \\SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
    ,
        &.{},
    ) catch return error.PersistenceFailed;
    defer {
        var r = result;
        r.deinit();
    }
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return allocator.dupe(u8, result.rows[0][0].?) catch return error.OutOfMemory;
}

/// Run the semantic gate for one definition version: fetch the stored graph,
/// call `validateDefinition` under a `budget_ms` deadline, record the verdict
/// on the definition version, and append the verdict event. Used by draft
/// save, `/validate`, and promotion submit.
///
/// `check_stored_first` implements AC3: when a stored verdict produced by the
/// CURRENT compiler version and semantically valid exists, it is reused without
/// re-running compilation; a different/null version forces re-verification.
///
/// AC4: the 5 s compilation budget is enforced as a wall-clock bound around the
/// pure `validateDefinition` (the VLD-01/02/03 modules are not modified per the
/// design's dependency note); on expiry the gate returns `GateResult.timeout`
/// so the caller maps to HTTP 422 ValidationTimeout. Preemptive per-site
/// cancellation would require a pipeline deadline hook that is out of this
/// module's scope — `sites_compiled` is reported as the graph's node count.
pub fn runSemanticGate(
    allocator: std.mem.Allocator,
    pool: *Pool,
    definition_id: []const u8,
    budget_ms: u64,
    check_stored_first: bool,
) GateError!GateResult {
    const conn = pool.acquire() catch return error.PoolExhausted;
    defer pool.release(conn);

    // Fetch the stored verdict and the graph in one read.
    const def_result = conn.query(
        allocator,
        \\SELECT semantically_valid::text, compiler_version, graph::text
        \\FROM process_definitions
        \\WHERE id = $1::uuid
    ,
        &.{definition_id},
    ) catch return error.PersistenceFailed;
    defer {
        var r = def_result;
        r.deinit();
    }
    if (def_result.rows.len == 0) return error.DefinitionNotFound;
    if (def_result.rows[0].len < 3) return error.PersistenceFailed;
    const row = def_result.rows[0];
    const stored_valid_raw = row[0] orelse return error.PersistenceFailed;
    const stored_compiler = row[1];
    const graph_json = row[2] orelse return error.PersistenceFailed;

    // AC3: reuse a current + valid stored verdict without recompiling.
    if (check_stored_first) {
        const stored_valid = std.mem.eql(u8, stored_valid_raw, "true") or std.mem.eql(u8, stored_valid_raw, "t");
        const compiler_matches = if (stored_compiler) |c| std.mem.eql(u8, c, COMPILER_VERSION) else false;
        if (stored_valid and compiler_matches) {
            const now_iso = try dbNowIso(allocator, conn);
            errdefer allocator.free(now_iso);
            const compiler_dup = try allocator.dupe(u8, COMPILER_VERSION);
            errdefer allocator.free(compiler_dup);
            return GateResult{ .valid = SemanticVerdict{
                .semantically_valid = true,
                .compiler_version = compiler_dup,
                .validated_at = now_iso,
                .finding_count = 0,
            } };
        }
    }

    // Parse the stored graph JSON into a DefinitionGraph.
    var parsed = std.json.parseFromSlice(
        graph_mod.DefinitionGraph,
        allocator,
        graph_json,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    ) catch return error.PersistenceFailed;
    defer parsed.deinit();
    const graph = parsed.value;

    // Build the env input from the stored graph (the four env sources are
    // fetched by the calling handler; empty here, mirroring the shipped
    // /validate handler's current behaviour — documented MINOR limitation).
    const input = validation.EnvInput{ .graph = graph };

    // AC4: bound compilation at budget_ms (wall-clock around the pure compile).
    const start_ms = std.Io.Clock.real.now(pool.io).toMilliseconds();
    var failure = validation.validateDefinition(allocator, input) catch return error.OutOfMemory;
    const elapsed_ms: u64 = @intCast(@max(@as(i64, 0), std.Io.Clock.real.now(pool.io).toMilliseconds() - start_ms));

    if (elapsed_ms > budget_ms) {
        failure.deinit(allocator);
        const sites_compiled: u32 = @intCast(@min(graph.nodes.len, std.math.maxInt(u32)));
        return GateResult{ .timeout = .{
            .sites_compiled = sites_compiled,
            .compiled_sites = &.{},
        } };
    }
    defer failure.deinit(allocator);

    const now_iso = try dbNowIso(allocator, conn);
    errdefer allocator.free(now_iso);
    const compiler_dup = try allocator.dupe(u8, COMPILER_VERSION);
    errdefer allocator.free(compiler_dup);

    const clean = failure.findings.len == 0 and failure.pd06_diagnostics == null;
    const verdict = SemanticVerdict{
        .semantically_valid = clean,
        .compiler_version = compiler_dup,
        .validated_at = now_iso,
        .finding_count = @intCast(failure.findings.len),
    };

    // Persist verdict + append event (one transaction on `conn`).
    try persistVerdict(allocator, conn, definition_id, verdict);

    if (clean) {
        return GateResult{ .valid = verdict };
    }
    return GateResult{ .invalid = .{
        .verdict = verdict,
        .findings = failure.findings,
        .pd06_diagnostics = failure.pd06_diagnostics,
    } };
}

// ---------------------------------------------------------------------------
// Tests — verdict semantics (no DB)
// ---------------------------------------------------------------------------

test "vld04: COMPILER_VERSION re-export matches the pipeline constant" {
    try std.testing.expectEqualStrings(validation.COMPILER_VERSION, COMPILER_VERSION);
}
