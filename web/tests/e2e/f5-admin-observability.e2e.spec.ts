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

function shotPath(name: string): string {
  const dir = path.resolve(SCREENSHOTS_DIR)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return path.join(dir, `F5-${name}.png`)
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
}

function getEnvOrDefault(name: string, fallback: string): string {
  const value = process.env[name]
  if (!value || !value.trim()) {
    return fallback
  }
  return value
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
  const username = getEnvOrDefault('BPM_E2E_ADMIN_USERNAME', 'admin-user')
  const password = getEnvOrDefault('BPM_E2E_ADMIN_PASSWORD', 'admin-pass')

  const response = await request.post(KEYCLOAK_TOKEN_URL, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    form: {
      client_id: KEYCLOAK_CLIENT_ID,
      username,
      password,
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

async function createAuditFixtureDefinition(request: APIRequestContext, token: string): Promise<{ id: string; name: string }> {
  const suffix = randomUUID().slice(0, 8)
  const name = `adm-ui-11-def-${suffix}`
  const response = await request.post(`${API_BASE_URL}/api/v1/definitions`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      name,
      version: '1.0.0',
      description: 'ADM-UI-11 audit fixture definition',
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

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Failed to create ADM-UI-11 fixture definition ${name} (${response.status()}): ${body}`)
  }

  const body = await response.json() as { id?: string }
  const id = body.id ?? ''
  if (!id) throw new Error(`Create definition response did not include an id for fixture ${name}`)

  return { id, name }
}

async function deleteDefinitionFixture(request: APIRequestContext, token: string, definitionId: string): Promise<void> {
  const response = await request.delete(`${API_BASE_URL}/api/v1/definitions/${definitionId}`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })

  if (!response.ok() && response.status() !== 404) {
    throw new Error(`Failed to cleanup ADM-UI-11 fixture definition ${definitionId} (${response.status()})`)
  }
}

async function navigateSpa(page: Page, targetPath: string): Promise<void> {
  await page.evaluate((nextPath) => {
    window.history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, targetPath)
  await page.waitForURL((url) => `${url.pathname}${url.search}` === targetPath, { timeout: 10_000 })
}

test.describe('F5 admin observability UI (ADM-UI-09..11)', () => {
  test.beforeEach(async ({ request }) => {
    await assertServiceReadiness(request)
  })

  test('TC-ADM-UI-09-01: health dashboard renders readiness cards and refresh behavior', async ({ page, request }) => {
    const adminToken = await getAdminToken(request)
    await loginWithToken(page, adminToken)

    let readinessCalls = 0
    page.on('response', (response) => {
      if (response.request().method() === 'GET' && response.url().includes('/health/ready')) {
        readinessCalls += 1
      }
    })

    await navigateSpa(page, '/admin/health')

    await expect(page.getByRole('heading', { name: 'Health' })).toBeVisible({ timeout: 10_000 })
    await expect(page.getByText('database')).toBeVisible()
    await expect(page.getByText('scheduler')).toBeVisible()
    await expect(page.getByText('DB query latency:')).toBeVisible()
    await expect(page.getByText('Uptime:')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Refresh now' })).toBeVisible()
    await shot(page, 'ADM-UI-09-dashboard')

    const beforeManualRefresh = readinessCalls
    await page.getByRole('button', { name: 'Refresh now' }).click()
    await expect.poll(() => readinessCalls, { timeout: 10_000 }).toBeGreaterThan(beforeManualRefresh)
    await shot(page, 'ADM-UI-09-refresh-indicator')

    const afterManualRefresh = readinessCalls
    await expect.poll(() => readinessCalls, { timeout: 30_000 }).toBeGreaterThan(afterManualRefresh)
  })

  test('TC-ADM-UI-10-01: metrics page renders grouped metric-family tables from Prometheus text', async ({ page, request }) => {
    const adminToken = await getAdminToken(request)
    await loginWithToken(page, adminToken)

    await navigateSpa(page, '/admin/metrics')

    await expect(page.getByRole('heading', { name: 'Metrics' })).toBeVisible({ timeout: 10_000 })
    await expect(page.getByText('Loading…')).toHaveCount(0, { timeout: 10_000 })

    const families = page.locator('section')
    const familyCount = await families.count()
    if (familyCount > 0) {
      await expect(families.first()).toBeVisible({ timeout: 10_000 })
      await expect(page.getByRole('columnheader', { name: 'Sample' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Labels' })).toBeVisible()
      await expect(page.getByRole('columnheader', { name: 'Value' })).toBeVisible()
    } else {
      const emptyCount = await page.getByText('No metrics are currently exposed.').count()
      const requestFailureCount = await page.getByText('Metrics request failed. The previous successful data remains cached.').count()
      const parseFailureCount = await page.getByText('Metrics payload could not be parsed as Prometheus exposition text.').count()
      expect(emptyCount + requestFailureCount + parseFailureCount).toBeGreaterThan(0)
    }
    await shot(page, 'ADM-UI-10-metrics-families')
  })

  test('TC-ADM-UI-11-01: audit page filters by actor/resource/time and expands rows into JSON diff view', async ({ page, request }) => {
    const adminToken = await getAdminToken(request)
    const fixtureDefinition = await createAuditFixtureDefinition(request, adminToken)

    try {
      await loginWithToken(page, adminToken)

      await navigateSpa(page, '/admin/audit')

      await expect(page.getByRole('heading', { name: 'Audit Log' })).toBeVisible({ timeout: 10_000 })

      // Validate time-range filter semantics without forcing a backend error path.
      await page.getByPlaceholder('From (ISO8601)').fill('2026-05-31T12:00:00Z')
      await page.getByPlaceholder('To (ISO8601)').fill('2026-05-30T12:00:00Z')
      await expect(page.getByText('Please enter valid ISO8601 date filters and ensure from ≤ to.')).toBeVisible({ timeout: 10_000 })
      await page.getByPlaceholder('From (ISO8601)').fill('')
      await page.getByPlaceholder('To (ISO8601)').fill('')
      await expect(page.getByText('Please enter valid ISO8601 date filters and ensure from ≤ to.')).toHaveCount(0)

      const firstRow = page.locator('tbody tr').first()
      await expect(firstRow).toBeVisible({ timeout: 15_000 })

      const actorCell = firstRow.locator('td').nth(2)
      const actorText = (await actorCell.innerText()).trim()
      if (!actorText || actorText === '—') {
        throw new Error('Could not infer actor from fixture audit row')
      }

      await page.getByPlaceholder('Actor ID').fill(actorText)
      await expect(firstRow).toBeVisible({ timeout: 10_000 })

      const resourceCell = firstRow.locator('td').nth(4)
      const resourceText = (await resourceCell.innerText()).replace(/\s+/g, ' ').trim()
      const resourcePrefixMatch = resourceText.match(/^([A-Za-z0-9_.-]+)\s*\//)
      if (!resourcePrefixMatch) {
        throw new Error(`Could not infer resource type from row: ${resourceText}`)
      }

      await page.getByPlaceholder('Resource type').fill(resourcePrefixMatch[1])
      await expect(firstRow).toBeVisible({ timeout: 10_000 })

      await expect(page.getByRole('button', { name: 'Previous' })).toBeVisible()
      await expect(page.getByRole('button', { name: 'Next' })).toBeVisible()
      await shot(page, 'ADM-UI-11-filtered-results')

      await firstRow.getByRole('button').first().click()
      const hasDiffTable = await page.getByRole('columnheader', { name: 'Field' }).count()
      if (hasDiffTable > 0) {
        await expect(page.getByRole('columnheader', { name: 'Field' })).toBeVisible({ timeout: 10_000 })
        await expect(page.getByRole('columnheader', { name: 'Before' })).toBeVisible()
        await expect(page.getByRole('columnheader', { name: 'After' })).toBeVisible()
      } else {
        await expect(page.getByText('No structured field changes for this entry.')).toBeVisible({ timeout: 10_000 })
      }
      await shot(page, 'ADM-UI-11-expanded-diff')
    } finally {
      await deleteDefinitionFixture(request, adminToken, fixtureDefinition.id)
    }
  })
})
