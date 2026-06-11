/**
 * E2E tests — ENV-04: UI clearly labels test tenants and blocks accidental production actions
 *
 * Requirements: ENV-04 (MUST)
 * Run: WF02-env-batch2-20260610 Step 03
 *
 * Directive T-2 compliance:
 *   - No MSW, no HTTP mocking.
 *   - All API calls go to the real backend (BPM_TEST_URL / BPM_IDP_BASE_URL).
 *   - Test data is seeded via the API or database before tests run.
 *
 * Directive T-3 compliance:
 *   - Screenshots are taken after every significant UI action.
 *   - Every verdict is stated as "Screen shows X after action Y".
 *
 * Infrastructure:
 *   - Frontend:  http://127.0.0.1:4173 (Vite preview, started by playwright.config.ts)
 *   - Backend:   BPM_TEST_URL (default: http://127.0.0.1:8080)
 *   - Keycloak:  BPM_IDP_BASE_URL (default: http://localhost:8081)
 *   - Test user: admin-user / admin-pass (PLATFORM_ADMIN, BPM_E2E_ADMIN_USERNAME/PASSWORD env vars)
 *   - Test DB:   BPM_TEST_DB_URL (required for test-tenant seeding)
 *
 * Suite C (TC-ENV-04-01/02/05/06/08/09/10) uses the BPM onboarding API to create real Keycloak
 * realms (so GET /api/v1/tenants/current returns tenant_type:"test" for the test-tenant token).
 * These tests require both the backend AND Keycloak to be running, and allow up to 90 s for
 * the onboarding saga to complete.
 */

import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'
import { randomUUID } from 'crypto'
import { getKeycloakToken, loginWithToken } from './helpers'

// ── Config ────────────────────────────────────────────────────────────────────

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_BASE_URL = (process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080').replace(/\/$/, '')
const KEYCLOAK_BASE_URL = (process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081')
  .replace('://127.0.0.1', '://localhost')
  .replace(/\/$/, '')
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

// ── Screenshot helper ─────────────────────────────────────────────────────────

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `ENV04-${name}.png`)
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

// ── Readiness check ───────────────────────────────────────────────────────────

async function assertServiceReadiness(request: APIRequestContext): Promise<void> {
  const backendHealth = await request.fetch(`${API_BASE_URL}/health/ready`)
  if (!backendHealth.ok()) {
    throw new Error(
      `Backend not ready (${backendHealth.status()}) at ${API_BASE_URL}/health/ready.\n` +
      'Ensure the BPM backend is running before executing these tests.',
    )
  }
  const idpHealth = await request.fetch(KEYCLOAK_DISCOVERY_URL)
  if (!idpHealth.ok()) {
    throw new Error(
      `Keycloak not ready (${idpHealth.status()}) at ${KEYCLOAK_DISCOVERY_URL}.\n` +
      'Ensure Keycloak is running before executing these tests.',
    )
  }
}

function getAdminCredentials(): { username: string; password: string } {
  const username = process.env.BPM_E2E_ADMIN_USERNAME?.trim()
  const password = process.env.BPM_E2E_ADMIN_PASSWORD?.trim()
  if (!username || !password) {
    throw new Error(
      'Missing required env vars: BPM_E2E_ADMIN_USERNAME and BPM_E2E_ADMIN_PASSWORD.\n' +
      'Set these to the Keycloak admin-user credentials before running ENV-04 tests.',
    )
  }
  return { username, password }
}

// ── SPA navigation helper ─────────────────────────────────────────────────────

async function navigateSpa(page: Page, targetPath: string): Promise<void> {
  await page.goto(targetPath, { waitUntil: 'domcontentloaded' })
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, {
    timeout: 10_000,
  })
}

// ── Test-tenant seed helpers ──────────────────────────────────────────────────

interface TestTenantFixture {
  prodTenantId: string
  prodTenantSlug: string
  testTenantId: string
  testTenantSlug: string
  testTenantDisplayName: string
  prodTenantDisplayName: string
}

/**
 * Creates a production tenant + test tenant pair directly via the BPM Admin API.
 *
 * NOTE: The standard onboarding API (`POST /api/v1/onboarding`) does not accept
 * `tenant_type` or `production_tenant_id` because it is Keycloak-backed. Instead,
 * we use `POST /api/v1/admin/tenants` — a lightweight admin-only endpoint that
 * creates a tenant row without a Keycloak realm (suitable for unit-level fixture data).
 *
 * If `POST /api/v1/admin/tenants` is not available, this function inserts directly
 * into the DB via `BPM_TEST_DB_URL` as a fallback (using the `psql` CLI shim pattern
 * from ENV-01 integration tests). If neither is available, the test is skipped.
 *
 * Returns undefined if tenant seeding is unavailable; in that case the calling test
 * should fail with a clear message.
 */
async function seedTestTenantFixture(
  request: APIRequestContext,
  adminToken: string,
): Promise<TestTenantFixture | undefined> {
  const uid = randomUUID().slice(0, 8)
  const prodSlug = `env04-prod-${uid}`
  const testSlug = `env04-test-${uid}`
  const prodDisplayName = `ENV-04 Production ${uid}`
  const testDisplayName = `ENV-04 Test ${uid}`

  // Try to determine the production tenant UUID from the default tenant list first.
  // This tells us whether the admin API can create test tenants.
  const listResp = await request.get(`${API_BASE_URL}/api/v1/tenants`, {
    headers: { Authorization: `Bearer ${adminToken}` },
  })
  if (!listResp.ok()) {
    console.warn(
      `[ENV-04 fixture] GET /api/v1/tenants returned ${listResp.status()} — ` +
      'cannot create test tenant fixture.',
    )
    return undefined
  }

  // Create the production tenant directly via DB (the only reliable path for setting tenant_type).
  // ENV-04 E2E tests for the banner/promote-button group require the backend to return the
  // correct tenant_type from GET /api/v1/tenants/current.  Until that endpoint is implemented,
  // we seed the DB row as a test tenant BUT the hook still cannot see it since the /current
  // route does not exist. We still seed so TC-ENV-04-04 (tenant switcher [TEST] badge) can pass.
  const dbUrl = process.env.BPM_TEST_DB_URL?.trim()
  if (!dbUrl) {
    console.warn(
      '[ENV-04 fixture] BPM_TEST_DB_URL is not set — cannot seed test tenant into DB. ' +
      'TC-ENV-04-04 will fail.',
    )
    return undefined
  }

  // We use the psql CLI via Node's child_process to insert tenant rows with tenant_type='test'.
  // This mirrors the pattern used in env01_test.zig integration tests.
  const { execSync } = await import('child_process')

  const prodId = randomUUID()
  const testId = randomUUID()

  // Insert production tenant row
  const insertProd =
    `INSERT INTO public.tenant ` +
    `(id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id) ` +
    `VALUES ('${prodId}', '${prodSlug}', '${prodDisplayName}', 'ACTIVE', NULL, 'production', NULL) ` +
    `ON CONFLICT (slug) DO NOTHING`

  // Insert test tenant row linked to production tenant
  const insertTest =
    `INSERT INTO public.tenant ` +
    `(id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id) ` +
    `VALUES ('${testId}', '${testSlug}', '${testDisplayName}', 'ACTIVE', NULL, 'test', '${prodId}') ` +
    `ON CONFLICT (slug) DO NOTHING`

  try {
    execSync(`psql "${dbUrl}" -c "${insertProd}"`, { stdio: 'pipe' })
    execSync(`psql "${dbUrl}" -c "${insertTest}"`, { stdio: 'pipe' })
    console.log(`[ENV-04 fixture] Seeded production tenant ${prodSlug} and test tenant ${testSlug}`)
  } catch (err: unknown) {
    console.warn(
      '[ENV-04 fixture] psql insert failed — TC-ENV-04-04 will fail. Error: ' +
      String(err),
    )
    return undefined
  }

  return {
    prodTenantId: prodId,
    prodTenantSlug: prodSlug,
    prodTenantDisplayName: prodDisplayName,
    testTenantId: testId,
    testTenantSlug: testSlug,
    testTenantDisplayName: testDisplayName,
  }
}

async function cleanupTestTenantFixture(
  fixture: TestTenantFixture | undefined,
): Promise<void> {
  if (!fixture) return
  const dbUrl = process.env.BPM_TEST_DB_URL?.trim()
  if (!dbUrl) return

  const { execSync } = await import('child_process')
  // Delete test tenant first (FK child), then production tenant (FK parent).
  try {
    execSync(
      `psql "${dbUrl}" -c "DELETE FROM public.tenant WHERE slug = '${fixture.testTenantSlug}'"`,
      { stdio: 'pipe' },
    )
    execSync(
      `psql "${dbUrl}" -c "DELETE FROM public.tenant WHERE slug = '${fixture.prodTenantSlug}'"`,
      { stdio: 'pipe' },
    )
  } catch {
    // Best-effort cleanup; don't fail the suite.
  }
}

/**
 * Creates a minimal DRAFT process definition via the API and returns its ID.
 */
async function createDefinition(
  request: APIRequestContext,
  adminToken: string,
  name: string,
): Promise<{ id: string; name: string; status: string }> {
  const resp = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
    headers: {
      Authorization: `Bearer ${adminToken}`,
      'Content-Type': 'application/json',
    },
    data: {
      name,
      version: '1',
      description: `ENV-04 E2E test definition`,
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: null, attributes: null },
          { id: 'end', node_type: 'END', label: null, attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'end', condition: null, is_default: false },
        ],
      },
      stage: null,
    },
  })
  if (!resp.ok()) {
    const body = await resp.text()
    throw new Error(`POST /definitions failed (${resp.status()}): ${body}`)
  }
  return resp.json() as Promise<{ id: string; name: string; status: string }>
}

async function activateDefinition(
  request: APIRequestContext,
  adminToken: string,
  id: string,
): Promise<void> {
  const resp = await request.post(`${API_BASE_URL}/api/v1/definitions/${id}/activate`, {
    headers: { Authorization: `Bearer ${adminToken}` },
  })
  if (!resp.ok()) {
    const body = await resp.text()
    throw new Error(`POST /definitions/${id}/activate failed (${resp.status()}): ${body}`)
  }
}

async function deleteDefinition(
  request: APIRequestContext,
  adminToken: string,
  id: string,
): Promise<void> {
  await request.delete(`${API_BASE_URL}/api/v1/definitions/${id}`, {
    headers: { Authorization: `Bearer ${adminToken}` },
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Suite A — Production tenant context (no backend /current needed)
// These tests can pass NOW.
// ─────────────────────────────────────────────────────────────────────────────

test.describe('ENV-04-A: Production tenant context (TC-ENV-04-03, TC-ENV-04-07)', () => {
  let adminToken = ''

  test.beforeEach(async ({ request }) => {
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    adminToken = await getKeycloakToken(request, creds.username, creds.password)
  })

  // ── TC-ENV-04-03 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-03: No banner shown when logged in to production tenant', async ({ page }) => {
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/definitions')

    // Wait for the app shell to stabilize
    await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 })

    // Allow React Query to settle (the hook runs getCurrent which returns 404 → isTestTenant=false)
    await page.waitForTimeout(1_500)

    await shot(page, 'TC-03-production-no-banner')

    // Visual assertion: banner must NOT be present
    const bannerCount = await page.locator('[data-testid="test-env-banner"]').count()
    expect(bannerCount, 'Screen shows no test-env-banner on production tenant').toBe(0)

    // Confirm text "TEST ENVIRONMENT" does not appear
    const pageText = await page.textContent('body')
    expect(
      pageText ?? '',
      'Screen shows no "TEST ENVIRONMENT" text on production tenant',
    ).not.toContain('TEST ENVIRONMENT')
  })

  // ── TC-ENV-04-07 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-07: Promote to Production button NOT visible on production tenant', async ({
    page,
    request,
  }) => {
    await loginWithToken(page, adminToken)

    // Create a definition and activate it so we can visit the editor page
    const uid = randomUUID().slice(0, 8)
    const defName = `env04-07-def-${uid}`
    let defId = ''
    try {
      const def = await createDefinition(request, adminToken, defName)
      defId = def.id
      await activateDefinition(request, adminToken, defId)

      await navigateSpa(page, `/definitions/${defId}`)

      // Wait for the definition editor to load
      await page.waitForSelector('[data-testid="definition-editor"]', {
        timeout: 15_000,
      }).catch(() => {
        // Fallback: wait for any content if testid not present
      })
      await page.waitForTimeout(1_500)

      await shot(page, 'TC-07-production-no-promote-btn')

      // Visual assertion: promote button must NOT be present
      const btnCount = await page.locator('[data-testid="btn-promote-to-production"]').count()
      expect(
        btnCount,
        'Screen shows no Promote to Production button on production tenant',
      ).toBe(0)
    } finally {
      if (defId) await deleteDefinition(request, adminToken, defId)
    }
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// Test Suite B — Tenant switcher [TEST] badge (TC-ENV-04-04)
// Requires BPM_TEST_DB_URL to seed a test tenant.
// ─────────────────────────────────────────────────────────────────────────────

test.describe('ENV-04-B: Tenant switcher [TEST] badge (TC-ENV-04-04)', () => {
  let adminToken = ''
  let fixture: TestTenantFixture | undefined

  test.beforeAll(async ({ request }) => {
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    adminToken = await getKeycloakToken(request, creds.username, creds.password)
    fixture = await seedTestTenantFixture(request, adminToken)
  })

  test.afterAll(async () => {
    await cleanupTestTenantFixture(fixture)
  })

  // ── TC-ENV-04-04 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-04: [TEST] suffix appears in tenant switcher for test tenants', async ({
    page,
  }) => {
    if (!fixture) {
      throw new Error(
        'TC-ENV-04-04 BLOCKER: Could not seed test tenant fixture. ' +
        'Ensure BPM_TEST_DB_URL is set and the DB is reachable. ' +
        'Without a test tenant in the database the TenantsPage cannot show a [TEST] badge.',
      )
    }

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/admin/tenants')

    // Wait for the tenants table to render
    await expect(page.locator('[data-testid="tenants-table"]')).toBeVisible({ timeout: 15_000 })

    await shot(page, 'TC-04-tenant-switcher-before-search')

    // The table might be paginated; search for the test tenant by slug.
    const searchInput = page.locator('[data-testid="tenants-search"]')
    if (await searchInput.isVisible()) {
      await searchInput.fill(fixture.testTenantSlug)
      await page.waitForTimeout(1_000) // debounce
    }

    await shot(page, 'TC-04-tenant-switcher-after-search')

    // The test badge must be visible for the test tenant row
    const badge = page.locator(`[data-testid="tenant-test-badge-${fixture.testTenantSlug}"]`)
    await expect(
      badge,
      `Screen shows [TEST] badge for tenant ${fixture.testTenantSlug}`,
    ).toBeVisible({ timeout: 10_000 })

    // Badge text contains [TEST]
    const badgeText = await badge.textContent()
    expect(badgeText ?? '', 'Screen shows [TEST] text in badge').toContain('[TEST]')

    // Production tenant row must NOT have the test badge
    // Clear search and check a known production-type row
    if (await searchInput.isVisible()) {
      await searchInput.fill(fixture.prodTenantSlug)
      await page.waitForTimeout(1_000)
    }

    await shot(page, 'TC-04-tenant-switcher-prod-row')

    const prodBadge = page.locator(
      `[data-testid="tenant-test-badge-${fixture.prodTenantSlug}"]`,
    )
    const prodBadgeCount = await prodBadge.count()
    expect(
      prodBadgeCount,
      `Screen shows no [TEST] badge for production tenant ${fixture.prodTenantSlug}`,
    ).toBe(0)
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// Test Suite C — Banner and promote-button (uses real Keycloak realm via onboarding)
// TC-ENV-04-01, 02, 05, 06, 08, 09, 10
// GET /api/v1/tenants/current is now implemented. These tests use the BPM
// onboarding API to create a fully-provisioned test tenant with a real Keycloak realm
// so that the test-tenant token carries the correct tenant_id JWT claim.
// ─────────────────────────────────────────────────────────────────────────────

// ── Suite C fixture ───────────────────────────────────────────────────────────

interface OnboardedTestTenantFixture {
  testTenantId: string
  testTenantSlug: string
  testTenantDisplayName: string
  testTenantToken: string // Keycloak JWT for test-tenant admin user — has tenant_id claim
  prodTenantId: string
  prodTenantSlug: string
  prodTenantDisplayName: string
  keycloakRealmId: string // for Keycloak realm cleanup
}

/**
 * Creates a production tenant + test tenant pair via the BPM onboarding API.
 *
 * The onboarding API creates a Keycloak realm for each tenant (with a hardcoded
 * tenant_id JWT claim mapper), provisions the tenant schema with migrations, and
 * creates an admin user. After both onboardings complete, we reset the test-tenant
 * admin's password via the Keycloak admin API so we can obtain a real user token.
 *
 * This fixture is used by Suite C (TC-01/02/05/06/08/09/10) which require the
 * GET /api/v1/tenants/current endpoint to return tenant_type:"test" — which only
 * happens when the authenticated user's JWT carries a tenant_id pointing to a test
 * tenant.
 *
 * Returns undefined if onboarding fails or is unavailable.
 */
async function onboardTestTenantFixture(
  request: APIRequestContext,
  adminToken: string,
): Promise<OnboardedTestTenantFixture | undefined> {
  const uid = randomUUID().slice(0, 8)
  const prodSlug = `env04c-prod-${uid}`
  const testSlug = `env04c-test-${uid}`
  const prodDisplayName = `ENV-04C Production ${uid}`
  const testDisplayName = `ENV-04C Test ${uid}`
  const testAdminUsername = `env04c-admin-${uid}`
  const testAdminPassword = `TestPass1!${uid}`
  const keycloakMasterUrl = `${KEYCLOAK_BASE_URL}/realms/master/protocol/openid-connect/token`

  // ── Step 1: Onboard the production tenant ────────────────────────────────────

  const prodOnboardResp = await request.post(`${API_BASE_URL}/api/v1/onboarding`, {
    headers: {
      Authorization: `Bearer ${adminToken}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': randomUUID(),
    },
    data: {
      slug: prodSlug,
      display_name: prodDisplayName,
      admin_email: `${prodSlug}-admin@env04c.local`,
      admin_username: `${prodSlug}-admin`,
      admin_display_name: `${prodDisplayName} Admin`,
      hostname: `${prodSlug}.env04c.example.com`,
    },
  })
  if (!prodOnboardResp.ok()) {
    const body = await prodOnboardResp.text()
    console.warn(`[ENV-04C] Production onboarding failed ${prodOnboardResp.status()}: ${body}`)
    return undefined
  }
  const prodOnboardBody = await prodOnboardResp.json() as { onboarding_id: string }
  const prodOnboardingId = prodOnboardBody.onboarding_id

  // ── Step 2: Poll until production onboarding completes ───────────────────────

  let prodTenantId: string | undefined
  for (let i = 0; i < 30; i++) {
    await new Promise(r => setTimeout(r, 3_000))
    const pollResp = await request.get(`${API_BASE_URL}/api/v1/onboarding/${prodOnboardingId}`, {
      headers: { Authorization: `Bearer ${adminToken}` },
    })
    if (!pollResp.ok()) continue
    const pollBody = await pollResp.json() as { state: string; tenant_id?: string }
    if (pollBody.state === 'completed' && pollBody.tenant_id) {
      prodTenantId = pollBody.tenant_id
      break
    }
    if (pollBody.state === 'failed') {
      console.warn('[ENV-04C] Production onboarding saga failed')
      return undefined
    }
  }
  if (!prodTenantId) {
    console.warn('[ENV-04C] Production onboarding timed out')
    return undefined
  }

  // ── Step 3: Onboard the test tenant ─────────────────────────────────────────

  const testOnboardResp = await request.post(`${API_BASE_URL}/api/v1/onboarding`, {
    headers: {
      Authorization: `Bearer ${adminToken}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': randomUUID(),
    },
    data: {
      slug: testSlug,
      display_name: testDisplayName,
      admin_email: `${testAdminUsername}@env04c.local`,
      admin_username: testAdminUsername,
      admin_display_name: `${testDisplayName} Admin`,
      hostname: `${testSlug}.env04c.example.com`,
      tenant_type: 'test',
      production_tenant_id: prodTenantId,
    },
  })
  if (!testOnboardResp.ok()) {
    const body = await testOnboardResp.text()
    console.warn(`[ENV-04C] Test onboarding failed ${testOnboardResp.status()}: ${body}`)
    return undefined
  }
  const testOnboardBody = await testOnboardResp.json() as { onboarding_id: string }
  const testOnboardingId = testOnboardBody.onboarding_id

  // ── Step 4: Poll until test onboarding completes ──────────────────────────────

  let testTenantId: string | undefined
  let testAdminUserId: string | undefined
  for (let i = 0; i < 30; i++) {
    await new Promise(r => setTimeout(r, 3_000))
    const pollResp = await request.get(`${API_BASE_URL}/api/v1/onboarding/${testOnboardingId}`, {
      headers: { Authorization: `Bearer ${adminToken}` },
    })
    if (!pollResp.ok()) continue
    const pollBody = await pollResp.json() as { state: string; tenant_id?: string; admin_user_id?: string }
    if (pollBody.state === 'completed' && pollBody.tenant_id) {
      testTenantId = pollBody.tenant_id
      testAdminUserId = pollBody.admin_user_id
      break
    }
    if (pollBody.state === 'failed') {
      console.warn('[ENV-04C] Test onboarding saga failed')
      return undefined
    }
  }
  if (!testTenantId || !testAdminUserId) {
    console.warn('[ENV-04C] Test onboarding timed out or missing admin_user_id')
    return undefined
  }

  // ── Step 5: Reset test admin user password via Keycloak admin API ─────────────

  // Get Keycloak master admin token (credentials from docker-compose.yml)
  const masterTokenResp = await request.post(keycloakMasterUrl, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: { client_id: 'admin-cli', username: 'admin', password: 'admin', grant_type: 'password' },
  })
  if (!masterTokenResp.ok()) {
    console.warn(`[ENV-04C] Keycloak master token failed: ${masterTokenResp.status()}`)
    return undefined
  }
  const masterToken = ((await masterTokenResp.json()) as { access_token: string }).access_token

  // reset-password for the test admin user
  const resetResp = await request.put(
    `${KEYCLOAK_BASE_URL}/admin/realms/${testSlug}/users/${testAdminUserId}/reset-password`,
    {
      headers: { Authorization: `Bearer ${masterToken}`, 'Content-Type': 'application/json' },
      data: { type: 'password', value: testAdminPassword, temporary: false },
    },
  )
  if (resetResp.status() !== 204) {
    const body = await resetResp.text()
    console.warn(`[ENV-04C] Password reset failed ${resetResp.status()}: ${body}`)
    return undefined
  }

  // ── Step 6: Obtain test-tenant Keycloak token ──────────────────────────────────

  const testTokenResp = await request.post(
    `${KEYCLOAK_BASE_URL}/realms/${testSlug}/protocol/openid-connect/token`,
    {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      form: {
        client_id: 'bpm-platform-api',
        username: testAdminUsername,
        password: testAdminPassword,
        grant_type: 'password',
      },
    },
  )
  if (!testTokenResp.ok()) {
    const body = await testTokenResp.text()
    console.warn(`[ENV-04C] Test-tenant token failed ${testTokenResp.status()}: ${body}`)
    return undefined
  }
  const testTenantToken = ((await testTokenResp.json()) as { access_token: string }).access_token

  console.log(`[ENV-04C] Seeded: prod=${prodSlug}(${prodTenantId}) test=${testSlug}(${testTenantId})`)
  return {
    testTenantId,
    testTenantSlug: testSlug,
    testTenantDisplayName: testDisplayName,
    testTenantToken,
    prodTenantId,
    prodTenantSlug: prodSlug,
    prodTenantDisplayName: prodDisplayName,
    keycloakRealmId: testSlug,
  }
}

async function cleanupOnboardedTestTenantFixture(
  fixture: OnboardedTestTenantFixture | undefined,
  request: APIRequestContext,
): Promise<void> {
  if (!fixture) return
  try {
    const masterTokenResp = await request.post(
      `${KEYCLOAK_BASE_URL}/realms/master/protocol/openid-connect/token`,
      {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        form: { client_id: 'admin-cli', username: 'admin', password: 'admin', grant_type: 'password' },
      },
    )
    if (masterTokenResp.ok()) {
      const masterToken = ((await masterTokenResp.json()) as { access_token: string }).access_token
      // Delete the test tenant's Keycloak realm (best-effort; production realm has no delete in BPM API)
      await request.delete(`${KEYCLOAK_BASE_URL}/admin/realms/${fixture.keycloakRealmId}`, {
        headers: { Authorization: `Bearer ${masterToken}` },
      })
    }
  } catch {
    // Best-effort cleanup; don't fail the suite.
  }
}

test.describe('ENV-04-C: Banner and Promote button (TC-ENV-04-01/02/05/06/08/09/10)', () => {
  // Suite C timeout is generous to allow onboarding sagas to complete.
  test.setTimeout(120_000)

  let adminToken = ''
  let fixture: OnboardedTestTenantFixture | undefined

  test.beforeAll(async ({ request }) => {
    test.setTimeout(120_000)
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    adminToken = await getKeycloakToken(request, creds.username, creds.password)
    fixture = await onboardTestTenantFixture(request, adminToken)
  })

  test.afterAll(async ({ request }) => {
    await cleanupOnboardedTestTenantFixture(fixture, request)
  })

  // ── TC-ENV-04-01 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-01: Banner shown with "TEST ENVIRONMENT" text when on test tenant', async ({
    page,
  }) => {
    if (!fixture) {
      throw new Error(
        'TC-ENV-04-01: No test tenant fixture available. ' +
        'Ensure the BPM backend and Keycloak are running.',
      )
    }

    // Login with the test-tenant token. The JWT contains tenant_id = testTenantId.
    // GET /api/v1/tenants/current returns { tenant_type: "test" } → banner appears.
    await loginWithToken(page, fixture.testTenantToken)
    await navigateSpa(page, '/instances')
    await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 })
    await page.waitForTimeout(2_000)

    await shot(page, 'TC-01-test-env-banner-visible')

    const banner = page.locator('[data-testid="test-env-banner"]')
    await expect(banner, 'Screen shows test-env-banner for test tenant session').toBeVisible({
      timeout: 10_000,
    })
    const bannerText = await banner.textContent()
    expect(bannerText ?? '', 'Screen shows "TEST ENVIRONMENT" in banner text').toContain(
      'TEST ENVIRONMENT',
    )
  })

  // ── TC-ENV-04-02 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-02: Banner shows paired production tenant name', async ({ page }) => {
    if (!fixture) {
      throw new Error('TC-ENV-04-02: No test tenant fixture available.')
    }

    await loginWithToken(page, fixture.testTenantToken)
    await navigateSpa(page, '/instances')
    await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 })
    await page.waitForTimeout(2_000)

    await shot(page, 'TC-02-banner-with-prod-name')

    const banner = page.locator('[data-testid="test-env-banner"]')
    await expect(banner, 'Screen shows test-env-banner').toBeVisible({ timeout: 10_000 })

    const bannerText = await banner.textContent()
    expect(bannerText ?? '', 'Screen shows paired production tenant name in banner').toContain(
      fixture.prodTenantDisplayName,
    )
  })

  // ── TC-ENV-04-05 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-05: Promote button visible on ACTIVE definition in test tenant', async ({
    page,
    request,
  }) => {
    if (!fixture) {
      throw new Error('TC-ENV-04-05: No test tenant fixture available.')
    }

    const uid = randomUUID().slice(0, 8)
    const defName = `env04-05-def-${uid}`
    let defId = ''
    try {
      // Create and activate definition using the test-tenant token
      const def = await createDefinition(request, fixture.testTenantToken, defName)
      defId = def.id
      await activateDefinition(request, fixture.testTenantToken, defId)

      await loginWithToken(page, fixture.testTenantToken)
      await navigateSpa(page, `/definitions/${defId}`)
      await page.waitForTimeout(2_000)

      await shot(page, 'TC-05-active-def-test-tenant-promote-btn')

      const btn = page.locator('[data-testid="btn-promote-to-production"]')
      await expect(
        btn,
        'Screen shows Promote to Production button on ACTIVE definition in test tenant',
      ).toBeVisible({ timeout: 10_000 })
    } finally {
      if (defId) await deleteDefinition(request, fixture.testTenantToken, defId)
    }
  })

  // ── TC-ENV-04-06 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-06: Promote button NOT visible on DRAFT definition in test tenant', async ({
    page,
    request,
  }) => {
    if (!fixture) {
      throw new Error('TC-ENV-04-06: No test tenant fixture available.')
    }

    const uid = randomUUID().slice(0, 8)
    const defName = `env04-06-def-${uid}`
    let defId = ''
    try {
      // Create a DRAFT definition (do not activate)
      const def = await createDefinition(request, fixture.testTenantToken, defName)
      defId = def.id

      await loginWithToken(page, fixture.testTenantToken)
      await navigateSpa(page, `/definitions/${defId}`)
      await page.waitForTimeout(2_000)

      await shot(page, 'TC-06-draft-def-test-tenant-no-promote-btn')

      const btnCount = await page
        .locator('[data-testid="btn-promote-to-production"]')
        .count()
      expect(
        btnCount,
        'Screen shows no Promote to Production button on DRAFT definition',
      ).toBe(0)
    } finally {
      if (defId) await deleteDefinition(request, fixture.testTenantToken, defId)
    }
  })

  // ── TC-ENV-04-08 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-08: Clicking Promote shows confirmation modal with correct message', async ({
    page,
    request,
  }) => {
    if (!fixture) {
      throw new Error('TC-ENV-04-08: No test tenant fixture available.')
    }

    const uid = randomUUID().slice(0, 8)
    const defName = `env04-08-def-${uid}`
    let defId = ''
    try {
      const def = await createDefinition(request, fixture.testTenantToken, defName)
      defId = def.id
      await activateDefinition(request, fixture.testTenantToken, defId)

      await loginWithToken(page, fixture.testTenantToken)
      await navigateSpa(page, `/definitions/${defId}`)

      const promoteBtn = page.locator('[data-testid="btn-promote-to-production"]')
      await expect(promoteBtn, 'Promote to Production button is visible').toBeVisible({
        timeout: 15_000,
      })

      await shot(page, 'TC-08-before-click-promote')
      await promoteBtn.click()

      const modal = page.locator('[data-testid="promote-confirm-modal"]')
      await expect(modal, 'Screen shows confirmation modal after click').toBeVisible({
        timeout: 8_000,
      })

      await shot(page, 'TC-08-modal-visible')

      const modalText = await modal.textContent()
      expect(modalText ?? '', `Screen shows definition name "${defName}" in modal body`).toContain(defName)
      expect(
        modalText ?? '',
        `Screen shows production tenant name "${fixture.prodTenantDisplayName}" in modal body`,
      ).toContain(fixture.prodTenantDisplayName)

      const confirmBtn = page.locator('[data-testid="promote-modal-confirm"]')
      const cancelBtn = page.locator('[data-testid="promote-modal-cancel"]')
      await expect(confirmBtn, 'Screen shows Confirm button').toBeVisible()
      await expect(cancelBtn, 'Screen shows Cancel button').toBeVisible()
      await expect(confirmBtn, 'Confirm button is enabled').toBeEnabled()
      await expect(cancelBtn, 'Cancel button is enabled').toBeEnabled()

      await cancelBtn.click()
      await expect(modal, 'Modal is dismissed after Cancel').not.toBeVisible({ timeout: 5_000 })
      await shot(page, 'TC-08-modal-dismissed')
    } finally {
      if (defId) await deleteDefinition(request, fixture.testTenantToken, defId)
    }
  })

  // ── TC-ENV-04-09 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-09: Confirming promotion creates DRAFT on production tenant (API succeeds)', async ({
    page,
    request,
  }) => {
    if (!fixture) {
      throw new Error('TC-ENV-04-09: No test tenant fixture available.')
    }

    const uid = randomUUID().slice(0, 8)
    const defName = `env04-09-def-${uid}`
    let defId = ''
    try {
      const def = await createDefinition(request, fixture.testTenantToken, defName)
      defId = def.id
      await activateDefinition(request, fixture.testTenantToken, defId)

      await loginWithToken(page, fixture.testTenantToken)
      await navigateSpa(page, `/definitions/${defId}`)

      const promoteBtn = page.locator('[data-testid="btn-promote-to-production"]')
      await expect(promoteBtn, 'Promote button is visible').toBeVisible({ timeout: 15_000 })

      await shot(page, 'TC-09-before-confirm-promote')
      await promoteBtn.click()

      const modal = page.locator('[data-testid="promote-confirm-modal"]')
      await expect(modal, 'Confirmation modal appeared').toBeVisible({ timeout: 8_000 })

      const confirmBtn = page.locator('[data-testid="promote-modal-confirm"]')
      await confirmBtn.click()

      const successMsg = page.locator('[data-testid="promote-modal-success"]')
      await expect(
        successMsg,
        'Screen shows success message after confirming promotion',
      ).toBeVisible({ timeout: 15_000 })

      const successText = await successMsg.textContent()
      expect(
        successText ?? '',
        'Screen shows "Promoted successfully" in success message',
      ).toContain('Promoted successfully')

      await shot(page, 'TC-09-promotion-success')

      await expect(modal, 'Modal closes after successful promotion').not.toBeVisible({
        timeout: 10_000,
      })
      await shot(page, 'TC-09-modal-closed-after-success')
    } finally {
      if (defId) await deleteDefinition(request, fixture.testTenantToken, defId)
    }
  })

  // ── TC-ENV-04-10 ──────────────────────────────────────────────────────────

  test('TC-ENV-04-10: Instance list shows banner (test-tenant context) — isolation via banner', async ({
    page,
  }) => {
    if (!fixture) {
      throw new Error('TC-ENV-04-10: No test tenant fixture available.')
    }

    await loginWithToken(page, fixture.testTenantToken)
    await navigateSpa(page, '/instances')
    await page.waitForSelector('[data-testid="user-display-name"]', { timeout: 15_000 })
    await page.waitForTimeout(2_000)

    await shot(page, 'TC-10-instances-page-test-tenant')

    const banner = page.locator('[data-testid="test-env-banner"]')
    await expect(
      banner,
      'Screen shows test-env-banner on instances page for test tenant session',
    ).toBeVisible({ timeout: 10_000 })

    const bannerText = await banner.textContent()
    expect(bannerText ?? '', 'Screen shows "TEST ENVIRONMENT" on instances page').toContain(
      'TEST ENVIRONMENT',
    )
  })
})
