//! Pure platform DDL validator — DDL-01
//!
//! Design artefact: src/design/ddl-01-validate-platform-ddl.md
//! Depends on: DDL-05 (src/platform/ddl_namespace.zig), composed as one of
//! three checks this module aggregates.
//!
//! `validatePlatformDDL` decides, for an entire migration file's parsed
//! statement list, whether every statement is safe to run against a live
//! tenant schema without holding an ACCESS EXCLUSIVE lock for a duration
//! proportional to table size, and whether every object name in the file
//! respects the `plat_` reserved-namespace rule (DDL-05, composed here, not
//! re-derived). This is the pre-flight gate MIG-01's fanout (`runFanout` in
//! src/platform/migration_fanout.zig) must pass through before opening a
//! connection to any tenant schema.
//!
//! Three independent per-statement checks (lock-class, index-concurrency,
//! namespace) plus one whole-file-set stateful check (DDL-02's
//! constrain-before-expand) run over the file set, in a fixed tie-break
//! order (lock-class, then index-concurrency, then namespace, then
//! constrain-before-expand — see the design doc's "Within-statement check
//! order" section), aggregated into ONE verdict naming the FIRST failing
//! statement in `order` (DDL-01 AC5):
//!   - Lock-class check (new): reject drop_column, cluster, vacuum_full,
//!     reindex_non_concurrent, alter_column_set_data_type.
//!   - Concurrent-index check (new): reject create_index_non_concurrent,
//!     drop_index_non_concurrent.
//!   - Namespace check (composed from DDL-05): delegate to
//!     ddl_namespace.checkNamespace for every statement.
//!   - Constrain-before-expand check (DDL-02, new): a stateful,
//!     whole-file-set scan (per-column UNSEEN -> EXPANDED -> BACKFILLED
//!     state machine) that rejects a column being constrained (SET NOT
//!     NULL, ADD CONSTRAINT without NOT VALID, or ADD COLUMN ... NOT NULL
//!     without a constant default) before it has been expanded and
//!     backfilled. See src/design/ddl-02-constrain-before-expand-check.md.
//!
//! Pure: no allocator, no database handle, no connection, no clock, no
//! environment variable (DDL-01 AC4) — matching ddl_namespace.zig's own
//! purity contract exactly. Every outcome, including all rejection cases, is
//! a normal return value (ValidationVerdict), never a thrown error: this
//! module raises no Zig error{...} set.
//!
//! Must NOT depend on: src/db/pool.zig, src/db/provisioning.zig,
//! src/db/migrations.zig, src/platform/migration_fanout.zig, std.time, or
//! any clock — see the design doc's Dependencies section.
const std = @import("std");
const ddl_namespace = @import("ddl_namespace.zig");

/// Statement classification the lock-class / index-concurrency checks switch
/// on. Distinct from ddl_namespace.StatementKind (create/rename_to/alter),
/// which is about *namespace* ownership, not *lock* behavior.
pub const StatementClass = enum {
    drop_column,
    cluster,
    vacuum_full,
    reindex_concurrent,
    reindex_non_concurrent,
    alter_column_set_data_type,
    create_index_concurrent,
    create_index_non_concurrent,
    drop_index_concurrent,
    drop_index_non_concurrent,
    other,
};

/// DDL-02: classifies what a statement means for the constrain-before-expand
/// dependency check — distinct from StatementClass (lock-duration behavior)
/// and ddl_namespace.StatementKind (namespace ownership). This is about
/// *dependency* shape: does this statement expand, backfill, or constrain a
/// column, or is it irrelevant to this check?
pub const OrderingRole = enum {
    /// ADD COLUMN ... <nullable, or NOT NULL WITH a constant DEFAULT>. A
    /// constant default makes Postgres able to fill every existing row's
    /// value into the catalog without a table rewrite/scan (fast-default
    /// path, PG11+). ADD COLUMN ... NOT NULL WITHOUT a default is
    /// `.constrain`, not `.expand`.
    expand,

    /// Fills in the column's data for existing rows: an UPDATE targeting
    /// the column, or a VALIDATE CONSTRAINT promoting an already-added NOT
    /// VALID constraint. Classifying raw SQL text as a backfill is parser
    /// work (see the module's "does NOT do" section); this module consumes
    /// the caller's classification.
    backfill,

    /// Requires the column already fully populated: SET NOT NULL, ADD
    /// CONSTRAINT ... CHECK/FOREIGN KEY without NOT VALID, or ADD COLUMN
    /// ... NOT NULL with no constant default.
    constrain,

    /// ADD CONSTRAINT ... NOT VALID — adds immediately (metadata-only), does
    /// not enforce against existing rows. Tracked separately from
    /// `.constrain` because it is always safe regardless of ordering, and a
    /// later VALIDATE CONSTRAINT is `.backfill`.
    constrain_not_valid,

    /// Everything else (CREATE TABLE, unrelated ALTERs, index statements) —
    /// ignored here, still visible to the other three checks.
    irrelevant,
};

/// DDL-02: names the column a statement's ordering role applies to. A
/// single-column shape covers every DDL-02 acceptance criterion; a
/// constraint spanning multiple columns is out of scope (see the design
/// doc's "Open questions").
pub const ColumnRef = struct {
    table: []const u8,
    column: []const u8,
};

/// The full statement descriptor validatePlatformDDL operates over. A
/// superset of ddl_namespace.StatementDescriptor's shape (kind, object_name,
/// previous_object_name) plus the fields the lock-class / index checks need.
pub const StatementDescriptor = struct {
    /// Namespace-check shape, reused verbatim so checkNamespace can be
    /// called with zero field-by-field translation.
    kind: ddl_namespace.StatementKind,
    object_name: []const u8,
    previous_object_name: ?[]const u8 = null,

    /// Lock-class / index-concurrency shape, read only by this module's own
    /// checks, never by ddl_namespace.checkNamespace.
    class: StatementClass,

    /// 1-based position of this statement within its file's statement list —
    /// AC5's "first failure in statement order" needs a stable order key.
    /// Set by the (out-of-scope) parser.
    order: u32,

    /// Raw statement text, exactly as written, for the failure detail.
    text: []const u8,

    /// DDL-02: what this statement means for the expand/backfill/constrain
    /// dependency check. Defaults to `.irrelevant` so every pre-DDL-02 call
    /// site compiles unchanged.
    ordering_role: OrderingRole = .irrelevant,

    /// DDL-02: which column `ordering_role` applies to. Null when
    /// `ordering_role == .irrelevant`.
    ordering_column: ?ColumnRef = null,

    /// DDL-02: the migration file path (or filename) this statement was
    /// parsed from. No default — DDL-01's existing rejection details already
    /// promise "naming that statement," and this field makes that precise
    /// (file + byte offset) for every check, not only DDL-02's. Set by the
    /// (out-of-scope) parser, exactly like `order`.
    file: []const u8,

    /// DDL-02: the 0-based byte position of this statement's first
    /// character within `file`'s raw text. No default — see `file` above and
    /// the design doc's "Migration impact on DDL-01's existing tests"
    /// section for why an empty/zero default was rejected.
    byte_offset: u32,
};

pub const FileSet = struct {
    /// Statements across the whole file (or file set) being validated, in
    /// declaration order. This module does not itself sort by `order` — the
    /// caller is expected to supply the slice already in file order.
    statements: []const StatementDescriptor,
    actor: ddl_namespace.Actor,
};

pub const UnboundedExclusiveLockDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    class: StatementClass,
};

pub const NonConcurrentIndexBuildDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
};

/// Re-exports of ddl_namespace's detail shapes plus the failing statement's
/// order/text, since ddl_namespace.NamespaceVerdict alone carries only
/// object_name.
pub const ReservedNamespaceDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    object_name: []const u8,
};

pub const UnreservedPlatformObjectDetail = struct {
    statement_order: u32,
    statement_text: []const u8,
    object_name: []const u8,
};

/// DDL-02: the constrain-before-expand verdict payload. `depended_on_*`
/// fields are null when the dependency is missing entirely from the file set
/// (never seen anywhere), vs. populated when it exists but appears AFTER the
/// constraining statement (the out-of-order case, AC2's worked example).
///
/// Per AC5 ("names the file and the byte offset of both the constraining
/// statement and the statement it depends on"), the detail carries
/// file/byte_offset for both statements, copied straight from the two
/// StatementDescriptors' own `file`/`byte_offset` fields.
pub const ConstrainBeforeExpandDetail = struct {
    constraining_statement_order: u32,
    constraining_statement_text: []const u8,
    constraining_statement_file: []const u8,
    constraining_statement_byte_offset: u32,
    depended_on_statement_order: ?u32,
    depended_on_statement_text: ?[]const u8,
    depended_on_statement_file: ?[]const u8,
    depended_on_statement_byte_offset: ?u32,
    column: ColumnRef,
};

pub const ValidationVerdict = union(enum) {
    accept,
    unbounded_exclusive_lock: UnboundedExclusiveLockDetail,
    non_concurrent_index_build: NonConcurrentIndexBuildDetail,
    reserved_namespace: ReservedNamespaceDetail,
    unreserved_platform_object: UnreservedPlatformObjectDetail,
    constrain_before_expand: ConstrainBeforeExpandDetail,
};

/// Lock-class check: is this statement's class one that holds ACCESS
/// EXCLUSIVE for a duration proportional to table size?
fn isUnboundedExclusiveLockClass(class: StatementClass) bool {
    return switch (class) {
        .drop_column,
        .cluster,
        .vacuum_full,
        .reindex_non_concurrent,
        .alter_column_set_data_type,
        => true,
        else => false,
    };
}

/// Index-concurrency check: is this statement a CREATE/DROP INDEX written
/// without CONCURRENTLY?
fn isNonConcurrentIndexClass(class: StatementClass) bool {
    return switch (class) {
        .create_index_non_concurrent, .drop_index_non_concurrent => true,
        else => false,
    };
}

/// DDL-02: per-column state during `checkConstrainBeforeExpand`'s scan.
/// UNSEEN -> EXPANDED -> BACKFILLED, per the design doc's state machine.
const ColumnState = enum { unseen, expanded, backfilled };

/// DDL-02: bounded working state for `checkConstrainBeforeExpand`. DDL-01
/// AC4's "no allocator" purity claim rules out a heap-allocated map, and
/// AC5's own benchmark bounds the realistic file-set size at 200 statements
/// — so a fixed-capacity linear-scan table (at most one entry per distinct
/// `(table, column)` pair actually referenced) comfortably covers it without
/// an allocator. 200 is generous headroom: a single migration file cannot
/// reference more distinct columns than it has statements.
const MAX_TRACKED_COLUMNS = 200;

const ColumnTrackEntry = struct {
    column: ColumnRef,
    state: ColumnState,
    /// The statement (order/text/file/byte_offset) that moved this column to
    /// its current state — i.e. the `.expand` statement once EXPANDED, or the
    /// `.backfill` statement once BACKFILLED. Used to populate
    /// `depended_on_*` when a later statement illegally constrains it.
    depended_on_order: u32,
    depended_on_text: []const u8,
    depended_on_file: []const u8,
    depended_on_byte_offset: u32,
};

fn columnRefEql(a: ColumnRef, b: ColumnRef) bool {
    return std.mem.eql(u8, a.table, b.table) and std.mem.eql(u8, a.column, b.column);
}

/// DDL-02: whole-file-set scan for the expand-before-constrain dependency.
/// Walks `statements` in order (the caller-supplied order, matching every
/// other check's "already sorted by order" contract), maintaining a bounded
/// per-column state table, and returns the FIRST violation encountered in
/// that iteration order, or null if every constraining statement in the file
/// set is properly preceded by an expand (and, unless `.constrain_not_valid`,
/// a backfill).
///
/// Pure: no allocator, no I/O — matches DDL-01 AC4's purity contract exactly
/// (see the design doc's "Dependencies" section on why a bounded stack table
/// was chosen over an allocator parameter).
fn checkConstrainBeforeExpand(statements: []const StatementDescriptor) ?ConstrainBeforeExpandDetail {
    var tracked: [MAX_TRACKED_COLUMNS]ColumnTrackEntry = undefined;
    var tracked_len: usize = 0;

    for (statements) |stmt| {
        const col = stmt.ordering_column orelse continue;
        if (stmt.ordering_role == .irrelevant) continue;

        // Find (or create) this column's tracking entry.
        var entry_idx: ?usize = null;
        for (tracked[0..tracked_len], 0..) |*e, i| {
            if (columnRefEql(e.column, col)) {
                entry_idx = i;
                break;
            }
        }
        if (entry_idx == null and tracked_len < MAX_TRACKED_COLUMNS) {
            tracked[tracked_len] = .{
                .column = col,
                .state = .unseen,
                .depended_on_order = stmt.order,
                .depended_on_text = stmt.text,
                .depended_on_file = stmt.file,
                .depended_on_byte_offset = stmt.byte_offset,
            };
            entry_idx = tracked_len;
            tracked_len += 1;
        }
        const idx = entry_idx orelse continue; // table exhausted: skip tracking (see MAX_TRACKED_COLUMNS)
        const e = &tracked[idx];

        switch (stmt.ordering_role) {
            .expand => {
                if (e.state == .unseen) {
                    e.state = .expanded;
                    e.depended_on_order = stmt.order;
                    e.depended_on_text = stmt.text;
                    e.depended_on_file = stmt.file;
                    e.depended_on_byte_offset = stmt.byte_offset;
                }
            },
            .backfill => {
                if (e.state == .expanded) {
                    e.state = .backfilled;
                    e.depended_on_order = stmt.order;
                    e.depended_on_text = stmt.text;
                    e.depended_on_file = stmt.file;
                    e.depended_on_byte_offset = stmt.byte_offset;
                }
            },
            .constrain_not_valid => {
                // NOT VALID is always safe regardless of state — never rejected.
            },
            .constrain => {
                if (e.state != .backfilled) {
                    return ConstrainBeforeExpandDetail{
                        .constraining_statement_order = stmt.order,
                        .constraining_statement_text = stmt.text,
                        .constraining_statement_file = stmt.file,
                        .constraining_statement_byte_offset = stmt.byte_offset,
                        .depended_on_statement_order = if (e.state == .unseen) null else e.depended_on_order,
                        .depended_on_statement_text = if (e.state == .unseen) null else e.depended_on_text,
                        .depended_on_statement_file = if (e.state == .unseen) null else e.depended_on_file,
                        .depended_on_statement_byte_offset = if (e.state == .unseen) null else e.depended_on_byte_offset,
                        .column = col,
                    };
                }
            },
            .irrelevant => unreachable, // filtered out above
        }
    }

    return null;
}

/// Validates every statement in `file_set.statements`, in `order`, against
/// four checks (lock-class, index-concurrency, namespace, and DDL-02's
/// constrain-before-expand) and returns the FIRST failing verdict in
/// statement order (AC5), or .accept if every statement passes every check.
/// Pure: no allocator, no I/O, no clock, no env var — DDL-01's stated purity
/// constraint, and AC4's testable consequence of it.
///
/// Within a single statement, if more than one check would fail
/// simultaneously, the fixed tie-break order is lock-class, then
/// index-concurrency, then namespace, then constrain-before-expand (see the
/// design doc's "Within-statement check order" section) — this makes the
/// verdict deterministic (AC4) regardless of which checks a given statement
/// happens to trip.
///
/// The caller is expected to supply `file_set.statements` already sorted by
/// `order`; this function does not itself sort, but iterates in the order
/// the slice is given and reports the first (in that iteration order)
/// non-accept verdict. Callers that cannot guarantee pre-sorted input should
/// sort by `order` before calling.
///
/// DDL-02's constrain-before-expand check is stateful and whole-file (unlike
/// the other three, which are per-statement), so it is run once up front to
/// find a candidate failing order, then interleaved with the per-statement
/// loop by comparing `order` values — whichever of the four checks' failures
/// has the smaller `order` wins, ties broken by the fixed priority above.
pub fn validatePlatformDDL(file_set: FileSet) ValidationVerdict {
    const cbe_candidate = checkConstrainBeforeExpand(file_set.statements);

    for (file_set.statements) |stmt| {
        // DDL-02: if the constrain-before-expand candidate's statement has
        // been reached and no earlier-order per-statement failure has fired
        // yet, report it now — this is what keeps "first failure in
        // statement order" true across all four checks (see the design
        // doc's aggregation rule).
        if (cbe_candidate) |cbe| {
            if (stmt.order == cbe.constraining_statement_order) {
                if (isUnboundedExclusiveLockClass(stmt.class)) {
                    return .{ .unbounded_exclusive_lock = .{
                        .statement_order = stmt.order,
                        .statement_text = stmt.text,
                        .class = stmt.class,
                    } };
                }
                if (isNonConcurrentIndexClass(stmt.class)) {
                    return .{ .non_concurrent_index_build = .{
                        .statement_order = stmt.order,
                        .statement_text = stmt.text,
                    } };
                }
                const ns_verdict = ddl_namespace.checkNamespace(file_set.actor, .{
                    .kind = stmt.kind,
                    .object_name = stmt.object_name,
                    .previous_object_name = stmt.previous_object_name,
                });
                switch (ns_verdict) {
                    .accept => {},
                    .reserved_namespace => |detail| return .{ .reserved_namespace = .{
                        .statement_order = stmt.order,
                        .statement_text = stmt.text,
                        .object_name = detail.object_name,
                    } },
                    .unreserved_platform_object => |detail| return .{ .unreserved_platform_object = .{
                        .statement_order = stmt.order,
                        .statement_text = stmt.text,
                        .object_name = detail.object_name,
                    } },
                }
                return .{ .constrain_before_expand = cbe };
            }
        }

        if (isUnboundedExclusiveLockClass(stmt.class)) {
            return .{ .unbounded_exclusive_lock = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
                .class = stmt.class,
            } };
        }

        if (isNonConcurrentIndexClass(stmt.class)) {
            return .{ .non_concurrent_index_build = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
            } };
        }

        const ns_verdict = ddl_namespace.checkNamespace(file_set.actor, .{
            .kind = stmt.kind,
            .object_name = stmt.object_name,
            .previous_object_name = stmt.previous_object_name,
        });
        switch (ns_verdict) {
            .accept => {},
            .reserved_namespace => |detail| return .{ .reserved_namespace = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
                .object_name = detail.object_name,
            } },
            .unreserved_platform_object => |detail| return .{ .unreserved_platform_object = .{
                .statement_order = stmt.order,
                .statement_text = stmt.text,
                .object_name = detail.object_name,
            } },
        }
    }

    return .accept;
}

// ---------------------------------------------------------------------------
// Unit tests — DDL-01 acceptance criteria
// ---------------------------------------------------------------------------

const testing = std.testing;

// DDL-01 AC1: GIVEN a file set containing `ALTER TABLE events DROP COLUMN
// legacy_flag`, WHEN the migration plan runs, THEN ValidatePlatformDDL
// returns UnboundedExclusiveLock naming that statement.
test "TC-DDL-01-AC1: DROP COLUMN statement is refused as UnboundedExclusiveLock" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .drop_column,
            .order = 1,
            .text = "ALTER TABLE events DROP COLUMN legacy_flag",
            .file = "001_test_ac1.sql",
            .byte_offset = 0,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
            try testing.expectEqualStrings("ALTER TABLE events DROP COLUMN legacy_flag", detail.statement_text);
            try testing.expectEqual(StatementClass.drop_column, detail.class);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// DDL-01 AC2: GIVEN a file set containing `CREATE INDEX idx_events_actor ON
// events (actor_id)` without CONCURRENTLY, WHEN validated, THEN
// NonConcurrentIndexBuild is returned.
test "TC-DDL-01-AC2: CREATE INDEX without CONCURRENTLY is refused as NonConcurrentIndexBuild" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "idx_events_actor",
            .class = .create_index_non_concurrent,
            .order = 1,
            .text = "CREATE INDEX idx_events_actor ON events (actor_id)",
            .file = "002_test_ac2.sql",
            .byte_offset = 0,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .non_concurrent_index_build => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
            try testing.expectEqualStrings("CREATE INDEX idx_events_actor ON events (actor_id)", detail.statement_text);
        },
        else => return error.TestExpectedNonConcurrentIndexBuild,
    }
}

// DDL-01 AC3: GIVEN a file set containing `ALTER TABLE events ALTER COLUMN
// payload SET DATA TYPE JSONB`, WHEN validated, THEN UnboundedExclusiveLock
// is returned.
test "TC-DDL-01-AC3: ALTER COLUMN SET DATA TYPE is refused as UnboundedExclusiveLock" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .alter_column_set_data_type,
            .order = 1,
            .text = "ALTER TABLE events ALTER COLUMN payload SET DATA TYPE JSONB",
            .file = "003_test_ac3.sql",
            .byte_offset = 0,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(StatementClass.alter_column_set_data_type, detail.class);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// DDL-01 AC4: GIVEN one descriptor list, WHEN ValidatePlatformDDL is called
// from a unit test with no database reachable and no BPM_DB_URL set, THEN
// the call succeeds and returns the same verdict as any other call — proven
// by this being a plain unit test with no DB setup at all, and by calling
// twice with identical input and asserting identical output (determinism).
test "TC-DDL-01-AC4: validatePlatformDDL is deterministic and requires no database" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "orders",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE orders (id uuid PRIMARY KEY)",
            .file = "004_test_ac4.sql",
            .byte_offset = 0,
        },
    };
    const file_set = FileSet{ .statements = &stmts, .actor = .tenant };
    const verdict1 = validatePlatformDDL(file_set);
    const verdict2 = validatePlatformDDL(file_set);
    try testing.expectEqual(ValidationVerdict.accept, verdict1);
    try testing.expectEqual(ValidationVerdict.accept, verdict2);
}

// DDL-01: first failure in statement order is reported — a file set with
// a passing statement first and a failing statement second must report the
// SECOND statement (order=2), not silently accept because the first passed.
// Named "order" (not "AC5") to avoid colliding with the genuine AC5
// (docs/requirements.yaml's 200-statement/100ms performance criterion,
// tested separately below as TC-DDL-01-AC5) — this test instead supports
// AC1/AC2/AC3's "naming that statement" wording for a multi-statement file
// set; see tests/specs/DDL-01.md's naming-disambiguation note.
test "TC-DDL-01-order: first failing statement in order is reported, earlier accepts are skipped" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "orders",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE orders (id uuid PRIMARY KEY)",
            .file = "005_test_order.sql",
            .byte_offset = 0,
        },
        .{
            .kind = .alter,
            .object_name = "orders",
            .class = .drop_column,
            .order = 2,
            .text = "ALTER TABLE orders DROP COLUMN stale",
            .file = "005_test_order.sql",
            .byte_offset = 45,
        },
        .{
            .kind = .create,
            .object_name = "idx_orders_bad",
            .class = .create_index_non_concurrent,
            .order = 3,
            .text = "CREATE INDEX idx_orders_bad ON orders (id)",
            .file = "005_test_order.sql",
            .byte_offset = 90,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(@as(u32, 2), detail.statement_order);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// DDL-01 ordering companion: no later statement is even inspected once an
// earlier one fails — verified here by having statement 1 fail the
// lock-class check and statement 2 carry an otherwise-detectable namespace
// violation; the verdict must name statement 1, proving statement 2 was
// never reached. See TC-DDL-01-order above for the naming-disambiguation
// note (this is "order-b", not "AC5b" — no collision with the AC5
// performance test below).
test "TC-DDL-01-order-b: a later statement's violation is never reported once an earlier one fails" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "orders",
            .class = .vacuum_full,
            .order = 1,
            .text = "VACUUM FULL orders",
            .file = "006_test_order_b.sql",
            .byte_offset = 0,
        },
        .{
            .kind = .create,
            .object_name = "plat_hijacked",
            .class = .other,
            .order = 2,
            .text = "CREATE TABLE plat_hijacked (id uuid PRIMARY KEY)",
            .file = "006_test_order_b.sql",
            .byte_offset = 20,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// Composition proof: the namespace check (DDL-05, composed via
// ddl_namespace.checkNamespace) fires through this module's own pipeline
// when no lock-class/index-concurrency violation precedes it.
test "TC-DDL-01-composition: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace via composed checkNamespace" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "plat_outbox",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE plat_outbox (id uuid PRIMARY KEY)",
            .file = "007_test_composition.sql",
            .byte_offset = 0,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .reserved_namespace => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
            try testing.expectEqualStrings("plat_outbox", detail.object_name);
        },
        else => return error.TestExpectedReservedNamespace,
    }
}

// Composition proof (platform side): a platform-authored CREATE without the
// plat_ prefix is refused as UnreservedPlatformObject via the composed check.
test "TC-DDL-01-composition-b: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "correlation_cursor",
            .class = .other,
            .order = 1,
            .text = "CREATE TABLE correlation_cursor (id uuid PRIMARY KEY)",
            .file = "008_test_composition_b.sql",
            .byte_offset = 0,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    switch (verdict) {
        .unreserved_platform_object => |detail| {
            try testing.expectEqualStrings("correlation_cursor", detail.object_name);
        },
        else => return error.TestExpectedUnreservedPlatformObject,
    }
}

/// Wall-clock nanosecond timer for TC-DDL-01-AC5's timing assertion only.
/// Zig 0.16 removed std.time.Timer / nanoTimestamp() from the public API
/// (see src/api/routes/instances.zig's currentMicrosecondTimestamp and
/// src/expr/benchmark.zig's getTimeNanos for the two other places this
/// codebase already reimplements the same platform primitives); this test
/// file needs its own copy purely to measure elapsed wall-clock time around
/// the call below. The module under test (validatePlatformDDL) itself takes
/// no clock dependency anywhere -- this timer lives ONLY in the test, never
/// in src/platform/ddl_validate.zig, so the module's own DDL-01 AC4 purity
/// contract ("no clock") is untouched.
fn testTimeNanos() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return unix_100ns * 100;
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.MONOTONIC, &ts);
        return ts.sec * 1_000_000_000 + ts.nsec;
    }
}

// DDL-01 AC5: GIVEN a file set of 200 accepted statements, WHEN validated,
// THEN the verdict is returned in under 100 ms. Deterministic in outcome
// (all 200 statements are `other`-classed CREATE TABLE statements that
// unconditionally ACCEPT, so the verdict itself never varies), only the
// wall-clock budget is environment-dependent -- this is DDL-01's own stated
// acceptance criterion, not an NFR benchmark, so it belongs in this unit
// test file rather than tests/bench. A 100ms budget against a pure,
// allocation-free, O(n) loop over 200 elements has enormous headroom; this
// is not a tight timing assertion prone to environment flakiness.
test "TC-DDL-01-AC5: 200 accepted statements validate in under 100ms" {
    var stmts: [200]StatementDescriptor = undefined;
    for (&stmts, 0..) |*stmt, i| {
        stmt.* = .{
            .kind = .create,
            .object_name = "orders",
            .class = .other,
            .order = @intCast(i + 1),
            .text = "CREATE TABLE orders (id uuid PRIMARY KEY)",
            .file = "009_test_ac5_perf.sql",
            .byte_offset = @intCast(i * 45),
        };
    }

    const start_ns = testTimeNanos();
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    const elapsed_ns = testTimeNanos() - start_ns;

    try testing.expectEqual(ValidationVerdict.accept, verdict);
    try testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
}

// Empty file set trivially accepts.
test "TC-DDL-01-empty: empty statement list is ACCEPT" {
    const stmts = [_]StatementDescriptor{};
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .platform });
    try testing.expectEqual(ValidationVerdict.accept, verdict);
}

// A statement using CONCURRENTLY for both index build and REINDEX is
// accepted (positive mirror of AC2's rejection cases) — proves the checks do
// not over-trigger on the safe/concurrent classes.
test "TC-DDL-01-positive: CONCURRENTLY index and reindex classes are ACCEPT" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .create,
            .object_name = "idx_events_actor",
            .class = .create_index_concurrent,
            .order = 1,
            .text = "CREATE INDEX CONCURRENTLY idx_events_actor ON events (actor_id)",
            .file = "010_test_positive.sql",
            .byte_offset = 0,
        },
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .reindex_concurrent,
            .order = 2,
            .text = "REINDEX INDEX CONCURRENTLY idx_events_actor",
            .file = "010_test_positive.sql",
            .byte_offset = 68,
        },
        .{
            .kind = .alter,
            .object_name = "events",
            .class = .drop_index_concurrent,
            .order = 3,
            .text = "DROP INDEX CONCURRENTLY idx_events_actor",
            .file = "010_test_positive.sql",
            .byte_offset = 114,
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    try testing.expectEqual(ValidationVerdict.accept, verdict);
}

// ---------------------------------------------------------------------------
// Unit tests — DDL-02 acceptance criteria
// ---------------------------------------------------------------------------

// DDL-02 AC1: GIVEN a file set running `ALTER TABLE instances ADD COLUMN
// first_event_at TIMESTAMPTZ NOT NULL`, WHEN validated, THEN
// ConstrainBeforeExpand is returned, because the column carries no constant
// default and no backfill precedes the constraint.
test "TC-DDL-02-AC1: ADD COLUMN NOT NULL with no default and no prior expand is refused as ConstrainBeforeExpand" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 1,
            .text = "ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NOT NULL",
            .file = "100_ddl02_ac1.sql",
            .byte_offset = 0,
            .ordering_role = .constrain,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .constrain_before_expand => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.constraining_statement_order);
            try testing.expectEqualStrings(
                "ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NOT NULL",
                detail.constraining_statement_text,
            );
            try testing.expectEqualStrings("100_ddl02_ac1.sql", detail.constraining_statement_file);
            try testing.expectEqual(@as(u32, 0), detail.constraining_statement_byte_offset);
            try testing.expectEqual(@as(?u32, null), detail.depended_on_statement_order);
            try testing.expectEqual(@as(?[]const u8, null), detail.depended_on_statement_text);
            try testing.expectEqualStrings("instances", detail.column.table);
            try testing.expectEqualStrings("first_event_at", detail.column.column);
        },
        else => return error.TestExpectedConstrainBeforeExpand,
    }
}

// DDL-02 AC2: GIVEN a file set running `ALTER TABLE instances ADD COLUMN
// first_event_at TIMESTAMPTZ NULL` followed immediately by
// `ALTER TABLE instances ALTER COLUMN first_event_at SET NOT NULL` with no
// backfill statement between them, WHEN validated, THEN ConstrainBeforeExpand
// is returned naming both statements.
test "TC-DDL-02-AC2: SET NOT NULL immediately after ADD COLUMN NULL with no backfill is refused, naming both statements" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 1,
            .text = "ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NULL",
            .file = "101_ddl02_ac2.sql",
            .byte_offset = 0,
            .ordering_role = .expand,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 2,
            .text = "ALTER TABLE instances ALTER COLUMN first_event_at SET NOT NULL",
            .file = "101_ddl02_ac2.sql",
            .byte_offset = 67,
            .ordering_role = .constrain,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .constrain_before_expand => |detail| {
            try testing.expectEqual(@as(u32, 2), detail.constraining_statement_order);
            try testing.expectEqualStrings(
                "ALTER TABLE instances ALTER COLUMN first_event_at SET NOT NULL",
                detail.constraining_statement_text,
            );
            try testing.expectEqualStrings("101_ddl02_ac2.sql", detail.constraining_statement_file);
            try testing.expectEqual(@as(u32, 67), detail.constraining_statement_byte_offset);
            // The dependency (the expand statement) exists but has no
            // intervening backfill — it is still named (AC5's "naming both
            // statements"), not treated as missing entirely.
            try testing.expectEqual(@as(?u32, 1), detail.depended_on_statement_order);
            try testing.expectEqualStrings(
                "ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NULL",
                detail.depended_on_statement_text.?,
            );
            try testing.expectEqualStrings("101_ddl02_ac2.sql", detail.depended_on_statement_file.?);
            try testing.expectEqual(@as(u32, 0), detail.depended_on_statement_byte_offset.?);
        },
        else => return error.TestExpectedConstrainBeforeExpand,
    }
}

// DDL-02 AC3: GIVEN a file set that adds the column nullable, adds
// `CHECK (first_event_at IS NOT NULL) NOT VALID`, backfills, then runs
// `VALIDATE CONSTRAINT`, WHEN validated, THEN the verdict is ACCEPT.
test "TC-DDL-02-AC3: expand, NOT VALID check, backfill, VALIDATE CONSTRAINT sequence is ACCEPT" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 1,
            .text = "ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NULL",
            .file = "102_ddl02_ac3.sql",
            .byte_offset = 0,
            .ordering_role = .expand,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 2,
            .text = "ALTER TABLE instances ADD CONSTRAINT first_event_at_not_null CHECK (first_event_at IS NOT NULL) NOT VALID",
            .file = "102_ddl02_ac3.sql",
            .byte_offset = 67,
            .ordering_role = .constrain_not_valid,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 3,
            .text = "UPDATE instances SET first_event_at = created_at WHERE first_event_at IS NULL",
            .file = "102_ddl02_ac3.sql",
            .byte_offset = 177,
            .ordering_role = .backfill,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 4,
            .text = "ALTER TABLE instances VALIDATE CONSTRAINT first_event_at_not_null",
            .file = "102_ddl02_ac3.sql",
            .byte_offset = 258,
            .ordering_role = .backfill,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    try testing.expectEqual(ValidationVerdict.accept, verdict);
}

// DDL-02 AC4: GIVEN an `ADD CONSTRAINT ... FOREIGN KEY` written without
// `NOT VALID`, WHEN validated, THEN ConstrainBeforeExpand is returned; a
// foreign key added without NOT VALID scans the whole table under a lock
// that blocks writes on both referencing and referenced tables.
test "TC-DDL-02-AC4: ADD CONSTRAINT FOREIGN KEY without NOT VALID is refused as ConstrainBeforeExpand" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 1,
            .text = "ALTER TABLE instances ADD COLUMN definition_id UUID NULL",
            .file = "103_ddl02_ac4.sql",
            .byte_offset = 0,
            .ordering_role = .expand,
            .ordering_column = .{ .table = "instances", .column = "definition_id" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 2,
            .text = "ALTER TABLE instances ADD CONSTRAINT fk_definition FOREIGN KEY (definition_id) REFERENCES definitions (id)",
            .file = "103_ddl02_ac4.sql",
            .byte_offset = 59,
            .ordering_role = .constrain,
            .ordering_column = .{ .table = "instances", .column = "definition_id" },
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .constrain_before_expand => |detail| {
            try testing.expectEqual(@as(u32, 2), detail.constraining_statement_order);
            try testing.expectEqualStrings("definition_id", detail.column.column);
        },
        else => return error.TestExpectedConstrainBeforeExpand,
    }
}

// DDL-02 AC5: The rejection message names the file and the byte offset of
// both the constraining statement and the statement it depends on. Verified
// directly against TC-DDL-02-AC2's populated-dependency case above (both
// non-null) and TC-DDL-02-AC1's missing-dependency case (both null) — this
// test adds a THIRD, cross-file-set-shaped scenario: two distinct columns
// tracked independently in the same file set, confirming the file/byte
// offset pairing is per-violation, not global state leaking between columns.
test "TC-DDL-02-AC5: rejection detail names file and byte offset for both statements, independent of other tracked columns" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 1,
            .text = "ALTER TABLE instances ADD COLUMN started_at TIMESTAMPTZ NULL",
            .file = "104_ddl02_ac5.sql",
            .byte_offset = 0,
            .ordering_role = .expand,
            .ordering_column = .{ .table = "instances", .column = "started_at" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 2,
            .text = "UPDATE instances SET started_at = created_at",
            .file = "104_ddl02_ac5.sql",
            .byte_offset = 63,
            .ordering_role = .backfill,
            .ordering_column = .{ .table = "instances", .column = "started_at" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 3,
            .text = "ALTER TABLE instances ALTER COLUMN started_at SET NOT NULL",
            .file = "104_ddl02_ac5.sql",
            .byte_offset = 109,
            .ordering_role = .constrain,
            .ordering_column = .{ .table = "instances", .column = "started_at" },
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 4,
            .text = "ALTER TABLE instances ADD COLUMN ended_at TIMESTAMPTZ NOT NULL",
            .file = "105_ddl02_ac5_second_file.sql",
            .byte_offset = 12,
            .ordering_role = .constrain,
            .ordering_column = .{ .table = "instances", .column = "ended_at" },
        },
    };
    // `started_at` is properly expanded+backfilled before being constrained
    // (order 1-3), so the FIRST violation in statement order is `ended_at`
    // at order 4 — proving per-column state does not leak across columns and
    // the reported file/byte_offset are `ended_at`'s own, not `started_at`'s.
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .constrain_before_expand => |detail| {
            try testing.expectEqual(@as(u32, 4), detail.constraining_statement_order);
            try testing.expectEqualStrings("105_ddl02_ac5_second_file.sql", detail.constraining_statement_file);
            try testing.expectEqual(@as(u32, 12), detail.constraining_statement_byte_offset);
            try testing.expectEqualStrings("ended_at", detail.column.column);
            try testing.expectEqual(@as(?u32, null), detail.depended_on_statement_order);
        },
        else => return error.TestExpectedConstrainBeforeExpand,
    }
}

// DDL-02 tie-break: constrain-before-expand loses to an earlier-order
// lock-class failure — proving the four-check aggregation keeps "first
// failure in statement order" true across all four checks, not just the
// original three.
test "TC-DDL-02-tiebreak: an earlier lock-class failure is reported instead of a later constrain-before-expand violation" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "orders",
            .class = .drop_column,
            .order = 1,
            .text = "ALTER TABLE orders DROP COLUMN stale",
            .file = "106_ddl02_tiebreak.sql",
            .byte_offset = 0,
        },
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 2,
            .text = "ALTER TABLE instances ADD COLUMN first_event_at TIMESTAMPTZ NOT NULL",
            .file = "106_ddl02_tiebreak.sql",
            .byte_offset = 40,
            .ordering_role = .constrain,
            .ordering_column = .{ .table = "instances", .column = "first_event_at" },
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .unbounded_exclusive_lock => |detail| {
            try testing.expectEqual(@as(u32, 1), detail.statement_order);
        },
        else => return error.TestExpectedUnboundedExclusiveLock,
    }
}

// DDL-02 positive: a pre-existing (never-expanded-in-this-file) column being
// constrained is rejected (the conservative, reject-by-default reading the
// design doc's "Open questions" #2 documents) — verified as a distinct case
// from AC1 since here `.constrain` is the ONLY statement touching this
// column, with no other statement in the file set at all.
test "TC-DDL-02-conservative: a bare SET NOT NULL with zero prior statements for that column anywhere in the file set is rejected" {
    const stmts = [_]StatementDescriptor{
        .{
            .kind = .alter,
            .object_name = "instances",
            .class = .other,
            .order = 1,
            .text = "ALTER TABLE instances ALTER COLUMN legacy_col SET NOT NULL",
            .file = "107_ddl02_conservative.sql",
            .byte_offset = 0,
            .ordering_role = .constrain,
            .ordering_column = .{ .table = "instances", .column = "legacy_col" },
        },
    };
    const verdict = validatePlatformDDL(.{ .statements = &stmts, .actor = .tenant });
    switch (verdict) {
        .constrain_before_expand => |detail| {
            try testing.expectEqual(@as(?u32, null), detail.depended_on_statement_order);
        },
        else => return error.TestExpectedConstrainBeforeExpand,
    }
}
