# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: sh01-04.shell.e2e.spec.ts >> SH-04 — Active user indicator >> TC-SH04-02: sidebar header shows roles from JWT
- Location: tests\e2e\sh01-04.shell.e2e.spec.ts:256:3

# Error details

```
Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
Call log:
  - navigating to "http://127.0.0.1:4173/login", waiting until "load"

```

# Test source

```ts
  1   | /**
  2   |  * E2E tests — Stage F1: Application Shell & Authentication
  3   |  * Requirements: SH-01, SH-02, SH-03, SH-04
  4   |  * Run: WF02-shf1a-20260528
  5   |  *
  6   |  * Directive T-2 compliance:
  7   |  *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
  8   |  *   - page.route() is used ONLY to stub GET /health/ready (the token-validation
  9   |  *     endpoint). All other application behaviour is exercised via the real
  10  |  *     frontend code running against the Vite dev server.
  11  |  *   - Token decode (SH-01/03/04) and session state (SH-02) are pure client-side
  12  |  *     paths that require no backend interaction beyond the health check.
  13  |  *
  14  |  * Directive T-3 compliance:
  15  |  *   - After every significant UI action a screenshot is taken and the visible
  16  |  *     DOM is asserted.  Every verdict is stated as "screen shows X after Y".
  17  |  */
  18  | 
  19  | import { test, expect, type Page } from '@playwright/test'
  20  | 
  21  | // ── JWT helper ────────────────────────────────────────────────────────────────
  22  | 
  23  | /**
  24  |  * Returns a fake JWT whose payload segment contains the given object.
  25  |  * Uses Buffer (Node.js) to produce standard base64.  The application's
  26  |  * decodeTokenPayload uses atob, which accepts standard base64, so these
  27  |  * tokens decode correctly.
  28  |  */
  29  | function makeFakeJwt(payload: Record<string, unknown>): string {
  30  |   const encode = (obj: unknown) =>
  31  |     Buffer.from(JSON.stringify(obj))
  32  |       .toString('base64')
  33  |       .replace(/=+$/, '')
  34  |   const header = encode({ alg: 'none', typ: 'JWT' })
  35  |   const body = encode(payload)
  36  |   return `${header}.${body}.fake-sig`
  37  | }
  38  | 
  39  | // Pre-built fake tokens for each role scenario used across multiple tests
  40  | const TOKEN_TASK_WORKER = makeFakeJwt({
  41  |   sub: 'tw-user-001',
  42  |   display_name: 'Task Worker',
  43  |   roles: ['TASK_WORKER'],
  44  | })
  45  | 
  46  | const TOKEN_PLATFORM_ADMIN = makeFakeJwt({
  47  |   sub: 'pa-user-001',
  48  |   display_name: 'Platform Admin',
  49  |   roles: ['PLATFORM_ADMIN'],
  50  | })
  51  | 
  52  | const TOKEN_PROCESS_DESIGNER = makeFakeJwt({
  53  |   sub: 'pd-user-001',
  54  |   display_name: 'Process Designer',
  55  |   roles: ['PROCESS_DESIGNER'],
  56  | })
  57  | 
  58  | const TOKEN_DISPLAY_NAME = makeFakeJwt({
  59  |   sub: 'dn-user-001',
  60  |   display_name: 'Alice Smith',
  61  |   roles: ['PROCESS_DESIGNER'],
  62  | })
  63  | 
  64  | // ── Helpers ───────────────────────────────────────────────────────────────────
  65  | 
  66  | /**
  67  |  * Stubs GET /health/ready to return the given status code, then performs the
  68  |  * full login flow: navigate to /login, fill the token field, submit.
  69  |  *
  70  |  * The route stub is installed before navigation so that the fetch in
  71  |  * AuthProvider.login() is intercepted, regardless of timing.
  72  |  */
  73  | async function loginWith(
  74  |   page: Page,
  75  |   token: string,
  76  |   healthStatus: 200 | 401 = 200,
  77  | ): Promise<void> {
  78  |   await page.route('**/health/ready', (route) =>
  79  |     route.fulfill({
  80  |       status: healthStatus,
  81  |       contentType: 'application/json',
  82  |       body: healthStatus === 200 ? '{"status":"ok"}' : '{"status":"unauthorized"}',
  83  |     }),
  84  |   )
> 85  |   await page.goto('/login')
      |              ^ Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
  86  |   await page.getByTestId('login-token-input').fill(token)
  87  |   await page.getByTestId('login-submit').click()
  88  | }
  89  | 
  90  | // ── SH-01: Token-based login ──────────────────────────────────────────────────
  91  | 
  92  | test.describe('SH-01 — Token-based login', () => {
  93  |   test('TC-SH01-01: login page renders token input and submit button', async ({ page }) => {
  94  |     await page.goto('/login')
  95  | 
  96  |     // Screen shows login page with token input field
  97  |     await expect(page.getByTestId('page-login')).toBeVisible()
  98  |     await expect(page.getByTestId('login-token-input')).toBeVisible()
  99  |     await expect(page.getByTestId('login-submit')).toBeVisible()
  100 | 
  101 |     await page.screenshot({ path: 'tests/screenshots/SH01-01-login-page.png' })
  102 |     // VERDICT: Screen shows login form with token input after navigating to /login
  103 |   })
  104 | 
  105 |   test('TC-SH01-02: valid token login navigates to workspace', async ({ page }) => {
  106 |     await loginWith(page, TOKEN_TASK_WORKER, 200)
  107 | 
  108 |     // Screen shows the AppShell (sidebar present with at least one nav link)
  109 |     await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()
  110 |     // URL is no longer /login
  111 |     await expect(page).not.toHaveURL(/\/login/)
  112 | 
  113 |     await page.screenshot({ path: 'tests/screenshots/SH01-02-workspace-after-login.png' })
  114 |     // VERDICT: Screen shows AppShell sidebar with "My Tasks" after valid token login
  115 |   })
  116 | 
  117 |   test('TC-SH01-03: invalid token (health 401) shows error message', async ({ page }) => {
  118 |     await loginWith(page, TOKEN_TASK_WORKER, 401)
  119 | 
  120 |     // Screen shows login-error alert
  121 |     const errorAlert = page.getByTestId('login-error')
  122 |     await expect(errorAlert).toBeVisible()
  123 |     await expect(errorAlert).toContainText('Invalid token or access denied.')
  124 |     // User remains on /login
  125 |     await expect(page).toHaveURL(/\/login/)
  126 | 
  127 |     await page.screenshot({ path: 'tests/screenshots/SH01-03-login-error-401.png' })
  128 |     // VERDICT: Screen shows error "Invalid token or access denied." after 401 health check
  129 |   })
  130 | 
  131 |   test('TC-SH01-04: empty token submission shows validation error', async ({ page }) => {
  132 |     await page.goto('/login')
  133 |     // Do NOT fill the token field — submit empty
  134 |     await page.getByTestId('login-submit').click()
  135 | 
  136 |     const errorAlert = page.getByTestId('login-error')
  137 |     await expect(errorAlert).toBeVisible()
  138 |     await expect(errorAlert).toContainText('Please enter an API token.')
  139 | 
  140 |     await page.screenshot({ path: 'tests/screenshots/SH01-04-login-error-empty.png' })
  141 |     // VERDICT: Screen shows "Please enter an API token." error when submitted empty
  142 |   })
  143 | })
  144 | 
  145 | // ── SH-02: Session persistence and expiry ─────────────────────────────────────
  146 | 
  147 | test.describe('SH-02 — Session persistence and expiry', () => {
  148 |   test('TC-SH02-01: auth:session-expired event navigates to /login?reason=session-expired', async ({ page }) => {
  149 |     // Login first
  150 |     await loginWith(page, TOKEN_TASK_WORKER, 200)
  151 |     await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()
  152 | 
  153 |     // Simulate 401 from an API call by dispatching the event that client.ts fires
  154 |     await page.evaluate(() =>
  155 |       window.dispatchEvent(new CustomEvent('auth:session-expired')),
  156 |     )
  157 | 
  158 |     // Screen shows session-expired page
  159 |     await expect(page).toHaveURL(/reason=session-expired/)
  160 |     const banner = page.getByTestId('login-session-expired')
  161 |     await expect(banner).toBeVisible()
  162 |     await expect(banner).toContainText('Your session has expired. Please log in again.')
  163 | 
  164 |     await page.screenshot({ path: 'tests/screenshots/SH02-01-session-expired-event.png' })
  165 |     // VERDICT: Screen shows /login?reason=session-expired banner after auth:session-expired event
  166 |   })
  167 | 
  168 |   test('TC-SH02-02: navigating to /login?reason=session-expired shows expiry banner', async ({ page }) => {
  169 |     await page.goto('/login?reason=session-expired')
  170 | 
  171 |     const banner = page.getByTestId('login-session-expired')
  172 |     await expect(banner).toBeVisible()
  173 |     await expect(banner).toContainText('Your session has expired. Please log in again.')
  174 | 
  175 |     await page.screenshot({ path: 'tests/screenshots/SH02-02-session-expired-direct-nav.png' })
  176 |     // VERDICT: Screen shows session-expired banner when URL contains reason=session-expired
  177 |   })
  178 | })
  179 | 
  180 | // ── SH-03: Role-aware navigation ──────────────────────────────────────────────
  181 | 
  182 | test.describe('SH-03 — Role-aware navigation', () => {
  183 |   const ALL_NAV_LABELS = [
  184 |     'Instances', 'My Tasks', 'Definitions', 'DLQ', 'Webhooks',
  185 |     'Users', 'Groups', 'Tokens', 'Audit', 'Health', 'Metrics',
```