# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: oidcf2-subdomain.e2e.spec.ts >> OIDC-F-05 — Tenant-config endpoint: localhost hostname >> TC-OIDCF2-02: GET /api/tenant-config?host=localhost returns valid OIDC fields
- Location: tests\e2e\oidcf2-subdomain.e2e.spec.ts:70:3

# Error details

```
Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
Call log:
  - navigating to "http://127.0.0.1:4173/login", waiting until "load"

```

# Test source

```ts
  1   | /**
  2   |  * E2E tests — Stage F1.6: Subdomain Tenant Routing
  3   |  * Requirements: OIDC-F-05 (MUST), OIDC-F-06 (MUST)
  4   |  * Run: WF02-oidcf2-20260528
  5   |  *
  6   |  * Directive T-2 compliance:
  7   |  *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
  8   |  *   - TC-OIDCF2-03 uses page.route() ONLY to abort the navigation to Keycloak
  9   |  *     to capture the outgoing URL without requiring a live Keycloak instance.
  10  |  *     No auth exchange is mocked.
  11  |  *   - TC-OIDCF2-04 uses page.route() ONLY to simulate a 500 from /api/tenant-config.
  12  |  *     This is the one allowed mock — it exercises the error-handling path in
  13  |  *     tenantConfig.ts that cannot be triggered via a live backend alone.
  14  |  *
  15  |  * Directive T-3 compliance:
  16  |  *   - After every significant UI action a screenshot is taken.
  17  |  *   - All verdicts are stated as "screen shows X after Y".
  18  |  *
  19  |  * Infrastructure:
  20  |  *   - Frontend: http://127.0.0.1:4173 (Vite dev server, started by playwright.config.ts)
  21  |  *   - Backend API: available at same origin via Vite proxy (/api → localhost:3000)
  22  |  *   - Default Keycloak realm: http://localhost:8081/realms/bpm-default
  23  |  */
  24  | 
  25  | import { test, expect } from '@playwright/test'
  26  | import * as fs from 'fs'
  27  | import * as path from 'path'
  28  | 
  29  | const SCREENSHOTS_DIR = 'tests/screenshots'
  30  | const KEYCLOAK_AUTH_PATTERN = '**/realms/**/protocol/openid-connect/auth**'
  31  | 
  32  | // ── Screenshot helper ─────────────────────────────────────────────────────────
  33  | 
  34  | async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  35  |   const dir = path.resolve(SCREENSHOTS_DIR)
  36  |   if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  37  |   await page.screenshot({ path: path.join(dir, `OIDCF2-${name}.png`) })
  38  | }
  39  | 
  40  | // ── TC-OIDCF2-01: API returns default config for unknown hostname ──────────────
  41  | 
  42  | test.describe('OIDC-F-05 — Tenant-config endpoint: unknown hostname', () => {
  43  |   test('TC-OIDCF2-01: GET /api/tenant-config?host=unknown.example.com returns default config', async ({ request, page }) => {
  44  |     // Navigate first to get a page context for screenshot
  45  |     await page.goto('/login')
  46  |     await shot(page, 'TC01-01-login-context')
  47  | 
  48  |     const response = await request.get('/api/tenant-config?host=unknown.example.com')
  49  | 
  50  |     // VERDICT: Response is 200 OK with default tenant config fields
  51  |     expect(response.status()).toBe(200)
  52  | 
  53  |     const body = await response.json() as { oidc_authority: string; client_id: string }
  54  | 
  55  |     // oidc_authority must be present and contain the default realm name
  56  |     expect(body.oidc_authority).toBeTruthy()
  57  |     expect(body.oidc_authority).toContain('bpm-default')
  58  | 
  59  |     // client_id must match the platform default
  60  |     expect(body.client_id).toBe('bpm-platform-api')
  61  | 
  62  |     await shot(page, 'TC01-02-after-api-call')
  63  |     // VERDICT: Screen shows login page; API returned default tenant config for unknown.example.com
  64  |   })
  65  | })
  66  | 
  67  | // ── TC-OIDCF2-02: API returns default config for localhost ────────────────────
  68  | 
  69  | test.describe('OIDC-F-05 — Tenant-config endpoint: localhost hostname', () => {
  70  |   test('TC-OIDCF2-02: GET /api/tenant-config?host=localhost returns valid OIDC fields', async ({ request, page }) => {
> 71  |     await page.goto('/login')
      |                ^ Error: page.goto: net::ERR_CONNECTION_REFUSED at http://127.0.0.1:4173/login
  72  |     await shot(page, 'TC02-01-login-context')
  73  | 
  74  |     const response = await request.get('/api/tenant-config?host=localhost')
  75  | 
  76  |     // VERDICT: Response is 200 OK with non-empty OIDC fields
  77  |     expect(response.status()).toBe(200)
  78  | 
  79  |     const body = await response.json() as { oidc_authority: string; client_id: string }
  80  | 
  81  |     expect(body.oidc_authority).toBeTruthy()
  82  |     expect(typeof body.oidc_authority).toBe('string')
  83  |     expect(body.oidc_authority.length).toBeGreaterThan(0)
  84  | 
  85  |     expect(body.client_id).toBeTruthy()
  86  |     expect(typeof body.client_id).toBe('string')
  87  |     expect(body.client_id.length).toBeGreaterThan(0)
  88  | 
  89  |     await shot(page, 'TC02-02-after-api-call')
  90  |     // VERDICT: Screen shows login page; API returned valid oidc_authority and client_id for localhost
  91  |   })
  92  | })
  93  | 
  94  | // ── TC-OIDCF2-03: SSO button uses default realm when loaded from localhost ─────
  95  | 
  96  | test.describe('OIDC-F-06 — Dynamic OIDC config: default realm from localhost', () => {
  97  |   test('TC-OIDCF2-03: SSO button navigation targets bpm-default realm when loaded at localhost', async ({ page }) => {
  98  |     // Abort Keycloak redirects to capture the URL without requiring a live Keycloak instance.
  99  |     // This does NOT mock the auth exchange — signinRedirect() executes fully and we
  100 |     // inspect the outgoing URL before the browser leaves the app.
  101 |     await page.route(KEYCLOAK_AUTH_PATTERN, async (route) => {
  102 |       await route.abort('aborted')
  103 |     })
  104 | 
  105 |     await page.goto('/login')
  106 |     await expect(page.getByTestId('login-sso-button')).toBeVisible()
  107 |     await shot(page, 'TC03-01-login-page-loaded')
  108 | 
  109 |     // Click SSO button and capture the outgoing Keycloak auth request
  110 |     const [capturedRequest] = await Promise.all([
  111 |       page.waitForRequest(
  112 |         (req) => req.url().includes('realms') && req.url().includes('openid-connect/auth'),
  113 |         { timeout: 10_000 },
  114 |       ),
  115 |       page.getByTestId('login-sso-button').click(),
  116 |     ])
  117 | 
  118 |     await shot(page, 'TC03-02-after-sso-click')
  119 | 
  120 |     // VERDICT: Screen shows login page; outgoing Keycloak auth URL contains bpm-default realm
  121 |     expect(capturedRequest.url()).toContain('bpm-default')
  122 |   })
  123 | })
  124 | 
  125 | // ── TC-OIDCF2-04: Frontend falls back to env vars when tenant-config returns 500 ─
  126 | 
  127 | test.describe('OIDC-F-06 — Dynamic OIDC config: 500 fallback to env vars', () => {
  128 |   test('TC-OIDCF2-04: login page renders normally when /api/tenant-config returns 500', async ({ page }) => {
  129 |     // Simulate a 500 error from /api/tenant-config ONLY.
  130 |     // This is the one allowed mock in this suite — it exercises the catch branch
  131 |     // in fetchTenantConfig() that falls back to VITE_OIDC_AUTHORITY / VITE_OIDC_CLIENT_ID.
  132 |     // No Keycloak or auth exchange is mocked.
  133 |     await page.route('/api/tenant-config*', (route) => {
  134 |       route.fulfill({ status: 500, body: 'internal server error' }).catch(() => {
  135 |         // ignore route errors if navigation was aborted
  136 |       })
  137 |     })
  138 | 
  139 |     await page.goto('/login')
  140 | 
  141 |     // VERDICT: Screen shows login page with SSO button visible after tenant-config 500
  142 |     await expect(page.getByTestId('login-sso-button')).toBeVisible({ timeout: 10_000 })
  143 |     await shot(page, 'TC04-01-login-page-after-500')
  144 | 
  145 |     // App must not crash — no error overlay or blank body
  146 |     await expect(page.getByTestId('page-login')).toBeVisible()
  147 |     await shot(page, 'TC04-02-login-page-rendered-normally')
  148 | 
  149 |     // VERDICT: Screen shows complete login page with SSO button; app did not crash after API 500
  150 |   })
  151 | })
  152 | 
```