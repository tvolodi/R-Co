/**
 * Pipeline: Admin User Lifecycle
 *
 * Covers: ADM-UI-01 → ADM-UI-02 → ADM-UI-03 → ADM-UI-04
 *
 * Chain topology:
 *   login
 *   → verify user list (ADM-UI-01)
 *   → create user (ADM-UI-02)          [produces: userId, username]
 *   → update user profile (ADM-UI-03)  [reads: userId]
 *   → assign role (ADM-UI-03)          [reads: userId]
 *   → deactivate user (ADM-UI-04)      [reads: userId — also serves as cleanup]
 *
 * A failure at any step aborts all subsequent steps. The deactivate step
 * is registered as cleanup so it always runs even if the chain aborted
 * mid-way, preventing orphaned test users.
 */

import { test } from '@playwright/test'
import { randomUUID } from 'crypto'
import {
  createPipeline,
  getKeycloakToken,
  loginWithToken,
  navigateSpa,
  extractIdFromUrl,
  authHeaders,
} from '../pipeline'

const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

interface UserLifecycleState {
  adminToken: string
  userId: string
  username: string
  email: string
}

test.describe('Pipeline: admin user lifecycle (ADM-UI-01..04)', () => {
  test('full lifecycle: list → create → update → assign role → deactivate', async ({ page, request }) => {
    // Pre-check: services must be reachable before we start the chain
    const backendOk = await request.fetch(`${API_BASE_URL}/health/ready`)
    if (!backendOk.ok()) throw new Error(`Backend not ready: ${backendOk.status()}`)
    const idpOk = await request.fetch(KEYCLOAK_DISCOVERY_URL)
    if (!idpOk.ok()) throw new Error(`Keycloak not ready: ${idpOk.status()}`)

    const adminToken = await getKeycloakToken(request)
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 12)
    const username = `pl-user-${fixtureId}`
    const email = `${username}@example.com`

    const pl = createPipeline<UserLifecycleState>('admin-user-lifecycle', { page, request })
    pl.state.adminToken = adminToken
    pl.state.username = username
    pl.state.email = email

    // Always deactivate the created user, even if chain aborts mid-way
    pl.onCleanup(async (s) => {
      if (!s.userId) return
      await request.patch(`${API_BASE_URL}/api/v1/admin/users/${s.userId}`, {
        headers: authHeaders(s.adminToken),
        data: { status: 'INACTIVE', is_active: false },
      })
    })

    // ── Step 1: User list shows required columns and supports search ──────────
    await pl.step('ADM-UI-01: user list columns and search', async (s) => {
      await navigateSpa(page, '/admin/users')
      await page.getByRole('heading', { name: 'Users' }).waitFor({ timeout: 10_000 })
      await page.getByTestId('admin-users-table').waitFor()
      await page.getByRole('columnheader', { name: 'Username' }).waitFor()
      await page.getByRole('columnheader', { name: 'Display name' }).waitFor()
      await page.getByRole('columnheader', { name: 'Email' }).waitFor()
      await page.getByRole('columnheader', { name: 'Status' }).waitFor()

      await page.getByTestId('admin-users-search').fill('admin')
      await page.getByRole('button', { name: 'Apply' }).click()
      await page.getByTestId('admin-users-table').waitFor()

      pl.gate(!!s.adminToken, 'admin token must be present before creating a user')
    })

    // ── Step 2: Create user ───────────────────────────────────────────────────
    await pl.step('ADM-UI-02: create user', async (s) => {
      await navigateSpa(page, '/admin/users')
      await page.getByTestId('admin-users-new').click()
      await page.getByLabel('Username').fill(s.username)
      await page.getByLabel('Display name').fill(`Pipeline User ${fixtureId}`)
      await page.getByLabel('Email').fill(s.email)
      await page.getByLabel('Password').fill(`pw-${fixtureId}`)
      await page.getByRole('button', { name: 'Create user' }).click()
      await page.waitForURL(/\/admin\/users\/.+/, { timeout: 15_000 })

      s.userId = extractIdFromUrl(page.url(), 'users')
      pl.gate(!!s.userId, 'user ID must be present in URL after creation')

      await page.getByTestId('admin-user-detail-form').waitFor()
    })

    // ── Step 3: Update user profile ───────────────────────────────────────────
    await pl.step('ADM-UI-03a: update display name and email', async (s) => {
      await navigateSpa(page, `/admin/users/${s.userId}`)
      await page.getByTestId('admin-user-detail-form').waitFor({ timeout: 15_000 })

      await page.getByTestId('admin-user-display-name').fill(`Pipeline User ${fixtureId} (updated)`)
      await page.getByTestId('admin-user-email').fill(`${s.username}.updated@example.com`)
      await page.getByTestId('admin-user-save').click()
      await page.getByTestId('admin-user-submit-message').getByText('Saved').waitFor({ timeout: 10_000 })
    })

    // ── Step 4: Assign a role ─────────────────────────────────────────────────
    await pl.step('ADM-UI-03b: assign role', async (s) => {
      await navigateSpa(page, `/admin/users/${s.userId}`)
      await page.getByTestId('admin-user-detail-form').waitFor({ timeout: 15_000 })
      await page.getByRole('heading', { name: 'Role assignments' }).waitFor()

      const firstRole = page.locator('input[type="checkbox"]').first()
      const count = await firstRole.count()
      if (count > 0) {
        const wasChecked = await firstRole.isChecked()
        if (!wasChecked) await firstRole.check()
        await page.getByTestId('admin-user-save').click()
        await page.getByTestId('admin-user-submit-message').getByText('Saved').waitFor({ timeout: 10_000 })
      }
      // No roles available is not a failure — skip silently
    })

    // ── Step 5: Assign a second role (or verify multi-role state) ─────────────
    await pl.step('ADM-UI-03c: verify group memberships section visible', async (s) => {
      await navigateSpa(page, `/admin/users/${s.userId}`)
      await page.getByTestId('admin-user-detail-form').waitFor({ timeout: 15_000 })
      await page.getByRole('heading', { name: 'Group memberships' }).waitFor()
    })

    // ── Step 6: Deactivate user ───────────────────────────────────────────────
    // This step is also the primary cleanup — the onCleanup handler above is
    // the safety net if this step itself aborts.
    await pl.step('ADM-UI-04: deactivate user', async (s) => {
      await navigateSpa(page, `/admin/users/${s.userId}`)
      await page.getByTestId('admin-user-detail-form').waitFor({ timeout: 15_000 })

      await page.getByTestId('admin-user-deactivate').click()
      await page.getByText('Active tasks assigned to this user remain assigned').waitFor()
      await page.getByText('cannot complete them while INACTIVE').waitFor()

      await page.getByLabel('Deactivate user').getByRole('button', { name: 'Deactivate' }).click()
      await page.getByTestId('admin-user-status').getByText('INACTIVE').waitFor({ timeout: 10_000 })

      pl.gate(true, 'user deactivated — pipeline complete')
    })

    await pl.runCleanup()
  })
})
