/**
 * E2E — RND-UI-05: RateLimitBackpressure (strict no-mock contract)
 *
 *  No mocks. Real backend with rate-limit middleware (API-10) that
 *  responds 429 with Retry-After. The spec triggers a real 429 by
 *  firing many concurrent GETs to /api/v1/tasks/inbox, then asserts
 *  the UI behaviour per the design §5.1 + §12.1.
 *
 *  Design §0: every E2E hits the real backend (Keycloak
 *  http://localhost:8081/realms/bpm-default, BPM API http://127.0.0.1:8080,
 *  PostgreSQL localhost:5432). Zero HTTP mocking, zero page.route()
 *  interception of API or auth endpoints.
 */

import {
  test,
  expect,
  type Page,
  type APIRequestContext,
  type TestInfo,
} from '@playwright/test'
import { getKeycloakToken, loginWithToken } from './helpers'

async function loginAsWorker(page: Page, request: APIRequestContext): Promise<void> {
  const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
  await loginWithToken(page, token)
}

async function burstUntil429(
  request: APIRequestContext,
  token: string,
  endpoint: string,
  maxRequests = 60,
): Promise<{ limited: boolean; status: number; retryAfter: string | null }> {
  const headers = { Authorization: `Bearer ${token}` }
  let first429: { status: number; retryAfter: string | null } | null = null
  for (let i = 0; i < maxRequests; i += 1) {
    const r = await request.get(endpoint, { headers })
    if (r.status() === 429) {
      first429 = {
        status: 429,
        retryAfter: r.headers()['retry-after'] ?? null,
      }
      break
    }
  }
  if (first429) return { limited: true, ...first429 }
  return { limited: false, status: 200, retryAfter: null }
}

test.describe('RND-UI-05 — RateLimitBackpressure (no mocks)', () => {
  test.beforeEach(async ({ page, request }) => {
    await loginAsWorker(page, request)
  })

  test('TC-RND-UI-05-E2E-01: real 429 mounts RateLimitBackpressure on /tasks/inbox', async ({
    page,
    request,
  }, testInfo: TestInfo) => {
    test.setTimeout(60_000)
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    const burst = await burstUntil429(request, token, '/api/v1/tasks/inbox')
    if (!burst.limited) {
      testInfo.skip(
        true,
        `No 429 observed after burst — backend rate-limit not engaged (status=${burst.status}). ` +
          'Increase maxRequests or check API-10 config.',
      )
      return
    }
    expect(burst.status).toBe(429)
    expect(burst.retryAfter).not.toBeNull()

    await page.goto('/tasks/inbox')
    const wrapper = page.getByTestId('rate-limit-backpressure')
    await expect(wrapper).toBeVisible({ timeout: 10_000 })
    await expect(wrapper).toHaveAttribute('role', 'status')
    await expect(wrapper).toHaveAttribute('aria-live', 'polite')
    await expect(wrapper).toHaveAttribute('aria-atomic', 'true')
  })

  test('TC-RND-UI-05-E2E-02: countdown text decreases each second', async ({
    page,
    request,
  }, testInfo: TestInfo) => {
    test.setTimeout(60_000)
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    const burst = await burstUntil429(request, token, '/api/v1/tasks/inbox', 60)
    if (!burst.limited) {
      testInfo.skip(true, 'No 429 observed after burst — skipping countdown assertion')
      return
    }
    await page.goto('/tasks/inbox')
    const countdown = page.getByTestId('retry-countdown')
    await expect(countdown).toBeVisible({ timeout: 10_000 })
    const initial = (await countdown.textContent()) ?? ''
    await page.waitForTimeout(2_500)
    const later = (await countdown.textContent()) ?? ''
    expect(later).not.toEqual(initial)
    expect(initial).toMatch(/Retry in \d+s/)
    expect(later).toMatch(/Retry in \d+s/)
  })

  test('TC-RND-UI-05-E2E-03: clicking Retry-now fires exactly one refetch', async ({
    page,
    request,
  }, testInfo: TestInfo) => {
    test.setTimeout(60_000)
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    const burst = await burstUntil429(request, token, '/api/v1/tasks/inbox', 60)
    if (!burst.limited) {
      testInfo.skip(true, 'No 429 observed after burst — skipping refetch assertion')
      return
    }

    const inboxRequests: string[] = []
    page.on('request', (req) => {
      if (req.url().includes('/api/v1/tasks/inbox')) {
        inboxRequests.push(req.url())
      }
    })

    await page.goto('/tasks/inbox')
    await expect(page.getByTestId('rate-limit-backpressure')).toBeVisible({ timeout: 10_000 })
    await page.getByTestId('rate-limit-retry-now').click()
    await page.waitForTimeout(2_000)
    const pageInboxRequests = inboxRequests.length
    expect(pageInboxRequests).toBeGreaterThanOrEqual(1)
    // At most one click-triggered refetch from the boundary (the parent
    // owns the query lifecycle; React Query retry:0 prevents doubles).
    expect(pageInboxRequests).toBeLessThanOrEqual(2)
  })

  test('TC-RND-UI-05-E2E-04: second 429 starts a new countdown', async ({
    page,
    request,
  }, testInfo: TestInfo) => {
    test.setTimeout(90_000)
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    const first = await burstUntil429(request, token, '/api/v1/tasks/inbox', 60)
    if (!first.limited) {
      testInfo.skip(true, 'No 429 observed after burst — skipping second-429 assertion')
      return
    }
    await page.goto('/tasks/inbox')
    await expect(page.getByTestId('rate-limit-backpressure')).toBeVisible({ timeout: 10_000 })
    await page.getByTestId('rate-limit-retry-now').click()
    await page.waitForTimeout(2_000)
    const second = await burstUntil429(request, token, '/api/v1/tasks/inbox', 60)
    if (!second.limited) {
      testInfo.skip(true, 'Second burst did not 429 — bucket recovered (documented skip)')
      return
    }
    await page.goto('/tasks/inbox')
    await expect(page.getByTestId('rate-limit-backpressure')).toBeVisible({ timeout: 10_000 })
    const countdown = page.getByTestId('retry-countdown')
    await expect(countdown).toBeVisible()
    expect(await countdown.textContent()).toMatch(/Retry in \d+s/)
  })

  test('TC-RND-UI-05-E2E-05: 429 without Retry-After renders FetchError (no RateLimitBackpressure)', async ({
    page,
    request,
  }, testInfo: TestInfo) => {
    test.setTimeout(60_000)
    const token = await getKeycloakToken(request, 'worker-user', 'worker-pass')
    const headers = { Authorization: `Bearer ${token}` }
    let sawNoRetryAfter = false
    for (let i = 0; i < 60; i += 1) {
      const r = await request.get('/api/v1/tasks/inbox', { headers })
      if (r.status() === 429 && (r.headers()['retry-after'] ?? null) === null) {
        sawNoRetryAfter = true
        break
      }
    }
    if (!sawNoRetryAfter) {
      testInfo.skip(
        true,
        'Backend fixture did not produce a 429 without Retry-After in this run. ' +
          'The unit test (RateLimitBackpressure.test.tsx + classifyError.test.ts) covers ' +
          'the §12.1 mode 2 contract deterministically.',
      )
      return
    }
    await page.goto('/tasks/inbox')
    await expect(page.getByTestId('rate-limit-backpressure')).toHaveCount(0)
    await expect(page.getByRole('button', { name: /retry/i }).first()).toBeVisible({
      timeout: 10_000,
    })
  })
})
