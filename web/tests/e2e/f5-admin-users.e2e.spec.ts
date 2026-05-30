import { expect, test } from '@playwright/test'
import * as fs from 'fs'
import * as path from 'path'

const SCREENSHOTS_DIR = 'tests/screenshots'
const KEYCLOAK_TOKEN_URL = 'http://localhost:8081/realms/bpm-default/protocol/openid-connect/token'
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'
const KEYCLOAK_ADMIN_USERNAME = 'admin-user'
const KEYCLOAK_ADMIN_PASSWORD = 'admin-pass'
const ADMIN_SEARCH_USERNAME = 'admin-user'

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `F5-${name}.png`)
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

async function loginWithToken(page: import('@playwright/test').Page, token: string): Promise<void> {
  await page.goto('/login')
  await expect(page.getByTestId('login-token-input')).toBeVisible({ timeout: 10_000 })
  await page.getByTestId('login-token-input').fill(token)
  await page.getByTestId('login-submit').click()

  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 15_000 })
}

async function navigateSpa(page: import('@playwright/test').Page, targetPath: string): Promise<void> {
  await page.evaluate((nextPath) => {
    window.history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

test.describe('F5 admin users UI (ADM-UI-01..04)', () => {
  const adminUsername = ADMIN_SEARCH_USERNAME
  let adminToken = ''

  test.beforeEach(async ({ request }) => {
    adminToken = await getKeycloakToken(request, KEYCLOAK_ADMIN_USERNAME, KEYCLOAK_ADMIN_PASSWORD)
  })

  test('ADM-UI-01..04: list, create, edit, and deactivate user with visible confirmations', async ({ page }) => {
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

    const createUsername = `tc-f5-new-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
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
    await expect(page.getByTestId('admin-user-detail-form')).toBeVisible()
    await shot(page, 'ADM-UI-02-created-user-detail')

    await page.getByTestId('admin-user-display-name').fill('F5 Updated Name')
    await page.getByTestId('admin-user-email').fill(`${createUsername}.updated@example.com`)
    await page.getByTestId('admin-user-save').click()
    await expect(page.getByTestId('admin-user-submit-message')).toContainText('Saved', { timeout: 10_000 })
    await shot(page, 'ADM-UI-03-edited-user')

    await page.getByTestId('admin-user-deactivate').click()
    await expect(page.getByText('Active tasks assigned to this user remain assigned')).toBeVisible()
    await expect(page.getByText('cannot complete them while INACTIVE')).toBeVisible()
    await shot(page, 'ADM-UI-04-confirmation-dialog')

    await page.getByLabel('Deactivate user').getByRole('button', { name: 'Deactivate' }).click()
    await expect(page.getByTestId('admin-user-status')).toHaveValue('INACTIVE', { timeout: 10_000 })
    await expect(page.getByTestId('admin-user-submit-message')).toContainText('deactivated', { timeout: 10_000 })
    await shot(page, 'ADM-UI-04-user-inactive')
  })
})
