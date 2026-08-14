# Test Spec: SOL-01/02/03 — Solution Pack Export, Install, and Role Gate

**Run ID:** WF02-sol-batch1-20260814
**Requirement IDs:** SOL-01 (MUST), SOL-02 (MUST), SOL-03 (MUST)
**Test files:**
- `tests/integration/sol01_export_test.zig`
- `tests/integration/sol02_install_test.zig`
- `tests/integration/sol03_role_gate_test.zig`

---

## SOL-01: Solution Pack Export

| Test ID | AC Ref | Setup | Action | Assertion |
|---------|--------|-------|--------|-----------|
| TC-SOL01-01 | SOL-01 AC1 | Insert a definition with a minimal START→END graph (no SERVICE_TASK or HUMAN_TASK nodes) using a unique random name | `exportPack("1.0.0", [def_id])` | `doc.definitions` has 1 entry; `pack_id` is 36-char UUID; `bpm_export_schema_version == "bpm/solution-pack/v1"`; `service_catalog_entries` is empty; `manifest.required_roles` is empty |
| TC-SOL01-02 | SOL-01 AC1 | Insert a definition whose graph contains a SERVICE_TASK node with a unique `service_id`; insert a matching `public.service_catalog` row | `exportPack("1.0.0", [def_id])` | `doc.service_catalog_entries` has exactly 1 entry; `entry.service_id` matches the inserted row; `entry.endpoint_url` matches |
| TC-SOL01-03 | SOL-01 AC1 + AC3 | Insert a definition whose graph contains two HUMAN_TASK nodes with `assignee_type="ROLE"` and role names "Zebra Role" and "Alpha Role" | `exportPack("1.0.0", [def_id])` | `manifest.required_roles` has exactly 2 entries; first entry is "Alpha Role", second is "Zebra Role" (alphabetical, flat list) |
| TC-SOL01-04 | SOL-01 AC1 | No matching definition in the database | `exportPack("1.0.0", [random_uuid_not_in_db])` | Returns `error.DefinitionNotFound` |

**SOL-01 test count: 4**

---

## SOL-02: Solution Pack Installation

| Test ID | AC Ref | Setup | Action | Assertion |
|---------|--------|-------|--------|-----------|
| TC-SOL02-01 | SOL-02 AC1 + AC4 | Build a `SolutionPackDocument` with 1 `PackedDefinition` (minimal graph), no catalog entries, 1 manifest role that is NOT bound in `tenant_role` | `installPack(doc, actor_id)` | `result.installed_definitions` has 1 entry with `status="DRAFT"`; a `solution_pack_installs` row exists in DB; `role_mapping_checklist` has 1 entry with `bound=false`; no auto-activation |
| TC-SOL02-02 | SOL-02 AC2 | Pre-insert a `public.service_catalog` row with `service_id="sol02-conflict-svc"`; build a pack with the same `service_id` but a **different** `request_schema` | `installPack(doc, actor_id)` | Returns `error.CatalogConflict`; no `solution_pack_installs` row created (transaction rolled back) |
| TC-SOL02-03 | SOL-02 AC3 | Pre-insert a `public.service_catalog` row; build a pack with the **identical** `service_id` and **identical** schemas | `installPack(doc, actor_id)` | Install succeeds (no error); `result.installed_definitions` has 1 entry; only 1 `service_catalog` row for that `service_id` exists |
| TC-SOL02-04 | SOL-02 AC5 | Install a pack once; keep the exact same `doc` | `installPack(doc, actor_id)` a second time | Second call returns a result (no error); `result.warnings` contains the idempotent-skip message; exactly 1 `solution_pack_installs` row for `(pack_id, pack_version)` |

**SOL-02 test count: 4**

---

## SOL-03: Role-Mapping Activation Gate

| Test ID | AC Ref | Setup | Action | Assertion |
|---------|--------|-------|--------|-----------|
| TC-SOL03-01 | SOL-03 AC1 | Install a pack with 3 manifest roles ("RoleA", "RoleB", "RoleC"); bind only "RoleA" in `tenant_role` | `checkRoleGate(new_def_id)` | `result.allowed == false`; `result.unbound_roles` has exactly 2 entries: "RoleB" and "RoleC" |
| TC-SOL03-02 | SOL-03 AC2 | Install a pack with 1 manifest role ("RoleX"); bind "RoleX" in `tenant_role` | `checkRoleGate(new_def_id)` | `result.allowed == true`; `result.unbound_roles` is empty |
| TC-SOL03-03 | SOL-03 AC3 | Insert a definition via normal INSERT (no `solution_pack_install_id`) | `checkRoleGate(def_id)` | `result.allowed == true`; `result.unbound_roles` is empty (gate does not apply to non-pack definitions) |

**SOL-03 test count: 3**

---

## Summary

| Requirement | MUST ACs | Test IDs | Count |
|-------------|----------|----------|-------|
| SOL-01 | AC1, AC3 | TC-SOL01-01..04 | 4 |
| SOL-02 | AC1, AC2, AC3, AC4, AC5 | TC-SOL02-01..04 | 4 |
| SOL-03 | AC1, AC2, AC3 | TC-SOL03-01..03 | 3 |
| **Total** | | | **11** |

All 11 test cases are implemented. No deferred or phase-2 cases. No `error.SkipZigTest` on any MUST test.
