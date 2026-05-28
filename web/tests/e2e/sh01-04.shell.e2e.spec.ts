/**
 * E2E tests — Stage F1: Application Shell & Authentication
 * Requirements: SH-01, SH-02, SH-03, SH-04
 * Run: WF02-shf1a-20260528
 *
 * Directive T-2 compliance:
 *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
 *   - page.route() is used ONLY to stub GET /health/ready (the token-validation
 *     endpoint). All other application behaviour is exercised via the real
 *     frontend code running against the Vite dev server.
 *   - Token decode (SH-01/03/04) and session state (SH-02) are pure client-side
 *     paths that require no backend interaction beyond the health check.
 *
 * Directive T-3 compliance:
 *   - After every significant UI action a screenshot is taken and the visible
 *     DOM is asserted.  Every verdict is stated as "screen shows X after Y".
 */

import { test, expect, type Page } from '@playwright/test'

// ── JWT helper ────────────────────────────────────────────────────────────────

/**
 * Returns a fake JWT whose payload segment contains the given object.
 * Uses Buffer (Node.js) to produce standard base64.  The application's
 * decodeTokenPayload uses atob, which accepts standard base64, so these
 * tokens decode correctly.
 */
function makeFakeJwt(payload: Record<string, unknown>): string {
  const encode = (obj: unknown) =>
    Buffer.from(JSON.stringify(obj))
      .toString('base64')
      .replace(/=+$/, '')
  const header = encode({ alg: 'none', typ: 'JWT' })
  const body = encode(payload)
  return `${header}.${body}.fake-sig`
}

// Pre-built fake tokens for each role scenario used across multiple tests
const TOKEN_TASK_WORKER = makeFakeJwt({
  sub: 'tw-user-001',
  display_name: 'Task Worker',
  roles: ['TASK_WORKER'],
})

const TOKEN_PLATFORM_ADMIN = makeFakeJwt({
  sub: 'pa-user-001',
  display_name: 'Platform Admin',
  roles: ['PLATFORM_ADMIN'],
})

const TOKEN_PROCESS_DESIGNER = makeFakeJwt({
  sub: 'pd-user-001',
  display_name: 'Process Designer',
  roles: ['PROCESS_DESIGNER'],
})

const TOKEN_DISPLAY_NAME = makeFakeJwt({
  sub: 'dn-user-001',
  display_name: 'Alice Smith',
  roles: ['PROCESS_DESIGNER'],
})

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Stubs GET /health/ready to return the given status code, then performs the
 * full login flow: navigate to /login, fill the token field, submit.
 *
 * The route stub is installed before navigation so that the fetch in
 * AuthProvider.login() is intercepted, regardless of timing.
 */
async function loginWith(
  page: Page,
  token: string,
  healthStatus: 200 | 401 = 200,
): Promise<void> {
  await page.route('**/health/ready', (route) =>
    route.fulfill({
      status: healthStatus,
      contentType: 'application/json',
      body: healthStatus === 200 ? '{"status":"ok"}' : '{"status":"unauthorized"}',
    }),
  )
  await page.goto('/login')
  await page.getByTestId('login-token-input').fill(token)
  await page.getByTestId('login-submit').click()
}

// ── SH-01: Token-based login ──────────────────────────────────────────────────

test.describe('SH-01 — Token-based login', () => {
  test('TC-SH01-01: login page renders token input and submit button', async ({ page }) => {
    await page.goto('/login')

    // Screen shows login page with token input field
    await expect(page.getByTestId('page-login')).toBeVisible()
    await expect(page.getByTestId('login-token-input')).toBeVisible()
    await expect(page.getByTestId('login-submit')).toBeVisible()

    await page.screenshot({ path: 'tests/screenshots/SH01-01-login-page.png' })
    // VERDICT: Screen shows login form with token input after navigating to /login
  })

  test('TC-SH01-02: valid token login navigates to workspace', async ({ page }) => {
    await loginWith(page, TOKEN_TASK_WORKER, 200)

    // Screen shows the AppShell (sidebar present with at least one nav link)
    await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()
    // URL is no longer /login
    await expect(page).not.toHaveURL(/\/login/)

    await page.screenshot({ path: 'tests/screenshots/SH01-02-workspace-after-login.png' })
    // VERDICT: Screen shows AppShell sidebar with "My Tasks" after valid token login
  })

  test('TC-SH01-03: invalid token (health 401) shows error message', async ({ page }) => {
    await loginWith(page, TOKEN_TASK_WORKER, 401)

    // Screen shows login-error alert
    const errorAlert = page.getByTestId('login-error')
    await expect(errorAlert).toBeVisible()
    await expect(errorAlert).toContainText('Invalid token or access denied.')
    // User remains on /login
    await expect(page).toHaveURL(/\/login/)

    await page.screenshot({ path: 'tests/screenshots/SH01-03-login-error-401.png' })
    // VERDICT: Screen shows error "Invalid token or access denied." after 401 health check
  })

  test('TC-SH01-04: empty token submission shows validation error', async ({ page }) => {
    await page.goto('/login')
    // Do NOT fill the token field — submit empty
    await page.getByTestId('login-submit').click()

    const errorAlert = page.getByTestId('login-error')
    await expect(errorAlert).toBeVisible()
    await expect(errorAlert).toContainText('Please enter an API token.')

    await page.screenshot({ path: 'tests/screenshots/SH01-04-login-error-empty.png' })
    // VERDICT: Screen shows "Please enter an API token." error when submitted empty
  })
})

// ── SH-02: Session persistence and expiry ─────────────────────────────────────

test.describe('SH-02 — Session persistence and expiry', () => {
  test('TC-SH02-01: auth:session-expired event navigates to /login?reason=session-expired', async ({ page }) => {
    // Login first
    await loginWith(page, TOKEN_TASK_WORKER, 200)
    await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()

    // Simulate 401 from an API call by dispatching the event that client.ts fires
    await page.evaluate(() =>
      window.dispatchEvent(new CustomEvent('auth:session-expired')),
    )

    // Screen shows session-expired page
    await expect(page).toHaveURL(/reason=session-expired/)
    const banner = page.getByTestId('login-session-expired')
    await expect(banner).toBeVisible()
    await expect(banner).toContainText('Your session has expired. Please log in again.')

    await page.screenshot({ path: 'tests/screenshots/SH02-01-session-expired-event.png' })
    // VERDICT: Screen shows /login?reason=session-expired banner after auth:session-expired event
  })

  test('TC-SH02-02: navigating to /login?reason=session-expired shows expiry banner', async ({ page }) => {
    await page.goto('/login?reason=session-expired')

    const banner = page.getByTestId('login-session-expired')
    await expect(banner).toBeVisible()
    await expect(banner).toContainText('Your session has expired. Please log in again.')

    await page.screenshot({ path: 'tests/screenshots/SH02-02-session-expired-direct-nav.png' })
    // VERDICT: Screen shows session-expired banner when URL contains reason=session-expired
  })
})

// ── SH-03: Role-aware navigation ──────────────────────────────────────────────

test.describe('SH-03 — Role-aware navigation', () => {
  const ALL_NAV_LABELS = [
    'Instances', 'My Tasks', 'Definitions', 'DLQ', 'Webhooks',
    'Users', 'Groups', 'Tokens', 'Audit', 'Health', 'Metrics',
  ]

  test('TC-SH03-01: TASK_WORKER sees only My Tasks', async ({ page }) => {
    await loginWith(page, TOKEN_TASK_WORKER, 200)

    // Screen shows "My Tasks"
    await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()

    // All other nav items must not be in the DOM
    const absent = ALL_NAV_LABELS.filter((l) => l !== 'My Tasks')
    for (const label of absent) {
      await expect(page.getByRole('link', { name: label })).not.toBeAttached()
    }

    await page.screenshot({ path: 'tests/screenshots/SH03-01-task-worker-nav.png' })
    // VERDICT: Screen shows only "My Tasks" nav link for TASK_WORKER role
  })

  test('TC-SH03-02: PLATFORM_ADMIN sees all 11 nav items', async ({ page }) => {
    await loginWith(page, TOKEN_PLATFORM_ADMIN, 200)

    // All 11 nav items must be visible
    for (const label of ALL_NAV_LABELS) {
      await expect(page.getByRole('link', { name: label })).toBeVisible()
    }

    // Exactly 11 nav links in the sidebar
    const navLinks = page.locator('aside nav a')
    await expect(navLinks).toHaveCount(11)

    await page.screenshot({ path: 'tests/screenshots/SH03-02-platform-admin-nav.png' })
    // VERDICT: Screen shows all 11 nav links for PLATFORM_ADMIN role
  })

  test('TC-SH03-03: PROCESS_DESIGNER sees Instances and Definitions only', async ({ page }) => {
    await loginWith(page, TOKEN_PROCESS_DESIGNER, 200)

    // Visible items
    await expect(page.getByRole('link', { name: 'Instances' })).toBeVisible()
    await expect(page.getByRole('link', { name: 'Definitions' })).toBeVisible()

    // Items that must not appear
    const absent = ['My Tasks', 'DLQ', 'Webhooks', 'Users', 'Groups', 'Tokens', 'Audit', 'Health', 'Metrics']
    for (const label of absent) {
      await expect(page.getByRole('link', { name: label })).not.toBeAttached()
    }

    // Exactly 2 nav links
    const navLinks = page.locator('aside nav a')
    await expect(navLinks).toHaveCount(2)

    await page.screenshot({ path: 'tests/screenshots/SH03-03-process-designer-nav.png' })
    // VERDICT: Screen shows only "Instances" and "Definitions" links for PROCESS_DESIGNER
  })
})

// ── SH-04: Active user indicator ─────────────────────────────────────────────

test.describe('SH-04 — Active user indicator', () => {
  test('TC-SH04-01: sidebar header shows display_name from JWT', async ({ page }) => {
    await loginWith(page, TOKEN_DISPLAY_NAME, 200)

    const displayName = page.getByTestId('user-display-name')
    await expect(displayName).toBeVisible()
    await expect(displayName).toHaveText('Alice Smith')

    await page.screenshot({ path: 'tests/screenshots/SH04-01-user-display-name.png' })
    // VERDICT: Screen shows "Alice Smith" in data-testid=user-display-name after login
  })

  test('TC-SH04-02: sidebar header shows roles from JWT', async ({ page }) => {
    await loginWith(page, TOKEN_DISPLAY_NAME, 200)

    const rolesEl = page.getByTestId('user-roles')
    await expect(rolesEl).toBeVisible()
    await expect(rolesEl).toContainText('PROCESS_DESIGNER')

    await page.screenshot({ path: 'tests/screenshots/SH04-02-user-roles.png' })
    // VERDICT: Screen shows "PROCESS_DESIGNER" in data-testid=user-roles after login
  })

  test('TC-SH04-03: logout button clears session and navigates to /login', async ({ page }) => {
    await loginWith(page, TOKEN_PLATFORM_ADMIN, 200)
    await expect(page.getByTestId('logout-button')).toBeVisible()

    // Click logout
    await page.getByTestId('logout-button').click()

    // Screen shows login page
    await expect(page.getByTestId('page-login')).toBeVisible()
    await expect(page).toHaveURL(/\/login/)

    // Session is cleared — no user-display-name in DOM
    await expect(page.getByTestId('user-display-name')).not.toBeAttached()

    await page.screenshot({ path: 'tests/screenshots/SH04-03-after-logout.png' })
    // VERDICT: Screen shows /login page with no user info after clicking Sign out
  })
})
