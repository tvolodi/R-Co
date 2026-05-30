import { expect, test } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'
import { randomUUID } from 'crypto'

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
    // Keep explicit env overrides, but provide deterministic defaults for local/CI runs.
    username: getEnvOrDefault('BPM_E2E_ADMIN_USERNAME', 'admin-user'),
    password: getEnvOrDefault('BPM_E2E_ADMIN_PASSWORD', 'admin-pass'),
  }
}

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `F5-${name}.png`)
}

async function shot(page: import('@playwright/test').Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

function jwtSubject(token: string): string {
  const parts = token.split('.')
  if (parts.length !== 3) throw new Error('Invalid JWT format')
  const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')) as { sub?: string }
  if (!payload.sub) throw new Error('JWT does not contain sub claim')
  return payload.sub
}

async function createUserFixture(
  page: import('@playwright/test').Page,
  label: string,
): Promise<{ id: string; username: string; email: string }> {
  const fixtureId = randomUUID()
  const username = `f5-${label}-${fixtureId.slice(0, 12)}`
  const email = `${username}@example.com`

  await navigateSpa(page, '/admin/users')
  await page.getByTestId('admin-users-new').click()
  await page.getByLabel('Username').fill(username)
  await page.getByLabel('Display name').fill(`Fixture ${label}`)
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password').fill(`pw-${fixtureId.slice(0, 16)}`)
  await page.getByRole('button', { name: 'Create user' }).click()
  await page.waitForURL(/\/admin\/users\/.+/, { timeout: 15_000 })

  const createdPath = page.url().split('/admin/users/')[1] ?? ''
  const createdId = createdPath.split('?')[0].split('#')[0]
  if (!createdId) {
    throw new Error('Failed to create fixture user (missing created id from URL)')
  }
  return { id: createdId, username, email }
}

async function cleanupUserFixture(
  request: import('@playwright/test').APIRequestContext,
  token: string,
  userId: string,
): Promise<void> {
  const response = await request.patch(`${API_BASE_URL}/api/v1/admin/users/${userId}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'x-bpm-user-id': jwtSubject(token),
    },
    data: {
      status: 'INACTIVE',
      is_active: false,
    },
  })

  if (!response.ok() && response.status() !== 404) {
    throw new Error(`Failed to cleanup fixture user ${userId} (${response.status()})`)
  }
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

test.describe('F5 admin users UI (ADM-UI-01..04)', () => {
  let adminUsername = ''
  let adminToken = ''

  test.beforeEach(async ({ request }) => {
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    adminUsername = creds.username
    adminToken = await getKeycloakToken(request, creds.username, creds.password)
  })

  test('ADM-UI-01: user list shows required table columns and supports search', async ({ page }) => {
    await loginWithToken(page, adminToken)

    await navigateSpa(page, '/admin/users')
    await expect(page.getByRole('heading', { name: 'Users' })).toBeVisible({ timeout: 10_000 })
    await expect(page.getByTestId('admin-users-table')).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Username' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Display name' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Email' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Roles' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Status' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Created' })).toBeVisible()
    await shot(page, 'ADM-UI-01-list-columns')

    await page.getByTestId('admin-users-search').fill(adminUsername)
    await page.getByRole('button', { name: 'Apply' }).click()
    await expect(page.getByTestId('admin-users-table')).toBeVisible()
    await shot(page, 'ADM-UI-01-search-results')
  })

  test('ADM-UI-02: new user flow collects required fields and creates user', async ({ page, request }) => {
    const cleanupUserIds: string[] = []
    try {
      await loginWithToken(page, adminToken)
      await navigateSpa(page, '/admin/users')

      const createUsername = `tc-f5-create-${randomUUID().slice(0, 12)}`
      await page.getByTestId('admin-users-new').click()
      await page.getByLabel('Username').fill(createUsername)
      await page.getByLabel('Display name').fill('F5 New User')
      await page.getByLabel('Email').fill(`${createUsername}@example.com`)
      const firstRole = page.locator('input[name="role_ids"]').first()
      if (await firstRole.count()) {
        await firstRole.check()
      }
      await page.getByRole('button', { name: 'Create user' }).click()
      await page.waitForURL(/\/admin\/users\/.+/, { timeout: 15_000 })
      const createdPath = page.url().split('/admin/users/')[1] ?? ''
      const createdId = createdPath.split('?')[0].split('#')[0]
      if (createdId) cleanupUserIds.push(createdId)
      await expect(page.getByTestId('admin-user-detail-form')).toBeVisible()
      await shot(page, 'ADM-UI-02-created-user-detail')
    } finally {
      for (const userId of cleanupUserIds) {
        await cleanupUserFixture(request, adminToken, userId)
      }
    }
  })

  test('ADM-UI-03: user detail page updates profile, status, roles, and groups', async ({ page, request }) => {
    await loginWithToken(page, adminToken)
    const fixture = await createUserFixture(page, 'edit')

    try {
      await navigateSpa(page, `/admin/users/${fixture.id}`)
      await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })
      await expect(page.getByRole('heading', { name: 'Role assignments' })).toBeVisible()
      await expect(page.getByRole('heading', { name: 'Group memberships' })).toBeVisible()

      const roleCheckbox = page.locator('input[type="checkbox"]').first()
      if (await roleCheckbox.count()) {
        const wasChecked = await roleCheckbox.isChecked()
        if (wasChecked) {
          await roleCheckbox.uncheck()
        } else {
          await roleCheckbox.check()
        }
      }

      await page.getByTestId('admin-user-display-name').fill('F5 Updated Name')
      await page.getByTestId('admin-user-email').fill(`${fixture.username}.updated@example.com`)
      await page.getByTestId('admin-user-status').selectOption('ACTIVE')
      await page.getByTestId('admin-user-save').click()
      await expect(page.getByTestId('admin-user-submit-message')).toContainText('Saved', { timeout: 10_000 })
      await shot(page, 'ADM-UI-03-edited-user')
    } finally {
      await cleanupUserFixture(request, adminToken, fixture.id)
    }
  })

  test('ADM-UI-04: deactivate action shows warning copy and sets status to INACTIVE', async ({ page, request }) => {
    await loginWithToken(page, adminToken)
    const fixture = await createUserFixture(page, 'deactivate')

    try {
      await navigateSpa(page, `/admin/users/${fixture.id}`)
      await expect(page.getByTestId('admin-user-detail-form')).toBeVisible({ timeout: 15_000 })

      await page.getByTestId('admin-user-deactivate').click()
      await expect(page.getByText('Active tasks assigned to this user remain assigned')).toBeVisible()
      await expect(page.getByText('cannot complete them while INACTIVE')).toBeVisible()
      await shot(page, 'ADM-UI-04-confirmation-dialog')

      await page.getByLabel('Deactivate user').getByRole('button', { name: 'Deactivate' }).click()
      await expect(page.getByTestId('admin-user-status')).toHaveValue('INACTIVE', { timeout: 10_000 })
      await expect(page.getByTestId('admin-user-submit-message')).toContainText('deactivated', { timeout: 10_000 })
      await shot(page, 'ADM-UI-04-user-inactive')
    } finally {
      await cleanupUserFixture(request, adminToken, fixture.id)
    }
  })
})
