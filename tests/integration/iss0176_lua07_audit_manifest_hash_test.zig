//! Integration test for ISS-0176 / GH #504 — LUA-07 second acceptance
//! criterion: a script execution's manifest_hash must appear in the
//! persisted execution audit record.
//!
//! See src/design/iss0176-lua07-audit-manifest-hash-minimal-wiring.md §5 for
//! the full design of this test. The load-bearing assertion (TC-ISS-0176-01
//! below) queries `lua_script_execution_audit` directly by the `audit_id`
//! returned from `executeScriptForAudit` and compares the persisted
//! `manifest_hash` bytes against the manifest's own hash — this fails if the
//! INSERT (or its manifest_hash binding) is ever removed, unlike an assertion
//! against the in-memory ScriptResult alone (which the hash-producing side,
//! executor.zig's executeScriptWithManifest, already satisfies independent
//! of this fix).
//!
//! ## Why this file does NOT use tests/integration/helpers.zig's TestHarness
//!
//! TestHarness imports `bpm` (src/bpm.zig), which owns src/simulation/* as
//! plain members of its own module. src/lua/mod.zig's host_api/call_service.zig
//! escapes src/lua/ into ../../simulation/runtime.zig — the SAME files bpm
//! already owns. Zig 0.16 rejects a compile unit that imports both `bpm` and
//! `lua` (or anything reaching lua/mod.zig) with "file exists in modules
//! 'bpm' and 'lua_script_audit'" (verified empirically while wiring this
//! test). This file therefore connects to PostgreSQL directly through the
//! bpm-free `pool`/`tenant_context` modules and the `lua_script_audit`
//! module's own re-export of util/uuid.zig, rather than through TestHarness.
//! See src/lua_script_audit_root.zig for the full account.
//!
//! Consequently this test does NOT run migrations itself (Migrations.run's
//! advisory-lock/race-safety machinery documented in helpers.zig's
//! runMigrations() is nontrivial to duplicate safely) — it requires the
//! caller to have already applied migrations (`zig build migrate` against
//! BPM_TEST_DB_URL, as every workflow that runs this target already does
//! before dispatching TEST-RUNNER) and fails with a clear, typed error
//! (TableMissing) rather than a confusing raw SQL error if the table is
//! absent.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing at a real,
//! already-migrated PostgreSQL database.
const std = @import("std");
const testing = std.testing;
const portable_env = @import("env");
const pool_mod = @import("pool");
const tenant_context = @import("tenant_context");

const Pool = pool_mod.Pool;
const PoolConfig = pool_mod.PoolConfig;

// Reached through the dedicated lua_script_audit named module (build.zig),
// NOT through `bpm` — see the file-level doc comment above and
// src/lua_script_audit_root.zig for why these two module graphs can never
// share a compile unit.
const lua_script_audit_root = @import("lua_script_audit");
const lua_engine_audit = lua_script_audit_root.lua_script_audit;
const lua = lua_script_audit_root.lua;
const uuid_mod = lua_script_audit_root.uuid;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - integration test cannot run\n", .{});
            return error.TestEnvironmentMissing;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Tenant context must be set BEFORE Pool.init so every acquire() applies
    // SET search_path (schema isolation) — same convention every other
    // integration test in this suite follows (see exp601_tier_quota_test.zig).
    tenant_context.set(tenant_context.DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 3 });
}

/// Fails loudly and specifically if `zig build migrate` (migration 095) has
/// not been applied to this database yet, rather than letting every test
/// below fail with an opaque `relation does not exist`.
fn ensureTableExists(alloc: std.mem.Allocator, conn: *pool_mod.Conn) !void {
    var result = try conn.query(
        alloc,
        "SELECT to_regclass('lua_script_execution_audit')::text",
        &.{},
    );
    defer result.deinit();
    if (result.rows.len == 0 or result.rows[0][0] == null) {
        std.debug.print(
            "lua_script_execution_audit table not found — run `zig build migrate` " ++
                "against BPM_TEST_DB_URL first (migration 095_iss0176_lua_script_execution_audit.sql)\n",
            .{},
        );
        return error.TableMissing;
    }
}

fn cleanupAuditRow(pool: *Pool, audit_id_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM lua_script_execution_audit WHERE audit_id = $1::uuid",
        &.{audit_id_hex},
    ) catch {};
}

fn newUuidString(allocator: std.mem.Allocator) ![]u8 {
    return @constCast(try uuid_mod.newUuidV4(allocator));
}

/// Lowercase hex encode into a caller-supplied buffer (must be exactly
/// bytes.len * 2 long). std.fmt.fmtSliceHexLower is not available in this
/// Zig version's stdlib; this mirrors the hexEncodeAlloc helper already used
/// in src/secrets/store.zig and src/engine/lua_script_audit.zig.
fn hexEncodeInto(buf: []u8, bytes: []const u8) []const u8 {
    std.debug.assert(buf.len >= bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = alphabet[(b >> 4) & 0x0f];
        buf[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return buf[0 .. bytes.len * 2];
}

test "TC-ISS-0176-01: executeScriptForAudit persists manifest_hash to a queryable audit row" {
    const alloc = testing.allocator;

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);
    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    try ensureTableExists(alloc, conn);

    // Fresh per-test UUID for instance_id — never a hardcoded/shared value
    // (test isolation convention, docs/guides/test_infrastructure_guide.md §9).
    const instance_id = try newUuidString(alloc);
    defer alloc.free(instance_id);
    const actor_id = try newUuidString(alloc);
    defer alloc.free(actor_id);

    // Step 2 (design §5): a real ScriptManifest via validateManifest, exactly
    // as manifest.zig's own tests already do — no new fixture machinery.
    var caps = lua.capabilities.CapabilitySet.init(alloc);
    defer caps.deinit();
    try caps.add("cel:eval");

    const script_source = "return 1";
    var script_manifest = try lua.manifest.validateManifest(
        &.{"cel:eval"},
        &caps,
        lua.manifest.Limits.MIN_INSTRUCTIONS,
        lua.manifest.Limits.MIN_MEMORY_BYTES,
        lua.manifest.Limits.MIN_TIMEOUT_SECONDS,
        script_source,
        alloc,
    );
    defer script_manifest.deinit();

    const context = lua.ExecutionContext{
        .allocator = alloc,
        .capabilities = &caps,
        .instance_id = instance_id,
        .actor_id = actor_id,
    };

    // Step 3: the function under test, on the SAME connection this test then
    // reads back from — a separately acquired connection would not see an
    // uncommitted/differently-scoped write; here `conn.exec`/`conn.query` are
    // plain autocommitting statements on one connection, so read-your-write
    // is guaranteed without any transaction juggling.
    var outcome = try lua_engine_audit.executeScriptForAudit(
        alloc,
        conn,
        &context,
        script_source,
        &script_manifest,
        script_manifest.manifest_hash,
        actor_id,
    );
    defer outcome.script_result.deinit(alloc);

    var audit_id_buf: [36]u8 = undefined;
    const audit_id_hex = std.fmt.bufPrint(
        &audit_id_buf,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            outcome.audit_id[0],  outcome.audit_id[1],  outcome.audit_id[2],  outcome.audit_id[3],
            outcome.audit_id[4],  outcome.audit_id[5],  outcome.audit_id[6],  outcome.audit_id[7],
            outcome.audit_id[8],  outcome.audit_id[9],  outcome.audit_id[10], outcome.audit_id[11],
            outcome.audit_id[12], outcome.audit_id[13], outcome.audit_id[14], outcome.audit_id[15],
        },
    ) catch unreachable;
    defer cleanupAuditRow(&pool, audit_id_hex);

    // Step 4: the executor's own contract (already true today independent of
    // this fix) — not what this test exists to catch, but a sanity check
    // that the call actually ran the script successfully.
    try testing.expect(outcome.script_result.success);
    try testing.expect(outcome.script_result.manifest_hash != null);
    try testing.expectEqualSlices(u8, &script_manifest.manifest_hash, &outcome.script_result.manifest_hash.?);

    // Step 5 — THE LOAD-BEARING ASSERTION. Query the persisted row directly
    // by audit_id and compare manifest_hash bytes. Deleting the INSERT in
    // executeScriptForAudit (or dropping just the manifest_hash column
    // binding from it) makes this query return no row, or a row whose
    // manifest_hash does not match — this assertion fails either way. There
    // is no path by which commenting out the persistence write leaves this
    // test green.
    var result = try conn.query(
        alloc,
        \\SELECT encode(manifest_hash, 'hex'), instance_id::text, script_success
        \\FROM lua_script_execution_audit
        \\WHERE audit_id = $1::uuid
    ,
        &.{audit_id_hex},
    );
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    const row = result.rows[0];

    const persisted_hash_hex = row[0] orelse return error.MissingManifestHash;
    var expected_hash_hex_buf: [64]u8 = undefined;
    const expected_hash_hex = hexEncodeInto(&expected_hash_hex_buf, &script_manifest.manifest_hash);
    try testing.expectEqualStrings(expected_hash_hex, persisted_hash_hex);

    const persisted_instance_id = row[1] orelse return error.MissingInstanceId;
    try testing.expectEqualStrings(instance_id, persisted_instance_id);

    // PostgreSQL's text-format wire representation of BOOLEAN is 't'/'f',
    // not 'true'/'false' — confirmed empirically running this test against
    // real Postgres (the goal of this whole file: no assumption goes
    // unverified against the real database).
    const persisted_success = row[2] orelse return error.MissingSuccessFlag;
    try testing.expectEqualStrings("t", persisted_success);
}

test "TC-ISS-0176-02: executeScriptForAudit rejects a malformed instance_id without persisting anything" {
    const alloc = testing.allocator;

    const db_url = try testDbUrl(alloc);
    defer alloc.free(db_url);
    var pool = try makePool(alloc, db_url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    try ensureTableExists(alloc, conn);

    var caps = lua.capabilities.CapabilitySet.init(alloc);
    defer caps.deinit();

    const script_source = "return 1";
    var script_manifest = try lua.manifest.validateManifest(
        &.{},
        &caps,
        lua.manifest.Limits.MIN_INSTRUCTIONS,
        lua.manifest.Limits.MIN_MEMORY_BYTES,
        lua.manifest.Limits.MIN_TIMEOUT_SECONDS,
        script_source,
        alloc,
    );
    defer script_manifest.deinit();

    // Not a canonical UUID — must be rejected before the executor even runs.
    const context = lua.ExecutionContext{
        .allocator = alloc,
        .capabilities = &caps,
        .instance_id = "not-a-real-uuid",
        .actor_id = "also-not-a-uuid",
    };

    // Baseline row count before the rejected call — avoids ever binding the
    // deliberately-malformed instance_id string against a UUID-typed column
    // (which PostgreSQL would reject at the SQL layer regardless of what
    // this test is trying to prove, and which the asymmetric-cast linter
    // flags for uuid-typed columns compared via ::text).
    var before_result = try conn.query(alloc, "SELECT count(*) FROM lua_script_execution_audit", &.{});
    defer before_result.deinit();
    const before_count = before_result.rows[0][0] orelse "0";
    const before_count_owned = try alloc.dupe(u8, before_count);
    defer alloc.free(before_count_owned);

    const result = lua_engine_audit.executeScriptForAudit(
        alloc,
        conn,
        &context,
        script_source,
        &script_manifest,
        script_manifest.manifest_hash,
        null,
    );
    try testing.expectError(lua_engine_audit.LuaScriptAuditError.InvalidInstanceId, result);

    // Zero rows added: InvalidInstanceId returned before any INSERT was
    // attempted, so the table's row count is unchanged by this call.
    var after_result = try conn.query(alloc, "SELECT count(*) FROM lua_script_execution_audit", &.{});
    defer after_result.deinit();
    const after_count = after_result.rows[0][0] orelse "0";
    try testing.expectEqualStrings(before_count_owned, after_count);
}
