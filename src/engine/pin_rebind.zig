//! PIN-05: Explicit Instance Pin Rebind
//!
//! POST /api/v1/instances/{id}/rebind-pins — the SOLE write path to an
//! instance's effective pin set after INSTANCE_STARTED (PIN-05 AC5). Takes
//! explicit {kind, ref, version} entries and a mandatory reason; validates
//! every named ref exists in the instance's CURRENT effective pin set
//! (PIN-04's mergeEffectivePins()) and that the instance is not terminal;
//! on success, appends INSTANCE_PINS_REBOUND carrying {ref, prior_version,
//! new_version, actor, reason} per changed entry, atomically and
//! all-or-nothing (PIN-05 AC1/AC2).
//!
//! Design artefact: src/design/pin-05-explicit-instance-pin-rebind.md
const std = @import("std");
const db = @import("pool");
const graph_mod = @import("graph");
const pin_resolver_mod = @import("pin_resolver.zig");
const reconstruction_mod = @import("reconstruction.zig");

pub const Uuid = graph_mod.Uuid;

// ---------------------------------------------------------------------------
// Public types (per the design's Public interface)
// ---------------------------------------------------------------------------

pub const RebindError = error{
    /// A requested entry's {kind, ref} has no match in the instance's current
    /// effective pin set (PIN-05 AC2). HTTP 422. No entries from the request
    /// are applied.
    UnknownPinRef,
    /// Instance status is terminal — COMPLETED, CANCELLED, or the codebase's
    /// ERROR status (the requirement text's "FAILED"; instance.zig's
    /// InstanceStatus enum has no separate FAILED variant — see this
    /// module's doc comment on isTerminalStatus() below). PIN-05 AC3. HTTP 409.
    InstanceNotRebindable,
    /// instance_id not found at all. HTTP 404.
    InstanceNotFound,
    /// Request body fails validation: empty entries[], malformed entry, or
    /// missing/empty reason (PIN-05 AC4). HTTP 422.
    InvalidInput,
    /// SELECT FOR UPDATE NOWAIT blocked by a concurrent transaction, same
    /// convention as CompleteTaskError.ConcurrentModification. HTTP 409.
    ConcurrentModification,
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
};

pub const RebindEntry = struct {
    kind: pin_resolver_mod.PinKind,
    ref: []const u8,
    version: []const u8, // the NEW version requested
};

pub const RebindInput = struct {
    instance_id: Uuid,
    entries: []const RebindEntry,
    reason: []const u8,
    actor_id: []const u8,
};

/// One changed entry as recorded in INSTANCE_PINS_REBOUND — the exact
/// per-entry shape PIN-04's mergeEffectivePins() reads back out of this
/// event's payload via reconstruction.zig's parseReboundChanges(). This
/// module is the shape's source of truth since it is the writer.
pub const RebindChange = struct {
    kind: pin_resolver_mod.PinKind,
    ref: []const u8,
    prior_version: []const u8,
    new_version: []const u8,
};

// ---------------------------------------------------------------------------
// rebindPins — Data flow Steps 1-5
// ---------------------------------------------------------------------------

/// Runs the full pipeline. Returns the changed entries on success. Any
/// RebindError means NO INSTANCE_PINS_REBOUND row is written (PIN-05 AC2's
/// "applies none of the entries" extends to every error variant here).
///
/// rebindPins() acquires and manages its own connection/transaction
/// internally (Open questions §1 of the design: this is the top-level
/// operation for its own HTTP request, unlike PIN-01's resolve() which runs
/// inside InstanceStore.create()'s larger transaction).
///
/// Security: every SQL parameter is bound as $N — no SQL string
/// interpolation. instance_id is the only tenant-scoped lookup key here;
/// instance_projections is reached via SCHEMA-mode routing (the caller's
/// request-scoped tenant_context, already set by auth middleware before this
/// function runs) exactly as every other instance.zig call site relies on —
/// no bpm_effective_tenant_id() call and no session GUC, per the INV-1 fix
/// pattern from the immediately preceding batch.
pub fn rebindPins(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    input: RebindInput,
) RebindError![]RebindChange {
    // ── Step 1: validate request body ───────────────────────────────────
    if (input.entries.len == 0) return RebindError.InvalidInput;
    if (std.mem.trim(u8, input.reason, " \t\r\n").len == 0) return RebindError.InvalidInput;
    for (input.entries) |e| {
        if (e.ref.len == 0) return RebindError.InvalidInput;
        if (e.version.len == 0) return RebindError.InvalidInput;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inst_id_hex = uuidToHex(a, input.instance_id) catch return RebindError.OutOfMemory;

    const conn = pool.acquire() catch |err| switch (err) {
        db.PoolError.ExhaustedPool => return RebindError.PoolExhausted,
        else => return RebindError.TransactionFailed,
    };
    defer pool.release(conn);

    conn.begin() catch return RebindError.TransactionFailed;
    var committed = false;
    errdefer if (!committed) {
        conn.rollback() catch {};
    };

    // ── Step 2: lock the instance row and check terminal status ────────
    // Mirrors CompleteTaskError's InstanceNotActive / ConcurrentModification
    // locked-read pattern (SELECT ... FOR UPDATE NOWAIT).
    const lock_row = conn.query(
        a,
        \\SELECT status
        \\FROM instance_projections
        \\WHERE instance_id = $1::uuid
        \\FOR UPDATE NOWAIT
    ,
        &.{inst_id_hex},
    ) catch return RebindError.ConcurrentModification;
    var mlock = lock_row;
    defer mlock.deinit();

    if (mlock.rows.len == 0) return RebindError.InstanceNotFound;
    const status_str = colGet(mlock.rows[0], 0);
    if (isTerminalStatus(status_str)) return RebindError.InstanceNotRebindable;

    // ── Step 3: compute the CURRENT effective pin set ───────────────────
    // Reuses the SAME merge logic PIN-04's GET .../pins route and PIN-03's
    // execution-time guard both call — one merge implementation, three
    // callers, so they never disagree on "what is the effective pin set
    // right now."
    const effective = reconstruction_mod.reconstructEffectivePins(allocator, pool, input.instance_id) catch |err| switch (err) {
        reconstruction_mod.ReconstructionError.InstanceNotFound => return RebindError.InstanceNotFound,
        reconstruction_mod.ReconstructionError.PoolExhausted => return RebindError.PoolExhausted,
        reconstruction_mod.ReconstructionError.OutOfMemory => return RebindError.OutOfMemory,
        else => return RebindError.TransactionFailed,
    };
    defer pin_resolver_mod.freeEffectivePins(allocator, effective);

    // ── Step 4: look up each requested entry in the effective set ──────
    // All-or-nothing: any UnknownPinRef aborts before any change list entry
    // is built, and — critically — before the transaction begun in Step 2
    // ever writes anything (the errdefer above rolls it back).
    var changes = std.ArrayList(RebindChange).empty;
    for (input.entries) |req| {
        var matched = false;
        for (effective) |ep| {
            if (ep.pin.kind != req.kind) continue;
            if (!std.mem.eql(u8, ep.pin.ref, req.ref)) continue;
            matched = true;
            changes.append(a, .{
                .kind = req.kind,
                .ref = a.dupe(u8, req.ref) catch return RebindError.OutOfMemory,
                .prior_version = a.dupe(u8, ep.pin.version) catch return RebindError.OutOfMemory,
                .new_version = a.dupe(u8, req.version) catch return RebindError.OutOfMemory,
            }) catch return RebindError.OutOfMemory;
            break;
        }
        if (!matched) return RebindError.UnknownPinRef;
    }

    // ── Step 5: append INSTANCE_PINS_REBOUND, same transaction, COMMIT ──
    const payload_json = buildReboundPayload(a, input.actor_id, input.reason, changes.items) catch
        return RebindError.OutOfMemory;

    var idem_bytes: Uuid = undefined;
    fillRandomBytes(&idem_bytes);
    idem_bytes[6] = (idem_bytes[6] & 0x0f) | 0x40;
    idem_bytes[8] = (idem_bytes[8] & 0x3f) | 0x80;
    const idem_key_hex = uuidToHex(a, idem_bytes) catch return RebindError.OutOfMemory;

    conn.exec(
        \\WITH seq AS (
        \\    INSERT INTO instance_sequence (instance_id, next_seq)
        \\    VALUES ($1::uuid, 2)
        \\    ON CONFLICT (instance_id) DO UPDATE
        \\        SET next_seq = instance_sequence.next_seq + 1
        \\    RETURNING next_seq - 1 AS val
        \\)
        \\INSERT INTO events
        \\    (instance_id, event_type, payload, actor_id,
        \\     sequence_number, idempotency_key)
        \\SELECT $1::uuid, 'INSTANCE_PINS_REBOUND', $2::jsonb, $3::uuid, seq.val, $4
        \\FROM seq
    ,
        &.{ inst_id_hex, payload_json, input.actor_id, idem_key_hex },
    ) catch return RebindError.TransactionFailed;

    conn.exec(
        \\UPDATE instance_projections
        \\SET last_event_seq = last_event_seq + 1,
        \\    updated_at     = NOW()
        \\WHERE instance_id  = $1::uuid
    ,
        &.{inst_id_hex},
    ) catch return RebindError.TransactionFailed;

    conn.commit() catch return RebindError.TransactionFailed;
    committed = true;

    // Return a caller-allocator-owned copy of the changes — `a` (the arena)
    // is freed when this function returns.
    const out = allocator.alloc(RebindChange, changes.items.len) catch return RebindError.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |c| {
            allocator.free(c.ref);
            allocator.free(c.prior_version);
            allocator.free(c.new_version);
        }
        allocator.free(out);
    }
    for (changes.items, 0..) |c, i| {
        out[i] = .{
            .kind = c.kind,
            .ref = allocator.dupe(u8, c.ref) catch return RebindError.OutOfMemory,
            .prior_version = allocator.dupe(u8, c.prior_version) catch return RebindError.OutOfMemory,
            .new_version = allocator.dupe(u8, c.new_version) catch return RebindError.OutOfMemory,
        };
        filled += 1;
    }
    return out;
}

/// Frees a []RebindChange slice returned by rebindPins().
pub fn freeRebindChanges(allocator: std.mem.Allocator, changes: []const RebindChange) void {
    for (changes) |c| {
        allocator.free(c.ref);
        allocator.free(c.prior_version);
        allocator.free(c.new_version);
    }
    allocator.free(changes);
}

/// PIN-05 AC3's terminal set. The requirement text (docs/requirements.yaml
/// PIN-05) names COMPLETED, CANCELLED, FAILED — but instance.zig's
/// InstanceStatus enum (and instance_projections.status, an unconstrained
/// TEXT column) has no FAILED value anywhere in this codebase; the
/// equivalent and only terminal-failure status actually written is ERROR
/// (src/engine/instance.zig's SetInstanceErrorArgs / EE-10). This function
/// treats the requirement's "FAILED" as this codebase's "ERROR" — flagged
/// as a MINOR naming-drift issue in this batch's handoff result rather than
/// inventing a FAILED status this codebase does not otherwise have.
fn isTerminalStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "COMPLETED") or
        std.mem.eql(u8, status, "CANCELLED") or
        std.mem.eql(u8, status, "ERROR");
}

/// Build the INSTANCE_PINS_REBOUND event payload JSON:
///   {"actor_id":"...","reason":"...","changes":[{"kind":"...","ref":"...",
///    "prior_version":"...","new_version":"..."}, ...]}
///
/// Security: all string fields are serialised through std.json.Stringify's
/// escaping — no raw concatenation of user-supplied `reason`/`ref` values
/// into the JSON literal (reason in particular is caller-supplied free text).
fn buildReboundPayload(
    allocator: std.mem.Allocator,
    actor_id: []const u8,
    reason: []const u8,
    changes: []const RebindChange,
) error{OutOfMemory}![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, "{\"actor_id\":");
    try appendJsonStr(allocator, &buf, actor_id);
    try buf.appendSlice(allocator, ",\"reason\":");
    try appendJsonStr(allocator, &buf, reason);
    try buf.appendSlice(allocator, ",\"changes\":[");
    for (changes, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"kind\":");
        try appendJsonStr(allocator, &buf, pinKindStr(c.kind));
        try buf.appendSlice(allocator, ",\"ref\":");
        try appendJsonStr(allocator, &buf, c.ref);
        try buf.appendSlice(allocator, ",\"prior_version\":");
        try appendJsonStr(allocator, &buf, c.prior_version);
        try buf.appendSlice(allocator, ",\"new_version\":");
        try appendJsonStr(allocator, &buf, c.new_version);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn appendJsonStr(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) error{OutOfMemory}!void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn pinKindStr(kind: pin_resolver_mod.PinKind) []const u8 {
    return switch (kind) {
        .catalog_entry => "catalog_entry",
        .variable_schema => "variable_schema",
        .module => "module",
    };
}

fn colGet(row: []?[]u8, i: usize) []const u8 {
    if (i >= row.len) return "";
    return row[i] orelse "";
}

fn uuidToHex(allocator: std.mem.Allocator, uuid: Uuid) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

const builtin = @import("builtin");

/// Cross-platform OS entropy — mirrors instance.zig's fillRandom() (kept
/// local rather than exported from instance.zig to avoid a new cross-module
/// dependency for a single helper).
fn fillRandomBytes(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandomBytes: unsupported OS — add a platform branch"),
    }
}

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB; rebindPins() itself is DB-bound and covered by
// integration tests instead)
// ---------------------------------------------------------------------------

test "isTerminalStatus: COMPLETED/CANCELLED/ERROR are terminal, ACTIVE is not" {
    try std.testing.expect(isTerminalStatus("COMPLETED"));
    try std.testing.expect(isTerminalStatus("CANCELLED"));
    try std.testing.expect(isTerminalStatus("ERROR"));
    try std.testing.expect(!isTerminalStatus("ACTIVE"));
    try std.testing.expect(!isTerminalStatus("RESTORED_ORPHAN"));
}

test "buildReboundPayload: escapes a reason containing a quote" {
    const changes = [_]RebindChange{
        .{ .kind = .catalog_entry, .ref = "svc-a", .prior_version = "100", .new_version = "200" },
    };
    const json = try buildReboundPayload(std.testing.allocator, "actor-1", "rollback \"bad\" release", &changes);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "rollback \\\"bad\\\" release") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"catalog_entry\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"prior_version\":\"100\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"new_version\":\"200\"") != null);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
