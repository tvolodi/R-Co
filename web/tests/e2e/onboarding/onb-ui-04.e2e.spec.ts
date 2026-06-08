/**
 * ONB-UI-04 — Onboarding result screen
 *
 * Tests:
 *   1. Completed result screen shows slug and oidc_authority.
 *   2. "Try Again" navigates back to form with prefilled values.
 *   3. Page-reload restore — navigate to result URL with ?hostname=<h>, reload, verify result shown.
 *
 * No mocks. No MSW. Real Keycloak + real backend required.
 * Tests 1 and 3 require a completed saga; test 2 uses injected router state.
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
} from '../pipeline'

// Saga completion may take up to 90 s
test.setTimeout(120_000)

const API_BASE_URL       = process.env.BPM_TEST_URL     ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL  = process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081'
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

/**
 * Run the full form → progress → result flow and return the final URL parts.
 */
async function runFullWizard(
  page: Parameters<typeof loginWithToken>[0],
  request: Parameters<typeof getKeycloakToken>[0],
): Promise<{ slug: string; hostname: string; onboardingId: string; resultUrl: string }> {
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

  // Wait for saga to reach terminal state (completed OR failed).
  // Allow 150s because multiple concurrent background sagas may slow Keycloak realm creation.
  await page.waitForURL(/\/admin\/onboarding\/.+\/result/, { timeout: 150_000 })

  const resultUrl  = page.url()
  const urlObj     = new URL(resultUrl, 'http://localhost')
  const segments   = urlObj.pathname.split('/').filter(Boolean)
  // path: /admin/onboarding/<id>/result
  const onboardingId = segments[segments.indexOf('onboarding') + 1] ?? ''

  return { slug, hostname, onboardingId, resultUrl }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test.describe('ONB-UI-04 — Onboarding result screen', () => {

  test('completed result screen shows slug and oidc_authority', async ({ page, request }) => {
    await assertServicesReady(request)

    const { slug } = await runFullWizard(page, request)

    await page.screenshot({ path: 'scratch/onb-ui-04-result-screen.png', fullPage: true })

    // MUST path: success assertions are required for this test and must not be skipped.
    const successBanner = page.getByText(/tenant onboarding completed successfully/i)
    await expect(successBanner).toBeVisible({ timeout: 30_000 })

    // Screen shows the tenant slug (exact:true to avoid matching the same text inside the oidc_authority URL)
    await expect(page.getByText(slug, { exact: true })).toBeVisible()

    // Screen shows the oidc_authority URL (a link)
    const oidcLink = page.getByRole('link', { name: /http.*realms/i })
    await expect(oidcLink).toBeVisible()

    // Completed result exposes readiness confirmations for completion gate checks
    await expect(page.getByText('Tenant Visible')).toBeVisible()
    await expect(page.getByText('OIDC Authority Ready')).toBeVisible()
    await expect(page.getByText('Schema Materialized')).toBeVisible()
    await expect(page.getByText('Ready', { exact: true })).toHaveCount(3)

    // Back to Admin button is present
    await expect(page.getByRole('button', { name: /back to admin/i })).toBeVisible()
  })

  test('"Try Again" navigates back to form with prefilled slug', async ({ page, request }) => {
      await assertServicesReady(request)

      const uid = randomUUID().slice(0, 8)
      const slug = `test-${uid}`
      const hostname = `tenant-${uid}.example.com`

      const token = await getKeycloakToken(request)
      await loginWithToken(page, token)

      // Navigate once so the SPA runtime is initialized.
      await navigateSpa(page, '/admin/onboarding/new')
      await page.waitForSelector('form', { timeout: 15_000 })

      // Inject router location.state with a failed saga result.
      // This validates the failed-result UI without HTTP mocking.
      await page.evaluate(({ testSlug, testHostname }) => {
        const state = {
          usr: {
            sagaResult: {
              state: 'failed',
              error: 'Simulated failure for Try Again test',
            },
            formValues: {
              slug: testSlug,
              display_name: `Test Tenant ${testSlug}`,
              admin_email: `admin@${testSlug}.example.com`,
              admin_username: `admin-${testSlug}`,
              admin_display_name: `Admin ${testSlug}`,
              hostname: testHostname,
              redirect_uris: ['https://app.example.com/cb'],
            },
          },
          key: 'onb-ui-04-failed-state',
          idx: 1,
        }

        window.history.pushState(state, '', '/admin/onboarding/00000000-0000-0000-0000-000000000000/result')
        window.dispatchEvent(new PopStateEvent('popstate', { state }))
      }, { testSlug: slug, testHostname: hostname })

      await page.waitForURL(/\/admin\/onboarding\/.+\/result/, { timeout: 15_000 })

    await page.screenshot({ path: 'scratch/onb-ui-04-failed-result.png', fullPage: true })

    // Screen shows the failed result text (not just URL containing "result")
    await expect(page.getByText('Onboarding failed.')).toBeVisible({ timeout: 15_000 })
    await expect(page.getByText('Simulated failure for Try Again test')).toBeVisible()

    // Click "Try Again"
    await page.getByRole('button', { name: /try again/i }).click()

    // Screen must show the registration form at /admin/onboarding/new
    await page.waitForURL(/\/admin\/onboarding\/new/, { timeout: 15_000 })

    await page.screenshot({ path: 'scratch/onb-ui-04-try-again-prefill.png', fullPage: true })

    // Screen shows the registration form with the slug field prefilled
    const slugInput = page.locator('#slug')
    await expect(slugInput).toHaveValue(slug)
  })

  test('page-reload restore via ?hostname= shows completed result', async ({ page, request }) => {
    await assertServicesReady(request)

    const { slug, hostname, onboardingId, resultUrl } = await runFullWizard(page, request)

    // MUST path: this test requires completed state before reload restore assertions.
    await expect(page.getByText(/tenant onboarding completed successfully/i)).toBeVisible({
      timeout: 30_000,
    })

    // Reload the page — this clears React Router state
    const urlWithHostname = resultUrl.includes('?hostname=')
      ? resultUrl
      : `/admin/onboarding/${onboardingId}/result?hostname=${encodeURIComponent(hostname)}`

    // Navigate directly to result URL (simulating reload with no router state)
    await page.goto(urlWithHostname, { waitUntil: 'domcontentloaded' })

    // Screen briefly shows loading indicator
    const loadingText = page.getByText(/restoring onboarding state/i)
    // Loading may be very brief — don't assert it must be visible, just wait for it to resolve

    // Wait for the result to be shown (API call completes)
    await expect(page.getByText(/tenant onboarding completed successfully/i)).toBeVisible({
      timeout: 20_000,
    })

    await page.screenshot({ path: 'scratch/onb-ui-04-page-reload-restore.png', fullPage: true })

    // Screen shows slug after page reload restore (exact:true to avoid matching in oidc_authority URL)
    await expect(page.getByText(slug, { exact: true })).toBeVisible()

    // Screen shows oidc_authority link
    const oidcLink = page.getByRole('link', { name: /http.*realms/i })
    await expect(oidcLink).toBeVisible()

    // Reloaded completed screen still shows readiness confirmations
    await expect(page.getByText('Tenant Visible')).toBeVisible()
    await expect(page.getByText('OIDC Authority Ready')).toBeVisible()
    await expect(page.getByText('Schema Materialized')).toBeVisible()
    await expect(page.getByText('Ready', { exact: true })).toHaveCount(3)

    void loadingText // referenced for documentation; state may resolve before assertion
  })

})
