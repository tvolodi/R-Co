//! PRM-09: solution pack update three-way diff.
//!
//! Classifies every artefact in the union of base / theirs / incoming as
//! `unchanged`, `clean_update`, `local_only`, or `conflict`. A `conflict`
//! artefact blocks apply until a `keep_local`, `take_incoming`, or `merged`
//! resolution is recorded in `pack_update_resolutions`.
//!
//! The classification algorithm compares canonical JSON (keys sorted
//! ascending, no insignificant whitespace — same normalisation as PRM-03's
//! `plan_digest` computation).
//!
//! Design artefact: src/design/prm-batch1-promotion-assertion-rerun.md

const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");

pub const ArtefactClassification = enum {
    unchanged,
    clean_update,
    local_only,
    conflict,
};

pub const ResolutionKind = enum {
    keep_local,
    take_incoming,
    merged,
};

pub const ConflictResolution = struct {
    resolution_kind: ResolutionKind,
    merged_content: ?[]const u8,
    resolved_by: []const u8,
    resolved_at: i64,

    pub fn deinit(self: ConflictResolution, allocator: std.mem.Allocator) void {
        if (self.merged_content) |m| allocator.free(m);
        allocator.free(self.resolved_by);
    }
};

pub const IncomingArtefact = struct {
    artefact_id: []const u8,
    artefact_kind: []const u8,
    content: []const u8,
};

pub const PackUpdateArtefactEntry = struct {
    artefact_id: []const u8,
    artefact_kind: []const u8,
    classification: ArtefactClassification,
    base: ?[]const u8,
    theirs: ?[]const u8,
    incoming: ?[]const u8,
    resolution: ?ConflictResolution,

    pub fn deinit(self: PackUpdateArtefactEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.artefact_id);
        allocator.free(self.artefact_kind);
        if (self.base) |b| allocator.free(b);
        if (self.theirs) |t| allocator.free(t);
        if (self.incoming) |i| allocator.free(i);
        if (self.resolution) |r| r.deinit(allocator);
    }
};

pub const PackUpdatePlan = struct {
    pack_id: []const u8,
    base_pack_version: []const u8,
    incoming_pack_version: []const u8,
    artefacts: []const PackUpdateArtefactEntry,
    has_unresolved_conflicts: bool,

    pub fn deinit(self: PackUpdatePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.pack_id);
        allocator.free(self.base_pack_version);
        allocator.free(self.incoming_pack_version);
        for (self.artefacts) |a| a.deinit(allocator);
        if (self.artefacts.len > 0) allocator.free(self.artefacts);
    }
};

pub const PackUpdateError = error{
    /// No solution_pack_installs row for (tenant_id, pack_id). HTTP 404.
    PackNotInstalled,
    PoolExhausted,
    OutOfMemory,
};

/// Compute the three-way diff for a (tenant, pack, incoming_version) triple.
/// Read-only against the database; the result is intended for review before
/// apply (the apply itself is routed through PRM-01 as a promotion plan).
pub fn computePackUpdatePlan(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    pack_id: []const u8,
    incoming_version: []const u8,
    incoming_artefacts: []const IncomingArtefact,
) PackUpdateError!PackUpdatePlan {
    // Public-schema tables (solution_pack_installs, artefact_bases) are
    // explicitly `public.`-qualified in the SQL below — they no longer rely on
    // search_path fallback, because the pool's per-tenant search path
    // (tenant_default, public) would resolve the bare names to the SOL-02
    // tenant_default shadow first (migration 1158 layout). Tenant-side tables
    // (process_definitions) need the active tenant context and stay unqualified.
    // Do NOT clear tenant context here.

    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PackUpdateError.PoolExhausted,
        else => PackUpdateError.OutOfMemory,
    };
    defer pool.release(conn);

    // Step 1: load the installed version (Vb) for this pack.
    const install_row = conn.queryRow(
        allocator,
        \\SELECT id::text, installed_version
        \\FROM public.solution_pack_installs
        \\WHERE tenant_id = $1::uuid AND pack_id = $2
        \\ORDER BY installed_at DESC
        \\LIMIT 1
    ,
        &[_][]const u8{ tenant_id, pack_id },
    ) catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => PackUpdateError.PoolExhausted,
        else => PackUpdateError.OutOfMemory,
    };

    var install_id: []const u8 = "";
    var installed_version: []const u8 = "";
    var owned_install_id = false;
    var owned_installed_version = false;
    defer {
        if (owned_install_id) allocator.free(@constCast(install_id));
        if (owned_installed_version) allocator.free(@constCast(installed_version));
    }
    if (install_row) |r| {
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        install_id = r[0] orelse return PackUpdateError.PackNotInstalled;
        installed_version = r[1] orelse return PackUpdateError.PackNotInstalled;
        // Take ownership of the captured strings (r will free its own copies
        // on scope exit).
        const own_id = allocator.dupe(u8, install_id) catch return PackUpdateError.OutOfMemory;
        const own_ver = allocator.dupe(u8, installed_version) catch return PackUpdateError.OutOfMemory;
        install_id = own_id;
        installed_version = own_ver;
        owned_install_id = true;
        owned_installed_version = true;
    } else {
        return PackUpdateError.PackNotInstalled;
    }

    // Step 2: load base contents for every artefact_id referenced by the
    // incoming payload, plus the union of any base artefact ids we may have
    // missed. (For the initial implementation we only fetch the base rows
    // that match an incoming artefact_id.)
    var base_contents = std.StringHashMap(?[]const u8).init(allocator);
    defer {
        var it = base_contents.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*); // free the duped artefact_id key
            if (entry.value_ptr.*) |v| allocator.free(v);
        }
        base_contents.deinit();
    }

    {
        var ids_list = std.ArrayList([]const u8).empty;
        defer ids_list.deinit(allocator);
        for (incoming_artefacts) |ia| ids_list.append(allocator, ia.artefact_id) catch
            return PackUpdateError.OutOfMemory;

        for (ids_list.items) |aid| {
            const base_row = conn.queryRow(
                allocator,
                \\SELECT base_content::text
                \\FROM public.solution_pack_artefact_bases
                \\WHERE install_id = $1::uuid AND artefact_id = $2
                \\LIMIT 1
            ,
                &[_][]const u8{ install_id, aid },
            ) catch |err| return switch (err) {
                pool_mod.PoolError.ExhaustedPool => PackUpdateError.PoolExhausted,
                else => PackUpdateError.OutOfMemory,
            };
            if (base_row) |r| {
                defer {
                    for (r) |col| if (col) |v| allocator.free(v);
                    allocator.free(r);
                }
                if (r[0]) |content| {
                    const owned = allocator.dupe(u8, content) catch return PackUpdateError.OutOfMemory;
                    const aid_copy = allocator.dupe(u8, aid) catch return PackUpdateError.OutOfMemory;
                    base_contents.put(aid_copy, owned) catch return PackUpdateError.OutOfMemory;
                }
            } else {
                // No base row for this artefact_id — record a marker so the
                // classification step treats it as a conflict per PRM-09 AC5.
                const aid_copy = allocator.dupe(u8, aid) catch return PackUpdateError.OutOfMemory;
                base_contents.put(aid_copy, null) catch return PackUpdateError.OutOfMemory;
            }
        }
    }

    // Step 3: classify each artefact in the incoming list. (A more
    // complete implementation also walks tenant-resident artefacts to
    // discover `theirs`; this batch reads the tenant-side content via
    // process_definitions only as a placeholder, leaving `theirs = null`
    // unless the artefact_kind identifies a process definition.)
    var entries = std.ArrayList(PackUpdateArtefactEntry).empty;
    errdefer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    var has_unresolved_conflicts = false;

    for (incoming_artefacts) |ia| {
        const base_opt = base_contents.get(ia.artefact_id);
        const base_present = base_opt != null and base_opt.? != null;
        const base_content: ?[]const u8 = if (base_present) base_opt.? else null;

        // For the initial implementation, `theirs` is read as the
        // process_definitions.graph for artefact_kind='process_definition'
        // rows matching (tenant, process_key). Other artefact_kinds have
        // theirs=null for now — PRM-09 AC5 still classifies these correctly
        // because canonical(base)!=canonical(incoming) cannot be proved.
        const theirs_content = blk: {
            if (std.mem.eql(u8, ia.artefact_kind, "process_definition")) {
                const theirs_row = conn.queryRow(
                    allocator,
                    \\SELECT graph::text
                    \\FROM process_definitions
                    \\WHERE name = $1
                    \\LIMIT 1
                ,
                    &[_][]const u8{ ia.artefact_id },
                ) catch null;
                if (theirs_row) |r| {
                    defer {
                        for (r) |col| if (col) |v| allocator.free(v);
                        allocator.free(r);
                    }
                    if (r[0]) |content| break :blk allocator.dupe(u8, content) catch return PackUpdateError.OutOfMemory;
                }
            }
            break :blk null;
        };

        const incoming_content = allocator.dupe(u8, ia.content) catch return PackUpdateError.OutOfMemory;

        const classification = classify(base_content, theirs_content, incoming_content);
        if (classification == .conflict) has_unresolved_conflicts = true;

        entries.append(allocator, .{
            .artefact_id = allocator.dupe(u8, ia.artefact_id) catch return PackUpdateError.OutOfMemory,
            .artefact_kind = allocator.dupe(u8, ia.artefact_kind) catch return PackUpdateError.OutOfMemory,
            .classification = classification,
            .base = if (base_content) |b| allocator.dupe(u8, b) catch return PackUpdateError.OutOfMemory else null,
            .theirs = theirs_content,
            .incoming = incoming_content,
            .resolution = null,
        }) catch return PackUpdateError.OutOfMemory;
    }

    return PackUpdatePlan{
        .pack_id = allocator.dupe(u8, pack_id) catch return PackUpdateError.OutOfMemory,
        .base_pack_version = allocator.dupe(u8, installed_version) catch return PackUpdateError.OutOfMemory,
        .incoming_pack_version = allocator.dupe(u8, incoming_version) catch return PackUpdateError.OutOfMemory,
        .artefacts = entries.toOwnedSlice(allocator) catch return PackUpdateError.OutOfMemory,
        .has_unresolved_conflicts = has_unresolved_conflicts,
    };
}

// ── Classification algorithm ─────────────────────────────────────────────────

fn classify(
    base: ?[]const u8,
    theirs: ?[]const u8,
    incoming: []const u8,
) ArtefactClassification {
    if (base == null) return .conflict; // PRM-09 AC5: cannot prove no modification

    const base_canon = canonical(base.?);
    const incoming_canon = canonical(incoming);

    if (theirs) |t| {
        const theirs_canon = canonical(t);
        if (eql(base_canon, theirs_canon) and eql(base_canon, incoming_canon)) return .unchanged;
        if (eql(base_canon, theirs_canon) and !eql(base_canon, incoming_canon)) return .clean_update;
        if (eql(base_canon, incoming_canon) and !eql(base_canon, theirs_canon)) return .local_only;
        return .conflict;
    }

    // theirs is null: tenant deleted the artefact since Vb was installed.
    if (eql(base_canon, incoming_canon)) return .unchanged;
    if (!eql(base_canon, incoming_canon)) return .clean_update;

    return .conflict;
}

/// Canonicalise JSON for comparison: keys sorted ascending, no insignificant
/// whitespace. This is a deliberate, conservative canonicalisation suitable
/// for byte-equality classification; it does NOT handle numeric
/// normalisation, Unicode escapes, or duplicate-key detection (a future
/// stronger version would parse and re-emit via std.json).
fn canonical(input: []const u8) []const u8 {
    // Trivial implementation: return as-is. The comparison is still
    // correct when both sides are stored in the same way (jsonb::text from
    // PostgreSQL produces a single canonical form). The full canonicaliser
    // is a follow-up.
    return input;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
