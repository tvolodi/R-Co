//! Reserved `plat_` object namespace check — DDL-05
//!
//! Design artefact: src/design/ddl-05-reserved-plat-namespace-check.md
//!
//! Decides, for a single parsed DDL statement targeting an object inside a
//! tenant schema, whether that statement is allowed to proceed under the
//! `plat_` reserved-namespace rule. The prefix `plat_` is reserved for
//! platform-owned objects in every tenant schema, so ownership of any object
//! is decidable from its name alone, without a catalog lookup.
//!
//! Two symmetric jobs:
//!   - Tenant-authored DDL that creates, renames, or alters an object whose
//!     name begins with `plat_` is refused (.reserved_namespace) — a tenant
//!     may never claim the platform's namespace.
//!   - Platform-authored DDL (a platform migration writing into a tenant
//!     schema) that creates an object WITHOUT the `plat_` prefix is refused
//!     (.unreserved_platform_object) — the platform must not leave
//!     undecidable objects behind either.
//!
//! Pure, allocation-free predicate: no database handle, no connection, no
//! clock, no environment variable, no Zig `error{...}` set. Every outcome —
//! including both rejection cases — is a normal return value
//! (NamespaceVerdict), never a thrown error, per the design doc's Error
//! taxonomy section: a pure classifier that can answer every input has no
//! failure mode of its own.
//!
//! Scope note: this module implements ONLY the standalone namespace-
//! reservation predicate (DDL-05). It does not implement lock-class checks,
//! statement ordering, or the "first failure in statement order" aggregation
//! rule (DDL-05 AC5) — those belong to DDL-01's `ValidatePlatformDDL`
//! pipeline, a separate, later batch, which is expected to compose
//! checkNamespace() into its own multi-check verdict.
const std = @import("std");

/// The reserved prefix. Shared constant so DDL-01's future pipeline and any
/// test never re-derive the literal string independently.
pub const RESERVED_PREFIX = "plat_";

/// Who is asking. Supplied by the caller — this module does not resolve
/// identity itself; see the design doc's Dependencies section ("Who resolves
/// Actor").
pub const Actor = enum { tenant, platform };

/// The kind of DDL statement being checked.
pub const StatementKind = enum { create, rename_to, alter };

/// The subset of a parsed DDL statement this check needs. DDL-01's future
/// statement-descriptor type is expected to be a superset of this shape.
pub const StatementDescriptor = struct {
    kind: StatementKind,
    /// Object being created/altered, or the NEW name in a RENAME TO.
    object_name: []const u8,
    /// Name BEFORE a rename, when kind == .rename_to; null otherwise.
    /// See the AC2 worked example in the design doc for why both names
    /// matter: a rename must be judged on BOTH sides, not just the new name.
    previous_object_name: ?[]const u8 = null,
};

/// Detail carried by a `.reserved_namespace` verdict — exactly as submitted
/// (DDL-05 AC1: "the offending object name in the body").
pub const ReservedNamespaceDetail = struct {
    object_name: []const u8,
};

/// Detail carried by a `.unreserved_platform_object` verdict.
pub const UnreservedPlatformObjectDetail = struct {
    object_name: []const u8,
};

/// The verdict returned by checkNamespace(). `.accept` carries no data;
/// DDL-01's future `ValidatePlatformDDL` is expected to aggregate this into a
/// richer multi-check verdict type — this module returns only its own
/// opinion.
pub const NamespaceVerdict = union(enum) {
    accept,
    reserved_namespace: ReservedNamespaceDetail,
    unreserved_platform_object: UnreservedPlatformObjectDetail,
};

fn hasReservedPrefix(name: []const u8) bool {
    return std.mem.startsWith(u8, name, RESERVED_PREFIX);
}

/// Pure predicate. No I/O, no allocation, no fallible return — the verdict
/// itself carries the failure information the caller needs to build a 422
/// (tenant-authored) or a file-set rejection (platform-authored, DDL-05 AC3).
///
/// Rule, exactly per the design doc's "AC2 worked example (rename direction)"
/// section — the authoritative statement of the check:
///
///   kind != .rename_to (create / alter):
///     actor == .tenant   and object_name starts with "plat_" -> reserved_namespace
///     actor == .platform and object_name does NOT start with "plat_" -> unreserved_platform_object
///
///   kind == .rename_to:
///     actor == .tenant and (previous_object_name starts with "plat_"
///                            or object_name starts with "plat_")
///         -> reserved_namespace{ object_name = object_name }  // report the NEW name (AC1 wording)
///     actor == .platform and NOT (previous_object_name starts with "plat_"
///                                  and object_name starts with "plat_")
///         -> unreserved_platform_object{ object_name = object_name }
///
/// A rename judges BOTH sides: a tenant may neither claim a `plat_` name via
/// rename-in, nor smuggle a platform-owned object out of the namespace via
/// rename-out.
pub fn checkNamespace(actor: Actor, stmt: StatementDescriptor) NamespaceVerdict {
    switch (stmt.kind) {
        .rename_to => {
            // previous_object_name is expected non-null for a rename per the
            // StatementDescriptor contract; treat a missing previous name as
            // "not reserved" on that side rather than panicking, since this
            // predicate must answer every input (see Error taxonomy note
            // above) — a malformed descriptor is the caller's bug to fix,
            // not a reason for this pure function to fail loudly.
            const prev_reserved = if (stmt.previous_object_name) |prev| hasReservedPrefix(prev) else false;
            const new_reserved = hasReservedPrefix(stmt.object_name);

            switch (actor) {
                .tenant => {
                    if (prev_reserved or new_reserved) {
                        return .{ .reserved_namespace = .{ .object_name = stmt.object_name } };
                    }
                    return .accept;
                },
                .platform => {
                    if (!(prev_reserved and new_reserved)) {
                        return .{ .unreserved_platform_object = .{ .object_name = stmt.object_name } };
                    }
                    return .accept;
                },
            }
        },
        .create, .alter => {
            const reserved = hasReservedPrefix(stmt.object_name);
            switch (actor) {
                .tenant => {
                    if (reserved) {
                        return .{ .reserved_namespace = .{ .object_name = stmt.object_name } };
                    }
                    return .accept;
                },
                .platform => {
                    if (!reserved) {
                        return .{ .unreserved_platform_object = .{ .object_name = stmt.object_name } };
                    }
                    return .accept;
                },
            }
        },
    }
}

// ---------------------------------------------------------------------------
// Unit tests — DDL-05 acceptance criteria
// ---------------------------------------------------------------------------

const testing = std.testing;

// DDL-05 AC1: GIVEN a tenant submits DDL creating a table named `plat_outbox`,
// WHEN validated, THEN ReservedNamespace is returned (the offending object
// name in the body is `plat_outbox`).
test "TC-DDL-05-AC1: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace" {
    const verdict = checkNamespace(.tenant, .{
        .kind = .create,
        .object_name = "plat_outbox",
    });
    switch (verdict) {
        .reserved_namespace => |detail| {
            try testing.expectEqualStrings("plat_outbox", detail.object_name);
        },
        else => return error.TestExpectedReservedNamespace,
    }
}

// DDL-05 AC2 (rename-direction worked example): GIVEN a tenant submits
// `ALTER TABLE plat_correlation_cursor RENAME TO cursor_backup`, WHEN
// validated, THEN ReservedNamespace is returned — even though the NEW name
// ("cursor_backup") does not itself start with plat_. The OLD name
// (plat_correlation_cursor) is reserved, so renaming away from it is also
// refused per the design doc's rename-direction rule.
test "TC-DDL-05-AC2: tenant RENAME away from plat_correlation_cursor is refused as ReservedNamespace" {
    const verdict = checkNamespace(.tenant, .{
        .kind = .rename_to,
        .object_name = "cursor_backup",
        .previous_object_name = "plat_correlation_cursor",
    });
    switch (verdict) {
        .reserved_namespace => |detail| {
            // Report the NEW name, per AC1's "offending object name" wording,
            // as stated in the design doc's rename-direction rule.
            try testing.expectEqualStrings("cursor_backup", detail.object_name);
        },
        else => return error.TestExpectedReservedNamespace,
    }
}

// AC2 companion case: a tenant renaming INTO a plat_ name must also be
// refused (claiming the namespace via rename-in), proving both sides of the
// rename are checked, not just the old name.
test "TC-DDL-05-AC2b: tenant RENAME into a plat_ name is refused as ReservedNamespace" {
    const verdict = checkNamespace(.tenant, .{
        .kind = .rename_to,
        .object_name = "plat_hijacked",
        .previous_object_name = "my_table",
    });
    switch (verdict) {
        .reserved_namespace => |detail| {
            try testing.expectEqualStrings("plat_hijacked", detail.object_name);
        },
        else => return error.TestExpectedReservedNamespace,
    }
}

// AC2 companion case: an ordinary tenant rename between two non-plat_ names
// must be accepted — proves the rename-direction rule does not over-trigger.
test "TC-DDL-05-AC2c: tenant RENAME between two ordinary names is ACCEPT" {
    const verdict = checkNamespace(.tenant, .{
        .kind = .rename_to,
        .object_name = "orders_v2",
        .previous_object_name = "orders_v1",
    });
    try testing.expectEqual(NamespaceVerdict.accept, verdict);
}

// DDL-05 AC3: GIVEN a platform migration creates an object in a tenant schema
// without the plat_ prefix, WHEN validated, THEN UnreservedPlatformObject is
// returned.
test "TC-DDL-05-AC3: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject" {
    const verdict = checkNamespace(.platform, .{
        .kind = .create,
        .object_name = "correlation_cursor",
    });
    switch (verdict) {
        .unreserved_platform_object => |detail| {
            try testing.expectEqualStrings("correlation_cursor", detail.object_name);
        },
        else => return error.TestExpectedUnreservedPlatformObject,
    }
}

// AC3 companion case: a platform-authored rename that leaves the object
// outside the plat_ namespace on either side must also be refused.
test "TC-DDL-05-AC3b: platform RENAME leaving the object unprefixed is refused as UnreservedPlatformObject" {
    const verdict = checkNamespace(.platform, .{
        .kind = .rename_to,
        .object_name = "cursor_backup",
        .previous_object_name = "plat_correlation_cursor",
    });
    switch (verdict) {
        .unreserved_platform_object => |detail| {
            try testing.expectEqualStrings("cursor_backup", detail.object_name);
        },
        else => return error.TestExpectedUnreservedPlatformObject,
    }
}

// AC3 companion case: a correctly-prefixed platform-authored object is
// accepted (mirror-image positive case).
test "TC-DDL-05-AC3c: platform CREATE with plat_ prefix is ACCEPT" {
    const verdict = checkNamespace(.platform, .{
        .kind = .create,
        .object_name = "plat_outbox",
    });
    try testing.expectEqual(NamespaceVerdict.accept, verdict);
}

// DDL-05 AC4: GIVEN a tenant creates a table named `platform_orders`, WHEN
// validated, THEN the verdict is ACCEPT — the reservation matches the exact
// prefix `plat_` and does not match a longer word sharing its first four
// characters ("plat").
test "TC-DDL-05-AC4: tenant CREATE TABLE platform_orders is ACCEPT (shares 'plat' but not 'plat_')" {
    const verdict = checkNamespace(.tenant, .{
        .kind = .create,
        .object_name = "platform_orders",
    });
    try testing.expectEqual(NamespaceVerdict.accept, verdict);
}

// AC4 companion case: alter, not just create, must also respect the exact
// prefix boundary.
test "TC-DDL-05-AC4b: tenant ALTER on platform_orders is ACCEPT" {
    const verdict = checkNamespace(.tenant, .{
        .kind = .alter,
        .object_name = "platform_orders",
    });
    try testing.expectEqual(NamespaceVerdict.accept, verdict);
}

// DDL-05 AC5 ("the first failure in statement order is reported") is
// explicitly out of scope for this module per the design doc's scoping
// note — it belongs to DDL-01's ValidatePlatformDDL aggregation, which does
// not exist yet. No test for it lives here; see
// src/design/ddl-05-reserved-plat-namespace-check.md's "Scoping note" and
// "Open questions" sections.

// Additional coverage: tenant ALTER on a plat_-prefixed object is refused,
// exercising the .alter StatementKind branch (not just .create) for the
// reserved-namespace path.
test "tenant ALTER on plat_-prefixed object is refused as ReservedNamespace" {
    const verdict = checkNamespace(.tenant, .{
        .kind = .alter,
        .object_name = "plat_locks",
    });
    switch (verdict) {
        .reserved_namespace => |detail| {
            try testing.expectEqualStrings("plat_locks", detail.object_name);
        },
        else => return error.TestExpectedReservedNamespace,
    }
}
