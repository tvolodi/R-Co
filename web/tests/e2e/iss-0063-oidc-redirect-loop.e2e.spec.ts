/**
 * E2E regression suite — ISS-0063: OIDC login redirect loop
 *
 * Covers the three real-environment failure surfaces end-to-end:
 *   1. tenant-config must return the browser-visible localhost authority on :8081
 *   2. the authorization redirect must target the preserved authority and the
 *      browser must return through the real Keycloak callback path
 *   3. a callback-page reload must not lose the OIDC state needed to finish login
 *
 * This suite uses no mocks or stubs. If BPM_TEST_DB_URL, BPM_TEST_URL, or
 * BPM_IDP_BASE_URL are missing, or if the backend / Keycloak readiness checks fail,
 * the tests throw a clear prerequisite error and fail immediately.
 */

import { test, expect, type APIRequestContext, type Page } from '@playwright/test'

const API_BASE_URL = (process.env.BPM_TEST_URL ?? '').replace(/\/$/, '')
const KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? '').replace(/\/$/, '')
const REQUIRED_DB_URL = process.env.BPM_TEST_DB_URL ?? ''
const SCREENSHOTS_DIR = 'tests/screenshots'
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

function requireEnv(name: string, value: string): string {
  if (!value) {
    throw new Error(`ISS-0063 prerequisite not satisfied: ${name} is missing`)
  }

  return value
}

async function screenshot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: `${SCREENSHOTS_DIR}/ISS-0063-${name}.png` })
}

async function ensurePrerequisites(request: APIRequestContext): Promise<void> {
  requireEnv('BPM_TEST_DB_URL', REQUIRED_DB_URL)
  const apiBaseUrl = requireEnv('BPM_TEST_URL', API_BASE_URL)
  const keycloakBaseUrl = requireEnv('BPM_IDP_BASE_URL', KEYCLOAK_BASE_URL)

  const backendHealth = await request.get(`${apiBaseUrl}/health/ready`)
  if (!backendHealth.ok()) {
    throw new Error(`ISS-0063 prerequisite not satisfied: backend readiness check failed (${backendHealth.status()}) at ${apiBaseUrl}/health/ready`)
  }

  const keycloakDiscovery = await request.get(`${keycloakBaseUrl}/realms/bpm-default/.well-known/openid-configuration`)
  if (!keycloakDiscovery.ok()) {
    throw new Error(`ISS-0063 prerequisite not satisfied: Keycloak discovery check failed (${keycloakDiscovery.status()}) at ${KEYCLOAK_DISCOVERY_URL}`)
  }
}

async function assertTenantConfig(request: APIRequestContext): Promise<void> {
  const response = await request.get('/api/tenant-config?host=localhost')
  expect(response.status()).toBe(200)

  const body = await response.json() as { oidc_authority: string; client_id: string }
  expect(body.oidc_authority).toContain('http://localhost:8081/realms/')
  expect(body.oidc_authority).not.toContain('127.0.0.1')
  expect(body.client_id).toBe('bpm-platform-api')
}

async function waitForKeycloakAuthRequest(page: Page): Promise<string> {
  const captured = await page.waitForRequest(
    (request) => request.url().includes('/protocol/openid-connect/auth'),
    { timeout: 20_000 },
  )

  return captured.url()
}

async function completeBrowserLogin(page: Page, username: string, password: string): Promise<void> {
  const usernameInput = page.locator('input#username, input[name="username"]').first()
  const passwordInput = page.locator('input#password, input[name="password"]').first()

  await expect(usernameInput).toBeVisible({ timeout: 20_000 })
  await expect(passwordInput).toBeVisible({ timeout: 20_000 })
  await screenshot(page, 'keycloak-login-form')

  await usernameInput.fill(username)
  await passwordInput.fill(password)
  await screenshot(page, 'keycloak-credentials-filled')

  await page.locator('input[name="login"], [type="submit"]').first().click()
  await expect(page.getByTestId('oidc-callback-status')).toBeVisible({ timeout: 20_000 })
}

async function assertAuthenticatedWorkspace(page: Page): Promise<void> {
  await expect(page).toHaveURL('/')
  await expect(page.getByTestId('user-display-name')).toBeVisible({ timeout: 20_000 })
  await expect(page.getByTestId('logout-button')).toBeVisible()
  await screenshot(page, 'workspace-authenticated')
}

test.describe('ISS-0063 — OIDC login redirect loop regression', () => {
  test('TC-ISS-0063-00: suite preflight fails fast when required backend/browser prerequisites are missing', async ({ request }) => {
    await ensurePrerequisites(request)
  })

  test('TC-ISS-0063-01: tenant-config returns the browser-visible localhost authority with port 8081', async ({ request, page }) => {
    await ensurePrerequisites(request)

    await page.goto('/')
    await screenshot(page, 'tenant-config-preflight')

    await assertTenantConfig(request)

    await screenshot(page, 'tenant-config-validated')
    await expect(page.getByTestId('page-oidc-callback')).toHaveCount(0)
  })

  test('TC-ISS-0063-02: login redirect targets Keycloak on the preserved authority and completes the real Keycloak return path', async ({ request, page }) => {
    await ensurePrerequisites(request)

    const authRequestPromise = waitForKeycloakAuthRequest(page)

    await page.goto('/')
    const authUrl = await authRequestPromise
    expect(authUrl).toContain('localhost:8081')
    expect(authUrl).toContain('/realms/bpm-default/protocol/openid-connect/auth')
    await screenshot(page, 'auth-request-captured')

    await completeBrowserLogin(page, 'admin-user', 'admin-pass')
    await page.waitForURL('/', { timeout: 20_000 })

    await assertAuthenticatedWorkspace(page)
  })

  test('TC-ISS-0063-03: callback state survives a callback-page reload and completes login', async ({ request, page }) => {
    await ensurePrerequisites(request)

    await page.goto('/')
    await waitForKeycloakAuthRequest(page)
    await completeBrowserLogin(page, 'admin-user', 'admin-pass')
    await screenshot(page, 'callback-before-reload')

    await page.reload({ waitUntil: 'domcontentloaded' })
    await page.waitForURL('/', { timeout: 20_000 })

    await assertAuthenticatedWorkspace(page)
  })
})