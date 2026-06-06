/**
 * E2E tests for TM-01 (tenant list page) and TM-03 (edit tenant page).
 *
 * TC-TM-UI-01: PLATFORM_ADMIN navigates to /admin/tenants and sees tenant list
 * TC-TM-UI-02: Non-admin is redirected away from /admin/tenants
 * TC-TM-UI-03: Edit button navigates to /admin/tenants/:slug/edit
 * TC-TM-UI-04: EditTenantPage shows slug and idp_realm_id as read-only
 * TC-TM-UI-05: EditTenantPage allows editing display_name and saving
 * TC-TM-UI-06: 'Register New Tenant' button navigates to /admin/onboarding/new
 * TC-TM-UI-07: 'Tenants' nav link is hidden from non-PLATFORM_ADMIN
 * TC-TM-UI-08: PLATFORM_ADMIN can deactivate and reactivate a tenant via lifecycle controls
 * TC-TM-UI-09: Lifecycle controls are state-driven (ACTIVE shows Deactivate, INACTIVE shows Reactivate)
 *
 * All tests run against the real backend (no mocks, no MSW).
 * Every verdict is visual: screenshots are taken and asserted on visible content.
 */

import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { randomUUID } from 'crypto'
import * as fs from 'fs'
import * as path from 'path'
import { getKeycloakToken, loginWithToken } from './helpers'

// ── Config ────────────────────────────────────────────────────────────────────

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081')
  .replace('://127.0.0.1', '://localhost')
  .replace(/\/$/, '')
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

// ── Helpers ───────────────────────────────────────────────────────────────────

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `TM-${name}.png`)
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

function getAdminCredentials(): { username: string; password: string } {
  const username = process.env.BPM_E2E_ADMIN_USERNAME?.trim()
  const password = process.env.BPM_E2E_ADMIN_PASSWORD?.trim()
  if (!username || !password) {
    throw new Error(
      'Missing required env vars for tenants E2E: BPM_E2E_ADMIN_USERNAME and BPM_E2E_ADMIN_PASSWORD',
    )
  }
  return {
    username,
    password,
  }
}

async function assertServiceReadiness(request: APIRequestContext): Promise<void> {
  const backendHealth = await request.fetch(`${API_BASE_URL}/health/ready`)
  if (!backendHealth.ok()) {
    throw new Error(
      `Backend readiness check failed (${backendHealth.status()}) at ${API_BASE_URL}/health/ready`,
    )
  }
  const idpHealth = await request.fetch(KEYCLOAK_DISCOVERY_URL)
  if (!idpHealth.ok()) {
    throw new Error(
      `Keycloak readiness check failed (${idpHealth.status()}) at ${KEYCLOAK_DISCOVERY_URL}`,
    )
  }
}

async function navigateSpa(page: Page, targetPath: string): Promise<void> {
  // Use page.goto for reliable SPA navigation — addInitScript from loginWithToken
  // restores the session before every page load, so the user stays authenticated.
  await page.goto(targetPath, { waitUntil: 'domcontentloaded' })
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, {
    timeout: 10_000,
  })
}

/**
 * Inject a non-PLATFORM_ADMIN session (PROCESS_OPERATOR) for frontend role-gating tests.
 * Uses the admin token so API calls succeed if made, but the roles array in sessionStorage
 * is restricted — matching what the app would see for a non-admin Keycloak user.
 */
async function loginAsNonAdmin(page: Page, adminToken: string): Promise<void> {
  await page.addInitScript((args: { token: string }) => {
    const session = {
      token: args.token,
      display_name: 'Process Operator',
      roles: ['PROCESS_OPERATOR'],
      loginSource: 'oidc' as const,
    }
    sessionStorage.setItem('__e2e_session', JSON.stringify(session))
  }, { token: adminToken })
  await page.goto('/', { waitUntil: 'domcontentloaded' })
  // Wait for app shell to render
  await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 }).catch(() => {})
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test.describe('TM tenants UI (TM-01, TM-02, TM-03, TM-04, TM-05)', () => {
  let adminToken = ''

  test.beforeEach(async ({ request }) => {
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    adminToken = await getKeycloakToken(request, creds.username, creds.password)
  })

  // ── TC-TM-UI-01 ─────────────────────────────────────────────────────────────

  test('TC-TM-UI-01: PLATFORM_ADMIN navigates to /admin/tenants and sees tenant list', async ({ page }) => {
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    // Page heading visible
    await expect(page.getByRole('heading', { name: 'Tenants' })).toBeVisible({ timeout: 10_000 })

    // Table rendered
    await expect(page.locator('[data-testid="tenants-page"]')).toBeVisible()
    await expect(page.locator('[data-testid="tenants-table"]')).toBeVisible()

    // At least one tenant row present (the default tenant always exists)
    const rows = page.locator('[data-testid^="tenant-row-"]')
    await expect(rows.first()).toBeVisible({ timeout: 10_000 })

    await shot(page, 'UI-01-tenant-list')

    // Visual assertion: screenshot shows the "Tenants" heading and the table
    const heading = await page.getByRole('heading', { name: 'Tenants' }).isVisible()
    expect(heading, 'Screen shows Tenants heading').toBe(true)
    const tableVisible = await page.locator('[data-testid="tenants-table"]').isVisible()
    expect(tableVisible, 'Screen shows tenants table').toBe(true)
  })

  // ── TC-TM-UI-02 ─────────────────────────────────────────────────────────────

  test('TC-TM-UI-02: Non-PLATFORM_ADMIN is redirected away from /admin/tenants', async ({ page }) => {
    // Inject a PROCESS_OPERATOR session — the frontend redirects non-admin away from this route
    await loginAsNonAdmin(page, adminToken)

    await navigateSpa(page, '/admin/tenants').catch(() => {/* redirect may change URL */})

    // Wait for the redirect to complete — should land on /instances
    await page.waitForURL((url) => url.pathname === '/instances', { timeout: 10_000 })

    await shot(page, 'UI-02-non-admin-redirected')

    // Visual assertion: screen shows the Instances page, not the Tenants list
    const currentPath = new URL(page.url()).pathname
    expect(currentPath, 'Screen shows /instances path after redirect').toBe('/instances')

    // The tenants-page container must not be present
    const tenantsPage = await page.locator('[data-testid="tenants-page"]').count()
    expect(tenantsPage, 'Tenants page is not rendered for non-admin').toBe(0)
  })

  // ── TC-TM-UI-03 ─────────────────────────────────────────────────────────────

  test('TC-TM-UI-03: Edit button navigates to /admin/tenants/:slug/edit', async ({ page }) => {
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    await expect(page.locator('[data-testid="tenants-table"]')).toBeVisible({ timeout: 10_000 })

    // Click the first edit button in the table
    const firstEditBtn = page.locator('[data-testid^="tenant-edit-"]').first()
    await expect(firstEditBtn).toBeVisible({ timeout: 10_000 })

    // Extract the slug from the data-testid before clicking
    const testId = await firstEditBtn.getAttribute('data-testid') ?? ''
    const slug = testId.replace('tenant-edit-', '')
    expect(slug.length, 'Edit button has a slug in its testid').toBeGreaterThan(0)

    await firstEditBtn.click()

    // Wait for navigation to the edit page
    await page.waitForURL((url) => url.pathname.endsWith('/edit'), { timeout: 10_000 })

    await shot(page, 'UI-03-edit-navigation')

    // Visual assertion: URL contains the slug and /edit suffix
    const currentUrl = page.url()
    expect(currentUrl, `Screen shows edit URL for slug ${slug}`).toContain(`/admin/tenants/${slug}/edit`)
  })

  // ── TC-TM-UI-04 ─────────────────────────────────────────────────────────────

  test('TC-TM-UI-04: EditTenantPage shows slug and idp_realm_id as read-only display elements', async ({ page }) => {
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    await expect(page.locator('[data-testid="tenants-table"]')).toBeVisible({ timeout: 10_000 })

    // Click the first edit button in the table
    const firstEditBtn = page.locator('[data-testid^="tenant-edit-"]').first()
    await expect(firstEditBtn).toBeVisible({ timeout: 10_000 })
    await firstEditBtn.click()

    // Wait for navigation to the edit page
    await page.waitForURL((url) => url.pathname.endsWith('/edit'), { timeout: 10_000 })

    await expect(page.locator('[data-testid="edit-tenant-page"]')).toBeVisible({ timeout: 15_000 })

    // slug element exists and is not an input
    const slugEl = page.locator('[data-testid="edit-tenant-slug"]')
    await expect(slugEl).toBeVisible()
    const slugTagName = await slugEl.evaluate((el) => el.tagName.toLowerCase())
    expect(slugTagName, 'Slug is displayed in a non-input element (read-only)').not.toBe('input')

    // idp_realm_id element exists and is not an input
    const realmEl = page.locator('[data-testid="edit-tenant-realm"]')
    await expect(realmEl).toBeVisible()
    const realmTagName = await realmEl.evaluate((el) => el.tagName.toLowerCase())
    expect(realmTagName, 'IDP realm ID is displayed in a non-input element (read-only)').not.toBe('input')

    await shot(page, 'UI-04-readonly-fields')

    // Visual assertion: edit-tenant-page container is visible with read-only fields
    const pageVisible = await page.locator('[data-testid="edit-tenant-page"]').isVisible()
    expect(pageVisible, 'Screen shows EditTenantPage container').toBe(true)
  })

  // ── TC-TM-UI-05 ─────────────────────────────────────────────────────────────

  test('TC-TM-UI-05: EditTenantPage allows editing display_name and saving', async ({ page }) => {
    test.setTimeout(60_000)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    await expect(page.locator('[data-testid="tenants-table"]')).toBeVisible({ timeout: 10_000 })

    // Click the first edit button (same pattern as TC-TM-UI-04 — uses existing tenant)
    const firstEditBtn = page.locator('[data-testid^="tenant-edit-"]').first()
    await expect(firstEditBtn).toBeVisible({ timeout: 10_000 })

    // Extract the slug from the data-testid
    const testId = await firstEditBtn.getAttribute('data-testid') ?? ''
    const slug = testId.replace('tenant-edit-', '')
    expect(slug.length, 'Edit button has a slug in its testid').toBeGreaterThan(0)

    await firstEditBtn.click()
    await page.waitForURL((url) => url.pathname.endsWith('/edit'), { timeout: 10_000 })
    await expect(page.locator('[data-testid="edit-tenant-page"]')).toBeVisible({ timeout: 15_000 })

    // Read the current display_name so we can restore it after the test
    const displayNameInput = page.locator('[data-testid="edit-tenant-display-name"]')
    await expect(displayNameInput).toBeVisible()
    const originalName = await displayNameInput.inputValue()

    // Edit the display_name field
    const newName = `TM UI-05 Updated ${randomUUID().slice(0, 6)}`
    await displayNameInput.fill(newName)

    await shot(page, 'UI-05-before-save')

    // Submit the form
    await page.getByRole('button', { name: /save/i }).click()

    // Should navigate back to /admin/tenants on success
    await page.waitForURL((url) => url.pathname === '/admin/tenants', { timeout: 15_000 })

    await shot(page, 'UI-05-after-save')

    // Visual assertion: URL is back at /admin/tenants after save
    const finalPath = new URL(page.url()).pathname
    expect(finalPath, 'Screen shows /admin/tenants after successful save').toBe('/admin/tenants')

    // Restore the original display_name to leave the tenant as we found it
    await navigateSpa(page, `/admin/tenants/${slug}/edit`)
    await expect(page.locator('[data-testid="edit-tenant-page"]')).toBeVisible({ timeout: 15_000 })
    await expect(page.locator('[data-testid="edit-tenant-display-name"]')).toBeVisible()
    await page.locator('[data-testid="edit-tenant-display-name"]').fill(originalName)
    await page.getByRole('button', { name: /save/i }).click()
    await page.waitForURL((url) => url.pathname === '/admin/tenants', { timeout: 15_000 })
  })

  // ── TC-TM-UI-06 ─────────────────────────────────────────────────────────────

  test("TC-TM-UI-06: 'Register New Tenant' button navigates to /admin/onboarding/new", async ({ page }) => {
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    await expect(page.locator('[data-testid="tenants-page"]')).toBeVisible({ timeout: 10_000 })

    const registerBtn = page.locator('[data-testid="register-new-tenant-btn"]')
    await expect(registerBtn).toBeVisible()

    await shot(page, 'UI-06-before-click')

    await registerBtn.click()

    // Wait for navigation to the onboarding page
    await page.waitForURL((url) => url.pathname === '/admin/onboarding/new', { timeout: 10_000 })

    await shot(page, 'UI-06-onboarding-page')

    // Visual assertion: screen shows /admin/onboarding/new
    const currentPath = new URL(page.url()).pathname
    expect(currentPath, "Screen shows /admin/onboarding/new after clicking 'Register New Tenant'").toBe(
      '/admin/onboarding/new',
    )
  })

  // ── TC-TM-UI-08 ─────────────────────────────────────────────────────────────

  test('TC-TM-UI-08: PLATFORM_ADMIN can deactivate and reactivate a tenant via lifecycle controls', async ({ page }) => {
    test.setTimeout(120_000)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    const statusBadge = page.locator('[data-testid^="tenant-status-"]').first()
    await expect(statusBadge).toBeVisible({ timeout: 30_000 })
    const statusId = await statusBadge.getAttribute('data-testid') ?? ''
    const slug = statusId.replace('tenant-status-', '')
    expect(slug.length, 'Expected slug from first tenant status badge').toBeGreaterThan(0)

    const originalStatusText = (await statusBadge.innerText()).toLowerCase()
    const startsActive = originalStatusText.includes('active')

    // Ensure we are in ACTIVE state before validating full deactivate/reactivate roundtrip.
    if (!startsActive) {
      await page.locator(`[data-testid="tenant-reactivate-${slug}"]`).click()
      await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toBeVisible()
      await page.locator('[data-testid="tenant-lifecycle-confirm"]').click()
      await expect(page.locator(`[data-testid="tenant-status-${slug}"]`)).toContainText('Active', { timeout: 30_000 })
    }

    await expect(page.locator(`[data-testid="tenant-deactivate-${slug}"]`)).toBeVisible()
    await expect(page.locator(`[data-testid="tenant-reactivate-${slug}"]`)).toHaveCount(0)
    await shot(page, 'UI-08-before-deactivate')

    await page.locator(`[data-testid="tenant-deactivate-${slug}"]`).click()
    await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toBeVisible()
    await shot(page, 'UI-08-confirm-deactivate')
    await page.locator('[data-testid="tenant-lifecycle-confirm"]').click()

    await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toHaveCount(0)
    await expect(page.locator(`[data-testid="tenant-status-${slug}"]`)).toContainText('Inactive', { timeout: 30_000 })
    await expect(page.locator(`[data-testid="tenant-reactivate-${slug}"]`)).toBeVisible()
    await expect(page.locator(`[data-testid="tenant-deactivate-${slug}"]`)).toHaveCount(0)
    await shot(page, 'UI-08-after-deactivate')

    await page.locator(`[data-testid="tenant-reactivate-${slug}"]`).click()
    await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toBeVisible()
    await shot(page, 'UI-08-confirm-reactivate')
    await page.locator('[data-testid="tenant-lifecycle-confirm"]').click()

    await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toHaveCount(0)
    await expect(page.locator(`[data-testid="tenant-status-${slug}"]`)).toContainText('Active', { timeout: 30_000 })
    await expect(page.locator(`[data-testid="tenant-deactivate-${slug}"]`)).toBeVisible()
    await expect(page.locator(`[data-testid="tenant-reactivate-${slug}"]`)).toHaveCount(0)
    await shot(page, 'UI-08-after-reactivate')

    expect(await page.locator(`[data-testid="tenant-status-${slug}"]`).innerText()).toContain('Active')
  })

  // ── TC-TM-UI-09 ─────────────────────────────────────────────────────────────

  test('TC-TM-UI-09: Lifecycle controls are state-driven by tenant status', async ({ page }) => {
    test.setTimeout(120_000)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    const statusBadge = page.locator('[data-testid^="tenant-status-"]').first()
    await expect(statusBadge).toBeVisible({ timeout: 30_000 })
    const statusId = await statusBadge.getAttribute('data-testid') ?? ''
    const slug = statusId.replace('tenant-status-', '')
    expect(slug.length, 'Expected slug from first tenant status badge').toBeGreaterThan(0)

    // ACTIVE row must show only Deactivate
    const statusText = (await statusBadge.innerText()).toLowerCase()
    if (!statusText.includes('active')) {
      await page.locator(`[data-testid="tenant-reactivate-${slug}"]`).click()
      await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toBeVisible()
      await page.locator('[data-testid="tenant-lifecycle-confirm"]').click()
      await expect(page.locator(`[data-testid="tenant-status-${slug}"]`)).toContainText('Active', { timeout: 30_000 })
    }

    await expect(page.locator(`[data-testid="tenant-deactivate-${slug}"]`)).toBeVisible()
    await expect(page.locator(`[data-testid="tenant-reactivate-${slug}"]`)).toHaveCount(0)
    await shot(page, 'UI-09-active-controls')

    await page.locator(`[data-testid="tenant-deactivate-${slug}"]`).click()
    await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toBeVisible()
    await page.locator('[data-testid="tenant-lifecycle-confirm"]').click()

    await expect(page.locator(`[data-testid="tenant-status-${slug}"]`)).toContainText('Inactive', { timeout: 30_000 })
    await expect(page.locator(`[data-testid="tenant-reactivate-${slug}"]`)).toBeVisible()
    await expect(page.locator(`[data-testid="tenant-deactivate-${slug}"]`)).toHaveCount(0)
    await shot(page, 'UI-09-inactive-controls')

    // Restore active state to avoid leaving changed tenant status after test.
    await page.locator(`[data-testid="tenant-reactivate-${slug}"]`).click()
    await expect(page.locator('[data-testid="tenant-lifecycle-confirm-dialog"]')).toBeVisible()
    await page.locator('[data-testid="tenant-lifecycle-confirm"]').click()
    await expect(page.locator(`[data-testid="tenant-status-${slug}"]`)).toContainText('Active', { timeout: 30_000 })

    expect(await page.locator(`[data-testid="tenant-reactivate-${slug}"]`).count()).toBe(0)
  })

  // ── TC-TM-UI-07 ─────────────────────────────────────────────────────────────

  test("TC-TM-UI-07: 'Tenants' nav link is hidden from non-PLATFORM_ADMIN", async ({ page }) => {
    // Inject a PROCESS_OPERATOR session — should not see the Tenants nav link
    await loginAsNonAdmin(page, adminToken)

    await shot(page, 'UI-07-non-admin-nav')

    // Visual assertion: sidebar does not contain a "Tenants" link
    const tenantsLink = page.getByRole('link', { name: 'Tenants', exact: true })
    const linkCount = await tenantsLink.count()
    expect(linkCount, "Screen does not show 'Tenants' nav link for PROCESS_OPERATOR").toBe(0)

    // The 'Instances' link IS visible (confirming the sidebar rendered)
    const instancesLink = page.getByRole('link', { name: 'Instances', exact: true })
    await expect(instancesLink).toBeVisible()
  })
})
