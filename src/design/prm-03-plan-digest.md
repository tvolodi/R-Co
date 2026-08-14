# Module: prm-03-plan-digest

**Requirement ID:** PRM-03
**Run ID:** WF02-prm-batch2-20260814 (Stage 16)
**Step:** 01 (CODE-DESIGNER)
**Type:** Type E — Novel business logic

**Extends:**
- `src/definition/promotion_plan.zig` (PRM-01 — `PromotionPlan`, `PlanEntry` with `{type, id, change_kind, before, after}`)
- `src/api/routes/promotions.zig` (PRM-01 — `POST /api/v1/promotions` handler)
- `docs/processes/system/definition-promotion.md` — Steps 5, 9, 10

---

## Classification rationale

Applying `templates/lego-catalog.md` selection rules:

1. **Type C?** No new table is introduced by PRM-03 itself. The `plan_digest` is stored on the `promotion_reviews` row created by PRM-04 (a separate migration). No migration needed here.
2. **Type A?** Not a CRUD endpoint. Digest computation is an internal utility called at two points: at plan submission time (to store alongside the review row) and at approve/apply time (to verify the request body digest matches the stored one).
3. **Type E — yes.** SHA-256 canonical JSON digest over a structured plan with a precise definition of canonical form. This is a cryptographic operation with specific ordering guarantees (lexicographic key sort, no insignificant whitespace). Must be correct and deterministic.

---

## Module purpose

Bind every approval to a `plan_digest`: a lowercase hexadecimal SHA-256 over the canonical JSON serialisation of the promotion plan. The digest is computed at **submit time** and stored on the `promotion_reviews` row alongside the full serialised plan. At **approve time** and **apply time**, the digest in the request body must match the stored digest — a mismatch returns HTTP 409 `PlanDigestMismatch`.

Digest is **not** recomputed at approval or apply time; the stored value is compared directly.

---

## Canonical JSON rules

Canonical means:

1. **Object keys sorted lexicographically** (ascending, by Unicode code point).
2. **No insignificant whitespace** — no spaces after `:`, no spaces after `,`, no newlines or indentation.
3. **UTF-8 encoded** (JSON strings are always UTF-8 in Zig/PostgreSQL).
4. **`null` values are included** — a `null` in a field is serialised as the literal `null`, not omitted.

These rules ensure the digest is **deterministic**: two byte-identical plans always produce the same digest, and any difference in plan content (even a whitespace change) produces a different digest.

---

## Plan entry shape (PRM-03 requirement)

Each plan entry in the array is:

```json
{
  "type": "<PlanEntryType string>",
  "id": "<string>",
  "change_kind": "<added|modified|removed>",
  "before": "<JSON string or null>",
  "after": "<JSON string or null>"
}
```

**Note:** PRM-03's AC and body specify `{type, id, change_kind, before, after}` — this is the entry shape the digest is computed over, NOT `{type, id, changes}` (which was the prior draft and was flagged as conflicting with RELEASED PRM-01).

---

## Public interface

```zig
/// Computes the canonical SHA-256 digest of a PromotionPlan.
/// Returns lowercase hexadecimal string (64 characters).
/// Canonical form: keys sorted lexicographically, no insignificant whitespace.
pub fn computePlanDigest(allocator: std.mem.Allocator, plan: PromotionPlan) []const u8;

/// Verifies that a request-body digest matches the stored digest.
/// Returns true if equal, false otherwise.
pub fn verifyDigest(stored: []const u8, provided: []const u8) bool;
```

---

## Data flow diagram

```
Plan submission (POST /api/v1/promotions)
        |
        v
computePromotionPlan()  [PRM-01]
        |
        v
canonicalise(plan)  --> JSON bytes with sorted keys, no extra whitespace
        |
        v
plan_digest = SHA-256(canonical_json)  [lowercase hex, 64 chars]
        |
        |  [store: plan_digest + full serialised plan on promotion_reviews]
        v
POST .../approve  (request body: { plan_digest: "...", approved_by: "..." })
        |
        v
compare(request_body.plan_digest, stored.plan_digest)
        |
        +-- match  --> proceed with approval transition
        |
        +-- mismatch  --> HTTP 409 PlanDigestMismatch, review stays pending_review
        |
        v
POST .../apply  (request body: { plan_digest: "..." })
        |
        v
compare(request_body.plan_digest, stored.plan_digest)
        |
        +-- match  --> proceed with apply
        |
        +-- mismatch  --> HTTP 409 PlanDigestMismatch, no sandbox claimed
```

---

## Digest computation detail

```zig
// Canonical JSON for a single PlanEntry:
// {"after":null,"before":null,"change_kind":"added","id":"node-1","type":"graph_node"}
//
// The canonical JSON for the whole plan is the JSON array of entries,
// with object keys sorted at every level.
//
// Canonicalise function pseudocode:
//   1. Clone the plan entries to avoid mutating the original.
//   2. Sort object keys lexicographically for every entry (type, id, change_kind, before, after).
//   3. Serialise to JSON with compact options (no indentation, no spaces after : or ,).
//   4. Compute SHA-256 over the UTF-8 bytes of the serialised string.
//   5. Return lowercase hex (64 characters).
```

---

## Error taxonomy

PRM-03 introduces no new error types — `PlanDigestMismatch` is surfaced at the API layer:

| Error | Trigger | Surfaced as |
|---|---|---|
| `PlanDigestMismatch` | Approve/apply request body digest ≠ stored digest | HTTP 409 `PLAN_DIGEST_MISMATCH` |

No new error set in the Zig module — this is an API-layer concern.

---

## Dependencies

| Dependency | Kind | Notes |
|---|---|---|
| `PromotionPlan` / `PlanEntry` | Types | From `src/definition/promotion_plan.zig` (PRM-01) |
| SHA-256 | Crypto | Zig standard library: `std.crypto.hash.sha2.Sha256` |
| `promotion_reviews` table | DB | Digest stored by PRM-04; this module reads it for comparison |

**Must NOT depend on:** Any schema decision about how the serialised plan is stored (text vs. jsonb) — that is PRM-04's concern. This module treats the plan as an opaque `PromotionPlan` value.

---

## Open questions

1. **Plan serialisation for storage:** PRM-03 says "digest and full serialised plan stored on `promotion_reviews`." It does not specify whether the serialised plan is stored as `text` or `jsonb`. BACKEND-DEV to decide based on existing conventions for storing JSON in this codebase (see other `promotion_*` tables or similar). If `jsonb`, query indexing may be available; if `text`, it is raw but simpler.

2. **Stable canonical JSON encoder in Zig:** Zig's `std.json.stringify` with `.{}` emits map fields in declaration order (insertion order), which is **not** guaranteed to be lexicographically sorted. BACKEND-DEV must implement custom serialisation that explicitly sorts object keys before emitting — either by sorting the `PlanEntry` slice before serialising, or by using a custom encoder that sorts during output. A unit test must verify that two plans with the same content in different key orders produce identical digests.

3. **Digest comparison timing:** `verifyDigest` must use a **constant-time comparison** to avoid timing attacks on the digest value. Standard `std.mem.eql(u8, ...)` is sufficient for 64-char hex strings but note this explicitly in implementation.
