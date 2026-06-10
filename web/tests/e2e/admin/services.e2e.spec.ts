/**
 * E2E tests for SVC-04 — Admin Services page role-gate.
 *
 * TC-SVC-04-UI-01: platform-admin can view Services page and sees Register Service button.
 * TC-SVC-04-UI-02: non-platform-admin (PROCESS_DESIGNER) sees Services page but NOT Register Service button.
 *
 * Both tests verify against a real running backend (DIRECTIVE T-2: no HTTP mocking).
 * The Services page calls GET /api/v1/admin/services (platform-admin) or
 * GET /api/v1/services (other roles) on load; both real API calls must succeed.
 */

import * as fs from 'fs'
import * as path from 'path'
import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from '../helpers'

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081').replace(/\/$/, '')
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `SVC04-${name}.png`)
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

async function assertServicesReady(request: APIRequestContext): Promise<void> {
  const backend = await request.fetch(`${API_BASE_URL}/health/ready`)
  if (!backend.ok()) {
    throw new Error(`Backend not ready (${backend.status()}) at ${API_BASE_URL}/health/ready`)
  }
  const idp = await request.fetch(KEYCLOAK_DISCOVERY_URL)
  if (!idp.ok()) {
    throw new Error(`Keycloak not ready (${idp.status()}) at ${KEYCLOAK_DISCOVERY_URL}`)
  }
}

async function navigateSpa(page: Page, targetPath: string): Promise<void> {
  await page.evaluate((p) => {
    window.history.pushState({}, '', p)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

test.describe('SVC-04: admin Services page role-gate', () => {
  test.beforeEach(async ({ request }) => {
    await assertServicesReady(request)
  })

  // ── TC-SVC-04-UI-01 ─────────────────────────────────────────────────────────
  test('TC-SVC-04-UI-01: platform-admin sees Services page with Register Service button', async ({ page, request }) => {
    // Login as platform-admin (has PLATFORM_ADMIN role).
    const adminToken = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    await loginWithToken(page, adminToken)

    await navigateSpa(page, '/admin/services')

    // Heading must be visible.
    await expect(page.getByRole('heading', { name: 'Services' })).toBeVisible({ timeout: 15_000 })

    // The "+ Register service" button must be visible for platform-admins.
    const registerBtn = page.getByRole('button', { name: /register service/i })
    await expect(registerBtn).toBeVisible({ timeout: 10_000 })

    // Screen shows: Services heading + Register Service button
    await shot(page, 'UI-01-platform-admin-services-with-register-btn')
  })

  // ── TC-SVC-04-UI-02 ─────────────────────────────────────────────────────────
  test('TC-SVC-04-UI-02: non-platform-admin (PROCESS_DESIGNER) sees Services page without Register Service button', async ({ page, request }) => {
    // Login as designer-user (has PROCESS_DESIGNER role, not PLATFORM_ADMIN).
    const designerToken = await getKeycloakToken(request, 'designer-user', 'designer-pass')
    await loginWithToken(page, designerToken)

    await navigateSpa(page, '/admin/services')

    // Heading must be visible — page is accessible to all authenticated users.
    await expect(page.getByRole('heading', { name: 'Services' })).toBeVisible({ timeout: 15_000 })

    // The Register Service button must NOT be present for non-platform-admins.
    const registerBtn = page.getByRole('button', { name: /register service/i })
    await expect(registerBtn).not.toBeVisible({ timeout: 5_000 })

    // Screen shows: Services heading, no Register Service button
    await shot(page, 'UI-02-non-admin-services-no-register-btn')
  })
})
