# Module: prm-batch1-promotion-assertion-rerun

**Requirement IDs:** PRM-06 (MUST), PRM-07 (MUST), PRM-08 (SHOULD), PRM-09 (SHOULD)
**Run ID:** WF02-prm-batch1-20260814 (Stage 16)
**Step:** 01 (CODE-DESIGNER)

**Extends:**
- `src/definition/promotion.zig` (ENV-03 — `promoteDefinition()`)
- `src/definition/promotion_plan.zig` (PRM-01 — `computePromotionPlan()`)
- `docs/processes/system/definition-promotion.md` — steps 12–24 are this design's scope

**Process document references:**
- Step 12–16: PRM-06/07 (assertion re-run, sandbox teardown)
- Step 19–20: PRM-08 (rollback)
- Step 21–24: PRM-09 (solution pack update three-way diff)

---

## Classification rationale

Applying `templates/lego-catalog.md` selection rules:

1. **Type C?** Two new migrations are needed: `promotion_assertion_runs` (PRM-06) and three
   solution-pack tables (PRM-09). Both are Type C components of this design.

2. **Type A?** `POST /api/v1/definitions/{process_key}/rollback` (PRM-08) matches a CRUD
   endpoint shape but disqualifies from pure Type A: it executes a multi-step within-transaction
   sequence (two UPDATE statements + event append + `promotion_reviews` supersede), and requires
   the "was ever active" check against `process_definitions.status IN ('ACTIVE','SUPERSEDED')`.
   Type A codegen emits a single INSERT or UPDATE, not a coordinated multi-row transaction.

3. **Type E — yes.** The assertion re-run pipeline (PRM-06/07) is a novel multi-step
   coordinated flow (idempotency check → sandbox claim → fixture load → replay under frozen
   clock/seeded RNG/stub effects → teardown on all exit paths) with no structural analogue in
   existing code. The three-way diff (PRM-09) is a classification algorithm consuming three
   content sources per artefact with conflict-resolution state. Both are Type E.

**Final classification:** Type C × 2 (migrations only) + Type E (prose design, this document).

---

## Module purpose

Extends the promotion pipeline (PRM-01..05) with four new capabilities that gate, protect, and
reverse a production definition promotion:

1. **PRM-06** — Idempotent pre-promotion assertion re-run in an ephemeral sandbox. The sandbox
   is loaded with *only* the artifact's `fixtures[]` (never organic tenant data), runs under a
   frozen clock, a seeded RNG, and the stub effect recorder. Results are recorded in
   `promotion_assertion_runs` with `UNIQUE (tenant_id, idempotency_key)`.

2. **PRM-07** — Sandbox teardown on every exit path (normal return, assertion failure,
   infrastructure failure, panic). A teardown failure appends `PROMOTION_ASSERTION_TEARDOWN_FAILED`
   and sets `promotion_assertion_runs.status = 'teardown_failed'` but never converts a passing
   assertion run into a promotion failure.

3. **PRM-08** — Promotion rollback as a version pointer move: `POST /api/v1/definitions/
   {process_key}/rollback` re-points the active version to any version that was previously
   active in the tenant (status ∈ {'ACTIVE','SUPERSEDED'} proves prior activation). Appends
   `DEFINITION_VERSION_ROLLED_BACK`. No DDL.

4. **PRM-09** — Solution pack update via three-way comparison (base/theirs/incoming). Each
   artefact is classified as `unchanged`, `clean_update`, `local_only`, or `conflict`. A
   `conflict` artefact blocks apply until a `keep_local`, `take_incoming`, or `merged`
   resolution is recorded.

This module adds new files alongside `src/definition/promotion.zig`. It does not alter the
event store, the graph engine, tenant provisioning, or any prior migration.

---

## Dependencies

| Dependency | Kind | Notes |
|---|---|---|
| `promotion_reviews` table | DB prerequisite | Created in the PRM-04 migration batch (not this batch). `promotion_assertion_runs` carries an FK to it. `1156_prm06_promotion_assertion_runs.sql` must run after that migration. |
| `src/definition/promotion_plan.zig` | Code (read) | `PromotionPlan`, `PlanEntry`, `plan_digest` field — consumed, not modified |
| `src/effects/stub.zig` | Code (read) | `StubEffectsExecutor` — sandbox replay passes this as the effects executor |
| `src/event_store/store.zig` | Code (read) | `Store.append()` for teardown-failed event and rollback event |
| `src/config/quota_policy.zig` | Code (read) | `max_concurrent_sandboxes` — quota guard before sandbox claim |
| Ephemeral sandbox pool | Runtime | Provided by new `SandboxPool` type (this module) |

**Must NOT depend on:**
- `src/simulation/scenario_runner.zig` — the assertion replay is not a scenario run
- `src/lua/executor.zig` directly — business effects go through `StubEffectsExecutor`
- Any migration numbered ≤ 1155 — all sealed

---

## PRM-06 design — pre-promotion assertion re-run

### 1. `promotion_assertion_runs` table schema

**Migration file:** `1156_prm06_promotion_assertion_runs.sql`
**Kind:** per-tenant table (lives in tenant schema, same classification as `process_definitions`)

```
promotion_assertion_runs

  id                     UUID         PRIMARY KEY DEFAULT gen_random_uuid()
  tenant_id              UUID         NOT NULL
                                        REFERENCES tenant(id) ON DELETE CASCADE
  review_id              UUID         NOT NULL
                                        -- FK to promotion_reviews(id); see FK note below
  idempotency_key        TEXT         NOT NULL
                                        -- format: "promotion_rerun:<review_id>:<plan_digest>"
  status                 TEXT         NOT NULL
                                        CHECK (status IN (
                                          'running',
                                          'passed',
                                          'failed',
                                          'teardown_failed'
                                        ))
  sandbox_id             UUID                     -- NULL until claimed; retained for reaper
  plan_digest            TEXT         NOT NULL    -- echoed from the review row
  assertions_total       INTEGER      NOT NULL    DEFAULT 0
  assertions_passed      INTEGER      NOT NULL    DEFAULT 0
  assertions_failed      INTEGER      NOT NULL    DEFAULT 0
  failing_assertion_ids  JSONB                    -- NULL unless status = 'failed';
                                                  -- JSON array of assertion ID strings
  teardown_error         TEXT                     -- NULL unless status = 'teardown_failed';
                                                  -- operator-visible error message
  reaper_claimed_at      TIMESTAMPTZ              -- NULL until the background reaper
                                                  -- reclaims a leaked sandbox (PRM-07 AC5)
  started_at             TIMESTAMPTZ  NOT NULL    DEFAULT NOW()
  completed_at           TIMESTAMPTZ              -- NULL while running
  created_at             TIMESTAMPTZ  NOT NULL    DEFAULT NOW()

  CONSTRAINT uq_promotion_assertion_runs_idempotency
    UNIQUE (tenant_id, idempotency_key)
```

**FK note (`review_id`):** The FK `REFERENCES promotion_reviews(id)` is created
conditionally: `IF to_regclass('promotion_reviews') IS NOT NULL`. If `promotion_reviews`
does not yet exist at migration time (i.e. the PRM-04 batch has not run), the column is
still created as `UUID NOT NULL` without the FK constraint, and a `RAISE NOTICE` is emitted.
BACKEND-DEV must run the PRM-04 batch migration before this one in production. This guard
avoids a migration-time `ERROR: relation "promotion_reviews" does not exist` when applying
both batches in the same pass.

**Status lifecycle (single-column, four terminal states):**

```
running ──[assertions pass, teardown OK]──────────────────→ passed
running ──[any assertion fails, teardown OK or fail]──────→ failed
running ──[assertions pass, teardown fails]───────────────→ teardown_failed
```

`teardown_failed` with `assertions_failed = 0` permits promotion to proceed (PRM-07).
The promotion apply pipeline evaluates `assertions_failed = 0`, not `status = 'passed'`,
to decide whether to move the version pointer.

---

### 2. `applyPromotionAssertionRerun()` function signature

**New file:** `src/definition/promotion_assertion_rerun.zig`

```
pub fn applyPromotionAssertionRerun(
    allocator:    std.mem.Allocator,
    pool:         *pool_mod.Pool,
    sandbox_pool: *SandboxPool,
    tenant_id:    []const u8,    // production tenant UUID
    review_id:    []const u8,    // UUID of the promotion_reviews row
    plan_digest:  []const u8,    // hex(64) SHA-256 of the canonical plan (PRM-03)
    artifact:     PromotionArtifact,
) AssertionRerunError!AssertionRerunResult
```

Supporting types:

**PromotionArtifact** fields:

| Field | Type | Notes |
|---|---|---|
| `id` | `[]const u8` | Artefact identifier |
| `assertions` | `[]const Assertion` | Each has `id: []const u8` (used in `failing_assertion_ids`) and `payload: []const u8` (JSON assertion spec) |
| `fixtures` | `[]const FixtureRow` | Each has `table_name: []const u8` and `row_json: []const u8` |
| `rng_seed` | `u64` | Seeded RNG seed; upper 32 bits used as frozen clock source |
| `non_deterministic_fields` | `[]const []const u8` | Dot-paths stripped before assertion comparison |
| `candidate_definitions` | `[]const CandidateDefinition` | Each has `process_key`, `graph_json`, `variable_schema` (`[]const u8` each) |

**AssertionRerunResult** fields:

| Field | Type | Notes |
|---|---|---|
| `run_id` | `[]const u8` | UUID of the `promotion_assertion_runs` row |
| `status` | `RunStatus` | `enum { passed, failed, teardown_failed }` |
| `assertions_passed` | `u32` | |
| `assertions_failed` | `u32` | |
| `failing_assertion_ids` | `[]const []const u8` | Empty slice when `status != failed` |
| `sandbox_id` | `?[]const u8` | Non-null even on `teardown_failed` |

**AssertionRerunError** values:

| Error | HTTP | Notes |
|---|---|---|
| `AlreadyRecorded` | — | Idempotency hit; caller reads existing row |
| `SandboxUnavailable` | 503 | No sandbox free within 60 s (PRM-06 AC5) |
| `FixtureLoadFailed` | 422 | Fixture INSERT failed in sandbox schema |
| `PoolExhausted` | 503 | DB pool exhausted |
| `TransactionFailed` | 500 | |
| `OutOfMemory` | 500 | |

---

### 3. Sandbox fixture isolation

**New file:** `src/definition/fixture_loader.zig`

```
pub fn loadFixturesOnly(
    pool:           *pool_mod.Pool,
    sandbox_schema: []const u8,       // SET search_path TO <sandbox_schema> before each query
    fixtures:       []const FixtureRow,
) FixtureLoadError!void

pub const FixtureLoadError = error{
    InvalidTableName,     // table_name not in allowlist
    InsertFailed,
    PoolExhausted,
    OutOfMemory,
};
```

**Isolation rules:**

1. Each fixture target table is validated against a hardcoded allowlist (e.g.
   `process_definitions`, `variable_schemas`, `instances`) before any SQL is issued. A
   table_name not in the allowlist returns `FixtureLoadError.InvalidTableName`. This is the
   SQL-injection boundary — no string interpolation on table names reaches the DB.
2. Before inserting, `TRUNCATE <table> CASCADE` (schema-qualified) is issued for every
   distinct table that appears in `fixtures`. This removes any rows from prior sandbox uses.
3. Each row is inserted as:
   `INSERT INTO <table> SELECT * FROM jsonb_populate_record(NULL::<table>, $1::jsonb)`
   where `$1` is the `row_json` bytes. The table name is schema-qualified at bind time using
   the sandbox_schema, never string-interpolated.
4. If any insert fails, the function returns `FixtureLoadFailed` and the sandbox is left in an
   inconsistent state (the `defer` release from PRM-07 still fires).

---

### 4. Frozen clock and seeded RNG injection

| Component | New type | Injection point |
|---|---|---|
| Frozen clock | `FrozenClockProvider` | Replaces `std.time.milliTimestamp` in replay engine calls; returns a fixed `i64` millisecond value |
| Seeded RNG | `SeededRngProvider` | Replaces the default PRNG; wraps `std.Random.DefaultPrng.init(artifact.rng_seed)` |
| Effects executor | `StubEffectsExecutor` | `src/effects/stub.zig` — consumed as-is |

`FrozenClockProvider` derives the frozen timestamp from `artifact.rng_seed`: the upper 32 bits
of `rng_seed` are treated as a Unix epoch in seconds and multiplied by 1000 to produce
milliseconds. BACKEND-DEV may override this derivation if the artifact carries an explicit
`frozen_clock_ms` field; the injection interface (`ClockProvider`) is stable regardless (see
Open questions §1).

These three providers are passed to the replay engine as parameters — the engine itself is not
modified. The providers live in `src/definition/promotion_assertion_rerun.zig`.

---

### 5. Non-deterministic fields stripping

```
pub fn stripNonDeterministicFields(
    allocator: std.mem.Allocator,
    result_json: []const u8,
    fields: []const []const u8,   // dot-path strings, e.g. "metadata.timestamp", "id"
) ![]const u8
```

After each assertion replay, this function removes the named dot-paths from both the expected
and actual result JSON before comparison. Comparison is then byte-level on the stripped output.
Paths that do not exist in the result are silently skipped.

---

### 6. Idempotency check flow

```
Step 1:  Compute key = "promotion_rerun:" ++ review_id ++ ":" ++ plan_digest

Step 2:  INSERT INTO promotion_assertion_runs
           (tenant_id, review_id, idempotency_key, status, plan_digest, started_at)
         VALUES ($1, $2, $3, 'running', $4, NOW())
         ON CONFLICT (tenant_id, idempotency_key) DO NOTHING
         RETURNING id

Step 3:  If INSERT returned no row (conflict):
           SELECT id, status, assertions_failed, failing_assertion_ids
             FROM promotion_assertion_runs
            WHERE tenant_id = $1 AND idempotency_key = $3
           Return AssertionRerunError.AlreadyRecorded — caller reads the returned row
           and returns the cached outcome without claiming a sandbox.

Step 4:  Proceed: claim sandbox, load fixtures, replay assertions, record result.
```

---

### 7. HTTP integration point

**Handler file:** `src/api/routes/promotion_assertion.zig`
**Route:** `POST /api/v1/promotions/{review_id}/run-assertions`

The handler calls `applyPromotionAssertionRerun()` and maps the result to HTTP:

| Outcome | HTTP | Notes |
|---|---|---|
| `RunStatus.passed` or `teardown_failed` with `assertions_failed = 0` | 200 | Assertion gate passed; promotion may proceed |
| `RunStatus.failed` (`assertions_failed > 0`) | 422 | Assertion gate failed; body includes `failing_assertion_ids` |
| `AlreadyRecorded` | 200 | Returns cached outcome from `promotion_assertion_runs` |
| `SandboxUnavailable` | 503 | |
| `FixtureLoadFailed` | 422 | |
| `PoolExhausted` | 503 | |

---

## PRM-07 design — sandbox teardown on all exit paths

### 1. Where sandbox release is called

The Zig `defer` keyword is set immediately after a successful `sandbox_pool.claim()`:

```
// Pattern (Zig keywords only — not implementation code):

claim = try sandbox_pool.claim(60_000)     // 60 s timeout; returns SandboxClaim
                                           // or SandboxUnavailable on timeout

defer {
    sandbox_pool.release(claim.sandbox_id) catch |release_err| {
        // (a) append PROMOTION_ASSERTION_TEARDOWN_FAILED event
        // (b) UPDATE promotion_assertion_runs SET
        //         status = 'teardown_failed',
        //         teardown_error = <release_err message>
        //     WHERE id = run_id
    }
}

// ... fixture load, assertion replay ...
// defer fires here on: normal return, error return, panic unwind
```

The `defer` is the ONLY release path. There is no `errdefer` with different logic and no
conditional release after the assertion result. A panic in Zig unwinds defers, so this covers
the panic case.

---

### 2. `PROMOTION_ASSERTION_TEARDOWN_FAILED` event

Appended via `Store.append()` (event type pre-seeded in `event_type_registry`):

```json
{
  "run_id":    "<uuid>",
  "sandbox_id":"<uuid>",
  "error":     "<release error message>",
  "tenant_id": "<uuid>"
}
```

Event type key: `PROMOTION_ASSERTION_TEARDOWN_FAILED`

---

### 3. Status after teardown failure (does not block promotion)

| Column | Value after teardown failure | Value after clean teardown (assertions passed) |
|---|---|---|
| `promotion_assertion_runs.status` | `teardown_failed` | `passed` |
| `promotion_assertion_runs.teardown_error` | error message | NULL |
| `promotion_reviews.status` | unchanged (`approved`) | unchanged (`approved`) |
| Version pointer | unchanged (promotion CONTINUES) | unchanged (promotion CONTINUES) |

The promotion apply pipeline reads `promotion_assertion_runs.assertions_failed = 0` to decide
whether to move the version pointer. It does NOT read `status = 'passed'`. A `teardown_failed`
row with `assertions_failed = 0` is a green gate.

---

### 4. Read endpoint surfacing (PRM-07 AC3)

`GET /api/v1/promotions/{id}` response includes the assertion run state when present:

```json
{
  "assertion_run": {
    "run_id":     "<uuid>",
    "status":     "teardown_failed",
    "sandbox_id": "<uuid>",
    "teardown_error": "<message>",
    "assertions_passed": 12,
    "assertions_failed": 0,
    "failing_assertion_ids": []
  }
}
```

---

### 5. Sandbox reaper (PRM-07 AC5)

The scheduler calls a `reclaimLeakedSandboxes()` function on a configurable interval. It:

1. Queries `promotion_assertion_runs WHERE status = 'teardown_failed' AND reaper_claimed_at IS NULL`
2. For each row, attempts `sandbox_pool.release(sandbox_id)`
3. On success: `UPDATE promotion_assertion_runs SET reaper_claimed_at = NOW() WHERE id = $1`
4. On failure: logs and retries on the next interval

The `reaper_claimed_at` column (in the table schema above) prevents double-reap.

---

## PRM-08 design — promotion rollback

### 1. Rollback endpoint

**Route:** `POST /api/v1/definitions/{process_key}/rollback`
**New handler file:** `src/api/routes/definition_rollback.zig`
**New domain file:** `src/definition/rollback.zig`

Request body:
```json
{ "target_version": 42 }
```

Response (HTTP 200):
```json
{
  "definition_id":           "<uuid>",
  "version":                 42,
  "rolled_back_from_version":45,
  "superseded_review_id":    "<uuid or null>",
  "event_id":                "<uuid>"
}
```

---

### 2. `rollbackDefinitionVersion()` function signature

```
pub fn rollbackDefinitionVersion(
    allocator:      std.mem.Allocator,
    pool:           *pool_mod.Pool,
    tenant_id:      []const u8,    // production tenant UUID (from auth context)
    process_key:    []const u8,    // path parameter
    target_version: u32,
    actor_id:       []const u8,
) RollbackError!RollbackResult

pub const RollbackResult = struct {
    definition_id:             []const u8,    // UUID of the now-active version
    version:                   u32,           // = target_version
    rolled_back_from_version:  u32,
    superseded_review_id:      ?[]const u8,   // UUID of the promotion_reviews row that
                                              // applied the now-superseded version;
                                              // null if no matching review exists
    event_id:                  []const u8,    // UUID of DEFINITION_VERSION_ROLLED_BACK

    pub fn deinit(self: RollbackResult, allocator: std.mem.Allocator) void { ... }
};

pub const RollbackError = error{
    /// Caller lacks platform.admin permission. HTTP 403.
    Forbidden,
    /// No process_definitions row for (tenant_id, process_key, target_version)
    /// with status IN ('ACTIVE', 'SUPERSEDED'). HTTP 422.
    VersionNeverActive,
    /// target_version equals the current ACTIVE version — nothing to do. HTTP 422.
    AlreadyActive,
    /// No process_definitions rows for process_key in this tenant. HTTP 404.
    ProcessKeyNotFound,
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
};
```

---

### 3. Version pointer update (in a single serialisable transaction)

1. Guard: `SELECT 1 FROM role_permissions WHERE user_id=$actor_id AND permission='platform.admin'` → `Forbidden` if absent.
2. `SELECT id, version, status FROM process_definitions WHERE tenant_id=$tenant_id AND name=$process_key FOR UPDATE`; identify `current_active` (status `ACTIVE`) and `target_row` (version = target, status ∈ `{ACTIVE, SUPERSEDED}`). Guard `ProcessKeyNotFound` / `VersionNeverActive` / `AlreadyActive`.
3. `UPDATE process_definitions SET status='SUPERSEDED' WHERE id=current_active.id`; `UPDATE … SET status='ACTIVE' WHERE id=target_row.id`.
4. `Store.append(DEFINITION_VERSION_ROLLED_BACK, {process_key, from_version=current_active.version, to_version=target_version, actor_id})` → capture `event_id`.
5. `UPDATE promotion_reviews SET status='superseded', superseded_by=event_id WHERE tenant_id=$tenant_id AND def_id=current_active.id AND status IN ('applied','approved')`; zero rows acceptable. Commit → return `RollbackResult`.

**Why `status IN ('ACTIVE','SUPERSEDED')` proves prior activation:** `process_definitions.status`
follows the lifecycle `DRAFT → ACTIVE → SUPERSEDED`. A row in `SUPERSEDED` was necessarily
`ACTIVE` at some prior point. This check requires no additional history table and no event log
scan.

---

### 4. Error HTTP codes for the handler

| `RollbackError` | HTTP code | Body error code |
|---|---|---|
| `Forbidden` | 403 | `FORBIDDEN` |
| `VersionNeverActive` | 422 | `VERSION_NEVER_ACTIVE` |
| `AlreadyActive` | 422 | `ALREADY_ACTIVE` |
| `ProcessKeyNotFound` | 404 | `PROCESS_KEY_NOT_FOUND` |
| `PoolExhausted` | 503 | `SERVICE_UNAVAILABLE` |
| `TransactionFailed`, `OutOfMemory` | 500 | `INTERNAL_ERROR` |

---

## PRM-09 design — solution pack update conflict resolution

### 1. Three-way diff data structures

**New file:** `src/definition/pack_update.zig`

`ArtefactClassification` enum: `unchanged` | `clean_update` | `local_only` | `conflict` (also when base is absent — PRM-09 AC5)

`ResolutionKind` enum: `keep_local` | `take_incoming` | `merged`

**ConflictResolution** fields:

| Field | Type | Notes |
|---|---|---|
| `resolution_kind` | `ResolutionKind` | |
| `merged_content` | `?[]const u8` | Non-null only when `kind = merged` |
| `resolved_by` | `[]const u8` | Principal UUID |
| `resolved_at` | `i64` | Milliseconds since epoch |

**PackUpdateArtefactEntry** fields:

| Field | Type | Notes |
|---|---|---|
| `artefact_id` | `[]const u8` | |
| `artefact_kind` | `[]const u8` | `"process_definition"` \| `"variable_schema"` \| etc. |
| `classification` | `ArtefactClassification` | |
| `base` | `?[]const u8` | JSON-serialised base (how Vb installed it); null when `unchanged` |
| `theirs` | `?[]const u8` | JSON-serialised tenant current form; null when `unchanged` |
| `incoming` | `?[]const u8` | JSON-serialised Vn form; null when `unchanged` |
| `resolution` | `?ConflictResolution` | Non-null only when `classification = conflict` |

**PackUpdatePlan** fields:

| Field | Type | Notes |
|---|---|---|
| `pack_id` | `[]const u8` | |
| `base_pack_version` | `[]const u8` | Vb: the installed version |
| `incoming_pack_version` | `[]const u8` | Vn: the offered version |
| `artefacts` | `[]const PackUpdateArtefactEntry` | |
| `has_unresolved_conflicts` | `bool` | True iff any `conflict` entry has `resolution=null`; rejected by PRM-02 at apply time (PRM-09 AC6) |

**IncomingArtefact** fields: `artefact_id: []const u8`, `artefact_kind: []const u8`, `content: []const u8` (JSON-serialised Vn form)

---

### 2. `computePackUpdatePlan()` function signature

```
pub fn computePackUpdatePlan(
    allocator:          std.mem.Allocator,
    pool:               *pool_mod.Pool,
    tenant_id:          []const u8,
    pack_id:            []const u8,
    incoming_version:   []const u8,
    incoming_artefacts: []const IncomingArtefact,
) PackUpdateError!PackUpdatePlan

pub const PackUpdateError = error{
    /// No solution_pack_installs row for (tenant_id, pack_id). HTTP 404.
    PackNotInstalled,
    PoolExhausted,
    OutOfMemory,
};
```

---

### 3. Classification algorithm

Comparison is byte-level on canonical JSON (keys sorted ascending, no insignificant whitespace
— the same normalisation as PRM-03's `plan_digest` computation).

```
For each artefact in union(base_artefacts, incoming_artefacts, tenant_artefacts):

  base     ← solution_pack_artefact_bases.base_content WHERE install_id = $install_id
               AND artefact_id = $artefact_id
             (NULL if no install record: treat as conflict per PRM-09 AC5)

  theirs   ← current tenant artefact content (query per-tenant schema)
             (NULL if artefact has been deleted from the tenant since Vb was installed)

  incoming ← IncomingArtefact.content for this artefact_id
             (NULL if artefact was removed from Vn)

  if base == NULL:
      classification ← conflict          // PRM-09 AC5: cannot prove no modification

  else if canonical(base) == canonical(theirs) == canonical(incoming):
      classification ← unchanged

  else if canonical(base) == canonical(theirs) AND canonical(base) != canonical(incoming):
      classification ← clean_update

  else if canonical(base) == canonical(incoming) AND canonical(base) != canonical(theirs):
      classification ← local_only

  else:
      classification ← conflict          // both sides changed
```

---

### 4. `solution_pack_*` table schemas

**Migration file:** `1157_prm09_solution_pack_update.sql`
**Kind:** global tables (public schema — install records are cross-tenant infrastructure)

```
solution_pack_installs
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid()
  tenant_id        UUID        NOT NULL REFERENCES tenant(id) ON DELETE CASCADE
  pack_id          TEXT        NOT NULL
  installed_version TEXT       NOT NULL    -- Vb
  installed_at     TIMESTAMPTZ NOT NULL    DEFAULT NOW()
  installed_by     UUID        NOT NULL    -- actor UUID
  CONSTRAINT uq_solution_pack_installs_tenant_pack_version
    UNIQUE (tenant_id, pack_id, installed_version)

solution_pack_artefact_bases
  id           UUID   PRIMARY KEY DEFAULT gen_random_uuid()
  install_id   UUID   NOT NULL REFERENCES solution_pack_installs(id) ON DELETE CASCADE
  artefact_id  TEXT   NOT NULL
  artefact_kind TEXT  NOT NULL
  base_content JSONB  NOT NULL              -- exact content as installed at Vb
  CONSTRAINT uq_artefact_bases_install_artefact
    UNIQUE (install_id, artefact_id)

pack_update_resolutions
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid()
  tenant_id        UUID        NOT NULL REFERENCES tenant(id) ON DELETE CASCADE
  pack_id          TEXT        NOT NULL
  incoming_version TEXT        NOT NULL    -- Vn being offered
  artefact_id      TEXT        NOT NULL
  resolution_kind  TEXT        NOT NULL
                               CHECK (resolution_kind IN ('keep_local','take_incoming','merged'))
  merged_content   JSONB                   -- non-null only when resolution_kind = 'merged'
  resolved_by      UUID        NOT NULL
  resolved_at      TIMESTAMPTZ NOT NULL    DEFAULT NOW()
  CONSTRAINT uq_pack_update_resolution_per_artefact
    UNIQUE (tenant_id, pack_id, incoming_version, artefact_id)
```

**Base advancement on apply:** When `computePackUpdatePlan()` produces a plan and it is
applied (routed through PRM-01 as a promotion plan per process doc step 24), the migration
records are updated: for each applied artefact with `classification != local_only`, INSERT a
new `solution_pack_artefact_bases` row (against a new `solution_pack_installs` row for Vn) to
record the new base. The old install record for Vb is NOT deleted; it remains for audit.

---

## Data flow diagram

```
                        applyPromotionAssertionRerun()
                                     │
         ┌───────────────────────────┼────────────────────────────┐
         │                           │                            │
         ▼                           ▼                            ▼
  idempotency check          sandbox_pool.claim()       artifact.fixtures[]
  INSERT ... ON CONFLICT      (60s timeout)              │
         │                           │                   │
  conflict?                  SandboxClaim               loadFixturesOnly()
    │ yes                    sandbox_id,                  │
    ▼                        schema_name                  │ TRUNCATE + INSERT
  return AlreadyRecorded             │                   per FixtureRow
  (caller reads DB)          defer release()◄────────────┤
                                     │                   │
                             load candidate definitions  │
                             into sandbox schema         │
                                     │                   │
                             replay assertions           │
                             FrozenClockProvider         │
                             SeededRngProvider           │
                             StubEffectsExecutor         │
                             stripNonDeterministicFields │
                                     │                   │
                             record result in            │
                             promotion_assertion_runs    │
                                     │                   │
                             defer fires ────────────────┘
                             (always — normal/error/panic)
                                     │
                        release OK?  │
                         yes ──→ status = passed/failed
                         no  ──→ status = teardown_failed
                                 + PROMOTION_ASSERTION_TEARDOWN_FAILED event
```

```
rollbackDefinitionVersion()
         │
    permission check (platform.admin)
         │
    SELECT process_definitions FOR UPDATE
    find current ACTIVE + target row (status IN ACTIVE/SUPERSEDED)
         │
    UPDATE current → SUPERSEDED
    UPDATE target  → ACTIVE
         │
    Store.append(DEFINITION_VERSION_ROLLED_BACK)
         │
    UPDATE promotion_reviews → superseded (WHERE def_id = former_active)
         │
    COMMIT → return RollbackResult
```

---

## Error taxonomy

| Error | Req | HTTP | Description |
|---|---|---|---|
| `SandboxUnavailable` | PRM-06 AC5 | 503 | No sandbox free within 60 s |
| `FixtureLoadFailed` | PRM-06 | 422 | Fixture INSERT failed in sandbox |
| `AlreadyRecorded` | PRM-06 | — | Idempotency hit; caller returns cached outcome |
| `PROMOTION_ASSERTION_TEARDOWN_FAILED` (event) | PRM-07 | — | Teardown failed; appended; promotion continues |
| `Forbidden` | PRM-08 | 403 | No `platform.admin` permission |
| `VersionNeverActive` | PRM-08 | 422 | Version not in `{ACTIVE, SUPERSEDED}` |
| `AlreadyActive` | PRM-08 | 422 | Rollback target is already active |
| `ProcessKeyNotFound` | PRM-08 | 404 | No definitions for process_key in tenant |
| `PackNotInstalled` | PRM-09 | 404 | No `solution_pack_installs` row |
| `UnresolvedTemplateConflict` | PRM-09 AC6 | 409 | Conflict artefact lacks resolution at apply |

---

## State transitions

### `promotion_assertion_runs.status`

```
               running
              /       \
  (fail)    /           \ (pass)
           ▼             ▼
        failed      release?
                    /       \
                (ok)         (fail)
                  ▼             ▼
               passed    teardown_failed
```

Note: `failed` + teardown failure → the status stays `failed` (assertion failure takes
precedence; the teardown error is still logged in `teardown_error` column and the event is
still appended).

### `promotion_reviews.status` (PRM-06/07/08 interactions)

```
approved ──[assertions_failed > 0]──────────→ failed        (PRM-06)
approved ──[assertions_failed = 0, applied]──→ applied       (PRM-04)
applied  ──[rollback of this version]────────→ superseded    (PRM-08)
```

### `process_definitions.status` (PRM-08 rollback)

```
DRAFT ──[first activation]──→ ACTIVE
ACTIVE ──[new version promoted]──→ SUPERSEDED
SUPERSEDED ──[rollback targets this row]──→ ACTIVE
```

---

## Migration file names

| File | Requirement | Schema scope | Notes |
|---|---|---|---|
| `1156_prm06_promotion_assertion_runs.sql` | PRM-06 | Per-tenant | FK to `promotion_reviews` is conditional on `to_regclass` guard |
| `1157_prm09_solution_pack_update.sql` | PRM-09 | Global (public) | Creates `solution_pack_installs`, `solution_pack_artefact_bases`, `pack_update_resolutions` |

**Prerequisite (prior batch):** `promotion_reviews` table — created in the PRM-04 migration
batch. `1156_prm06_promotion_assertion_runs.sql` must run after that file.

No GBL-* migration files are needed: the new `promotion_assertion_runs` table is per-tenant
(tenant schema) and follows the standard per-tenant bootstrap path. The `solution_pack_*`
tables are public-schema and applied in the normal public pass.

---

## Files NOT to change

| File | Reason |
|---|---|
| `src/definition/promotion.zig` | ENV-03 — `promoteDefinition()` unchanged; apply pipeline wraps it |
| `src/definition/promotion_plan.zig` | PRM-01 — plan computation is read-only |
| `src/api/routes/promotion.zig` | ENV-03 handler — endpoint path unchanged |
| `src/api/routes/promotions.zig` | PRM-01 handler — `POST /api/v1/promotions` unchanged |
| `src/effects/stub.zig` | Consumed as-is; `StubEffectsExecutor` interface unchanged |
| `src/event_store/store.zig` | Consumed via existing `Store.append()` — no new API surface |
| Any migration numbered ≤ 1155 | All sealed |

## New files to create

| File | Purpose |
|---|---|
| `src/definition/promotion_assertion_rerun.zig` | `applyPromotionAssertionRerun()`, `PromotionArtifact`, `AssertionRerunResult`, `AssertionRerunError`, `RunStatus`, `SandboxPool` interface |
| `src/definition/sandbox_pool.zig` | `SandboxPool` type, `SandboxClaim`, `claim()`, `release()` |
| `src/definition/fixture_loader.zig` | `loadFixturesOnly()`, `FixtureRow`, `FixtureLoadError` |
| `src/definition/rollback.zig` | `rollbackDefinitionVersion()`, `RollbackResult`, `RollbackError` |
| `src/definition/pack_update.zig` | `computePackUpdatePlan()`, `PackUpdatePlan`, `ArtefactClassification`, `ConflictResolution`, etc. |
| `src/api/routes/definition_rollback.zig` | HTTP handler for `POST /api/v1/definitions/{process_key}/rollback` |
| `migrations/1156_prm06_promotion_assertion_runs.sql` | Schema for `promotion_assertion_runs` |
| `migrations/1157_prm09_solution_pack_update.sql` | Schema for `solution_pack_installs`, `solution_pack_artefact_bases`, `pack_update_resolutions` |
| `src/api/routes/promotion_assertion.zig` | HTTP handler for `POST /api/v1/promotions/{review_id}/run-assertions`; calls `applyPromotionAssertionRerun()`; maps `RunStatus.failed` → HTTP 422 |

---

## Open questions

1. **Frozen clock derivation.** This design derives the frozen clock timestamp from the upper
   32 bits of `artifact.rng_seed`. If REQ-ANALYST later specifies that the artifact carries an
   explicit `frozen_clock_ms` field, the `FrozenClockProvider` injection interface is unchanged
   but the value source changes. BACKEND-DEV should confirm with the artifact schema owner
   before implementing the clock derivation.

2. **Fixture table allowlist scope.** `loadFixturesOnly()` validates `table_name` against a
   hardcoded allowlist. If fixtures targeting entity subsystem tables (from `src/entities/`) or
   other dynamically-registered tables are required, the allowlist mechanism needs extension.
   This is within BACKEND-DEV's discretion for the initial implementation; flag as a follow-up
   if entity fixtures are needed in the first assertion re-run test suite.

3. **`SandboxPool` provisioning mechanics.** This design specifies the `claim()` / `release()`
   interface but not how sandboxes are provisioned or warmed. BACKEND-DEV should implement a
   minimal on-demand `EphemeralSandboxPool` (provision schema at claim time, drop schema at
   release) for the PRM-06 gate. The warm-pool mechanics described in EXP-702 are a separate
   future concern; the interface is stable regardless.

4. **`promotion_assertion_runs` placement.** The table is designed as per-tenant (lives in
   tenant schema). If the apply endpoint resolves `tenant_id` from the `promotion_reviews` row
   before setting the search_path, the INSERT in step 2 of the idempotency check must be issued
   with the correct tenant schema set. BACKEND-DEV must verify the search_path transition order
   in the apply handler.
