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
const KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081').replace(/\/$/, '')
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
  return {
    username: process.env.BPM_E2E_ADMIN_USERNAME?.trim() || 'admin-user',
    password: process.env.BPM_E2E_ADMIN_PASSWORD?.trim() || 'admin-pass',
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
  await page.evaluate((nextPath) => {
    window.history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, {
    timeout: 10_000,
  })
}

/**
 * Create a test tenant via the backend API.
 * Returns the created tenant's slug.
 */
async function createTestTenant(
  request: APIRequestContext,
  token: string,
  slug: string,
  displayName: string,
): Promise<void> {
  const response = await request.post(`${API_BASE_URL}/api/v1/admin/tenants`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: { slug, display_name: displayName },
  })
  // 201 = created; 409 = already exists (fine for idempotency in tests)
  if (!response.ok() && response.status() !== 409) {
    const body = await response.text()
    throw new Error(`Failed to create test tenant ${slug} (${response.status()}): ${body}`)
  }
}

/**
 * Delete a test tenant via the backend API (best-effort cleanup).
 */
async function deleteTestTenant(
  request: APIRequestContext,
  token: string,
  slug: string,
): Promise<void> {
  await request.delete(`${API_BASE_URL}/api/v1/admin/tenants/${slug}`, {
    headers: { Authorization: `Bearer ${token}` },
  }).catch(() => {/* best-effort */})
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

test.describe('TM tenants UI (TM-01, TM-02, TM-03)', () => {
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

    const firstEditBtn = page.locator('[data-testid^="tenant-edit-"]').first()
    await expect(firstEditBtn).toBeVisible({ timeout: 10_000 })
    await firstEditBtn.click()
    await page.waitForURL((url) => url.pathname.endsWith('/edit'), { timeout: 10_000 })

    await expect(page.locator('[data-testid="edit-tenant-page"]')).toBeVisible({ timeout: 10_000 })

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

  test('TC-TM-UI-05: EditTenantPage allows editing display_name and saving', async ({ page, request }) => {
    // Create a dedicated fixture tenant for this test so we can safely modify it.
    const fixtureSlug = `tc-tm-ui-05-${randomUUID().slice(0, 8)}`
    const originalName = 'TM UI-05 Original'

    try {
      await createTestTenant(request, adminToken, fixtureSlug, originalName)

      await loginWithToken(page, adminToken)
      await navigateSpa(page, `/admin/tenants/${fixtureSlug}/edit`)

      await expect(page.locator('[data-testid="edit-tenant-page"]')).toBeVisible({ timeout: 15_000 })

      // Edit the display_name field
      const displayNameInput = page.locator('[data-testid="edit-tenant-display-name"]')
      await expect(displayNameInput).toBeVisible()
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
    } finally {
      await deleteTestTenant(request, adminToken, fixtureSlug)
    }
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
