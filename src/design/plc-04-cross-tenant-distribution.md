# Module: plc-04-cross-tenant-distribution

**Requirement IDs:** PLC-04
**Run ID:** WF02-plc-batch-a-20260815 (Stage 15)
**Type:** Type E — access-control design

---

## Module purpose

Controls which tenants can resolve which modules in the process module catalog. By default,
no tenant can see another tenant's modules. Explicit sharing grants — authorised by a
`PLATFORM_ADMIN` — allow a publishing tenant's catalog to be visible to specific subscribing
tenants. Revocation does not affect already-running child instances.

---

## Two-layer visibility model

### Layer 1: Tenant-local modules

Every tenant can always see and use its own modules (`owning_tenant_id == requesting_tenant_id`).
No grant is required. This is the **owning tenant's** view of its own catalog.

### Layer 2: Shared modules

Cross-tenant visibility requires a **sharing grant** — a row in
`process_module_catalog_share` created by a PLATFORM_ADMIN acting on behalf of the publishing
tenant.

```
Sharing grant:
  granting_tenant_id  = publishing tenant (owns the module)
  module_id           = which module to share
  receiving_tenant_id = subscriber tenant (wants to use it)
  granted_by          = platform admin who authorised
```

Without a grant, cross-tenant resolution is indistinguishable from a non-existent module.

---

## Resolution integration

`resolveModuleRef` (PLC-01) implements the visibility check:

```zig
pub fn resolveModuleRef(..., requesting_tenant_id) -> ModuleRefResolution:
    // Layer 1: own modules always visible
    entry = db.query(
        "SELECT * FROM process_module_catalog
         WHERE module_id = $1
           AND owning_tenant_id = $2
           AND status = 'ACTIVE'
         ORDER BY semver_sort(version) DESC
         LIMIT 1",
        module_ref.module_id, requesting_tenant_id
    )
    if entry != null and satisfies_constraint(entry.version, module_ref.version_constraint):
        return ModuleRefResolution { resolved: true, entry }

    // Layer 2: shared modules
    entry = db.query(
        "SELECT pmc.* FROM process_module_catalog pmc
         JOIN process_module_catalog_share pmcs
           ON pmcs.granting_tenant_id = pmc.owning_tenant_id
          AND pmcs.module_id = pmc.module_id
         WHERE pmc.module_id = $1
           AND pmcs.receiving_tenant_id = $2
           AND pmc.status = 'ACTIVE'
         ORDER BY semver_sort(pmc.version) DESC
         LIMIT 1",
        module_ref.module_id, requesting_tenant_id
    )
    if entry != null and satisfies_constraint(entry.version, module_ref.version_constraint):
        return ModuleRefResolution { resolved: true, entry }

    // Neither own nor granted
    return ModuleRefResolution { resolved: false, error_code: "UNRESOLVED_MODULE_REF" }
```

---

## Grant lifecycle

### Create grant

```
POST /api/v1/admin/module-shares
{
  "granting_tenant_id": "uuid-of-publisher",
  "module_id": "order-processing",
  "receiving_tenant_id": "uuid-of-subscriber"
}
```

Requires: caller holds `PLATFORM_ADMIN` role (global, not scoped to a tenant).
Returns: 201 with `{ grant_id, ... }`.

**Audit log:** `grantModuleVisibility` MUST emit a structured `audit_log` event with `event_type = "MODULE_SHARE_GRANTED"`, recording `granting_tenant_id`, `receiving_tenant_id`, `module_id`, `granted_by` (actor), and `granted_at`.

Errors:
- `409 CONFLICT` if grant already exists for the same tuple.
- `404 NOT_FOUND` if `granting_tenant_id` does not own a module with that `module_id`.
- `403 FORBIDDEN` if caller is not PLATFORM_ADMIN.

### List grants

```
GET /api/v1/admin/module-shares?granting_tenant_id=&receiving_tenant_id=
```

Returns: page of grants visible to the calling context (PLATFORM_ADMIN sees all;
PROCESS_DESIGNER sees only their tenant's own grants).

### Revoke grant

```
DELETE /api/v1/admin/module-shares/{grant_id}
```

Requires: caller holds `PLATFORM_ADMIN` role.
Returns: 204 No Content on success.

**Audit log:** `revokeModuleVisibility` MUST emit a structured `audit_log` event with `event_type = "MODULE_SHARE_REVOKED"`, recording the `grant_id`, `module_id`, `receiving_tenant_id`, and `revoked_by` (actor).

---

## Revocation semantics: running instances are unaffected

When a grant is revoked:

1. **New activations blocked:** A subsequent call to `resolveModuleRef` by the revoked
   tenant for the same `module_id` will no longer find a visible entry → returns
   `UnresolvedModuleRef` → parent instance transitions to ERROR per EE-10.
2. **Already-running child instances continue:** The child instance was started under a
   prior valid resolution and has its own `definition_snapshot` (PD-08) capturing the
   resolved `owning_definition_id`. Revocation does not retroactively change that snapshot.
   The child runs to completion under its original definition.

This is intentional: retroactive termination of in-flight instances would create orphaned
workflows with no clean recovery mechanism. The grace period is "running instances complete
normally; new activations are blocked."

---

## Information leakage prevention

The design intentionally returns the **same error** (`UnresolvedModuleRef` / HTTP 422) for:

- A module that does not exist at all.
- A module that exists but is not visible to the requesting tenant.

This prevents a subscribing tenant from probing a publishing tenant's catalog by enumerating
`module_id` values. The absence of a sharing grant is indistinguishable from the module not
existing.

---

## Grant vs. `exportable` flag

These are two independent controls:

| Control | Mechanism | Governs |
|---|---|---|
| `process_module_catalog_share` rows | Visibility at runtime | Whether a subscribing tenant can `resolveModuleRef` and use the module in a running instance |
| `process_module_catalog.exportable` | SOL-01 pack export | Whether a platform admin can inline the module's definition content into a solution pack for distribution |

A module can be `exportable = true` but have no grants (not shared at runtime). Conversely,
a module can be granted to subscribers but marked `exportable = false` (shareable at runtime
but not pack-inlinable). These are independent decisions made by different actors
(PLATFORM_ADMIN for grants; owning tenant's PROCESS_DESIGNER for `exportable`).

---

## Data model (already in PLC-01)

```sql
-- process_module_catalog_share (defined in plc-01-process-module-catalog.md)
CREATE TABLE process_module_catalog_share (
    grant_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    granting_tenant_id   UUID NOT NULL,
    module_id            VARCHAR(255) NOT NULL,
    receiving_tenant_id  UUID NOT NULL,
    granted_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    granted_by           UUID NOT NULL,
    UNIQUE (granting_tenant_id, module_id, receiving_tenant_id)
);
```

Index for common query:

```sql
CREATE INDEX idx_module_share_receiving
  ON process_module_catalog_share (receiving_tenant_id, module_id)
  WHERE granting_tenant_id != receiving_tenant_id;
```

---

## Dependencies

- **PLC-01:** Catalog table, `resolveModuleRef` function, share table.
- **PIN-01:** Resolution is invoked from the instance-start path.
- **SOL-01:** Pack export reads `exportable` flag separately from share grants.
- **IDN-03:** PLATFORM_ADMIN role enforcement in the grant/revoke handlers.

---

## Edge cases

| Case | Expected behaviour |
|---|---|
| Grant for a module the publisher doesn't own | HTTP 404 — grant creation fails; no info leak about publisher's catalog |
| Grant for a module in DRAFT status | Allow — visibility is at catalog level; resolution still fails if no ACTIVE version satisfies constraint |
| Subscriber has multiple ACTIVE versions of the same module | `resolveModuleRef` returns highest semver satisfying constraint (per PLC-01) |
| Grant exists but all versions are DEPRECATED | Resolution returns `UnresolvedModuleRef` |
| Same `module_id` shared by two publishers | `module_id` is per-tenant-scoped (per PLC-01 OQ-2); same `module_id` from two publishers are distinct entries |

---

## Open questions

1. **Can a tenant have multiple grants for the same module from different publishers?**
   If `module_id` is per-tenant-scoped (per PLC-01 OQ-2), this cannot happen — a grant's
   `module_id` is always paired with its `granting_tenant_id`, so the composite key
   `(granting_tenant_id, module_id, receiving_tenant_id)` is unique. No ambiguity.
2. **Does PLATFORM_ADMIN need tenant context to create/revoke a grant?** Yes —
   `granting_tenant_id` must be specified so the platform knows whose catalog is being shared.
   PLATFORM_ADMIN is global but must name the affected tenant relationship.
3. **Audit log:** Should `grantModuleVisibility` and `revokeModuleVisibility` emit structured
   audit events? This follows the same pattern as other administrative actions — recommend yes,
   using the existing `audit_log` table with `resource_type = 'process_module_catalog_share'`.
