import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { randomUUID } from 'crypto'
import * as fs from 'fs'
import * as path from 'path'
import { loginWithToken } from './helpers'

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_TOKEN_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'

test.use({ permissions: ['clipboard-read', 'clipboard-write'] })

interface FixtureUser {
  id: string
  username: string
  displayName: string
  email: string
}

interface FixtureGroup {
  id: string
  name: string
  displayName: string
  description: string
}

interface FixtureToken {
  id: string
  value: string
  user: FixtureUser
}

function getEnvOrDefault(name: string, fallback: string): string {
  const value = process.env[name]
  return value && value.trim() ? value : fallback
}

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `F5-${name}.png`)
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

function jwtSubject(token: string): string {
  const parts = token.split('.')
  if (parts.length !== 3) throw new Error('Invalid JWT format')
  const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')) as { sub?: string }
  if (!payload.sub) throw new Error('JWT does not contain sub claim')
  return payload.sub
}

function authHeaders(token: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    'x-bpm-user-id': jwtSubject(token),
  }
}

async function assertServiceReadiness(request: APIRequestContext): Promise<void> {
  const backendHealth = await request.fetch(`${API_BASE_URL}/health/ready`)
  if (!backendHealth.ok()) {
    throw new Error(`Backend readiness check failed (${backendHealth.status()}) at ${API_BASE_URL}/health/ready`)
  }

  const idpHealth = await request.fetch(KEYCLOAK_DISCOVERY_URL)
  if (!idpHealth.ok()) {
    throw new Error(`Keycloak readiness check failed (${idpHealth.status()}) at ${KEYCLOAK_DISCOVERY_URL}`)
  }
}

async function getAdminToken(request: APIRequestContext): Promise<string> {
  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: {
      client_id: KEYCLOAK_CLIENT_ID,
      username: getEnvOrDefault('BPM_E2E_ADMIN_USERNAME', 'admin-user'),
      password: getEnvOrDefault('BPM_E2E_ADMIN_PASSWORD', 'admin-pass'),
      grant_type: 'password',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Failed to fetch admin token (${response.status()}): ${body}`)
  }

  const body = await response.json() as { access_token: string }
  return body.access_token
}

async function navigateSpa(page: Page, targetPath: string): Promise<void> {
  await page.evaluate((nextPath) => {
    window.history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

async function createUser(request: APIRequestContext, token: string, prefix: string): Promise<FixtureUser> {
  const fixtureId = randomUUID()
  const username = `${prefix}-${fixtureId.slice(0, 12)}`
  const displayName = `${prefix.toUpperCase()} ${fixtureId.slice(0, 8)}`
  const email = `${username}@example.com`

  const response = await request.post(`${API_BASE_URL}/api/v1/users`, {
    headers: authHeaders(token),
    data: {
      username,
      display_name: displayName,
      email,
      status: 'ACTIVE',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Failed to create user ${username} (${response.status()}): ${body}`)
  }

  const body = await response.json() as { id?: string; user_id?: string }
  const id = body.id ?? body.user_id ?? ''
  if (!id) throw new Error(`Create user response did not include an id for ${username}`)

  return { id, username, displayName, email }
}

async function cleanupUser(request: APIRequestContext, token: string, userId: string): Promise<void> {
  const response = await request.patch(`${API_BASE_URL}/api/v1/users/${userId}`, {
    headers: authHeaders(token),
    data: { status: 'INACTIVE', is_active: false },
  })

  if (!response.ok() && response.status() !== 404) {
    throw new Error(`Failed to cleanup user ${userId} (${response.status()})`)
  }
}

async function createGroupViaUi(page: Page, name: string, displayName: string, description: string): Promise<FixtureGroup> {
  const createResponsePromise = page.waitForResponse((response) =>
    response.request().method() === 'POST' && response.url().endsWith('/api/v1/admin/groups'))

  await page.getByRole('button', { name: '+ New Group' }).click()
  const createPanel = page.locator('div').filter({ has: page.getByRole('heading', { name: 'Create group' }) }).first()
  await expect(createPanel).toBeVisible()
  const inputs = createPanel.locator('input')
  await inputs.nth(0).fill(name)
  await inputs.nth(1).fill(displayName)
  await inputs.nth(2).fill(description)
  await page.getByRole('button', { name: 'Save' }).click()

  const response = await createResponsePromise
  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Failed to create group ${name} (${response.status()}): ${body}`)
  }

  const body = await response.json() as { id?: string; group_id?: string }
  const id = body.id ?? body.group_id ?? ''
  if (!id) throw new Error(`Create group response did not include an id for ${name}`)

  return { id, name, displayName, description }
}

async function deleteGroup(request: APIRequestContext, token: string, groupId: string): Promise<void> {
  const response = await request.delete(`${API_BASE_URL}/api/v1/admin/groups/${groupId}`, {
    headers: authHeaders(token),
  })

  if (!response.ok() && response.status() !== 404) {
    throw new Error(`Failed to delete group ${groupId} (${response.status()})`)
  }
}

async function issueTokenViaUi(page: Page, user: FixtureUser, roles: string[]): Promise<FixtureToken> {
  const valuePromise = page.waitForResponse((response) =>
    response.request().method() === 'POST' && response.url().endsWith('/api/v1/auth/tokens'))

  await page.getByRole('button', { name: '+ Issue token' }).click()
  const userSelect = page.locator('select').first()
  await expect(userSelect).toBeVisible()
  await expect(userSelect.locator('option').filter({ hasText: user.email })).toHaveCount(1, { timeout: 10_000 })
  await userSelect.selectOption(user.id)
  await page.getByPlaceholder('Comma-separated roles').fill(roles.join(', '))
  await page.getByRole('button', { name: 'Issue token', exact: true }).click()

  const response = await valuePromise
  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Failed to issue token for ${user.username} (${response.status()}): ${body}`)
  }

  const body = await response.json() as { token_id?: string; token_value?: string }
  const id = body.token_id ?? ''
  const value = body.token_value ?? ''
  if (!id || !value) throw new Error(`Issue token response did not include both id and value for ${user.username}`)

  const issuedDialog = page.getByRole('dialog', { name: 'Issued token' })
  if (await issuedDialog.count()) {
    await issuedDialog.getByRole('button', { name: 'Close' }).click()
    await expect(issuedDialog).toHaveCount(0)
  }

  return { id, value, user }
}

async function revokeToken(request: APIRequestContext, token: string, tokenId: string): Promise<void> {
  const response = await request.delete(`${API_BASE_URL}/api/v1/auth/tokens/${tokenId}`, {
    headers: authHeaders(token),
  })

  if (!response.ok() && response.status() !== 404) {
    throw new Error(`Failed to revoke token ${tokenId} (${response.status()})`)
  }
}

function groupRow(page: Page, group: FixtureGroup): ReturnType<Page['locator']> {
  return page.locator('tbody tr').filter({ hasText: group.name })
}

function tokenRow(page: Page, user: FixtureUser): ReturnType<Page['locator']> {
  return page.locator('tbody tr').filter({ hasText: user.displayName })
}

test.describe('F5 admin groups and tokens UI (ADM-UI-05..08)', () => {
  test.beforeEach(async ({ request }) => {
    await assertServiceReadiness(request)
  })

  test('TC-ADM-UI-05-01: groups page supports create, member updates, and delete-empty-group flow', async ({ page, request }) => {
    const adminToken = await getAdminToken(request)
    await loginWithToken(page, adminToken)
    const user = await createUser(request, adminToken, 'adm-ui-05-user')
    const groupName = `adm-ui-05-${randomUUID().slice(0, 8)}`
    const groupDisplayName = `ADM UI 05 ${groupName}`
    const groupDescription = 'Groups flow fixture'

    let group: FixtureGroup | null = null

    try {
      await navigateSpa(page, '/admin/groups')

      await expect(page.getByRole('heading', { name: 'Groups' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Name', exact: true })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Display name' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Members' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Description' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Actions' })).toBeVisible()
      await shot(page, 'ADM-UI-05-groups-list')

      group = await createGroupViaUi(page, groupName, groupDisplayName, groupDescription)
      const createdRow = groupRow(page, group)
      await expect(createdRow).toBeVisible({ timeout: 10_000 })
      await expect(createdRow).toContainText(groupDisplayName)
      await expect(createdRow).toContainText('0')
      await shot(page, 'ADM-UI-05-group-created')

      await createdRow.getByRole('button', { name: 'Manage members' }).click()
      const dialog = page.getByRole('dialog', { name: 'Manage group members' })
      await expect(dialog).toBeVisible()
      await expect(dialog.getByText(groupDisplayName)).toBeVisible()
      await dialog.getByLabel('Add member').selectOption({ label: `${user.displayName} <${user.email}>` })
      await dialog.getByRole('button', { name: 'Add member' }).click()
      await expect(dialog.getByText(user.displayName)).toBeVisible({ timeout: 10_000 })
      await shot(page, 'ADM-UI-05-member-added')

      await dialog.getByRole('button', { name: 'Remove' }).click()
      await expect(dialog.getByText('No members in this group.')).toBeVisible({ timeout: 10_000 })
      await shot(page, 'ADM-UI-05-member-removed')

      await dialog.getByRole('button', { name: 'Close' }).click()
      await expect(createdRow).toContainText('0')
      await expect(createdRow.getByRole('button', { name: 'Delete' })).toBeVisible()

      createdRow.getByRole('button', { name: 'Delete' }).click()
      const deleteDialog = page.getByRole('dialog', { name: 'Delete group' })
      await expect(deleteDialog).toBeVisible()
      await deleteDialog.getByRole('button', { name: 'Delete group' }).click()
      await expect(groupRow(page, group)).toHaveCount(0, { timeout: 10_000 })
      await shot(page, 'ADM-UI-05-group-deleted')
    } finally {
      if (group) {
        await deleteGroup(request, adminToken, group.id)
      }
      await cleanupUser(request, adminToken, user.id)
    }
  })

  test('TC-ADM-UI-06-01: token list shows metadata and never reveals the raw token value', async ({ page, request }) => {
    const adminToken = await getAdminToken(request)
    await loginWithToken(page, adminToken)
    const user = await createUser(request, adminToken, 'adm-ui-06-user')
    await navigateSpa(page, '/admin/tokens')
    const token = await issueTokenViaUi(page, user, ['TASK_WORKER', 'PROCESS_OPERATOR'])

    try {
      await navigateSpa(page, '/admin/tokens')

      await expect(page.getByRole('heading', { name: 'API Tokens' })).toBeVisible()
      const row = tokenRow(page, user)
      await expect(row).toBeVisible({ timeout: 10_000 })
      await expect(row).toContainText(user.displayName)
      await expect(row).toContainText('TASK_WORKER, PROCESS_OPERATOR')
      await expect(row).toContainText('Never')
      await expect(row).toContainText('ACTIVE')
      await expect(row.locator('td').nth(3)).not.toHaveText('', { timeout: 10_000 })
      await expect(page.getByText(token.value, { exact: true })).toHaveCount(0)
      await shot(page, 'ADM-UI-06-token-list')
    } finally {
      await revokeToken(request, adminToken, token.id)
      await cleanupUser(request, adminToken, user.id)
    }
  })

  test('TC-ADM-UI-07-01: issue-token flow shows the one-time modal, copy action, and close behavior', async ({ page, request }) => {
    const adminToken = await getAdminToken(request)
    await loginWithToken(page, adminToken)
    const user = await createUser(request, adminToken, 'adm-ui-07-user')
    let token: FixtureToken | null = null

    try {
      await navigateSpa(page, '/admin/tokens')

      await expect(page.getByRole('heading', { name: 'API Tokens' })).toBeVisible()
      await page.getByRole('button', { name: '+ Issue token' }).click()
      await expect(page.getByRole('heading', { name: 'Issue token' })).toBeVisible()
      await expect(page.locator('input[type="datetime-local"]')).toBeVisible()
      const userSelect = page.locator('select').first()
      await expect(userSelect.locator('option').filter({ hasText: user.email })).toHaveCount(1, { timeout: 10_000 })
      await userSelect.selectOption(user.id)
      await page.getByPlaceholder('Comma-separated roles').fill('TASK_WORKER, PROCESS_OPERATOR')

      const createResponsePromise = page.waitForResponse((response) =>
        response.request().method() === 'POST' && response.url().endsWith('/api/v1/auth/tokens'))
      await page.getByRole('button', { name: 'Issue token', exact: true }).click()
      const response = await createResponsePromise
      if (!response.ok()) {
        const body = await response.text()
        throw new Error(`Issue-token submission failed (${response.status()}): ${body}`)
      }

      const body = await response.json() as { token_id?: string; token_value?: string }
      const id = body.token_id ?? ''
      const value = body.token_value ?? ''
      if (!id || !value) throw new Error('Issue-token response did not include token id and value')
      token = { id, value, user }

      const issuedDialog = page.getByRole('dialog', { name: 'Issued token' })
      await expect(issuedDialog).toBeVisible()
      await expect(issuedDialog).toContainText('This value will not be shown again.')
      const tokenValue = issuedDialog.getByTestId('issued-token-value')
      await expect(tokenValue).toHaveText(value)
      await issuedDialog.getByRole('button', { name: 'Copy token' }).click()
      await expect(issuedDialog.getByText('Copied')).toBeVisible()
      await shot(page, 'ADM-UI-07-issued-token-modal')

      await issuedDialog.getByRole('button', { name: 'Close' }).click()
      await expect(issuedDialog).toHaveCount(0)
      await expect(page.getByText(value, { exact: true })).toHaveCount(0)
      await shot(page, 'ADM-UI-07-modal-closed')
    } finally {
      if (token) {
        await revokeToken(request, adminToken, token.id)
      }
      await cleanupUser(request, adminToken, user.id)
    }
  })

  test('TC-ADM-UI-08-01: revoke flow confirms the action and marks the token row as revoked', async ({ page, request }) => {
    const adminToken = await getAdminToken(request)
    await loginWithToken(page, adminToken)
    const user = await createUser(request, adminToken, 'adm-ui-08-user')
    await navigateSpa(page, '/admin/tokens')
    const token = await issueTokenViaUi(page, user, ['TASK_WORKER'])

    try {
      await navigateSpa(page, '/admin/tokens')

      const row = tokenRow(page, user)
      await expect(row).toBeVisible({ timeout: 10_000 })
      await expect(row).toContainText('ACTIVE')

      await row.getByRole('button', { name: 'Revoke' }).click()
      const dialog = page.getByRole('dialog', { name: 'Revoke token' })
      await expect(dialog).toBeVisible()
      await expect(dialog.getByText('Revoking this API token immediately removes access for the associated user and roles.')).toBeVisible()
      await shot(page, 'ADM-UI-08-confirmation-dialog')

      await dialog.getByRole('button', { name: 'Revoke token' }).click()
      await expect(row).toContainText('REVOKED', { timeout: 10_000 })
      await expect(row).toHaveCSS('text-decoration-line', 'line-through', { timeout: 10_000 })
      await expect(row.getByRole('button', { name: 'Revoke' })).toHaveCount(0)
      await shot(page, 'ADM-UI-08-token-revoked')
    } finally {
      await revokeToken(request, adminToken, token.id)
      await cleanupUser(request, adminToken, user.id)
    }
  })
})