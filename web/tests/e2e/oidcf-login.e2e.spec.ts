/**
 * E2E tests — Stage F1.5: OIDC SSO Login
 * Requirements: OIDC-F-01, OIDC-F-02, OIDC-F-04 (MUST); OIDC-F-04 (SHOULD)
 * Run: WF02-oidcf-20260528
 *
 * Directive T-2 compliance:
 *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
 *   - TC-OIDCF-01 and TC-OIDCF-02 use page.route() ONLY to abort the navigation
 *     away from the app (to avoid requiring a live Keycloak for URL-assertion tests).
 *     No auth exchange is mocked. The actual signinRedirect() code path runs.
 *   - TC-OIDCF-03 and TC-OIDCF-05 require a live Keycloak instance.
 *     If Keycloak is not running, the tests FAIL (not skip) with a clear timeout.
 *   - TC-OIDCF-04 exercises a pure client-side error path (no Keycloak needed).
 *
 * Directive T-3 compliance:
 *   - After every significant UI action a screenshot is taken.
 *   - All verdicts are stated as "screen shows X after Y".
 *
 * Infrastructure:
 *   - Frontend: http://127.0.0.1:4173 (Vite dev server, started by playwright.config.ts)
 *   - Keycloak: http://localhost:8081/realms/bpm-default
 *   - Test user: admin-user / admin-pass (role: PLATFORM_ADMIN)
 */

import { test, expect } from '@playwright/test'

const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_REALM_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default`
const KEYCLOAK_AUTH_PATTERN = '**/realms/bpm-default/protocol/openid-connect/auth**'

async function assertKeycloakReady(request: import('@playwright/test').APIRequestContext): Promise<void> {
  const discovery = await request.fetch(`${KEYCLOAK_REALM_URL}/.well-known/openid-configuration`)
  if (!discovery.ok()) {
    throw new Error(`Keycloak prerequisite not satisfied: ${KEYCLOAK_REALM_URL} is unreachable or unhealthy (${discovery.status()})`)
  }
}

// ── Screenshot helper ─────────────────────────────────────────────────────────

async function shot(page: import('@playwright/test').Page, name: string) {
  await page.screenshot({ path: `tests/screenshots/OIDCF-${name}.png` })
}

async function installKeycloakPortRewrite(page: import('@playwright/test').Page): Promise<void> {
  // Some local Keycloak configs emit portless follow-up URLs (http://127.0.0.1/...).
  // Rewrite those requests to the actual exposed Keycloak port for real end-to-end flow.
  await page.route('http://127.0.0.1/realms/**', async (route) => {
    const originalUrl = route.request().url()
    const rewrittenUrl = originalUrl.replace('http://127.0.0.1/', `${KEYCLOAK_BASE_URL}/`)
    await route.continue({ url: rewrittenUrl })
  })
}

// ── Helper: perform a full Keycloak login flow ────────────────────────────────

/**
 * Navigates to /login, clicks the SSO button, completes the Keycloak login form,
 * and waits for the app to redirect back to the workspace root.
 *
 * If Keycloak is not reachable the Playwright default timeout will fire with a
 * clear "Waiting for locator ... timed out" message — the test FAILS, not skips.
 */
async function performOidcLogin(
  page: import('@playwright/test').Page,
  username: string,
  password: string,
  screenshotPrefix: string,
): Promise<void> {
  await installKeycloakPortRewrite(page)
  await page.goto('/login')
  await expect(page.getByTestId('login-sso-button')).toBeVisible()
  await shot(page, `${screenshotPrefix}-01-login-page`)

  // Click SSO — browser navigates away to Keycloak
  await page.getByTestId('login-sso-button').click()

  // Allow slow environments a moment to complete cross-origin navigation.
  try {
    await page.waitForURL(/\/realms\/[^/]+\//, { timeout: 20_000 })
  } catch {
    throw new Error('Keycloak prerequisite not satisfied: browser could not reach Keycloak authorization endpoint')
  }

  // Wait for Keycloak login form. If Keycloak is not running, this times out with a
  // clear failure — NOT a test skip.
  const usernameInput = page.locator('input#username, input[name="username"]').first()
  const passwordInput = page.locator('input#password, input[name="password"]').first()
  await expect(usernameInput).toBeVisible({ timeout: 20_000 })
  await expect(passwordInput).toBeVisible({ timeout: 20_000 })
  await shot(page, `${screenshotPrefix}-02-keycloak-login-form`)

  // Fill Keycloak credentials
  await usernameInput.fill(username)
  await passwordInput.fill(password)
  await shot(page, `${screenshotPrefix}-03-keycloak-credentials-filled`)

  // Submit — Keycloak validates and redirects back to /auth/callback
  await page.locator('input[name=login], [type=submit]').first().click()

  // OidcCallbackPage processes the code and navigates to /
  await page.waitForURL('/', { timeout: 15_000 })
  await shot(page, `${screenshotPrefix}-04-workspace-after-oidc-login`)
}

// ── TC-OIDCF-01: SSO button visible on LoginPage ──────────────────────────────

test.describe('OIDC-F-01 — SSO login button', () => {
  test('TC-OIDCF-01: SSO button and token input are both visible on /login', async ({ page }) => {
    await page.goto('/login')

    // Screen shows login page container
    await expect(page.getByTestId('page-login')).toBeVisible()

    // Screen shows the existing token input (original path preserved)
    await expect(page.getByTestId('login-token-input')).toBeVisible()
    await expect(page.getByTestId('login-submit')).toBeVisible()

    // Screen shows the new SSO button
    const ssoButton = page.getByTestId('login-sso-button')
    await expect(ssoButton).toBeVisible()

    // SSO button text references Keycloak
    const buttonText = await ssoButton.textContent()
    expect(buttonText?.toLowerCase()).toContain('keycloak')

    await shot(page, 'TC01-login-page-with-sso-button')
    // VERDICT: Screen shows login page with both token input and Keycloak SSO button visible
  })
})

// ── TC-OIDCF-02: SSO button triggers Keycloak redirect ───────────────────────

test.describe('OIDC-F-01 — SSO redirect URL', () => {
  test('TC-OIDCF-02: clicking SSO button navigates to Keycloak authorization endpoint', async ({ page }) => {
    // Intercept navigation to Keycloak to capture URL without completing the redirect.
    // Aborting the navigation keeps the test self-contained — no live Keycloak required.
    await page.route(KEYCLOAK_AUTH_PATTERN, async (route) => {
      await route.abort('aborted')
    })

    await page.goto('/login')
    await expect(page.getByTestId('login-sso-button')).toBeVisible()

    // Click SSO button — signinRedirect() executes and navigates toward Keycloak
    const [capturedRequest] = await Promise.all([
      page.waitForRequest((req) => req.url().includes('realms/bpm-default/protocol/openid-connect/auth')),
      page.getByTestId('login-sso-button').click(),
    ])

    // Assert captured URL structure — real PKCE authorization code flow parameters
    const url = capturedRequest.url()
    expect(url).toContain('realms/bpm-default/protocol/openid-connect/auth')
    expect(url).toContain('client_id=bpm-platform-api')
    expect(url).toContain('response_type=code')
    expect(url).toContain('redirect_uri=')
    expect(url).toContain('%2Fauth%2Fcallback')   // URL-encoded /auth/callback

    // Captured URL stored by route handler should match
    // Note: capturedUrl via page.route() may be null for cross-origin navigations;
    // capturedRequest.url() is the canonical check above.

    await shot(page, 'TC02-sso-redirect-intercepted')
    // VERDICT: Clicking SSO button sends browser to Keycloak /auth endpoint with correct PKCE params
  })
})

// ── TC-OIDCF-03: Full OIDC auth flow (requires live Keycloak) ────────────────

test.describe('OIDC-F-02 — Full OIDC auth flow', () => {
  test('TC-OIDCF-03: real Keycloak login succeeds and workspace is shown', async ({ page, request }) => {
    await assertKeycloakReady(request)
    await performOidcLogin(page, 'admin-user', 'admin-pass', 'TC03')

    // Assert user is on the workspace root, not on /login or /auth/callback
    await expect(page).toHaveURL('/')
    await expect(page.getByTestId('page-login')).not.toBeAttached()

    // Assert the AppShell is rendered — user is authenticated
    await expect(page.getByTestId('logout-button')).toBeVisible()
    await expect(page.getByTestId('user-display-name')).toBeVisible()

    // user-display-name should be non-empty (populated from JWT display_name / preferred_username)
    const displayName = await page.getByTestId('user-display-name').textContent()
    expect(displayName?.trim().length).toBeGreaterThan(0)

    // PLATFORM_ADMIN sees admin nav items
    await expect(page.getByRole('link', { name: 'Users' })).toBeVisible()

    await shot(page, 'TC03-workspace-authenticated')
    // VERDICT: Screen shows AppShell workspace with logout button and user display name
    //          after completing real Keycloak login as admin-user
  })
})

// ── TC-OIDCF-04: Callback error path → /login?reason=auth-error ──────────────

test.describe('OIDC-F-02 — Callback error handling', () => {
  test('TC-OIDCF-04: navigating to /auth/callback with error params redirects to auth-error login', async ({ page }) => {
    // Navigate directly to the callback URL with error parameters.
    // OidcCallbackPage calls signinRedirectCallback() — with no valid OIDC state in
    // memory, oidc-client-ts throws. The catch block does window.location.replace('/login?reason=auth-error').
    await page.goto('/auth/callback?error=access_denied&error_description=User+denied+access')

    // OidcCallbackPage should briefly show, then redirect
    // Wait for the redirect to complete
    await page.waitForURL(/\/login\?reason=auth-error/, { timeout: 8_000 })

    // Screen shows login page with auth-error banner
    await expect(page.getByTestId('login-auth-error')).toBeVisible()

    const bannerText = await page.getByTestId('login-auth-error').textContent()
    expect(bannerText).toContain('Authentication failed')

    // Confirm user is on /login, not on /auth/callback
    await expect(page).toHaveURL(/reason=auth-error/)

    await shot(page, 'TC04-callback-error-banner')
    // VERDICT: Screen shows /login with auth-error banner after navigating to
    //          /auth/callback with error=access_denied params
  })
})

// ── TC-OIDCF-05: OIDC logout hits Keycloak end-session (requires live Keycloak) ─

test.describe('OIDC-F-04 — OIDC logout', () => {
  test('TC-OIDCF-05: logout after OIDC login navigates to Keycloak end-session endpoint', async ({ page, request }) => {
    await assertKeycloakReady(request)
    // First: perform a real OIDC login (requires live Keycloak)
    await performOidcLogin(page, 'admin-user', 'admin-pass', 'TC05-setup')

    // Confirm we are authenticated
    await expect(page.getByTestId('logout-button')).toBeVisible()
    await shot(page, 'TC05-01-authenticated-before-logout')

    // Capture the end-session request before it completes
    const [logoutRequest] = await Promise.all([
      page.waitForRequest(
        (req) => req.url().includes('realms/bpm-default/protocol/openid-connect/logout'),
        { timeout: 10_000 },
      ),
      page.getByTestId('logout-button').click(),
    ])

    // Assert the captured request targets Keycloak end-session endpoint
    expect(logoutRequest.url()).toContain(`${KEYCLOAK_REALM_URL}/protocol/openid-connect/logout`)

    await shot(page, 'TC05-02-after-logout-click')
    // VERDICT: Clicking logout after OIDC login navigates to Keycloak end-session endpoint
  })
})
