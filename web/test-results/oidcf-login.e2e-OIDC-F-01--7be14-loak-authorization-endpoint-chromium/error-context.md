# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: oidcf-login.e2e.spec.ts >> OIDC-F-01 — SSO redirect URL >> TC-OIDCF-02: clicking SSO button navigates to Keycloak authorization endpoint
- Location: tests\e2e\oidcf-login.e2e.spec.ts:105:3

# Error details

```
Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
Call log:
  - navigating to "http://127.0.0.1:4173/login", waiting until "load"

```

# Test source

```ts
  12  |  *     If Keycloak is not running, the tests FAIL (not skip) with a clear timeout.
  13  |  *   - TC-OIDCF-04 exercises a pure client-side error path (no Keycloak needed).
  14  |  *
  15  |  * Directive T-3 compliance:
  16  |  *   - After every significant UI action a screenshot is taken.
  17  |  *   - All verdicts are stated as "screen shows X after Y".
  18  |  *
  19  |  * Infrastructure:
  20  |  *   - Frontend: http://127.0.0.1:4173 (Vite dev server, started by playwright.config.ts)
  21  |  *   - Keycloak: http://localhost:8081/realms/bpm-default
  22  |  *   - Test user: admin-user / admin-pass (role: PLATFORM_ADMIN)
  23  |  */
  24  | 
  25  | import { test, expect } from '@playwright/test'
  26  | 
  27  | const KEYCLOAK_REALM_URL = 'http://localhost:8081/realms/bpm-default'
  28  | const KEYCLOAK_AUTH_PATTERN = '**/realms/bpm-default/protocol/openid-connect/auth**'
  29  | 
  30  | // ── Screenshot helper ─────────────────────────────────────────────────────────
  31  | 
  32  | async function shot(page: import('@playwright/test').Page, name: string) {
  33  |   await page.screenshot({ path: `tests/screenshots/OIDCF-${name}.png` })
  34  | }
  35  | 
  36  | // ── Helper: perform a full Keycloak login flow ────────────────────────────────
  37  | 
  38  | /**
  39  |  * Navigates to /login, clicks the SSO button, completes the Keycloak login form,
  40  |  * and waits for the app to redirect back to the workspace root.
  41  |  *
  42  |  * If Keycloak is not reachable the Playwright default timeout will fire with a
  43  |  * clear "Waiting for locator ... timed out" message — the test FAILS, not skips.
  44  |  */
  45  | async function performOidcLogin(
  46  |   page: import('@playwright/test').Page,
  47  |   username: string,
  48  |   password: string,
  49  |   screenshotPrefix: string,
  50  | ): Promise<void> {
  51  |   await page.goto('/login')
  52  |   await expect(page.getByTestId('login-sso-button')).toBeVisible()
  53  |   await shot(page, `${screenshotPrefix}-01-login-page`)
  54  | 
  55  |   // Click SSO — browser navigates away to Keycloak
  56  |   await page.getByTestId('login-sso-button').click()
  57  | 
  58  |   // Wait for Keycloak login form. If Keycloak is not running, this times out with a
  59  |   // clear failure — NOT a test skip.
  60  |   await expect(page.locator('input#username')).toBeVisible({ timeout: 10_000 })
  61  |   await shot(page, `${screenshotPrefix}-02-keycloak-login-form`)
  62  | 
  63  |   // Fill Keycloak credentials
  64  |   await page.locator('input#username').fill(username)
  65  |   await page.locator('input#password').fill(password)
  66  |   await shot(page, `${screenshotPrefix}-03-keycloak-credentials-filled`)
  67  | 
  68  |   // Submit — Keycloak validates and redirects back to /auth/callback
  69  |   await page.locator('input[name=login], [type=submit]').first().click()
  70  | 
  71  |   // OidcCallbackPage processes the code and navigates to /
  72  |   await page.waitForURL('/', { timeout: 15_000 })
  73  |   await shot(page, `${screenshotPrefix}-04-workspace-after-oidc-login`)
  74  | }
  75  | 
  76  | // ── TC-OIDCF-01: SSO button visible on LoginPage ──────────────────────────────
  77  | 
  78  | test.describe('OIDC-F-01 — SSO login button', () => {
  79  |   test('TC-OIDCF-01: SSO button and token input are both visible on /login', async ({ page }) => {
  80  |     await page.goto('/login')
  81  | 
  82  |     // Screen shows login page container
  83  |     await expect(page.getByTestId('page-login')).toBeVisible()
  84  | 
  85  |     // Screen shows the existing token input (original path preserved)
  86  |     await expect(page.getByTestId('login-token-input')).toBeVisible()
  87  |     await expect(page.getByTestId('login-submit')).toBeVisible()
  88  | 
  89  |     // Screen shows the new SSO button
  90  |     const ssoButton = page.getByTestId('login-sso-button')
  91  |     await expect(ssoButton).toBeVisible()
  92  | 
  93  |     // SSO button text references Keycloak
  94  |     const buttonText = await ssoButton.textContent()
  95  |     expect(buttonText?.toLowerCase()).toContain('keycloak')
  96  | 
  97  |     await shot(page, 'TC01-login-page-with-sso-button')
  98  |     // VERDICT: Screen shows login page with both token input and Keycloak SSO button visible
  99  |   })
  100 | })
  101 | 
  102 | // ── TC-OIDCF-02: SSO button triggers Keycloak redirect ───────────────────────
  103 | 
  104 | test.describe('OIDC-F-01 — SSO redirect URL', () => {
  105 |   test('TC-OIDCF-02: clicking SSO button navigates to Keycloak authorization endpoint', async ({ page }) => {
  106 |     // Intercept navigation to Keycloak to capture URL without completing the redirect.
  107 |     // Aborting the navigation keeps the test self-contained — no live Keycloak required.
  108 |     await page.route(KEYCLOAK_AUTH_PATTERN, async (route) => {
  109 |       await route.abort('aborted')
  110 |     })
  111 | 
> 112 |     await page.goto('/login')
      |                ^ Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
  113 |     await expect(page.getByTestId('login-sso-button')).toBeVisible()
  114 | 
  115 |     // Click SSO button — signinRedirect() executes and navigates toward Keycloak
  116 |     const [capturedRequest] = await Promise.all([
  117 |       page.waitForRequest((req) => req.url().includes('realms/bpm-default/protocol/openid-connect/auth')),
  118 |       page.getByTestId('login-sso-button').click(),
  119 |     ])
  120 | 
  121 |     // Assert captured URL structure — real PKCE authorization code flow parameters
  122 |     const url = capturedRequest.url()
  123 |     expect(url).toContain('realms/bpm-default/protocol/openid-connect/auth')
  124 |     expect(url).toContain('client_id=bpm-platform-api')
  125 |     expect(url).toContain('response_type=code')
  126 |     expect(url).toContain('redirect_uri=')
  127 |     expect(url).toContain('%2Fauth%2Fcallback')   // URL-encoded /auth/callback
  128 | 
  129 |     // Captured URL stored by route handler should match
  130 |     // Note: capturedUrl via page.route() may be null for cross-origin navigations;
  131 |     // capturedRequest.url() is the canonical check above.
  132 | 
  133 |     await shot(page, 'TC02-sso-redirect-intercepted')
  134 |     // VERDICT: Clicking SSO button sends browser to Keycloak /auth endpoint with correct PKCE params
  135 |   })
  136 | })
  137 | 
  138 | // ── TC-OIDCF-03: Full OIDC auth flow (requires live Keycloak) ────────────────
  139 | 
  140 | test.describe('OIDC-F-02 — Full OIDC auth flow', () => {
  141 |   test('TC-OIDCF-03: real Keycloak login succeeds and workspace is shown', async ({ page }) => {
  142 |     await performOidcLogin(page, 'admin-user', 'admin-pass', 'TC03')
  143 | 
  144 |     // Assert user is on the workspace root, not on /login or /auth/callback
  145 |     await expect(page).toHaveURL('/')
  146 |     await expect(page.getByTestId('page-login')).not.toBeAttached()
  147 | 
  148 |     // Assert the AppShell is rendered — user is authenticated
  149 |     await expect(page.getByTestId('logout-button')).toBeVisible()
  150 |     await expect(page.getByTestId('user-display-name')).toBeVisible()
  151 | 
  152 |     // user-display-name should be non-empty (populated from JWT display_name / preferred_username)
  153 |     const displayName = await page.getByTestId('user-display-name').textContent()
  154 |     expect(displayName?.trim().length).toBeGreaterThan(0)
  155 | 
  156 |     // PLATFORM_ADMIN sees admin nav items
  157 |     await expect(page.getByRole('link', { name: 'Users' })).toBeVisible()
  158 | 
  159 |     await shot(page, 'TC03-workspace-authenticated')
  160 |     // VERDICT: Screen shows AppShell workspace with logout button and user display name
  161 |     //          after completing real Keycloak login as admin-user
  162 |   })
  163 | })
  164 | 
  165 | // ── TC-OIDCF-04: Callback error path → /login?reason=auth-error ──────────────
  166 | 
  167 | test.describe('OIDC-F-02 — Callback error handling', () => {
  168 |   test('TC-OIDCF-04: navigating to /auth/callback with error params redirects to auth-error login', async ({ page }) => {
  169 |     // Navigate directly to the callback URL with error parameters.
  170 |     // OidcCallbackPage calls signinRedirectCallback() — with no valid OIDC state in
  171 |     // memory, oidc-client-ts throws. The catch block does window.location.replace('/login?reason=auth-error').
  172 |     await page.goto('/auth/callback?error=access_denied&error_description=User+denied+access')
  173 | 
  174 |     // OidcCallbackPage should briefly show, then redirect
  175 |     // Wait for the redirect to complete
  176 |     await page.waitForURL(/\/login\?reason=auth-error/, { timeout: 8_000 })
  177 | 
  178 |     // Screen shows login page with auth-error banner
  179 |     await expect(page.getByTestId('login-auth-error')).toBeVisible()
  180 | 
  181 |     const bannerText = await page.getByTestId('login-auth-error').textContent()
  182 |     expect(bannerText).toContain('Authentication failed')
  183 | 
  184 |     // Confirm user is on /login, not on /auth/callback
  185 |     await expect(page).toHaveURL(/reason=auth-error/)
  186 | 
  187 |     await shot(page, 'TC04-callback-error-banner')
  188 |     // VERDICT: Screen shows /login with auth-error banner after navigating to
  189 |     //          /auth/callback with error=access_denied params
  190 |   })
  191 | })
  192 | 
  193 | // ── TC-OIDCF-05: OIDC logout hits Keycloak end-session (requires live Keycloak) ─
  194 | 
  195 | test.describe('OIDC-F-04 — OIDC logout', () => {
  196 |   test('TC-OIDCF-05: logout after OIDC login navigates to Keycloak end-session endpoint', async ({ page }) => {
  197 |     // First: perform a real OIDC login (requires live Keycloak)
  198 |     await performOidcLogin(page, 'admin-user', 'admin-pass', 'TC05-setup')
  199 | 
  200 |     // Confirm we are authenticated
  201 |     await expect(page.getByTestId('logout-button')).toBeVisible()
  202 |     await shot(page, 'TC05-01-authenticated-before-logout')
  203 | 
  204 |     // Capture the end-session request before it completes
  205 |     const [logoutRequest] = await Promise.all([
  206 |       page.waitForRequest(
  207 |         (req) => req.url().includes('realms/bpm-default/protocol/openid-connect/logout'),
  208 |         { timeout: 10_000 },
  209 |       ),
  210 |       page.getByTestId('logout-button').click(),
  211 |     ])
  212 | 
```