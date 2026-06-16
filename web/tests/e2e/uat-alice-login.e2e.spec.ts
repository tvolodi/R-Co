/**
 * UAT: Alice Bauer login and dashboard verification (EO-003, EO-004)
 * 
 * This script:
 * 1. Gets Alice's token via the swiftroute realm
 * 2. Navigates to the BPM dashboard using loginWithToken
 * 3. Takes screenshots for EO-003 (Alice is logged in) and EO-004 (dashboard shows tenant)
 */
import { test } from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './pipeline'

const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://localhost:8081'

test.setTimeout(60_000)

test('EO-003+EO-004: Alice logs in to swiftroute workspace and sees dashboard', async ({ page, request }) => {
  // Get Alice's Keycloak token via the swiftroute realm
  let aliceToken: string
  try {
    aliceToken = await getKeycloakToken(request, 'alice.bauer', 'Alice-pass-001', 'swiftroute')
    console.log('ALICE_TOKEN_OK: obtained token for alice.bauer in swiftroute realm')
  } catch (err) {
    console.error('ALICE_TOKEN_ERROR:', err)
    throw err
  }

  // Step EO-003: Navigate to Keycloak account page for swiftroute realm, then fill credentials
  await page.goto(`${KEYCLOAK_BASE_URL}/realms/swiftroute/account`, { waitUntil: 'networkidle' })
  // If login page appears, fill credentials and submit
  const usernameField = page.locator('input[name="username"], input[id="username"]')
  if (await usernameField.isVisible({ timeout: 5_000 }).catch(() => false)) {
    await usernameField.fill('alice.bauer')
    await page.locator('input[name="password"], input[id="password"]').fill('Alice-pass-001')
    await page.locator('input[type="submit"], button[type="submit"]').click()
    await page.waitForLoadState('networkidle', { timeout: 15_000 })
  }
  await page.screenshot({ path: 'scratch/uat-eo-003-alice-keycloak-account.png', fullPage: true })
  const eo003Title = await page.title()
  const eo003Url = page.url()
  console.log('EO_003_SCREENSHOT: scratch/uat-eo-003-alice-keycloak-account.png')
  console.log('EO_003_TITLE:', eo003Title)
  console.log('EO_003_URL:', eo003Url)
  const eo003LoggedIn = !eo003Url.includes('/login') && !eo003Url.includes('/auth')
  console.log('EO_003_LOGGED_IN:', eo003LoggedIn)

  // Step EO-004: Navigate to BPM platform dashboard using admin token (platform admin can see tenant)
  // Then navigate to tenants list to verify swiftroute tenant workspace appears
  await loginWithToken(page, aliceToken)
  // Check what page we landed on
  await page.waitForTimeout(3000)
  const eo004Url = page.url()
  const eo004Title = await page.title()
  console.log('EO_004_URL_AFTER_INJECT:', eo004Url)
  console.log('EO_004_TITLE:', eo004Title)
  await page.screenshot({ path: 'scratch/uat-eo-004-alice-bpm-dashboard.png', fullPage: true })
  console.log('EO_004_SCREENSHOT: scratch/uat-eo-004-alice-bpm-dashboard.png')

  // Check tenant display in the header
  const tenantHeader = page.locator('[data-testid="tenant-display-name"]')
  const headerVisible = await tenantHeader.isVisible().catch(() => false)
  if (headerVisible) {
    const displayText = await tenantHeader.textContent()
    console.log('TENANT_DISPLAY_NAME:', displayText?.trim())
  } else {
    const pageText = await page.locator('body').textContent()
    const hasSwiftroute = pageText?.toLowerCase().includes('swiftroute')
    const hasPipelineTenant = pageText?.toLowerCase().includes('pipeline tenant')
    console.log('TENANT_HEADER_NOT_FOUND: sidebar_has_swiftroute=', hasSwiftroute, 'has_pipeline_tenant=', hasPipelineTenant)
  }

  // Check for other tenants being visible (cross-tenant isolation)
  const pageContent = await page.locator('body').textContent() ?? ''
  const hasVortex = pageContent.toLowerCase().includes('vortex')
  const hasMeridian = pageContent.toLowerCase().includes('meridian')
  console.log('CROSS_TENANT_VORTEX_VISIBLE:', hasVortex)
  console.log('CROSS_TENANT_MERIDIAN_VISIBLE:', hasMeridian)

  console.log('FINAL_URL:', page.url())
})
