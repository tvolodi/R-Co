//! Integration tests for SPT-02 — Data migration: copy rows into tenant schemas
//! and remove RLS infrastructure.
//!
//! Covers all 6 SPT-02 acceptance criteria. Tests operate against the
//! post-migration state (migrations 061, 062, 063 already applied by
//! TestHarness.init()):
//!   - public tables have no tenant_id column (dropped by 062)
//!   - bpm_effective_tenant_id() function does not exist (dropped by 062)
//!   - all 6 tenant RLS policies are absent (dropped by 062 + 063)
//!   - public.tenant_schemas has a status TEXT column (added by 061)
//!
//! All tests use TestHarness transaction rollback for automatic cleanup:
//! h.deinit() rolls back all provisioned schemas, tenant_schemas rows, and
//! test tables created within the test. No schema leakage between tests.
//!
//! Requirement: SPT-02
//! Requires: BPM_TEST_DB_URL set to a real PostgreSQL instance.
//! All fixtures use per-test UUIDs. No error.SkipZigTest on any MUST test.

const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const schemaNameForTenant = bpm.pool.schemaNameForTenant;

// Kept for TestHarness @hasDecl guard resolution (consistent with other integration modules).
const root = @import("root");

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Generate a random RFC 4122 v4 UUID string.
/// The result is owned by the caller and must be freed with allocator.free().
fn randomUuidStr(allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    std.testing.io.random(&raw);
    // Set version 4 and variant bits per RFC 4122.
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 10xx
    return std.fmt.allocPrint(allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}-" ++
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            raw[0],  raw[1],  raw[2],  raw[3],
            raw[4],  raw[5],
            raw[6],  raw[7],
            raw[8],  raw[9],
            raw[10], raw[11], raw[12], raw[13], raw[14], raw[15],
        });
}

/// Derive the PostgreSQL schema name for a tenant UUID using the same logic
/// as schemaNameForTenant. Returns a slice into buf.
fn deriveSchemaName(uuid_str: []const u8, buf: *[80]u8) []const u8 {
    return schemaNameForTenant(uuid_str, buf);
}

// ---------------------------------------------------------------------------
// TC-SPT-02-01 (AC-1)
// GIVEN 2 distinct tenant UUIDs, WHEN bpm_provision_tenant_schema() is called
// for each, THEN public.tenant_schemas has exactly 2 rows for those UUIDs AND
// 2 schemas named tenant_<uuid_no_hyphens> exist in the database.
// ---------------------------------------------------------------------------
test "TC-SPT-02-01: N tenants provisioned produce N rows in tenant_schemas and N schemas in pg_namespace" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const uuid_a = try randomUuidStr(alloc);
    defer alloc.free(uuid_a);
    const uuid_b = try randomUuidStr(alloc);
    defer alloc.free(uuid_b);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    const schema_a = deriveSchemaName(uuid_a, &buf_a);
    const schema_b = deriveSchemaName(uuid_b, &buf_b);

    // Provision both tenants inside the TestHarness transaction.
    // h.deinit() rolls back, removing schemas and tenant_schemas rows automatically.
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_a});
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_b});

    // Verify tenant_schemas row for tenant A.
    var reg_a = try h.conn.query(alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{uuid_a});
    defer reg_a.deinit();
    try std.testing.expect(reg_a.rows.len > 0);
    const count_a = try std.fmt.parseInt(i64, reg_a.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), count_a);

    // Verify tenant_schemas row for tenant B.
    var reg_b = try h.conn.query(alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{uuid_b});
    defer reg_b.deinit();
    try std.testing.expect(reg_b.rows.len > 0);
    const count_b = try std.fmt.parseInt(i64, reg_b.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), count_b);

    // Verify schema A exists in pg_namespace.
    var schema_a_result = try h.conn.query(alloc,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
        &.{schema_a});
    defer schema_a_result.deinit();
    try std.testing.expect(schema_a_result.rows.len > 0);
    const schema_a_count = try std.fmt.parseInt(i64, schema_a_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), schema_a_count);

    // Verify schema B exists in pg_namespace.
    var schema_b_result = try h.conn.query(alloc,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
        &.{schema_b});
    defer schema_b_result.deinit();
    try std.testing.expect(schema_b_result.rows.len > 0);
    const schema_b_count = try std.fmt.parseInt(i64, schema_b_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), schema_b_count);
}

// ---------------------------------------------------------------------------
// TC-SPT-02-02 (AC-2)
// GIVEN two tenant schemas provisioned, WHEN a row is inserted into tenant A's
// table, THEN it does not appear in tenant B's table (no cross-tenant
// contamination). Each schema's tables are physically separate objects.
// ---------------------------------------------------------------------------
test "TC-SPT-02-02: data inserted into one tenant schema is not visible from another tenant schema" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const uuid_a = try randomUuidStr(alloc);
    defer alloc.free(uuid_a);
    const uuid_b = try randomUuidStr(alloc);
    defer alloc.free(uuid_b);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    const schema_a = deriveSchemaName(uuid_a, &buf_a);
    const schema_b = deriveSchemaName(uuid_b, &buf_b);

    // Provision both tenant schemas inside the transaction.
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_a});
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_b});

    // Create a minimal isolation test table in schema A.
    // Schema names are UUID-derived (format: tenant_<32hex>) — safe to embed in DDL.
    const create_a = try std.fmt.allocPrint(alloc,
        "CREATE TABLE {s}.spt02_iso_check (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), marker TEXT NOT NULL)",
        .{schema_a});
    defer alloc.free(create_a);
    try h.conn.exec(create_a, &.{});

    // Create the same table in schema B.
    const create_b = try std.fmt.allocPrint(alloc,
        "CREATE TABLE {s}.spt02_iso_check (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), marker TEXT NOT NULL)",
        .{schema_b});
    defer alloc.free(create_b);
    try h.conn.exec(create_b, &.{});

    // Insert a marker row into schema A only.
    const insert_a = try std.fmt.allocPrint(alloc,
        "INSERT INTO {s}.spt02_iso_check (marker) VALUES ('tenant-a-exclusive')",
        .{schema_a});
    defer alloc.free(insert_a);
    try h.conn.exec(insert_a, &.{});

    // Schema A must contain exactly 1 row.
    const count_a_sql = try std.fmt.allocPrint(alloc,
        "SELECT count(*) FROM {s}.spt02_iso_check",
        .{schema_a});
    defer alloc.free(count_a_sql);
    var result_a = try h.conn.query(alloc, count_a_sql, &.{});
    defer result_a.deinit();
    try std.testing.expect(result_a.rows.len > 0);
    const count_a = try std.fmt.parseInt(i64, result_a.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    if (count_a != 1) {
        std.debug.print("TC-SPT-02-02: expected 1 row in schema A, found {}\n", .{count_a});
    }
    try std.testing.expectEqual(@as(i64, 1), count_a);

    // Schema B must have 0 rows — marker from schema A must not have leaked.
    const count_b_sql = try std.fmt.allocPrint(alloc,
        "SELECT count(*) FROM {s}.spt02_iso_check",
        .{schema_b});
    defer alloc.free(count_b_sql);
    var result_b = try h.conn.query(alloc, count_b_sql, &.{});
    defer result_b.deinit();
    try std.testing.expect(result_b.rows.len > 0);
    const count_b = try std.fmt.parseInt(i64, result_b.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    if (count_b != 0) {
        std.debug.print("TC-SPT-02-02: cross-tenant contamination detected — {d} row(s) found in schema B\n", .{count_b});
    }
    try std.testing.expectEqual(@as(i64, 0), count_b);
}

// ---------------------------------------------------------------------------
// TC-SPT-02-03 (AC-3)
// GIVEN migration 062 was applied, THEN:
//   (a) No tenant_id column exists on any affected public table.
//   (b) bpm_effective_tenant_id() function does not exist in the public schema.
//   (c) All 6 known tenant RLS policies are absent.
//   (d) RLS is disabled on all affected tables.
//   (e) All known tenant_id composite indexes are absent.
// ---------------------------------------------------------------------------
test "TC-SPT-02-03: migration 062 removed tenant_id columns, bpm_effective_tenant_id function, RLS policies, and composite indexes" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // ── (a) No tenant_id column on any affected public table ──────────────────
    var col_result = try h.conn.query(alloc,
        \\SELECT count(*) FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND column_name  = 'tenant_id'
        \\  AND table_name IN (
        \\      'events', 'events_archive', 'process_definitions',
        \\      'instance_projections', 'tasks', 'tokens',
        \\      'audit_entries', 'audit_log', 'users', 'groups', 'tenant_hostnames'
        \\  )
    , &.{});
    defer col_result.deinit();
    try std.testing.expect(col_result.rows.len > 0);
    const col_count = try std.fmt.parseInt(i64, col_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    if (col_count != 0) {
        std.debug.print("TC-SPT-02-03 (a): expected 0 tenant_id columns on public tables, found {}\n", .{col_count});
    }
    try std.testing.expectEqual(@as(i64, 0), col_count);

    // ── (b) bpm_effective_tenant_id() function does not exist ─────────────────
    var fn_result = try h.conn.query(alloc,
        \\SELECT count(*) FROM pg_proc p
        \\JOIN pg_namespace n ON p.pronamespace = n.oid
        \\WHERE n.nspname = 'public'
        \\  AND p.proname = 'bpm_effective_tenant_id'
    , &.{});
    defer fn_result.deinit();
    try std.testing.expect(fn_result.rows.len > 0);
    const fn_count = try std.fmt.parseInt(i64, fn_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    if (fn_count != 0) {
        std.debug.print("TC-SPT-02-03 (b): bpm_effective_tenant_id() still exists ({} instance(s))\n", .{fn_count});
    }
    try std.testing.expectEqual(@as(i64, 0), fn_count);

    // ── (c) All 6 known tenant RLS policies are absent ────────────────────────
    var rls_result = try h.conn.query(alloc,
        \\SELECT count(*) FROM pg_policies
        \\WHERE schemaname = 'public'
        \\  AND policyname IN (
        \\      'process_definitions_tenant_policy',
        \\      'instance_projections_tenant_policy',
        \\      'tasks_tenant_policy',
        \\      'tokens_tenant_policy',
        \\      'audit_entries_tenant_policy',
        \\      'audit_log_tenant_policy'
        \\  )
    , &.{});
    defer rls_result.deinit();
    try std.testing.expect(rls_result.rows.len > 0);
    const rls_count = try std.fmt.parseInt(i64, rls_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    if (rls_count != 0) {
        std.debug.print("TC-SPT-02-03 (c): expected 0 tenant RLS policies, found {}\n", .{rls_count});
    }
    try std.testing.expectEqual(@as(i64, 0), rls_count);

    // ── (d) RLS is disabled on all affected tables ─────────────────────────────
    var rls_on_result = try h.conn.query(alloc,
        \\SELECT count(*) FROM pg_class c
        \\JOIN pg_namespace n ON c.relnamespace = n.oid
        \\WHERE n.nspname = 'public'
        \\  AND c.relrowsecurity = true
        \\  AND c.relname IN (
        \\      'process_definitions', 'instance_projections', 'tasks',
        \\      'tokens', 'audit_entries', 'audit_log',
        \\      'events', 'events_archive', 'users', 'groups'
        \\  )
    , &.{});
    defer rls_on_result.deinit();
    try std.testing.expect(rls_on_result.rows.len > 0);
    const rls_on_count = try std.fmt.parseInt(i64, rls_on_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    if (rls_on_count != 0) {
        std.debug.print("TC-SPT-02-03 (d): expected 0 tables with RLS enabled, found {}\n", .{rls_on_count});
    }
    try std.testing.expectEqual(@as(i64, 0), rls_on_count);

    // ── (e) Representative tenant_id composite indexes are absent ─────────────
    var idx_result = try h.conn.query(alloc,
        \\SELECT count(*) FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND indexname IN (
        \\      'idx_events_tenant_instance_seq',
        \\      'idx_events_tenant_global_seq',
        \\      'idx_events_archive_tenant_instance_seq',
        \\      'uq_active_definition_tenant',
        \\      'idx_def_tenant_name_status',
        \\      'uq_instance_tenant_correlation',
        \\      'idx_proj_tenant_status',
        \\      'idx_task_tenant_instance',
        \\      'idx_audit_entries_tenant_time',
        \\      'idx_groups_tenant_name'
        \\  )
    , &.{});
    defer idx_result.deinit();
    try std.testing.expect(idx_result.rows.len > 0);
    const idx_count = try std.fmt.parseInt(i64, idx_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    if (idx_count != 0) {
        std.debug.print("TC-SPT-02-03 (e): expected 0 tenant_id composite indexes, found {}\n", .{idx_count});
    }
    try std.testing.expectEqual(@as(i64, 0), idx_count);
}

// ---------------------------------------------------------------------------
// TC-SPT-02-04 (AC-4)
// GIVEN migration 062 completed, WHEN migration 063 DROP POLICY IF EXISTS
// statements are executed, THEN no error is raised (belt-and-suspenders
// idempotency: these are no-ops since policies are already absent).
// ---------------------------------------------------------------------------
test "TC-SPT-02-04: migration 063 DROP POLICY IF EXISTS statements are no-ops when policies are already absent" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Re-execute all 6 DROP POLICY IF EXISTS from migration 063.
    // These are no-ops since migration 062 already dropped the policies.
    // Use explicit public.* qualification to avoid search_path ambiguity.
    try h.conn.exec("DROP POLICY IF EXISTS process_definitions_tenant_policy   ON public.process_definitions",  &.{});
    try h.conn.exec("DROP POLICY IF EXISTS instance_projections_tenant_policy  ON public.instance_projections", &.{});
    try h.conn.exec("DROP POLICY IF EXISTS tasks_tenant_policy                 ON public.tasks",                &.{});
    try h.conn.exec("DROP POLICY IF EXISTS tokens_tenant_policy                ON public.tokens",               &.{});
    try h.conn.exec("DROP POLICY IF EXISTS audit_entries_tenant_policy         ON public.audit_entries",        &.{});
    try h.conn.exec("DROP POLICY IF EXISTS audit_log_tenant_policy             ON public.audit_log",            &.{});

    // Post-verify: 0 known policies remain (state is unchanged).
    var check = try h.conn.query(alloc,
        \\SELECT count(*) FROM pg_policies
        \\WHERE schemaname = 'public'
        \\  AND policyname IN (
        \\      'process_definitions_tenant_policy',
        \\      'instance_projections_tenant_policy',
        \\      'tasks_tenant_policy',
        \\      'tokens_tenant_policy',
        \\      'audit_entries_tenant_policy',
        \\      'audit_log_tenant_policy'
        \\  )
    , &.{});
    defer check.deinit();
    try std.testing.expect(check.rows.len > 0);
    const check_count = try std.fmt.parseInt(i64, check.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 0), check_count);
}

// ---------------------------------------------------------------------------
// TC-SPT-02-05 (AC-5)
// GIVEN migrations 062 and 063 have already been applied, WHEN all their DDL
// statements are re-executed (all guarded with IF EXISTS), THEN no error is
// raised and the structural state remains unchanged.
// ---------------------------------------------------------------------------
test "TC-SPT-02-05: re-running migrations 062 and 063 DDL on already-applied database raises no error" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // ── Re-run migration 063 statements ───────────────────────────────────────
    try h.conn.exec("DROP POLICY IF EXISTS process_definitions_tenant_policy   ON public.process_definitions",  &.{});
    try h.conn.exec("DROP POLICY IF EXISTS instance_projections_tenant_policy  ON public.instance_projections", &.{});
    try h.conn.exec("DROP POLICY IF EXISTS tasks_tenant_policy                 ON public.tasks",                &.{});
    try h.conn.exec("DROP POLICY IF EXISTS tokens_tenant_policy                ON public.tokens",               &.{});
    try h.conn.exec("DROP POLICY IF EXISTS audit_entries_tenant_policy         ON public.audit_entries",        &.{});
    try h.conn.exec("DROP POLICY IF EXISTS audit_log_tenant_policy             ON public.audit_log",            &.{});

    // ── Re-run migration 062 DROP INDEX IF EXISTS statements ──────────────────
    try h.conn.exec("DROP INDEX IF EXISTS idx_events_tenant_instance_seq",                 &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_events_tenant_global_seq",                   &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_events_archive_tenant_instance_seq",         &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_events_archive_tenant_global_seq",           &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_events_tenant_pipeline_run_seq",             &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_events_archive_tenant_pipeline_run_seq",     &.{});
    try h.conn.exec("DROP INDEX IF EXISTS uq_active_definition_tenant",                    &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_def_tenant_name_status",                     &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_def_tenant_created",                         &.{});
    try h.conn.exec("DROP INDEX IF EXISTS uq_instance_tenant_correlation",                 &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_proj_tenant_status",                         &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_proj_tenant_definition",                     &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_proj_tenant_instance",                       &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_task_tenant_instance",                       &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_task_tenant_pending_assignee",               &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_task_tenant_status",                         &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_token_tenant_instance",                      &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_token_tenant_active",                        &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_token_tenant_waiting",                       &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_audit_entries_tenant_time",                  &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_audit_entries_tenant_resource_time",         &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_audit_entries_tenant_pipeline_time",         &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_audit_entries_tenant_chain_lookup",          &.{});
    try h.conn.exec("DROP INDEX IF EXISTS uq_audit_entries_tenant_chain_hash",             &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_audit_entries_tenant_chain",                 &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_audit_log_tenant_time",                      &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_users_tenant_status_created",                &.{});
    try h.conn.exec("DROP INDEX IF EXISTS idx_groups_tenant_name",                         &.{});

    // ── Re-run migration 062 DROP CONSTRAINT IF EXISTS ────────────────────────
    try h.conn.exec(
        "ALTER TABLE IF EXISTS public.process_definitions DROP CONSTRAINT IF EXISTS uq_definition_tenant_version",
        &.{});

    // ── Re-run migration 062 DROP FUNCTION IF EXISTS ───────────────────────────
    try h.conn.exec("DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id() CASCADE", &.{});

    // ── Re-run migration 062 DISABLE ROW LEVEL SECURITY ───────────────────────
    try h.conn.exec("ALTER TABLE IF EXISTS public.process_definitions   DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.instance_projections  DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.tasks                 DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.tokens                DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.audit_entries         DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.audit_log             DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.events                DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.events_archive        DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.users                 DISABLE ROW LEVEL SECURITY", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.groups                DISABLE ROW LEVEL SECURITY", &.{});

    // ── Re-run migration 062 DROP COLUMN IF EXISTS statements ─────────────────
    try h.conn.exec("ALTER TABLE IF EXISTS public.events               DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.events_archive       DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.process_definitions  DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.instance_projections DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.tasks                DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.tokens               DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.audit_entries        DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.audit_log            DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.users                DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.groups               DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});
    try h.conn.exec("ALTER TABLE IF EXISTS public.tenant_hostnames     DROP COLUMN IF EXISTS tenant_id CASCADE", &.{});

    // ── Post-verify: structural state is unchanged ────────────────────────────
    // (a) Still 0 tenant_id columns on affected public tables.
    var col_check = try h.conn.query(alloc,
        \\SELECT count(*) FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND column_name  = 'tenant_id'
        \\  AND table_name IN (
        \\      'events', 'events_archive', 'process_definitions',
        \\      'instance_projections', 'tasks', 'tokens',
        \\      'audit_entries', 'audit_log', 'users', 'groups', 'tenant_hostnames'
        \\  )
    , &.{});
    defer col_check.deinit();
    try std.testing.expect(col_check.rows.len > 0);
    const col_check_count = try std.fmt.parseInt(i64, col_check.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 0), col_check_count);

    // (b) Still 0 known tenant RLS policies.
    var rls_check = try h.conn.query(alloc,
        \\SELECT count(*) FROM pg_policies
        \\WHERE schemaname = 'public'
        \\  AND policyname IN (
        \\      'process_definitions_tenant_policy',
        \\      'instance_projections_tenant_policy',
        \\      'tasks_tenant_policy',
        \\      'tokens_tenant_policy',
        \\      'audit_entries_tenant_policy',
        \\      'audit_log_tenant_policy'
        \\  )
    , &.{});
    defer rls_check.deinit();
    try std.testing.expect(rls_check.rows.len > 0);
    const rls_check_count = try std.fmt.parseInt(i64, rls_check.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 0), rls_check_count);
}

// ---------------------------------------------------------------------------
// TC-SPT-02-06 (AC-6)
// GIVEN the migration is interrupted mid-way through a tenant's data copy,
// WHEN the migration runner retries, THEN the partially-migrated tenant is
// detected via public.tenant_schemas.status and the copy is retried without
// duplicating rows.
//
// Implementation note: migration 061's DO block cannot be re-executed after
// migration 062 drops tenant_id from public tables. This test therefore
// verifies the state-machine MECHANISMS that enable the retry:
//   - status='pending' correctly signals "incomplete copy"
//   - The "CONTINUE WHEN status='active'" guard in migration 061 correctly
//     skips already-completed tenants
//   - bpm_provision_tenant_schema() is idempotent (ON CONFLICT DO NOTHING)
//     so repeated calls never duplicate tenant_schemas rows or schemas
// ---------------------------------------------------------------------------
test "TC-SPT-02-06: tenant_schemas status column enables interrupted copy detection and idempotent retry" {
    const alloc = std.testing.allocator;

    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const uuid_test = try randomUuidStr(alloc);
    defer alloc.free(uuid_test);

    var buf: [80]u8 = undefined;
    const schema_name_str = deriveSchemaName(uuid_test, &buf);

    // Step 1: Provision the tenant. bpm_provision_tenant_schema() creates the
    // schema and inserts a tenant_schemas row with DEFAULT status = 'pending'
    // (the DEFAULT was added by migration 061's ALTER TABLE ADD COLUMN).
    // This represents the state after bpm_provision_tenant_schema ran but
    // before migration 061's data copy loop marked it 'active'.
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_test});

    // Step 2: Verify initial status = 'pending' (incomplete migration state).
    var status_result = try h.conn.query(alloc,
        "SELECT status FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{uuid_test});
    defer status_result.deinit();
    try std.testing.expect(status_result.rows.len > 0);
    const initial_status = status_result.rows[0][0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pending", initial_status);

    // Step 3: Verify "skip if active" guard: a 'pending' tenant is NOT in the
    // skip set → migration 061's CONTINUE WHEN EXISTS (...status='active')
    // would NOT skip it → the copy would be retried.
    var pending_guard = try h.conn.query(alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND status = 'active'",
        &.{uuid_test});
    defer pending_guard.deinit();
    try std.testing.expect(pending_guard.rows.len > 0);
    const pending_guard_count = try std.fmt.parseInt(i64, pending_guard.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    // Expected 0: 'pending' → NOT in skip set → would be retried (no premature skip).
    try std.testing.expectEqual(@as(i64, 0), pending_guard_count);

    // Step 4: Re-provision the same tenant. bpm_provision_tenant_schema() uses
    // ON CONFLICT DO NOTHING on tenant_schemas → no duplicate row is created.
    // CREATE SCHEMA IF NOT EXISTS is also a no-op on the already-existing schema.
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_test});

    // Verify exactly 1 row in tenant_schemas (no duplication).
    var dedup_result = try h.conn.query(alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{uuid_test});
    defer dedup_result.deinit();
    try std.testing.expect(dedup_result.rows.len > 0);
    const dedup_count = try std.fmt.parseInt(i64, dedup_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), dedup_count);

    // Verify exactly 1 schema in pg_namespace (no duplicate schema created).
    var schema_count_result = try h.conn.query(alloc,
        "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
        &.{schema_name_str});
    defer schema_count_result.deinit();
    try std.testing.expect(schema_count_result.rows.len > 0);
    const schema_count = try std.fmt.parseInt(i64, schema_count_result.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), schema_count);

    // Step 5: Simulate migration copy completion — update status to 'active'.
    try h.conn.exec(
        "UPDATE public.tenant_schemas SET status = 'active' WHERE tenant_id = $1::uuid",
        &.{uuid_test});

    // Step 6: Verify "skip if active" guard now returns 1 → migration 061's
    // CONTINUE WHEN EXISTS (...status='active') WOULD skip this tenant.
    // This means a re-run of the migration would not duplicate data.
    var active_guard = try h.conn.query(alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND status = 'active'",
        &.{uuid_test});
    defer active_guard.deinit();
    try std.testing.expect(active_guard.rows.len > 0);
    const active_guard_count = try std.fmt.parseInt(i64, active_guard.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    // Expected 1: 'active' → in skip set → would be skipped (no duplicate copy).
    try std.testing.expectEqual(@as(i64, 1), active_guard_count);

    // Step 7: Re-provision once more after status='active'. Still exactly 1 row
    // and 1 schema — idempotency holds after migration completion.
    try h.conn.exec("SELECT public.bpm_provision_tenant_schema($1::uuid)", &.{uuid_test});

    var final_row_count = try h.conn.query(alloc,
        "SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
        &.{uuid_test});
    defer final_row_count.deinit();
    try std.testing.expect(final_row_count.rows.len > 0);
    const final_count = try std.fmt.parseInt(i64, final_row_count.rows[0][0] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), final_count);
}
