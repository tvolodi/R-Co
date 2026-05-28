/**
 * E2E tests — Stage F1.6: Subdomain Tenant Routing
 * Requirements: OIDC-F-05 (MUST), OIDC-F-06 (MUST)
 * Run: WF02-oidcf2-20260528
 *
 * Directive T-2 compliance:
 *   - No MSW, no axios-mock-adapter, no manual fetch intercepts.
 *   - TC-OIDCF2-03 uses page.route() ONLY to abort the navigation to Keycloak
 *     to capture the outgoing URL without requiring a live Keycloak instance.
 *     No auth exchange is mocked.
 *   - TC-OIDCF2-04 uses page.route() ONLY to simulate a 500 from /api/tenant-config.
 *     This is the one allowed mock — it exercises the error-handling path in
 *     tenantConfig.ts that cannot be triggered via a live backend alone.
 *
 * Directive T-3 compliance:
 *   - After every significant UI action a screenshot is taken.
 *   - All verdicts are stated as "screen shows X after Y".
 *
 * Infrastructure:
 *   - Frontend: http://127.0.0.1:4173 (Vite dev server, started by playwright.config.ts)
 *   - Backend API: available at same origin via Vite proxy (/api → localhost:3000)
 *   - Default Keycloak realm: http://localhost:8081/realms/bpm-default
 */

import { test, expect } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'

const SCREENSHOTS_DIR = 'tests/screenshots'
const KEYCLOAK_AUTH_PATTERN = '**/realms/**/protocol/openid-connect/auth**'

// ── Screenshot helper ─────────────────────────────────────────────────────────

async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  await page.screenshot({ path: path.join(dir, `OIDCF2-${name}.png`) })
}

// ── TC-OIDCF2-01: API returns default config for unknown hostname ──────────────

test.describe('OIDC-F-05 — Tenant-config endpoint: unknown hostname', () => {
  test('TC-OIDCF2-01: GET /api/tenant-config?host=unknown.example.com returns default config', async ({ request, page }) => {
    // Navigate first to get a page context for screenshot
    await page.goto('/login')
    await shot(page, 'TC01-01-login-context')

    const response = await request.get('/api/tenant-config?host=unknown.example.com')

    // VERDICT: Response is 200 OK with default tenant config fields
    expect(response.status()).toBe(200)

    const body = await response.json() as { oidc_authority: string; client_id: string }

    // oidc_authority must be present and contain the default realm name
    expect(body.oidc_authority).toBeTruthy()
    expect(body.oidc_authority).toContain('bpm-default')

    // client_id must match the platform default
    expect(body.client_id).toBe('bpm-platform-api')

    await shot(page, 'TC01-02-after-api-call')
    // VERDICT: Screen shows login page; API returned default tenant config for unknown.example.com
  })
})

// ── TC-OIDCF2-02: API returns default config for localhost ────────────────────

test.describe('OIDC-F-05 — Tenant-config endpoint: localhost hostname', () => {
  test('TC-OIDCF2-02: GET /api/tenant-config?host=localhost returns valid OIDC fields', async ({ request, page }) => {
    await page.goto('/login')
    await shot(page, 'TC02-01-login-context')

    const response = await request.get('/api/tenant-config?host=localhost')

    // VERDICT: Response is 200 OK with non-empty OIDC fields
    expect(response.status()).toBe(200)

    const body = await response.json() as { oidc_authority: string; client_id: string }

    expect(body.oidc_authority).toBeTruthy()
    expect(typeof body.oidc_authority).toBe('string')
    expect(body.oidc_authority.length).toBeGreaterThan(0)

    expect(body.client_id).toBeTruthy()
    expect(typeof body.client_id).toBe('string')
    expect(body.client_id.length).toBeGreaterThan(0)

    await shot(page, 'TC02-02-after-api-call')
    // VERDICT: Screen shows login page; API returned valid oidc_authority and client_id for localhost
  })
})

// ── TC-OIDCF2-03: SSO button uses default realm when loaded from localhost ─────

test.describe('OIDC-F-06 — Dynamic OIDC config: default realm from localhost', () => {
  test('TC-OIDCF2-03: SSO button navigation targets bpm-default realm when loaded at localhost', async ({ page }) => {
    // Abort Keycloak redirects to capture the URL without requiring a live Keycloak instance.
    // This does NOT mock the auth exchange — signinRedirect() executes fully and we
    // inspect the outgoing URL before the browser leaves the app.
    await page.route(KEYCLOAK_AUTH_PATTERN, async (route) => {
      await route.abort('aborted')
    })

    await page.goto('/login')
    await expect(page.getByTestId('login-sso-button')).toBeVisible()
    await shot(page, 'TC03-01-login-page-loaded')

    // Click SSO button and capture the outgoing Keycloak auth request
    const [capturedRequest] = await Promise.all([
      page.waitForRequest(
        (req) => req.url().includes('realms') && req.url().includes('openid-connect/auth'),
        { timeout: 10_000 },
      ),
      page.getByTestId('login-sso-button').click(),
    ])

    await shot(page, 'TC03-02-after-sso-click')

    // VERDICT: Screen shows login page; outgoing Keycloak auth URL contains bpm-default realm
    expect(capturedRequest.url()).toContain('bpm-default')
  })
})

// ── TC-OIDCF2-04: Frontend falls back to env vars when tenant-config returns 500 ─

test.describe('OIDC-F-06 — Dynamic OIDC config: 500 fallback to env vars', () => {
  test('TC-OIDCF2-04: login page renders normally when /api/tenant-config returns 500', async ({ page }) => {
    // Simulate a 500 error from /api/tenant-config ONLY.
    // This is the one allowed mock in this suite — it exercises the catch branch
    // in fetchTenantConfig() that falls back to VITE_OIDC_AUTHORITY / VITE_OIDC_CLIENT_ID.
    // No Keycloak or auth exchange is mocked.
    await page.route('/api/tenant-config*', (route) => {
      route.fulfill({ status: 500, body: 'internal server error' }).catch(() => {
        // ignore route errors if navigation was aborted
      })
    })

    await page.goto('/login')

    // VERDICT: Screen shows login page with SSO button visible after tenant-config 500
    await expect(page.getByTestId('login-sso-button')).toBeVisible({ timeout: 10_000 })
    await shot(page, 'TC04-01-login-page-after-500')

    // App must not crash — no error overlay or blank body
    await expect(page.getByTestId('page-login')).toBeVisible()
    await shot(page, 'TC04-02-login-page-rendered-normally')

    // VERDICT: Screen shows complete login page with SSO button; app did not crash after API 500
  })
})
