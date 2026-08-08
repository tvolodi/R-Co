//! Integration tests for ADP-09 -- tamper-evident audit chaining.

const std = @import("std");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

fn restoreAuditNoUpdateTrigger(conn: anytype) !void {
    try conn.exec(
        \\DROP TRIGGER IF EXISTS trg_audit_entries_no_update ON audit_entries
    ,
        &.{},
    );
    try conn.exec(
        \\CREATE TRIGGER trg_audit_entries_no_update
        \\BEFORE UPDATE ON audit_entries
        \\FOR EACH ROW EXECUTE FUNCTION bpm_audit_immutable_guard()
    ,
        &.{},
    );
}

fn restoreAuditChainTrigger(conn: anytype) !void {
    try conn.exec(
        \\DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries
    ,
        &.{},
    );
    try conn.exec(
        \\CREATE TRIGGER trg_bpm_audit_apply_chain_hash
        \\BEFORE INSERT ON audit_entries
        \\FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash()
    ,
        &.{},
    );
}

fn restoreAuditPreventUpdateTrigger(conn: anytype) !void {
    // Migration 059 consolidated duplicate immutability triggers.
    // The old trg_bpm_audit_prevent_update trigger and bpm_audit_enforce_immutability()
    // function were removed. The sole immutability guard is now trg_audit_entries_no_update
    // using bpm_audit_immutable_guard(), handled by restoreAuditNoUpdateTrigger().
    _ = conn;
}

test "TC-ADP-09-01: migration adds nullable chain columns and validation primitives" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    var cols = try harness.conn.query(
        alloc,
        \\SELECT column_name, is_nullable
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name = 'audit_entries'
        \\  AND column_name IN ('chain_hash', 'prev_chain_hash')
        \\ORDER BY column_name ASC
    ,
        &.{},
    );
    defer cols.deinit();

    try testing.expectEqual(@as(usize, 2), cols.rows.len);
    try testing.expectEqualStrings("chain_hash", cols.rows[0][0] orelse "");
    try testing.expectEqualStrings("YES", cols.rows[0][1] orelse "");
    try testing.expectEqualStrings("prev_chain_hash", cols.rows[1][0] orelse "");
    try testing.expectEqualStrings("YES", cols.rows[1][1] orelse "");

    var funcs = try harness.conn.query(
        alloc,
        \\SELECT proname
        \\FROM pg_proc
        \\WHERE proname IN (
        \\  'bpm_audit_compute_chain_hash',
        \\  'bpm_audit_apply_chain_hash',
        \\  'bpm_audit_validate_chain'
        \\)
        \\ORDER BY proname ASC
    ,
        &.{},
    );
    defer funcs.deinit();

    try testing.expectEqual(@as(usize, 3), funcs.rows.len);

    var idx = try harness.conn.query(
        alloc,
        \\SELECT indexname
        \\FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND indexname IN (
        \\    'idx_audit_entries_tenant_chain_lookup',
        \\    'uq_audit_entries_tenant_chain_hash'
        \\  )
        \\ORDER BY indexname ASC
    ,
        &.{},
    );
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.rows.len);
}

test "TC-ADP-09-05: canonical hash computation is stable for semantically equal JSON" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    var q = try harness.conn.query(
        alloc,
        \\SELECT
        \\  bpm_audit_compute_chain_hash(
        \\    'e9000000-0000-0000-0000-000000000001'::uuid,
        \\    'e9000000-0000-0000-0000-000000000101'::uuid,
        \\    'e9000000-0000-0000-0000-000000000201'::uuid,
        \\    'definition.update',
        \\    'definition',
        \\    'e9000000-0000-0000-0000-000000000301'::uuid,
        \\    '2026-05-26T10:30:02Z'::timestamptz,
        \\    '{"alpha":1,"beta":2}'::jsonb,
        \\    '{"flags":{"a":true,"b":false},"status":"ACTIVE"}'::jsonb,
        \\    '22222222-3333-4444-5555-666666666666'::uuid,
        \\    NULL,
        \\    '0000000000000000000000000000000000000000000000000000000000000000',
        \\    NULL
        \\  ) AS h1,
        \\  bpm_audit_compute_chain_hash(
        \\    'e9000000-0000-0000-0000-000000000001'::uuid,
        \\    'e9000000-0000-0000-0000-000000000101'::uuid,
        \\    'e9000000-0000-0000-0000-000000000201'::uuid,
        \\    'definition.update',
        \\    'definition',
        \\    'e9000000-0000-0000-0000-000000000301'::uuid,
        \\    '2026-05-26T10:30:02Z'::timestamptz,
        \\    '{"beta":2,"alpha":1}'::jsonb,
        \\    '{"status":"ACTIVE","flags":{"b":false,"a":true}}'::jsonb,
        \\    '22222222-3333-4444-5555-666666666666'::uuid,
        \\    NULL,
        \\    '0000000000000000000000000000000000000000000000000000000000000000',
        \\    NULL
        \\  ) AS h2
    ,
        &.{},
    );
    defer q.deinit();

    try testing.expectEqual(@as(usize, 1), q.rows.len);
    const row = q.rows[0];
    try testing.expectEqualStrings(row[0] orelse "", row[1] orelse "");
}

test "TC-ADP-09-02: new rows chain deterministically with tenant-scoped predecessors" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant_a = try harness.newUuidString(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try harness.newUuidString(alloc);
    defer alloc.free(tenant_b);

    try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state, pipeline_run_id
        \\)
        \\VALUES
        \\  ('a9000000-0000-0000-0000-000000000101'::uuid, $1::uuid, 'a9000000-0000-0000-0000-000000000201'::uuid, 'definition.create', 'definition', 'a9000000-0000-0000-0000-000000000301'::uuid, '2026-05-26T10:00:01Z'::timestamptz, NULL, '{"status":"DRAFT"}'::jsonb, NULL),
        \\  ('a9000000-0000-0000-0000-000000000102'::uuid, $1::uuid, 'a9000000-0000-0000-0000-000000000201'::uuid, 'definition.update', 'definition', 'a9000000-0000-0000-0000-000000000301'::uuid, '2026-05-26T10:00:02Z'::timestamptz, '{"status":"DRAFT"}'::jsonb, '{"status":"ACTIVE"}'::jsonb, '11111111-2222-3333-4444-555555555555'::uuid),
        \\  ('b9000000-0000-0000-0000-000000000101'::uuid, $2::uuid, 'b9000000-0000-0000-0000-000000000201'::uuid, 'task.create', 'task', 'b9000000-0000-0000-0000-000000000301'::uuid, '2026-05-26T10:00:03Z'::timestamptz, NULL, '{"status":"PENDING"}'::jsonb, NULL),
        \\  ('b9000000-0000-0000-0000-000000000102'::uuid, $2::uuid, 'b9000000-0000-0000-0000-000000000201'::uuid, 'task.complete', 'task', 'b9000000-0000-0000-0000-000000000301'::uuid, '2026-05-26T10:00:04Z'::timestamptz, '{"status":"PENDING"}'::jsonb, '{"status":"COMPLETED"}'::jsonb, NULL)
    ,
        &.{ tenant_a, tenant_b },
    );

    var first_a_q = try harness.conn.query(
        alloc,
        "SELECT prev_chain_hash, chain_hash FROM audit_entries WHERE audit_id = 'a9000000-0000-0000-0000-000000000101'::uuid",
        &.{},
    );
    defer first_a_q.deinit();
    try testing.expectEqual(@as(usize, 1), first_a_q.rows.len);
    const first_a = first_a_q.rows[0];

    var second_a_q = try harness.conn.query(
        alloc,
        "SELECT prev_chain_hash, chain_hash FROM audit_entries WHERE audit_id = 'a9000000-0000-0000-0000-000000000102'::uuid",
        &.{},
    );
    defer second_a_q.deinit();
    try testing.expectEqual(@as(usize, 1), second_a_q.rows.len);
    const second_a = second_a_q.rows[0];

    var first_b_q = try harness.conn.query(
        alloc,
        "SELECT prev_chain_hash, chain_hash FROM audit_entries WHERE audit_id = 'b9000000-0000-0000-0000-000000000101'::uuid",
        &.{},
    );
    defer first_b_q.deinit();
    try testing.expectEqual(@as(usize, 1), first_b_q.rows.len);
    const first_b = first_b_q.rows[0];

    var second_b_q = try harness.conn.query(
        alloc,
        "SELECT prev_chain_hash, chain_hash FROM audit_entries WHERE audit_id = 'b9000000-0000-0000-0000-000000000102'::uuid",
        &.{},
    );
    defer second_b_q.deinit();
    try testing.expectEqual(@as(usize, 1), second_b_q.rows.len);
    const second_b = second_b_q.rows[0];

    try testing.expect(first_a[0] == null);
    try testing.expect(first_a[1] != null);
    try testing.expect(second_a[0] != null);
    try testing.expect(second_a[1] != null);
    try testing.expectEqualStrings(first_a[1].?, second_a[0].?);

    try testing.expect(first_b[0] == null);
    try testing.expect(first_b[1] != null);
    try testing.expect(second_b[0] != null);
    try testing.expect(second_b[1] != null);
    try testing.expectEqualStrings(first_b[1].?, second_b[0].?);

    var deterministic_q = try harness.conn.query(
        alloc,
        \\SELECT bpm_audit_compute_chain_hash(
        \\  tenant_id,
        \\  audit_id,
        \\  actor_id,
        \\  action,
        \\  resource_type,
        \\  resource_id,
        \\  "timestamp",
        \\  before_state,
        \\  after_state,
        \\  pipeline_run_id,
        \\  NULL,
        \\  prev_chain_hash,
        \\  NULL
        \\) AS expected_chain,
        \\chain_hash
        \\FROM audit_entries
        \\WHERE audit_id = 'a9000000-0000-0000-0000-000000000102'::uuid
    ,
        &.{},
    );
    defer deterministic_q.deinit();
    try testing.expectEqual(@as(usize, 1), deterministic_q.rows.len);
    const deterministic = deterministic_q.rows[0];

    try testing.expectEqualStrings(deterministic[0] orelse "", deterministic[1] orelse "");
}

test "TC-ADP-09-03: chain validation reports tampered row first and descendants after" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant = try harness.newUuidString(alloc);
    defer alloc.free(tenant);

    try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state
        \\)
        \\VALUES
        \\  ('c9000000-0000-0000-0000-000000000101'::uuid, $1::uuid, 'c9000000-0000-0000-0000-000000000201'::uuid, 'definition.create', 'definition', 'c9000000-0000-0000-0000-000000000301'::uuid, '2026-05-26T10:10:01Z'::timestamptz, NULL, '{"status":"DRAFT"}'::jsonb),
        \\  ('c9000000-0000-0000-0000-000000000102'::uuid, $1::uuid, 'c9000000-0000-0000-0000-000000000201'::uuid, 'definition.update', 'definition', 'c9000000-0000-0000-0000-000000000301'::uuid, '2026-05-26T10:10:02Z'::timestamptz, '{"status":"DRAFT"}'::jsonb, '{"status":"ACTIVE"}'::jsonb),
        \\  ('c9000000-0000-0000-0000-000000000103'::uuid, $1::uuid, 'c9000000-0000-0000-0000-000000000201'::uuid, 'definition.archive', 'definition', 'c9000000-0000-0000-0000-000000000301'::uuid, '2026-05-26T10:10:03Z'::timestamptz, '{"status":"ACTIVE"}'::jsonb, '{"status":"ARCHIVED"}'::jsonb)
    ,
        &.{tenant},
    );

    try harness.conn.exec(
        \\DROP TRIGGER IF EXISTS trg_audit_entries_no_update ON audit_entries
    ,
        &.{},
    );
    defer restoreAuditNoUpdateTrigger(&harness.conn) catch {};

    try harness.conn.exec(
        \\DROP TRIGGER IF EXISTS trg_bpm_audit_prevent_update ON audit_entries
    ,
        &.{},
    );
    defer restoreAuditPreventUpdateTrigger(&harness.conn) catch {};

    try harness.conn.exec(
        "UPDATE audit_entries SET action = 'definition.tampered' WHERE audit_id = 'c9000000-0000-0000-0000-000000000102'::uuid",
        &.{},
    );

    try restoreAuditNoUpdateTrigger(&harness.conn);
    try restoreAuditPreventUpdateTrigger(&harness.conn);

    var issues = try harness.conn.query(
        alloc,
        \\SELECT audit_id::text, sequence_no::text, code
        \\FROM bpm_audit_validate_chain($1::uuid, NULL, NULL, false)
        \\ORDER BY sequence_no ASC
    ,
        &.{tenant},
    );
    defer issues.deinit();

    try testing.expect(issues.rows.len >= 2);
// GH-512 retention: deterministic actor fixture for audit-chain / IO-capture tests (matches SQL VALUES and expectEqualStrings)
    try testing.expectEqualStrings("c9000000-0000-0000-0000-000000000102", issues.rows[0][0] orelse "");
    try testing.expectEqualStrings("ChainHashMismatch", issues.rows[0][2] orelse "");
// GH-512 retention: deterministic actor fixture for audit-chain / IO-capture tests (matches SQL VALUES and expectEqualStrings)
    try testing.expectEqualStrings("c9000000-0000-0000-0000-000000000103", issues.rows[1][0] orelse "");
    try testing.expectEqualStrings("PrevHashMismatch", issues.rows[1][2] orelse "");
}

test "TC-ADP-09-04: legacy pre-chain rows remain valid and boundary row starts cleanly" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const tenant = try harness.newUuidString(alloc);
    defer alloc.free(tenant);

    try harness.conn.exec(
        \\DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries
    ,
        &.{},
    );
    defer restoreAuditChainTrigger(&harness.conn) catch {};

    try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state, chain_hash, prev_chain_hash
        \\)
        \\VALUES (
        \\  'd9000000-0000-0000-0000-000000000101'::uuid,
        \\  $1::uuid,
        \\  'd9000000-0000-0000-0000-000000000201'::uuid,
        \\  'definition.legacy',
        \\  'definition',
        \\  'd9000000-0000-0000-0000-000000000301'::uuid,
        \\  '2026-05-26T10:20:01Z'::timestamptz,
        \\  NULL,
        \\  '{"status":"LEGACY"}'::jsonb,
        \\  NULL,
        \\  NULL
        \\)
    ,
        &.{tenant},
    );

    try restoreAuditChainTrigger(&harness.conn);

    try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state
        \\)
        \\VALUES (
        \\  'd9000000-0000-0000-0000-000000000102'::uuid,
        \\  $1::uuid,
        \\  'd9000000-0000-0000-0000-000000000201'::uuid,
        \\  'definition.create',
        \\  'definition',
        \\  'd9000000-0000-0000-0000-000000000301'::uuid,
        \\  '2026-05-26T10:20:02Z'::timestamptz,
        \\  NULL,
        \\  '{"status":"DRAFT"}'::jsonb
        \\)
    ,
        &.{tenant},
    );

    var boundary_q = try harness.conn.query(
        alloc,
        "SELECT prev_chain_hash, chain_hash FROM audit_entries WHERE audit_id = 'd9000000-0000-0000-0000-000000000102'::uuid",
        &.{},
    );
    defer boundary_q.deinit();
    try testing.expectEqual(@as(usize, 1), boundary_q.rows.len);
    const boundary = boundary_q.rows[0];

    try testing.expect(boundary[0] == null);
    try testing.expect(boundary[1] != null);

    var issues = try harness.conn.query(
        alloc,
        "SELECT code FROM bpm_audit_validate_chain($1::uuid, NULL, NULL, false)",
        &.{tenant},
    );
    defer issues.deinit();

    try testing.expectEqual(@as(usize, 0), issues.rows.len);
}
