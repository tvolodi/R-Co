# Module: AGT-05, AGT-06, AGT-07 — RNG Seed Identity, Dual-Sweep Retention, Deprecated Field Rejection

## Module Purpose

This design covers three Stage 17 agent-pipeline enhancements that extend the foundation
laid by AGT-01–04:

- **AGT-05** binds run determinism into task-spec identity by requiring a non-zero `rng_seed`
  and including it in the canonical JSON before `spec_hash` is computed.
- **AGT-06** governs how staging artifacts are aged out: a dual-sweep retention job removes
  unreviewed artifacts after a short TTL and verified artifacts only once their version-pair
  pin has been collected and a long TTL has elapsed.
- **AGT-07** prevents stale submitters from silently using the deprecated `ignore_fields`
  envelope field; the check fires before payload schema validation and returns a distinct 400
  error code.

---

## Classification (Lego Catalog)

All three requirements are **Type E** (novel / cross-cutting):

- **AGT-05**: The zero-seed guard and the canonical-JSON inclusion of `rng_seed` are already
  implemented in `src/api/routes/agent_task_specs.zig`; this design documents and confirms
  the existing behaviour. No DB schema changes are needed (`rng_seed BIGINT NOT NULL` column
  already exists on `task_specs` from migration 1170).
- **AGT-06**: Requires a new migration (two schema additions), a new transactional side-effect
  on the verified-state transition path in `agent_artifacts.zig`, and two new Zig retention
  functions wired into the scheduler. This crosses handler, migration, and scheduler concerns
  in a way that does not fit Type A–D.
- **AGT-07**: Requires a new pre-validation check inside an existing handler function at a
  specific point in the processing pipeline (after body parse, before kind validation),
  returning a non-standard 400 code. The ordering constraint and code-level insertion point
  cannot be expressed in a parameter file.

No Type A–D parameter files are produced for this batch.

---

## AGT-05 — Non-zero RNG Seed Folded into Spec Identity

### Call Site

**File:** `src/api/routes/agent_task_specs.zig`  
**Function:** `handleSubmitTaskSpec`

The zero-seed guard and spec_hash inclusion are already present. The design documents the
existing behaviour as the canonical interface:

```
// Step 1 — Orchestrator gate (SBX-02)
// Step 2 — Parse body JSON
// Step 3 — Extract rng_seed; reject if 0 or absent → HTTP 400 rng_seed_zero
//           (handles .integer and .number_string variants)
// Step 4 — Build merged JSON: copy all body keys except orchestrator_principal,
//           then append server-authoritative orchestrator_principal
//           (rng_seed is present in the body and therefore included here)
// Step 5 — RFC 8785 canonicalise merged JSON → sha256Hex → spec_hash
// Step 6 — INSERT task_specs (spec_hash, spec_body, orchestrator_principal, rng_seed)
//           ON CONFLICT (spec_hash) DO NOTHING RETURNING task_spec_id
```

### rng_seed in Canonical JSON

Because `rng_seed` is a field in the submitted body object, it is copied into `merged_json`
in step 4 (the key-copying loop excludes only `orchestrator_principal`). After canonical
serialisation the `rng_seed` integer is serialised as a bare decimal integer (no exponent
form), making its contribution to `spec_hash` stable across submitters.

Two specs differing only in `rng_seed` therefore produce different `spec_hash` values and
are stored as separate rows.

### Error Taxonomy

| Condition | HTTP | Code |
|---|---|---|
| `rng_seed` absent from body | 400 | `rng_seed_zero` |
| `rng_seed` present with value 0 | 400 | `rng_seed_zero` |
| `rng_seed` present with non-zero value | proceeds | — |

### Acceptance Criteria Notes

AC4 is satisfied by the existing spec_hash guard in handleArtifactSubmit (AGT-04) — when an artifact is submitted with a spec_hash computed without rng_seed, the stored spec_hash (which includes rng_seed) differs, so the guard returns HTTP 409 spec_hash_mismatch.

AC5 (replay uses stored rng_seed) is a SIM-01 concern and out of scope for this implementation unit. task_specs.rng_seed persists the seed for replay; the replay module (SIM-01) is responsible for reading it.

### DB Schema

No changes. `task_specs.rng_seed BIGINT NOT NULL` already exists (migration 1170).

### Dependencies

- `src/api/routes/agent_task_specs.zig` — implementation site (no change needed)
- `migrations/1170_sbx_task_specs_agent_sandboxes.sql` — `task_specs.rng_seed` column

---

## AGT-06 — Dual-Sweep Artifact Retention

### Data Flow Diagram

```
Verified-state transition (handleArtifactVerify)
  └─ BEGIN
       UPDATE staging.agent_artifacts SET status='verified', verified_at=NOW() WHERE ...
       INSERT INTO staging.artifact_version_pins (artifact_id, task_spec_version,
                                                   process_definition_version)
     COMMIT

Daily scheduler at 03:00 UTC
  ├─ runArtifactRetentionSweep1(pool, review_ttl_days)
  │    DELETE FROM staging.agent_artifacts
  │    WHERE status = 'needs_review'
  │      AND created_at < NOW() - INTERVAL '$1 days'
  └─ runArtifactRetentionSweep2(pool, verified_ttl_days)
       DELETE FROM staging.agent_artifacts a
       USING staging.artifact_version_pins p
       WHERE a.artifact_id = p.artifact_id
         AND p.collected_at IS NOT NULL
         AND a.verified_at < NOW() - INTERVAL '$1 days'
```

### Database Schema

**Migration:** `migrations/1173_agt06_artifact_retention.sql`  
**Scope:** `staging_only`

```sql
-- Add lifecycle columns to existing artifact table
ALTER TABLE staging.agent_artifacts
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'needs_review'
      CHECK (status IN ('needs_review', 'verified')),
  ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ NULL;

CREATE INDEX IF NOT EXISTS idx_aa_status_created
    ON staging.agent_artifacts (status, created_at);

-- Version-pair pin table written atomically on verified transition
CREATE TABLE IF NOT EXISTS staging.artifact_version_pins (
    pin_id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_id                 UUID        NOT NULL
                                             REFERENCES staging.agent_artifacts(artifact_id)
                                             ON DELETE CASCADE,
    task_spec_version           TEXT        NOT NULL,
    process_definition_version  TEXT        NOT NULL,
    collected_at                TIMESTAMPTZ NULL,   -- NULL = not yet collected
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_avp_artifact
    ON staging.artifact_version_pins (artifact_id);
CREATE INDEX IF NOT EXISTS idx_avp_collected
    ON staging.artifact_version_pins (collected_at)
    WHERE collected_at IS NOT NULL;
```

### Public Interface

**File:** `src/api/routes/agent_artifacts.zig`  
**New helper on verified transition (call site TBD by BACKEND-DEV):**

```zig
// Called inside a DB transaction when an artifact transitions to 'verified'.
fn writeArtifactVersionPin(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    artifact_id: []const u8,
    task_spec_version: []const u8,
    process_definition_version: []const u8,
) error{OutOfMemory, DbError}!void;
```

The INSERT and the UPDATE to `status='verified'` MUST commit in the same transaction (DB-03).
If either fails the transaction rolls back and the artifact remains `needs_review`.

**File:** `src/scheduler/artifact_retention.zig` (new file)

```zig
/// Sweep 1: delete needs_review artifacts older than review_ttl_days.
pub fn runArtifactRetentionSweep1(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    review_ttl_days: u32,
) !u64;  // returns rows deleted

/// Sweep 2: delete verified artifacts whose pin is collected
///          AND verified_at > verified_ttl_days ago.
pub fn runArtifactRetentionSweep2(
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    verified_ttl_days: u32,
) !u64;  // rows deleted
```

Both functions are idempotent: a second call with the same clock returns 0 rows deleted.

**Scheduler wiring** (`src/scheduler/scheduler.zig` or config equivalent):

```
daily at 03:00 UTC:
  1. runArtifactRetentionSweep1(pool, env("BPM_STAGING_REVIEW_TTL_DAYS", 30))
  2. runArtifactRetentionSweep2(pool, env("BPM_STAGING_VERIFIED_TTL_DAYS", 365))
```

Sweep 1 runs before sweep 2 so that `needs_review` rows aged out in sweep 1 never enter
the sweep-2 predicate.

### Configuration

| Variable | Default | Semantics |
|---|---|---|
| `BPM_STAGING_REVIEW_TTL_DAYS` | 30 | Age in days before a `needs_review` artifact is deleted |
| `BPM_STAGING_VERIFIED_TTL_DAYS` | 365 | Age in days (from `verified_at`) before a verified artifact with a collected pin is deleted |

### Error Taxonomy

No new HTTP errors. The retention sweeps are internal; failures are logged at ERROR level
and retried on the next daily run.

### State Transitions

```
created → needs_review (default on INSERT)
needs_review → verified   (POST /verify endpoint; writes artifact_version_pins atomically)
needs_review → [deleted]  (sweep 1 after review_ttl_days)
verified     → [deleted]  (sweep 2 after pin collected AND verified_ttl_days elapsed)
```

### Dependencies

- `migrations/1173_agt06_artifact_retention.sql` — schema additions
- `src/api/routes/agent_artifacts.zig` — verified-transition side effect
- `src/scheduler/artifact_retention.zig` — sweep implementations (new file)
- `src/scheduler/scheduler.zig` — daily registration
- `migrations/1171_agt01_03_agent_artifacts.sql` — base table that migration 1172 extends

### Open Questions

None. Status column default (`needs_review`) and pin table FK cascade (`ON DELETE CASCADE`)
are sufficient to make the sweeps safe to re-run.

---

## AGT-07 — Deprecated Envelope Field Names Rejected

### Call Site

**File:** `src/api/routes/agent_artifacts.zig`  
**Function:** `handleArtifactSubmit`

The deprecated-field check is inserted as a new step [2.5] between the existing
body-parse step [2] and the kind-validation step [3]. This ordering ensures:

1. The environment gate (step 1) still fires first on production deployments.
2. A stale submitter using `ignore_fields` on a production deployment still gets HTTP 403
   (env gate fires before the body parse, so step [2.5] is never reached).
3. The check fires before schema validation (step [5]), so a submitter using a deprecated
   field receives HTTP 400 rather than HTTP 422.

```
// Existing step [1]: production_mode guard → 403 wrong_environment
// Existing step [2]: parse body JSON → root_obj
// NEW step [2.5]: deprecated field check
//   if root_obj contains "ignore_fields" → HTTP 400 deprecated_field:ignore_fields
// Existing step [3]: kind extraction and enum validation
// ... (remaining steps unchanged)
```

### New Helper Function

```zig
fn deprecatedField400(
    allocator: std.mem.Allocator,
    deprecated: []const u8,
    replacement: []const u8,
) HandlerResult {
    const body = std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"deprecated_field:{s}\",\"replacement\":\"{s}\",\"status\":400}}",
        .{ deprecated, replacement },
    ) catch "{\"error\":\"deprecated_field\",\"status\":400}";
    return .{ .status_code = 400, .body = body };
}
```

### Deprecated Name Registry

The check is a simple key presence test on `root_obj`:

| Deprecated key | Replacement | Error code |
|---|---|---|
| `ignore_fields` | `non_deterministic_fields` | `deprecated_field:ignore_fields` |

When a future rename occurs, the prior name is added to this table (not to an alias map),
and a new `deprecated_field:<name>` error code is introduced.

### Error Taxonomy

| Condition | HTTP | Code | Body |
|---|---|---|---|
| `ignore_fields` key present (any value) | 400 | `deprecated_field:ignore_fields` | `{"error":"deprecated_field:ignore_fields","replacement":"non_deterministic_fields","status":400}` |
| Both `ignore_fields` and `non_deterministic_fields` present | 400 | `deprecated_field:ignore_fields` | Same as above |
| `ignore_fields` with empty array | 400 | `deprecated_field:ignore_fields` | Same as above |

The presence of `non_deterministic_fields` does NOT excuse `ignore_fields`. The check is
purely presence-based on the deprecated key.

### Dependencies

- `src/api/routes/agent_artifacts.zig` — implementation site (insert step [2.5])

---

## Cross-Cutting Notes

### Requirement-to-Artefact Map

| Req | Type | Artefacts |
|---|---|---|
| AGT-05 | E (existing code documented) | this design doc |
| AGT-06 | E | `migrations/1173_agt06_artifact_retention.sql`, `src/scheduler/artifact_retention.zig`, changes to `src/api/routes/agent_artifacts.zig` and `src/scheduler/scheduler.zig` |
| AGT-07 | E | change to `src/api/routes/agent_artifacts.zig` |

### Security Notes

- `artifact_version_pins.collected_at` is set by an internal process (not by the agent).
  No external endpoint exposes a direct write to this column.
- The `staging.` schema is inaccessible on production deployments (AGT-02); the retention
  tables therefore never exist in production.
- The deprecated-field check discards the submitted value entirely and writes no artifact
  row, preventing any form of aliased-field injection.
