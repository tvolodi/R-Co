# Test Spec: OIDC-21 — Agent token rotation

**Requirement:** OIDC-21 — Agent client secrets are rotatable with overlap grace period and eventual old-secret invalidation.

**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-OIDC-21-01: Rotation overlap rows are discoverable for finalization
**Given:** A rotation record with status OVERLAP and expired old_secret_valid_until
**When:** Pending-finalization rows are queried
**Then:** Rotation appears as pending for finalization
**Layer:** integration
**Acceptance criterion mapped:** In-flight overlap behavior is represented without interruption window

### TC-OIDC-21-02: Finalized rotation removes row from overlap pending set
**Given:** An overlap rotation record
**When:** Status transitions to FINALIZED
**Then:** Query for expired OVERLAP rows no longer returns the record
**Layer:** integration
**Acceptance criterion mapped:** Old secret invalidates after grace period

### TC-OIDC-21-03: Rotation state machine only accepts declared statuses
**Given:** agent_secret_rotation status constraints
**When:** Invalid status insertion is attempted
**Then:** Insert is rejected by DB constraints
**Layer:** integration
**Acceptance criterion mapped:** Rotation lifecycle is deterministic and safe
