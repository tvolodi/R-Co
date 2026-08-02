//! Integration regression tests for ISS-0121 / GitHub #387 —
//! `TestHarness.newUuid()` and `TestHarness.newUuidString(allocator)` helpers.
//!
//! Pins the contract documented in
//!   * `src/design/iss0121_per_test_uuids.md` §3 (API contract)
//!   * `tests/integration/helpers.zig` (TestHarness impl)
//!   * `src/util/uuid.zig` (`generateUuidV4BytesInto`, `newUuidV4`)
//!
//! Per DIRECTIVE T-1: real PostgreSQL only via `BPM_TEST_DB_URL` for TC-07.
//! TC-01..TC-06 are unit-style and require no DB connection — both helpers
//! `_ = self;` so an uninitialised `TestHarness` is safe to use.
//!
//! Per DIRECTIVE T-3 (frontend visual verification): N/A — backend regression.
//!
//! Test cases mirror `tests/specs/ISS-0121.md`:
//!   TC-ISS-0121-01: newUuid returns a non-zero UUID
//!   TC-ISS-0121-02: newUuid called twice returns distinct UUIDs
//!   TC-ISS-0121-03: newUuid returns an RFC 4122 v4 UUID (version + variant bits)
//!   TC-ISS-0121-04: newUuidString returns a 36-byte hyphenated lowercase string
//!   TC-ISS-0121-05: newUuidString called twice returns distinct strings
//!   TC-ISS-0121-06: 1000 successive newUuid calls are pairwise distinct
//!   TC-ISS-0121-07: round-trip — newUuidString into audit_entries.resource_id

const std = @import("std");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Uuid = bpm.uuid.Uuid;

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0121-01 — newUuid returns a non-zero UUID
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0121-01: newUuid returns a non-zero UUID" {
    var h: TestHarness = undefined;
    const u = h.newUuid();

    // The all-zero UUID is the platform's default-tenant sentinel; it MUST
    // never be returned by the helper. A broken fillRandomBytes dispatch
    // (or a dead-code path that returns a zeroed stack buffer) would fail
    // this assertion.
    const all_zero = [_]u8{0} ** 16;
    try testing.expect(!std.mem.eql(u8, &u, &all_zero));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0121-02 — newUuid called twice returns distinct UUIDs
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0121-02: newUuid called twice returns distinct UUIDs" {
    var h: TestHarness = undefined;
    const first = h.newUuid();
    const second = h.newUuid();

    // Independence per call. A test that seeded the generator with a fixed
    // value, or returned a process-global singleton UUID, would fail this.
    try testing.expect(!std.mem.eql(u8, &first, &second));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0121-03 — newUuid is RFC 4122 v4 compliant (version + variant bits)
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0121-03: newUuid is RFC 4122 v4 compliant" {
    var h: TestHarness = undefined;
    const u = h.newUuid();

    // RFC 4122 §4.4: byte 6 high nibble = 0x4 (version 4).
    try testing.expectEqual(@as(u8, 0x40), u[6] & 0xF0);

    // RFC 4122 §4.1.1: byte 8 top two bits = 0b10 (variant).
    try testing.expectEqual(@as(u8, 0x80), u[8] & 0xC0);
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0121-04 — newUuidString returns a 36-byte hyphenated lowercase string
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0121-04: newUuidString returns a 36-byte hyphenated lowercase string" {
    const alloc = testing.allocator;
    var h: TestHarness = undefined;
    const s = try h.newUuidString(alloc);
    defer alloc.free(s);

    // Length.
    try testing.expectEqual(@as(usize, 36), s.len);

    // Canonical dash positions: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
    try testing.expectEqual('-', s[8]);
    try testing.expectEqual('-', s[13]);
    try testing.expectEqual('-', s[18]);
    try testing.expectEqual('-', s[23]);

    // Lowercase hex + dash only (RFC 4122 canonical representation).
    for (s, 0..) |ch, i| {
        const is_dash = ch == '-';
        const is_hex = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        try testing.expect(is_dash or is_hex);
        _ = i; // index used implicitly above; silence unused warning if Zig elides
    }

    // Version nibble at position 14 (the 13th char of the 3rd group) is '4'.
    try testing.expectEqual('4', s[14]);

    // Variant nibble at position 19 (the 17th char) is one of '8'..'b'.
    const v = s[19];
    try testing.expect(v == '8' or v == '9' or v == 'a' or v == 'b');
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0121-05 — newUuidString called twice returns distinct strings
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0121-05: newUuidString called twice returns distinct strings" {
    const alloc = testing.allocator;
    var h: TestHarness = undefined;
    const s1 = try h.newUuidString(alloc);
    defer alloc.free(s1);
    const s2 = try h.newUuidString(alloc);
    defer alloc.free(s2);

    try testing.expect(!std.mem.eql(u8, s1, s2));
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0121-06 — 1000 successive newUuid calls are pairwise distinct
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0121-06: 1000 successive newUuid calls are pairwise distinct" {
    const alloc = testing.allocator;
    var h: TestHarness = undefined;

    const N: usize = 1000;
    var list = try std.ArrayList(Uuid).initCapacity(alloc, N);
    defer list.deinit(alloc);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const u = h.newUuid();
        try list.append(alloc, u);
    }

    try testing.expectEqual(N, list.items.len);

    // O(N^2) pairwise comparison — bounded to 499 500 pairs at N=1000.
    // 128-bit CSPRNG output makes a collision vanishingly unlikely
    // (~ N^2 / 2^129) so any duplicate is a definitive failure of the
    // random source or the version/variant masking.
    var a: usize = 0;
    while (a < N) : (a += 1) {
        var b: usize = a + 1;
        while (b < N) : (b += 1) {
            try testing.expect(!std.mem.eql(u8, &list.items[a], &list.items[b]));
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TC-ISS-0121-07 — round-trip: newUuidString through audit_entries.resource_id
// ─────────────────────────────────────────────────────────────────────────────
test "TC-ISS-0121-07: newUuidString round-trips through audit_entries.resource_id" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // Per-test audit_id + tenant_id + actor_id, all generated by the helper
    // under test. resource_type is fixed per TC-07 so the SELECT is
    // unambiguously isolated.
    const audit_id = try h.newUuidString(alloc);
    defer alloc.free(audit_id);
    const tenant_id = try h.newUuidString(alloc);
    defer alloc.free(tenant_id);
    const actor_id = try h.newUuidString(alloc);
    defer alloc.free(actor_id);
    const resource_id = try h.newUuidString(alloc);
    defer alloc.free(resource_id);

    const resource_type = "iss0121.roundtrip.tc07";
    const action = "iss0121.tc07.create";

    // INSERT. The trg_bpm_audit_apply_chain_hash BEFORE INSERT trigger fires
    // and computes chain_hash; the row's resource_id column accepts TEXT so
    // the generated 36-char hyphenated string lands in the same column
    // family as audit_chain_utf8_test.zig exercises.
    try h.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, tenant_id, actor_id, action, resource_type, resource_id,
        \\  "timestamp", before_state, after_state, trace_id
        \\)
        \\VALUES (
        \\  $1, $2, $3, $4, $5, $6, NOW(), NULL, '{"k":"v"}'::jsonb, 'iss0121-test'
        \\)
    , &.{
        audit_id,
        tenant_id,
        actor_id,
        action,
        resource_type,
        resource_id,
    });

    // SELECT the row back and compare resource_id byte-for-byte.
    var row_q = try h.conn.query(
        alloc,
        \\SELECT resource_id, octet_length(resource_id)
        \\FROM audit_entries
        \\WHERE audit_id = $1
    , &.{audit_id});
    defer row_q.deinit();

    try testing.expectEqual(@as(usize, 1), row_q.rows.len);
    const selected = row_q.rows[0][0] orelse "";
    try testing.expectEqualStrings(resource_id, selected);
    try testing.expectEqual(
        @as(usize, 36),
        std.fmt.parseInt(usize, row_q.rows[0][1] orelse "0", 10) catch 0,
    );
}
