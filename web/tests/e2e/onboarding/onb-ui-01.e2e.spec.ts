/**
 * ONB-UI-01 — Register Tenant entry point
 *
 * Tests:
 *   1. PLATFORM_ADMIN sees "Register Tenant" in the sidebar nav.
 *   2. A non-PLATFORM_ADMIN user (TASK_WORKER) does NOT see it — absent from DOM.
 *
 * No mocks. No MSW. Real Keycloak tokens via getKeycloakToken().
 * Verdict: "screen shows X after Y" — screenshots taken after each action.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
} from '../pipeline'

const API_BASE_URL       = process.env.BPM_TEST_URL     ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL  = process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081'
const KEYCLOAK_DISCOVERY = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

// ── Pre-flight ────────────────────────────────────────────────────────────────

async function assertServicesReady(request: Parameters<typeof getKeycloakToken>[0]) {
  const backend = await request.fetch(`${API_BASE_URL}/health/ready`).catch(() => null)
  if (!backend?.ok()) {
    throw new Error(
      `Backend not ready at ${API_BASE_URL}/health/ready. ` +
      'Ensure docker-compose services are running before executing these tests.'
    )
  }
  const idp = await request.fetch(KEYCLOAK_DISCOVERY).catch(() => null)
  if (!idp?.ok()) {
    throw new Error(
      `Keycloak not ready at ${KEYCLOAK_DISCOVERY}. ` +
      'Ensure docker-compose keycloak service is running before executing these tests.'
    )
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test.describe('ONB-UI-01 — Register Tenant entry point', () => {

  test('PLATFORM_ADMIN sees "Register Tenant" nav entry in the sidebar', async ({ page, request }) => {
    await assertServicesReady(request)

    const token = await getKeycloakToken(request)
    await loginWithToken(page, token)
    await navigateSpa(page, '/admin/users')

    // Wait for the admin shell to settle
    await page.waitForSelector('[data-testid="nav-sidebar"], nav', { timeout: 15_000 })

    await page.screenshot({ path: 'scratch/onb-ui-01-platform-admin-nav.png', fullPage: true })

    // Screen must show "Register Tenant" as a navigable link or button
    const registerTenantEntry = page
      .getByRole('link', { name: /register tenant/i })
      .or(page.getByRole('button', { name: /register tenant/i }))

    await expect(registerTenantEntry.first()).toBeVisible({ timeout: 10_000 })

    // Clicking it must navigate to /admin/onboarding/new
    await registerTenantEntry.first().click()
    await page.waitForURL(/\/admin\/onboarding\/new/, { timeout: 10_000 })

    await page.screenshot({ path: 'scratch/onb-ui-01-register-tenant-page.png', fullPage: true })

    // Screen shows the "Register Tenant" heading on the form page
    await expect(page.getByRole('heading', { name: /register tenant/i })).toBeVisible()
  })

  test('TASK_WORKER user does NOT see "Register Tenant" in the sidebar (absent from DOM)', async ({ page, request }) => {
    await assertServicesReady(request)

    // Use TASK_WORKER credentials — must not have PLATFORM_ADMIN role
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    await loginWithToken(page, token)
    await navigateSpa(page, '/admin/users')

    // Wait for the shell to render
    await page.waitForSelector('[data-testid="nav-sidebar"], nav', { timeout: 15_000 })

    await page.screenshot({ path: 'scratch/onb-ui-01-task-worker-nav.png', fullPage: true })

    // "Register Tenant" must not appear anywhere in the rendered DOM
    const registerTenantEntry = page
      .getByRole('link', { name: /register tenant/i })
      .or(page.getByRole('button', { name: /register tenant/i }))

    // count() returns 0 immediately if element is not in DOM
    await expect(registerTenantEntry).toHaveCount(0)

    // Additional guard: text content must also be absent
    const bodyText = await page.locator('body').textContent()
    expect(
      bodyText?.toLowerCase().includes('register tenant'),
      'Body text must not contain "Register Tenant" for non-PLATFORM_ADMIN users'
    ).toBe(false)
  })

  test('non-PLATFORM_ADMIN navigating directly to /admin/onboarding/new is redirected away', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    await loginWithToken(page, token)
    await navigateSpa(page, '/admin/onboarding/new')
    await page.waitForTimeout(2_000)

    await page.screenshot({ path: 'scratch/onb-ui-01-direct-nav-redirect.png', fullPage: true })

    // Must NOT show the registration form — should have redirected to /instances or similar
    const formVisible = await page.locator('form').isVisible().catch(() => false)
    expect(formVisible, 'Non-PLATFORM_ADMIN must not see the registration form when navigating directly').toBe(false)
    expect(page.url()).not.toContain('/admin/onboarding')
  })

  test('non-PLATFORM_ADMIN navigating directly to a progress URL is redirected away', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    await loginWithToken(page, token)
    await navigateSpa(page, `/admin/onboarding/${randomUUID()}/progress`)
    await page.waitForTimeout(2_000)

    await page.screenshot({ path: 'scratch/onb-ui-01-progress-redirect.png', fullPage: true })

    const progressVisible = await page.locator('[data-testid="progress-screen"], [aria-label*="progress" i]').isVisible().catch(() => false)
    expect(progressVisible, 'Non-PLATFORM_ADMIN must not see progress screen when navigating directly').toBe(false)
    expect(page.url()).not.toContain('/progress')
  })

  test('non-PLATFORM_ADMIN navigating directly to a result URL is redirected away', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    await loginWithToken(page, token)
    await navigateSpa(page, `/admin/onboarding/${randomUUID()}/result?hostname=test.localhost`)
    await page.waitForTimeout(2_000)

    await page.screenshot({ path: 'scratch/onb-ui-01-result-redirect.png', fullPage: true })

    const resultVisible = await page.locator('[data-testid="result-screen"], [class*="result"]').isVisible().catch(() => false)
    expect(resultVisible, 'Non-PLATFORM_ADMIN must not see result screen when navigating directly').toBe(false)
    expect(page.url()).not.toContain('/result')
  })

})
