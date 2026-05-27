# Test Spec: OIDC-15 — Realm deletion safety

**Requirement:** OIDC-15 — Realm deletion via the adapter MUST be a two-step operation: mark for deletion (no new tokens issued, existing tokens accepted until expiry), then hard delete (after a configurable grace period, default 7 days).

**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-15-01: RealmDeletionStatus roundtrip
**Given:** All `RealmDeletionStatus` enum values: ACTIVE, MARKED_FOR_DELETION, DELETING, DELETED
**When:** String roundtrip via `fromString` and `asString`
**Then:** Each value converts to and from its string representation correctly; "UNKNOWN" returns null
**Layer:** unit
**Acceptance criterion mapped:** Mark for deletion then hard delete after grace period

### TC-OIDC-15-02: GRACE_PERIOD_DEFAULT_SECONDS is 7 days
**Given:** The constant `GRACE_PERIOD_DEFAULT_SECONDS`
**When:** Its value is inspected
**Then:** It equals `604800` which is `7 * 24 * 60 * 60`
**Layer:** unit
**Acceptance criterion mapped:** Mark for deletion then hard delete after a configurable grace period, default 7 days

### TC-OIDC-15-03: insertDeletionTracker creates tracker row
**Given:** A realm is marked for deletion
**When:** `insertDeletionTracker` is called with valid input
**Then:** A new row is inserted into `realm_deletion_tracker` with status `MARKED_FOR_DELETION`
**Layer:** integration
**Acceptance criterion mapped:** Mark for deletion then hard delete after grace period

### TC-OIDC-15-04: insertDeletionTracker is idempotent on conflict
**Given:** Two concurrent mark-deletion attempts for the same realm
**When:** `insertDeletionTracker` is called twice
**Then:** The second call succeeds gracefully (ON CONFLICT DO NOTHING) without error
**Layer:** integration
**Acceptance criterion mapped:** Mark for deletion then hard delete after grace period

### TC-OIDC-15-05: releaseTenantBinding clears idp_realm_id
**Given:** A tenant has `idp_realm_id` pointing to a realm being hard-deleted
**When:** `releaseTenantBinding` is called with that realm_id
**Then:** The tenant's `idp_realm_id` is set to NULL
**Layer:** integration
**Acceptance criterion mapped:** Hard deletion is irreversible and audit-logged

### TC-OIDC-15-06: markTrackerDeleted updates status to DELETED
**Given:** A `realm_deletion_tracker` row exists with status `MARKED_FOR_DELETION`
**When:** `markTrackerDeleted` is called
**Then:** The row's status is updated to `DELETED` and `hard_deleted_at` is set
**Layer:** integration
**Acceptance criterion mapped:** Hard deletion is irreversible and audit-logged

### TC-OIDC-15-07: markUsersInactiveByRealm updates affected OIDC users
**Given:** Users with `auth_source = 'oidc'` and `external_realm` matching the deleted realm
**When:** `markUsersInactiveByRealm` is called
**Then:** Those users have `status = 'INACTIVE'` and `is_active = false`
**Layer:** integration
**Acceptance criterion mapped:** Hard deletion is irreversible and audit-logged

### TC-OIDC-15-08: queryPendingHardDeletions returns eligible entries
**Given:** Multiple `realm_deletion_tracker` entries, some with `hard_delete_after <= NOW()`
**When:** `queryPendingHardDeletions` is called
**Then:** Only entries past their grace period are returned, ordered by `hard_delete_after`
**Layer:** integration
**Acceptance criterion mapped:** Mark for deletion then hard delete after grace period

### TC-OIDC-15-09: incrementRetryCount increments retry counter
**Given:** A `realm_deletion_tracker` row exists
**When:** `incrementRetryCount` is called
**Then:** The `retry_count` is incremented by 1 and `last_retry_at` is updated
**Layer:** integration
**Acceptance criterion mapped:** Mark for deletion then hard delete after grace period
