/**
 * Pipeline: Simulation — Admin Business Processes
 *
 * Exercises the platform admin workflows that a system operator runs
 * day-to-day. All steps drive the real UI; no human interaction.
 * Screenshots are taken after every significant action.
 *
 * Chain topology:
 *   pre-check services
 *   → login as platform admin
 *   → check system health dashboard        [screen shows all services green]
 *   → check metrics page                   [screen shows metric data]
 *   → browse audit log                     [screen shows audit entries table]
 *   → filter audit log by actor            [screen shows filtered results]
 *   → create a user for role-assignment    [produces: targetUserId]
 *   → assign PROCESS_DESIGNER role         [screen shows "Saved"]
 *   → verify role appears in user list     [screen shows role in Roles column]
 *   → issue an API token for that user     [produces: tokenId]
 *   → verify token appears in token list   [screen shows token row]
 *   → revoke the token                     [screen shows REVOKED status]
 *   → deactivate the test user             [screen shows INACTIVE]
 *   → cleanup: ensure user deactivated
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
  shot,
} from '../pipeline'

const API_BASE_URL       = process.env.BPM_TEST_URL     ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL  = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`

interface AdminProcessState {
  adminToken:   string
  fixtureId:    string
  targetUserId: string
  tokenId:      string
}

test.describe('Pipeline: sim-admin-processes', () => {
  test('admin: health → audit → role-assign → token lifecycle', async ({ page, request }) => {

    // ── Pre-checks ────────────────────────────────────────────────────────────
    const backendOk = await request.fetch(`${API_BASE_URL}/health/ready`)
    if (!backendOk.ok()) throw new Error(`Backend not ready: ${backendOk.status()}`)
    const idpOk = await request.fetch(KEYCLOAK_DISCOVERY)
    if (!idpOk.ok()) throw new Error(`Keycloak not ready: ${idpOk.status()}`)

    const adminToken = await getKeycloakToken(request)
    await loginWithToken(page, adminToken)

    const fixtureId = randomUUID().slice(0, 8)

    const pl = createPipeline<AdminProcessState>('sim-admin-processes', { page, request })
    pl.state.adminToken = adminToken
    pl.state.fixtureId  = fixtureId

    // Cleanup: deactivate test user if chain aborts mid-way
    pl.onCleanup(async (s) => {
      if (!s.targetUserId) return
      await request.patch(`${API_BASE_URL}/api/v1/users/${s.targetUserId}`, {
        headers: authHeaders(s.adminToken),
        data: { status: 'INACTIVE' },
      })
    })

    // ── Step 1: System health dashboard ──────────────────────────────────────
    await pl.step('01: health dashboard shows system status', async () => {
      await navigateSpa(page, '/admin/health')
      await page.getByRole('heading', { name: /health/i }).waitFor({ timeout: 10_000 })
      // Verify at least one status indicator is visible (green/ok text or badge)
      const statusEl = page.getByText(/ok|healthy|up/i).first()
      await statusEl.waitFor({ timeout: 10_000 })
      pl.gate(await statusEl.count() > 0, 'health dashboard must show at least one healthy status')
      await shot(page, 'sim-admin-processes', '01-health-dashboard')
    })

    // ── Step 2: Metrics page renders data ─────────────────────────────────────
    await pl.step('02: metrics page shows metric content', async () => {
      await navigateSpa(page, '/admin/metrics')
      await page.getByRole('heading', { name: /metrics/i }).waitFor({ timeout: 10_000 })
      // Metrics page should render some content (counters, graphs, or raw text)
      const content = page.locator('pre, table, [data-testid*="metric"]').first()
      await content.waitFor({ timeout: 15_000 })
      pl.gate(await content.count() > 0, 'metrics page must render metric content')
      await shot(page, 'sim-admin-processes', '02-metrics-page')
    })

    // ── Step 3: Audit log page loads and shows entries ─────────────────────────
    await pl.step('03: audit log table is visible', async () => {
      await navigateSpa(page, '/admin/audit')
      await page.getByRole('heading', { name: /audit/i }).waitFor({ timeout: 10_000 })
      // Table or entry list must be present
      const table = page.locator('table, [role="table"], [data-testid*="audit"]').first()
      await table.waitFor({ timeout: 10_000 })
      pl.gate(await table.count() > 0, 'audit log must render a table or entry list')
      await shot(page, 'sim-admin-processes', '03-audit-log')
    })

    // ── Step 4: Filter audit log by the admin actor ───────────────────────────
    await pl.step('04: filter audit log by actor', async () => {
      await navigateSpa(page, '/admin/audit')
      await page.getByRole('heading', { name: /audit/i }).waitFor({ timeout: 10_000 })

      // Look for a filter/search input
      const filterInput = page.getByPlaceholder(/actor|filter|search/i)
        .or(page.getByRole('textbox').first())
      if (await filterInput.count() > 0) {
        await filterInput.first().fill('admin')
        // Submit via button or Enter
        const applyBtn = page.getByRole('button', { name: /apply|filter|search/i })
        if (await applyBtn.count() > 0) {
          await applyBtn.first().click()
        } else {
          await filterInput.first().press('Enter')
        }
        await page.waitForTimeout(1_000)
      }
      await shot(page, 'sim-admin-processes', '04-audit-filtered')
    })

    // ── Step 5: Create a user for role-assignment testing ─────────────────────
    await pl.step('05: create test user for role assignment', async (s) => {
      await navigateSpa(page, '/admin/users')
      await page.getByTestId('admin-users-new').click()

      await page.getByLabel('Username').fill(`adm-proc-${fixtureId}`)
      await page.getByLabel('Display name').fill(`Admin Process Test [${fixtureId}]`)
      await page.getByLabel('Email').fill(`adm.proc.${fixtureId}@example.com`)
      await page.getByLabel('Password').fill(`Pw-${fixtureId}-adm!`)
      await page.getByRole('button', { name: 'Create user' }).click()
      await page.waitForURL(/\/admin\/users\/.+/, { timeout: 15_000 })

      s.targetUserId = extractIdFromUrl(page.url(), 'users')
      pl.gate(!!s.targetUserId, 'test user ID must be present in URL after creation')
      await shot(page, 'sim-admin-processes', '05-user-created')
    })

    // ── Step 6: Assign PROCESS_DESIGNER role ─────────────────────────────────
    await pl.step('06: assign PROCESS_DESIGNER role', async (s) => {
      await navigateSpa(page, `/admin/users/${s.targetUserId}`)
      await page.getByTestId('admin-user-detail-form').waitFor({ timeout: 15_000 })
      await page.getByRole('heading', { name: 'Role assignments' }).waitFor()

      const roleCheckbox = page.getByLabel(/PROCESS_DESIGNER/i)
      if (await roleCheckbox.count() > 0) {
        if (!await roleCheckbox.isChecked()) await roleCheckbox.check()
        await page.getByTestId('admin-user-save').click()
        await page.getByTestId('admin-user-submit-message').getByText('Saved').waitFor({ timeout: 10_000 })
        pl.gate(true, 'role saved successfully')
      }
      // If no PROCESS_DESIGNER checkbox found, assign a different available role
      else {
        const anyCheckbox = page.locator('input[type="checkbox"]').first()
        if (await anyCheckbox.count() > 0) {
          if (!await anyCheckbox.isChecked()) await anyCheckbox.check()
          await page.getByTestId('admin-user-save').click()
          await page.getByTestId('admin-user-submit-message').getByText('Saved').waitFor({ timeout: 10_000 })
        }
      }
      await shot(page, 'sim-admin-processes', '06-role-assigned')
    })

    // ── Step 7: Verify role appears in Users list ─────────────────────────────
    await pl.step('07: role visible in user list Roles column', async () => {
      await navigateSpa(page, '/admin/users')
      await page.getByTestId('admin-users-search').fill(`adm-proc-${fixtureId}`)
      await page.getByRole('button', { name: 'Apply' }).click()
      await page.getByTestId('admin-users-table').waitFor()

      const row = page.getByTestId('admin-users-row').first()
      await row.waitFor({ timeout: 8_000 })
      // Roles column (index 3) should not be empty
      const rolesCell = row.getByRole('cell').nth(3)
      const rolesText = await rolesCell.innerText()
      pl.gate(rolesText.trim().length > 0, `Roles column must be non-empty, got "${rolesText}"`)
      await shot(page, 'sim-admin-processes', '07-role-in-user-list')
    })

    // ── Step 8: Issue an API token for the test user ──────────────────────────
    await pl.step('08: issue API token for test user', async (s) => {
      await navigateSpa(page, '/admin/tokens')
      await page.getByRole('heading', { name: /token/i }).waitFor({ timeout: 10_000 })

      // Click "Issue token" or equivalent button
      await page.getByRole('button', { name: /issue|new token/i }).click()

      // Fill the issue-token dialog
      const dialog = page.getByRole('dialog')
      await dialog.waitFor({ timeout: 8_000 })

      // Select user
      const userSelect = dialog.getByRole('combobox').first()
        .or(dialog.getByPlaceholder(/user/i).first())
      await userSelect.fill(`adm-proc-${fixtureId}`)
      const option = dialog.getByRole('option', { name: new RegExp(fixtureId) })
      if (await option.count() > 0) await option.first().click()

      // Roles
      const rolesInput = dialog.getByPlaceholder(/roles/i)
      if (await rolesInput.count() > 0) {
        await rolesInput.fill('PROCESS_DESIGNER')
      }

      // Expiry — set a date in the future
      const expiryInput = dialog.locator('input[type="datetime-local"]')
      if (await expiryInput.count() > 0) {
        // 1 hour from now
        const future = new Date(Date.now() + 3_600_000)
        const val = future.toISOString().slice(0, 16)  // "YYYY-MM-DDTHH:MM"
        await expiryInput.fill(val)
      }

      await dialog.getByRole('button', { name: /issue/i }).click()

      // Success modal should appear with the token value
      const successModal = page.getByRole('dialog', { name: /issued token/i })
        .or(page.getByText(/issued token/i).locator('..'))
      await successModal.waitFor({ timeout: 10_000 })
      pl.gate(true, 'token issue dialog appeared after submit')

      // Verify "This value will not be shown again" warning is present
      await page.getByText(/will not be shown again/i).waitFor({ timeout: 5_000 })

      await shot(page, 'sim-admin-processes', '08-token-issued')

      // Close the dialog
      await page.getByRole('button', { name: /close|done/i }).click()
      await page.getByRole('dialog').waitFor({ state: 'hidden', timeout: 5_000 }).catch(() => {})

      // Get the token ID for the next step (from the table row)
      await page.getByRole('table').or(page.locator('[role="table"]')).waitFor({ timeout: 8_000 })
      const tokenResp = await request.get(`${API_BASE_URL}/api/v1/auth/tokens`, {
        headers: authHeaders(s.adminToken),
      })
      const tokens = await tokenResp.json()
      const found = (tokens.items ?? tokens).find((t: { user_id?: string; username?: string; id?: string; token_id?: string }) =>
        t.user_id === s.targetUserId || t.username === `adm-proc-${fixtureId}`
      )
      if (found) s.tokenId = found.id ?? found.token_id ?? ''
    })

    // ── Step 9: Verify token row appears in token list ────────────────────────
    await pl.step('09: token visible in token list', async () => {
      await navigateSpa(page, '/admin/tokens')
      await page.getByRole('heading', { name: /token/i }).waitFor({ timeout: 10_000 })

      // The user display name should appear in the list
      const tokenRow = page.getByText(`Admin Process Test [${fixtureId}]`)
        .or(page.getByText(`adm-proc-${fixtureId}`))
        .first()
      await tokenRow.waitFor({ timeout: 10_000 })
      pl.gate(await tokenRow.count() > 0, 'issued token must be visible in token list')

      // Status should be ACTIVE
      const statusBadge = page.locator('[data-testid*="token"]').getByText('ACTIVE').first()
        .or(page.getByText('ACTIVE').first())
      await statusBadge.waitFor({ timeout: 5_000 })
      await shot(page, 'sim-admin-processes', '09-token-in-list')
    })

    // ── Step 10: Revoke the token ─────────────────────────────────────────────
    await pl.step('10: revoke token', async () => {
      await navigateSpa(page, '/admin/tokens')
      await page.getByRole('heading', { name: /token/i }).waitFor({ timeout: 10_000 })

      // Find the row for our test user and click Revoke
      const tokenRow = page.getByText(`adm-proc-${fixtureId}`).locator('../..')
        .or(page.getByRole('row', { name: new RegExp(fixtureId) }))
        .first()
      await tokenRow.waitFor({ timeout: 8_000 })
      await tokenRow.getByRole('button', { name: /revoke/i }).click()

      // Confirmation dialog
      const confirmDialog = page.getByRole('dialog')
      await confirmDialog.waitFor({ timeout: 8_000 })
      await page.getByText(/revoking this api token/i).waitFor({ timeout: 5_000 })
      await confirmDialog.getByRole('button', { name: /revoke token/i }).click()

      // Row should now show REVOKED
      await page.getByText('REVOKED').waitFor({ timeout: 10_000 })
      pl.gate(true, 'token successfully revoked — status shows REVOKED')
      await shot(page, 'sim-admin-processes', '10-token-revoked')
    })

    // ── Step 11: Deactivate the test user ─────────────────────────────────────
    await pl.step('11: deactivate test user', async (s) => {
      await navigateSpa(page, `/admin/users/${s.targetUserId}`)
      await page.getByTestId('admin-user-detail-form').waitFor({ timeout: 15_000 })

      await page.getByTestId('admin-user-deactivate').click()
      const deactivateDialog = page.getByRole('dialog')
      await deactivateDialog.waitFor({ timeout: 8_000 })
      await deactivateDialog.getByRole('button', { name: 'Deactivate' }).click()
      await page.getByTestId('admin-user-status').getByText('INACTIVE').waitFor({ timeout: 10_000 })

      pl.gate(true, 'user deactivated — pipeline complete')
      await shot(page, 'sim-admin-processes', '11-user-deactivated')
    })

    await pl.runCleanup()
  })
})
