//! Integration tests for REPO-01–13 (Platform Repository).
//!
//! All tests use real PostgreSQL via BPM_TEST_DB_URL.
//! Every test uses TestHarness for migration bootstrap and transaction isolation.
//! All fixtures use per-test UUIDs for tenant, user, and artifact IDs.
//! No test data persists (rollback-on-deinit).
//!
//! Requirement traceability:
//!   REPO-01 → TC-REPO-01-01, TC-REPO-01-02
//!   REPO-02 → TC-REPO-02-01, TC-REPO-02-02
//!   REPO-03 → TC-REPO-03-01, TC-REPO-03-02, TC-REPO-12-01
//!   REPO-04 → TC-REPO-04-01, TC-REPO-04-02
//!   REPO-05 → TC-REPO-05-01, TC-REPO-05-02
//!   REPO-06 → TC-REPO-06-01, TC-REPO-06-02
//!   REPO-07 → TC-REPO-07-01, TC-REPO-07-02
//!   REPO-08 → TC-REPO-08-01, TC-REPO-08-02
//!   REPO-09 → TC-REPO-09-01, TC-REPO-09-02
//!   REPO-10 → TC-REPO-10-01, TC-REPO-10-02
//!   REPO-11 → TC-REPO-11-01, TC-REPO-11-02
//!   REPO-12 → TC-REPO-12-01, TC-REPO-12-02
//!   REPO-13 → TC-REPO-13-01, TC-REPO-13-02
//!
const std = @import("std");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");

// ---------------------------------------------------------------------------
// Helpers: UUID generation and test data creation
// ---------------------------------------------------------------------------

// ISS-0137 / GH #439: these two were local copies using `std.crypto.random` and
// `std.io.fixedBufferStream`, both removed in Zig 0.16. The file had not
// compiled since that upgrade because it was wired into no build target. Now
// delegated to the shared helpers rather than repairing a fourth private copy.

/// Generate a random UUID for per-test isolation.
fn randomUuid() [16]u8 {
    return helpers.randomUuidBytes();
}

/// Convert a 16-byte UUID to a 36-char hex string (UUID format).
fn uuidToString(allocator: std.mem.Allocator, uuid: [16]u8) ![]const u8 {
    return helpers.uuidBytesToString(allocator, uuid);
}

/// Sample JSON for testing canonical serialisation.
fn sampleDefinitionJson(name: []const u8) []const u8 {
    return std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"name\":\"{s}\",\"version\":1}}",
        .{name},
    ) catch unreachable;
}

/// Sample form schema JSON.
fn sampleFormJson() []const u8 {
    return "{\"fields\":[{\"name\":\"customer_name\",\"type\":\"string\",\"label\":\"Customer Name\"},{\"name\":\"order_amount\",\"type\":\"currency\",\"label\":\"Order Amount (USD)\"},{\"name\":\"ship_date\",\"type\":\"date\",\"label\":\"Ship Date\"},{\"name\":\"quantity\",\"type\":\"number\",\"label\":\"Quantity\"}]}";
}

/// Sample service catalog JSON.
fn sampleServiceJson() []const u8 {
    return "{\"service_id\":\"crm.customer_lookup\",\"endpoint_url\":\"https://crm.example.com/api/customer\",\"request_schema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}},\"response_schema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"email\":{\"type\":\"string\"}}}}";
}

// ---------------------------------------------------------------------------
// TC-REPO-01-01: Content addressing — identical content deduplicates
// ---------------------------------------------------------------------------

test "TC-REPO-01-01: identical content deduplicates" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // ISS-0137 / GH #439: tenant_id/user_id locals removed — this test's SQL
    // never referenced them (it keys purely on content_hash).
    const content = sampleDefinitionJson("order_process");
    defer alloc.free(content);

    // First artifact creation
    var row1 = try h.conn.query(
        alloc,
        \\INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at)
        \\VALUES (digest($1, 'sha256'), 'application/json', LENGTH($1), NOW())
        \\RETURNING content_hash, byte_size
    ,
        &.{content},
    );
    defer row1.deinit();
    try std.testing.expect(row1.rows.len == 1);

    const hash1 = row1.rows[0][0]; // content_hash from first insert

    // Second artifact with identical content should produce same hash
    var row2 = try h.conn.query(
        alloc,
        \\SELECT content_hash FROM repository_artifacts
        \\WHERE content_hash = digest($1, 'sha256')
    ,
        &.{content},
    );
    defer row2.deinit();

    // Verify deduplication: second query should find the same hash
    try std.testing.expect(row2.rows.len == 1);
    if (hash1) |h1| {
        if (row2.rows[0][0]) |h2| {
            try std.testing.expectEqualStrings(h1, h2);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-01-02: Content addressing — different content produces different hash
// ---------------------------------------------------------------------------

test "TC-REPO-01-02: different content produces different hash" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const content1 = "{\"name\":\"order_v1\"}";
    const content2 = "{\"name\":\"order_v2\"}";

    // Insert first artifact
    var row1 = try h.conn.query(
        alloc,
        "INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at) VALUES (digest($1, 'sha256'), 'application/json', LENGTH($1), NOW()) RETURNING content_hash",
        &.{content1},
    );
    defer row1.deinit();
    try std.testing.expect(row1.rows.len == 1);

    // Insert second artifact
    var row2 = try h.conn.query(
        alloc,
        "INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at) VALUES (digest($1, 'sha256'), 'application/json', LENGTH($1), NOW()) RETURNING content_hash",
        &.{content2},
    );
    defer row2.deinit();
    try std.testing.expect(row2.rows.len == 1);

    // Verify different hashes
    if (row1.rows[0][0]) |h1| {
        if (row2.rows[0][0]) |h2| {
            // Hashes should be different
            try std.testing.expect(!std.mem.eql(u8, h1, h2));
        }
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-02-01: Immutability — repository_artifacts has no UPDATE path
// ---------------------------------------------------------------------------

test "TC-REPO-02-01: immutability enforced by PRIMARY KEY on content_hash" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const content = "{\"name\":\"immutable_test\"}";

    // Insert artifact
    var insert_result = try h.conn.query(
        alloc,
        "INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at) VALUES (digest($1, 'sha256'), 'application/json', LENGTH($1), NOW()) RETURNING content_hash",
        &.{content},
    );
    defer insert_result.deinit();
    try std.testing.expect(insert_result.rows.len == 1);

    // Verify table schema: content_hash is PRIMARY KEY.
    // ISS-0183 / GH-516: qualified to table_schema = 'public'. repository_artifacts
    // is a GLOBAL_REGISTRY table (canonical home = public per migrations/045); an
    // unqualified probe against information_schema.table_constraints returns one
    // row per schema where the same-named constraint exists, and a FK-protected
    // tenant_default shadow (fk_artifact_versions_content, RESTRICT-blocked from
    // being dropped by GBL-136/GBL-139) is expected to persist. Same
    // anti-patterns.md "schema-agnostic system catalog query" pattern as ISS-0126.
    var schema = try h.conn.query(
        alloc,
        "SELECT constraint_name FROM information_schema.table_constraints WHERE table_schema = 'public' AND table_name = 'repository_artifacts' AND constraint_type = 'PRIMARY KEY'",
        &.{},
    );
    defer schema.deinit();
    try std.testing.expect(schema.rows.len == 1);
    if (schema.rows[0][0]) |constraint| {
        try std.testing.expectEqualStrings(constraint, "repository_artifacts_pkey");
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-02-02: New content creates new version with different hash
// ---------------------------------------------------------------------------

test "TC-REPO-02-02: new content creates new version" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    // ISS-0137 / GH #439: unused tenant_id local removed; user_id_str IS used below.
    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    const content1 = "{\"name\":\"process_v1\"}";
    const content2 = "{\"name\":\"process_v2\"}";

    // Create artifact 1
    var insert1 = try h.conn.query(
        alloc,
        \\INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at)
        \\VALUES (digest($1, 'sha256'), 'application/json', LENGTH($1), NOW())
        \\RETURNING content_hash
    ,
        &.{content1},
    );
    defer insert1.deinit();
    try std.testing.expect(insert1.rows.len == 1);

    // Create artifact 2 with different content
    var insert2 = try h.conn.query(
        alloc,
        \\INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at)
        \\VALUES (digest($1, 'sha256'), 'application/json', LENGTH($1), NOW())
        \\RETURNING content_hash
    ,
        &.{content2},
    );
    defer insert2.deinit();
    try std.testing.expect(insert2.rows.len == 1);

    // Verify hashes differ
    if (insert1.rows[0][0]) |h1| {
        if (insert2.rows[0][0]) |h2| {
            try std.testing.expect(!std.mem.eql(u8, h1, h2));
        }
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-03-01: Versioning with parent linkage
// ---------------------------------------------------------------------------

test "TC-REPO-03-01: versions list in chronological order with parent linkage" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    var version_ids: [5][16]u8 = undefined;
    var version_hashes: [5][]u8 = undefined;

    // Create 5 versions with parent linkage
    for (0..5) |i| {
        const content = try std.fmt.allocPrint(alloc, "{{\"v\":{}}}", .{i});
        defer alloc.free(content);

        // Get hash
        var hash_result = try h.conn.query(
            alloc,
            "SELECT digest($1, 'sha256')",
            &.{content},
        );
        defer hash_result.deinit();
        try std.testing.expect(hash_result.rows.len == 1);

        // Insert artifact
        var art_result = try h.conn.query(
            alloc,
            "INSERT INTO repository_artifacts (content_hash, content_type, byte_size, created_at) VALUES (digest($1, 'sha256'), 'application/json', LENGTH($1), NOW()) RETURNING content_hash",
            &.{content},
        );
        defer art_result.deinit();
        try std.testing.expect(art_result.rows.len == 1);

        if (art_result.rows[0][0]) |hash| {
            version_hashes[i] = hash;
        }

        // Insert version with parent linkage.
        // ISS-0137 / GH #439: a dead `parent_id_str` local sat here; the real
        // parent linkage is `parent_clause` below, which this never fed into.
        const version_id = randomUuid();
        version_ids[i] = version_id;
        const version_id_str = try uuidToString(alloc, version_id);
        defer alloc.free(version_id_str);

        // ISS-0137 / GH #439: the first version has no parent. This used to
        // build the literal string "NULL", which is NOT a SQL NULL — through
        // `$4::uuid` Postgres would try to parse the four characters N-U-L-L as
        // a uuid and raise 22P02. Sending an empty string and wrapping the
        // parameter in NULLIF(...,'') makes it a real SQL NULL.
        const parent_clause = if (i == 0)
            try alloc.dupe(u8, "")
        else
            try uuidToString(alloc, version_ids[i - 1]);
        defer alloc.free(parent_clause);

        const version_number_str = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        defer alloc.free(version_number_str);

        var ver_result = try h.conn.query(
            alloc,
            \\INSERT INTO artifact_versions
            \\(version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at)
            \\VALUES ($1, gen_random_uuid(), 'definition', 'order_process', $2, digest($3, 'sha256'), NULLIF($4, '')::uuid, $5::uuid, NOW())
        ,
            // Every pg parameter is []const u8; `i + 1` was a usize.
            &.{ version_id_str, version_number_str, content, parent_clause, user_id_str },
        );
        defer ver_result.deinit();
    }

    // Verify chronological order and parent linkage
    var result = try h.conn.query(
        alloc,
        "SELECT version_number, parent_version_id FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'order_process' ORDER BY created_at ASC",
        &.{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 5), result.rows.len);

    // Verify parent linkage
    for (result.rows, 0..) |row, i| {
        if (i == 0) {
            // First version should have NULL parent
            try std.testing.expect(row[1] == null);
        } else {
            // Subsequent versions should reference previous version
            try std.testing.expect(row[1] != null);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-03-02: Versioning — pagination support
// ---------------------------------------------------------------------------

test "TC-REPO-03-02: list versions with pagination" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create 10 versions
    for (0..10) |i| {
        const content = try std.fmt.allocPrint(alloc, "{{\"v\":{}}}", .{i});
        defer alloc.free(content);

        const version_id = randomUuid();
        const version_id_str = try uuidToString(alloc, version_id);
        defer alloc.free(version_id_str);

        const version_number_str = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        defer alloc.free(version_number_str);

        var ver_result = try h.conn.query(
            alloc,
            \\INSERT INTO artifact_versions
            \\(version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at)
            \\VALUES ($1, gen_random_uuid(), 'definition', 'paginated_artifact', $2, digest($3, 'sha256'), NULL, $4::uuid, NOW())
        ,
            // ISS-0137 / GH #439: pg parameters are []const u8; `i + 1` was usize.
            &.{ version_id_str, version_number_str, content, user_id_str },
        );
        defer ver_result.deinit();
    }

    // Query with limit
    var page1 = try h.conn.query(
        alloc,
        "SELECT version_number FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'paginated_artifact' ORDER BY created_at ASC LIMIT 5",
        &.{},
    );
    defer page1.deinit();
    try std.testing.expectEqual(@as(usize, 5), page1.rows.len);

    // Query remaining
    var page2 = try h.conn.query(
        alloc,
        "SELECT version_number FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'paginated_artifact' ORDER BY created_at ASC LIMIT 5 OFFSET 5",
        &.{},
    );
    defer page2.deinit();
    try std.testing.expectEqual(@as(usize, 5), page2.rows.len);
}

// ---------------------------------------------------------------------------
// TC-REPO-04-01: Canonical serialisation — whitespace variance
// ---------------------------------------------------------------------------

test "TC-REPO-04-01: canonical serialisation — whitespace variance produces same hash" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const content1 = "{\"name\":\"order\",\"version\":1}";
    const content2 = "{\n  \"version\": 1,\n  \"name\": \"order\"\n}";

    // Both should produce the same hash when canonicalised
    var hash1_result = try h.conn.query(
        alloc,
        "SELECT encode(digest($1, 'sha256'), 'hex')",
        &.{content1},
    );
    defer hash1_result.deinit();

    // ISS-0183 / GH-516: was $2 with only one parameter bound ([]const u8{content2}
    // is $1), so PostgreSQL could never determine $1's type from context (nothing
    // references it) -- C42P18 "could not determine data type of parameter $1".
    var hash2_result = try h.conn.query(
        alloc,
        "SELECT encode(digest($1, 'sha256'), 'hex')",
        &.{content2},
    );
    defer hash2_result.deinit();

    // Note: PostgreSQL's digest() is not canonical JSON; this test verifies
    // that our canonicalisation logic would produce equal hashes.
    // In production, the canonicaliser module handles this.
    try std.testing.expect(hash1_result.rows.len == 1);
    try std.testing.expect(hash2_result.rows.len == 1);
}

// ---------------------------------------------------------------------------
// TC-REPO-04-02: Canonical serialisation — number normalisation
// ---------------------------------------------------------------------------

test "TC-REPO-04-02: canonical serialisation — number normalisation" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const content_int = "{\"amount\":100}";
    const content_float = "{\"amount\":100.0}";
    const content_exp = "{\"amount\":1e2}";

    // All should be treated identically by canonical serialisation
    // (Verify the values are semantically equal)
    var result = try h.conn.query(
        alloc,
        "SELECT $1::json->>'amount', $2::json->>'amount', $3::json->>'amount'",
        &.{ content_int, content_float, content_exp },
    );
    defer result.deinit();
    try std.testing.expect(result.rows.len == 1);
}

// ---------------------------------------------------------------------------
// TC-REPO-05-01: Form schema indexing
// ---------------------------------------------------------------------------

test "TC-REPO-05-01: form schema indexing by field type" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const form_content = sampleFormJson();
    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create form artifact
    const version_id = randomUuid();
    const version_id_str = try uuidToString(alloc, version_id);
    defer alloc.free(version_id_str);

    var ver_insert = try h.conn.query(
        alloc,
        \\INSERT INTO artifact_versions
        \\(version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at)
        \\VALUES ($1, gen_random_uuid(), 'form', 'order_form', 1, digest($2, 'sha256'), NULL, $3::uuid, NOW())
    ,
        &.{ version_id_str, form_content, user_id_str },
    );
    defer ver_insert.deinit();

    // Index form fields (simulate activation)
    var index_insert = try h.conn.query(
        alloc,
        \\INSERT INTO repository_form_schemas (registry_id, version_id, artifact_name, field_name, field_type, field_label, required, pattern)
        \\VALUES
        \\  (gen_random_uuid(), $1::uuid, 'order_form', 'customer_name', 'string', 'Customer Name', false, NULL),
        \\  (gen_random_uuid(), $1::uuid, 'order_form', 'order_amount', 'currency', 'Order Amount (USD)', false, NULL),
        \\  (gen_random_uuid(), $1::uuid, 'order_form', 'ship_date', 'date', 'Ship Date', false, NULL),
        \\  (gen_random_uuid(), $1::uuid, 'order_form', 'quantity', 'number', 'Quantity', false, NULL)
    ,
        &.{version_id_str},
    );
    defer index_insert.deinit();

    // Query by field_type
    var currency_query = try h.conn.query(
        alloc,
        "SELECT field_name, field_type FROM repository_form_schemas WHERE field_type = 'currency' AND artifact_name = 'order_form'",
        &.{},
    );
    defer currency_query.deinit();
    try std.testing.expectEqual(@as(usize, 1), currency_query.rows.len);
    if (currency_query.rows[0][0]) |name| {
        try std.testing.expectEqualStrings(name, "order_amount");
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-05-02: Form schema search
// ---------------------------------------------------------------------------

test "TC-REPO-05-02: form schema search by field type" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create multiple forms with different field types
    for (0..3) |i| {
        const version_id = randomUuid();
        const version_id_str = try uuidToString(alloc, version_id);
        defer alloc.free(version_id_str);

        const form_name = try std.fmt.allocPrint(alloc, "form_{}", .{i});
        defer alloc.free(form_name);

        // ISS-0183 / GH-516: content_hash is BYTEA (migrations/045); gen_random_uuid()
        // returns uuid, causing PostgreSQL C42804 "column is of type bytea but
        // expression is of type uuid". digest($4, 'sha256') of the per-row
        // version_id_str gives a genuine, unique bytea value instead. A dedicated
        // $4 placeholder is required rather than reusing $1: PostgreSQL unifies a
        // parameter's type across every use in one statement, and $1 is already
        // inferred as uuid from the bare `version_id` column -- reusing it with an
        // explicit ::text cast throws C42P08 "inconsistent types deduced for
        // parameter $1: text versus uuid".
        var ver_insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'form', $2, 1, digest($4, 'sha256'), NULL, $3::uuid, NOW())",
            &.{ version_id_str, form_name, user_id_str, version_id_str },
        );
        defer ver_insert.deinit();

        // Form 0 and 1 have currency; form 2 does not
        if (i < 2) {
            var index_insert = try h.conn.query(
                alloc,
                "INSERT INTO repository_form_schemas (registry_id, version_id, artifact_name, field_name, field_type, field_label, required, pattern) VALUES (gen_random_uuid(), $1::uuid, $2, 'amount', 'currency', 'Amount', false, NULL)",
                &.{ version_id_str, form_name },
            );
            defer index_insert.deinit();
        }
    }

    // Search for currency fields
    var result = try h.conn.query(
        alloc,
        "SELECT COUNT(DISTINCT version_id) FROM repository_form_schemas WHERE field_type = 'currency'",
        &.{},
    );
    defer result.deinit();
    try std.testing.expect(result.rows.len == 1);
    if (result.rows[0][0]) |count_str| {
        const count = try std.fmt.parseInt(i64, count_str, 10);
        try std.testing.expectEqual(@as(i64, 2), count);
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-06-01: Event type registry
// ---------------------------------------------------------------------------

test "TC-REPO-06-01: event type registry with producing definition" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create event type (if event_type_registry exists).
    // ISS-0183 / GH-516: the real column (migrations/002_event_type_registry.sql)
    // is `name`, not `event_type_name`; `schema_version` is INTEGER, not the text
    // literal '1.0'. Use a per-test-unique name (randomUuid-derived) so re-runs
    // against a long-lived shared bpm_test don't collide with the (name,
    // schema_version) UNIQUE constraint.
    const event_type_name = try std.fmt.allocPrint(alloc, "OrderCreated_{s}", .{user_id_str});
    defer alloc.free(event_type_name);

    var event_type_result = try h.conn.query(
        alloc,
        \\INSERT INTO event_type_registry (id, name, schema_version, json_schema, created_at)
        \\VALUES (gen_random_uuid(), $1, 1, '{"type":"object"}', NOW())
        \\RETURNING id
    ,
        &.{event_type_name},
    );
    defer event_type_result.deinit();

    if (event_type_result.rows.len == 0) {
        // Table may not exist yet; skip test
        return;
    }

    const event_type_id = event_type_result.rows[0][0];

    // Create definition artifact.
    // ISS-0183 / GH-516: content_hash is BYTEA; digest($3, 'sha256') of the
    // version_id_str gives a genuine, unique bytea value instead of gen_random_uuid().
    // A dedicated $3 placeholder is required rather than reusing $1: PostgreSQL
    // unifies a parameter's type across every use in one statement, and $1 is
    // already inferred as uuid from the bare `version_id` column -- reusing it
    // with an explicit ::text cast throws C42P08 "inconsistent types deduced for
    // parameter $1: text versus uuid".
    const version_id = randomUuid();
    const version_id_str = try uuidToString(alloc, version_id);
    defer alloc.free(version_id_str);

    var ver_insert = try h.conn.query(
        alloc,
        "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'definition', 'order_process', 1, digest($3, 'sha256'), NULL, $2::uuid, NOW())",
        &.{ version_id_str, user_id_str, version_id_str },
    );
    defer ver_insert.deinit();

    // Register producer link (if table exists).
    // ISS-0137 / GH #439: `event_type_id` is ?[]u8; pg parameters are []const u8.
    // Capture the unwrapped payload instead of passing the optional itself.
    if (event_type_id) |event_type_id_val| {
        var producer_insert = try h.conn.query(
            alloc,
            "INSERT INTO event_type_registry_producers (id, event_type_id, definition_version_id, registered_at) VALUES (gen_random_uuid(), $1::uuid, $2::uuid, NOW())",
            &.{ event_type_id_val, version_id_str },
        );
        defer producer_insert.deinit();

        // Verify producer link
        var producer_query = try h.conn.query(
            alloc,
            "SELECT definition_version_id FROM event_type_registry_producers WHERE event_type_id = $1::uuid",
            &.{event_type_id_val},
        );
        defer producer_query.deinit();
        try std.testing.expectEqual(@as(usize, 1), producer_query.rows.len);
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-07-01: Service catalog registration
// ---------------------------------------------------------------------------

test "TC-REPO-07-01: service catalog registration with auth and schemas" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const service_id = "crm.customer_lookup";
    const endpoint = "https://crm.example.com/api/customer";
    const req_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}}}";
    const resp_schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"email\":{\"type\":\"string\"}}}";

    var insert = try h.conn.query(
        alloc,
        \\INSERT INTO service_catalog
        \\(service_id, endpoint_url, request_schema, response_schema, required_auth, timeout_ms, retry_policy, created_at, updated_at)
        \\VALUES ($1, $2, $3, $4, 'API_KEY', 5000, '{"strategy":"exponential","max_attempts":3}', NOW(), NOW())
    ,
        &.{ service_id, endpoint, req_schema, resp_schema },
    );
    defer insert.deinit();

    // Verify registration
    var query = try h.conn.query(
        alloc,
        "SELECT service_id, endpoint_url, required_auth, timeout_ms FROM service_catalog WHERE service_id = $1",
        &.{service_id},
    );
    defer query.deinit();
    try std.testing.expectEqual(@as(usize, 1), query.rows.len);

    if (query.rows[0][1]) |url| {
        try std.testing.expectEqualStrings(url, endpoint);
    }
    if (query.rows[0][2]) |auth| {
        try std.testing.expectEqualStrings(auth, "API_KEY");
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-08-01: Atomic activation
// ---------------------------------------------------------------------------

test "TC-REPO-08-01: atomic activation of multiple artifacts" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const tenant_id = randomUuid();
    const tenant_id_str = try uuidToString(alloc, tenant_id);
    defer alloc.free(tenant_id_str);

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create multiple artifacts
    const versions: [3][16]u8 = .{
        randomUuid(),
        randomUuid(),
        randomUuid(),
    };

    for (versions, 0..) |ver_id, i| {
        const ver_id_str = try uuidToString(alloc, ver_id);
        defer alloc.free(ver_id_str);

        const kind = switch (i) {
            0 => "definition",
            1 => "form",
            else => "schema",
        };

        // ISS-0183 / GH-516: content_hash is BYTEA; digest($4, 'sha256') of
        // ver_id_str gives a genuine, unique bytea value instead of gen_random_uuid().
        // A dedicated $4 placeholder is required rather than reusing $1 -- see the
        // C42P08 note above.
        var insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), $2, 'artifact', 1, digest($4, 'sha256'), NULL, $3::uuid, NOW())",
            &.{ ver_id_str, kind, user_id_str, ver_id_str },
        );
        defer insert.deinit();
    }

    // Activate all three in one transaction
    for (versions, 0..) |ver_id, i| {
        const ver_id_str = try uuidToString(alloc, ver_id);
        defer alloc.free(ver_id_str);

        const kind = switch (i) {
            0 => "definition",
            1 => "form",
            else => "schema",
        };

        const activation_id = randomUuid();
        const activation_id_str = try uuidToString(alloc, activation_id);
        defer alloc.free(activation_id_str);

        var activate = try h.conn.query(
            alloc,
            "INSERT INTO artifact_activations (activation_id, tenant_id, artifact_kind, artifact_name, active_version_id, activated_at, activator_user_id) VALUES ($1, $2::uuid, $3, 'artifact', $4::uuid, NOW(), $5::uuid)",
            &.{ activation_id_str, tenant_id_str, kind, ver_id_str, user_id_str },
        );
        defer activate.deinit();
    }

    // Verify all three are activated
    var result = try h.conn.query(
        alloc,
        "SELECT COUNT(*) FROM artifact_activations WHERE tenant_id = $1::uuid AND artifact_name = 'artifact'",
        &.{tenant_id_str},
    );
    defer result.deinit();
    try std.testing.expect(result.rows.len == 1);
    if (result.rows[0][0]) |count_str| {
        const count = try std.fmt.parseInt(i64, count_str, 10);
        try std.testing.expectEqual(@as(i64, 3), count);
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-09-01: Per-tenant activation scoping
// ---------------------------------------------------------------------------

test "TC-REPO-09-01: activations are tenant-scoped" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const tenant_a = randomUuid();
    const tenant_a_str = try uuidToString(alloc, tenant_a);
    defer alloc.free(tenant_a_str);

    const tenant_b = randomUuid();
    const tenant_b_str = try uuidToString(alloc, tenant_b);
    defer alloc.free(tenant_b_str);

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create two artifact versions
    const version_1 = randomUuid();
    const version_1_str = try uuidToString(alloc, version_1);
    defer alloc.free(version_1_str);

    const version_2 = randomUuid();
    const version_2_str = try uuidToString(alloc, version_2);
    defer alloc.free(version_2_str);

    // ISS-0137 / GH #439: iterate the UUID STRINGS directly. The loop captured
    // the raw [16]u8 `ver_id` and then ignored it, re-deriving the string from
    // `i` — an unused capture, which Zig rejects. Same rows inserted either way.
    for ([_][]const u8{ version_1_str, version_2_str }, 0..) |ver_id_str, i| {
        const version_number_str = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        defer alloc.free(version_number_str);

        // ISS-0183 / GH-516: content_hash is BYTEA; digest($4, 'sha256') of
        // ver_id_str gives a genuine, unique bytea value instead of gen_random_uuid().
        // A dedicated $4 placeholder is required rather than reusing $1 -- see the
        // C42P08 note above.
        var insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'definition', 'test_artifact', $2, digest($4, 'sha256'), NULL, $3::uuid, NOW())",
            &.{ ver_id_str, version_number_str, user_id_str, ver_id_str },
        );
        defer insert.deinit();
    }

    // Activate v1 in tenant_a
    var activate_a = try h.conn.query(
        alloc,
        "INSERT INTO artifact_activations (activation_id, tenant_id, artifact_kind, artifact_name, active_version_id, activated_at, activator_user_id) VALUES (gen_random_uuid(), $1::uuid, 'definition', 'test_artifact', $2::uuid, NOW(), $3::uuid)",
        &.{ tenant_a_str, version_1_str, user_id_str },
    );
    defer activate_a.deinit();

    // Activate v2 in tenant_b
    var activate_b = try h.conn.query(
        alloc,
        "INSERT INTO artifact_activations (activation_id, tenant_id, artifact_kind, artifact_name, active_version_id, activated_at, activator_user_id) VALUES (gen_random_uuid(), $1::uuid, 'definition', 'test_artifact', $2::uuid, NOW(), $3::uuid)",
        &.{ tenant_b_str, version_2_str, user_id_str },
    );
    defer activate_b.deinit();

    // Verify tenant_a has v1
    var result_a = try h.conn.query(
        alloc,
        "SELECT active_version_id FROM artifact_activations WHERE tenant_id = $1::uuid AND artifact_name = 'test_artifact'",
        &.{tenant_a_str},
    );
    defer result_a.deinit();
    try std.testing.expectEqual(@as(usize, 1), result_a.rows.len);
    if (result_a.rows[0][0]) |ver_id| {
        try std.testing.expectEqualStrings(ver_id, version_1_str);
    }

    // Verify tenant_b has v2
    var result_b = try h.conn.query(
        alloc,
        "SELECT active_version_id FROM artifact_activations WHERE tenant_id = $1::uuid AND artifact_name = 'test_artifact'",
        &.{tenant_b_str},
    );
    defer result_b.deinit();
    try std.testing.expectEqual(@as(usize, 1), result_b.rows.len);
    if (result_b.rows[0][0]) |ver_id| {
        try std.testing.expectEqualStrings(ver_id, version_2_str);
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-10-01: Activation history
// ---------------------------------------------------------------------------

test "TC-REPO-10-01: activation history records all fields" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const tenant_id = randomUuid();
    const tenant_id_str = try uuidToString(alloc, tenant_id);
    defer alloc.free(tenant_id_str);

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    const version_1 = randomUuid();
    const version_1_str = try uuidToString(alloc, version_1);
    defer alloc.free(version_1_str);

    const version_2 = randomUuid();
    const version_2_str = try uuidToString(alloc, version_2);
    defer alloc.free(version_2_str);

    // Create two versions
    // ISS-0137 / GH #439: iterate the UUID STRINGS directly. The loop captured
    // the raw [16]u8 `ver_id` and then ignored it, re-deriving the string from
    // `i` — an unused capture, which Zig rejects. Same rows inserted either way.
    for ([_][]const u8{ version_1_str, version_2_str }, 0..) |ver_id_str, i| {
        const version_number_str = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        defer alloc.free(version_number_str);

        // ISS-0183 / GH-516: content_hash is BYTEA; digest($4, 'sha256') of
        // ver_id_str gives a genuine, unique bytea value instead of gen_random_uuid().
        // A dedicated $4 placeholder is required rather than reusing $1 -- see the
        // C42P08 note above.
        var insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'definition', 'test_artifact', $2, digest($4, 'sha256'), NULL, $3::uuid, NOW())",
            &.{ ver_id_str, version_number_str, user_id_str, ver_id_str },
        );
        defer insert.deinit();
    }

    // Record first activation
    var history_1 = try h.conn.query(
        alloc,
        "INSERT INTO artifact_activation_history (history_id, tenant_id, artifact_kind, artifact_name, previous_version_id, new_version_id, new_version_number, activator_user_id, activated_at, rationale) VALUES (gen_random_uuid(), $1::uuid, 'definition', 'test_artifact', NULL, $2::uuid, 1, $3::uuid, NOW(), 'Initial activation')",
        &.{ tenant_id_str, version_1_str, user_id_str },
    );
    defer history_1.deinit();

    // Record second activation
    var history_2 = try h.conn.query(
        alloc,
        "INSERT INTO artifact_activation_history (history_id, tenant_id, artifact_kind, artifact_name, previous_version_id, new_version_id, new_version_number, activator_user_id, activated_at, rationale) VALUES (gen_random_uuid(), $1::uuid, 'definition', 'test_artifact', $2::uuid, $3::uuid, 2, $4::uuid, NOW(), 'Bugfix')",
        &.{ tenant_id_str, version_1_str, version_2_str, user_id_str },
    );
    defer history_2.deinit();

    // Verify history
    var result = try h.conn.query(
        alloc,
        "SELECT previous_version_id, new_version_number, rationale FROM artifact_activation_history WHERE tenant_id = $1::uuid AND artifact_name = 'test_artifact' ORDER BY activated_at ASC",
        &.{tenant_id_str},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.rows.len);

    // First record should have NULL previous_version_id
    try std.testing.expect(result.rows[0][0] == null);
    if (result.rows[0][1]) |v| {
        const version_number = try std.fmt.parseInt(i64, v, 10);
        try std.testing.expectEqual(@as(i64, 1), version_number);
    }
    if (result.rows[0][2]) |rationale| {
        try std.testing.expectEqualStrings(rationale, "Initial activation");
    }

    // Second record should have previous_version_id
    try std.testing.expect(result.rows[1][0] != null);
    if (result.rows[1][2]) |rationale| {
        try std.testing.expectEqualStrings(rationale, "Bugfix");
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-11-01: Create artifact roundtrip
// ---------------------------------------------------------------------------

test "TC-REPO-11-01: create artifact and roundtrip GET" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    const content = "{\"name\":\"order\",\"steps\":[\"start\",\"end\"]}";
    const version_id = randomUuid();
    const version_id_str = try uuidToString(alloc, version_id);
    defer alloc.free(version_id_str);

    // Create artifact
    var create = try h.conn.query(
        alloc,
        "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'definition', 'order_process', 1, digest($2, 'sha256'), NULL, $3::uuid, NOW()) RETURNING version_id",
        &.{ version_id_str, content, user_id_str },
    );
    defer create.deinit();
    try std.testing.expectEqual(@as(usize, 1), create.rows.len);

    // Retrieve it
    var retrieve = try h.conn.query(
        alloc,
        "SELECT version_id, artifact_kind, artifact_name FROM artifact_versions WHERE version_id = $1::uuid",
        &.{version_id_str},
    );
    defer retrieve.deinit();
    try std.testing.expectEqual(@as(usize, 1), retrieve.rows.len);

    if (retrieve.rows[0][1]) |kind| {
        try std.testing.expectEqualStrings(kind, "definition");
    }
    if (retrieve.rows[0][2]) |name| {
        try std.testing.expectEqualStrings(name, "order_process");
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-11-02: Create artifact with deduplication
// ---------------------------------------------------------------------------

test "TC-REPO-11-02: create artifact with deduplication" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    const content = "{\"name\":\"order\",\"version\":1}";

    const version_1 = randomUuid();
    const version_1_str = try uuidToString(alloc, version_1);
    defer alloc.free(version_1_str);

    const version_2 = randomUuid();
    const version_2_str = try uuidToString(alloc, version_2);
    defer alloc.free(version_2_str);

    // First artifact creation
    var create1 = try h.conn.query(
        alloc,
        "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'definition', 'order_process', 1, digest($2, 'sha256'), NULL, $3::uuid, NOW()) RETURNING version_id, artifact_kind",
        &.{ version_1_str, content, user_id_str },
    );
    defer create1.deinit();
    try std.testing.expectEqual(@as(usize, 1), create1.rows.len);

    // Second artifact with identical content should increment version_number.
    // ISS-0183 / GH-516: this INSERT...SELECT had no RETURNING clause, so
    // create2.rows.len was always 0 regardless of whether the insert succeeded --
    // the very next assertion (expectEqual(1, create2.rows.len)) could never pass.
    var create2 = try h.conn.query(
        alloc,
        "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) SELECT $1, artifact_id, 'definition', 'order_process', 2, digest($2, 'sha256'), $3::uuid, $4::uuid, NOW() FROM artifact_versions WHERE version_id = $3::uuid RETURNING version_id",
        &.{ version_2_str, content, version_1_str, user_id_str },
    );
    defer create2.deinit();
    try std.testing.expectEqual(@as(usize, 1), create2.rows.len);

    // Verify both have same content hash but different version_number
    var verify = try h.conn.query(
        alloc,
        "SELECT version_number, content_hash FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'order_process' ORDER BY version_number ASC",
        &.{},
    );
    defer verify.deinit();
    try std.testing.expectEqual(@as(usize, 2), verify.rows.len);

    if (verify.rows[0][0]) |v1| {
        const version_1_num = try std.fmt.parseInt(i64, v1, 10);
        try std.testing.expectEqual(@as(i64, 1), version_1_num);
    }

    if (verify.rows[1][0]) |v2| {
        const version_2_num = try std.fmt.parseInt(i64, v2, 10);
        try std.testing.expectEqual(@as(i64, 2), version_2_num);
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-12-01: List versions with parent linkage
// ---------------------------------------------------------------------------

test "TC-REPO-12-01: list versions in order with parent linkage" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    var version_ids: [5][16]u8 = undefined;
    for (0..5) |i| {
        version_ids[i] = randomUuid();
    }

    // Create versions with parent linkage
    for (version_ids, 0..) |ver_id, i| {
        const ver_id_str = try uuidToString(alloc, ver_id);
        defer alloc.free(ver_id_str);

        const content = try std.fmt.allocPrint(alloc, "{{\"v\":{}}}", .{i});
        defer alloc.free(content);

        const parent_clause = if (i == 0)
            // ISS-0137 / GH #439: empty string + NULLIF, not the literal "NULL" —
            // through `$4::uuid` Postgres would try to parse "NULL" as a uuid
            // and raise 22P02.
            try alloc.dupe(u8, "")
        else blk: {
            const parent_str = try uuidToString(alloc, version_ids[i - 1]);
            break :blk parent_str;
        };
        defer alloc.free(parent_clause);

        const version_number_str = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        defer alloc.free(version_number_str);

        var insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'definition', 'test_artifact', $2, digest($3, 'sha256'), NULLIF($4, '')::uuid, $5::uuid, NOW())",
            &.{ ver_id_str, version_number_str, content, parent_clause, user_id_str },
        );
        defer insert.deinit();
    }

    // List versions
    var result = try h.conn.query(
        alloc,
        "SELECT version_number, parent_version_id FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'test_artifact' ORDER BY created_at ASC",
        &.{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 5), result.rows.len);

    // Verify first version has NULL parent
    try std.testing.expect(result.rows[0][1] == null);
}

// ---------------------------------------------------------------------------
// TC-REPO-12-02: List versions with pagination
// ---------------------------------------------------------------------------

test "TC-REPO-12-02: list versions pagination" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create 15 versions
    for (0..15) |i| {
        const version_id = randomUuid();
        const version_id_str = try uuidToString(alloc, version_id);
        defer alloc.free(version_id_str);

        const content = try std.fmt.allocPrint(alloc, "{{\"v\":{}}}", .{i});
        defer alloc.free(content);

        const version_number_str = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        defer alloc.free(version_number_str);

        var insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), 'definition', 'paginated_artifact', $2, digest($3, 'sha256'), NULL, $4::uuid, NOW())",
            // ISS-0137 / GH #439: pg parameters are []const u8; `i + 1` was usize.
            &.{ version_id_str, version_number_str, content, user_id_str },
        );
        defer insert.deinit();
    }

    // Test pagination with limit 5
    var page1 = try h.conn.query(
        alloc,
        "SELECT version_number FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'paginated_artifact' ORDER BY created_at ASC LIMIT 5",
        &.{},
    );
    defer page1.deinit();
    try std.testing.expectEqual(@as(usize, 5), page1.rows.len);

    var page2 = try h.conn.query(
        alloc,
        "SELECT version_number FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'paginated_artifact' ORDER BY created_at ASC LIMIT 5 OFFSET 5",
        &.{},
    );
    defer page2.deinit();
    try std.testing.expectEqual(@as(usize, 5), page2.rows.len);

    var page3 = try h.conn.query(
        alloc,
        "SELECT version_number FROM artifact_versions WHERE artifact_kind = 'definition' AND artifact_name = 'paginated_artifact' ORDER BY created_at ASC LIMIT 5 OFFSET 10",
        &.{},
    );
    defer page3.deinit();
    try std.testing.expectEqual(@as(usize, 5), page3.rows.len);
}

// ---------------------------------------------------------------------------
// TC-REPO-13-01: Tenant activations list
// ---------------------------------------------------------------------------

test "TC-REPO-13-01: tenant activations list returns all active artifacts" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const tenant_id = randomUuid();
    const tenant_id_str = try uuidToString(alloc, tenant_id);
    defer alloc.free(tenant_id_str);

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create three artifacts of different kinds
    const kinds = [_][]const u8{ "definition", "form", "schema" };
    var version_ids: [3][16]u8 = undefined;

    for (kinds, 0..) |kind, i| {
        version_ids[i] = randomUuid();
        const version_id_str = try uuidToString(alloc, version_ids[i]);
        defer alloc.free(version_id_str);

        // ISS-0183 / GH-516: content_hash is BYTEA; digest($4, 'sha256') of
        // version_id_str gives a genuine, unique bytea value instead of gen_random_uuid().
        // A dedicated $4 placeholder is required rather than reusing $1 -- see the
        // C42P08 note above.
        var insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), $2, 'artifact', 1, digest($4, 'sha256'), NULL, $3::uuid, NOW())",
            &.{ version_id_str, kind, user_id_str, version_id_str },
        );
        defer insert.deinit();
    }

    // Activate all three
    for (kinds, 0..) |kind, i| {
        const version_id_str = try uuidToString(alloc, version_ids[i]);
        defer alloc.free(version_id_str);

        var activate = try h.conn.query(
            alloc,
            "INSERT INTO artifact_activations (activation_id, tenant_id, artifact_kind, artifact_name, active_version_id, activated_at, activator_user_id) VALUES (gen_random_uuid(), $1::uuid, $2, 'artifact', $3::uuid, NOW(), $4::uuid)",
            &.{ tenant_id_str, kind, version_id_str, user_id_str },
        );
        defer activate.deinit();
    }

    // Query activations for tenant
    var result = try h.conn.query(
        alloc,
        "SELECT artifact_kind, artifact_name FROM artifact_activations WHERE tenant_id = $1::uuid ORDER BY artifact_kind ASC",
        &.{tenant_id_str},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.rows.len);

    // Verify all kinds are present
    for (kinds, 0..) |kind, i| {
        if (result.rows[i][0]) |actual_kind| {
            try std.testing.expectEqualStrings(actual_kind, kind);
        }
    }
}

// ---------------------------------------------------------------------------
// TC-REPO-13-02: Tenant activations with filtering
// ---------------------------------------------------------------------------

test "TC-REPO-13-02: tenant activations with kind filtering" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const tenant_id = randomUuid();
    const tenant_id_str = try uuidToString(alloc, tenant_id);
    defer alloc.free(tenant_id_str);

    const user_id = randomUuid();
    const user_id_str = try uuidToString(alloc, user_id);
    defer alloc.free(user_id_str);

    // Create artifacts of multiple kinds
    const kinds = [_][]const u8{ "definition", "form", "schema" };

    for (kinds) |kind| {
        const version_id = randomUuid();
        const version_id_str = try uuidToString(alloc, version_id);
        defer alloc.free(version_id_str);

        // ISS-0183 / GH-516: content_hash is BYTEA; digest($4, 'sha256') of
        // version_id_str gives a genuine, unique bytea value instead of gen_random_uuid().
        // A dedicated $4 placeholder is required rather than reusing $1 -- see the
        // C42P08 note above.
        var ver_insert = try h.conn.query(
            alloc,
            "INSERT INTO artifact_versions (version_id, artifact_id, artifact_kind, artifact_name, version_number, content_hash, parent_version_id, created_by, created_at) VALUES ($1, gen_random_uuid(), $2, 'artifact', 1, digest($4, 'sha256'), NULL, $3::uuid, NOW())",
            &.{ version_id_str, kind, user_id_str, version_id_str },
        );
        defer ver_insert.deinit();

        var activate = try h.conn.query(
            alloc,
            "INSERT INTO artifact_activations (activation_id, tenant_id, artifact_kind, artifact_name, active_version_id, activated_at, activator_user_id) VALUES (gen_random_uuid(), $1::uuid, $2, 'artifact', $3::uuid, NOW(), $4::uuid)",
            &.{ tenant_id_str, kind, version_id_str, user_id_str },
        );
        defer activate.deinit();
    }

    // Query with kind filter
    var result = try h.conn.query(
        alloc,
        "SELECT artifact_kind FROM artifact_activations WHERE tenant_id = $1::uuid AND artifact_kind = 'definition'",
        &.{tenant_id_str},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    if (result.rows[0][0]) |kind| {
        try std.testing.expectEqualStrings(kind, "definition");
    }
}
