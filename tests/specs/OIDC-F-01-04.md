# Test Spec — OIDC-F-01 through OIDC-F-04

**Run:** WF02-oidcf-20260528  
**Stage:** F1.5 — OIDC SSO Login  
**Author:** TEST-DESIGNER  
**Date:** 2026-05-28

---

## Requirement Coverage

| Req ID | Priority | Test File | Test Name |
|---|---|---|---|
| OIDC-F-01 | MUST | web/tests/e2e/oidcf-login.e2e.spec.ts | TC-OIDCF-01: SSO button is visible on LoginPage |
| OIDC-F-01 | MUST | web/tests/e2e/oidcf-login.e2e.spec.ts | TC-OIDCF-02: SSO button redirects to Keycloak authorization endpoint |
| OIDC-F-02 | MUST | web/tests/e2e/oidcf-login.e2e.spec.ts | TC-OIDCF-03: Full OIDC auth flow — real Keycloak login succeeds |
| OIDC-F-02 | MUST | web/tests/e2e/oidcf-login.e2e.spec.ts | TC-OIDCF-04: Callback error redirects to /login with auth-error banner |
| OIDC-F-04 | SHOULD | web/tests/e2e/oidcf-login.e2e.spec.ts | TC-OIDCF-05: OIDC logout hits Keycloak end-session endpoint |

---

## Infrastructure Requirements

- **Frontend dev server:** `http://127.0.0.1:4173` (Vite, `npm run dev`)
- **Backend API:** `http://localhost:3000` (real server — health check endpoint must respond)
- **Keycloak:** `http://localhost:8081/realms/bpm-default` (real Keycloak instance)
- **Test users pre-configured in Keycloak:**
  - `admin-user` / `admin-pass` — role: `PLATFORM_ADMIN`
  - `designer-user` / `designer-pass` — role: `PROCESS_DESIGNER`
  - `worker-user` / `worker-pass` — role: `TASK_WORKER`
- **Keycloak client:** `bpm-platform-api` — public client with redirect URI `http://127.0.0.1:4173/auth/callback`
- **No MSW, no HTTP mocking of Keycloak or backend** (Directives T-2, T-3)

---

## Directives

- **T-2:** No MSW, no `axios-mock-adapter`, no manual `fetch` intercepts. Every test involving Keycloak or API data uses real servers.
- **T-3:** After every significant UI action, a screenshot is taken and DOM assertions verify what the screen shows. Test verdicts state "screen shows X after Y".
- **Exception (TC-OIDCF-01, TC-OIDCF-02):** These tests exercise pure frontend code paths that do not require Keycloak token exchange. TC-OIDCF-02 uses `page.waitForRequest` to capture the Keycloak redirect URL and aborts the navigation — no auth exchange occurs.

---

## Test Cases

### TC-OIDCF-01: SSO button is visible on LoginPage

**Requirement:** OIDC-F-01 (MUST)  
**Type:** Frontend UI  
**Preconditions:** Frontend dev server running at `http://127.0.0.1:4173`

**Steps:**
1. Navigate to `/login`
2. Assert `data-testid="page-login"` is visible
3. Assert `data-testid="login-sso-button"` is visible
4. Assert the button text contains "Keycloak" or "SSO"
5. Assert the existing `data-testid="login-token-input"` is still visible (token path preserved)
6. Take screenshot

**Expected result:** Screen shows the login page with both the token input field and the "Sign in with Keycloak" SSO button visible simultaneously.

**Pass condition:** `login-sso-button` and `login-token-input` are both attached and visible.

---

### TC-OIDCF-02: SSO button redirects to Keycloak authorization endpoint

**Requirement:** OIDC-F-01 (MUST)  
**Type:** Frontend navigation (no real Keycloak exchange)  
**Preconditions:** Frontend dev server running

**Steps:**
1. Navigate to `/login`
2. Register `page.waitForRequest` listener for requests matching `**/realms/bpm-default/protocol/openid-connect/auth**` to capture the redirect URL before the navigation completes
3. Register `page.route` on the same pattern to abort the navigation (prevents leaving the app)
4. Click `data-testid="login-sso-button"`
5. Await the captured request
6. Assert the captured URL contains `realms/bpm-default/protocol/openid-connect/auth`
7. Assert URL contains `client_id=bpm-platform-api`
8. Assert URL contains `response_type=code` (authorization code flow)
9. Assert URL contains `redirect_uri=` and the callback path `/auth/callback`
10. Take screenshot

**Expected result:** Clicking the SSO button causes the browser to navigate to Keycloak's authorization endpoint with correct PKCE/authorization code flow parameters.

**Pass condition:** All URL parameter assertions pass. Navigation is aborted before reaching Keycloak.

---

### TC-OIDCF-03: Full OIDC auth flow — real Keycloak login succeeds

**Requirement:** OIDC-F-02 (MUST)  
**Type:** E2E integration (requires real Keycloak)  
**Preconditions:**
- Frontend dev server running at `http://127.0.0.1:4173`
- Keycloak running at `http://localhost:8081/realms/bpm-default`
- User `admin-user` / `admin-pass` configured in Keycloak with `PLATFORM_ADMIN` role mapped in JWT

**Steps:**
1. Navigate to `/login`
2. Assert `data-testid="login-sso-button"` is visible
3. Take screenshot (screen: login page with SSO button)
4. Click `data-testid="login-sso-button"` — browser navigates to Keycloak login form
5. Wait for Keycloak login form: `input#username` to be visible (timeout 10s; if not found the test FAILS with "Keycloak not reachable")
6. Fill `input#username` with `admin-user`
7. Fill `input#password` with `admin-pass`
8. Take screenshot (screen: Keycloak login form filled)
9. Click `input[name=login]` or `[type=submit]`
10. Wait for navigation back to the app — `page.waitForURL` for `**/auth/callback**` or `/`
11. `OidcCallbackPage` processes the code: calls `signinRedirectCallback()`, decodes JWT, calls `setSession()`, navigates to `/`
12. Assert URL is `/` (not `/login`, not `/auth/callback`)
13. Assert `data-testid="logout-button"` is visible (AppShell rendered — user is authenticated)
14. Assert `data-testid="user-display-name"` is visible and non-empty
15. Take screenshot (screen: authenticated workspace with logout button)

**Expected result:** After completing the Keycloak login form, the app redirects back to the root workspace with the AppShell visible and the user authenticated as `admin-user`.

**Pass condition:**
- URL resolves to `/`
- `logout-button` is visible
- `user-display-name` is non-empty
- `page-login` is not attached

**Failure mode if Keycloak unreachable:** Test fails at step 5 with a Playwright timeout error — NOT skipped.

---

### TC-OIDCF-04: Callback error redirects to /login with auth-error banner

**Requirement:** OIDC-F-02 (MUST)  
**Type:** Frontend integration (error path — no Keycloak needed)  
**Preconditions:** Frontend dev server running

**Steps:**
1. Navigate directly to `/auth/callback?error=access_denied&error_description=User+denied+access`
2. `OidcCallbackPage` mounts and calls `signinRedirectCallback()` — which throws because there is no valid state/code parameter
3. The catch block executes `window.location.replace('/login?reason=auth-error')`
4. Wait for URL to match `/login?reason=auth-error` (timeout 5s)
5. Assert `data-testid="login-auth-error"` is visible
6. Assert the auth error banner contains "Authentication failed"
7. Take screenshot (screen: login page showing auth-error banner)

**Expected result:** Navigating to the callback with an error parameter causes the app to redirect to `/login?reason=auth-error` and display the authentication error banner.

**Pass condition:** URL contains `reason=auth-error` and `login-auth-error` banner is visible.

**Note:** This test exercises a pure client-side error path. The `error` query parameter is not explicitly used by `OidcCallbackPage` — rather, the absence of a valid OIDC `state`/`code` combination causes `signinRedirectCallback()` to throw, triggering the catch branch. This is the correct integration test of that error path.

---

### TC-OIDCF-05: OIDC logout hits Keycloak end-session endpoint

**Requirement:** OIDC-F-04 (SHOULD)  
**Type:** E2E integration (requires real Keycloak)  
**Preconditions:**
- Frontend dev server and Keycloak both running
- Depends on TC-OIDCF-03 completing successfully (same user session)

**Steps:**
1. Repeat the login steps from TC-OIDCF-03 (navigate to `/login`, click SSO, fill Keycloak form, complete callback)
2. Assert `data-testid="logout-button"` is visible (authenticated)
3. Take screenshot (screen: authenticated workspace)
4. Register `page.waitForRequest` listener for requests to `**/realms/bpm-default/protocol/openid-connect/logout**`
5. Click `data-testid="logout-button"`
6. Await the captured end-session request (timeout 5s)
7. Assert the captured URL contains `realms/bpm-default/protocol/openid-connect/logout`
8. Take screenshot (screen: Keycloak logout or /login redirect)

**Expected result:** Clicking logout when `loginSource === 'oidc'` triggers `OidcManager.signoutRedirect()`, which navigates to Keycloak's end-session endpoint. The Keycloak end-session endpoint URL is requested.

**Pass condition:** A request to `/realms/bpm-default/protocol/openid-connect/logout` is captured.

---

## Coverage Matrix

| Requirement | Acceptance Criterion | TC | Status |
|---|---|---|---|
| OIDC-F-01 | SSO button visible on login screen | TC-OIDCF-01 | Covered |
| OIDC-F-01 | Clicking button initiates OIDC code flow | TC-OIDCF-02 | Covered |
| OIDC-F-02 | Full code exchange, token stored in memory, navigate to workspace | TC-OIDCF-03 | Covered |
| OIDC-F-02 | Callback error → `/login?reason=auth-error` | TC-OIDCF-04 | Covered |
| OIDC-F-02 | `InMemoryWebStorage` (not sessionStorage/localStorage) | TC-OIDCF-03 (implicit — in-memory means no persistence check needed) | Covered |
| OIDC-F-03 | Silent renew | Not tested (requires timing control; covered by unit test of OidcManager) | Deferred |
| OIDC-F-04 | Logout calls Keycloak end-session endpoint | TC-OIDCF-05 | Covered |
