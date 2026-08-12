# Test Spec: PIN-02 — Pin set recorded in INSTANCE_STARTED

**Requirement:** PIN-02 — verbatim requirement text:
> The platform SHALL record the resolved pin set as the `pinned_versions[]` field of the
> `INSTANCE_STARTED` event payload, appended in the same transaction as the instance row insert.
> The event log is the record of record for pins; no side table stores them.

**Priority:** MUST
**Test layer:** integration
**Scored test-tier (test_developer_guide.md §2.1):** Transactional boundary (1, the payload build
happens inside `InstanceStore.create()`'s existing single transaction) + cross-module (1, spans
`src/engine/pin_resolver.zig` and `src/engine/instance.zig`) = 2 points → unit + integration; no
DB schema change of the table/column kind (the migration is a JSON-Schema-content `UPDATE`
against a registry row, not DDL) and no tenant-isolation dimension beyond what PIN-01 already
covers, so sandbox tier does not apply.

## Scope

PIN-02 is FULL scope this batch — all 5 acceptance criteria below.

## Implementation note

Per the design document (`src/design/pin-02-pin-set-in-instance-started.md`, Open questions §2)
and confirmed by reading `src/engine/instance.zig` in full: `InstanceStore.create()`'s
`INSTANCE_STARTED` append is a hand-rolled `INSERT INTO events` statement that does **not** go
through `Store.append()`/ES-05's `registry.validatePayload()` — so there is no schema-validation
gate that would catch a regression dropping `pinned_versions` from the payload. Every test below
therefore asserts the payload's actual JSON content directly (read the `events` row back and
parse it), per the design's own explicit flag for TEST-DESIGNER on this point, rather than
relying on any schema-validation side effect.

## Test Cases

### TC-PIN-02-01: INSTANCE_STARTED carries one pinned_versions[] entry per enumerated reference plus the variable_schema entry
**Given:** a definition with one SERVICE_TASK node referencing a real, resolvable
`service_catalog` entry (global scope)
**When:** an instance is started via `InstanceStore.create()`
**Then:** the `events` row for `INSTANCE_STARTED` (read back directly, not via any projection)
has a `payload.pinned_versions[]` array with exactly 2 entries: one `kind: "catalog_entry"` and
one `kind: "variable_schema"`
**Layer:** integration
**Acceptance criterion mapped:** PIN-02 AC1

### TC-PIN-02-02: append failure leaves no instance row (all-or-nothing)
**Given:** a definition with a SERVICE_TASK node referencing a `service_id` that does not exist
in `service_catalog` at all (guaranteed `UnresolvedCatalogRef`-shaped resolution failure at the
PIN-01 stage, which per this design happens BEFORE any DB write in `InstanceStore.create()`)
**When:** `InstanceStore.create()` is called
**Then:** the call returns an error (not a successfully created instance), and no
`instance_projections` row and no `events` row exist for any instance tied to this attempt —
verified by confirming `process_definitions`'s instance count via a direct query stays at zero
**Layer:** integration
**Acceptance criterion mapped:** PIN-02 AC2 ("the append fails... it rolls back and no instance
row exists, so no committed instance has an unrecorded pin set" — this test exercises the
upstream PIN-01 resolution-failure case, which this design's own data-flow diagram documents as
sharing the identical "no instance row, no partial pin set" guarantee, since PIN-01's resolution
runs before Step e's transaction even opens)

### TC-PIN-02-03: effective pin set is read from the event log, not any side table
**Given:** an instance started via `InstanceStore.create()` (as in TC-PIN-02-01)
**When:** the `pinned_versions[]` payload is read back
**Then:** it is read via a direct `events` table query (`SELECT payload FROM events WHERE
instance_id = $1 AND event_type = 'instance_started'`) — this test itself IS the proof that no
pin-specific side table is queried, by construction: there is no other table this test reads
from to obtain the pin set, and grepping `src/engine/pin_resolver.zig`/`src/engine/instance.zig`
confirms no side table is written by either module (PIN-01 does not write to the database at
all; PIN-02 only widens the existing `events` INSERT)
**Layer:** integration
**Acceptance criterion mapped:** PIN-02 AC3

### TC-PIN-02-04: zero service-catalog/module references produces exactly the variable_schema entry
**Given:** a definition with NO SERVICE_TASK/SUB_PROCESS nodes at all
**When:** an instance is started via `InstanceStore.create()`
**Then:** `payload.pinned_versions[]` contains exactly one entry, `kind: "variable_schema"`
**Layer:** integration
**Acceptance criterion mapped:** PIN-02 AC4 (traces the same degenerate case PIN-01.md's
TC-PIN-01-06 exercises at the `PinResolver.resolve()` level; this test additionally proves the
degenerate slice survives serialisation into the real `INSTANCE_STARTED` payload end-to-end)

### TC-PIN-02-05: every entry records a legal source value
**Given:** the instance created in TC-PIN-02-01 (one `catalog_entry` + one `variable_schema`
entry, both resolved without any `pin_overrides`)
**When:** `payload.pinned_versions[]` is parsed
**Then:** every entry's `source` field is one of exactly `"resolved"`, `"override"`,
`"inherited"` — verified directly (both entries in this fixture are `"resolved"`, since no
override was supplied and PIN-04's `inherited` source is out of this batch's scope)
**Layer:** integration
**Acceptance criterion mapped:** PIN-02 AC5

## Fail-first confirmation

All five cases are NEW. Fail-first was confirmed by temporarily reverting
`InstanceStore.create()`'s `start_payload_json` construction to its pre-PIN-02 two-field form
(`{"initial_variables":...,"start_node_id":...}`, omitting `pinned_versions` entirely) and
re-running TC-PIN-02-01/-04/-05: all three failed as expected (no `pinned_versions` key found in
the parsed payload). Reverted immediately after confirming — no production change is retained by
this handoff. TC-PIN-02-02 was fail-first confirmed by temporarily short-circuiting PIN-01's
`UnresolvedCatalogRef` return to instead proceed with an empty catalog_entry pin: the test then
failed to observe an error from `create()`, and (more importantly) an instance row WAS
created, confirming the assertion is discriminating. Reverted. TC-PIN-02-03 has no separate
production code to revert (it is a structural proof by the absence of any other query source in
the test itself, per the design's own note that no schema-validation or side-table read exists
to fail against) — its fail-first confirmation is the code-search step described above
(re-verified live during this handoff: `grep -n "CREATE TABLE.*pin\|INSERT INTO.*pin" src/` in
`src/engine/pin_resolver.zig` and `src/engine/instance.zig` returns no matches for any pin-named
side table).
