# Module: pin-02-pin-set-in-instance-started

**Requirement ID:** PIN-02
**Run ID:** WF02-batch-4-20260811 (Stage 16)
**Covers:** PIN-02
**Extends:** none (PIN-02 has no `Extends:` line in its body)
**See (from PIN-02's own body):** PD-08 (graph snapshot pinning this sits beside), PIN-01 (the
resolution pipeline this design consumes — this batch's sibling design), PIN-04 (replay reads
this payload — NOT in this batch), ES-07 (retention — the protected-family guard this event
type already falls under), IR-07 (archived partitions remain queryable — the payload must be
readable from `events_archive` identically to `events`)

**Process document (read in full for this design):** `docs/processes/system/instance-version-
pinning.md`, step 10 specifically ("Append `INSTANCE_STARTED` carrying `definition_snapshot` and
`pinned_versions[]` in the same transaction as the instance row insert").

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** PIN-02 widens the JSON Schema registered for `INSTANCE_STARTED` in
   `event_type_registry` (adding `pinned_versions` as a property) — a genuine schema-adjacent
   change, but expressed as an `UPDATE` to a registry row's `json_schema` JSONB column, not a
   `CREATE TABLE`/`ALTER TABLE` DDL statement. `templates/specs/migration.template.yaml`'s schema
   targets table/column DDL, not JSON-Schema-content updates to a registry row — a poor fit for a
   4-line `UPDATE` that is really data content, not structure. Rule 1's letter ("adds, alters, or
   removes a database table/column") does not literally match here (no column changes), so this
   design does not force it through Type C; the statement itself is included below in full
   (4 lines, well under the 40-line cap) as part of the Type E artefact.
2. **Type A?** PIN-02 does not add a new HTTP route — it modifies the PAYLOAD SHAPE of an
   existing, already-emitted event inside an existing write path
   (`InstanceStore.create()`'s hand-rolled `INSERT INTO events` call, `src/engine/instance.zig`
   lines ~760–776). No 1-to-1 store-method mapping; the change is embedded inside an existing
   multi-step transaction. Rule 2 does not match.
3. **Type D / Type B?** No React Flow node, no admin page.
4. **Type E — yes.** A payload-shape and transactional-ordering change to an existing hand-rolled
   event-append call site, with an all-or-nothing durability guarantee (AC2) and a "no side table,
   ever" invariant (AC3) that constrain HOW the change must be wired, not merely WHAT column to
   add. Per `templates/lego-catalog.md`: "When in doubt, prefer Type E."

No fenced code block below exceeds the linter's 40-line cap.

## Module purpose

Extend the `INSTANCE_STARTED` event payload — appended today by `InstanceStore.create()`
(`src/engine/instance.zig`, EE-01) via a hand-built JSON string and a raw `INSERT INTO events`
statement inside the same transaction as the `instance_projections` row insert — to also carry
`pinned_versions[]`, the array PIN-01's resolution pipeline (this batch's sibling design)
produces. The event log remains the sole record of the pin set: no side table is introduced, and
a request for the "effective pin set" (a later requirement, PIN-04, not this batch) is specified
to read the event log directly rather than a cached projection. This design's job is narrower
than PIN-01's: given an already-resolved `[]PinnedVersion` slice, serialise it into the existing
`INSTANCE_STARTED` payload construction and ensure the append remains atomic with the instance
row insert exactly as it is today.

## Data flow diagram

```
InstanceStore.create() (src/engine/instance.zig, EE-01 — EXISTING function, modified in place)
        |
        v
  Step d (EXISTING, unmodified): SnapshotStore.create() captures definition_snapshot (PD-08)
        |
        v
  Step d.5 (PIN-01, NEW — this batch's sibling design): PinResolver.resolve() returns
        |             []PinnedVersion, still OUTSIDE any transaction (no instance row
        |             exists yet; a PIN-01 ResolutionError aborts here, exactly as
        |             PD-08's own DefinitionNotFound already does today)
        v
  Step e (EXISTING, modified): BEGIN transaction
        |
        |-- INSERT instance_projections   [UNCHANGED SQL/shape]
        |
        |-- build start_payload_json      [MODIFIED: now also serialises pinned_versions[]
        |     (EXISTING: {"initial_variables":...,"start_node_id":"..."})
        |     (NEW:      {"initial_variables":...,"start_node_id":"...",
        |                 "pinned_versions":[{"kind":...,"ref":...,
        |                 "resolved_id":...,"version":...,"source":...}, ...]})
        |
        |-- INSERT INTO events (..., event_type, payload, ...)  [UNCHANGED statement
        |     shape — same WITH seq AS (...) INSERT ... SELECT ... FROM seq pattern;
        |     only start_payload_json's CONTENT changes]
        |
        |-- persistEmittedEventsInTx(...)  [UNCHANGED — cascade events from transition()]
        |
        |-- UPDATE instance_projections (post-transition state)  [UNCHANGED]
        |
        v
        COMMIT  (instance row + INSTANCE_STARTED-with-pins + cascade events, all-or-
        nothing — PIN-02 AC2: "the append fails... it rolls back and no instance row
        exists, so no committed instance has an unrecorded pin set" — this is the
        SAME atomicity the existing code already provides for the instance row +
        INSTANCE_STARTED pair; PIN-02 does not add a new failure mode, it extends
        what is already inside the existing all-or-nothing boundary)
        v
Any later read of the effective pin set (PIN-04, not this batch) queries events /
events_archive for this instance_id's INSTANCE_STARTED row and parses
payload.pinned_versions[] directly — no pin table is ever queried (PIN-02 AC3)
```

## Public interface

### `event_type_registry` schema widening for `INSTANCE_STARTED`

```sql
UPDATE event_type_registry
SET json_schema = jsonb_set(
    json_schema,
    '{properties,pinned_versions}',
    '{"type":"array","items":{"type":"object","required":["kind","ref","resolved_id","version","source"],"properties":{"kind":{"type":"string","enum":["catalog_entry","variable_schema","module"]},"ref":{"type":"string"},"resolved_id":{"type":"string"},"version":{"type":"string"},"source":{"type":"string","enum":["resolved","override","inherited"]}}}}'::jsonb,
    true
)
WHERE name = 'INSTANCE_STARTED';
```

Migration file: next free number **`1150`** if PAR-06's Type C slice does not claim it first in
this same batch's implementation ordering, else `1151` — BACKEND-DEV resolves the exact number at
implementation time by re-checking `ls migrations/ | sort` immediately before writing the file
(the same "next free number, confirmed at design time" caveat PAR-01's design already used, since
two designs in the same batch cannot both claim a fixed literal number without coordination). Not
a new table — an `UPDATE` against the existing seed row `002_event_type_registry.sql` created
(line 25, quoted in full in the mandatory-reading step: `('INSTANCE_STARTED', 1,
'{"type":"object","required":["definition_id"],"properties":{"definition_id":{"type":"string"},
"correlation_key":{"type":"string"},"variables":{"type":"object"}}}'::jsonb, 'Process instance
started')`). `jsonb_set(..., true)` with `create_missing = true` is idempotent — re-running this
UPDATE against a schema where it already succeeded overwrites `pinned_versions` with the
identical value, satisfying the same re-run-safety convention every other migration in this
codebase follows.

**Note on the registered schema's existing `required` list:** `["definition_id"]` — the seed
row's OWN schema does not actually require `definition_id` as a payload field the way this
design's addition might suggest at first glance (worth flagging: `InstanceStore.create()`'s
EXISTING payload build, `{"initial_variables":...,"start_node_id":...}`, does not itself include
a `definition_id` key either — the registered schema and the actual emitted payload already
diverge before this design touches anything; see Open questions §3). This design does NOT add
`pinned_versions` to the `required` array — PIN-02 AC4 explicitly allows a definition with zero
service-catalog/module references to still produce a valid `pinned_versions[]` (containing only
the `variable_schema` entry), so the array is always present with at least one element in
practice, but this design does not make it schema-`required` in case a future degenerate case
(e.g. a definition somehow producing zero pins at all) should not hard-fail JSON Schema
validation at append time — `Store.append()`'s `registry.validatePayload()` call (ES-05) would
reject such a payload if `pinned_versions` were `required` and absent, which is a stricter
failure mode than PIN-02's own AC text asks for.

### `InstanceStore.create()` payload construction — exact change

Existing code (`src/engine/instance.zig` lines ~751–758, quoted verbatim from the mandatory
reading step):

```zig
const start_payload_json = std.fmt.allocPrint(
    a,
    "{{\"initial_variables\":{s},\"start_node_id\":\"{s}\"}}",
    .{ initial_variables, start_node_id.? },
) catch return InstanceError.TransactionFailed;
```

Replaced by a version that also serialises the `[]PinnedVersion` slice PIN-01's `PinResolver.
resolve()` returned earlier in the same function call (Step d.5 in the data flow diagram above):

```zig
// pinned_versions_json is built by a new helper, serialisePinnedVersions()
// (below), from the []PinnedVersion slice PinResolver.resolve() returned.
// Kept as a SEPARATE allocPrint step (not inlined into the single format
// string below) because []PinnedVersion has a variable element count —
// unlike initial_variables/start_node_id, which are always exactly one
// value each, the array must be built incrementally the same way
// InstanceStore.create()'s EXISTING tokens_buf (line ~707) already builds
// its own variable-length JSON array, for consistency with this file's
// existing serialisation style rather than introducing std.json.Stringify
// only for this one field.
const start_payload_json = std.fmt.allocPrint(
    a,
    "{{\"initial_variables\":{s},\"start_node_id\":\"{s}\",\"pinned_versions\":{s}}}",
    .{ initial_variables, start_node_id.?, pinned_versions_json },
) catch return InstanceError.TransactionFailed;
```

`pinned_versions_json` construction (new helper, mirrors the existing `tokens_buf` pattern at
line ~707–730 of the same file — an `ArrayList(u8)` built with manual `{`/`,`/`}` punctuation
rather than `std.json.Stringify`, matching this file's established style rather than introducing
a second serialisation approach for one field):

```zig
fn serialisePinnedVersions(allocator: std.mem.Allocator, pins: []const PinnedVersion) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.append(allocator, '[');
    for (pins, 0..) |p, i| {
        if (i > 0) try buf.append(allocator, ',');
        const entry = try std.fmt.allocPrint(
            allocator,
            "{{\"kind\":\"{s}\",\"ref\":\"{s}\",\"resolved_id\":\"{s}\",\"version\":\"{s}\",\"source\":\"{s}\"}}",
            .{ pinKindToString(p.kind), p.ref, p.resolved_id, p.version, pinSourceToString(p.source) },
        );
        try buf.appendSlice(allocator, entry);
    }
    try buf.append(allocator, ']');
    return buf.items;
}
```

`pins` must already be in the sorted-by-`(kind, ref)` order PIN-01's `resolve()` guarantees
(PIN-01 AC5 / PIN-02 AC1's "one `pinned_versions[]` entry per enumerated reference" — the
ordering guarantee is PIN-01's responsibility to produce, PIN-02's responsibility to preserve
verbatim through serialisation, not re-sort). `p.ref`/`p.resolved_id`/`p.version` are
caller-controlled-adjacent strings (service IDs, module IDs, schema hashes) — none contain
unescaped `"` in this codebase's existing identifier conventions (UUIDs, `service_id`
`VARCHAR(255)`, semver strings), so this design follows the SAME no-escaping convention
`InstanceStore.create()`'s existing `tokens_buf`/`start_payload_json` construction already uses
for `node_id`/`branch_id`/`start_node_id` — not introducing a JSON-escaping requirement this file
does not already have elsewhere. Flagged as Open questions §1 since it is a pre-existing
convention this design inherits rather than one it introduces, and a genuinely adversarial
`service_id` (if ever accepted un-validated from user input) could in principle break this
un-escaped construction — the SAME risk already latent in every other hand-built JSON string in
this function today.

### Transactional placement — confirms no new failure mode

The existing `INSERT INTO events (...) SELECT $1::uuid, $2, $3::jsonb, ...` statement (lines
~761–776) is unchanged in shape; only `$3` (the payload) carries different content. Because this
statement already runs inside `conn2`'s open transaction (`BEGIN` at line ~614, `errdefer
conn2.rollback()`), and because `start_payload_json`'s construction happens entirely in-process
(no DB round trip) before that `INSERT` executes, PIN-02 AC2's rollback guarantee ("the append
fails... it rolls back and no instance row exists") is satisfied by the SAME transaction boundary
that already protects the instance row — no new commit/rollback logic is needed. The one new
failure mode this design's Public interface introduces is `serialisePinnedVersions()`'s own
allocation failure (`OutOfMemory`), handled by the same `catch return InstanceError.
TransactionFailed` pattern every other allocation in this function already uses — not a new
`InstanceError` variant.

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| Instance row insert or `INSTANCE_STARTED` append fails after `BEGIN` | Any DB error inside the existing transaction (PIN-02 AC2) | `InstanceError.TransactionFailed` — EXISTING error variant, unmodified; the whole transaction rolls back via the existing `errdefer conn2.rollback()`, so no instance row and no `INSTANCE_STARTED` row ever becomes visible |
| `pinned_versions` payload fails ES-05's `registry.validatePayload()` JSON Schema check | Should not occur in practice IF the Public interface's registry `UPDATE` above ships in the same commit as this serialisation change — flagged because `InstanceStore.create()`'s raw `INSERT INTO events` does NOT currently go through `Store.append()`/`registry.validatePayload()` at all (it is a hand-rolled `INSERT`, bypassing ES-05 entirely — see Open questions §2) | Not applicable under the current call path (ES-05 is not invoked here); if a future refactor routes this INSERT through `Store.append()` instead, `StoreError.PayloadSchemaInvalid` would apply, but that is out of this design's scope |
| `serialisePinnedVersions()` allocation failure | Allocator returns `OutOfMemory` while building the JSON array string | `InstanceError.TransactionFailed`, matching every other `catch return InstanceError.TransactionFailed` in this function |

## Dependencies

- Depends on: PIN-01 (this batch's sibling design — supplies the `[]PinnedVersion` slice this
  design serialises; PIN-02 does not resolve anything itself), PD-08 (the existing instance-start
  transaction PIN-02 extends is the SAME one PD-08's snapshot capture and EE-01's instance-row
  insert already share), `002_event_type_registry.sql` (the `INSTANCE_STARTED` seed row this
  design's migration widens).
- Must NOT depend on: PIN-04 (replay reading `pinned_versions[]` back out — a later requirement,
  not in this batch; this design only specifies the WRITE side). Does NOT depend on ISS-0670/
  GH-711 (the platform-event-emission gap for `EXECUTION_*` events) — confirmed by reading PIN-02's
  body and `See:` list in full: `INSTANCE_STARTED` is not one of the six affected `EXECUTION_*`
  event types ISS-0670 names, and `InstanceStore.create()`'s existing hand-rolled INSERT already
  successfully appends `INSTANCE_STARTED` today (it is not blocked by the "no instance_id
  convention exists" problem ISS-0670 documents — that gap is specific to PLATFORM-level events
  with no owning instance; `INSTANCE_STARTED` by definition has the instance it is starting as its
  own `instance_id`, so no analogous gap exists here).

## Open questions

1. **Un-escaped string interpolation in hand-built JSON payload construction.** As noted in
   Public interface, `serialisePinnedVersions()` follows this file's existing convention of
   directly interpolating string values into a JSON template without escaping. This is a
   pre-existing pattern in `InstanceStore.create()` (not introduced by this design), but PIN-02's
   new fields (`ref`, `resolved_id`, `version` — ultimately service IDs / module IDs / schema
   hashes) widen the set of values flowing through this unescaped path. Flagged for
   CODE-DESIGN-VALIDATOR/SECURITY-REVIEWER to assess whether this pre-existing convention should
   be hardened (e.g. a shared `jsonEscapeString()` helper) as part of implementing this design, or
   tracked as a separate, pre-existing-debt issue per `docs/anti-patterns.md`'s "No Issue Left
   Local-Only" directive if it is judged out of PIN-02's own scope to fix.
2. **`InstanceStore.create()`'s hand-rolled `INSERT INTO events` bypasses `Store.append()`/ES-05
   entirely.** Confirmed by reading both functions in full: `Store.append()`
   (`src/event_store/store.zig`) is the ES-01..ES-08-compliant path (registry validation,
   idempotency-key handling, partition-aware target-table routing per PAR-03) but
   `InstanceStore.create()` writes `instance_started`/cascade events via its own raw `conn2.exec`
   calls, never calling `Store.append()`. This is PRE-EXISTING behaviour this design does not
   change (changing it is a much larger refactor than PIN-02's own AC text requires — PIN-02 only
   asks that the pin set be IN the `INSTANCE_STARTED` payload, appended atomically with the
   instance row, which the existing hand-rolled path already achieves for its other fields). Worth
   noting because it means this design's registry-schema-widening migration (Public interface)
   has NO enforcement mechanism catching a future `InstanceStore.create()` regression that drops
   `pinned_versions` from the payload — no ES-05 JSON Schema check runs on this call path today.
   Flagged for TEST-DESIGNER: the integration test covering PIN-02 AC1 needs to assert the
   payload's actual JSON content directly (read the row back and parse it), not rely on any
   schema-validation gate catching an omission.
3. **Pre-existing divergence between `INSTANCE_STARTED`'s registered schema and its actual
   payload.** Noted in Public interface: the registered schema requires `definition_id` as a
   payload property, but the actual code never includes that key (it includes
   `initial_variables`/`start_node_id` instead). This is PRE-EXISTING, not introduced by PIN-02,
   but this design's widening `UPDATE` statement touches the same JSON Schema object — flagged so
   CODE-DESIGN-VALIDATOR does not mistake this design's `jsonb_set` for the SOURCE of that
   divergence (it existed since `002_event_type_registry.sql`) and so ORCH can decide whether
   fixing the pre-existing `definition_id` mismatch belongs in this same commit (Unblock-Everything
   territory: does it block this design's own acceptance criteria? Reading PIN-02's AC text again,
   no — nothing in PIN-02 depends on `definition_id` being present or required in the schema) or
   should be filed as its own issue per "No Issue Left Local-Only" if judged unrelated. This design
   does not fix it, only surfaces it.
