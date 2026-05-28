# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: sh01-04.shell.e2e.spec.ts >> SH-02 — Session persistence and expiry >> TC-SH02-02: navigating to /login?reason=session-expired shows expiry banner
- Location: tests\e2e\sh01-04.shell.e2e.spec.ts:168:3

# Error details

```
Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login?reason=session-expired
Call log:
  - navigating to "http://127.0.0.1:4173/login?reason=session-expired", waiting until "load"

```

# Test source

```ts
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
  85  |   await page.goto('/login')
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
> 169 |     await page.goto('/login?reason=session-expired')
      |                ^ Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login?reason=session-expired
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
  186 |   ]
  187 | 
  188 |   test('TC-SH03-01: TASK_WORKER sees only My Tasks', async ({ page }) => {
  189 |     await loginWith(page, TOKEN_TASK_WORKER, 200)
  190 | 
  191 |     // Screen shows "My Tasks"
  192 |     await expect(page.getByRole('link', { name: 'My Tasks' })).toBeVisible()
  193 | 
  194 |     // All other nav items must not be in the DOM
  195 |     const absent = ALL_NAV_LABELS.filter((l) => l !== 'My Tasks')
  196 |     for (const label of absent) {
  197 |       await expect(page.getByRole('link', { name: label })).not.toBeAttached()
  198 |     }
  199 | 
  200 |     await page.screenshot({ path: 'tests/screenshots/SH03-01-task-worker-nav.png' })
  201 |     // VERDICT: Screen shows only "My Tasks" nav link for TASK_WORKER role
  202 |   })
  203 | 
  204 |   test('TC-SH03-02: PLATFORM_ADMIN sees all 11 nav items', async ({ page }) => {
  205 |     await loginWith(page, TOKEN_PLATFORM_ADMIN, 200)
  206 | 
  207 |     // All 11 nav items must be visible
  208 |     for (const label of ALL_NAV_LABELS) {
  209 |       await expect(page.getByRole('link', { name: label })).toBeVisible()
  210 |     }
  211 | 
  212 |     // Exactly 11 nav links in the sidebar
  213 |     const navLinks = page.locator('aside nav a')
  214 |     await expect(navLinks).toHaveCount(11)
  215 | 
  216 |     await page.screenshot({ path: 'tests/screenshots/SH03-02-platform-admin-nav.png' })
  217 |     // VERDICT: Screen shows all 11 nav links for PLATFORM_ADMIN role
  218 |   })
  219 | 
  220 |   test('TC-SH03-03: PROCESS_DESIGNER sees Instances and Definitions only', async ({ page }) => {
  221 |     await loginWith(page, TOKEN_PROCESS_DESIGNER, 200)
  222 | 
  223 |     // Visible items
  224 |     await expect(page.getByRole('link', { name: 'Instances' })).toBeVisible()
  225 |     await expect(page.getByRole('link', { name: 'Definitions' })).toBeVisible()
  226 | 
  227 |     // Items that must not appear
  228 |     const absent = ['My Tasks', 'DLQ', 'Webhooks', 'Users', 'Groups', 'Tokens', 'Audit', 'Health', 'Metrics']
  229 |     for (const label of absent) {
  230 |       await expect(page.getByRole('link', { name: label })).not.toBeAttached()
  231 |     }
  232 | 
  233 |     // Exactly 2 nav links
  234 |     const navLinks = page.locator('aside nav a')
  235 |     await expect(navLinks).toHaveCount(2)
  236 | 
  237 |     await page.screenshot({ path: 'tests/screenshots/SH03-03-process-designer-nav.png' })
  238 |     // VERDICT: Screen shows only "Instances" and "Definitions" links for PROCESS_DESIGNER
  239 |   })
  240 | })
  241 | 
  242 | // ── SH-04: Active user indicator ─────────────────────────────────────────────
  243 | 
  244 | test.describe('SH-04 — Active user indicator', () => {
  245 |   test('TC-SH04-01: sidebar header shows display_name from JWT', async ({ page }) => {
  246 |     await loginWith(page, TOKEN_DISPLAY_NAME, 200)
  247 | 
  248 |     const displayName = page.getByTestId('user-display-name')
  249 |     await expect(displayName).toBeVisible()
  250 |     await expect(displayName).toHaveText('Alice Smith')
  251 | 
  252 |     await page.screenshot({ path: 'tests/screenshots/SH04-01-user-display-name.png' })
  253 |     // VERDICT: Screen shows "Alice Smith" in data-testid=user-display-name after login
  254 |   })
  255 | 
  256 |   test('TC-SH04-02: sidebar header shows roles from JWT', async ({ page }) => {
  257 |     await loginWith(page, TOKEN_DISPLAY_NAME, 200)
  258 | 
  259 |     const rolesEl = page.getByTestId('user-roles')
  260 |     await expect(rolesEl).toBeVisible()
  261 |     await expect(rolesEl).toContainText('PROCESS_DESIGNER')
  262 | 
  263 |     await page.screenshot({ path: 'tests/screenshots/SH04-02-user-roles.png' })
  264 |     // VERDICT: Screen shows "PROCESS_DESIGNER" in data-testid=user-roles after login
  265 |   })
  266 | 
  267 |   test('TC-SH04-03: logout button clears session and navigates to /login', async ({ page }) => {
  268 |     await loginWith(page, TOKEN_PLATFORM_ADMIN, 200)
  269 |     await expect(page.getByTestId('logout-button')).toBeVisible()
```