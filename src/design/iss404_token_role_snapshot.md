# Module: ISS-404 Token Role Snapshot

**Covers:** ISS-404 (Codify `api_tokens.roles[]` as a point-in-time grant)
**Files:**
- `src/identity/service.zig` — token creation/issuance logic (snapshot roles at creation)
- `src/api/middleware/auth.zig` — token validation role resolution (read from snapshot)

**Depends on:**
- Existing `api_tokens` table (migration 008_identity.sql) — already has `roles_json` column.
- Existing `user_roles` table — live role registry that can change post-issuance.

---

## Module purpose

This module codifies the rule introduced in architecture document v1.1 section 6.7: **token roles are a point-in-time snapshot taken at token issuance**. Once a token is issued, its effective roles are frozen in `api_tokens.roles[]`. Changes to the user's `user_roles` rows after issuance do not retroactively alter an already-issued token.

This closes an ambiguity where both `user_roles` (live) and `api_tokens.roles[]` (stored) could serve as the authoritative role source for a token-authenticated request. The resolution:

- `user_roles` is the **user registry** — it defines what roles the user currently holds.
- `api_tokens.roles[]` is the **token snapshot** — a copy of the user's roles at the moment of issuance.
- **Token validation reads from the snapshot**, not from the live registry.

---

## Scope and non-goals

**In scope:**
- Token creation: snapshot `user_roles` into `api_tokens.roles_json` at issuance time.
- Token validation (auth middleware): read roles from `api_tokens.roles[]` only, never from `user_roles`.
- Tests that verify a `user_roles` change does not affect an existing token's effective roles.

**Out of scope:**
- Automatic token re-issue when roles change (manual/admin action required).
- Role expiry / time-bound grants (all grants are permanent until explicitly revoked).
- Changing the `api_tokens` schema (the `roles_json` column already exists; this module only codifies the behaviour contract).
- The OIDC token path (OIDC tokens carry roles in the token claims, not in `api_tokens`).

---

## Behaviour contract

### Token issuance

When a new API token is created (via `POST /api/v1/tokens` or equivalent admin API):

```
createToken(user_id, ...):
  // 1. Query user_roles for the current set of role names.
  roles = SELECT r.name FROM roles r
          JOIN user_roles ur ON ur.role_id = r.id
          WHERE ur.user_id = $1

  // 2. Serialise role names to JSON array (e.g. ["TASK_WORKER", "VIEWER"]).
  roles_json = json.encode(roles)

  // 3. Insert into api_tokens with roles_json = snapshot.
  INSERT INTO api_tokens (id, user_id, token_hash, roles_json, ...)
  VALUES ($1, $2, $3, $4::jsonb, ...)
```

The snapshot is taken **inside the same transaction** as the token creation to ensure consistency.

### Token validation (existing flow, confirmed)

The `authenticate()` function in `src/api/middleware/auth.zig` already reads roles from `api_tokens.roles_json`:

```
// Existing code (auth.zig, lines 1248-1263):
const roles_json = row[4] orelse "[]";
if (roles_json.len > 2) {
    const token_roles = parseRolesJson(allocator, roles_json);
    // ... use token_roles from the snapshot
    role = primaryRole(token_roles);
} else {
    // Fallback: roles_json is empty "[]" — load from user_roles
    // This is the legacy path for tokens created before roles_json was populated.
}
```

The ISS-404 codification:
1. **The fallback path (loading from `user_roles` when `roles_json` is empty `"[]"`) is deprecated for new code but preserved for backward compatibility with pre-existing tokens.**
2. **All newly issued tokens MUST have a non-empty `roles_json` array.** A token with an empty `roles_json` at creation time (user has no roles) should store `["VIEWER"]` as the minimum grant.
3. **If `roles_json` array is empty AND the fallback path loads from `user_roles`, that is acceptable for legacy tokens only.** The implementation should log a warning when the fallback is exercised.

### Role change after issuance

When a user's roles are modified (e.g. via `POST /api/v1/users/:id/roles`):

```
// Changing user_roles does NOT affect existing api_tokens.roles[].
UPDATE user_roles SET role_id = $new_role WHERE user_id = $user_id;
// No trigger, no cascade, no API token update.
```

Result:
- The token still carries its original snapshot.
- The user must obtain a new token (revoke + re-issue) to pick up the new roles.
- This is by design: it prevents a privilege-escalation race where an admin unknowingly grants elevated access to all active sessions.

### Token re-issue

To pick up new roles, the user or admin must:
1. Revoke the existing token (sets `api_tokens.revoked_at`).
2. Issue a new token (which snapshots the current `user_roles`).

There is no "refresh roles" endpoint — re-issue is the only mechanism.

---

## Public interface changes

### `src/identity/service.zig` — token creation

The token creation function signature should explicitly document the snapshot behaviour:

```zig
/// Create a new API token for the given user.
///
/// Roles are SNAPSHOTTED from `user_roles` at call time and stored
/// immutably in `api_tokens.roles_json`. Subsequent changes to the
/// user's role assignments do NOT affect this token's effective roles.
/// To pick up new roles, the token must be revoked and re-issued.
///
/// `roles_json` column is populated with a JSON array of role name strings.
/// If the user has no roles, the snapshot is `["VIEWER"]` (minimum grant).
pub fn createApiToken(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    user_id: []const u8,
    description: []const u8,
    expires_at: ?i64,
) (CreateApiTokenError)!ApiToken;
```

### `src/api/middleware/auth.zig` — role resolution (no code change, documentation only)

The existing code already reads from `api_tokens.roles_json` first. The ISS-404 requirement confirms this is the correct behaviour and clarifies that the fallback to `user_roles` is a legacy compatibility path for pre-existing tokens, NOT the intended path for newly issued tokens.

---

## Data flow

```
Token issuance:
  user_roles (live) ──► snapshot ──► api_tokens.roles_json
                                            │
                                            ▼
              [token is issued with frozen roles]

Token validation (every request):
  Authorization: Bearer <token>
         │
         ▼
  auth.authenticate()
         │
         ▼
  SELECT roles_json FROM api_tokens WHERE token_hash = $1
         │
         ▼
  Parse roles from JSON array ──► AuthContext.role

Role change (separate admin action):
  UPDATE user_roles ...
         │
         ▼
  [existing api_tokens.roles[] are NOT updated]
  [user must re-issue token to pick up new roles]
```

---

## Error taxonomy

No new error types. The snapshot is a best-effort operation during token creation; if `user_roles` query fails, the token creation fails with the existing `PersistenceFailed` error.

---

## Key invariants

1. **Token roles are immutable after issuance.** No code path modifies `api_tokens.roles_json` after the initial INSERT.
2. **Token validation reads from the snapshot.** The `authenticate()` function reads `api_tokens.roles_json` and never queries `user_roles` when the snapshot is non-empty.
3. **user_roles changes do not cascade.** There are no triggers, listeners, or scheduled jobs that propagate `user_roles` changes to `api_tokens`.
4. **Minimum grant:** a token issued when the user has no roles stores `["VIEWER"]`, ensuring the token has at least one valid role.
5. **Re-issue = new token.** The only way to change the effective roles of a session is to revoke the old token and create a new one with a fresh snapshot.

---

## Test implications

The following test scenarios are specified for ISS-404:

1. **Snapshot match at issuance:** Issue a token for a user with roles `["TASK_WORKER", "VIEWER"]`. Assert `api_tokens.roles_json` contains exactly those roles. Authenticate with the token; assert `AuthContext.role` matches the snapshot.

2. **Post-issuance role change does not affect token:** Issue a token. Modify the user's `user_roles` (e.g. promote from TASK_WORKER to PROCESS_OPERATOR). Authenticate with the same token; assert the role is still TASK_WORKER (the original snapshot).

3. **Re-issue picks up new roles:** After changing `user_roles`, revoke the old token and issue a new one. Authenticate with the new token; assert the role matches the updated `user_roles`.

---

## Dependencies

- `src/identity/registry.zig` — `user_roles` table access (read roles at issuance time).
- `src/api/middleware/auth.zig` — `authenticate()` role resolution (already reads from snapshot).
- `src/identity/service.zig` — token creation (must snapshot roles).
- Existing `api_tokens.roles_json` column (migration 008_identity.sql).

---

## Open questions

None. The design codifies the existing behaviour with explicit documentation and test coverage.

