/**
 * ONB-UI-02 — Tenant registration form
 *
 * Tests:
 *   1. Submitting empty form shows validation errors on all required fields.
 *   2. Invalid slug format (contains uppercase / special chars) shows slug error.
 *   3. Invalid email (no @) shows email validation error.
 *   4. Hostname with protocol prefix shows hostname validation error.
 *   5. Empty redirect_uris shows URI validation error.
 *   6. Valid form submission navigates to progress screen.
 *
 * No mocks. No MSW. Real Keycloak tokens. Real backend for test 6.
 * Verdict: screen shows the error message text or navigates to /progress.
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

async function assertServicesReady(request: Parameters<typeof getKeycloakToken>[0]) {
  const backend = await request.fetch(`${API_BASE_URL}/health/ready`).catch(() => null)
  if (!backend?.ok()) {
    throw new Error(
      `Backend not ready at ${API_BASE_URL}/health/ready. ` +
      'Ensure docker-compose services are running.'
    )
  }
  const idp = await request.fetch(KEYCLOAK_DISCOVERY).catch(() => null)
  if (!idp?.ok()) {
    throw new Error(
      `Keycloak not ready at ${KEYCLOAK_DISCOVERY}. ` +
      'Ensure docker-compose keycloak service is running.'
    )
  }
}

async function loginAsAdmin(page: Parameters<typeof loginWithToken>[0], request: Parameters<typeof getKeycloakToken>[0]) {
  const token = await getKeycloakToken(request)
  await loginWithToken(page, token)
  await navigateSpa(page, '/admin/onboarding/new')
  await page.waitForSelector('form', { timeout: 15_000 })
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test.describe('ONB-UI-02 — Tenant registration form', () => {

  test('submitting empty form shows validation errors on required fields', async ({ page, request }) => {
    await assertServicesReady(request)
    await loginAsAdmin(page, request)

    await page.screenshot({ path: 'scratch/onb-ui-02-empty-form.png', fullPage: true })

    // Click submit with all fields empty
    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-empty-form-errors.png', fullPage: true })

    // Screen shows inline error messages for required fields
    // Use exact:true where the message text is a prefix of another error message
    await expect(page.getByText('Slug is required')).toBeVisible()
    await expect(page.getByText('Display name is required', { exact: true })).toBeVisible()
    await expect(page.getByText('Admin email is required')).toBeVisible()
    await expect(page.getByText('Admin username is required')).toBeVisible()
    await expect(page.getByText('Admin display name is required')).toBeVisible()
    await expect(page.getByText('Hostname is required')).toBeVisible()
    await expect(page.getByText('At least one redirect URI is required')).toBeVisible()

    // Verify we stayed on the form (no navigation)
    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('invalid slug format shows slug validation error', async ({ page, request }) => {
    await assertServicesReady(request)
    await loginAsAdmin(page, request)

    // Fill slug with invalid value (uppercase + special char)
    await page.locator('#slug').fill('My Slug!')

    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-slug-error.png', fullPage: true })

    // Screen shows the slug-format error message
    await expect(
      page.getByText('Slug may only contain lowercase letters, digits, and hyphens')
    ).toBeVisible()

    // Verify we stayed on the form
    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('invalid email shows email validation error', async ({ page, request }) => {
    await assertServicesReady(request)
    await loginAsAdmin(page, request)

    const uid = randomUUID().slice(0, 8)

    // Fill just enough fields so only email fails
    await page.locator('#slug').fill(`test-${uid}`)
    await page.locator('#display_name').fill(`Test Tenant ${uid}`)
    await page.locator('#admin_email').fill('notanemail')
    await page.locator('#admin_username').fill(`admin-${uid}`)
    await page.locator('#admin_display_name').fill(`Admin ${uid}`)
    await page.locator('#hostname').fill(`tenant-${uid}.example.com`)
    await page.locator('input[placeholder*="callback"]').first().fill('https://app.example.com/cb')

    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-email-error.png', fullPage: true })

    // Screen shows the email error message
    await expect(page.getByText('Enter a valid email address')).toBeVisible()

    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('hostname with protocol prefix shows hostname validation error', async ({ page, request }) => {
    await assertServicesReady(request)
    await loginAsAdmin(page, request)

    const uid = randomUUID().slice(0, 8)

    await page.locator('#slug').fill(`test-${uid}`)
    await page.locator('#display_name').fill(`Test Tenant ${uid}`)
    await page.locator('#admin_email').fill(`admin@test-${uid}.example.com`)
    await page.locator('#admin_username').fill(`admin-${uid}`)
    await page.locator('#admin_display_name').fill(`Admin ${uid}`)
    // Provide hostname WITH a protocol prefix — must be rejected
    await page.locator('#hostname').fill(`https://tenant-${uid}.example.com`)
    await page.locator('input[placeholder*="callback"]').first().fill('https://app.example.com/cb')

    await page.getByRole('button', { name: /register tenant/i }).click()

    await page.screenshot({ path: 'scratch/onb-ui-02-hostname-error.png', fullPage: true })

    // Screen shows the hostname error message
    await expect(page.getByText('Enter a hostname only (no protocol or path)')).toBeVisible()

    expect(page.url()).toContain('/admin/onboarding/new')
  })

  test('valid form submission navigates to progress screen', async ({ page, request }) => {
    await assertServicesReady(request)
    await loginAsAdmin(page, request)

    const uid = randomUUID().slice(0, 8)
    const slug = `test-${uid}`

    // Fill all required fields with valid values
    await page.locator('#slug').fill(slug)
    await page.locator('#display_name').fill(`Test Tenant ${uid}`)
    await page.locator('#admin_email').fill(`admin@test-${uid}.example.com`)
    await page.locator('#admin_username').fill(`admin-${uid}`)
    await page.locator('#admin_display_name').fill(`Admin ${uid}`)
    await page.locator('#hostname').fill(`tenant-${uid}.example.com`)
    await page.locator('input[placeholder*="callback"]').first().fill('https://app.example.com/cb')

    await page.screenshot({ path: 'scratch/onb-ui-02-filled-form.png', fullPage: true })

    // Submit the form
    await page.getByRole('button', { name: /register tenant/i }).click()

    // Screen must show the progress page (URL changes to /progress)
    await page.waitForURL(/\/admin\/onboarding\/.+\/progress/, { timeout: 30_000 })

    await page.screenshot({ path: 'scratch/onb-ui-02-after-submit-progress.png', fullPage: true })

    // Screen shows the progress heading or spinner
    const progressHeading = page.getByRole('heading', { name: /onboarding in progress/i })
    const spinner = page.locator('[role="status"]')

    const headingVisible = await progressHeading.isVisible().catch(() => false)
    const spinnerVisible  = await spinner.isVisible().catch(() => false)

    expect(
      headingVisible || spinnerVisible,
      'Screen must show either "Onboarding in Progress" heading or a status spinner after form submission'
    ).toBe(true)
  })

  test('each submission attempt generates a distinct Idempotency-Key header', async ({ page, request }) => {
    const token = await getKeycloakToken(request, 'admin-user', 'admin-pass')
    await loginWithToken(page, token)
    await navigateSpa(page, '/admin/onboarding/new')
    await page.waitForSelector('form', { timeout: 15_000 })

    const capturedKeys: string[] = []
    await page.route('**/api/v1/onboarding', async (route) => {
      const headers = route.request().headers()
      const key = headers['idempotency-key'] ?? headers['Idempotency-Key'] ?? ''
      if (key) capturedKeys.push(key)
      await route.continue()
    })

    const id1 = randomUUID().slice(0, 8)
    const fillAndSubmit = async (slug: string) => {
      // Use id-based selectors matching RegisterTenantPage's DOM structure
      await page.locator('#slug').fill(slug)
      await page.locator('#display_name').fill(`Test ${slug}`)
      await page.locator('#admin_email').fill(`admin@${slug}.example.com`)
      await page.locator('#admin_username').fill(`admin-${slug}`)
      await page.locator('#admin_display_name').fill(`Admin ${slug}`)
      await page.locator('#hostname').fill(`${slug}.localhost`)
      const uriInputs = await page.locator('input[placeholder*="callback"]').all()
      if (uriInputs.length > 0) await uriInputs[0].fill(`http://${slug}.localhost/*`)
      await page.click('button[type="submit"]')
      await page.waitForTimeout(500)
    }

    await fillAndSubmit(id1)
    // Navigate back to form for second attempt
    await navigateSpa(page, '/admin/onboarding/new')
    await page.waitForSelector('form', { timeout: 10_000 })
    const id2 = randomUUID().slice(0, 8)
    await fillAndSubmit(id2)

    await page.screenshot({ path: 'scratch/onb-ui-02-idempotency-keys.png', fullPage: true })

    expect(capturedKeys.length).toBeGreaterThanOrEqual(2)
    expect(capturedKeys[0]).not.toBe(capturedKeys[1])
  })

})
