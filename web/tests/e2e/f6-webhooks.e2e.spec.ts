import { expect, test, type APIRequestContext, type Page } from '@playwright/test'
import { randomUUID } from 'crypto'
import * as fs from 'fs'
import * as path from 'path'
import { loginWithToken } from './helpers'

const SCREENSHOTS_DIR = 'tests/screenshots'
const API_BASE_URL = process.env.BPM_TEST_URL ?? 'http://127.0.0.1:8080'
const KEYCLOAK_BASE_URL = process.env.BPM_IDP_BASE_URL ?? 'http://127.0.0.1:8081'
const KEYCLOAK_DISCOVERY_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/.well-known/openid-configuration`
const KEYCLOAK_TOKEN_URL = `${KEYCLOAK_BASE_URL}/realms/bpm-default/protocol/openid-connect/token`
const KEYCLOAK_CLIENT_ID = 'bpm-platform-api'
const API_PREFIX = '/api/v1'
const DLQ_ALERT_THRESHOLD = Number(process.env.VITE_DLQ_ALERT_THRESHOLD ?? '10')

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
  return path.join(dir, `F6-WH-${name}.png`)
}

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: shotPath(name), fullPage: true })
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

async function getKeycloakToken(request: APIRequestContext, username: string, password: string): Promise<string> {
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
    throw new Error(`Failed to fetch token (${response.status()}): ${body}`)
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

type WebhookFixture = {
  id: string
  target_url: string
  event_types: string[]
  status: 'ACTIVE' | 'PAUSED'
  hmac_secret_once?: string
}

type WebhookDeliveryAttemptFixture = {
  delivery_id: string
  subscription_id: string
  event_type: string
  status: 'SUCCESS' | 'FAILED'
  http_status_code: number | null
  attempted_at: string
  attempt_count: number
  max_attempts: number
  last_error?: string | null
}

type WebhookDeliveryFixtureContext = DlqFixtureContext

async function createWebhookFixture(
  request: APIRequestContext,
  token: string,
  overrides?: Partial<{ target_url: string; event_types: string[] }>,
): Promise<WebhookFixture> {
  const targetUrl = overrides?.target_url ?? `https://example.test/webhooks/${randomUUID()}`
  const eventTypes = overrides?.event_types ?? ['task.completed']

  const response = await request.post(`${API_BASE_URL}${API_PREFIX}/webhooks/subscriptions`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      target_url: targetUrl,
      event_types: eventTypes,
      secret: null,
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Webhook fixture create failed (${response.status()}): ${body}`)
  }

  const payload = await response.json() as {
    id?: string
    subscription_id?: string
    target_url?: string
    url?: string
    event_types?: string[]
    status?: 'ACTIVE' | 'PAUSED'
    is_active?: boolean
    hmac_secret_once?: string
  }

  const id = payload.subscription_id ?? payload.id
  if (!id) {
    throw new Error('Webhook fixture create response missing id/subscription_id')
  }

  const resolvedStatus = payload.status ?? (payload.is_active === false ? 'PAUSED' : 'ACTIVE')

  return {
    id,
    target_url: payload.target_url ?? payload.url ?? targetUrl,
    event_types: payload.event_types ?? eventTypes,
    status: resolvedStatus,
    hmac_secret_once: payload.hmac_secret_once,
  }
}

async function updateWebhookStatus(
  request: APIRequestContext,
  token: string,
  webhookId: string,
  status: 'ACTIVE' | 'PAUSED',
): Promise<void> {
  const response = await request.patch(`${API_BASE_URL}${API_PREFIX}/webhooks/subscriptions/${webhookId}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      status,
      is_active: status === 'ACTIVE',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Webhook fixture update failed for ${webhookId} (${response.status()}): ${body}`)
  }
}

async function deleteWebhookFixture(request: APIRequestContext, token: string, webhookId: string): Promise<void> {
  const response = await request.delete(`${API_BASE_URL}${API_PREFIX}/webhooks/subscriptions/${webhookId}`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })

  if (![200, 202, 204, 404].includes(response.status())) {
    const body = await response.text()
    throw new Error(`Webhook fixture delete failed for ${webhookId} (${response.status()}): ${body}`)
  }
}

async function listWebhookDeliveries(
  request: APIRequestContext,
  token: string,
  webhookId: string,
  limit = 20,
): Promise<WebhookDeliveryAttemptFixture[]> {
  const response = await request.get(`${API_BASE_URL}${API_PREFIX}/webhooks/subscriptions/${webhookId}/deliveries`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
    params: {
      limit: String(limit),
    },
  })

  if (response.status() === 404) {
    return []
  }

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Webhook deliveries list failed for ${webhookId} (${response.status()}): ${body}`)
  }

  const payload = await response.json() as { items?: WebhookDeliveryAttemptFixture[] }
  return Array.isArray(payload.items) ? payload.items : []
}

async function waitForWebhookDeliveries(
  request: APIRequestContext,
  token: string,
  webhookId: string,
  predicate: (items: WebhookDeliveryAttemptFixture[]) => boolean,
): Promise<WebhookDeliveryAttemptFixture[]> {
  const deadline = Date.now() + 20_000
  let lastItems: WebhookDeliveryAttemptFixture[] = []

  while (Date.now() < deadline) {
    const items = await listWebhookDeliveries(request, token, webhookId)
    lastItems = items
    if (predicate(items)) return items
    await new Promise((resolve) => setTimeout(resolve, 500))
  }

  throw new Error(`Timed out waiting for webhook deliveries for subscription ${webhookId}; last payload size=${lastItems.length}`)
}

async function createWebhookDeliveryFixture(
  request: APIRequestContext,
  token: string,
  eventType: string,
): Promise<WebhookDeliveryFixtureContext> {
  const tokenPayload = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString('utf-8')) as { sub?: string }
  const assignee = typeof tokenPayload.sub === 'string' && tokenPayload.sub.length > 0 ? tokenPayload.sub : 'admin-user'
  const fixtureId = randomUUID()
  const definitionId = await createDlqFixtureDefinition(request, token, assignee, fixtureId)
  const instanceId = await startFixtureInstance(request, token, definitionId, `f6-wh-delivery-${eventType}-${fixtureId}`)
  const taskId = await waitForTaskId(request, token, instanceId)
  await completeFixtureTask(request, token, taskId)

  return {
    definitionId,
    instanceIds: [instanceId],
    dlqIds: [],
  }
}

async function cleanupWebhookDeliveryFixture(
  request: APIRequestContext,
  token: string,
  fixture: WebhookDeliveryFixtureContext,
): Promise<void> {
  await cleanupDlqFixtures(request, token, fixture)
}

type DlqFixtureContext = {
  definitionId: string
  instanceIds: string[]
  dlqIds: string[]
}

async function createDlqFixtureDefinition(
  request: APIRequestContext,
  token: string,
  assigneeUserId: string,
  fixtureId: string,
): Promise<string> {
  const createResponse = await request.post(`${API_BASE_URL}${API_PREFIX}/definitions`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      name: `F6 DLQ Badge Fixture ${fixtureId}`,
      version: '1.0.0',
      description: 'F6 DLQ depth badge fixture definition generated by E2E setup',
      stage: null,
      graph: {
        nodes: [
          { id: 'start', node_type: 'START', label: 'Start', attributes: null },
          {
            id: 'task-1',
            node_type: 'HUMAN_TASK',
            label: 'Approve payload',
            attributes: JSON.stringify({
              role: 'reviewer',
              assignee_type: 'USER',
              assignee_ref: assigneeUserId,
              form_schema: {
                type: 'object',
                properties: {
                  approved: { type: 'boolean', title: 'Approved' },
                  comment: { type: 'string', title: 'Comment' },
                },
                required: ['approved', 'comment'],
              },
            }),
          },
          {
            id: 'service-1',
            node_type: 'SERVICE_TASK',
            label: 'Failing webhook simulation',
            attributes: JSON.stringify({
              endpoint: 'http://127.0.0.1:65535/fail-fast',
              method: 'POST',
              timeout_ms: 150,
              retry_limit: 0,
            }),
          },
          { id: 'end', node_type: 'END', label: 'End', attributes: null },
        ],
        edges: [
          { id: 'e1', source: 'start', target: 'task-1', condition: null, is_default: false },
          { id: 'e2', source: 'task-1', target: 'service-1', condition: null, is_default: false },
          { id: 'e3', source: 'service-1', target: 'end', condition: null, is_default: false },
        ],
      },
    },
  })

  if (!createResponse.ok()) {
    const body = await createResponse.text()
    throw new Error(`DLQ fixture definition create failed (${createResponse.status()}): ${body}`)
  }

  const created = await createResponse.json() as { id?: string }
  if (!created.id) {
    throw new Error('DLQ fixture definition create response missing id')
  }

  const activateResponse = await request.post(`${API_BASE_URL}${API_PREFIX}/definitions/${created.id}/activate`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })

  if (!activateResponse.ok()) {
    const body = await activateResponse.text()
    throw new Error(`DLQ fixture definition activate failed (${activateResponse.status()}): ${body}`)
  }

  return created.id
}

async function startFixtureInstance(
  request: APIRequestContext,
  token: string,
  definitionId: string,
  correlationKey: string,
): Promise<string> {
  const response = await request.post(`${API_BASE_URL}${API_PREFIX}/instances`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      definition_id: definitionId,
      correlation_key: correlationKey,
      initial_variables: {
        source: 'f6-dlq-badge-e2e',
        fixture_id: correlationKey,
      },
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`DLQ fixture instance start failed (${response.status()}): ${body}`)
  }

  const payload = await response.json() as { instance_id?: string }
  if (!payload.instance_id) throw new Error('DLQ fixture start response missing instance_id')
  return payload.instance_id
}

async function waitForTaskId(
  request: APIRequestContext,
  token: string,
  instanceId: string,
): Promise<string> {
  const deadline = Date.now() + 20_000
  while (Date.now() < deadline) {
    const response = await request.get(`${API_BASE_URL}${API_PREFIX}/tasks`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
      params: {
        instance_id: instanceId,
      },
    })

    if (response.ok()) {
      const payload = await response.json() as { items?: Array<{ id?: string }> }
      const taskId = payload.items?.[0]?.id
      if (taskId) return taskId
    }

    await new Promise((resolve) => setTimeout(resolve, 400))
  }

  throw new Error(`DLQ fixture task did not appear for instance ${instanceId}`)
}

async function completeFixtureTask(
  request: APIRequestContext,
  token: string,
  taskId: string,
): Promise<void> {
  const response = await request.post(`${API_BASE_URL}${API_PREFIX}/tasks/${taskId}/complete`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      output_variables: {
        approved: true,
        comment: 'trigger service task failure for dlq badge fixture',
      },
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`DLQ fixture task completion failed (${response.status()}): ${body}`)
  }
}

async function fetchDlqItems(
  request: APIRequestContext,
  token: string,
): Promise<Array<{ id: string; instance_id?: string | null }>> {
  const response = await request.get(`${API_BASE_URL}/dlq`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
    params: {
      page_size: '50',
    },
  })

  if (!response.ok()) {
    const body = await response.text()
    throw new Error(`Failed to list DLQ items (${response.status()}): ${body}`)
  }

  const payload = await response.json() as { items?: Array<{ id?: string; instance_id?: string | null }> }
  const items = Array.isArray(payload.items) ? payload.items : []
  return items.filter((item): item is { id: string; instance_id?: string | null } => typeof item.id === 'string' && item.id.length > 0)
}

async function createDlqItems(
  request: APIRequestContext,
  token: string,
  count: number,
): Promise<DlqFixtureContext> {
  const tokenPayload = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString('utf-8')) as { sub?: string }
  const assignee = typeof tokenPayload.sub === 'string' && tokenPayload.sub.length > 0 ? tokenPayload.sub : 'admin-user'
  const fixtureId = randomUUID()
  const definitionId = await createDlqFixtureDefinition(request, token, assignee, fixtureId)

  const baseline = await fetchDlqItems(request, token)
  const baselineIds = new Set(baseline.map((item) => item.id))
  const instanceIds: string[] = []

  for (let index = 0; index < count; index += 1) {
    const correlation = `f6-dlq-badge-${fixtureId}-${index}`
    const instanceId = await startFixtureInstance(request, token, definitionId, correlation)
    instanceIds.push(instanceId)
    const taskId = await waitForTaskId(request, token, instanceId)
    await completeFixtureTask(request, token, taskId)
  }

  const needed = new Set(instanceIds)
  const discovered = new Map<string, string>()
  const deadline = Date.now() + 45_000

  while (Date.now() < deadline && discovered.size < needed.size) {
    const items = await fetchDlqItems(request, token)
    for (const item of items) {
      if (baselineIds.has(item.id)) continue
      if (!item.instance_id || !needed.has(item.instance_id)) continue
      if (!discovered.has(item.instance_id)) discovered.set(item.instance_id, item.id)
    }

    if (discovered.size < needed.size) {
      await new Promise((resolve) => setTimeout(resolve, 500))
    }
  }

  if (discovered.size !== needed.size) {
    throw new Error(`DLQ fixture creation incomplete: expected ${needed.size} new entries, found ${discovered.size}`)
  }

  return {
    definitionId,
    instanceIds,
    dlqIds: [...discovered.values()],
  }
}

async function discardDlqItem(request: APIRequestContext, token: string, dlqId: string): Promise<void> {
  const response = await request.post(`${API_BASE_URL}/dlq/${dlqId}/discard`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })

  if (![200, 202, 204, 404].includes(response.status())) {
    const body = await response.text()
    throw new Error(`DLQ discard failed for ${dlqId} (${response.status()}): ${body}`)
  }
}

async function cancelInstance(request: APIRequestContext, token: string, instanceId: string): Promise<void> {
  const response = await request.post(`${API_BASE_URL}${API_PREFIX}/instances/${instanceId}/cancel`, {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    data: {
      reason: 'F6 webhook/DLQ E2E cleanup',
    },
  })

  if (![200, 202, 204, 404].includes(response.status())) {
    const body = await response.text()
    throw new Error(`Instance cancel failed for ${instanceId} (${response.status()}): ${body}`)
  }
}

async function deleteDefinition(request: APIRequestContext, token: string, definitionId: string): Promise<void> {
  const response = await request.delete(`${API_BASE_URL}${API_PREFIX}/definitions/${definitionId}`, {
    headers: {
      Authorization: `Bearer ${token}`,
    },
  })

  if (![200, 202, 204, 404].includes(response.status())) {
    const body = await response.text()
    throw new Error(`Definition delete failed for ${definitionId} (${response.status()}): ${body}`)
  }
}

async function cleanupDlqFixtures(request: APIRequestContext, token: string, fixture: DlqFixtureContext): Promise<void> {
  const cleanupErrors: string[] = []

  for (const dlqId of fixture.dlqIds) {
    try {
      await discardDlqItem(request, token, dlqId)
    } catch (error) {
      cleanupErrors.push(`discard dlq ${dlqId}: ${String(error)}`)
    }
  }

  for (const instanceId of fixture.instanceIds) {
    try {
      await cancelInstance(request, token, instanceId)
    } catch (error) {
      cleanupErrors.push(`cancel instance ${instanceId}: ${String(error)}`)
    }
  }

  try {
    await deleteDefinition(request, token, fixture.definitionId)
  } catch (error) {
    cleanupErrors.push(`delete definition ${fixture.definitionId}: ${String(error)}`)
  }

  if (cleanupErrors.length > 0) {
    throw new Error(`DLQ fixture cleanup failed (${cleanupErrors.join(' | ')})`)
  }
}

function parseRgbChannels(rgbValue: string): [number, number, number] {
  const match = rgbValue.match(/rgb\((\d+),\s*(\d+),\s*(\d+)\)/i)
  if (!match) {
    throw new Error(`Unexpected color format: ${rgbValue}`)
  }

  return [Number(match[1]), Number(match[2]), Number(match[3])]
}

function expectColorClose(actual: string, expected: [number, number, number], tolerance = 8): void {
  const channels = parseRgbChannels(actual)
  for (let i = 0; i < 3; i += 1) {
    const delta = Math.abs(channels[i] - expected[i])
    expect(delta).toBeLessThanOrEqual(tolerance)
  }
}

test.describe('F6 DLQ depth badge (DLQ-UI-05)', () => {
  test('TC-DLQ-UI-05-01: badge shows pending count and warning color when pending items exist', async ({ page, request }) => {
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    const adminToken = await getKeycloakToken(request, creds.username, creds.password)

    const fixture = await createDlqItems(request, adminToken, 1)
    try {
      await loginWithToken(page, adminToken)
      await expect(page.getByRole('link', { name: /DLQ/ })).toBeVisible({ timeout: 10_000 })

      const badge = page.getByLabel(/DLQ pending count/i).first()
      await expect(badge).toBeVisible({ timeout: 20_000 })
      await expect.poll(async () => Number((await badge.innerText()).trim()), { timeout: 20_000 }).toBeGreaterThan(0)

      const badgeColor = await badge.evaluate((el) => window.getComputedStyle(el).backgroundColor)
      const resolvedCount = Number((await badge.innerText()).trim())
      if (resolvedCount > DLQ_ALERT_THRESHOLD) {
        expectColorClose(badgeColor, [239, 68, 68])
      } else {
        expectColorClose(badgeColor, [245, 158, 11])
      }
      await shot(page, 'DLQ-UI-05-warning')
    } finally {
      await cleanupDlqFixtures(request, adminToken, fixture)
    }
  })

  test('TC-DLQ-UI-05-02: badge switches to critical color when count exceeds configured threshold', async ({ page, request }) => {
    await assertServiceReadiness(request)
    const creds = getAdminCredentials()
    const adminToken = await getKeycloakToken(request, creds.username, creds.password)

    const neededCount = Math.max(DLQ_ALERT_THRESHOLD + 1, 2)
    const fixture = await createDlqItems(request, adminToken, neededCount)

    try {
      await loginWithToken(page, adminToken)
      await expect(page.getByRole('link', { name: /DLQ/ })).toBeVisible({ timeout: 10_000 })

      const badge = page.getByLabel(/DLQ pending count/i).first()
      await expect(badge).toBeVisible({ timeout: 20_000 })
      await expect.poll(async () => Number((await badge.innerText()).trim()), { timeout: 25_000 }).toBeGreaterThan(DLQ_ALERT_THRESHOLD)

      const badgeColor = await badge.evaluate((el) => window.getComputedStyle(el).backgroundColor)
      expectColorClose(badgeColor, [239, 68, 68])
      await shot(page, 'DLQ-UI-05-critical')
    } finally {
      await cleanupDlqFixtures(request, adminToken, fixture)
    }
  })
})

test.describe('F6 webhooks UI (WH-UI-01..03)', () => {
  let adminToken = ''
  let createdWebhookIds: string[] = []
  let deliveryFixtures: WebhookDeliveryFixtureContext[] = []

  test.beforeEach(async ({ request }) => {
    await assertServiceReadiness(request)
    createdWebhookIds = []
    deliveryFixtures = []
    const creds = getAdminCredentials()
    adminToken = await getKeycloakToken(request, creds.username, creds.password)
  })

  test.afterEach(async ({ request }) => {
    const cleanupErrors: string[] = []
    for (const webhookId of createdWebhookIds) {
      try {
        await deleteWebhookFixture(request, adminToken, webhookId)
      } catch (error) {
        cleanupErrors.push(`delete webhook ${webhookId}: ${String(error)}`)
      }
    }

    for (const fixture of deliveryFixtures) {
      try {
        await cleanupWebhookDeliveryFixture(request, adminToken, fixture)
      } catch (error) {
        cleanupErrors.push(String(error))
      }
    }

    createdWebhookIds = []
    deliveryFixtures = []
    if (cleanupErrors.length > 0) {
      throw new Error(`Webhook fixture cleanup failed (${cleanupErrors.join(' | ')})`)
    }
  })

  test('TC-WH-UI-01-01: webhook page renders required subscription table columns and fixture rows', async ({ page, request }) => {
    const activeFixture = await createWebhookFixture(request, adminToken, {
      event_types: ['task.completed', 'instance.started'],
    })
    createdWebhookIds.push(activeFixture.id)

    const pausedFixture = await createWebhookFixture(request, adminToken, {
      event_types: ['instance.completed'],
    })
    createdWebhookIds.push(pausedFixture.id)
    await updateWebhookStatus(request, adminToken, pausedFixture.id, 'PAUSED')

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    await expect(page.getByRole('heading', { name: 'Webhook Subscriptions' })).toBeVisible({ timeout: 10_000 })
    await expect(page.getByRole('columnheader', { name: 'Target URL' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Event types' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Status' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Created' })).toBeVisible()
    await expect(page.getByRole('columnheader', { name: 'Actions' })).toBeVisible()

    await expect(page.getByText(activeFixture.target_url)).toBeVisible({ timeout: 15_000 })
    await expect(page.getByText(pausedFixture.target_url)).toBeVisible({ timeout: 15_000 })
    const activeRow = page.locator('tr', { hasText: activeFixture.target_url })
    const pausedRow = page.locator('tr', { hasText: pausedFixture.target_url })
    await expect(activeRow.getByText('task.completed, instance.started')).toBeVisible({ timeout: 15_000 })
    await expect(pausedRow.getByText('instance.completed')).toBeVisible({ timeout: 15_000 })
    await expect(activeRow.getByText('ACTIVE')).toBeVisible()
    await expect(pausedRow.getByText('PAUSED')).toBeVisible()

    await shot(page, 'WH-UI-01-list')
  })

  test('TC-WH-UI-02-02: create form rejects invalid URL and missing event selection', async ({ page }) => {
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    await page.getByRole('button', { name: '+ New Subscription' }).click()
    await expect(page.getByRole('heading', { name: 'Create subscription' })).toBeVisible({ timeout: 10_000 })

    await page.getByRole('button', { name: 'Save' }).click()
    await expect(page.getByText('Target URL and at least one event type are required.')).toBeVisible()

    await page.getByPlaceholder('https://example.com/webhooks/bpm').fill('not-a-valid-url')
    await page.getByLabel('Task completed').check()
    await page.getByRole('button', { name: 'Save' }).click()
    await expect(page.getByText('Target URL is invalid.')).toBeVisible()
    await shot(page, 'WH-UI-02-validation')
  })

  test('TC-WH-UI-02-01: create form creates subscription with one-time secret panel', async ({ page }) => {
    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    await page.getByRole('button', { name: '+ New Subscription' }).click()
    await expect(page.getByRole('heading', { name: 'Create subscription' })).toBeVisible({ timeout: 10_000 })

    const newTargetUrl = `https://example.test/webhooks/${randomUUID()}`
    await page.getByPlaceholder('https://example.com/webhooks/bpm').fill(newTargetUrl)
    await page.getByLabel('Task completed').check()
    await page.getByLabel('Instance started').check()
    await page.getByRole('button', { name: 'Save' }).click()

    const secretPanel = page.getByTestId('webhook-secret-once-panel')
    await expect(secretPanel).toBeVisible({ timeout: 10_000 })
    await expect(secretPanel.getByText('One-time HMAC secret')).toBeVisible()
    await expect(secretPanel.getByRole('button', { name: 'Copy and dismiss' })).toBeVisible()
    await expect(secretPanel.getByRole('button', { name: 'Dismiss', exact: true })).toBeVisible()
    const renderedSecret = (await secretPanel.locator('code').innerText()).trim()
    expect(renderedSecret.length).toBeGreaterThan(0)

    const createdRow = page.locator('tr', { hasText: newTargetUrl })
    await expect(createdRow).toBeVisible({ timeout: 10_000 })
    await expect(createdRow.getByText('task.completed, instance.started')).toBeVisible()

    await secretPanel.getByRole('button', { name: 'Dismiss', exact: true }).click()
    await expect(secretPanel).toBeHidden({ timeout: 10_000 })

    // Query API once to locate the created row id for deterministic cleanup.
    const listResponse = await page.request.get(`${API_BASE_URL}${API_PREFIX}/webhooks/subscriptions`, {
      headers: {
        Authorization: `Bearer ${adminToken}`,
      },
      params: {
        search: newTargetUrl,
      },
    })
    expect(listResponse.ok()).toBeTruthy()
    const listPayload = await listResponse.json() as { items?: Array<{ id?: string; subscription_id?: string; target_url?: string; url?: string }> } | Array<{ id?: string; subscription_id?: string; target_url?: string; url?: string }>
    const items = Array.isArray(listPayload) ? listPayload : (listPayload.items ?? [])
    const created = items.find((row) => {
      const target = row.target_url ?? row.url
      return target === newTargetUrl
    })
    const createdId = created?.subscription_id ?? created?.id
    expect(createdId).toBeTruthy()
    if (createdId) createdWebhookIds.push(createdId)

    await shot(page, 'WH-UI-02-created-secret')
  })

  test('TC-WH-UI-03-01: paused subscription row is visually distinct and resumes with one click', async ({ page, request }) => {
    const pausedFixture = await createWebhookFixture(request, adminToken, {
      event_types: ['instance.errored'],
    })
    createdWebhookIds.push(pausedFixture.id)
    await updateWebhookStatus(request, adminToken, pausedFixture.id, 'PAUSED')

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    const row = page.locator('tr', { hasText: pausedFixture.target_url })
    await expect(row).toBeVisible({ timeout: 15_000 })
    await expect(row.getByText('PAUSED')).toBeVisible()

    const rowColor = await row.evaluate((el) => window.getComputedStyle(el).backgroundColor)
    expectColorClose(rowColor, [255, 247, 237])

    await row.getByRole('button', { name: 'Resume' }).click()
    await expect(row.getByText('ACTIVE')).toBeVisible({ timeout: 10_000 })
    await expect(row.getByRole('button', { name: 'Pause' })).toBeVisible({ timeout: 10_000 })
    await shot(page, 'WH-UI-03-resume')
  })

  test('TC-WH-UI-03-02: active subscription can be paused and exposes resume action', async ({ page, request }) => {
    const activeFixture = await createWebhookFixture(request, adminToken, {
      event_types: ['instance.completed'],
    })
    createdWebhookIds.push(activeFixture.id)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    const row = page.locator('tr', { hasText: activeFixture.target_url })
    await expect(row).toBeVisible({ timeout: 15_000 })
    await expect(row.getByText('ACTIVE')).toBeVisible()

    await row.getByRole('button', { name: 'Pause' }).click()
    await expect(row.getByText('PAUSED')).toBeVisible({ timeout: 10_000 })
    await expect(row.getByRole('button', { name: 'Resume' })).toBeVisible({ timeout: 10_000 })
    await shot(page, 'WH-UI-03-pause')
  })

  test('TC-WH-UI-04-01: subscription detail shows summary and delivery columns for a recent failed attempt', async ({ page, request }) => {
    const webhook = await createWebhookFixture(request, adminToken, {
      target_url: 'http://127.0.0.1:65535/f6-wh-ui-04-summary',
      event_types: ['task.completed'],
    })
    createdWebhookIds.push(webhook.id)

    const deliveryFixture = await createWebhookDeliveryFixture(request, adminToken, 'task.completed')
    deliveryFixtures.push(deliveryFixture)
    const deliveries = await waitForWebhookDeliveries(request, adminToken, webhook.id, (items) => items.length > 0)
    expect(deliveries[0]?.event_type).toBe('task.completed')

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    const row = page.locator('tr', { hasText: webhook.target_url })
    await expect(row).toBeVisible({ timeout: 15_000 })
    await row.getByRole('button', { name: 'View details' }).click()

    const panel = page.getByTestId('webhook-subscription-detail-panel')
    await expect(panel).toBeVisible({ timeout: 10_000 })
    await expect(panel.getByTestId('webhook-subscription-summary')).toContainText(webhook.target_url)
    await expect(panel.getByRole('columnheader', { name: 'Status' })).toBeVisible()
    await expect(panel.getByRole('columnheader', { name: 'HTTP code' })).toBeVisible()
    await expect(panel.getByRole('columnheader', { name: 'Timestamp' })).toBeVisible()
    await expect(panel.getByRole('columnheader', { name: 'Event type' })).toBeVisible()
    await expect(panel.getByRole('columnheader', { name: 'Attempt' })).toBeVisible()
    await expect(panel.getByTestId('webhook-delivery-attempts-table').getByText('task.completed')).toBeVisible()
    await expect(panel.getByText(/^FAILED$/)).toBeVisible()
    await shot(page, 'WH-UI-04-detail-table')
  })

  test('TC-WH-UI-04-02: failed delivery rows are visually highlighted and preserve missing response codes', async ({ page, request }) => {
    const webhook = await createWebhookFixture(request, adminToken, {
      target_url: 'http://127.0.0.1:65535/f6-wh-ui-04-failure',
      event_types: ['task.completed'],
    })
    createdWebhookIds.push(webhook.id)

    const deliveryFixture = await createWebhookDeliveryFixture(request, adminToken, 'task.completed')
    deliveryFixtures.push(deliveryFixture)
    await waitForWebhookDeliveries(
      request,
      adminToken,
      webhook.id,
      (items) => items.some((item) => item.status === 'FAILED' && item.http_status_code === null),
    )

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    const row = page.locator('tr', { hasText: webhook.target_url })
    await expect(row).toBeVisible({ timeout: 15_000 })
    await row.getByRole('button', { name: 'View details' }).click()

    const failedRow = page.getByTestId('webhook-delivery-row-failed').first()
    await expect(failedRow).toBeVisible({ timeout: 10_000 })
    await expect(failedRow.getByText('—')).toBeVisible()
    const rowColor = await failedRow.evaluate((el) => window.getComputedStyle(el).backgroundColor)
    expectColorClose(rowColor, [254, 242, 242])
    await shot(page, 'WH-UI-04-failed-highlight')
  })

  test('TC-WH-UI-04-03: detail panel shows empty-state copy when no delivery attempts exist yet', async ({ page, request }) => {
    const webhook = await createWebhookFixture(request, adminToken, {
      target_url: `https://example.test/webhooks/${randomUUID()}`,
      event_types: ['task.completed'],
    })
    createdWebhookIds.push(webhook.id)

    await loginWithToken(page, adminToken)
    await navigateSpa(page, '/webhooks')

    const row = page.locator('tr', { hasText: webhook.target_url })
    await expect(row).toBeVisible({ timeout: 15_000 })
    await row.getByRole('button', { name: 'View details' }).click()

    const emptyState = page.getByTestId('webhook-delivery-empty')
    await expect(emptyState).toBeVisible({ timeout: 10_000 })
    await expect(emptyState).toContainText('No delivery attempts recorded yet.')
    await shot(page, 'WH-UI-04-empty')
  })
})
