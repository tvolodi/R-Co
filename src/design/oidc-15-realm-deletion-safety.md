# Module: OIDC-15 Realm Deletion Safety

## Module purpose

This module defines the two-phase realm deletion protocol that prevents accidental or irreversible data loss at the identity provider. Realm deletion proceeds through a soft "mark for deletion" phase (no new tokens issued; existing tokens accepted until expiry), followed by a configurable grace period (default 7 days), after which a hard delete irreversibly removes all provider-side realm data. Both phases are recorded in the audit log per OBS-03 and ADP-09.

## Public interface

### Realm deletion lifecycle management

```zig
/// Status of a realm in the deletion lifecycle.
pub const RealmDeletionStatus = enum {
    /// Realm is active — normal operation.
    ACTIVE,
    /// Realm is marked for deletion — no new logins, existing sessions
    /// continue until token expiry.
    MARKED_FOR_DELETION,
    /// Hard deletion is in progress.
    DELETING,
    /// Realm has been hard-deleted from the provider.
    DELETED,
};

/// Input for marking a realm for deletion (phase 1).
pub const MarkForDeletionInput = struct {
    /// The IdP realm identifier to mark.
    realm_id: []const u8,
    /// Who initiated the deletion (for audit).
    actor_id: []const u8,
    /// Reason for deletion (for audit).
    reason: []const u8,
    /// Grace period in seconds before hard delete is allowed.
    /// Default: 604800 (7 days).
    grace_period_seconds: u64 = GRACE_PERIOD_DEFAULT_SECONDS,
};

/// Result of marking a realm for deletion.
pub const MarkForDeletionResult = struct {
    realm_id: []const u8,
    deletion_status: RealmDeletionStatus,
    /// The timestamp after which hard deletion is allowed.
    hard_delete_after: i64,
    /// Number of currently active sessions (approximate, from provider).
    active_session_count: u64,
};

/// Input for hard-deleting a realm (phase 2).
pub const HardDeleteRealmInput = struct {
    /// The IdP realm identifier to hard-delete.
    realm_id: []const u8,
    /// Who initiated the deletion (for audit).
    actor_id: []const u8,
    /// Force deletion even if grace period has not elapsed.
    /// Only allowed for PLATFORM_ADMIN.
    force: bool,
};

/// Result of hard-deleting a realm.
pub const HardDeleteRealmResult = struct {
    realm_id: []const u8,
    deletion_status: RealmDeletionStatus.DELETED,
    /// Timestamp of the hard deletion.
    deleted_at: i64,
    /// True if the tenant binding was also removed.
    tenant_binding_released: bool,
};
```

### Phase 1: Mark for deletion

```zig
/// Mark a realm for deletion.
///
/// This phase disables the realm at the provider so that:
///   - The provider rejects new authentication attempts (login page shows
///     "realm disabled" or similar).
///   - Existing bearer tokens remain valid until their natural expiry.
///   - Token refresh is denied (new tokens are not issued for the realm).
///   - Admin REST API still works for reading realm data and performing
///     the hard-delete later.
///
/// Implementation in the Keycloak adapter (realm_api.zig):
///   PUT /admin/realms/{realm}
///   Body: { "enabled": false }
///
/// The adapter should also update the realm's display name to include
/// a "[MARKED FOR DELETION - yyyy-mm-dd]" suffix for visibility in the
/// Keycloak admin console.
///
/// After marking, the adapter records:
///   - The grace period deadline in the BPM database (realm_deletion_tracker table).
///   - An audit event of type REALM_MARKED_FOR_DELETION (OBS-03, ADP-09).
///
/// Error cases:
///   - RealmNotFound: The realm does not exist at the provider.
///   - AlreadyMarked: The realm is already in MARKED_FOR_DELETION status.
///   - ActiveTenantBound: The realm is bound to a tenant that still has
///     active process instances. Deletion must be refused until all
///     instances complete or are cancelled (policy decision — see open
///     questions).
///   - UpstreamUnavailable / UnauthorizedAdminCall / UpstreamProtocolError.
pub fn markRealmForDeletion(
    allocator: std.mem.Allocator,
    pool: *Pool,
    provider: *IdentityProvider,
    audit_writer: *AuditWriter,
    input: MarkForDeletionInput,
) MarkForDeletionError!MarkForDeletionResult;
```

### Phase 2: Hard delete

```zig
/// Hard-delete a previously marked realm.
///
/// This phase irreversibly removes all realm data from the provider:
///   - Users, groups, roles, clients, authentication flows, keys, etc.
///   - All event logs and admin audit data for the realm.
///   - Realm is permanently removed from the provider.
///
/// Preconditions:
///   1. The realm MUST be in MARKED_FOR_DELETION status.
///   2. The grace period MUST have elapsed (unless force=true with
///      PLATFORM_ADMIN authorization).
///
/// Implementation in the Keycloak adapter (realm_api.zig):
///   DELETE /admin/realms/{realm}
///
/// The adapter MUST verify the realm is disabled (enabled=false)
/// before issuing the DELETE, as a safety check.
///
/// After deletion, the adapter:
///   1. Clears the tenant's idp_realm_id binding OR sets it to NULL
///      (policy decision — see open questions).
///   2. Records an audit event of type REALM_HARD_DELETED (OBS-03, ADP-09).
///   3. Removes or archives the realm_deletion_tracker record.
///
/// Error cases:
///   - RealmNotFound: Realm already deleted or never existed.
///   - NotMarkedForDeletion: Realm is still ACTIVE — caller must
///     mark it first.
///   - GracePeriodNotElapsed: Attempted hard delete before grace period
///     ended without force=true.
///   - ProviderSideDeletionFailed: Keycloak returned an error during
///     DELETE (non-transient — realm may be in an inconsistent state).
///   - UpstreamUnavailable / UnauthorizedAdminCall / UpstreamProtocolError.
pub fn hardDeleteRealm(
    allocator: std.mem.Allocator,
    pool: *Pool,
    provider: *IdentityProvider,
    audit_writer: *AuditWriter,
    input: HardDeleteRealmInput,
) HardDeleteError!HardDeleteRealmResult;
```

### Grace period scheduler

```zig
/// Scheduler check for pending hard-deletions.
///
/// This function is called by the background scheduler (scheduler.zig)
/// periodically (e.g., every hour). It queries the realm_deletion_tracker
/// table for entries where:
///   - status = 'MARKED_FOR_DELETION'
///   - hard_delete_after <= NOW()
///
/// For each eligible entry, it calls hardDeleteRealm.
///
/// Failed deletions are re-queued (up to max_retries, then logged for
/// manual intervention).
pub fn processPendingHardDeletions(
    allocator: std.mem.Allocator,
    pool: *Pool,
    provider: *IdentityProvider,
    audit_writer: *AuditWriter,
) ProcessError!ProcessResult;

pub const ProcessResult = struct {
    processed: u32,
    succeeded: u32,
    failed: u32,
    skipped: u32,
};
```

### Query realm deletion status

```zig
/// Input for querying a realm's deletion status.
pub const RealmDeletionStatusInput = struct {
    realm_id: []const u8,
};

/// Query the current deletion status of a realm.
///
/// Returns null if no deletion tracker entry exists for this realm
/// (i.e., it is an active realm that has never been marked).
pub fn queryDeletionStatus(
    allocator: std.mem.Allocator,
    pool: *Pool,
    input: RealmDeletionStatusInput,
) LookupError!?RealmDeletionTrackerEntry;
```

### Error taxonomy

```zig
pub const MarkForDeletionError = error{
    RealmNotFound,
    AlreadyMarked,
    ActiveTenantBound,
    UpstreamUnavailable,
    UnauthorizedAdminCall,
    UpstreamProtocolError,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

pub const HardDeleteError = error{
    RealmNotFound,
    NotMarkedForDeletion,
    GracePeriodNotElapsed,
    ProviderSideDeletionFailed,
    UpstreamUnavailable,
    UnauthorizedAdminCall,
    UpstreamProtocolError,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};
```

## Data types

### Realm deletion tracker (new DB table)

```zig
/// Persistent tracking record for realm deletion lifecycle.
pub const RealmDeletionTrackerEntry = struct {
    /// The realm identifier being deleted.
    realm_id: []const u8,
    /// Current status in the deletion lifecycle.
    status: RealmDeletionStatus,
    /// When the realm was marked for deletion (Unix epoch seconds).
    marked_at: i64,
    /// Who initiated the deletion.
    marked_by: []const u8,
    /// Reason for deletion.
    reason: []const u8,
    /// Grace period duration in seconds.
    grace_period_seconds: u64,
    /// Timestamp after which hard deletion is permitted (Unix epoch seconds).
    hard_delete_after: i64,
    /// When the realm was actually hard-deleted (null if not yet deleted).
    hard_deleted_at: ?i64,
    /// Number of retry attempts for hard deletion.
    retry_count: u32,
    /// Timestamp of the last retry attempt.
    last_retry_at: ?i64,
    /// Additional metadata (JSON).
    metadata_json: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};
```

## Key invariants

1. **Two-phase protocol is mandatory.** A realm MUST NOT be hard-deleted without first being marked for deletion. The adapter MUST verify `enabled=false` before issuing the DELETE. The `NotMarkedForDeletion` error prevents accidental one-step deletion.

2. **Tokens issued before marking remain valid until expiry.** Disabling the realm prevents new logins and refresh token issuance, but existing access tokens retain their validity. This ensures in-flight process executions are not interrupted mid-step.

3. **Grace period is configurable per realm.** Default 7 days (604800 seconds). The grace period starts from `marked_at`, not from when the first token expires. Platform operators can shorten it (e.g., 24h for test realms) or extend it (e.g., 30 days for production realms).

4. **Active tenant with running instances blocks marking.** If the tenant bound to the realm (OIDC-12) has active (non-terminal) process instances, `markRealmForDeletion` MUST return `ActiveTenantBound`. The operator must first cancel or complete all instances. This prevents data loss for in-flight processes.

5. **Hard deletion is irreversible.** After hard deletion, all provider-side realm data (users, groups, roles, clients, keys, sessions, events) is permanently removed. The BPM platform retains its own user records (with `auth_source = 'oidc'` but `external_id` still point to the now-nonexistent provider identity). A reconciliation process may be needed to mark OIDC users from deleted realms as INACTIVE.

6. **All steps are audit-logged.** Both mark and hard-delete emit audit events:
   - `REALM_MARKED_FOR_DELETION`: `{ realm_id, marked_by, reason, grace_period_seconds, hard_delete_after }`
   - `REALM_HARD_DELETED`: `{ realm_id, deleted_at, tenant_binding_released }`

## DB tables/columns touched

### New table: `realm_deletion_tracker`

```sql
CREATE TABLE IF NOT EXISTS realm_deletion_tracker (
    realm_id TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'MARKED_FOR_DELETION'
        CHECK (status IN ('MARKED_FOR_DELETION', 'DELETING', 'DELETED')),
    marked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    marked_by UUID NOT NULL,
    reason TEXT NOT NULL DEFAULT '',
    grace_period_seconds BIGINT NOT NULL DEFAULT 604800,
    hard_delete_after TIMESTAMPTZ NOT NULL,
    hard_deleted_at TIMESTAMPTZ,
    retry_count INT NOT NULL DEFAULT 0,
    last_retry_at TIMESTAMPTZ,
    metadata_json JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for the grace-period scheduler query.
CREATE INDEX IF NOT EXISTS idx_realm_deletion_tracker_pending
ON realm_deletion_tracker (status, hard_delete_after)
WHERE status = 'MARKED_FOR_DELETION';
```

### Tenant binding release

When a realm is hard-deleted, the tenant's `idp_realm_id` should be set to NULL (releasing the binding). This allows the tenant to be re-provisioned with a new realm later.

```sql
UPDATE tenant
SET idp_realm_id = NULL, updated_at = NOW()
WHERE idp_realm_id = $1;
```

## Data flow

```mermaid
flowchart TD
    subgraph Phase1 [Phase 1: Mark for Deletion]
        A[Admin/Agent requests deletion] --> B[markRealmForDeletion]
        B --> C{Active process instances?}
        C -->|Yes| D[return ActiveTenantBound error]
        C -->|No| E[PUT /admin/realms/{realm} enabled=false]
        E --> F[Insert realm_deletion_tracker row]
        F --> G[Emit REALM_MARKED_FOR_DELETION audit event]
        G --> H[Return MarkForDeletionResult]
    end

    subgraph GracePeriod [Grace Period (default 7 days)]
        I[Token expiry check] --> J{Token from marked realm?}
        J -->|Yes, within expiry| K[Accept — token was issued before mark]
        J -->|Yes, expired| L[Reject — require re-auth]
        J -->|No| M[Normal flow]
    end

    subgraph Phase2 [Phase 2: Hard Delete]
        N[processPendingHardDeletions scheduler]
        O{hard_delete_after <= NOW()?}
        N --> O
        O -->|Yes| P[hardDeleteRealm]
        O -->|No| Q[Wait for next scheduler tick]
        P --> R{Realm enabled=false?}
        R -->|No| S[Abort — safety check failed]
        R -->|Yes| T[DELETE /admin/realms/{realm}]
        T --> U[Clear tenant idp_realm_id]
        U --> V[Update tracker status to DELETED]
        V --> W[Emit REALM_HARD_DELETED audit event]
    end
```

## Cross-module dependencies

### This module calls / depends on:

| Module | Why |
|---|---|
| `src/identity/provider/interface.zig` | `IdentityProvider` contract (the adapter implements the REST calls) |
| `src/identity/provider/adapters/keycloak/realm_api.zig` | Keycloak-specific enable/disable and DELETE realm calls |
| `src/identity/provider/adapters/keycloak/admin_token.zig` | Admin bearer token for REST calls |
| `src/db/pool.zig` | Database access for `realm_deletion_tracker` CRUD and tenant binding release |
| `src/obs/audit.zig` | Audit event emission for both phases |
| `src/scheduler/scheduler.zig` | Background task for grace-period expiry processing |
| OIDC-12 module | `resolveTenantByRealm` — to check for active instances before marking |

### This module must NOT depend on:

| Module | Why |
|---|---|
| `src/oidc/jit_provisioning.zig` | JIT provisioning is irrelevant for deletion |
| `src/api/routes/*.zig` | Route handlers call this module, not the other way around |
| `src/engine/transition.zig` | No engine dependency — deletion policy is administrative |

## Identified risks / open questions

1. **Active instance check scope.** `markRealmForDeletion` checks for active process instances in the tenant bound to the realm. The check must cover all instance states that are non-terminal (RUNNING, SUSPENDED, WAITING, etc.). Terminal states (COMPLETED, TERMINATED, CANCELLED) are not blockers. The exact state list must align with `InstanceState` definitions in `src/engine/state.zig`.

2. **What happens to OIDC users after hard delete?** After the realm is hard-deleted, the BPM platform's local user records (with `auth_source = 'oidc'`) still exist but their `external_id` points to a now-nonexistent identity at the provider. These users cannot authenticate (no valid IdP), so they are effectively locked out. Options:
   - Mark all affected users as INACTIVE after hard delete (recommended).
   - Leave them as-is (they cannot auth anyway, but their historical data is preserved).
   - Provide a bulk conversion path to internal users.
   
   **Recommended approach:** After hard-delete, run a batch UPDATE to set `status = 'INACTIVE'` for all users with `auth_source = 'oidc'` and `external_realm = <deleted_realm>`. This prevents stale identity references and makes the inactive state visible in the admin console.

3. **Re-provisioning a deleted realm.** After hard-delete, the tenant's `idp_realm_id` is set to NULL. A new realm can be provisioned for the tenant via OIDC-14. The new realm will have a different `idp_realm_id` (or the same name, if the old realm name is reused — the provider DELETE removes the name). Existing users from the old realm will have stale `external_id` values — a bulk migration process is needed to re-link them to the new realm's user records.

4. **Force-deletion safety.** The `force` flag on `hardDeleteRealmInput` allows a PLATFORM_ADMIN to bypass the grace period. This is a dangerous operation — it should require explicit confirmation and always emit a CRITICAL audit event. Consider a rate limit (max 1 force-deletion per hour per admin).

5. **Realm deletion and the default tenant.** The default tenant's realm (`idp_realm_id = 'bpm-default'`) must never be deletable. `markRealmForDeletion` MUST reject attempts to mark the default realm with a specific `CannotDeleteDefaultRealm` error.
