# Test Spec: DDL-05 — Reserved `plat_` object namespace

**Requirement:** DDL-05 — The prefix `plat_` SHALL be reserved for platform-owned objects in
every tenant schema. Tenant-authored DDL that creates, renames, or alters an object whose
name begins with `plat_` SHALL be refused with HTTP 422 before any statement is executed.
Every object the platform itself creates inside a tenant schema SHALL carry the prefix. The
check runs inside `ValidatePlatformDDL` in the same pass as the lock-class and ordering
checks.

**Priority:** MUST
**Test layer:** unit (pure function, no I/O, no allocation, no database)
**Test-tier score (test_developer_guide.md §2.1):** Tenant isolation (2, the namespace
partitions tenant vs. platform ownership inside every tenant schema) = **2 points → unit +
integration.** This batch implements only the standalone `checkNamespace` predicate (see
Scope note below), which has no DB or HTTP surface of its own to integration-test yet — the
integration layer for this score attaches once DDL-01's `ValidatePlatformDDL` pipeline (a
separate, later batch) composes this predicate into an HTTP-facing check. Unit coverage
alone is complete for the code that exists in this batch.
**Design:** `src/design/ddl-05-reserved-plat-namespace-check.md`
**Implementation:** `src/platform/ddl_namespace.zig`

---

## Scope note — read before treating AC5 as uncovered

This batch (WF02-batch-0-20260811) implements **only** `checkNamespace()`, the standalone
pure namespace-reservation predicate. The design artefact's own "Scoping note" section
states explicitly that DDL-05 AC5 ("the first failure in statement order is reported, so one
plan run yields one deterministic verdict") belongs to **DDL-01**'s `ValidatePlatformDDL`
aggregation pipeline — a separate, later batch that does not exist yet in this codebase.
CODE-DESIGN-VALIDATOR passed this scoping at WF02-batch-0-20260811 Step 01b. AC5 is
therefore **out of scope for this spec**, not an untested gap: there is no
multi-check-aggregating caller yet for a test to exercise. `ddl_namespace.zig`'s own
in-file comment (lines 289-294) records the same scoping note at the point AC5 would
otherwise be expected. When DDL-01's batch starts, its own test spec must add the
first-failure-in-statement-order coverage; this file's AC5 row is a forward pointer, not a
completed row.

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN a tenant submits DDL creating a table named `plat_outbox`, WHEN validated, THEN `ReservedNamespace` is returned, the API responds 422 with the offending object name in the body, and no statement is executed. | `TC-DDL-05-AC1` |
| AC2 | GIVEN a tenant submits `ALTER TABLE plat_correlation_cursor RENAME TO cursor_backup`, WHEN validated, THEN `ReservedNamespace` is returned and the API responds 422. | `TC-DDL-05-AC2`, `TC-DDL-05-AC2b`, `TC-DDL-05-AC2c` |
| AC3 | GIVEN a platform migration creates an object in a tenant schema without the `plat_` prefix, WHEN validated, THEN `UnreservedPlatformObject` is returned and the file set is REJECTED. | `TC-DDL-05-AC3`, `TC-DDL-05-AC3b`, `TC-DDL-05-AC3c` |
| AC4 | GIVEN a tenant creates a table named `platform_orders`, WHEN validated, THEN the verdict is ACCEPT; the reservation matches the exact prefix `plat_` and does not match a longer word sharing its first four characters. | `TC-DDL-05-AC4`, `TC-DDL-05-AC4b` |
| AC5 | GIVEN a file set failing the namespace check and the lock-class check, WHEN validated, THEN the first failure in statement order is reported, so one plan run yields one deterministic verdict. | **Out of scope for this batch** — belongs to DDL-01's `ValidatePlatformDDL` aggregation (see Scope note above). No test exists here by design, not by omission. |

Note on AC1's "the API responds 422" / "no statement is executed" clauses: this batch's
`checkNamespace()` is a pure classifier with no HTTP layer and no statement-execution
side-effects of its own (see design doc §"Module purpose" — the verdict is a plain return
value, never a thrown error, never an I/O call). The predicate correctly *returning*
`.reserved_namespace` is the full extent of what this module can prove; wiring that verdict
to an actual HTTP 422 response and to "no statement executed" is DDL-01's caller-side
responsibility once it exists, per the design's own division of labor.

---

## Test cases

### TC-DDL-05-AC1: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace
**Given:** Actor `.tenant`, a `.create` statement targeting object name `plat_outbox`.
**When:** `checkNamespace(.tenant, .{ .kind = .create, .object_name = "plat_outbox" })` is called.
**Then:** The verdict is `.reserved_namespace` and `detail.object_name` equals `"plat_outbox"` — the offending name is preserved exactly, matching AC1's "the offending object name in the body".
**Layer:** unit
**Acceptance criterion mapped:** AC1
**Zig test:** `"TC-DDL-05-AC1: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace"` (`src/platform/ddl_namespace.zig`)

### TC-DDL-05-AC2: tenant RENAME away from a plat_ name is refused as ReservedNamespace
**Given:** Actor `.tenant`, a `.rename_to` statement with `previous_object_name = "plat_correlation_cursor"` and `object_name = "cursor_backup"`.
**When:** `checkNamespace` is called.
**Then:** The verdict is `.reserved_namespace` with `detail.object_name == "cursor_backup"` (the NEW name is reported, per AC1's "offending object name" wording applied to the rename-direction rule) — even though the new name itself does not start with `plat_`, because the OLD name did.
**Layer:** unit
**Acceptance criterion mapped:** AC2 (worked example, exact wording from the requirement body)
**Zig test:** `"TC-DDL-05-AC2: tenant RENAME away from plat_correlation_cursor is refused as ReservedNamespace"`

### TC-DDL-05-AC2b: tenant RENAME into a plat_ name is refused as ReservedNamespace
**Given:** Actor `.tenant`, a `.rename_to` statement with `previous_object_name = "my_table"` and `object_name = "plat_hijacked"`.
**When:** `checkNamespace` is called.
**Then:** The verdict is `.reserved_namespace` with `detail.object_name == "plat_hijacked"` — proves the rename check judges BOTH sides, not just the old name; a tenant cannot claim the platform namespace by renaming into it.
**Layer:** unit
**Acceptance criterion mapped:** AC2 (companion case — rename-in direction, not explicit in the requirement's own worked example but required by the design doc's "judges BOTH sides" rule, which the requirement's rename semantics imply)
**Zig test:** `"TC-DDL-05-AC2b: tenant RENAME into a plat_ name is refused as ReservedNamespace"`

### TC-DDL-05-AC2c: tenant RENAME between two ordinary names is ACCEPT
**Given:** Actor `.tenant`, a `.rename_to` statement with `previous_object_name = "orders_v1"` and `object_name = "orders_v2"`.
**When:** `checkNamespace` is called.
**Then:** The verdict is `.accept` — proves the rename-direction rule does not over-trigger on ordinary renames.
**Layer:** unit
**Acceptance criterion mapped:** AC2 (negative companion — guards against a false positive on the rule AC2 establishes)
**Zig test:** `"TC-DDL-05-AC2c: tenant RENAME between two ordinary names is ACCEPT"`

### TC-DDL-05-AC3: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject
**Given:** Actor `.platform`, a `.create` statement targeting object name `correlation_cursor` (no prefix).
**When:** `checkNamespace` is called.
**Then:** The verdict is `.unreserved_platform_object` with `detail.object_name == "correlation_cursor"`.
**Layer:** unit
**Acceptance criterion mapped:** AC3
**Zig test:** `"TC-DDL-05-AC3: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject"`

### TC-DDL-05-AC3b: platform RENAME leaving the object unprefixed is refused as UnreservedPlatformObject
**Given:** Actor `.platform`, a `.rename_to` statement with `previous_object_name = "plat_correlation_cursor"` and `object_name = "cursor_backup"` (new name loses the prefix).
**When:** `checkNamespace` is called.
**Then:** The verdict is `.unreserved_platform_object` with `detail.object_name == "cursor_backup"` — a platform-authored rename must keep the object inside the namespace on both sides, not just the old side.
**Layer:** unit
**Acceptance criterion mapped:** AC3 (companion case — platform rename symmetry)
**Zig test:** `"TC-DDL-05-AC3b: platform RENAME leaving the object unprefixed is refused as UnreservedPlatformObject"`

### TC-DDL-05-AC3c: platform CREATE with plat_ prefix is ACCEPT
**Given:** Actor `.platform`, a `.create` statement targeting object name `plat_outbox`.
**When:** `checkNamespace` is called.
**Then:** The verdict is `.accept` — mirror-image positive case proving the check does not over-trigger on correctly-prefixed platform objects.
**Layer:** unit
**Acceptance criterion mapped:** AC3 (negative companion)
**Zig test:** `"TC-DDL-05-AC3c: platform CREATE with plat_ prefix is ACCEPT"`

### TC-DDL-05-AC4: tenant CREATE TABLE platform_orders is ACCEPT
**Given:** Actor `.tenant`, a `.create` statement targeting object name `platform_orders` (shares the first four characters "plat" with the reserved prefix but is not `plat_`).
**When:** `checkNamespace` is called.
**Then:** The verdict is `.accept` — the reservation matches the exact prefix `plat_` (including the underscore), not the substring `plat`.
**Layer:** unit
**Acceptance criterion mapped:** AC4
**Zig test:** `"TC-DDL-05-AC4: tenant CREATE TABLE platform_orders is ACCEPT (shares 'plat' but not 'plat_')"`

### TC-DDL-05-AC4b: tenant ALTER on platform_orders is ACCEPT
**Given:** Actor `.tenant`, an `.alter` statement targeting object name `platform_orders`.
**When:** `checkNamespace` is called.
**Then:** The verdict is `.accept` — proves the exact-prefix boundary holds for `.alter`, not only `.create`.
**Layer:** unit
**Acceptance criterion mapped:** AC4 (companion case — statement-kind coverage)
**Zig test:** `"TC-DDL-05-AC4b: tenant ALTER on platform_orders is ACCEPT"`

### TC-DDL-05-extra: tenant ALTER on a plat_-prefixed object is refused
**Given:** Actor `.tenant`, an `.alter` statement targeting object name `plat_locks`.
**When:** `checkNamespace` is called.
**Then:** The verdict is `.reserved_namespace` with `detail.object_name == "plat_locks"` — exercises the `.alter` branch of the reserved-namespace path (AC1's worked example only shows `.create`).
**Layer:** unit
**Acceptance criterion mapped:** AC1 (statement-kind coverage — `.alter` alongside `.create`)
**Zig test:** `"tenant ALTER on plat_-prefixed object is refused as ReservedNamespace"`

---

## Fixtures and isolation

`checkNamespace` is a pure, allocation-free, I/O-free function (no database handle, no
connection, no clock, no environment variable — see the module's own header comment). Every
test case constructs its `StatementDescriptor` inline with literal strings; there is no
shared state between test blocks, no fixture setup/teardown, and no database dependency.
Determinism is structural, not merely observed: the function has no non-deterministic input
to control for.

---

## Coverage summary

| Test case | Zig `test "..."` name | Covers |
|---|---|---|
| TC-DDL-05-AC1 | `TC-DDL-05-AC1: tenant CREATE TABLE plat_outbox is refused as ReservedNamespace` | AC1 |
| TC-DDL-05-AC2 | `TC-DDL-05-AC2: tenant RENAME away from plat_correlation_cursor is refused as ReservedNamespace` | AC2 |
| TC-DDL-05-AC2b | `TC-DDL-05-AC2b: tenant RENAME into a plat_ name is refused as ReservedNamespace` | AC2 (rename-in) |
| TC-DDL-05-AC2c | `TC-DDL-05-AC2c: tenant RENAME between two ordinary names is ACCEPT` | AC2 (negative) |
| TC-DDL-05-AC3 | `TC-DDL-05-AC3: platform CREATE without plat_ prefix is refused as UnreservedPlatformObject` | AC3 |
| TC-DDL-05-AC3b | `TC-DDL-05-AC3b: platform RENAME leaving the object unprefixed is refused as UnreservedPlatformObject` | AC3 (rename symmetry) |
| TC-DDL-05-AC3c | `TC-DDL-05-AC3c: platform CREATE with plat_ prefix is ACCEPT` | AC3 (negative) |
| TC-DDL-05-AC4 | `TC-DDL-05-AC4: tenant CREATE TABLE platform_orders is ACCEPT (shares 'plat' but not 'plat_')` | AC4 |
| TC-DDL-05-AC4b | `TC-DDL-05-AC4b: tenant ALTER on platform_orders is ACCEPT` | AC4 (alter) |
| TC-DDL-05-extra | `tenant ALTER on plat_-prefixed object is refused as ReservedNamespace` | AC1 (alter) |

**Implemented case count: 10 test blocks**, all in `src/platform/ddl_namespace.zig`. No gap
was found within this batch's scope — every AC this module implements (AC1-AC4) has at
least one, and in most cases 2-3, covering test cases; AC5 is deliberately out of scope (see
Scope note above), not a missed case. No `error.SkipZigTest` appears in this file (verified
by grep — zero matches).

Run: `zig build test-ddl-namespace` — confirmed 10/10 passing at time of writing.

---

## Traceability

- DDL-05 acceptance: AC1-AC4 fully covered by TC-DDL-05-AC1..AC4b plus one extra
  statement-kind case; AC5 explicitly deferred to DDL-01 per the design artefact's own
  scoping note.
- Extends SPT-01 (schema-per-tenant layout) — no new test coverage needed here; SPT-01's own
  spec covers schema provisioning itself.
- See MIG-01 (`tests/specs/MIG-01.md`) for the companion namespace convention on the
  platform-authored side (`platform.platform_migrations` itself lives in a dedicated
  `platform` schema, not a tenant schema, so DDL-05's tenant-schema-scoped rule does not
  apply to it directly — noted here only to avoid a reader assuming DDL-05 governs MIG-01's
  table name).
