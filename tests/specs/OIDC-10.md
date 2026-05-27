# Test Spec: OIDC-10 — Attribute Synchronisation and Role Reconciliation

**Requirement:** OIDC-10 — On every authentication, the platform MUST synchronise the local user record's `display_name`, `email`, and `status` from token claims, and reconcile role bindings so that OIDC-sourced roles match the token's role set while locally-assigned roles are preserved. Sync failure MUST NOT block authentication (best-effort).

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-10-01: Full flow — resolve user, update profile, reconcile roles
**Given:** An existing OIDC-provisioned user with stale display_name and OIDC role `TASK_WORKER`
**When:** `syncAttributesFromIdentityContext` is called with a token containing `display_name="Updated Name"` and roles `["TASK_WORKER", "PROCESS_OPERATOR"]`
**Then:** The user's display_name is updated; `TASK_WORKER` (already present) is kept; `PROCESS_OPERATOR` is added as OIDC-sourced; `SyncResult` indicates `profile_changed=true` and `roles_added` contains `PROCESS_OPERATOR`
**Layer:** integration
**Acceptance criterion mapped:** Profile sync and role reconciliation happen on every auth

### TC-OIDC-10-02: Profile sync — display_name, email, status updated when claims differ
**Given:** An OIDC user with stored `display_name="Old Name"`, `email="old@example.com"`, `status=ACTIVE`
**When:** `syncAttributesFromIdentityContext` is called with claims `display_name="New Name"`, `email="new@example.com"`
**Then:** The user record in the DB has `display_name="New Name"` and `email="new@example.com"`; `profile_changed=true`
**Layer:** integration
**Acceptance criterion mapped:** Profile fields are updated when token claims differ

### TC-OIDC-10-03: Profile no-op — no update when claims match stored values
**Given:** An OIDC user whose stored `display_name` and `email` match the incoming token claims
**When:** `syncAttributesFromIdentityContext` is called
**Then:** No UPDATE is performed on the users table; `profile_changed=false`
**Layer:** integration
**Acceptance criterion mapped:** No unnecessary database writes when nothing changed

### TC-OIDC-10-04: Role reconciliation — add new OIDC roles, remove stale OIDC roles
**Given:** An OIDC user with existing OIDC-sourced roles `["TASK_WORKER", "PROCESS_DESIGNER"]`
**When:** `syncAttributesFromIdentityContext` is called with token roles `["TASK_WORKER", "PROCESS_OPERATOR"]`
**Then:** `PROCESS_OPERATOR` is added as OIDC-sourced; `PROCESS_DESIGNER` is removed (OIDC-sourced); `TASK_WORKER` is preserved; `roles_added` contains `PROCESS_OPERATOR`; `roles_removed` contains `PROCESS_DESIGNER`
**Layer:** integration
**Acceptance criterion mapped:** Token roles are authoritative for OIDC bindings

### TC-OIDC-10-05: Role preservation — locally-assigned roles survive reconciliation
**Given:** An OIDC user with `VIEWER` locally-assigned (`role_source='internal'`) and `TASK_WORKER` OIDC-sourced
**When:** `syncAttributesFromIdentityContext` is called with token roles `["PROCESS_OPERATOR"]`
**Then:** `VIEWER` is preserved (not removed); `TASK_WORKER` is removed; `PROCESS_OPERATOR` is added as OIDC-sourced
**Layer:** integration
**Acceptance criterion mapped:** Locally-assigned roles are never modified

### TC-OIDC-10-06: Role overlap — OIDC role removed, separate local role preserved
**Given:** An OIDC user with `PROCESS_DESIGNER` OIDC-sourced and a different role slug (`PROCESS_DESIGNER_LOCAL`) locally-assigned (the UNIQUE `(user_id, role_id)` constraint prevents two bindings for the same role slug with different sources)
**When:** `syncAttributesFromIdentityContext` is called with empty token roles
**Then:** The OIDC-sourced `PROCESS_DESIGNER` binding is removed; the locally-assigned `PROCESS_DESIGNER_LOCAL` binding is preserved
**Layer:** integration
**Acceptance criterion mapped:** Overlapping role slugs are handled correctly — OIDC binding removed, local binding survives

### TC-OIDC-10-07: Empty token roles — all OIDC-sourced roles removed, local ones preserved
**Given:** An OIDC user with OIDC-sourced roles `["TASK_WORKER", "PROCESS_OPERATOR"]` and locally-assigned role `["VIEWER"]`
**When:** `syncAttributesFromIdentityContext` is called with empty token roles `[]`
**Then:** Both OIDC-sourced roles are removed; `VIEWER` is preserved; `roles_added` is empty; `roles_removed` contains `TASK_WORKER` and `PROCESS_OPERATOR`
**Layer:** integration
**Acceptance criterion mapped:** Empty token roles strip all OIDC-sourced bindings

### TC-OIDC-10-08: Error handling — user not found returns error.UserNotFound
**Given:** An external identity that has no local user record
**When:** `syncAttributesFromIdentityContext` is called
**Then:** `error.UserNotFound` is returned
**Layer:** integration
**Acceptance criterion mapped:** Unknown identities are reported as UserNotFound

### TC-OIDC-10-09: Best-effort — sync failure does not block auth
**Given:** A failing `syncAttributesFromIdentityContext` call (e.g., user not found)
**When:** The auth middleware catches the error
**Then:** The auth pipeline continues with the existing `AuthContext`; a warning is logged
**Layer:** integration
**Acceptance criterion mapped:** Sync failure is non-fatal to authentication

### TC-OIDC-10-10: No change — identical profile and roles produce empty result
**Given:** An OIDC user whose stored profile and current role bindings match the token claims and token roles exactly
**When:** `syncAttributesFromIdentityContext` is called
**Then:** `profile_changed=false`; `roles_added` and `roles_removed` are both empty
**Layer:** integration
**Acceptance criterion mapped:** No unnecessary work when nothing changed

### TC-OIDC-10-11: Unit — reconciliation algorithm computes correct add_set and remove_set
**Given:** A current set of bindings `[(TASK_WORKER, oidc), (VIEWER, internal)]` and token roles `["TASK_WORKER", "PROCESS_OPERATOR"]`
**When:** The reconciliation algorithm (partition, diff) is computed
**Then:** `add_set = {PROCESS_OPERATOR}`; `remove_set = {}`; `local_slugs = {VIEWER}` remains untouched
**Layer:** unit
**Acceptance criterion mapped:** Algorithm correctly partitions and diffs

### TC-OIDC-10-12: Unit — empty token roles produce removal of all OIDC roles
**Given:** A current set of bindings `[(TASK_WORKER, oidc), (PROCESS_OPERATOR, oidc)]` and token roles `[]`
**When:** The reconciliation algorithm is computed
**Then:** `add_set = {}`; `remove_set = {TASK_WORKER, PROCESS_OPERATOR}`
**Layer:** unit
**Acceptance criterion mapped:** Empty token roles remove all OIDC bindings

### TC-OIDC-10-13: Unit — all roles locally-assigned, token has new roles
**Given:** A current set of bindings `[(VIEWER, internal)]` and token roles `["PROCESS_OPERATOR"]`
**When:** The reconciliation algorithm is computed
**Then:** `add_set = {PROCESS_OPERATOR}`; `remove_set = {}`
**Layer:** unit
**Acceptance criterion mapped:** New roles are added even when no OIDC roles exist yet

### TC-OIDC-10-14: Unit — role is both OIDC-sourced and locally-assigned
**Given:** A current set of bindings `[(PROCESS_DESIGNER, oidc), (PROCESS_DESIGNER, internal)]` and token roles `[]`
**When:** The reconciliation algorithm is computed
**Then:** `add_set = {}`; `remove_set = {PROCESS_DESIGNER}` (only the oidc one); local `PROCESS_DESIGNER` is preserved
**Layer:** unit
**Acceptance criterion mapped:** Overlapping role sources handled correctly

### TC-OIDC-10-15: Unit — no OIDC-sourced roles at all
**Given:** A current set of bindings `[(VIEWER, internal)]` and token roles `[]`
**When:** The reconciliation algorithm is computed
**Then:** `add_set = {}`; `remove_set = {}`; no changes needed
**Layer:** unit
**Acceptance criterion mapped:** No OIDC roles means nothing to reconcile
