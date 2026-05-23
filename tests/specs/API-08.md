# Test Spec: API-08 — Bearer token auth

**Requirement:** API-08 — All API endpoints SHALL require a Bearer token in the `Authorization` header. Requests without a valid token MUST receive HTTP 401. Requests with insufficient permissions MUST receive HTTP 403. See bootstrapping note for Stage 4 testing.
**Priority:** MUST
**Test layer:** unit, integration

## Test Cases

### TC-API-08-01: Missing Authorization header → HTTP 401 + WWW-Authenticate

**Given:**
- The auth middleware has been initialised (`init()` called successfully).
- A request arrives with no `Authorization` header (`authorization_header` is `null`).
- No bootstrap token is configured.

**When:**
- `authenticate(allocator, null, &pool)` is called.

**Then:**
- Returns `AuthResult.unauthenticated` with:
  - `status_code` = 401
  - `body` contains RFC 9457 Problem Details JSON with:
    - `"type": "https://bpm.example.com/problems/unauthorized"`
    - `"title": "Unauthorized"`
    - `"status": 401`
    - `"detail": "missing Authorization header"`

**Layer:** unit
**Acceptance criterion mapped:** AC1 — GIVEN a request to any platform endpoint without an `Authorization` header, THEN HTTP 401 is returned with a `WWW-Authenticate: Bearer` header.

**Note:** The `WWW-Authenticate` header is the HTTP server's responsibility (set when status_code=401); this test verifies the middleware produces the correct status and body. The header instruction is validated in integration tests.

---

### TC-API-08-02: Malformed header (no Bearer prefix) → HTTP 401

**Given:**
- The auth middleware has been initialised.
- A request arrives with `Authorization: Basic YWxhZGRpbjpvcGVuIHNlc2FtZQ==` (no `Bearer ` prefix).
- No bootstrap token is configured.

**When:**
- `authenticate(allocator, "Basic YWxhZGRpbjpvcGVuIHNlc2FtZQ==", &pool)` is called.

**Then:**
- Returns `AuthResult.unauthenticated` with:
  - `status_code` = 401
  - `detail` = "malformed Authorization header; expected Bearer token"

**Layer:** unit
**Acceptance criterion mapped:** Edge case — Token present but `Bearer` prefix missing: HTTP 401 (malformed header).

---

### TC-API-08-02b: Empty Bearer token → HTTP 401

**Given:**
- The auth middleware has been initialised.
- A request arrives with `Authorization: Bearer ` (no token after prefix).

**When:**
- `authenticate(allocator, "Bearer ", &pool)` is called.

**Then:**
- Returns `AuthResult.unauthenticated` with:
  - `status_code` = 401
  - `detail` = "empty Bearer token"

**Layer:** unit
**Acceptance criterion mapped:** Edge case — empty token after `Bearer ` prefix still fails authentication.

---

### TC-API-08-03: Unknown/revoked token → HTTP 401

**Given:**
- The auth middleware has been initialised.
- A PostgreSQL database is seeded with `api_tokens` rows (via migration 008_identity.sql).
- A request arrives with `Authorization: Bearer <token>` where `<token>` is NOT in the `api_tokens` table (unknown), OR the matching row has `revoked_at IS NOT NULL`.

**When:**
- `authenticate(allocator, "Bearer <unknown-token>", &pool)` is called.

**Then:**
- Returns `AuthResult.unauthenticated` with:
  - `status_code` = 401
  - `detail` = "unknown token" or "token revoked"

**Layer:** integration
**Acceptance criterion mapped:** AC2 — GIVEN a request with `Authorization: Bearer <token>` where the token is unknown or revoked, THEN HTTP 401 is returned.

---

### TC-API-08-04: Valid bootstrap token → authenticated as PLATFORM_ADMIN

**Given:**
- `BPM_ENV` ≠ `"production"` (e.g., `"development"`).
- `BPM_BOOTSTRAP_TOKEN` is set to `"my-bootstrap-token"`.
- `init()` has been called, which hashed and stored the bootstrap token.

**When:**
- `authenticate(allocator, "Bearer my-bootstrap-token", &pool)` is called.

**Then:**
- Returns `AuthResult.authenticated` with:
  - `user_id` = `"00000000-0000-0000-0000-000000000000"` (nil UUID)
  - `role` = `Role.PLATFORM_ADMIN`
  - `is_bootstrap` = `true`

**Layer:** unit
**Acceptance criterion mapped:** AC4 — GIVEN `BPM_ENV ≠ production` and `BPM_BOOTSTRAP_TOKEN` is set, THEN requests with that token are accepted with PLATFORM_ADMIN role.

---

### TC-API-08-05: Valid token but insufficient role → HTTP 403

**Given:**
- A real PostgreSQL database with a user assigned the `VIEWER` role and a valid `api_token`.
- A request arrives with `Authorization: Bearer <viewer-token>` targeting an endpoint that requires `PROCESS_DESIGNER`.

**When:**
- `authenticate()` succeeds (returns `.authenticated` with `role=VIEWER`), then the RBAC middleware checks against the required role.

**Then:**
- The RBAC middleware returns HTTP 403.

**Layer:** integration
**Acceptance criterion mapped:** AC3 — GIVEN a request with a valid token but the caller's role does not permit the operation, THEN HTTP 403 is returned.

---

### TC-API-08-06: Valid token with sufficient role → pass through

**Given:**
- A real PostgreSQL database with a user assigned the `PROCESS_DESIGNER` role and a valid `api_token`.
- A request arrives with `Authorization: Bearer <designer-token>` targeting an endpoint that requires `PROCESS_DESIGNER`.

**When:**
- `authenticate()` succeeds (returns `.authenticated` with `role=PROCESS_DESIGNER`), then the RBAC middleware checks against the required role.

**Then:**
- Request passes through to the route handler.

**Layer:** integration
**Acceptance criterion mapped:** AC3 — demonstrates the positive path where the role is sufficient.

---

### TC-API-08-07: BPM_BOOTSTRAP_TOKEN in production → fatal startup error

**Given:**
- `BPM_ENV` = `"production"`.
- `BPM_BOOTSTRAP_TOKEN` is set to any non-empty value (e.g., `"dangerous"`).

**When:**
- `init(allocator)` is called.

**Then:**
- Returns `AuthError.BootstrapTokenInProduction`.
- The auth module does NOT store a bootstrap hash.
- `bootstrap_hash` remains `null`.

**Layer:** unit
**Acceptance criterion mapped:** AC5 — GIVEN `BPM_ENV=production` and `BPM_BOOTSTRAP_TOKEN` is set, THEN the platform MUST refuse to start (fatal error).

---

### TC-API-08-08: Empty bootstrap token → treated as not set

**Given:**
- `BPM_ENV` = `"development"`.
- `BPM_BOOTSTRAP_TOKEN` is set to an empty string `""`.

**When:**
- `init(allocator)` is called.

**Then:**
- `init()` returns successfully (no error).
- Bootstrap auth is disabled; `bootstrap_hash` is `null`.
- A call to `authenticate(allocator, "Bearer any-token", &pool)` does NOT match the bootstrap token (falls through to DB lookup, which would fail but that's not tested here).

**Layer:** unit
**Acceptance criterion mapped:** Edge case — `BPM_BOOTSTRAP_TOKEN` set to an empty string: treated as not set; bootstrap auth disabled.

---

### TC-API-08-09: Whitespace in Authorization header → normalised

**Given:**
- The auth middleware has been initialised with a bootstrap token `"my-token"`.
- A request arrives with `Authorization:   Bearer my-token   ` (leading and trailing whitespace).

**When:**
- `authenticate(allocator, "  Bearer my-token  ", &pool)` is called.

**Then:**
- Returns `AuthResult.authenticated` (whitespace trimmed before prefix matching).

**Layer:** unit
**Acceptance criterion mapped:** Robustness — RFC 7230 §3.2.6 allows optional whitespace around header values.

---

## Coverage Summary

| Test Case | Layer | Requirement mapping |
|---|---|---|
| TC-API-08-01 | unit | AC1 — missing header → 401 |
| TC-API-08-02 | unit | Edge — malformed header (no Bearer prefix) |
| TC-API-08-02b | unit | Edge — empty Bearer token |
| TC-API-08-03 | integration | AC2 — unknown/revoked token → 401 |
| TC-API-08-04 | unit | AC4 — bootstrap token → PLATFORM_ADMIN |
| TC-API-08-05 | integration | AC3 — insufficient role → 403 |
| TC-API-08-06 | integration | AC3 — sufficient role → pass |
| TC-API-08-07 | unit | AC5 — production + bootstrap = fatal error |
| TC-API-08-08 | unit | Edge — empty bootstrap = disabled |
| TC-API-08-09 | unit | Robustness — whitespace-trimmed header |
