//! PIN-01: Dependency Version Resolution (SCOPED: AC3, AC4, AC5 only)
//!
//! AC1 (service_catalog version resolution) and AC2 (module-ref resolution
//! against PLC-01) are explicitly OUT OF SCOPE for this batch — tracked as
//! ISS-0672 / GH-306. `service_catalog` has no version/status column and
//! PLC-01 (process module catalog) does not exist yet in this codebase.
//! Per the Step 01b validator routing, this module implements the
//! catalog_entry/module resolution branches only as far as the design's
//! explicitly-marked-provisional stopgap queries: any reference that does
//! not resolve under that degenerate reading returns UnresolvedCatalogRef /
//! UnresolvedModuleRef — never a silent no-op, never a TODO stub.
//!
//! Design artefact: src/design/pin-01-dependency-version-resolution.md
const std = @import("std");
const db = @import("pool");
const graph_mod = @import("graph");
const registry_mod = @import("../event_store/registry.zig");

pub const Uuid = graph_mod.Uuid;

// ---------------------------------------------------------------------------
// Public types (per the design's Public interface)
// ---------------------------------------------------------------------------

pub const PinKind = enum { catalog_entry, variable_schema, module };
pub const PinSource = enum { resolved, override, inherited };

pub const PinnedVersion = struct {
    kind: PinKind,
    /// service_id (catalog_entry) / definition_id (variable_schema) / module_id (module).
    ref: []const u8,
    /// Catalog row id / module version id — kind-dependent; under this
    /// batch's provisional stopgap (Open questions §1/§2 in the design doc),
    /// catalog_entry resolves to service_id itself (no real version identity
    /// exists yet) and module never resolves (PLC-01 is not built).
    resolved_id: []const u8,
    version: []const u8,
    source: PinSource,
};

// ---------------------------------------------------------------------------
// PIN-04 / PIN-05 shared types (src/design/pin-04-pin-resolution-on-replay-
// and-sub-processes.md Public interface, src/design/pin-05-explicit-
// instance-pin-rebind.md Public interface §RebindChange).
//
// Placed here (not in instance.zig or reconstruction.zig) because both PIN-04
// (reconstruction.zig's mergeEffectivePins() caller) and PIN-05
// (pin_rebind.zig's rebindPins(), which also calls mergeEffectivePins()) need
// the SAME EffectivePin/RebindEventRow shapes — this module is the one both
// already depend on for PinnedVersion/PinKind.
// ---------------------------------------------------------------------------

/// A pin entry merged with its source event id — the shape GET .../pins
/// (PIN-04 AC4) and PIN-03's execution-time lookup both consume.
pub const EffectivePin = struct {
    pin: PinnedVersion,
    /// The events.event_id (text form) of the INSTANCE_STARTED or
    /// INSTANCE_PINS_REBOUND row this entry's CURRENT version came from.
    source_event_id: []const u8,
};

/// One INSTANCE_PINS_REBOUND event row, as read back from the event log for
/// mergeEffectivePins() to fold into the base INSTANCE_STARTED set.
/// PIN-05 (src/engine/pin_rebind.zig) is the writer of this event type; this
/// shape must stay in lockstep with PIN-05's RebindChange (PIN-05 is the
/// shape's source of truth since it is the writer).
pub const RebindEventRow = struct {
    event_id: []const u8,
    changes: []const RebindChangeEntry,
};

/// One changed entry as recorded in an INSTANCE_PINS_REBOUND payload.
pub const RebindChangeEntry = struct {
    kind: PinKind,
    ref: []const u8,
    prior_version: []const u8,
    new_version: []const u8,
};

/// Merges an INSTANCE_STARTED base set with zero or more INSTANCE_PINS_REBOUND
/// overlays (in event order), producing the effective set with per-entry
/// provenance (PIN-04 AC1/AC4). Pure function — no I/O. `rebind_events` must
/// be ordered oldest -> newest; the LAST row that touches a given {kind,ref}
/// wins (PIN-04 Data flow Step 3: "last INSTANCE_PINS_REBOUND per ref wins").
///
/// Every returned EffectivePin's .pin.ref/.resolved_id/.version and
/// .source_event_id are freshly allocator-owned dupes — callers own and must
/// free them (mirrors resolve()'s existing ownership convention for
/// PinnedVersion's string fields).
pub fn mergeEffectivePins(
    allocator: std.mem.Allocator,
    started_pins: []const PinnedVersion,
    started_event_id: []const u8,
    rebind_events: []const RebindEventRow,
) error{OutOfMemory}![]EffectivePin {
    var out = std.ArrayList(EffectivePin).empty;
    errdefer {
        for (out.items) |ep| {
            allocator.free(ep.pin.ref);
            allocator.free(ep.pin.resolved_id);
            allocator.free(ep.pin.version);
            allocator.free(ep.source_event_id);
        }
        out.deinit(allocator);
    }

    for (started_pins) |p| {
        try out.append(allocator, .{
            .pin = .{
                .kind = p.kind,
                .ref = try allocator.dupe(u8, p.ref),
                .resolved_id = try allocator.dupe(u8, p.resolved_id),
                .version = try allocator.dupe(u8, p.version),
                .source = p.source,
            },
            .source_event_id = try allocator.dupe(u8, started_event_id),
        });
    }

    // Fold each rebind row's changes in event order — the LAST row touching
    // a given {kind, ref} determines that entry's final resolved_id/version/
    // source_event_id (PIN-04 Data flow Step 3).
    for (rebind_events) |rebind| {
        for (rebind.changes) |change| {
            var found = false;
            for (out.items) |*ep| {
                if (ep.pin.kind != change.kind) continue;
                if (!std.mem.eql(u8, ep.pin.ref, change.ref)) continue;

                const new_resolved_id = try allocator.dupe(u8, change.new_version);
                const new_version = try allocator.dupe(u8, change.new_version);
                const new_source_event_id = try allocator.dupe(u8, rebind.event_id);
                allocator.free(ep.pin.resolved_id);
                allocator.free(ep.pin.version);
                allocator.free(ep.source_event_id);
                ep.pin.resolved_id = new_resolved_id;
                ep.pin.version = new_version;
                ep.pin.source = .override;
                ep.source_event_id = new_source_event_id;
                found = true;
                break;
            }
            if (!found) {
                // A rebind that named a ref not present in the base set at
                // merge time (should not happen under PIN-05's own
                // UnknownPinRef validation gate, which validates against
                // this SAME merge — defensive only). Add it so the merged
                // set stays a superset rather than silently dropping a
                // recorded rebind.
                try out.append(allocator, .{
                    .pin = .{
                        .kind = change.kind,
                        .ref = try allocator.dupe(u8, change.ref),
                        .resolved_id = try allocator.dupe(u8, change.new_version),
                        .version = try allocator.dupe(u8, change.new_version),
                        .source = .override,
                    },
                    .source_event_id = try allocator.dupe(u8, rebind.event_id),
                });
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Frees a []EffectivePin slice produced by mergeEffectivePins().
pub fn freeEffectivePins(allocator: std.mem.Allocator, pins: []const EffectivePin) void {
    for (pins) |ep| {
        allocator.free(ep.pin.ref);
        allocator.free(ep.pin.resolved_id);
        allocator.free(ep.pin.version);
        allocator.free(ep.source_event_id);
    }
    allocator.free(pins);
}

pub const ResolutionError = error{
    /// A SERVICE_TASK's service_id names no catalog entry with an active
    /// version (PIN-01 AC1). HTTP 422.
    UnresolvedCatalogRef,
    /// A module_ref semver range matches no published module version
    /// (PIN-01 AC2). HTTP 422. Always raised under this batch's scope since
    /// PLC-01 (the module catalog) does not exist yet — see Scoping note.
    UnresolvedModuleRef,
    /// Initial variables violate the resolved variable_schema version
    /// (PIN-01 AC3). HTTP 422.
    VariableSchemaViolation,
    /// pin_overrides names a version that does not exist (PIN-01 AC4). HTTP 422.
    UnresolvedPinOverride,
    PoolExhausted,
    TransactionFailed,
};

pub const ResolutionInput = struct {
    definition_id: Uuid,
    /// REWORK 1 (SECURITY-REVIEWER INV-1 fix): the requesting caller's tenant,
    /// threaded through from the live request's tenant context. Used to bind
    /// a parameterized tenant scope onto service_catalog lookups — see
    /// resolveServiceCatalogRef() below. Never sourced from a SQL-side
    /// session function (bpm_effective_tenant_id() no longer exists after
    /// the LEGACY_RLS-to-SCHEMA cutover; see GBL-116/123/130/131).
    tenant_id: Uuid,
    graph: graph_mod.DefinitionGraph, // the just-captured PD-08 snapshot's graph
    initial_variables: []const u8, // raw JSON object bytes, already object-validated
    pin_overrides: ?[]const u8, // raw JSON, optional caller-supplied {kind,ref,version}[]
};

// ---------------------------------------------------------------------------
// PinResolver
// ---------------------------------------------------------------------------

pub const PinResolver = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) PinResolver {
        return .{ .pool = pool };
    }

    /// Runs the resolution pipeline scoped to AC3 (variable_schema), AC4
    /// (pin_overrides), AC5 (deterministic ordering). Enumerates
    /// catalog_entry/module candidates from the graph (Step 2, unscoped —
    /// enumeration itself is not AC1/AC2's blocked work) and resolves them
    /// via the design's documented provisional stopgap queries; any
    /// candidate that does not resolve under that stopgap returns
    /// UnresolvedCatalogRef/UnresolvedModuleRef per the error taxonomy —
    /// never a silent no-op.
    ///
    /// Any ResolutionError means the caller MUST NOT proceed to write the
    /// instance row — no partial pin set is ever returned (PIN-01 AC4's
    /// guarantee applies to all four error variants, since none is reached
    /// after any DB write in this design).
    pub fn resolve(
        self: *PinResolver,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        input: ResolutionInput,
    ) ResolutionError![]PinnedVersion {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var pins: std.ArrayList(PinnedVersion) = .empty;
        // Free allocator-owned strings in any accumulated pins on error.
        // resolved_id/version are always allocator-owned; ref is allocator-owned only for .variable_schema.
        errdefer for (pins.items) |p| {
            if (p.kind == .variable_schema) allocator.free(p.ref);
            allocator.free(p.resolved_id);
            allocator.free(p.version);
        };

        // ── Step 2/3: catalog_entry candidates (SERVICE_TASK nodes carrying
        // service_id — the ADP-08 catalog-reference form, not "url") ───────
        for (input.graph.nodes) |node| {
            if (node.node_type != .SERVICE_TASK) continue;
            const attrs = node.attributes orelse continue;
            const service_id = extractStringField(a, attrs, "service_id") orelse continue;

            const resolved = try self.resolveServiceCatalogRef(allocator, conn, service_id, input.tenant_id);
            pins.append(a, PinnedVersion{
                .kind = .catalog_entry,
                .ref = service_id,
                .resolved_id = resolved.resolved_id,
                .version = resolved.version,
                .source = .resolved,
            }) catch return ResolutionError.TransactionFailed;
        }

        // ── Step 2/3: module candidates (SUB_PROCESS nodes carrying
        // module_ref) — always unresolved under this batch's scope, since
        // PLC-01 (the module catalog) does not exist. A SUB_PROCESS using
        // the existing child_definition_id form produces NO module
        // candidate at all (PLC-01's own "legacy nodes continue to work
        // unchanged" AC). ─────────────────────────────────────────────────
        for (input.graph.nodes) |node| {
            if (node.node_type != .SUB_PROCESS) continue;
            const attrs = node.attributes orelse continue;
            const module_id = extractStringField(a, attrs, "module_ref") orelse continue;
            // Presence of module_ref with no PLC-01 catalog to resolve
            // against is, under this batch's explicit scoping, always
            // UnresolvedModuleRef — never a silent skip.
            _ = module_id;
            return ResolutionError.UnresolvedModuleRef;
        }

        // ── Step 3/4: variable_schema candidate — ALWAYS present exactly
        // once, and ALWAYS resolves (a definition with zero variable_schemas
        // rows still has a well-defined, empty-set hash). ──────────────────
        const vs_pin = try self.resolveVariableSchemaVersion(allocator, conn, input.definition_id);
        pins.append(a, vs_pin) catch return ResolutionError.TransactionFailed;

        // ── Step 4: validate initial_variables against the resolved
        // variable_schema rows. ─────────────────────────────────────────────
        try self.validateVariableSchema(allocator, conn, input.definition_id, input.initial_variables);

        // ── Step 5: apply pin_overrides, if supplied. ───────────────────────
        if (input.pin_overrides) |overrides_json| {
            try self.applyPinOverrides(allocator, conn, pins.items, overrides_json, input.tenant_id);
        }

        // ── Step 6: deterministic ordering — sort by (kind, ref) (PIN-01
        // AC5: byte-identical payloads across two starts of the same
        // definition against the same catalog). ────────────────────────────
        const owned = allocator.alloc(PinnedVersion, pins.items.len) catch return ResolutionError.TransactionFailed;
        var i: usize = 0;
        errdefer {
            for (owned[0..i]) |p| {
                allocator.free(p.ref);
                allocator.free(p.resolved_id);
                allocator.free(p.version);
            }
            allocator.free(owned);
        }
        while (i < pins.items.len) : (i += 1) {
            const src = pins.items[i];
            owned[i] = PinnedVersion{
                .kind = src.kind,
                .ref = allocator.dupe(u8, src.ref) catch return ResolutionError.TransactionFailed,
                .resolved_id = allocator.dupe(u8, src.resolved_id) catch return ResolutionError.TransactionFailed,
                .version = allocator.dupe(u8, src.version) catch return ResolutionError.TransactionFailed,
                .source = src.source,
            };
            // Pre-existing leak fix (surfaced by the REWORK 1 regression test,
            // the first test to exercise resolve()'s success-return path
            // against real Postgres with leak detection): src.resolved_id and
            // src.version are always `allocator`-owned (returned by
            // resolveServiceCatalogRef()/resolveVariableSchemaVersion(), both
            // called with `allocator` above, never the arena `a`), so they
            // must be freed now that owned[i] holds its own dupe. src.ref is
            // NOT freed here: for .catalog_entry it aliases `service_id`,
            // which is arena-allocated (extractStringField() used `a`) and
            // freed by `arena.deinit()`; for .variable_schema it IS
            // `allocator`-owned (resolveVariableSchemaVersion() also builds
            // .ref with `allocator`) — freeing it unconditionally here would
            // double-free the catalog_entry case, so only free it for the
            // kind that actually owns it via `allocator`.
            if (src.kind == .variable_schema) allocator.free(src.ref);
            allocator.free(src.resolved_id);
            allocator.free(src.version);
        }

        std.mem.sort(PinnedVersion, owned, {}, pinLessThan);
        return owned;
    }

    // -----------------------------------------------------------------------
    // Service catalog resolution (catalog_entry branch) — provisional
    // stopgap query per Scoping note §1: no version/status column exists on
    // service_catalog, so a resolving row is treated as its own single
    // implicit "active version" (interpretation (b) in the design's Open
    // questions §1).
    //
    // REWORK 1 (SECURITY-REVIEWER INV-1 fix): tenant scope is bound as a
    // parameterized $2::uuid against service_catalog.owner_tenant_id, NOT
    // via the dropped bpm_effective_tenant_id() SQL function (removed by the
    // LEGACY_RLS-to-SCHEMA cutover migrations GBL-116/123/130/131) and NOT
    // via a session GUC (SCHEMA mode never sets bpm.tenant_id — see
    // src/db/pool.zig applyRequestStorageRouting()). service_catalog lives
    // in the shared `public` schema in both storage modes, so this bound
    // predicate is the only correct tenant scope here. Mirrors
    // src/repository/service_catalog.zig getServiceForTenant() exactly.
    // -----------------------------------------------------------------------
    fn resolveServiceCatalogRef(
        self: *PinResolver,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        service_id: []const u8,
        tenant_id: Uuid,
    ) ResolutionError!struct { resolved_id: []const u8, version: []const u8 } {
        _ = self;
        const tenant_id_hex = uuidToHex(allocator, tenant_id) catch return ResolutionError.TransactionFailed;
        defer allocator.free(tenant_id_hex);

        const row = conn.queryRow(
            allocator,
            \\SELECT service_id, (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM service_catalog
            \\WHERE service_id = $1
            \\  AND (scope = 'global' OR owner_tenant_id = $2::uuid)
        ,
            &.{ service_id, tenant_id_hex },
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ResolutionError.PoolExhausted,
            else => return ResolutionError.TransactionFailed,
        };
        if (row == null) return ResolutionError.UnresolvedCatalogRef;
        const r = row.?;
        defer {
            for (r) |c| if (c) |v| allocator.free(v);
            allocator.free(r);
        }
        if (r.len < 2 or r[0] == null) return ResolutionError.UnresolvedCatalogRef;

        const resolved_id = allocator.dupe(u8, r[0].?) catch return ResolutionError.TransactionFailed;
        // No real version identity exists yet (Scoping note §1) — the
        // updated_at-derived value is used as a stable, deterministic
        // "version" string for this degenerate single-version-per-service
        // reading, so PIN-01 AC5's byte-identical-payload guarantee still
        // holds across two starts against the same unchanged catalog row.
        const version = if (r.len > 1 and r[1] != null)
            (allocator.dupe(u8, r[1].?) catch return ResolutionError.TransactionFailed)
        else
            (allocator.dupe(u8, "0") catch return ResolutionError.TransactionFailed);

        return .{ .resolved_id = resolved_id, .version = version };
    }

    // -----------------------------------------------------------------------
    // Variable schema version resolution (implementable today) — PIN-01's
    // "variable_schema version" pin is a single logical version identifier
    // for the WHOLE SET of a definition's per-key schemas as they exist at
    // instance-start time (a content hash), not a version of any individual
    // key's schema.
    // -----------------------------------------------------------------------
    fn resolveVariableSchemaVersion(
        self: *PinResolver,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        definition_id: Uuid,
    ) ResolutionError!PinnedVersion {
        _ = self;
        const def_hex = uuidToHex(allocator, definition_id) catch return ResolutionError.TransactionFailed;
        defer allocator.free(def_hex);

        var rows = conn.query(
            allocator,
            \\SELECT variable_key, json_schema
            \\FROM variable_schemas
            \\WHERE definition_id = $1::uuid
            \\ORDER BY variable_key ASC
        ,
            &.{def_hex},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ResolutionError.PoolExhausted,
            else => return ResolutionError.TransactionFailed,
        };
        defer rows.deinit();

        // Deterministic, order-independent-with-respect-to-nothing-but-row-
        // content hash: SHA-256 over the ordered (variable_key, json_schema)
        // pairs. Rows are already ORDER BY variable_key ASC, so two
        // definitions with identical row sets hash identically regardless of
        // insertion order (PIN-01 AC5).
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (rows.rows) |row| {
            const key = if (row.len > 0) (row[0] orelse "") else "";
            const schema = if (row.len > 1) (row[1] orelse "") else "";
            hasher.update(key);
            hasher.update(&[_]u8{0}); // field separator, avoids ("ab","c") == ("a","bc") collisions
            hasher.update(schema);
            hasher.update(&[_]u8{0});
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const version_hex = std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&digest, .lower)}) catch
            return ResolutionError.TransactionFailed;

        const ref = uuidToHex(allocator, definition_id) catch return ResolutionError.TransactionFailed;
        const resolved_id = allocator.dupe(u8, ref) catch return ResolutionError.TransactionFailed;

        return PinnedVersion{
            .kind = .variable_schema,
            .ref = ref,
            .resolved_id = resolved_id,
            .version = version_hex,
            .source = .resolved,
        };
    }

    /// PIN-01 AC3: validate initial_variables against every variable_schemas
    /// row for definition_id. Any failing field -> VariableSchemaViolation
    /// listing each failing field (a list, not first-failure short-circuit,
    /// per PIN-01 AC3's exact "listing each failing field" text). Reuses
    /// registry.validatePayloadAgainstSchema() — the same JSON Schema
    /// validation primitive ES-05 already uses — rather than a second engine.
    fn validateVariableSchema(
        self: *PinResolver,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        definition_id: Uuid,
        initial_variables: []const u8,
    ) ResolutionError!void {
        _ = self;
        const def_hex = uuidToHex(allocator, definition_id) catch return ResolutionError.TransactionFailed;
        defer allocator.free(def_hex);

        var rows = conn.query(
            allocator,
            \\SELECT variable_key, json_schema
            \\FROM variable_schemas
            \\WHERE definition_id = $1::uuid
            \\ORDER BY variable_key ASC
        ,
            &.{def_hex},
        ) catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ResolutionError.PoolExhausted,
            else => return ResolutionError.TransactionFailed,
        };
        defer rows.deinit();

        if (rows.rows.len == 0) return; // no registered schemas: nothing to violate

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            initial_variables,
            .{ .allocate = .alloc_always },
        ) catch return ResolutionError.VariableSchemaViolation;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return ResolutionError.VariableSchemaViolation,
        };

        var any_violation = false;
        for (rows.rows) |row| {
            const key = if (row.len > 0) (row[0] orelse "") else "";
            const schema_text = if (row.len > 1) (row[1] orelse "{}") else "{}";
            if (key.len == 0) continue;

            const value = obj.get(key) orelse continue; // Open questions §5: absence is not itself a violation under this design's conservative reading

            // ISS-0679 / GH-721: registry.validatePayloadAgainstSchema()'s
            // contract requires its `payload` argument to be a JSON OBJECT
            // (isJsonObject() guards on a leading '{') — it validates a whole
            // event/instance payload object against a whole schema document,
            // never a single scalar field against a single field schema. Each
            // variable_schemas row here is scoped to ONE variable key, whose
            // value is frequently a bare JSON scalar (e.g. `5`, `"x"`, `true`),
            // which can never satisfy isJsonObject() — every conforming
            // scalar-valued variable was therefore rejected unconditionally.
            // Fix: wrap both sides in a synthetic single-key/single-property
            // object before delegating to the existing validator, so its
            // isJsonObject() guard is always satisfied and the real
            // constraint checking (type/required/enum/minimum/etc., applied
            // to the wrapped property) is unchanged.
            var wrapped_value_obj = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
                return ResolutionError.TransactionFailed;
            defer wrapped_value_obj.deinit(allocator);
            wrapped_value_obj.put(allocator, key, value) catch
                return ResolutionError.TransactionFailed;
            const wrapped_value_json = std.json.Stringify.valueAlloc(
                allocator,
                std.json.Value{ .object = wrapped_value_obj },
                .{},
            ) catch return ResolutionError.TransactionFailed;
            defer allocator.free(wrapped_value_json);

            var parsed_field_schema = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                schema_text,
                .{},
            ) catch {
                // A stored schema that no longer parses is a registry-
                // integrity fault, not a caller error — matches
                // validatePayloadAgainstSchema()'s own InvalidJsonSchema
                // handling for this exact condition.
                return ResolutionError.TransactionFailed;
            };
            defer parsed_field_schema.deinit();

            var wrapped_props_obj = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
                return ResolutionError.TransactionFailed;
            defer wrapped_props_obj.deinit(allocator);
            wrapped_props_obj.put(allocator, key, parsed_field_schema.value) catch
                return ResolutionError.TransactionFailed;

            var wrapped_schema_obj = std.json.ObjectMap.init(allocator, &.{}, &.{}) catch
                return ResolutionError.TransactionFailed;
            defer wrapped_schema_obj.deinit(allocator);
            wrapped_schema_obj.put(allocator, "type", std.json.Value{ .string = "object" }) catch
                return ResolutionError.TransactionFailed;
            wrapped_schema_obj.put(allocator, "properties", std.json.Value{ .object = wrapped_props_obj }) catch
                return ResolutionError.TransactionFailed;

            const wrapped_schema_json = std.json.Stringify.valueAlloc(
                allocator,
                std.json.Value{ .object = wrapped_schema_obj },
                .{},
            ) catch return ResolutionError.TransactionFailed;
            defer allocator.free(wrapped_schema_json);

            var failures = registry_mod.validatePayloadAgainstSchema(allocator, wrapped_schema_json, wrapped_value_json) catch |err| switch (err) {
                registry_mod.RegistryError.PoolExhausted => return ResolutionError.PoolExhausted,
                else => return ResolutionError.TransactionFailed,
            };
            defer {
                registry_mod.freeFailures(allocator, failures.items);
                failures.deinit(allocator);
            }
            if (failures.items.len > 0) any_violation = true;
        }

        if (any_violation) return ResolutionError.VariableSchemaViolation;
    }

    /// PIN-01 AC4: apply pin_overrides, if supplied. Any override target not
    /// found -> UnresolvedPinOverride, aborting resolution entirely (no
    /// partial pin set — none of the other already-resolved entries are kept
    /// either).
    fn applyPinOverrides(
        self: *PinResolver,
        allocator: std.mem.Allocator,
        conn: *db.Conn,
        pins: []PinnedVersion,
        overrides_json: []const u8,
        tenant_id: Uuid,
    ) ResolutionError!void {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            overrides_json,
            .{ .allocate = .alloc_always },
        ) catch return ResolutionError.UnresolvedPinOverride;
        defer parsed.deinit();
        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return ResolutionError.UnresolvedPinOverride,
        };

        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => return ResolutionError.UnresolvedPinOverride,
            };
            const kind_str = jsonStringField(obj, "kind") orelse return ResolutionError.UnresolvedPinOverride;
            const ref = jsonStringField(obj, "ref") orelse return ResolutionError.UnresolvedPinOverride;
            const version = jsonStringField(obj, "version") orelse return ResolutionError.UnresolvedPinOverride;

            const kind: PinKind = if (std.mem.eql(u8, kind_str, "catalog_entry"))
                .catalog_entry
            else if (std.mem.eql(u8, kind_str, "module"))
                .module
            else if (std.mem.eql(u8, kind_str, "variable_schema"))
                .variable_schema
            else
                return ResolutionError.UnresolvedPinOverride;

            // module overrides: PLC-01 does not exist under this batch's
            // scope, so a module override can never verify — UnresolvedPinOverride.
            if (kind == .module) return ResolutionError.UnresolvedPinOverride;

            switch (kind) {
                .catalog_entry => {
                    // Degenerate form (Scoping note §1): only the row's own
                    // implicit "version" (updated_at-derived) can ever match.
                    const resolved = self.resolveServiceCatalogRef(allocator, conn, ref, tenant_id) catch
                        return ResolutionError.UnresolvedPinOverride;
                    // resolved.resolved_id/.version are allocator-owned
                    // (dupe'd inside resolveServiceCatalogRef() with
                    // `allocator`) and are ALWAYS this call's own copies to
                    // free, regardless of match outcome — applyOverrideToPins()
                    // takes its own dupe when it stores into the pin (see
                    // ISS-0683: it must never store a pointer this scope
                    // frees).
                    defer allocator.free(resolved.resolved_id);
                    defer allocator.free(resolved.version);
                    if (!std.mem.eql(u8, resolved.version, version)) {
                        return ResolutionError.UnresolvedPinOverride;
                    }
                    if (!applyOverrideToPins(allocator, pins, .catalog_entry, ref, resolved.resolved_id, resolved.version)) {
                        return ResolutionError.UnresolvedPinOverride;
                    }
                },
                .variable_schema => {
                    // No real version history exists for the content hash
                    // (design doc Open questions §4) — an override is only
                    // ever valid if it names the CURRENT computed hash.
                    const current = self.resolveVariableSchemaVersion(allocator, conn, parseDefinitionIdFromRef(ref) catch
                        return ResolutionError.UnresolvedPinOverride) catch
                        return ResolutionError.UnresolvedPinOverride;
                    // current.ref/.resolved_id/.version are all
                    // allocator-owned (resolveVariableSchemaVersion() builds
                    // them all with `allocator`) and are this call's own
                    // copies to free — applyOverrideToPins() dupes what it
                    // needs before storing (ISS-0683).
                    defer allocator.free(current.ref);
                    defer allocator.free(current.resolved_id);
                    defer allocator.free(current.version);
                    if (!std.mem.eql(u8, current.version, version)) {
                        return ResolutionError.UnresolvedPinOverride;
                    }
                    if (!applyOverrideToPins(allocator, pins, .variable_schema, ref, current.resolved_id, current.version)) {
                        return ResolutionError.UnresolvedPinOverride;
                    }
                },
                .module => unreachable, // handled above
            }
        }
    }
};

/// Applies an override's resolved_id/version onto the matching pin.
///
/// ISS-0683 fix: `resolved_id`/`version` here are the CALLER's own
/// allocator-owned copies (freed by the caller's own `defer` regardless of
/// whether a match is found) — this function must never store those
/// pointers directly into the long-lived `pins` slice, since resolve()'s
/// Step 6 success-path cleanup loop unconditionally frees every pin's
/// `.resolved_id`/`.version` via `allocator`, and storing an alias the
/// caller ALSO frees would double-free it. Instead: `allocator.dupe()` a
/// fresh copy for the pin, and free the pin's OLD `.resolved_id`/`.version`
/// (both allocator-owned already, set by the earlier resolve() steps)
/// before overwriting — mirroring the dupe-then-free pattern resolve()'s own
/// Step 6 loop already uses for the non-override path.
fn applyOverrideToPins(allocator: std.mem.Allocator, pins: []PinnedVersion, kind: PinKind, ref: []const u8, resolved_id: []const u8, version: []const u8) bool {
    for (pins) |*p| {
        if (p.kind == kind and std.mem.eql(u8, p.ref, ref)) {
            const new_resolved_id = allocator.dupe(u8, resolved_id) catch return false;
            const new_version = allocator.dupe(u8, version) catch {
                allocator.free(new_resolved_id);
                return false;
            };
            allocator.free(p.resolved_id);
            allocator.free(p.version);
            p.resolved_id = new_resolved_id;
            p.version = new_version;
            p.source = .override;
            return true;
        }
    }
    return false;
}

fn parseDefinitionIdFromRef(ref: []const u8) error{InvalidUuid}!Uuid {
    return parseUuid(ref);
}

fn pinLessThan(_: void, a: PinnedVersion, b: PinnedVersion) bool {
    const a_kind: u8 = @intFromEnum(a.kind);
    const b_kind: u8 = @intFromEnum(b.kind);
    if (a_kind != b_kind) return a_kind < b_kind;
    return std.mem.order(u8, a.ref, b.ref) == .lt;
}

/// PIN-03: looks up `ref` (a service_id or module_ref string) in `pins`, the
/// current instance's effective pin set. Returns the matching PinnedVersion
/// or null. Pure function — no I/O, no allocation beyond what pins/ref
/// already own. Called from the SERVICE_TASK/SUB_PROCESS completion loop
/// immediately before the existing parseConfigFromNodeAttributes()/module-
/// resolution call (src/design/pin-03-no-fallback-to-latest-version.md
/// Public interface).
pub fn findPinForRef(
    pins: []const PinnedVersion,
    kind: PinKind,
    ref: []const u8,
) ?PinnedVersion {
    for (pins) |p| {
        if (p.kind == kind and std.mem.eql(u8, p.ref, ref)) return p;
    }
    return null;
}

/// Same lookup as findPinForRef(), against a []EffectivePin slice (PIN-04's
/// merged, provenance-tagged set) instead of a raw []PinnedVersion — the
/// shape processServiceTaskRuntimeInTx()'s PIN-03 guard actually holds,
/// since it fetches the pin set via reconstructEffectivePins(). Avoids
/// forcing every EffectivePin caller to first unwrap to []PinnedVersion just
/// to call findPinForRef().
pub fn findEffectivePinForRef(
    pins: []const EffectivePin,
    kind: PinKind,
    ref: []const u8,
) ?PinnedVersion {
    for (pins) |ep| {
        if (ep.pin.kind == kind and std.mem.eql(u8, ep.pin.ref, ref)) return ep.pin;
    }
    return null;
}

/// Extract a top-level string field from a raw JSON object string, or null
/// if absent/not a string. Mirrors the attribute-parsing convention already
/// used by service_task.zig / instance.zig's parseAssigneeFields.
pub fn extractStringField(allocator: std.mem.Allocator, json_text: []const u8, field: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get(field) orelse return null;
    return switch (val) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

fn jsonStringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const val = obj.get(field) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
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

fn parseUuid(hex: []const u8) error{InvalidUuid}!Uuid {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: Uuid = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len) return error.InvalidUuid;
        const hi = hexNibble(hex[i]) catch return error.InvalidUuid;
        const lo = hexNibble(hex[i + 1]) catch return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexNibble(c: u8) error{InvalidUuid}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidUuid,
    };
}

// ---------------------------------------------------------------------------
// Unit tests (pure — no DB; resolve()/resolveServiceCatalogRef()/etc. are
// DB-bound and covered by integration tests instead)
// ---------------------------------------------------------------------------

test "pinLessThan: orders by kind then ref" {
    const a = PinnedVersion{ .kind = .catalog_entry, .ref = "svc-a", .resolved_id = "x", .version = "1", .source = .resolved };
    const b = PinnedVersion{ .kind = .catalog_entry, .ref = "svc-b", .resolved_id = "x", .version = "1", .source = .resolved };
    try std.testing.expect(pinLessThan({}, a, b));
    try std.testing.expect(!pinLessThan({}, b, a));

    const c = PinnedVersion{ .kind = .variable_schema, .ref = "def-1", .resolved_id = "x", .version = "1", .source = .resolved };
    // catalog_entry (0) < variable_schema (1)
    try std.testing.expect(pinLessThan({}, a, c));
}

test "extractStringField: reads a top-level string field" {
    const json = "{\"service_id\":\"svc-42\",\"other\":1}";
    const v = extractStringField(std.testing.allocator, json, "service_id");
    defer if (v) |s| std.testing.allocator.free(s);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("svc-42", v.?);
}

test "extractStringField: returns null for absent field" {
    const json = "{\"other\":1}";
    const v = extractStringField(std.testing.allocator, json, "service_id");
    try std.testing.expect(v == null);
}

test "uuidToHex/parseUuid: round-trips" {
    const uuid: Uuid = .{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 };
    const hex = try uuidToHex(std.testing.allocator, uuid);
    defer std.testing.allocator.free(hex);
    const parsed = try parseUuid(hex);
    try std.testing.expectEqualSlices(u8, &uuid, &parsed);
}

// ---------------------------------------------------------------------------
// PIN-04 mergeEffectivePins() unit tests
// ---------------------------------------------------------------------------

test "mergeEffectivePins: no rebind events -> base set unchanged, tagged with started_event_id" {
    const started = [_]PinnedVersion{
        .{ .kind = .catalog_entry, .ref = "svc-a", .resolved_id = "svc-a", .version = "100", .source = .resolved },
    };
    const merged = try mergeEffectivePins(std.testing.allocator, &started, "evt-1", &.{});
    defer freeEffectivePins(std.testing.allocator, merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqualStrings("svc-a", merged[0].pin.ref);
    try std.testing.expectEqualStrings("100", merged[0].pin.version);
    try std.testing.expectEqualStrings("evt-1", merged[0].source_event_id);
    try std.testing.expectEqual(PinSource.resolved, merged[0].pin.source);
}

test "mergeEffectivePins: a rebind overlay replaces the matching ref and tags the rebind's event id" {
    const started = [_]PinnedVersion{
        .{ .kind = .catalog_entry, .ref = "svc-a", .resolved_id = "svc-a", .version = "100", .source = .resolved },
        .{ .kind = .variable_schema, .ref = "def-1", .resolved_id = "def-1", .version = "hash-1", .source = .resolved },
    };
    const changes = [_]RebindChangeEntry{
        .{ .kind = .catalog_entry, .ref = "svc-a", .prior_version = "100", .new_version = "200" },
    };
    const rebinds = [_]RebindEventRow{
        .{ .event_id = "evt-rebind-1", .changes = &changes },
    };
    const merged = try mergeEffectivePins(std.testing.allocator, &started, "evt-1", &rebinds);
    defer freeEffectivePins(std.testing.allocator, merged);

    try std.testing.expectEqual(@as(usize, 2), merged.len);
    // svc-a was rebound: version 200, source event = the rebind row.
    try std.testing.expectEqualStrings("200", merged[0].pin.version);
    try std.testing.expectEqualStrings("evt-rebind-1", merged[0].source_event_id);
    try std.testing.expectEqual(PinSource.override, merged[0].pin.source);
    // def-1 untouched: still tagged with the INSTANCE_STARTED event id.
    try std.testing.expectEqualStrings("hash-1", merged[1].pin.version);
    try std.testing.expectEqualStrings("evt-1", merged[1].source_event_id);
}

test "findPinForRef: matches by kind and ref, returns null when absent" {
    const pins = [_]PinnedVersion{
        .{ .kind = .catalog_entry, .ref = "svc-a", .resolved_id = "svc-a", .version = "100", .source = .resolved },
        .{ .kind = .variable_schema, .ref = "def-1", .resolved_id = "def-1", .version = "hash-1", .source = .resolved },
    };
    const found = findPinForRef(&pins, .catalog_entry, "svc-a");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("100", found.?.version);

    try std.testing.expect(findPinForRef(&pins, .catalog_entry, "svc-b") == null);
    // Same ref string, different kind -> no match (kind is part of the key).
    try std.testing.expect(findPinForRef(&pins, .module, "svc-a") == null);
}

test "findEffectivePinForRef: matches by kind and ref against merged pins" {
    const eps = [_]EffectivePin{
        .{
            .pin = .{ .kind = .catalog_entry, .ref = "svc-a", .resolved_id = "svc-a", .version = "100", .source = .resolved },
            .source_event_id = "evt-1",
        },
    };
    const found = findEffectivePinForRef(&eps, .catalog_entry, "svc-a");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("100", found.?.version);
    try std.testing.expect(findEffectivePinForRef(&eps, .catalog_entry, "svc-missing") == null);
}

test "mergeEffectivePins: last rebind wins when the same ref is rebound twice" {
    const started = [_]PinnedVersion{
        .{ .kind = .catalog_entry, .ref = "svc-a", .resolved_id = "svc-a", .version = "100", .source = .resolved },
    };
    const changes1 = [_]RebindChangeEntry{
        .{ .kind = .catalog_entry, .ref = "svc-a", .prior_version = "100", .new_version = "200" },
    };
    const changes2 = [_]RebindChangeEntry{
        .{ .kind = .catalog_entry, .ref = "svc-a", .prior_version = "200", .new_version = "300" },
    };
    const rebinds = [_]RebindEventRow{
        .{ .event_id = "evt-rebind-1", .changes = &changes1 },
        .{ .event_id = "evt-rebind-2", .changes = &changes2 },
    };
    const merged = try mergeEffectivePins(std.testing.allocator, &started, "evt-1", &rebinds);
    defer freeEffectivePins(std.testing.allocator, merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqualStrings("300", merged[0].pin.version);
    try std.testing.expectEqualStrings("evt-rebind-2", merged[0].source_event_id);
}
