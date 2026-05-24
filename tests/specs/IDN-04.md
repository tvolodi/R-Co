# Test Spec: IDN-04 - API token management

**Requirement:** IDN-04 - Authorised PLATFORM_ADMINs SHALL be able to issue, list, and revoke API tokens scoped to a specific user and role set. Tokens SHALL carry an optional expiry. Once issued, token values are shown only once and are not retrievable again.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-IDN-04-01: POST /tokens returns one-time token value and persists only hash
**Given:** A valid PLATFORM_ADMIN actor and an ACTIVE target user
**When:** `POST /tokens` is called with valid `user_id`, non-empty `roles`, and no `expires_at`
**Then:** HTTP 201 is returned with `token_id` and `token_value`; database stores SHA-256 hash in `api_tokens.token_hash`; `GET /tokens` never includes `token_value`
**Layer:** integration
**Acceptance criterion mapped:** POST /tokens returns 201 and one-time token value; token values are stored as cryptographic hash and never retrievable from list APIs

### TC-IDN-04-02: POST /tokens rejects past expires_at
**Given:** A valid PLATFORM_ADMIN actor and an ACTIVE target user
**When:** `POST /tokens` is called with `expires_at` in the past
**Then:** HTTP 422 is returned
**Layer:** integration
**Acceptance criterion mapped:** Edge case: creating a token with `expires_at` in the past is rejected with HTTP 422

### TC-IDN-04-03: DELETE /tokens/:id revokes immediately for subsequent requests
**Given:** A valid issued token that authenticates successfully
**When:** `DELETE /tokens/:id` is called and then the same token is used again
**Then:** DELETE returns HTTP 204 (idempotent on repeat); subsequent auth returns HTTP 401
**Layer:** integration
**Acceptance criterion mapped:** Revocation is immediate for subsequent requests; revoked token use returns 401

### TC-IDN-04-04: Expired token is rejected with 401
**Given:** A token row whose `expires_at` is in the past
**When:** The token is used via Bearer authentication
**Then:** Authentication fails with HTTP 401
**Layer:** integration
**Acceptance criterion mapped:** Expired token is rejected with HTTP 401 on use

### TC-IDN-04-05: Optional expires_at and role-claim authorization interactions
**Given:** A token issued without `expires_at` and role claims `[TASK_WORKER, PROCESS_OPERATOR]`
**When:** The token is used for authentication
**Then:** Authentication succeeds; role claims are honored (primary role resolves to PROCESS_OPERATOR); invalid role claims are rejected with HTTP 401
**Layer:** integration
**Acceptance criterion mapped:** `expires_at` optional means token remains valid until revoked; role claims are validated in auth flow

### TC-IDN-04-06: Token endpoints are PLATFORM_ADMIN-only
**Given:** A non-admin caller (TASK_WORKER)
**When:** The caller attempts `POST /tokens`, `GET /tokens`, and `DELETE /tokens/:id`
**Then:** Each endpoint returns HTTP 403
**Layer:** integration
**Acceptance criterion mapped:** Only authorised PLATFORM_ADMIN callers may issue, list, and revoke tokens
