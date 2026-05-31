import { expect, test } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
const KEYCLOAK_TOKEN_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'

function getEnvOrDefault(name: string, fallback: string): string {
  const value = process.env[name]
  return value && value.trim() ? value : fallback
}

function getAdminCredentials(): { username: string; password: string } {
  return {
    username: getEnvOrDefault('BPM_E2E_ADMIN_USERNAME', 'admin-user'),
    password: getEnvOrDefault('BPM_E2E_ADMIN_PASSWORD', 'admin-pass'),
  }
}

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `F6-${name}.png`)
}

async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

async function getKeycloakToken(
  request: import('@playwright/test').APIRequestContext,
  username: string,
  password: string,
): Promise<string> {
  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: { client_id: KEYCLOAK_CLIENT_ID, username, password, grant_type: 'password' },
  })

  if (!response.ok()) {
    throw new Error(`Failed to fetch token (${response.status()})`)
  }

  const body = (await response.json()) as { access_token: string }
  return body.access_token
}

async function assertServiceReadiness(
  request: import('@playwright/test').APIRequestContext,
): Promise<void> {
  const backendHealth = await request.fetch(`${API_BASE_URL}/health/ready`)
  if (!backendHealth.ok()) {
    throw new Error(`Backend readiness check failed (${backendHealth.status()}) at ${API_BASE_URL}/health/ready`)
  }

  const idpHealth = await request.fetch(KEYCLOAK_DISCOVERY_URL)
  if (!idpHealth.ok()) {
    throw new Error(`Keycloak readiness check failed (${idpHealth.status()}) at ${KEYCLOAK_DISCOVERY_URL}`)
  }
}

async function loginWithToken(page: import('@playwright/test').Page, token: string): Promise<void> {
  await page.goto('/login')
  await expect(page.getByTestId('login-token-input')).toBeVisible({ timeout: 10_000 })
  const tokenInput = page.getByTestId('login-token-input')
  const submitButton = page.getByTestId('login-submit')

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await tokenInput.fill(token)
    await submitButton.click()

    try {
      await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 7_500 })
      return
    } catch {
      const invalidAlert = page.getByText('Invalid token or access denied.')
      if (attempt < 3 && await invalidAlert.isVisible()) {
        await page.waitForTimeout(1_000)
        continue
      }
      throw new Error(`Token login did not complete after ${attempt} attempt(s)`)
    }
  }
}

async function navigateSpa(page: import('@playwright/test').Page, targetPath: string): Promise<void> {
  await page.evaluate((nextPath) => {
    window.history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

test.describe('F6 DLQ UI (DLQ-UI-01..04)', () => {
  let adminToken = ''

  test.beforeEach(async ({ request }) => {
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    adminToken = await getKeycloakToken(request, creds.username, creds.password)
  })

  test('DLQ list renders and supports details, retry wiring, discard confirmation', async ({ page }) => {
    await loginWithToken(page, adminToken)

    await navigateSpa(page, '/dlq')
    await expect(page.getByRole('heading', { name: 'Dead-Letter Queue' })).toBeVisible({ timeout: 10_000 })
    await expect(page.getByTestId('dlq-table')).toBeVisible()
    await shot(page, 'DLQ-UI-01-list')

    const rows = page.locator('[data-testid^="dlq-row-"]')
    const rowCount = await rows.count()

    if (rowCount === 0) {
      await expect(page.getByText('Queue is empty.')).toBeVisible()
      await shot(page, 'DLQ-empty-state')
      return
    }

    const firstRow = rows.first()
    const rowTestId = await firstRow.getAttribute('data-testid')
    if (!rowTestId) {
      throw new Error('Missing DLQ row test id for first row')
    }

    const detailsButtonId = rowTestId.replace('dlq-row-', 'dlq-details-')
    const retryButtonId = rowTestId.replace('dlq-row-', 'dlq-retry-')
    const discardButtonId = rowTestId.replace('dlq-row-', 'dlq-discard-')

    await page.getByTestId(detailsButtonId).click()
    await expect(page.getByTestId('dlq-detail-panel')).toBeVisible()
    await expect(page.getByText('Full failure reason')).toBeVisible()
    await expect(page.getByText('Retry history')).toBeVisible()
    await expect(page.getByText('Source payload')).toBeVisible()
    await shot(page, 'DLQ-UI-02-detail-panel')

    if (await page.getByTestId(discardButtonId).isVisible()) {
      await page.getByTestId(discardButtonId).click()
      await expect(page.getByTestId('dlq-discard-dialog')).toBeVisible()
      await expect(page.getByText('Discard this DLQ item?')).toBeVisible()
      await shot(page, 'DLQ-UI-04-discard-confirmation')
      await page.getByRole('button', { name: 'Cancel' }).click()
      await expect(page.getByTestId('dlq-discard-dialog')).toBeHidden()
    }

    if (await page.getByTestId(retryButtonId).isVisible()) {
      await page.getByTestId(retryButtonId).click()

      const retryIndicator = page.locator('[data-testid^="dlq-row-"]').first().getByText(/retrying/i)
      const actionError = page.getByText('Retry failed. Please try again.')

      await Promise.race([
        retryIndicator.waitFor({ state: 'visible', timeout: 10_000 }),
        actionError.waitFor({ state: 'visible', timeout: 10_000 }),
      ])
      await shot(page, 'DLQ-UI-03-retry-attempt')
    }
  })
})
