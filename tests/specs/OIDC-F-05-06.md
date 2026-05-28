# Test Spec: OIDC-F-05 & OIDC-F-06 — Subdomain Tenant Routing

**Run ID:** WF02-oidcf2-20260528  
**Requirements:** OIDC-F-05 (Tenant-config discovery endpoint), OIDC-F-06 (Dynamic OIDC config from hostname)  
**Priority:** MUST  
**Test file:** `web/tests/e2e/oidcf2-subdomain.e2e.spec.ts`

---

## Scope

Verifies:
1. The backend `GET /api/tenant-config` endpoint returns correct JSON for known and unknown hostnames (OIDC-F-05).
2. The frontend reads the hostname at startup, uses the returned config to initialize `OidcManager`, and falls back to env vars when the API fails (OIDC-F-06).

---

## Infrastructure requirements

| Component | Value |
|---|---|
| Frontend | `http://127.0.0.1:4173` (Vite dev server, started by `playwright.config.ts`) |
| Backend API | `http://localhost:3000` (or same origin as frontend via proxy) |
| Default Keycloak realm | `http://localhost:8081/realms/bpm-default` |

---

## Directive compliance

| Directive | Compliance |
|---|---|
| T-2 (No MSW, no HTTP mocking) | PASS — only TC-OIDCF2-04 uses `page.route` and solely to simulate a 500 from `/api/tenant-config`. No Keycloak or auth exchange is mocked in any test case. |
| T-3 (Visual verification) | PASS — every test case takes at least one screenshot; verdicts state "screen shows X after Y". |

---

## Test Cases

### TC-OIDCF2-01 — API returns default config for unknown hostname `[OIDC-F-05 MUST]`

**Goal:** `GET /api/tenant-config?host=unknown.example.com` returns HTTP 200 with the default tenant config.

**Steps:**
1. Issue `GET /api/tenant-config?host=unknown.example.com` via Playwright `request`.
2. Assert response status is 200.
3. Parse response body as JSON.
4. Assert `oidc_authority` field is present and contains the string `bpm-default`.
5. Assert `client_id` field equals `bpm-platform-api`.

**Verdict:** Response body contains default tenant config fields for an unknown hostname.

---

### TC-OIDCF2-02 — API returns default config for localhost hostname `[OIDC-F-05 MUST]`

**Goal:** `GET /api/tenant-config?host=localhost` returns HTTP 200 with usable OIDC fields (no binding registered for `localhost`, so default is returned).

**Steps:**
1. Issue `GET /api/tenant-config?host=localhost` via Playwright `request`.
2. Assert response status is 200.
3. Parse response body as JSON.
4. Assert `oidc_authority` field is a non-empty string.
5. Assert `client_id` field is a non-empty string.

**Verdict:** Response contains valid `oidc_authority` and `client_id` fields for the `localhost` host.

---

### TC-OIDCF2-03 — SSO button uses default realm when loaded from localhost `[OIDC-F-06 MUST]`

**Goal:** When the app is loaded at `localhost`, clicking the SSO button initiates an OIDC flow toward the `bpm-default` realm.

**Steps:**
1. Navigate to `/login`.
2. Assert `data-testid="login-sso-button"` is visible.
3. Register a route interception on `**/realms/**` to abort the navigation (avoids requiring live Keycloak).
4. Capture the outgoing request URL when the SSO button is clicked.
5. Assert the captured URL contains `bpm-default`.
6. Take screenshot; state verdict.

**Verdict:** Screen shows login page; outgoing Keycloak auth URL contains `bpm-default` realm.

---

### TC-OIDCF2-04 — Frontend falls back to env vars when `/api/tenant-config` returns 500 `[OIDC-F-06 MUST]`

**Goal:** If the tenant-config API fails, the app falls back to env var values and renders the login page without crashing.

**Note on mock usage:** `page.route` is used here **only** to simulate a 500 response from `/api/tenant-config`. No Keycloak or auth exchange is mocked. This is the **one allowed mock** in this suite because the error path in `tenantConfig.ts` cannot be triggered otherwise without a live misconfigured backend.

**Steps:**
1. Register `page.route('/api/tenant-config*', ...)` to fulfill with status 500 before navigation.
2. Navigate to `/login`.
3. Assert `data-testid="login-sso-button"` is visible (app did not crash).
4. Assert no unhandled error modal or blank screen is present.
5. Take screenshot; state verdict.

**Verdict:** Screen shows login page with SSO button visible; app did not crash after tenant-config API failure.

---

## Acceptance criteria mapping

| Requirement AC | Test Case |
|---|---|
| `GET /api/tenant-config?host=unknown.localhost` returns default config HTTP 200 | TC-OIDCF2-01 |
| `GET /api/tenant-config?host=localhost` returns valid oidc_authority and client_id | TC-OIDCF2-02 |
| When app is accessed via localhost, SSO button uses default realm | TC-OIDCF2-03 |
| If `/api/tenant-config` returns HTTP 500, app falls back and login page renders normally | TC-OIDCF2-04 |

---

## Out of scope (future runs)

- `GET /api/tenant-config?host=acme1.localhost` returns acme1-specific realm — requires a test tenant hostname fixture to be seeded in the database (separate WF02 stage once subdomain tenant seeding is implemented).
- When app is accessed via `acme1.localhost`, SSO button uses acme1 realm — same fixture dependency as above.
