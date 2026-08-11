# Module: ddl-05-reserved-plat-namespace-check

**Requirement ID:** DDL-05
**Run ID:** WF02-batch-0-20260811 (Stage 16)
**Covers:** DDL-05
**Extends:** SPT-01 (the schema-per-tenant layout this reservation partitions)
**See also (not implemented here):** DDL-01 (`ValidatePlatformDDL`, the full lock-class +
ordering + namespace validating pass — a separate, later batch), MIG-01

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No table/column is added, altered, or removed.
2. **Type A?** No HTTP route is added by this piece in isolation — the 422 response DDL-05
   describes is emitted by whatever caller invokes this check (DDL-01's future validating
   pass, or an interim direct caller), not by a new CRUD endpoint this module owns.
3. **Type D?** No React Flow node.
4. **Type B?** No admin/list page.
5. **Type E — yes.** A pure statement-classification predicate that DDL-01 will later
   compose into `ValidatePlatformDDL`'s multi-check pipeline. There is no CRUD/list/migration
   Lego shape for "reject a DDL statement by inspecting the object name it targets," and the
   catalog explicitly reserves this kind of validation logic for Type E.

## Scoping note — read this before extending

DDL-05's own body says the check "runs inside `ValidatePlatformDDL` in the same pass as the
lock-class and ordering checks" — that composite pipeline is **DDL-01**, and DDL-01 is a
separate, later batch (batch index 1), not in scope here. This design produces **only** the
standalone namespace-reservation predicate: a function that takes a DDL statement descriptor
and an actor kind, and returns ACCEPT or a `ReservedNamespace`/`UnreservedPlatformObject`
verdict. It does not implement lock-class checks, statement ordering, the "first failure in
statement order" aggregation rule (DDL-05 AC5), or the `ValidatePlatformDDL` entry point
itself — those belong to DDL-01's design when that batch starts, and DDL-01's design MUST
call into this module rather than re-deriving the prefix check.

## Module purpose

`src/platform/ddl_namespace.zig` decides, for a single parsed DDL statement targeting an
object inside a tenant schema, whether that statement is allowed to proceed under the
`plat_` reserved-namespace rule (DDL-05). The `plat_` prefix is reserved for platform-owned
objects in every tenant schema, so ownership of any object is decidable from its name alone,
without a catalog lookup (DDL-05 body, paragraph 2). The module has two symmetric jobs:

- **Tenant-authored DDL** that creates, renames, or alters an object whose name begins with
  `plat_` is refused (`ReservedNamespace`) — a tenant may never claim the platform's
  namespace.
- **Platform-authored DDL** (a platform migration writing into a tenant schema) that creates
  an object WITHOUT the `plat_` prefix is refused (`UnreservedPlatformObject`) — the platform
  must not leave undecidable objects behind either. This is the mirror-image check DDL-05 AC3
  describes, catching a platform migration file that forgot the prefix before it ships.

The module is a pure, allocation-free predicate: no database handle, no connection, no clock,
no environment variable — the same purity constraint DDL-01's body states for
`ValidatePlatformDDL` as a whole, satisfied here for the one check this module owns so that
DDL-01 can compose it into a larger pure pipeline without re-deriving purity later.

## Public interface

Verdict and detail types — `.accept` carries no data; DDL-01's future `ValidatePlatformDDL`
is expected to aggregate this into a richer multi-check verdict type, and this module returns
only its own opinion:

```zig
pub const NamespaceVerdict = union(enum) {
    accept,
    reserved_namespace: ReservedNamespaceDetail,
    unreserved_platform_object: UnreservedPlatformObjectDetail,
};

pub const ReservedNamespaceDetail = struct {
    /// Exactly as submitted (DDL-05 AC1: "the offending object name in the body").
    object_name: []const u8,
};

pub const UnreservedPlatformObjectDetail = struct {
    object_name: []const u8,
};
```

Inputs — who is asking, and what they are asking to do. `Actor` is supplied by the caller;
this module does not resolve identity itself (see Dependencies). `StatementDescriptor` is the
subset of a parsed DDL statement this check needs; DDL-01's future statement-descriptor type
is expected to be a superset of this shape:

```zig
pub const Actor = enum { tenant, platform };

pub const StatementKind = enum { create, rename_to, alter };

pub const StatementDescriptor = struct {
    kind: StatementKind,
    /// Object being created/altered, or the NEW name in a RENAME TO.
    object_name: []const u8,
    /// Name BEFORE a rename, when kind == .rename_to; null otherwise.
    /// See "AC2 worked example" below for why both names matter.
    previous_object_name: ?[]const u8 = null,
};
```

The predicate itself, and the shared prefix constant so DDL-01's future pipeline and any test
never re-derive the literal string independently:

```zig
/// Pure predicate. No I/O, no allocation, no fallible return — the verdict
/// itself carries the failure information the caller needs to build a 422
/// (tenant-authored) or a file-set rejection (platform-authored, DDL-05 AC3).
pub fn checkNamespace(actor: Actor, stmt: StatementDescriptor) NamespaceVerdict;

pub const RESERVED_PREFIX = "plat_";
```

No HTTP handler, no error-to-Problem-Details mapping, and no route lives in this module.
Composing `checkNamespace`'s verdict into an HTTP 422 response (DDL-05 AC1/AC2) is DDL-01's
`ValidatePlatformDDL` pipeline's job — the same way `src/api/errors.zig`'s
`problemUnprocessable()` constructor is generic and is called by whichever route handler owns
the request, not embedded in the validator.

## Data flow

```
Tenant DDL request                    Platform migration file set
        │                                       │
        ▼                                       ▼
 (future: DDL-01 statement parser)     (future: DDL-01 statement parser)
        │                                       │
        │  StatementDescriptor{kind, object_name, ...}
        ▼                                       ▼
        Actor.tenant  ─────┐         ┌───── Actor.platform
                            ▼         ▼
                    checkNamespace(actor, stmt)
                            │
              ┌─────────────┼──────────────┐
              ▼             ▼              ▼
           .accept   .reserved_namespace  .unreserved_platform_object
              │             │              │
              ▼             ▼              ▼
      (continue to    (future: DDL-01   (future: DDL-01
       next check in   maps to HTTP 422  rejects the whole
       DDL-01's        via errors.zig    file set — DDL-05
       pipeline)        problemUnprocessable,  AC3: "the file set
                        detail = object_name)   is REJECTED")
```

`checkNamespace` itself has no branches back into I/O — every arrow after its return is
caller-owned, drawn here only to show where this module's output plugs into DDL-01's future
pipeline (`ValidatePlatformDDL`'s "first failure in statement order" aggregation, DDL-05 AC5,
lives entirely in that later module, not here).

## Error taxonomy

| Verdict | When | Corresponds to |
|---|---|---|
| `.accept` | `actor == .tenant` and `object_name` does not start with the exact prefix `plat_`; OR `actor == .platform` and it does. | DDL-05 AC4 (`platform_orders` — shares the first four characters `plat` but not the full `plat_` prefix — ACCEPT) |
| `.reserved_namespace` | `actor == .tenant` and `object_name` starts with `plat_`, for `kind` in `{create, alter}`; or for `kind == .rename_to`, when the NEW name (`object_name`) starts with `plat_`. | DDL-05 AC1 (`CREATE TABLE plat_outbox`), AC2 (`RENAME TO cursor_backup` — see note below; the AC2 example is actually a rename AWAY from a `plat_` name, covered by the symmetric rule stated in "AC2 worked example" below) |
| `.unreserved_platform_object` | `actor == .platform` and `object_name` (for create/alter) or the new name (for rename) does NOT start with `plat_`. | DDL-05 AC3 |

This module raises no Zig `error{...}` set — every outcome, including both rejection cases,
is a normal return value (`NamespaceVerdict`), not a thrown error. A pure classifier that can
answer every input has no failure mode of its own; forcing callers through `catch` for an
ordinary "reject" verdict would misrepresent a expected business outcome as an exceptional one
(the same reasoning `backend_developer_guide.md §3.2` gives for typed error sets: reserve
`error{...}` for things that can *fail* to be decided, not for a decision the caller dislikes).

### AC2 worked example (rename direction)

DDL-05 AC2 is: `ALTER TABLE plat_correlation_cursor RENAME TO cursor_backup` →
`ReservedNamespace`. Read literally, the *new* name (`cursor_backup`) does **not** start with
`plat_` — so a naive "check only the new name" rule would wrongly ACCEPT this statement, which
contradicts the AC. The correct rule, and the one `checkNamespace` implements, is: **for a
rename, check both `previous_object_name` and `object_name` (the new name), and reserve the
namespace on either side** — a tenant may neither claim a `plat_` name via rename-in, nor
smuggle a platform-owned object out of the namespace via rename-out (`cursor_backup` would
then be an ordinary tenant table masquerading as having escaped platform ownership, silently
breaking DDL-05's "ownership is decidable from the name alone" invariant for whatever this
object actually contains). This is the one respect in which the interface above understates
the rule in prose form — the field comment on `previous_object_name` names it, and this
section is the authoritative statement of the check itself for BACKEND-DEV to implement:

```
kind == .rename_to:
  if actor == .tenant and (starts_with(previous_object_name, "plat_")
                            or starts_with(object_name, "plat_")):
      -> .reserved_namespace{ object_name = object_name }   // report the NEW name, per AC1's
                                                              // "offending object name" wording
  if actor == .platform and not (starts_with(previous_object_name, "plat_")
                                  and starts_with(object_name, "plat_")):
      -> .unreserved_platform_object{ object_name = object_name }
```

## State transitions

Not applicable — `checkNamespace` is a single pure call with no persisted state and no
lifecycle. (Contrast with MIG-01's control-row `pending → done | failed` lifecycle in
`src/design/mig-02-mig-03-platform-migration-fanout.md`, which does have state transitions.)

## Dependencies

**Calls into:** nothing. `checkNamespace` is a leaf function — no database, no other `src/db/*`
or `src/platform/*` module, no allocator.

**Must NOT depend on:**
- `src/db/pool.zig`, `src/db/provisioning.zig`, `src/db/migrations.zig`, or any other module
  that opens a connection — this check runs on parsed statement descriptors already in memory,
  before any statement executes (DDL-05 AC1: "no statement is executed").
- `std.time` or any clock — determinism is required so the same statement always yields the
  same verdict regardless of when it is checked.
- Any DDL-01 type that does not yet exist. This module defines its own minimal
  `StatementDescriptor`/`Actor` so it can be built and tested standalone now; when DDL-01
  lands, its statement-descriptor and actor-resolution types should either match this shape or
  DDL-01's design must show the adapter between the two — this module's public interface is
  not expected to change shape at that point, only to gain a caller.

**Who resolves `Actor`:** out of scope for this module. The requirement text implies the
platform migration runner and the tenant-facing DDL API are distinguishable callers; DDL-01's
design (or an interim direct integration, if `ValidatePlatformDDL` has not landed when this
check needs to be wired in) is responsible for deciding, from request context, which `Actor`
value to pass in. `checkNamespace` trusts its caller's `Actor` value — it does not itself
inspect auth tokens, RBAC roles, or session state to determine who is calling.

## Open questions

None. DDL-05's five acceptance criteria are fully covered by the verdict table and the AC2
rename-direction rule above; the one genuine ambiguity in the requirement text (whether a
rename judges the old name, the new name, or both) is resolved by the worked example, which
is the interpretation consistent with all five ACs simultaneously (AC1 create, AC2 rename,
AC3 platform-authored, AC4 non-matching prefix, AC5 statement-order aggregation — the last of
which is explicitly DDL-01's job, not this module's, per the scoping note above).
