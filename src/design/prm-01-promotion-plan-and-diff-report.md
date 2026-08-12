# Module: prm-01-promotion-plan-and-diff-report

**Requirement ID:** PRM-01
**Run ID:** WF02-batch-5-20260812 (Stage 16)
**Covers:** PRM-01
**Extends:** ENV-03 (RELEASED — `src/definition/promotion.zig`'s `promoteDefinition()`,
`src/api/routes/promotion.zig`'s handler; replaces ENV-03's direct test-tenant-to-production-tenant
copy with a computed, reviewable plan, per PRM-01's own `Extends:` line)
**See (from PRM-01's own body):** PD-08 (process graph pinning — the graph-diff surface), REPO-07
(service catalog — the binding-diff surface, NOT version history), PLC-01 (module catalog —
PENDING, one of several diff dimensions named), PRM-02 (conflict pre-flight — DRAFT, next step in
the pipeline, not this design's scope), PRM-03 (plan digest — DRAFT, next step, not this design's
scope), VLD-04 (validation — DRAFT, referenced but not required by PRM-01's own AC text)

**Process document (read in full for this design):** `docs/processes/system/definition-
promotion.md` — steps 1–3 are this design's scope (step 4 onward is PRM-02/PRM-03/PRM-04, not this
batch).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C?** `promotion_reviews` (named in PRM-01 AC1: "creates no `promotion_reviews` row") does
   not exist yet — confirmed via `grep -rn "promotion_reviews" migrations/` (zero matches) and via
   the process document's own step 6, which is explicitly PRM-04's scope, not PRM-01's ("Insert into
   `promotion_reviews`... Requirement: PRM-04"). PRM-01's OWN AC text never describes writing that
   row — every PRM-01 AC either asserts a row is NOT created (AC1, AC3) or describes plan
   COMPUTATION, which precedes the insert entirely (process document step 2–3, vs. the insert at
   step 6). **This design therefore does NOT include a `promotion_reviews` migration** — the table
   belongs to PRM-04 (not this batch), which is the requirement that actually inserts into it. Flagged
   explicitly in Open questions §1 so BACKEND-DEV does not read PRM-01 AC1's literal mention of the
   table name as an instruction to create it here. Rule 1 does not match for what PRM-01 itself must
   ship.
2. **Type A?** `POST /api/v1/promotions` is a new HTTP route. Disqualified from Type A by the
   catalog's own carve-out: the handler must (a) check `promotion.submit` permission, (b) validate
   `source_tenant_id` is not itself a production tenant (AC4), (c) compute a MULTI-DIMENSION diff
   (graph, `variable_schema`, service-catalog bindings, `module_ref`, permission rules — five
   distinct diff surfaces per PRM-01's own body text), and (d) classify the plan as empty vs.
   non-empty before deciding the response shape (AC2 vs. AC3) — a multi-source computation
   coordinating several read paths before a single response, structurally the same shape PIN-01's
   design used to justify ITS OWN Type E classification ("a multi-source resolution pipeline...
   Rule 2 does not match"). Rule 2 does not match.
3. **Type D / Type B?** No React Flow node, no admin list page. Neither matches.
4. **Type E — yes.** A structurally novel, multi-source diff/plan computation invoked from a new
   endpoint, with a byte-stable-enough-to-digest output shape (this design's plan entries feed
   PRM-03's `plan_digest`, a later requirement, but PRM-01's OWN AC text already requires
   `{type, id, change_kind, before, after}` per entry — a specific, non-trivial output contract).
   Per `templates/lego-catalog.md`: "When in doubt, prefer Type E."

No fenced code block below exceeds the linter's 40-line cap.

## Scoping note — read this before implementing

**PRM-01's own AC bullets are fully implementable today, WITHOUT hitting the ISS-0672/GH-306
wall — verified by reading each AC bullet's literal text against what exists, not assumed from
PRM-01's body prose (which names REPO-07/PLC-01 as diff DIMENSIONS, not as gating dependencies for
the ACs that must pass).**

- **AC1** (caller without `promotion.submit` -> 403, no `promotion_reviews` row) needs only a
  permission check — `src/definition/promotion.zig`'s existing `promoteDefinition()` already has a
  precedent role-check pattern (`MissingDesignerRoleOnTest`/`MissingDesignerRoleOnProd`, reading
  `user_roles`/`roles` tables) this design reuses for the `promotion.submit` permission instead.
  "Creates no `promotion_reviews` row" is trivially true under THIS design's scope, since (per
  Classification rationale §1) PRM-01 does not write that table at all — the assertion holds
  vacuously for this batch and remains true once PRM-04 ships the insert, PROVIDED PRM-04's insert
  is correctly gated behind the SAME permission check this design specifies (a sequencing note for
  PRM-04's own future design, not something PRM-01 must itself guarantee beyond returning 403
  before touching the target tenant at all).
- **AC2** (target holds no version of `process_key` -> every entry `change_kind = added`, plan
  accepted) needs only: query the target tenant's `process_definitions` for `process_key`, find
  zero rows, and mark every diffed graph/variable-schema/binding/permission entry `added`. No
  catalog version history needed — "target has no version" is a row-count check against
  `process_definitions`, a table that already exists and is already queried this way (see
  `promotion.zig`'s existing Step 5, `SELECT COALESCE(MAX(version::int), 0)...`).
- **AC3** (source == target after canonicalisation -> `EmptyPromotionPlan`, 422, no review row)
  needs only: compute the diff (this design's Diff computation section below) and check whether
  every dimension produced zero entries. No catalog version history needed — this is a structural
  comparison of already-fetched graph JSON / `variable_schemas` rows / service-catalog BINDING
  references (which service_id a node names, not which VERSION of that service — see Diff
  computation, Service catalog bindings sub-section, for why this distinction matters and is
  honoured).
- **AC4** (`source_tenant_id` names a production tenant -> `InvalidPromotionSource`, 422) reuses
  `promotion.zig`'s EXISTING `tenant_type` check (`NotATestTenant`, read in full above) — this
  design's `InvalidPromotionSource` is the SAME check, renamed/reframed for PRM-01's own AC text
  and its NEW `POST /api/v1/promotions` route (ENV-03's OLD route,
  `POST /api/v1/tenants/:test_tenant_id/promote/:definition_name`, already enforces this exact
  rule via `NotATestTenant` — this design's version is the equivalent check on the new route's
  request-body-supplied `source_tenant_id` rather than a path parameter).
- **AC5** ("the plan is computed before any transaction that writes to the target tenant is
  opened") is an ORDERING guarantee, satisfied by this design's Data flow diagram (plan computation
  is entirely read-only against BOTH tenants; nothing opens a write transaction until AFTER the
  plan is returned/reviewed, which is PRM-04's scope, not PRM-01's) — a TEST-DESIGNER obligation
  (assert no `BEGIN`/write-intent query fires during plan computation) as much as a design one, same
  shape as PIN-01 AC5/PIN-03 AC5/PIN-04 AC5/PIN-05 AC5's negative-assertion pattern across this
  whole batch.

**Where PRM-01's body text (not its AC bullets) mentions PLC-01/REPO-07, this design honours the
distinction the AC text itself draws:** PRM-01's body says the plan diffs "service catalog
BINDINGS (REPO-07) on SERVICE_TASK nodes" and "`module_ref` RESOLUTIONS (PLC-01) on SUB_PROCESS
nodes" — bindings and resolutions are not the same operation PIN-01 AC1/AC2 needed (resolving a
reference to a concrete active VERSION). A binding diff only needs to know WHICH `service_id` a
node names before vs. after (a string comparison against graph JSON, no catalog query at all); a
resolutions diff for `module_ref` WOULD need PLC-01 if it were required to resolve semver ranges to
concrete versions the way PIN-01 AC2 does — but PRM-01's own AC bullets (AC1–AC5) never exercise
this dimension: none of the five ACs is written against a `module_ref`-bearing definition or
asserts anything about module diff output specifically. **This design implements the `module_ref`
diff dimension at the SAME structural level as the service-catalog dimension — a raw string/JSON
comparison of the `module_ref` field's before/after VALUE on each `SUB_PROCESS` node (i.e., "did
the semver range string change"), not a resolution of that range against PLC-01's catalog** — this
satisfies PRM-01's body text ("diffs... `module_ref` resolutions... on SUB_PROCESS nodes" read as
"diffs what module_ref each node names," the same non-committal reading PIN-01's design used for
`service_catalog`'s degenerate stopgap) without requiring PLC-01 to exist. **Flagged explicitly in
Open questions §2** as the one place this design's reading could be contested: if REQ-ANALYST later
clarifies "resolutions" must mean fully-resolved concrete module versions (not raw
range-string comparison), THAT reading would hit the PLC-01 wall and this design's `module_ref`
diff sub-section would need revision — but PRM-01's own AC bullets do not force that reading today,
so this design does not treat PRM-01 as PARTIAL on that basis, unlike PIN-01's AC1/AC2 which are
unambiguously about resolved catalog identity.

## Module purpose

Compute a read-only "promotion plan" before any write to a target tenant: diff the source tenant's
definition version against the target tenant's active version across the process graph, the
`variable_schema`, service-catalog bindings on `SERVICE_TASK` nodes, `module_ref` VALUES (not
resolutions — see Scoping note) on `SUB_PROCESS` nodes, and permission rules, producing one plan
entry per changed unit as `{type, id, change_kind, before, after}` with `change_kind` in `added`,
`modified`, `removed`. Render the plan both as JSON and as a human-readable change list. Exposed
via `POST /api/v1/promotions`, gated on `promotion.submit`. This design covers computation and the
endpoint's happy/error paths through "plan computed, no review row written yet" — persisting the
review row (`promotion_reviews`) is PRM-04's scope, not this design's, per Classification rationale
§1.

## Data flow diagram

```
POST /api/v1/promotions  (NEW route, src/api/routes/promotion.zig extended
                           or a new sibling file -- see Open questions §3)
        |
        v
Step 1 (PRM-01, NEW): permission check -- caller holds promotion.submit?
        |   reuses promotion.zig's EXISTING role-check query SHAPE
        |   (user_roles JOIN roles), against the promotion.submit permission
        |   instead of PROCESS_DESIGNER -> 403, no read of either tenant's
        |   definitions occurs (AC1)
        v
Step 2 (PRM-01, NEW): source_tenant_id validation -- tenant_type == 'test'?
        |   reuses promotion.zig's EXISTING NotATestTenant check SHAPE,
        |   reframed as InvalidPromotionSource for this route's AC4 wording
        |   fails -> 422 InvalidPromotionSource, STOP (AC4)
        v
Step 3 (PRM-01, NEW): fetch source definition (source_tenant_id, process_key,
        |   ACTIVE version -- reuses promotion.zig's EXISTING
        |   "SELECT id::text FROM process_definitions WHERE name = $1 AND
        |   status = 'ACTIVE'" query pattern verbatim, against source_tenant_id's schema)
        v
Step 4 (PRM-01, NEW): fetch target definition (target_tenant_id, SAME
        |   process_key, ACTIVE version) -- zero rows is NOT an error here
        |   (AC2: "target holds no version" is a valid, expected case)
        v
(continued below)
```

```
Step 5 (PRM-01, NEW): compute the diff across five dimensions (Diff
        |   computation section below) -- entirely READ-ONLY against both
        |   tenants' schemas, no transaction opened on either (AC5)
        |   target had zero rows at Step 4 -> every entry forced change_kind
        |     = added (AC2), diff computation still runs (so the PLAN's
        |     entries are populated, not empty) but with an implicit "target
        |     side is the empty set" baseline
        v
Step 6 (PRM-01, NEW): canonicalise + compare -- zero plan entries across all
        |   five dimensions? -> 422 EmptyPromotionPlan, STOP, no review row
        |   (AC3); non-empty -> proceed
        v
Step 7 (PRM-01, NEW): render plan as JSON array of {type, id, change_kind,
        |   before, after} PLUS a human-readable change-list string (PRM-01's
        |   body text, "rendered as a human-readable change list alongside
        |   its JSON form")
        v
returned to caller: 200 (or whatever status PRM-02/PRM-03/PRM-04 -- not this
batch -- eventually wrap this in) with the plan; NO promotion_reviews row is
written by this design (Classification rationale §1) -- persisting the plan
for later approval is PRM-04's scope
```

## Public interface

```zig
pub const ChangeKind = enum { added, modified, removed };

pub const PlanEntryType = enum {
    graph_node, // a process-graph node (PD-08)
    graph_edge, // a process-graph edge (PD-08)
    variable_schema, // a variable_schemas row
    service_binding, // a SERVICE_TASK node's service_id reference (REPO-07 binding, not version)
    module_ref, // a SUB_PROCESS node's module_ref VALUE (not resolution -- see Scoping note)
    permission_rule, // a role/permission grant tied to the definition
};

pub const PlanEntry = struct {
    type: PlanEntryType,
    id: []const u8, // node id / edge id / variable_key / role name, per `type`
    change_kind: ChangeKind,
    before: ?[]const u8, // JSON-serialised prior state; null for change_kind == added
    after: ?[]const u8, // JSON-serialised new state; null for change_kind == removed
};

pub const PromotionPlan = struct {
    entries: []const PlanEntry,
    human_readable: []const u8, // one line per entry, per PRM-01's body text
};
```

```zig
pub const PlanError = error{
    /// Caller lacks promotion.submit (PRM-01 AC1). HTTP 403.
    Forbidden,
    /// source_tenant_id names a production tenant (PRM-01 AC4). HTTP 422.
    InvalidPromotionSource,
    /// Every diff dimension produced zero entries (PRM-01 AC3). HTTP 422.
    EmptyPromotionPlan,
    /// source_tenant_id or process_key names nothing in the source tenant.
    /// HTTP 404. (Not explicitly named in PRM-01's own AC bullets, but
    /// required by AC2's contrast -- AC2 is specifically about the TARGET
    /// having no version; the SOURCE having no ACTIVE version is a distinct,
    /// necessary precondition failure, mirroring ENV-03's own
    /// ActiveDefinitionNotFound.)
    SourceDefinitionNotFound,
    PoolExhausted,
    TransactionFailed,
};

/// Computes the plan (Data flow Steps 1-7). Read-only against both tenants;
/// opens no write transaction (AC5). Returns PlanError.EmptyPromotionPlan
/// rather than a PromotionPlan with zero entries, so callers cannot
/// accidentally treat "nothing to promote" as success.
pub fn computePromotionPlan(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    actor_id: []const u8,
    source_tenant_id: []const u8,
    target_tenant_id: []const u8,
    process_key: []const u8,
) PlanError!PromotionPlan;
```

### Diff computation — five dimensions, all against already-existing data

```zig
// graph_node / graph_edge: compare source_def.graph.nodes/.edges against
//   target_def.graph.nodes/.edges by id -- id present only in source ->
//   added; only in target -> removed; present in both with different
//   attributes/label/condition -> modified. Reuses graph_mod.DefinitionGraph
//   (PD-08, EXISTING) -- no new graph representation.
// variable_schema: compare source/target variable_schemas rows by
//   variable_key (EXISTING table, migrations/012_event_retention.sql) --
//   same added/modified/removed logic by key presence + json_schema equality.
// service_binding: for each SERVICE_TASK node, compare its service_id
//   ATTRIBUTE VALUE (a string) before vs. after -- NOT a catalog lookup, a
//   graph-attribute diff (see Scoping note: this is the "binding," not the
//   "version").
// module_ref: for each SUB_PROCESS node, compare its module_ref ATTRIBUTE
//   VALUE (the semver-range string) before vs. after -- same non-resolving
//   treatment as service_binding (see Scoping note, Open questions §2).
// permission_rule: compare the definition's associated role/permission grants
//   (whichever existing table associates a process_definition with required
//   roles -- BACKEND-DEV to confirm the exact table; PRM-01's own AC text
//   does not specify the grant model's shape beyond "permission rules" as a
//   named diff dimension) by role-name presence.
```

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `Forbidden` | Caller lacks `promotion.submit` (PRM-01 AC1) | New `problemForbidden(detail)` reuse (existing constructor, no new one needed — matches `errors.zig`'s existing generic 403), HTTP 403; no `promotion_reviews` row created |
| `InvalidPromotionSource` | `source_tenant_id` names a production tenant (PRM-01 AC4) | New `problemInvalidPromotionSource(detail)` constructor, `.../problems/invalid-promotion-source`, HTTP 422, following PIN-01's `problem*` pattern |
| `EmptyPromotionPlan` | Source and target are identical after canonicalisation (PRM-01 AC3) | New `problemEmptyPromotionPlan(detail)` constructor, `.../problems/empty-promotion-plan`, HTTP 422; no review row created |
| `SourceDefinitionNotFound` | `source_tenant_id`/`process_key` names no ACTIVE source definition | Existing `problemNotFound(detail)`, HTTP 404 (mirrors ENV-03's `ActiveDefinitionNotFound`) |

## Dependencies

- Depends on: ENV-03 (RELEASED — `promoteDefinition()`'s role-check and tenant-lookup query SHAPES,
  reused verbatim for this design's Step 1/2/3; this design does NOT call `promoteDefinition()`
  itself, since ENV-03's function performs the WRITE this design must precede, not the diff), PD-08
  (`DefinitionGraph`/`graph.zig` types, reused for graph diffing), REPO-07/`variable_schemas`
  (EXISTING tables, reused for their respective diff dimensions).
- Must NOT depend on: PLC-01 (see Scoping note — `module_ref` is diffed as a raw value, not
  resolved), PRM-02 (conflict pre-flight — a LATER pipeline step that consumes this design's plan
  output but is not itself part of plan COMPUTATION), PRM-03 (plan digest — consumes this design's
  canonicalised plan but digest computation is its own requirement, not duplicated here), PRM-04
  (`promotion_reviews` persistence — explicitly NOT this design's scope, see Classification
  rationale §1), ISS-0672/GH-306 (`service_catalog` version/status columns — this design's
  service-catalog diff dimension never queries a version/status concept, only the binding's
  `service_id` string value).

## Open questions

1. **`promotion_reviews` does not exist yet — confirm PRM-01 itself must not create it.** This
   design's Classification rationale §1 reasons that PRM-01's own AC bullets never describe writing
   that table (only asserting it is NOT written on failure paths) and that the process document's
   own step numbering assigns the INSERT to PRM-04. This is this design's own close reading, not a
   REQ-ANALYST-confirmed fact — if REQ-ANALYST disagrees and PRM-01 is meant to include a minimal
   `promotion_reviews` row write (e.g., because BACKEND-DEV cannot ship `POST /api/v1/promotions`
   usefully without SOME persistence, even ahead of PRM-04's full review-state-machine), that
   reverses this design's scope boundary and pulls a Type C migration into PRM-01's own artefact
   set. Flagged here rather than silently assumed either way.
2. **Whether `module_ref` diffing must resolve against PLC-01 or may remain a raw-value
   comparison.** See Scoping note's full reasoning. This design's position (raw-value comparison
   suffices for PRM-01's own AC text) is the SAME kind of interpretive choice PIN-01's Open
   questions §1 flagged for `service_catalog`'s degenerate reading — stated as this design's chosen
   interpretation, not silently picked. If PRM-02's conflict-detection logic (a later requirement,
   not this batch) turns out to REQUIRE resolved module identity to detect a genuine conflict
   (e.g., two module versions that satisfy the same range string but are semantically different),
   that would retroactively push PLC-01 onto PRM-01's own critical path — not visible from PRM-01's
   AC text alone, flagged for REQ-ANALYST awareness when PRM-02 is designed.
3. **New route file vs. extending `src/api/routes/promotion.zig`.** ENV-03's existing route file
   handles `POST /api/v1/tenants/:test_tenant_id/promote/:definition_name` — a DIFFERENT URL shape
   (path-parameter-based) from PRM-01's `POST /api/v1/promotions` (a body-based request, per the
   process document's step 1 "with source, target, process_key, artifact_id"). This design does not
   mandate whether BACKEND-DEV extends the existing file with a second handler function or creates
   a sibling `src/api/routes/promotions.zig` (plural) — both satisfy PRM-01's AC text identically;
   a plural sibling file may read more clearly given the two routes' shapes differ enough that
   sharing a file mostly means sharing imports, not logic (this design's `computePromotionPlan()`
   lives in `src/definition/`, not in the route file either way, matching `promotion.zig`'s own
   existing route/logic separation).
4. **`artifact_id` (named in the process document's Inputs table and step 1, "carries
   `assertions[]`, `fixtures[]`, `rng_seed`") is NOT in PRM-01's own AC bullets at all.** The
   process document's step 1 lists `artifact_id` as a `POST /api/v1/promotions` input, but PRM-01's
   five AC bullets never reference it — assertions/fixtures/rng_seed are PRM-06's concern (sandbox
   assertion re-run), a much later pipeline step. This design's `computePromotionPlan()` signature
   therefore does NOT take an `artifact_id` parameter — the plan computation this design covers is
   independent of whatever artifact will later be replayed against it. Flagged so BACKEND-DEV does
   not read the process document's Inputs table as requiring `artifact_id` handling inside THIS
   requirement's own scope.
