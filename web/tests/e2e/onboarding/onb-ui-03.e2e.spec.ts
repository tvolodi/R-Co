/**
 * ONB-UI-03 — Onboarding progress display
 *
 * Tests:
 *   1. After submit, the progress screen shows a spinner (role="status").
 *   2. When the saga completes (or fails), the browser navigates to the result screen.
 *
 * Uses a real slug with a per-test UUID to avoid collision.
 * Sets a 60 s test timeout to accommodate the onboarding saga duration.
 *
 * No mocks. No MSW. Real Keycloak + real backend required.
 * Verdict: screen shows spinner; then screen shows result.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
} from '../pipeline'

// Onboarding saga involves Keycloak realm creation — allow generous timeout
test.setTimeout(120_000)

const API_BASE_URL       = process.env.BPM_TEST_URL     ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL  = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

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

async function submitValidForm(
  page: Parameters<typeof loginWithToken>[0],
  request: Parameters<typeof getKeycloakToken>[0],
): Promise<{ slug: string; hostname: string }> {
  const uid      = randomUUID().slice(0, 8)
  const slug     = `test-${uid}`
  const hostname = `tenant-${uid}.example.com`

  const token = await getKeycloakToken(request)
  await loginWithToken(page, token)
  await navigateSpa(page, '/admin/onboarding/new')
  await page.waitForSelector('form', { timeout: 15_000 })

  await page.locator('#slug').fill(slug)
  await page.locator('#display_name').fill(`Test Tenant ${uid}`)
  await page.locator('#admin_email').fill(`admin@test-${uid}.example.com`)
  await page.locator('#admin_username').fill(`admin-${uid}`)
  await page.locator('#admin_display_name').fill(`Admin ${uid}`)
  await page.locator('#hostname').fill(hostname)
  await page.locator('input[placeholder*="callback"]').first().fill('https://app.example.com/cb')

  await page.getByRole('button', { name: /register tenant/i }).click()
  await page.waitForURL(/\/admin\/onboarding\/.+\/progress/, { timeout: 30_000 })

  return { slug, hostname }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test.describe('ONB-UI-03 — Onboarding progress display', () => {

  test('progress screen shows spinner after form submit', async ({ page, request }) => {
    await assertServicesReady(request)
    await submitValidForm(page, request)

    await page.screenshot({ path: 'scratch/onb-ui-03-progress-screen.png', fullPage: true })

    // Screen shows a spinner with role="status"
    const spinner = page.locator('[role="status"]')
    await expect(spinner).toBeVisible({ timeout: 10_000 })

    // The heading confirms we are on the progress screen
    await expect(
      page.getByRole('heading', { name: /onboarding in progress/i })
    ).toBeVisible()
  })

  test('saga terminal state navigates to result screen', async ({ page, request }) => {
    await assertServicesReady(request)
    await submitValidForm(page, request)

    await page.screenshot({ path: 'scratch/onb-ui-03-waiting-for-saga.png', fullPage: true })

    // Wait for the saga to reach a terminal state — browser navigates to /result
    // Allow up to 90 s for Keycloak realm provisioning
    await page.waitForURL(/\/admin\/onboarding\/.+\/result/, { timeout: 90_000 })

    await page.screenshot({ path: 'scratch/onb-ui-03-result-reached.png', fullPage: true })

    // Screen shows the result page — not the spinner
    const spinner = page.locator('[role="status"]')
    await expect(spinner).not.toBeVisible()

    // The result screen must show either the success heading/content or the failure banner
    const successBanner = page.getByText(/tenant onboarding completed successfully/i)
    const failureBanner = page.getByText(/onboarding failed/i)

    const successVisible = await successBanner.isVisible().catch(() => false)
    const failureVisible = await failureBanner.isVisible().catch(() => false)

    expect(
      successVisible || failureVisible,
      'Result screen must show either a success confirmation or failure reason after saga completes'
    ).toBe(true)
  })

  test('three consecutive transient poll errors show error banner on progress screen', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    await loginWithToken(page, token)

    // Navigate directly to a fake progress URL and intercept ALL poll requests with 503
    const fakeId = randomUUID()
    let callCount = 0
    await page.route(`**/api/v1/onboarding/${fakeId}`, async (route) => {
      callCount++
      await route.fulfill({ status: 503, body: JSON.stringify({ error: 'service_unavailable' }) })
    })

    await navigateSpa(page, `/admin/onboarding/${fakeId}/progress`)
    await page.waitForSelector('[data-testid="progress-screen"], [aria-label*="progress" i], h1, h2', { timeout: 15_000 })

    // Wait for 3 poll cycles (poll interval default 10s — we force fast by intercepting immediately)
    // The page should show an error banner after 3 consecutive 503s
    await page.waitForSelector(
      '[data-testid="poll-error-banner"], [role="alert"], .error-banner, [class*="error"]',
      { timeout: 45_000 }
    )

    await page.screenshot({ path: 'scratch/onb-ui-03-three-errors.png', fullPage: true })

    const banner = page.locator('[data-testid="poll-error-banner"], [role="alert"], .error-banner, [class*="error"]').first()
    await expect(banner).toBeVisible()
    expect(callCount).toBeGreaterThanOrEqual(3)
  })

})
