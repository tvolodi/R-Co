//! SolutionPackStore — SOL-01 export, SOL-02 install, SOL-03 activation gate.
//!
//! Design artefact: src/design/sol-batch1-solution-pack.md
const std = @import("std");
const db = @import("pool");
const types = @import("types.zig");
const builder = @import("pack_builder.zig");
const uuid_util = @import("../util/uuid.zig");

pub const SolutionPackError = types.SolutionPackError;
pub const SolutionPackDocument = types.SolutionPackDocument;
pub const PackedDefinition = types.PackedDefinition;
pub const PackedCatalogEntry = types.PackedCatalogEntry;
pub const PackedVariableSchema = types.PackedVariableSchema;
pub const PackManifest = types.PackManifest;
pub const InstallResult = types.InstallResult;
pub const InstalledDefinition = types.InstalledDefinition;
pub const RoleChecklistEntry = types.RoleChecklistEntry;
pub const RoleGateResult = types.RoleGateResult;
pub const PACK_SCHEMA_VERSION = types.PACK_SCHEMA_VERSION;

// ---------------------------------------------------------------------------
// SolutionPackStore
// ---------------------------------------------------------------------------

pub const SolutionPackStore = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) SolutionPackStore {
        return .{ .pool = pool };
    }

    // -----------------------------------------------------------------------
    // exportPack  (SOL-01)
    // -----------------------------------------------------------------------

    /// Build a SolutionPackDocument from the given definition IDs.
    ///
    /// For each definition: fetches graph + variable schemas, walks graph
    /// to collect SERVICE_TASK service_ids and HUMAN_TASK role names,
    /// then queries public.service_catalog for each service entry.
    ///
    /// Returns DefinitionNotFound when any `definition_ids[i]` is absent.
    /// All returned strings are owned by `allocator`.
    pub fn exportPack(
        self: *SolutionPackStore,
        allocator: std.mem.Allocator,
        version: []const u8,
        definition_ids: []const []const u8,
    ) SolutionPackError!SolutionPackDocument {
        const conn = self.pool.acquire() catch return SolutionPackError.PoolExhausted;
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var packed_defs: std.ArrayList(PackedDefinition) = .empty;
        errdefer {
            for (packed_defs.items) |d| {
                allocator.free(d.definition_id);
                allocator.free(d.process_key);
                allocator.free(d.name);
                allocator.free(d.version);
                allocator.free(d.graph);
                allocator.free(d.variable_schema);
            }
            packed_defs.deinit(allocator);
        }

        var packed_vars: std.ArrayList(PackedVariableSchema) = .empty;
        errdefer {
            for (packed_vars.items) |v| {
                allocator.free(v.definition_id);
                allocator.free(v.schema_name);
                allocator.free(v.schema_content);
            }
            packed_vars.deinit(allocator);
        }

        // Collect service_ids (raw, may have duplicates) and role names.
        var raw_service_ids: std.ArrayList([]const u8) = .empty;
        defer raw_service_ids.deinit(a);
        var raw_role_names: std.ArrayList([]const u8) = .empty;
        defer raw_role_names.deinit(a);

        for (definition_ids) |def_id_str| {
            // Fetch definition row.
            const def_row = conn.queryRow(
                a,
                \\SELECT id::text, name, version, description, graph::text
                \\FROM process_definitions
                \\WHERE id = $1::uuid
            ,
                &.{def_id_str},
            ) catch return SolutionPackError.PersistenceFailed;

            const dr = def_row orelse return SolutionPackError.DefinitionNotFound;
            defer {
                for (dr) |c| if (c) |v| a.free(v);
                a.free(dr);
            }

            const id_text = dr[0] orelse def_id_str;
            const name_text = dr[1] orelse "";
            const ver_text = dr[2] orelse "";
            const graph_text = dr[4] orelse "{}";

            // Walk graph to collect dependencies.
            var def_service_ids: std.ArrayList([]const u8) = .empty;
            defer def_service_ids.deinit(a);
            var def_role_names: std.ArrayList([]const u8) = .empty;
            defer def_role_names.deinit(a);

            builder.collectGraphDeps(a, graph_text, &def_service_ids, &def_role_names) catch
                return SolutionPackError.OutOfMemory;

            for (def_service_ids.items) |sid| {
                raw_service_ids.append(a, sid) catch return SolutionPackError.OutOfMemory;
            }
            for (def_role_names.items) |rname| {
                raw_role_names.append(a, rname) catch return SolutionPackError.OutOfMemory;
            }

            // Fetch variable_schemas rows.
            var var_qr = conn.query(
                a,
                \\SELECT variable_key, json_schema::text
                \\FROM variable_schemas
                \\WHERE definition_id = $1::uuid
                \\ORDER BY variable_key
            ,
                &.{def_id_str},
            ) catch return SolutionPackError.PersistenceFailed;
            defer var_qr.deinit();

            for (var_qr.rows) |vrow| {
                const vkey = colGet(vrow, 0);
                const vschema = colGet(vrow, 1);

                const did_dup = allocator.dupe(u8, id_text) catch return SolutionPackError.OutOfMemory;
                errdefer allocator.free(did_dup);
                const vkey_dup = allocator.dupe(u8, vkey) catch return SolutionPackError.OutOfMemory;
                errdefer allocator.free(vkey_dup);
                const vs_dup = allocator.dupe(u8, vschema) catch return SolutionPackError.OutOfMemory;
                errdefer allocator.free(vs_dup);

                packed_vars.append(allocator, .{
                    .definition_id = did_dup,
                    .schema_name = vkey_dup,
                    .schema_content = vs_dup,
                }) catch return SolutionPackError.OutOfMemory;
            }

            // Build PackedDefinition.
            const id_dup = allocator.dupe(u8, id_text) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(id_dup);
            const key_dup = allocator.dupe(u8, name_text) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(key_dup);
            const name_dup = allocator.dupe(u8, name_text) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(name_dup);
            const ver_dup = allocator.dupe(u8, ver_text) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(ver_dup);
            const graph_dup = allocator.dupe(u8, graph_text) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(graph_dup);
            const vschema_dup = allocator.dupe(u8, "{}") catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(vschema_dup);

            packed_defs.append(allocator, .{
                .definition_id = id_dup,
                .process_key = key_dup,
                .name = name_dup,
                .version = ver_dup,
                .graph = graph_dup,
                .variable_schema = vschema_dup,
            }) catch return SolutionPackError.OutOfMemory;
        }

        // Deduplicate service IDs and query catalog.
        const deduped_sids = builder.dedupSorted(a, raw_service_ids.items) catch
            return SolutionPackError.OutOfMemory;
        defer a.free(deduped_sids);

        var packed_catalog: std.ArrayList(PackedCatalogEntry) = .empty;
        errdefer {
            for (packed_catalog.items) |e| {
                allocator.free(e.service_id);
                allocator.free(e.endpoint_url);
                allocator.free(e.request_schema);
                allocator.free(e.response_schema);
                allocator.free(e.required_auth);
                allocator.free(e.retry_policy);
            }
            packed_catalog.deinit(allocator);
        }

        for (deduped_sids) |sid| {
            const svc_row = conn.queryRow(
                a,
                \\SELECT service_id, endpoint_url, request_schema::text,
                \\       response_schema::text, required_auth, timeout_ms, retry_policy::text
                \\FROM public.service_catalog
                \\WHERE service_id = $1
            ,
                &.{sid},
            ) catch return SolutionPackError.PersistenceFailed;

            const sr = svc_row orelse continue; // skip services not found
            defer {
                for (sr) |c| if (c) |v| a.free(v);
                a.free(sr);
            }

            const sid_dup = allocator.dupe(u8, colGet(sr, 0)) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(sid_dup);
            const url_dup = allocator.dupe(u8, colGet(sr, 1)) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(url_dup);
            const req_dup = allocator.dupe(u8, colGet(sr, 2)) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(req_dup);
            const resp_dup = allocator.dupe(u8, colGet(sr, 3)) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(resp_dup);
            const auth_dup = allocator.dupe(u8, colGet(sr, 4)) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(auth_dup);
            const retry_dup = allocator.dupe(u8, colGet(sr, 6)) catch return SolutionPackError.OutOfMemory;
            errdefer allocator.free(retry_dup);
            const tms = std.fmt.parseInt(u32, colGet(sr, 5), 10) catch 30000;

            packed_catalog.append(allocator, .{
                .service_id = sid_dup,
                .endpoint_url = url_dup,
                .request_schema = req_dup,
                .response_schema = resp_dup,
                .required_auth = auth_dup,
                .timeout_ms = tms,
                .retry_policy = retry_dup,
            }) catch return SolutionPackError.OutOfMemory;
        }

        // Build sorted+deduped manifest roles.
        const sorted_roles = builder.dedupSorted(allocator, raw_role_names.items) catch
            return SolutionPackError.OutOfMemory;
        errdefer {
            for (sorted_roles) |r| allocator.free(r);
            allocator.free(sorted_roles);
        }

        // Generate pack_id and exported_at.
        const pack_id = newUuidStr(allocator) catch return SolutionPackError.OutOfMemory;
        errdefer allocator.free(pack_id);
        const exported_at = allocator.dupe(u8, "2000-01-01T00:00:00Z") catch
            return SolutionPackError.OutOfMemory;
        errdefer allocator.free(exported_at);
        const version_dup = allocator.dupe(u8, version) catch return SolutionPackError.OutOfMemory;
        errdefer allocator.free(version_dup);
        const schema_ver = allocator.dupe(u8, PACK_SCHEMA_VERSION) catch
            return SolutionPackError.OutOfMemory;
        errdefer allocator.free(schema_ver);

        return SolutionPackDocument{
            .pack_id = pack_id,
            .version = version_dup,
            .bpm_export_schema_version = schema_ver,
            .exported_at = exported_at,
            .definitions = try packed_defs.toOwnedSlice(allocator),
            .service_catalog_entries = try packed_catalog.toOwnedSlice(allocator),
            .variable_schemas = try packed_vars.toOwnedSlice(allocator),
            .manifest = .{ .required_roles = sorted_roles },
        };
    }

    // -----------------------------------------------------------------------
    // installPack  (SOL-02)
    // -----------------------------------------------------------------------

    /// Idempotently install a solution pack into the current tenant schema.
    ///
    /// Pre-transaction guards check schema version and idempotency.
    /// Inside the transaction: inserts install record, catalog entries,
    /// variable schemas, DRAFT definitions, and role map rows.
    ///
    /// Returns a role-mapping checklist so the admin knows which roles still
    /// need binding before any bundled definition can be activated.
    pub fn installPack(
        self: *SolutionPackStore,
        allocator: std.mem.Allocator,
        doc: SolutionPackDocument,
        actor_id: []const u8,
    ) SolutionPackError!InstallResult {
        // Pre-flight: validate schema version.
        if (!std.mem.eql(u8, doc.bpm_export_schema_version, PACK_SCHEMA_VERSION)) {
            return SolutionPackError.InvalidPackDocument;
        }

        const conn = self.pool.acquire() catch return SolutionPackError.PoolExhausted;
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Idempotency check: (pack_id, pack_version) already installed?
        const exist_row = conn.queryRow(
            a,
            \\SELECT id::text FROM solution_pack_installs
            \\WHERE pack_id = $1 AND pack_version = $2
        ,
            &.{ doc.pack_id, doc.version },
        ) catch return SolutionPackError.PersistenceFailed;

        if (exist_row != null) {
            defer {
                const r = exist_row.?;
                for (r) |c| if (c) |v| a.free(v);
                a.free(r);
            }
            // Already installed — return idempotent result with warning.
            return buildIdempotentResult(allocator, doc);
        }

        // Begin transaction.
        conn.begin() catch return SolutionPackError.TransactionFailed;
        errdefer conn.rollback() catch {};

        // Insert solution_pack_installs row.
        const install_row = conn.queryRow(
            a,
            \\INSERT INTO solution_pack_installs
            \\  (pack_id, pack_version, schema_version, installed_by)
            \\VALUES ($1, $2, $3, $4::uuid)
            \\RETURNING id::text
        ,
            &.{ doc.pack_id, doc.version, doc.bpm_export_schema_version, actor_id },
        ) catch return SolutionPackError.TransactionFailed;

        const irow = install_row orelse return SolutionPackError.TransactionFailed;
        defer {
            for (irow) |c| if (c) |v| a.free(v);
            a.free(irow);
        }
        const install_id = irow[0] orelse return SolutionPackError.TransactionFailed;
        const install_id_owned = a.dupe(u8, install_id) catch return SolutionPackError.OutOfMemory;

        // Process service catalog entries.
        for (doc.service_catalog_entries) |entry| {
            const check_row = conn.queryRow(
                a,
                \\SELECT request_schema::text, response_schema::text
                \\FROM public.service_catalog
                \\WHERE service_id = $1
            ,
                &.{entry.service_id},
            ) catch return SolutionPackError.TransactionFailed;

            if (check_row) |cr| {
                defer {
                    for (cr) |c| if (c) |v| a.free(v);
                    a.free(cr);
                }
                // Existing entry: check for schema conflict.
                const existing_req = colGet(cr, 0);
                const existing_resp = colGet(cr, 1);
                if (!std.mem.eql(u8, existing_req, entry.request_schema) or
                    !std.mem.eql(u8, existing_resp, entry.response_schema))
                {
                    conn.rollback() catch {};
                    return SolutionPackError.CatalogConflict;
                }
                // Same schemas — skip (reuse).
            } else {
                // Absent — insert.
                const tms_str = std.fmt.allocPrint(a, "{d}", .{entry.timeout_ms}) catch
                    return SolutionPackError.OutOfMemory;
                var ins_qr = conn.query(
                    a,
                    \\INSERT INTO public.service_catalog
                    \\  (service_id, endpoint_url, request_schema, response_schema,
                    \\   required_auth, timeout_ms, retry_policy, scope)
                    \\VALUES ($1, $2, $3::jsonb, $4::jsonb, $5, $6::bigint, $7::jsonb, 'global')
                    \\ON CONFLICT (service_id) DO NOTHING
                ,
                    &.{
                        entry.service_id,
                        entry.endpoint_url,
                        entry.request_schema,
                        entry.response_schema,
                        entry.required_auth,
                        tms_str,
                        entry.retry_policy,
                    },
                ) catch return SolutionPackError.TransactionFailed;
                ins_qr.deinit();
            }
        }

        // Process variable schemas.
        for (doc.variable_schemas) |vs| {
            const vcheck_row = conn.queryRow(
                a,
                \\SELECT json_schema::text FROM variable_schemas
                \\WHERE variable_key = $1
                \\  AND definition_id IN (
                \\    SELECT id FROM process_definitions WHERE name = $2
                \\  )
                \\LIMIT 1
            ,
                &.{ vs.schema_name, vs.definition_id },
            ) catch return SolutionPackError.TransactionFailed;

            if (vcheck_row) |vcr| {
                defer {
                    for (vcr) |c| if (c) |v| a.free(v);
                    a.free(vcr);
                }
                const existing_schema = colGet(vcr, 0);
                if (!std.mem.eql(u8, existing_schema, vs.schema_content)) {
                    conn.rollback() catch {};
                    return SolutionPackError.VariableSchemaConflict;
                }
                // Same content — skip.
            }
            // Note: variable schema rows are inserted after definitions (see below).
        }

        // Insert definitions.
        var installed_defs: std.ArrayList(InstalledDefinition) = .empty;
        errdefer {
            for (installed_defs.items) |d| {
                allocator.free(d.source_definition_id);
                allocator.free(d.new_definition_id);
                allocator.free(d.process_key);
            }
            installed_defs.deinit(allocator);
        }

        for (doc.definitions) |def| {
            const def_row = conn.queryRow(
                a,
                \\INSERT INTO process_definitions
                \\  (name, version, description, graph, created_by, solution_pack_install_id)
                \\VALUES ($1, $2, $3, $4::jsonb, $5::uuid, $6::uuid)
                \\RETURNING id::text
            ,
                &.{
                    def.process_key,
                    def.version,
                    "",
                    def.graph,
                    actor_id,
                    install_id_owned,
                },
            ) catch return SolutionPackError.TransactionFailed;

            const drow = def_row orelse return SolutionPackError.TransactionFailed;
            defer {
                for (drow) |c| if (c) |v| a.free(v);
                a.free(drow);
            }
            const new_def_id = drow[0] orelse return SolutionPackError.TransactionFailed;

            // Insert variable_schemas rows for this new definition.
            for (doc.variable_schemas) |vs| {
                if (!std.mem.eql(u8, vs.definition_id, def.definition_id)) continue;
                var vs_qr = conn.query(
                    a,
                    \\INSERT INTO variable_schemas (definition_id, variable_key, json_schema)
                    \\VALUES ($1::uuid, $2, $3::jsonb)
                    \\ON CONFLICT (definition_id, variable_key) DO NOTHING
                ,
                    &.{ new_def_id, vs.schema_name, vs.schema_content },
                ) catch return SolutionPackError.TransactionFailed;
                vs_qr.deinit();
            }

            const src_dup = allocator.dupe(u8, def.definition_id) catch
                return SolutionPackError.OutOfMemory;
            errdefer allocator.free(src_dup);
            const new_dup = allocator.dupe(u8, new_def_id) catch
                return SolutionPackError.OutOfMemory;
            errdefer allocator.free(new_dup);
            const key_dup = allocator.dupe(u8, def.process_key) catch
                return SolutionPackError.OutOfMemory;
            errdefer allocator.free(key_dup);

            installed_defs.append(allocator, .{
                .source_definition_id = src_dup,
                .new_definition_id = new_dup,
                .process_key = key_dup,
                .status = "DRAFT",
            }) catch return SolutionPackError.OutOfMemory;
        }

        // Insert role map rows.
        for (doc.manifest.required_roles) |role_name| {
            var rm_qr = conn.query(
                a,
                \\INSERT INTO solution_pack_role_map (install_id, role_name)
                \\VALUES ($1::uuid, $2)
                \\ON CONFLICT (install_id, role_name) DO NOTHING
            ,
                &.{ install_id_owned, role_name },
            ) catch return SolutionPackError.TransactionFailed;
            rm_qr.deinit();
        }

        conn.commit() catch return SolutionPackError.TransactionFailed;

        // Build role-mapping checklist.
        var checklist: std.ArrayList(RoleChecklistEntry) = .empty;
        errdefer {
            for (checklist.items) |e| allocator.free(e.role_name);
            checklist.deinit(allocator);
        }

        const check_conn = self.pool.acquire() catch return SolutionPackError.PoolExhausted;
        defer self.pool.release(check_conn);

        for (doc.manifest.required_roles) |role_name| {
            const bound_row = check_conn.queryRow(
                a,
                "SELECT id FROM tenant_role WHERE name = $1 LIMIT 1",
                &.{role_name},
            ) catch null;

            const is_bound = bound_row != null;
            if (bound_row) |br| {
                for (br) |c| if (c) |v| a.free(v);
                a.free(br);
            }

            const rname_dup = allocator.dupe(u8, role_name) catch
                return SolutionPackError.OutOfMemory;
            errdefer allocator.free(rname_dup);

            checklist.append(allocator, .{
                .role_name = rname_dup,
                .bound = is_bound,
            }) catch return SolutionPackError.OutOfMemory;
        }

        const warnings = try allocator.alloc([]const u8, 0);
        const pack_id_dup = allocator.dupe(u8, doc.pack_id) catch
            return SolutionPackError.OutOfMemory;
        errdefer allocator.free(pack_id_dup);
        const ver_dup = allocator.dupe(u8, doc.version) catch
            return SolutionPackError.OutOfMemory;
        errdefer allocator.free(ver_dup);

        return InstallResult{
            .pack_id = pack_id_dup,
            .version = ver_dup,
            .installed_definitions = try installed_defs.toOwnedSlice(allocator),
            .role_mapping_checklist = try checklist.toOwnedSlice(allocator),
            .warnings = warnings,
        };
    }

    // -----------------------------------------------------------------------
    // checkRoleGate  (SOL-03)
    // -----------------------------------------------------------------------

    /// Check whether the definition may be activated (SOL-03 gate).
    ///
    /// Returns allowed=true immediately when the definition was NOT installed
    /// via a solution pack (solution_pack_install_id IS NULL).
    /// When non-NULL, queries for manifest roles that have no tenant_role
    /// binding and returns allowed=false with the list of unbound names.
    ///
    /// `definition_id` must be the 36-char UUID hex string.
    pub fn checkRoleGate(
        self: *SolutionPackStore,
        allocator: std.mem.Allocator,
        definition_id: []const u8,
    ) SolutionPackError!RoleGateResult {
        const conn = self.pool.acquire() catch return SolutionPackError.PoolExhausted;
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Step 1: resolve install_id for this definition.
        const install_row = conn.queryRow(
            a,
            \\SELECT solution_pack_install_id::text
            \\FROM process_definitions
            \\WHERE id = $1::uuid
        ,
            &.{definition_id},
        ) catch return SolutionPackError.PersistenceFailed;

        const irow = install_row orelse {
            // Definition not found — let normal activation handle the 404.
            return RoleGateResult{ .allowed = true, .unbound_roles = &.{} };
        };
        defer {
            for (irow) |c| if (c) |v| a.free(v);
            a.free(irow);
        }

        const install_id_opt = irow[0];
        if (install_id_opt == null) {
            // No pack install — gate does not apply.
            return RoleGateResult{ .allowed = true, .unbound_roles = &.{} };
        }
        const install_id = install_id_opt.?;

        // Step 2: find unbound manifest roles.
        var unbound_qr = conn.query(
            a,
            \\SELECT r.role_name
            \\FROM solution_pack_role_map r
            \\WHERE r.install_id = $1::uuid
            \\  AND NOT EXISTS (
            \\    SELECT 1 FROM tenant_role tr WHERE tr.name = r.role_name
            \\  )
            \\ORDER BY r.role_name
        ,
            &.{install_id},
        ) catch return SolutionPackError.PersistenceFailed;
        defer unbound_qr.deinit();

        if (unbound_qr.rows.len == 0) {
            return RoleGateResult{ .allowed = true, .unbound_roles = &.{} };
        }

        // Build unbound_roles slice (owned by allocator).
        const unbound = try allocator.alloc([]const u8, unbound_qr.rows.len);
        errdefer {
            for (unbound) |s| allocator.free(s);
            allocator.free(unbound);
        }
        for (unbound_qr.rows, 0..) |row, i| {
            const role = colGet(row, 0);
            unbound[i] = allocator.dupe(u8, role) catch return SolutionPackError.OutOfMemory;
        }

        return RoleGateResult{ .allowed = false, .unbound_roles = unbound };
    }
};

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Safe column accessor: returns "" for out-of-range or NULL columns.
fn colGet(row: []?[]u8, idx: usize) []const u8 {
    if (idx >= row.len) return "";
    return row[idx] orelse "";
}

/// Build a UUID v4 string using the platform-safe uuid_util helper.
/// Caller owns the returned slice (must be freed with the supplied allocator).
fn newUuidStr(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const s = uuid_util.newUuidV4(allocator) catch return error.OutOfMemory;
    // newUuidV4 returns []const u8; we need []u8 — dupe gives mutability.
    defer allocator.free(s);
    return allocator.dupe(u8, s);
}

/// Build an idempotent InstallResult when the pack was already installed.
/// No database access; just a warning-only result.
fn buildIdempotentResult(
    allocator: std.mem.Allocator,
    doc: SolutionPackDocument,
) SolutionPackError!InstallResult {
    const pack_id = allocator.dupe(u8, doc.pack_id) catch return SolutionPackError.OutOfMemory;
    errdefer allocator.free(pack_id);
    const ver = allocator.dupe(u8, doc.version) catch return SolutionPackError.OutOfMemory;
    errdefer allocator.free(ver);

    const warn_msg = allocator.dupe(u8, "pack already installed — idempotent skip") catch
        return SolutionPackError.OutOfMemory;
    errdefer allocator.free(warn_msg);

    const warnings = allocator.alloc([]const u8, 1) catch return SolutionPackError.OutOfMemory;
    warnings[0] = warn_msg;

    return InstallResult{
        .pack_id = pack_id,
        .version = ver,
        .installed_definitions = &.{},
        .role_mapping_checklist = &.{},
        .warnings = warnings,
    };
}
