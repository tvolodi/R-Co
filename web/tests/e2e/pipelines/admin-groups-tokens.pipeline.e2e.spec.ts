/**
 * Pipeline: Admin Groups and API Tokens Lifecycle
 * Spec: tests/specs/PIPELINE-admin-groups-tokens.md
 * Covers: ADM-UI-05, ADM-UI-06, ADM-UI-07, ADM-UI-08
 *
 * Chain: create user → groups list → create group → add member →
 *        remove member + delete group → issue token (one-time modal) →
 *        verify token list → revoke token → cleanup user
 */

import { test, expect } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  authHeaders,
} from '../pipeline'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

interface GroupsTokensState {
  adminToken: string
  userId: string
  username: string
  displayName: string
  email: string
  groupId: string
  groupName: string
  groupDisplayName: string
  tokenId: string
  tokenValue: string
}

test.describe('Pipeline: admin groups and tokens lifecycle (ADM-UI-05..08)', () => {
  test('full lifecycle: create user → group CRUD → issue token → verify → revoke', async ({ page, request }) => {
    const backendOk = await request.fetch(`${API_BASE_URL}/health/ready`)
    if (!backendOk.ok()) throw new Error(`Backend not ready: ${backendOk.status()}`)
    const idpOk = await request.fetch(KEYCLOAK_DISCOVERY_URL)
    if (!idpOk.ok()) throw new Error(`Keycloak not ready: ${idpOk.status()}`)

    const adminToken = await getKeycloakToken(request)
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 12)
    const username = `pl-gt-${fixtureId}`
    const email = `${username}@example.com`
    const displayName = `Pipeline GT ${fixtureId}`
    const groupName = `pl-group-${fixtureId}`
    const groupDisplayName = `Pipeline Group ${fixtureId}`

    const pl = createPipeline<GroupsTokensState>('admin-groups-tokens', { page, request })
    pl.state.adminToken = adminToken

    pl.onCleanup(async (s) => {
      if (s.tokenId) {
        await request.delete(`${API_BASE_URL}/api/v1/auth/tokens/${s.tokenId}`, {
          headers: authHeaders(s.adminToken),
        }).catch(() => {})
      }
      if (s.groupId) {
        await request.delete(`${API_BASE_URL}/api/v1/admin/groups/${s.groupId}`, {
          headers: authHeaders(s.adminToken),
        }).catch(() => {})
      }
      if (s.userId) {
        await request.patch(`${API_BASE_URL}/api/v1/users/${s.userId}`, {
          headers: authHeaders(s.adminToken),
          data: { status: 'INACTIVE', is_active: false },
        }).catch(() => {})
      }
    })

    // ── Step 1: Create user fixture via API ───────────────────────────────────
    await pl.step('create user fixture', async (s) => {
      const resp = await request.post(`${API_BASE_URL}/api/v1/users`, {
        headers: authHeaders(s.adminToken),
        data: { username, display_name: displayName, email, status: 'ACTIVE' },
      })
      if (!resp.ok()) throw new Error(`Create user failed (${resp.status()}): ${await resp.text()}`)
      const body = await resp.json() as { id?: string; user_id?: string }
      s.userId = body.id ?? body.user_id ?? ''
      s.username = username
      s.displayName = displayName
      s.email = email
      pl.gate(!!s.userId, 'userId must be present after user creation')
    })

    // ── Step 2: Groups list structure ─────────────────────────────────────────
    await pl.step('ADM-UI-05a: groups list columns', async () => {
      await navigateSpa(page, '/admin/groups')
      await expect(page.getByRole('heading', { name: 'Groups' })).toBeVisible({ timeout: 10_000 })
      await expect(page.getByRole('columnheader', { name: 'Name', exact: true })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Display name' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Members' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Description' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Actions' })).toBeVisible()
    })

    // ── Step 3: Create group via UI ───────────────────────────────────────────
    await pl.step('ADM-UI-05b: create group via UI', async (s) => {
      await navigateSpa(page, '/admin/groups')

      const createResponsePromise = page.waitForResponse((r) =>
        r.request().method() === 'POST' && r.url().includes('/api/v1/admin/groups'))

      await page.getByRole('button', { name: '+ New Group' }).click()
      const createPanel = page.locator('div').filter({ has: page.getByRole('heading', { name: 'Create group' }) }).first()
      await expect(createPanel).toBeVisible()
      const inputs = createPanel.locator('input')
      await inputs.nth(0).fill(groupName)
      await inputs.nth(1).fill(groupDisplayName)
      await inputs.nth(2).fill('Pipeline test group')
      await page.getByRole('button', { name: 'Save' }).click()

      const createResp = await createResponsePromise
      if (!createResp.ok()) throw new Error(`Create group failed (${createResp.status()})`)
      const body = await createResp.json() as { id?: string; group_id?: string }
      s.groupId = body.id ?? body.group_id ?? ''
      s.groupName = groupName
      s.groupDisplayName = groupDisplayName
      pl.gate(!!s.groupId, 'groupId must be present after group creation')

      const groupRow = page.locator('tbody tr').filter({ hasText: groupName })
      await expect(groupRow).toBeVisible({ timeout: 10_000 })
      await expect(groupRow).toContainText(groupDisplayName)
      await expect(groupRow).toContainText('0')
    })

    // ── Step 4: Add user as group member ──────────────────────────────────────
    await pl.step('ADM-UI-05c: add member to group', async (s) => {
      await navigateSpa(page, '/admin/groups')
      const groupRow = page.locator('tbody tr').filter({ hasText: s.groupName })
      await expect(groupRow).toBeVisible({ timeout: 10_000 })

      await groupRow.getByRole('button', { name: 'Manage members' }).click()
      const dialog = page.getByRole('dialog', { name: 'Manage group members' })
      await expect(dialog).toBeVisible()

      await dialog.getByLabel('Add member').selectOption({ label: `${s.displayName} <${s.email}>` })
      await dialog.getByRole('button', { name: 'Add member' }).click()
      await expect(dialog.getByText(s.displayName)).toBeVisible({ timeout: 10_000 })
      await dialog.getByRole('button', { name: 'Close' }).click()
    })

    // ── Step 5: Remove member and delete group ────────────────────────────────
    await pl.step('ADM-UI-05d: remove member and delete group', async (s) => {
      await navigateSpa(page, '/admin/groups')
      const groupRow = page.locator('tbody tr').filter({ hasText: s.groupName })
      await expect(groupRow).toBeVisible({ timeout: 10_000 })

      await groupRow.getByRole('button', { name: 'Manage members' }).click()
      const dialog = page.getByRole('dialog', { name: 'Manage group members' })
      await expect(dialog).toBeVisible()
      await dialog.getByRole('button', { name: 'Remove' }).click()
      await expect(dialog.getByText('No members in this group.')).toBeVisible({ timeout: 10_000 })
      await dialog.getByRole('button', { name: 'Close' }).click()

      await expect(groupRow).toContainText('0')
      groupRow.getByRole('button', { name: 'Delete' }).click()
      const deleteDialog = page.getByRole('dialog', { name: 'Delete group' })
      await expect(deleteDialog).toBeVisible()
      await deleteDialog.getByRole('button', { name: 'Delete group' }).click()
      await expect(page.locator('tbody tr').filter({ hasText: s.groupName })).toHaveCount(0, { timeout: 10_000 })
      s.groupId = '' // deleted — cleanup handler should skip
    })

    // ── Step 6: Issue API token (one-time reveal modal) ───────────────────────
    await pl.step('ADM-UI-07: issue token and verify one-time modal', async (s) => {
      await navigateSpa(page, '/admin/tokens')
      await expect(page.getByRole('heading', { name: 'API Tokens' })).toBeVisible()

      const createResponsePromise = page.waitForResponse((r) =>
        r.request().method() === 'POST' && r.url().endsWith('/api/v1/auth/tokens'))

      await page.getByRole('button', { name: '+ Issue token' }).click()
      const userSelect = page.locator('select').first()
      await expect(userSelect.locator('option').filter({ hasText: s.email })).toHaveCount(1, { timeout: 10_000 })
      await userSelect.selectOption(s.userId)
      await page.getByPlaceholder('Comma-separated roles').fill('TASK_WORKER, PROCESS_OPERATOR')
      await page.getByRole('button', { name: 'Issue token', exact: true }).click()

      const createResp = await createResponsePromise
      if (!createResp.ok()) throw new Error(`Issue token failed (${createResp.status()})`)
      const body = await createResp.json() as { token_id?: string; token_value?: string }
      s.tokenId = body.token_id ?? ''
      s.tokenValue = body.token_value ?? ''
      pl.gate(!!s.tokenId && !!s.tokenValue, 'tokenId and tokenValue must be present after token issuance')

      const issuedDialog = page.getByRole('dialog', { name: 'Issued token' })
      await expect(issuedDialog).toBeVisible()
      await expect(issuedDialog).toContainText('This value will not be shown again.')
      await expect(issuedDialog.getByTestId('issued-token-value')).toHaveText(s.tokenValue)

      await issuedDialog.getByRole('button', { name: 'Close' }).click()
      await expect(issuedDialog).toHaveCount(0)
      await expect(page.getByText(s.tokenValue, { exact: true })).toHaveCount(0)
    })

    // ── Step 7: Verify token list metadata, no raw value exposed ─────────────
    await pl.step('ADM-UI-06: token list shows metadata, no raw value', async (s) => {
      await navigateSpa(page, '/admin/tokens')
      await expect(page.getByRole('heading', { name: 'API Tokens' })).toBeVisible()

      const tokenRow = page.locator('tbody tr').filter({ hasText: s.displayName })
      await expect(tokenRow).toBeVisible({ timeout: 10_000 })
      await expect(tokenRow).toContainText('TASK_WORKER, PROCESS_OPERATOR')
      await expect(tokenRow).toContainText('Never')
      await expect(tokenRow).toContainText('ACTIVE')
      await expect(page.getByText(s.tokenValue, { exact: true })).toHaveCount(0)
    })

    // ── Step 8: Revoke token ──────────────────────────────────────────────────
    await pl.step('ADM-UI-08: revoke token', async (s) => {
      await navigateSpa(page, '/admin/tokens')
      const tokenRow = page.locator('tbody tr').filter({ hasText: s.displayName })
      await expect(tokenRow).toBeVisible({ timeout: 10_000 })
      await expect(tokenRow).toContainText('ACTIVE')

      await tokenRow.getByRole('button', { name: 'Revoke' }).click()
      const dialog = page.getByRole('dialog', { name: 'Revoke token' })
      await expect(dialog).toBeVisible()
      await dialog.getByRole('button', { name: 'Revoke token' }).click()
      await expect(tokenRow).toContainText('REVOKED', { timeout: 10_000 })
      await expect(tokenRow.getByRole('button', { name: 'Revoke' })).toHaveCount(0)
      s.tokenId = '' // revoked — cleanup handler should skip
    })

    await pl.runCleanup()
  })
})
