# Module: pin-01-dependency-version-resolution

**Requirement ID:** PIN-01
**Run ID:** WF02-batch-4-20260811 (Stage 16)
**Covers:** PIN-01
**Extends:** PD-08, from the process graph to the non-graph versioned artefacts an instance
depends on
**See (from PIN-01's own body):** PD-08 (the graph-pinning mechanism this extends), REPO-07
(service catalog), SVC-01 (service catalog tenant scoping), PLC-01 (process module catalog),
PIN-02 (pin set recorded in `INSTANCE_STARTED` — the sibling requirement this batch also
designs), PIN-03 (no fallback to latest — NOT in this batch, execution-time enforcement)

**Process document (read in full for this design):** `docs/processes/system/instance-version-
pinning.md` — steps 1–10 are PIN-01/PIN-02's scope; steps 11–17 belong to PIN-03/PIN-04/PIN-05
(not this batch).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** No new table is strictly required by PIN-01's own AC text (unlike PAR-06, which
   adds two columns). Resolution reads existing/planned catalogs and writes nothing itself — the
   write (the `pinned_versions[]` payload) belongs to PIN-02, appended as part of
   `INSTANCE_STARTED`, not to a side table. Rule 1 does not match.
2. **Type A?** PIN-01 does not add a new HTTP route (it modifies the EXISTING `POST
   /api/v1/instances` handler's internal resolution step, per the process document's step 1) and
   does not map 1-to-1 onto a single store method — it is a multi-source resolution pipeline
   (service catalog + variable schema + module catalog + overrides) with four distinct 422
   failure modes. Rule 2 does not match ("Skip if the handler needs custom business logic
   mid-flight — that is Type E").
3. **Type D / Type B?** No React Flow node, no admin list page.
4. **Type E — yes.** A structurally novel, multi-source, ordered resolution pipeline invoked
   from inside an existing endpoint's request-handling path, with typed 422 outcomes and a
   byte-identical-ordering guarantee (AC5) that has no equivalent in any A–D template. Per
   `templates/lego-catalog.md`: "When in doubt, prefer Type E."

No fenced code block below exceeds the linter's 40-line cap.

## Scoping note — read this before implementing (CRITICAL — two hard dependencies are not yet built)

**PIN-01 cannot be fully implemented today. Two of the three reference kinds it must resolve
depend on infrastructure that does not exist in this codebase yet:**

1. **`service_catalog` has no version/active-version concept at all.** Read
   `migrations/049_repository_service_catalog.sql` and `migrations/GBL-117_svc01_service_catalog_
   scope.sql` in full: the table's columns are `service_id, endpoint_url, request_schema,
   response_schema, required_auth, timeout_ms, retry_policy, created_at, updated_at, scope,
   owner_tenant_id` — there is no `version` column, no `status` column, and therefore no way to
   express "no catalog entry with an ACTIVE version" (PIN-01 AC1's exact trigger condition).
   `service_id` is the table's PRIMARY KEY (one row per service, not one row per
   service-version). REPO-07's own AC text ("A script declaring `service:call:X` is rejected at
   registration if service X is not in the catalog") and ADP-08's existing consumer
   (`src/engine/service_task.zig`) both treat the catalog as unversioned — `resolveCatalogEndpoint()`
   looks up `service_id` directly with no version parameter anywhere in the call chain. Making
   PIN-01 AC1 real requires either (a) a new `version`/`status` column pair on `service_catalog`
   itself (a breaking reshape of an already-RELEASED, in-production table), or (b) a decision that
   `service_catalog` entries are implicitly always "active" (single-version-per-service, no
   version history) and PIN-01's `{kind: catalog_entry, ...}` pin records that single, unversioned
   identity as a degenerate "version" — this design cannot make that schema call unilaterally (per
   `docs/anti-patterns.md`'s "Do NOT make database schema decisions outside a Type C migration
   YAML" — here read as: outside a design artefact BACKEND-DEV implements from — this document IS
   that artefact, but the decision has product/backward-compatibility consequences beyond this
   design's scope). **Flagged in Open questions §1 as a BLOCKING gap** — this design specifies the
   resolution PIPELINE shape and the four error paths assuming a resolvable answer exists, but
   does not invent the missing `service_catalog` version column itself.
2. **`module_ref`/the process module catalog (PLC-01) do not exist in this codebase at all.**
   PLC-01 is `status: PENDING`, `priority: SHOULD`, in a LATER stage (15) than this batch's Stage
   16 — confirmed via `docs/requirements.yaml` and via `grep -rn "module_ref" src/` returning zero
   matches anywhere in `src/`. PIN-01 AC2 ("a `module_ref` semver range matching no published
   module version... `UnresolvedModuleRef`") is written against a catalog PLC-01 has not yet built.
   **This design specifies the resolution shape PIN-01 AC2 requires assuming PLC-01 ships first**,
   but implementing PIN-01's module-reference resolution branch is blocked on PLC-01, not merely
   deferred by choice. Flagged in Open questions §2.

**What PIN-01 CAN be implemented against today: the `variable_schema` resolution/validation
branch (AC3) and the `pin_overrides` branch (AC4), both of which have real, already-existing
infrastructure to resolve against** (`variable_schemas` table, `012_event_retention.sql`) or
require no external catalog at all (overrides are caller-supplied and validated against whichever
of the other two resolution paths they target). This design specifies all four branches in full
(so BACKEND-DEV has the complete shape once the two blocking gaps close) but marks the
service-catalog and module-catalog branches explicitly as **not implementable to their full AC
text without prerequisite work**, per the Rules in `.claude/agents/code-designer.md` ("If a
requirement is ambiguous: note it as an open question in the artefact and mark handoff PARTIAL"
— this is not ambiguity in PIN-01's own text, which is precise, but a genuine missing-dependency
gap discovered while designing against the actual current schema).

## Module purpose

At instance start, before the instance row is written (process document step 3, ahead of the
existing `InstanceStore.create()` INSERT), enumerate every versioned reference the definition
snapshot depends on — service catalog references on `SERVICE_TASK` nodes, the definition's
`variable_schema` version, and `module_ref` semver ranges on `SUB_PROCESS` nodes — resolve each
to a concrete `{kind, ref, resolved_id, version, source}` entry, validate initial variables
against the resolved schema, and apply any caller-supplied `pin_overrides`. Resolution is
all-or-nothing: any of the four failure modes below aborts the start with a structured 422 and
writes no instance row, no partial pin set, and no side effects. The resolved set itself is not
persisted by this module — PIN-02 (this batch's sibling design) specifies how the caller carries
the resolved `pinned_versions[]` array into the `INSTANCE_STARTED` append.

## Data flow diagram

```
POST /api/v1/instances  (existing route — src/api/routes/instances.zig, unmodified path,
                          new internal step inserted before InstanceStore.create()'s
                          existing Step d "Capture the definition snapshot")
        |
        v
Step 1: load + snapshot the definition (PD-08, EXISTING, unmodified — SnapshotStore.create())
        |
        v
Step 2 (PIN-01, NEW): enumerate versioned references in the just-captured snapshot.graph
        |   for each node where node_type == .SERVICE_TASK and attributes carry service_id:
        |     candidate: {kind: catalog_entry, ref: service_id}
        |   for each node where node_type == .SUB_PROCESS and attributes carry module_ref:
        |     candidate: {kind: module, ref: module_id, version_constraint}
        |   always exactly one candidate: {kind: variable_schema, ref: definition_id}
        |   zero SERVICE_TASK/SUB_PROCESS refs found -> pin set will contain ONLY the
        |     variable_schema entry (PIN-01 AC5's degenerate case)
        v
(continued below)
```

```
Step 3 (PIN-01, NEW): resolve each candidate, IN THE SAME PRE-INSTANCE-ROW PHASE PD-08's
        |              snapshot capture already runs in (no instance row exists yet;
        |              nothing to roll back if resolution fails)
        |
        |-- catalog_entry candidates -> resolveServiceCatalogRef()
        |     no active version -> UnresolvedCatalogRef (422), STOP, no instance row
        |
        |-- module candidates -> resolveModuleRef()
        |     no version satisfies version_constraint -> UnresolvedModuleRef (422), STOP
        |
        |-- variable_schema candidate -> resolveVariableSchemaVersion()
        |     always resolves (see Public interface) -> proceed to Step 4
        v
Step 4 (PIN-01, NEW): validate initial_variables against the resolved variable_schema version
        |   violation -> VariableSchemaViolation (422) listing each failing field, STOP
        v
Step 5 (PIN-01, NEW): apply pin_overrides, if supplied
        |   override names a version that does not exist -> UnresolvedPinOverride (422), STOP,
        |     writes no partial pin set
        |   override valid -> replaces the resolved entry's version, source: override
        v
Step 6 (PIN-01, NEW): sort resolved entries by (kind, ref) -> deterministic pinned_versions[]
        |   (PIN-01 AC5: byte-identical payloads across two starts of the same definition
        |    against the same catalog)
        v
returned to caller as an in-memory []PinnedVersion — PIN-02 (this batch's sibling design)
consumes this slice at the point INSTANCE_STARTED is appended, in the SAME transaction as
the instance row insert (existing InstanceStore.create() Step e). PIN-01 itself does not
write to the database.
```

## Public interface

```zig
pub const PinKind = enum { catalog_entry, variable_schema, module };
pub const PinSource = enum { resolved, override, inherited };

pub const PinnedVersion = struct {
    kind: PinKind,
    /// service_id (catalog_entry) / definition_id (variable_schema) / module_id (module).
    ref: []const u8,
    /// Catalog row id / module version id — kind-dependent, see Open questions §1/§2 for
    /// what this resolves to before service_catalog/PLC-01 gain real version identity.
    resolved_id: []const u8,
    version: []const u8,
    source: PinSource,
};

pub const ResolutionError = error{
    /// A SERVICE_TASK's service_id names no catalog entry with an active version
    /// (PIN-01 AC1). HTTP 422.
    UnresolvedCatalogRef,
    /// A module_ref semver range matches no published module version (PIN-01 AC2).
    /// HTTP 422.
    UnresolvedModuleRef,
    /// Initial variables violate the resolved variable_schema version (PIN-01 AC3).
    /// HTTP 422.
    VariableSchemaViolation,
    /// pin_overrides names a version that does not exist (PIN-01 AC4). HTTP 422.
    UnresolvedPinOverride,
    PoolExhausted,
    TransactionFailed,
};

pub const ResolutionInput = struct {
    definition_id: Uuid,
    graph: graph_mod.DefinitionGraph,   // the just-captured PD-08 snapshot's graph
    initial_variables: []const u8,      // raw JSON object bytes, already object-validated
    pin_overrides: ?[]const u8,         // raw JSON, optional caller-supplied {kind,ref,version}[]
};
```

```zig
pub const PinResolver = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) PinResolver;

    /// Runs the full pipeline (Data flow diagram Steps 2-6). Called AFTER
    /// SnapshotStore.create() succeeds and BEFORE the instance_projections
    /// INSERT — i.e. inserted into InstanceStore.create() between its
    /// existing Step d and Step e, per the process document's step ordering.
    /// Returns the ordered, deterministic pin set on success; any
    /// ResolutionError means the caller MUST NOT proceed to Step e (no
    /// instance row, no partial pin set — PIN-01 AC4's "writes no partial
    /// pin set" applies to every one of the four error variants, not only
    /// UnresolvedPinOverride's literal AC text, since none of the four is
    /// reached after any DB write in this design).
    pub fn resolve(
        self: *PinResolver,
        allocator: std.mem.Allocator,
        conn: *db.Conn,   // reuses InstanceStore.create()'s already-open connection;
                          // see Open questions §3 for why a shared connection matters
        input: ResolutionInput,
    ) ResolutionError![]PinnedVersion;
};
```

### Enumeration (Step 2) — reading references out of the snapshot graph

```zig
// For each snapshot.graph.nodes entry:
//   node.node_type == .SERVICE_TASK and node.attributes carries "service_id"
//     (the ADP-08 catalog-reference form, NOT the legacy "url" form — PIN-01's
//     body says "service catalog references on SERVICE_TASK nodes", and
//     ADP-08 already establishes that a "url"-only SERVICE_TASK has no
//     catalog reference to pin at all; only "service_id"-bearing nodes
//     produce a catalog_entry candidate)
//   node.node_type == .SUB_PROCESS and node.attributes carries "module_ref"
//     (PLC-01's proposed shape: {module_id, version_constraint} — see
//     Open questions §2; a SUB_PROCESS using the existing child_definition_id
//     form produces NO module candidate, matching PLC-01's own AC ("Legacy
//     SUB_PROCESS nodes using child_definition_id directly continue to work
//     unchanged"))
// Always exactly one variable_schema candidate: {kind: variable_schema,
//   ref: definition_id} — every definition has exactly one variable_schema
//   version to pin, regardless of how many/few per-variable-key schema rows
//   variable_schemas currently holds for it (see Open questions §4 for the
//   distinction between the two).
```

Reuses `src/definition/graph.zig`'s existing `DefinitionGraph`/`GraphNode`/`NodeType` types and
attribute-parsing conventions (`node.attributes` is a raw JSON-object string per node, already
the pattern `src/engine/service_task.zig`'s own attribute parsing and
`src/engine/instance.zig`'s `parseAssigneeFields`/`extractFormSchemaJson` helpers use) — no new
graph-parsing mechanism is introduced.

### Service catalog resolution (Step 3, catalog_entry branch) — degenerate form pending Open questions §1

```sql
-- Provisional query, valid ONLY under the "no version history, single row is
-- implicitly active" interpretation flagged in the Scoping note. If BACKEND-DEV/
-- REQ-ANALYST instead choose the "add version/status columns" path, this
-- statement changes to filter WHERE status = 'active' and bind resolved_id/
-- version from those new columns rather than synthesizing them.
SELECT service_id, updated_at
FROM service_catalog
WHERE service_id = $1
  AND (scope = 'global' OR owner_tenant_id = bpm_effective_tenant_id())
```

Zero rows -> `UnresolvedCatalogRef`, naming the node and the `service_id` reference in the error
detail (per PIN-01 AC1's exact text: "naming the node and the reference"). The `scope`/
`owner_tenant_id` filter reuses SVC-01's existing tenant-visibility rule verbatim (a service
invisible to the requesting tenant is unresolved for that tenant's instance start, the same as a
genuinely nonexistent `service_id`) — this design does not introduce a new tenant-scoping rule,
it applies SVC-01's already-RELEASED one.

### Module reference resolution (Step 3, module branch) — blocked on PLC-01

```sql
-- Provisional query against PLC-01's PROPOSED shape (module_id, version semver
-- string, owning_definition_id, status) -- PLC-01 is PENDING; this table does
-- not exist yet. Shown here so BACKEND-DEV has the exact resolution shape
-- ready the moment PLC-01 ships, per PIN-01's own See: reference to PLC-01.
SELECT module_id, version, owning_definition_id
FROM process_module_catalog
WHERE module_id = $1
  AND status = 'ACTIVE'
  AND version_satisfies(version, $2)   -- semver range match; exact predicate
                                        -- form is PLC-01's to specify, not
                                        -- re-derived here
ORDER BY version DESC
LIMIT 1
```

Zero rows -> `UnresolvedModuleRef`, naming the node, the range, AND "the versions available" (per
PIN-01 AC2's exact text — this requires a second query listing all published versions of
`module_id` regardless of range match, to populate the error detail; not shown as a separate
statement since its shape is a trivial unfiltered `SELECT version FROM process_module_catalog
WHERE module_id = $1`).

### Variable schema version resolution (Step 3/4, variable_schema branch) — implementable today

PIN-01's text says "the definition's `variable_schema` **version**" (singular) — a materially
different concept from the EXISTING `variable_schemas` table, which stores one row **per
variable key** (`UNIQUE (definition_id, variable_key)`, no version column at all — read in full
via `migrations/012_event_retention.sql`). This design does not conflate the two: PIN-01's
"variable_schema version" pin is a single logical version identifier for **the whole set** of a
definition's per-key schemas as they exist at instance-start time, not a version of any
individual key's schema. Concretely:

```sql
-- "Resolve" here means: compute a stable version identifier for the CURRENT
-- full set of variable_schemas rows for this definition_id. A content hash
-- (not a monotonic counter -- variable_schemas has no version/updated_at
-- ordering column to derive one from) makes two starts of the SAME
-- definition against the SAME variable_schemas rows produce the SAME
-- version string (PIN-01 AC5), while any row change (add/remove/edit a
-- variable_key's json_schema) changes the hash.
SELECT variable_key, json_schema
FROM variable_schemas
WHERE definition_id = $1
ORDER BY variable_key ASC   -- stable ordering feeds a stable hash
```

`resolved_id` for this pin's `PinnedVersion` is `definition_id` itself (there is no separate
schema-set row to point at); `version` is the computed content hash (see Open questions §4 for
the exact hash function — not fixed by this design). This branch ALWAYS resolves (a definition
with zero `variable_schemas` rows still has a well-defined, empty-set hash) — it can never itself
raise `UnresolvedCatalogRef`/`UnresolvedModuleRef`-shaped errors, only feed into the SEPARATE
`VariableSchemaViolation` check below.

### Variable schema validation (Step 4)

```zig
// For each variable_schemas row resolved above, if the row's variable_key is
// present in initial_variables, validate initial_variables[variable_key]
// against that row's json_schema (JSON Schema validation -- same validation
// primitive event_store/registry.zig's Registry.validatePayload() already
// uses for ES-05, reused here rather than a second JSON Schema engine).
// A required variable_key ABSENT from initial_variables is also a violation
// (see Open questions §5 -- "required" is not literally a variable_schemas
// column today; whether absence is itself a violation or merely "no
// validation performed for that key" needs REQ-ANALYST confirmation).
```

Any failing field -> `VariableSchemaViolation`, listing each failing field (PIN-01 AC3's exact
text: "listing each failing field" — plural, so the error detail is a list, not a first-failure
short-circuit).

### `pin_overrides` application (Step 5) — implementable today, independent of the two blocking gaps

```zig
// pin_overrides: [{kind, ref, version}, ...] (docs/processes/system/
// instance-version-pinning.md's Inputs table). For each override entry:
//   - kind == catalog_entry: verify `version` exists for that service_id
//     (degenerate form: today, only the row's own implicit "version" can
//     ever match -- see Open questions #1; a genuine multi-version override
//     is not expressible until service_catalog gains real version history)
//   - kind == module: verify `version` exists for that module_id in
//     process_module_catalog (blocked on PLC-01, same as Step 3's module
//     branch)
//   - kind == variable_schema: this design does not define what "a
//     different variable_schema VERSION" would even mean without a real
//     version history for that resolved hash -- flagged, not resolved,
//     in Open questions #4
//   any override target not found -> UnresolvedPinOverride, STOP, no
//   partial pin set (none of the OTHER already-resolved entries are kept
//   either -- PIN-01 AC4 says "writes no partial pin set", read here as:
//   the override validation failure aborts resolution entirely, not just
//   the one bad override)
// A valid override REPLACES the resolved entry's `.version`/`.resolved_id`
// and sets `.source = .override` on that PinnedVersion.
```

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `UnresolvedCatalogRef` | A `SERVICE_TASK` node's `service_id` names no catalog entry with an active version (PIN-01 AC1) | New `problemUnresolvedCatalogRef(detail)` constructor in `src/api/errors.zig`, `type: .../problems/unresolved-catalog-ref`, HTTP 422; `detail` names the node id and the `service_id` reference, per AC1's exact text |
| `UnresolvedModuleRef` | A `module_ref` semver range matches no published module version (PIN-01 AC2) | New `problemUnresolvedModuleRef(detail)`, `.../problems/unresolved-module-ref`, HTTP 422; `detail` names the node, the range, and the versions available |
| `VariableSchemaViolation` | Initial variables violate the resolved `variable_schema` version (PIN-01 AC3) | New `problemVariableSchemaViolation(detail)`, `.../problems/variable-schema-violation`, HTTP 422; `detail` lists each failing field |
| `UnresolvedPinOverride` | `pin_overrides` names a version that does not exist (PIN-01 AC4) | New `problemUnresolvedPinOverride(detail)`, `.../problems/unresolved-pin-override`, HTTP 422; no partial pin set is applied |
| `CatalogUnavailable` (named in the process document's SLA table, NOT in PIN-01's own AC text) | A DB error occurs during catalog resolution itself (pool exhaustion, connection loss) | This design treats it as the EXISTING `PoolExhausted`/`TransactionFailed` `ResolutionError` variants, surfaced via the existing `problemServiceUnavailable`(503)/`problemInternalError`(500) constructors already in `errors.zig` — not a new named error, since PIN-01's own AC text does not name it (only the process document's SLA table does, which is descriptive of expected platform behaviour under failure, not a new acceptance criterion this batch must implement a bespoke error for) |

All four new `problem*` constructors follow `errors.zig`'s existing pattern exactly (see
`problemPartitionMissingForWrite` for the precedent of a PAR-01-specific constructor added
alongside the generic ones) — `type` is a kebab-case slug under the same `BASE` URI, `title` is
the Title Case rendering of the slug, `status: 422` for all four (matching PIN-01's own AC text,
which specifies HTTP 422 for every one of its four failure modes).

## Dependencies

- Depends on: PD-08 (this design's resolution pipeline runs on the definition snapshot PD-08's
  `SnapshotStore.create()` already captures — PIN-01 does not re-fetch the definition graph
  independently), REPO-07/SVC-01 (`service_catalog`'s existing shape and tenant-scoping rule —
  see Scoping note for the version-column gap this design cannot close), PLC-01 (the module
  catalog PIN-01's module-reference branch resolves against — not yet built; see Scoping note),
  ADP-08 (`SERVICE_TASK`'s `service_id`/`url` coexistence rule — this design's catalog_entry
  candidate enumeration only fires for the `service_id` form, matching ADP-08's own
  precedence rule).
- Must NOT depend on: PIN-03 (execution-time `PinMissing` enforcement — reads the pin set this
  design produces but is a separate, later requirement not in this batch), PIN-04 (replay/
  sub-process inheritance — also reads PIN-02's persisted pin set, not in this batch), PIN-05
  (rebind — a POST-start mutation of the pin set, entirely out of scope here). Does NOT depend on
  ISS-0670/GH-711 (the platform-event-emission gap) — confirmed by reading PIN-01's body and
  `See:` list in full: it names PD-08, REPO-07, SVC-01, PLC-01, PIN-02, PIN-03 only, and none of
  its five acceptance criteria mention appending any `EXECUTION_*` event; PIN-01 resolves
  in-memory and returns to its caller (PIN-02), it does not append anything itself.

## Open questions

1. **BLOCKING: `service_catalog` has no version/active-version concept.** See Scoping note §1 in
   full. This design cannot decide, on its own authority, between (a) adding `version`/`status`
   columns to the already-RELEASED `service_catalog` table (a breaking reshape with
   backward-compatibility consequences for every existing `service_id`-keyed caller, including
   `src/engine/service_task.zig`'s `resolveCatalogEndpoint()`), or (b) treating each row as an
   implicit single "active version" with no version history (satisfies PIN-01's LETTER — "no
   catalog entry with an active version" trivially means "no row with that `service_id`" under
   this reading — but not clearly its SPIRIT, which reads as if genuine version history was
   intended, especially given PIN-03 AC3's "pinned catalog entry version is set to DEPRECATED
   after the instance started" — DEPRECATED is a version-level status, not a service-level one,
   and does not exist as a concept anywhere in `service_catalog` today). **Needs REQ-ANALYST/ORCH
   decision before PIN-01's catalog_entry branch can be implemented against its full AC text.**
   This design's provisional query (Public interface, Service catalog resolution) implements
   interpretation (b) as the minimum viable stopgap, clearly marked provisional.
2. **BLOCKING: PLC-01 (process module catalog) does not exist.** PIN-01 AC2's `module_ref`
   resolution has nothing to query until PLC-01 ships (`process_module_catalog` table, `module_ref`
   attribute parsing in `src/definition/graph.zig`, `SUB_PROCESS_MISSING_CHILD_DEFINITION_ID`
   validation widened per PLC-01 AC3/AC4). This design specifies the resolution query shape
   PIN-01 needs (Public interface, Module reference resolution) against PLC-01's OWN proposed
   schema (read from PLC-01's body directly), but implementing it is sequenced behind PLC-01,
   not merely deferred by this design's own choice.
3. **Shared connection vs. its own transaction.** This design's `PinResolver.resolve()` signature
   takes an already-open `*db.Conn` (reusing whichever connection `InstanceStore.create()` holds
   at the point it is called) rather than acquiring its own from the pool — because PIN-01's
   resolution reads must see a CONSISTENT snapshot of `service_catalog`/`process_module_catalog`/
   `variable_schemas` as of the same instant PD-08's definition snapshot was captured, and because
   `pin_overrides` validation failures must never leave any DB row written (no instance row exists
   yet at this point in `InstanceStore.create()`, so this connection does not strictly need to be
   inside an open transaction for PIN-01's OWN work — only PIN-02's later append does). BACKEND-DEV
   should confirm the exact call-site wiring against `InstanceStore.create()`'s real structure
   (this design read that function in full for its EXISTING steps a–f, but the insertion point for
   PIN-01's new step is described narratively here, not as a line-numbered diff).
4. **Variable schema "version" — content hash function, and whether it materially differs from
   `variable_schemas`'s existing per-key row set.** This design proposes a content hash over the
   ordered `(variable_key, json_schema)` rows (Public interface, Variable schema version
   resolution) because `variable_schemas` has no version/updated_at column to derive a version
   identifier from otherwise. The EXACT hash function (SHA-256 over a canonical JSON
   serialisation? a simpler concatenation?) is left to BACKEND-DEV — this is an implementation
   choice, not a schema/behaviour decision, PROVIDED it is deterministic and order-independent
   with respect to nothing but the row CONTENT (two definitions with identical
   `(variable_key, json_schema)` sets in different row-insertion order must hash identically,
   satisfying PIN-01 AC5's byte-identical-payload guarantee).
5. **Whether a `variable_schemas` row absent from `initial_variables` is itself a violation.**
   `variable_schemas` has no `required` column — PIN-01 AC3's "violate the resolved
   `variable_schema` version" could mean "any variable present but not matching its schema" (a
   narrower reading, cheap to implement today) or "any variable_schemas row not represented in
   initial_variables is also a violation" (implies every registered variable_key is implicitly
   required, a broader reading with real behavioural consequences for existing definitions that
   register a `variable_schemas` row for an optional field). Needs REQ-ANALYST confirmation before
   BACKEND-DEV implements the validation loop's completeness condition — this design's Public
   interface intentionally leaves this unresolved in its comment rather than picking one silently.
