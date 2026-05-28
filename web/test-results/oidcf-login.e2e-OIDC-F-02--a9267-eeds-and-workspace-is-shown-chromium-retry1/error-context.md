# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: oidcf-login.e2e.spec.ts >> OIDC-F-02 — Full OIDC auth flow >> TC-OIDCF-03: real Keycloak login succeeds and workspace is shown
- Location: tests\e2e\oidcf-login.e2e.spec.ts:141:3

# Error details

```
Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
Call log:
  - navigating to "http://127.0.0.1:4173/login", waiting until "load"

```

# Test source

```ts
  1   | /**
  2   |  * E2E tests — Stage F1.5: OIDC SSO Login
  3   |  * Requirements: OIDC-F-01, OIDC-F-02, OIDC-F-04 (MUST); OIDC-F-04 (SHOULD)
  4   |  * Run: WF02-oidcf-20260528
  5   |  *
  6   |  * Directive T-2 compliance:
  7   |  *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
  8   |  *   - TC-OIDCF-01 and TC-OIDCF-02 use page.route() ONLY to abort the navigation
  9   |  *     away from the app (to avoid requiring a live Keycloak for URL-assertion tests).
  10  |  *     No auth exchange is mocked. The actual signinRedirect() code path runs.
  11  |  *   - TC-OIDCF-03 and TC-OIDCF-05 require a live Keycloak instance.
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
> 51  |   await page.goto('/login')
      |              ^ Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
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
  112 |     await page.goto('/login')
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
```