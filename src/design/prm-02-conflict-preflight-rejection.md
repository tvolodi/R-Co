# Module: prm-02-conflict-preflight-rejection

**Requirement ID:** PRM-02
**Run ID:** WF02-prm-batch2-20260814 (Stage 16)
**Step:** 01 (CODE-DESIGNER)
**Type:** Type E — Novel business logic

**Extends:**
- `src/definition/promotion_plan.zig` (PRM-01 — `computePromotionPlan()` output shape `{type, id, change_kind, before, after}`)
- `src/definition/promotion.zig` (ENV-03 — existing promotion pipeline, called before any write)
- `docs/processes/system/definition-promotion.md` — Step 4

---

## Classification rationale

Applying `templates/lego-catalog.md` selection rules:

1. **Type C?** No new table is introduced by PRM-02 itself — the conflict check reads from `process_definitions` (already exists) and writes `DEFINITION_PROMOTION_REJECTED` to the event store (already exists). No migration required.
2. **Type A?** The conflict check is not a CRUD endpoint — it is a pre-flight step called inside the promotion pipeline before the review row is created. It is not reachable via any HTTP route in its own right.
3. **Type E — yes.** The conflict check is a coordinated multi-step sequence: read target active version (no lock), compare against `base_version`, and on conflict: open a separate transaction to append exactly one event and return without touching the main promotion flow. This is structurally novel logic with precise ordering guarantees.

---

## Module purpose

Detect whether the target tenant has advanced past the version the source was branched from, as the **first step of the promotion pipeline before any transaction opens**. A conflict exists when `target_active_version > base_version`. On conflict: return a typed `ConflictRejection`, append `DEFINITION_PROMOTION_REJECTED` in its own transaction, and move no version pointer.

This function is called after `computePromotionPlan()` (PRM-01) and before the `promotion_reviews` row is inserted (PRM-04). It must hold **no lock** on the target tenant schema at the point it raises the conflict.

---

## Public interface

```zig
/// Result of a conflict check. Non-null return means a conflict was detected.
pub const ConflictRejection = struct {
    /// The conflicting definition id on the target tenant (target_def.id).
    target_definition_id: []const u8,
    /// The version of the conflicting definition on the target tenant.
    target_version: u32,
    /// The source-side change description (which version the source branched from).
    source_change: []const u8,
    /// The target-side change description (which version the target is now at).
    target_change: []const u8,
};

/// Returned when no conflict is present.
const NoConflict = struct {};

/// Checks for a promotion conflict before any transaction opens.
/// Reads target tenant's active version of process_key; compares with base_version.
/// On conflict: opens its own transaction to append DEFINITION_PROMOTION_REJECTED
/// and returns the rejection. On no conflict: returns null.
/// Called after computePromotionPlan(), before promotion_reviews insert.
pub fn rejectIfConflicts(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    target_tenant_id: []const u8,
    process_key: []const u8,
    base_version: u32,
) (error{ PoolExhausted, TransactionFailed } | ?ConflictRejection);
```

---

## Data flow diagram

```
Promotion pipeline begins (POST /api/v1/promotions)
        |
        v
computePromotionPlan()  [PRM-01 — read-only, no write]
        |
        v
rejectIfConflicts(target_tenant_id, process_key, base_version)
        |
        |  <- Step 4 in docs/processes/system/definition-promotion.md
        |     "before any transaction opens"
        |
        v
SELECT MAX(version::int)
  FROM target_tenant.process_definitions
  WHERE name = $process_key AND status = 'ACTIVE'
        |
        +-- target_version > base_version?  --> CONFLICT
        |     Open独立事务 (no lock on target)
        |     Append DEFINITION_PROMOTION_REJECTED event
        |     Return ConflictRejection to caller
        |     Promotion pipeline HALTS (no promotion_reviews row created)
        |
        +-- target_version <= base_version?  --> NO CONFLICT
              Return null, pipeline continues to PRM-04 (promotion_reviews insert)
```

**Critical ordering property:** The `SELECT MAX(version)` runs **outside** any transaction that will later write to the target tenant. This means the conflict check holds no row lock — the query is a plain read with no `FOR UPDATE`. If a conflict is found, the rejection event is written in a **separate, independent transaction** from whatever the main promotion pipeline does next.

---

## Canonical conflict condition

```
conflict = (target_active_version > base_version)
```

Where:
- `target_active_version` = `MAX(version::int)` from `target_tenant.process_definitions WHERE name = $process_key AND status = 'ACTIVE'`
- `base_version` = the version the source branched from, passed from the promotion plan submission

**Note:** If the target has no ACTIVE version of `process_key` (zero rows), `MAX` returns NULL → no conflict. This is correct: if the target has never seen this process_key, there is no version to conflict with, and the plan entries will all be `change_kind = added` (PRM-01 AC2, handled upstream).

---

## ConflictRejection body shape (HTTP 409)

```json
{
  "error": "PROMOTION_CONFLICT",
  "message": "Target tenant has advanced past base_version",
  "conflicts": [
    {
      "process_key": "<process_key>",
      "target_definition_id": "<uuid>",
      "target_version": 3,
      "source_change": "branched from version 1",
      "target_change": "target is now at version 3"
    }
  ]
}
```

HTTP status: **409 Conflict**

---

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `PoolExhausted` | Cannot acquire DB connection | HTTP 503 `SERVICE_UNAVAILABLE` |
| `TransactionFailed` | Event append fails | HTTP 500 `INTERNAL_ERROR` |

---

## Dependencies

| Dependency | Kind | Notes |
|---|---|---|
| `process_definitions` table | DB read | Already exists; queried in target tenant schema |
| `event_store.store.zig` | DB write | `Store.append()` for `DEFINITION_PROMOTION_REJECTED` event |
| `computePromotionPlan()` (PRM-01) | Caller | Conflict check runs after plan is computed |
| `base_version` | Input | Must be passed from the promotion submission; this is the version the source branched FROM |
| `target_tenant_id` | Input | The production tenant receiving the promotion |

**Must NOT depend on:** `promotion_reviews` table (created by PRM-04), `promotion_assertion_runs` (created by PRM-06) — PRM-02 runs before both.

---

## Open questions

1. **Event payload fields:** The `DEFINITION_PROMOTION_REJECTED` event body should carry `process_key`, `source_tenant_id`, `target_tenant_id`, `target_definition_id`, `target_version`, `base_version`, and a human-readable `reason`. BACKEND-DEV to align with the event schema registry (`src/event_store/registry.zig`) and the existing event-append pattern in `promotion.zig`.

2. **Multiple-process conflict:** PRM-02's AC describes one `ConflictRejection` naming each conflicting definition. If multiple `process_key` values are in the plan and more than one conflicts, the rejection should list all of them. BACKEND-DEV to implement as an array of conflicts, not just one — PRM-02 AC: "naming **each** conflicting definition."

3. **base_version source:** The `base_version` must be supplied at submission time. It is not yet clear whether it comes from the request body (`POST /api/v1/promotions` body may need to extend to accept `base_version`) or from a prior relationship tracked elsewhere. REQ-ANALYST to clarify if PRM-01's submission body needs a `base_version` field.
